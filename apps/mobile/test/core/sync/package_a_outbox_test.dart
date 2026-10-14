import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';

class PackageTransport implements CommandTransport {
  final requests = <DispatchRequest>[];
  DispatchResult? completionResult;
  Object? startResponse;
  @override
  Future<DispatchResult> dispatch(DispatchRequest request) async {
    requests.add(request);
    if (request.type == CommandType.completeIrrigationSession) {
      return completionResult ??
          const DispatchAccepted(
            response: {'session_charge_id': 'charge'},
            entityId: 'charge',
          );
    }
    return normalizeAcceptedResponse(
      request.type,
      startResponse ?? {'session_id': 'server-B'},
    );
  }
}

final instant = DateTime.utc(2026, 10, 13, 10);
CommandEnvelope command(
  String id,
  CommandType type,
  int sequence, {
  List<String> prerequisites = const [],
  String well = 'well',
}) => CommandEnvelope(
  localId: id,
  commandId: 'uuid-$id',
  type: type,
  accountId: 'account',
  sequence: sequence,
  occurredAt: instant,
  createdLocalAt: instant,
  wellId: well,
  prerequisites: prerequisites,
  localContext: const {'p_farm_id': 'farm', 'p_energy_source': 'well_diesel'},
  payload: type == CommandType.startBookingSession
      ? {'p_booking_id': 'B', 'p_crops': <String>[]}
      : {'p_session_id': 'server-A'},
);
void main() {
  test('booking contract dispatch excludes local context and dependencies and maps session', () async {
    final store = InMemoryOutboxStore();
    await store.insert(command('A', CommandType.completeIrrigationSession, 1));
    await store.insert(
      command('B', CommandType.startBookingSession, 2, prerequisites: ['A']),
    );
    final transport = PackageTransport();
    await SyncEngine(store: store, transport: transport).run('account');
    expect(transport.requests.map((r) => r.type.rpcName), [
      'complete_irrigation_session',
      'start_irrigation_session_from_booking',
    ]);
    expect(transport.requests.last.arguments, {
      'p_booking_id': 'B',
      'p_crops': [],
      'p_started_at': '2026-10-13T10:00:00.000Z',
      'p_command_id': 'uuid-B',
    });
    expect(
      (await store.mapping('account', 'B', EntityKind.session))?.serverId,
      'server-B',
    );
  });
  for (final mode in ['retry', 'review', 'missing', 'dispatching']) {
    test(
      'prerequisite $mode prevents B dispatch but permits unrelated well',
      () async {
        final store = InMemoryOutboxStore();
        if (mode != 'missing') {
          await store.insert(
            command('A', CommandType.completeIrrigationSession, 1),
          );
        }
        if (mode == 'dispatching') {
          await store.claim('account', 'A', attemptedAt: DateTime.now());
        }
        await store.insert(
          command(
            'B',
            CommandType.startBookingSession,
            2,
            prerequisites: ['A'],
          ),
        );
        await store.insert(
          command('C', CommandType.startBookingSession, 3, well: 'other-well'),
        );
        final transport = PackageTransport();
        if (mode == 'retry') {
          transport.completionResult = const DispatchFailed(
            disposition: FailureDisposition.retry,
            message: 'offline',
          );
        }
        if (mode == 'review') {
          transport.completionResult = const DispatchFailed(
            disposition: FailureDisposition.review,
            message: 'conflict',
          );
        }
        await SyncEngine(store: store, transport: transport).run('account');
        expect(transport.requests.any((r) => r.commandId == 'uuid-B'), isFalse);
        expect(transport.requests.any((r) => r.commandId == 'uuid-C'), isTrue);
        expect(
          (await store.commandByLocalId('account', 'B'))!.status,
          ['review', 'missing'].contains(mode)
              ? CommandStatus.review
              : CommandStatus.pending,
        );
      },
    );
  }
  test('booking conflict carrying an existing session ID is review, never acceptance', () {
    final result = normalizeAcceptedResponse(CommandType.startBookingSession, {
      'status': 'conflict',
      'session_id': 'existing',
      'message': 'booking already consumed',
    });
    expect(result, isA<DispatchFailed>());
    expect((result as DispatchFailed).disposition, FailureDisposition.review);
  });
  test(
    'well projection never requests the global account command list',
    () async {
      final store = NoGlobalReadStore();
      await store.insert(command('B', CommandType.startBookingSession, 1));
      await store.insert(
        command('C', CommandType.startBookingSession, 2, well: 'other-well'),
      );
      final coordinator = OfflineSessionCoordinator(store: store);
      final record = await coordinator.projectActiveSession(
        accountId: 'account',
        wellId: 'well',
      );
      expect(record?.localId, 'B');
      coordinator.dispose();
    },
  );
  test('A review is visible in B projection before another sync run', () async {
    final store = InMemoryOutboxStore();
    await store.insert(command('A', CommandType.completeIrrigationSession, 1));
    await store.insert(
      command('B', CommandType.startBookingSession, 2, prerequisites: ['A']),
    );
    await store.markNeedsReview(
      'account',
      'A',
      error: 'conflict',
      attemptedAt: instant,
    );
    final coordinator = OfflineSessionCoordinator(store: store);
    final record = await coordinator.projectActiveSession(
      accountId: 'account',
      wellId: 'well',
    );
    expect(record?.syncState, SessionSyncState.conflict);
    expect(record?.businessState.isActive, isTrue);
    coordinator.dispose();
  });
  test('atomic bundle rollback and deduplication keep commands and record together', () async {
    final store = InMemoryOutboxStore();
    final commands = [
      command('A', CommandType.completeIrrigationSession, 1),
      command('B', CommandType.startBookingSession, 2, prerequisites: ['A']),
    ];
    await expectLater(
      store.insertBundle(
        accountId: 'account',
        key: 'boundary',
        value: 'record',
        commands: commands,
        isCurrent: () => false,
      ),
      throwsStateError,
    );
    expect(await store.allCommands('account'), isEmpty);
    expect(await store.readBundle('account', 'boundary'), isNull);
    expect(
      await store.insertBundle(
        accountId: 'account',
        key: 'boundary',
        value: 'record',
        commands: commands,
      ),
      'record',
    );
    expect(
      await store.insertBundle(
        accountId: 'account',
        key: 'boundary',
        value: 'different',
        commands: commands,
      ),
      'record',
    );
    expect(await store.allCommands('account'), hasLength(2));
  });
}

class NoGlobalReadStore extends InMemoryOutboxStore {
  @override
  Future<List<CommandEnvelope>> allCommands(String accountId) async =>
      throw StateError('global scan prohibited');
}

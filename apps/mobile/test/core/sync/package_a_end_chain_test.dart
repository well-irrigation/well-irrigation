import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';

import 'package_a_outbox_test.dart' as f;

class EndChainTransport extends f.PackageTransport {
  bool rejectEnd = false;
  @override
  Future<DispatchResult> dispatch(DispatchRequest request) async {
    if (request.type != CommandType.endBookingTransitionChain) {
      return super.dispatch(request);
    }
    requests.add(request);
    return normalizeAcceptedResponse(
      request.type,
      rejectEnd
          ? {
              'contract': 'end_booking_transition_chain',
              'version': 1,
              'status': 'rejected',
              'reason_code': 'next_booking_exists',
            }
          : {
              'contract': 'end_booking_transition_chain',
              'version': 1,
              'status': 'ended',
              'session_id': 'server-B',
              'chain_id': 'chain',
              'well_id': 'well',
              'ended_reason': 'final_booking_completed',
              'ended_at': f.instant.toIso8601String(),
            },
    );
  }
}

void main() {
  test('end-chain contract has only session and stable command id, no entity or event time', () {
    const type = CommandType.endBookingTransitionChain;
    expect(type.rpcName, 'end_booking_transition_chain');
    expect(type.scope, CommandScope.session);
    expect(type.produces, isNull);
    expect(type.eventTimeArgument, isNull);
    expect(
      buildRpcArguments(
        type: type,
        commandId: 'stable',
        occurredAt: f.instant,
        resolvedPayload: {'p_session_id': 'server'},
      ),
      {'p_session_id': 'server', 'p_command_id': 'stable'},
    );
  });
  for (final mode in ['pending', 'retry', 'review', 'accepted']) {
    test(
      'retired end-chain held with completion $mode and another well dispatches',
      () async {
        final store = InMemoryOutboxStore();
        await store.insert(
          f.command('complete', CommandType.completeIrrigationSession, 1),
        );
        await store.insert(
          f.command(
            'unrelated',
            CommandType.startBookingSession,
            3,
            well: 'other',
          ),
        );
        await f.seedPackageHumanActions(store);
        await store.insert(
          f.command(
            'end',
            CommandType.endBookingTransitionChain,
            2,
            prerequisites: ['complete'],
          ),
        );
        if (mode == 'pending') {
          await store.claim('account', 'complete', attemptedAt: DateTime.now());
        }
        final transport = EndChainTransport()
          ..startResponse = {
            'session_id': 'server-unrelated',
            'booking_id': 'B',
            'well_id': 'other',
            'session_status': 'open',
            'booking_status': 'confirmed',
            'started_at': f.instant.toIso8601String(),
            'booked_duration_minutes': 10,
            'operational_end_at': f.instant
                .add(const Duration(minutes: 10))
                .toIso8601String(),
          };
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
        expect(
          transport.requests.any((r) => r.commandId == 'uuid-end'),
          isFalse,
        );
        expect(
          transport.requests.any((r) => r.commandId == 'uuid-unrelated'),
          isTrue,
        );
        expect(
          (await store.commandByLocalId('account', 'unrelated'))?.status,
          CommandStatus.confirmed,
        );
        final row = (await store.commandByLocalId('account', 'end'))!;
        expect(row.status, CommandStatus.pending);
        expect(row.lastAttemptAt, isNull);
        expect(row.commandId, 'uuid-end');
      },
    );
  }
  test(
    'resolved reference does not reactivate retired end-chain on replay',
    () async {
      final store = InMemoryOutboxStore();
      await store.putMapping(
        'account',
        IdMapping(
          localId: 'local-session',
          kind: EntityKind.session,
          serverId: 'server-B',
          resolvedAt: f.instant,
        ),
      );
      await store.insert(
        f.command('end', CommandType.endBookingTransitionChain, 1),
      );
      final before = (await store.commandByLocalId('account', 'end'))!;
      final transport = EndChainTransport();
      final engine = SyncEngine(store: store, transport: transport);
      await engine.run('account');
      await engine.run('account');
      expect(transport.requests, isEmpty);
      expect(
        (await store.commandByLocalId('account', 'end'))?.payload,
        before.payload,
      );
      expect(await store.mapping('account', 'end', EntityKind.session), isNull);
      expect(await store.mappings('account'), hasLength(1));
    },
  );
  test(
    'legacy rejection history survives without retrying retired end-chain',
    () async {
      final store = InMemoryOutboxStore();
      await store.insert(
        f.command('end', CommandType.endBookingTransitionChain, 1),
      );
      await store.markNeedsReview(
        'account',
        'end',
        error: 'next_booking_exists',
        attemptedAt: f.instant,
        serverResponse: {
          'status': 'rejected',
          'reason_code': 'next_booking_exists',
        },
      );
      final transport = EndChainTransport();
      final engine = SyncEngine(store: store, transport: transport);
      await engine.run('account');
      await engine.run('account');
      final row = (await store.commandByLocalId('account', 'end'))!;
      expect(row.status, CommandStatus.review);
      expect(row.serverResponse?['reason_code'], 'next_booking_exists');
      expect(transport.requests, isEmpty);
    },
  );
}

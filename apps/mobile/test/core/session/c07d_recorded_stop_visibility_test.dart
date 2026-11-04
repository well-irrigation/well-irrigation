import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/session/manual_stop_request_store.dart';
import 'package:well_irrigation_mobile/core/session/time_integrity.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

final startAt = DateTime.utc(2026, 11, 1, 8);
final stopAt = startAt.add(const Duration(seconds: 20));
CommandEnvelope root() => CommandEnvelope(
  accountId: 'a',
  wellId: 'w',
  localId: 'root',
  commandId: 'start-command',
  type: CommandType.startIrrigationSession,
  sequence: 1,
  occurredAt: startAt,
  createdLocalAt: startAt,
  payload: {'p_well_id': 'w', 'p_energy_source': 'well_diesel'},
);

class FailingReadStore extends InMemoryOutboxStore {
  @override
  Future<String?> readBundle(String account, String key) {
    if (key == ManualStopRequestStore.keyFor('w', 'root')) {
      throw StateError('recorded_stop_read_failed');
    }
    return super.readBundle(account, key);
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory directory;
  late SqliteOutboxStore store;
  Future<void> open() async {
    store = SqliteOutboxStore(
      databasePath: '${directory.path}/outbox.db',
      sqfliteFactory: databaseFactoryFfi,
      singleInstance: false,
    );
    await store.initialize();
  }

  Future<ManualStopRequest> record({DateTime? at}) =>
      ManualStopRequestStore(store).recordHumanStopRequest(
        accountId: 'a',
        wellId: 'w',
        sessionLocalId: 'root',
        requestedAt: at ?? stopAt,
      );
  Future<ActiveSessionRecord> project({DateTime? now}) async =>
      (await ActiveSessionProjector(store: store).projectSession(
        'a',
        'root',
        now: now ?? startAt.add(const Duration(hours: 1)),
      ))!;
  Future<String> snapshot() async => jsonEncode({
    'commands': [
      for (final c in await store.allCommands('a'))
        dispatchCommandFingerprint(c),
    ],
    'mappings': await store.notificationEvents.db.query(
      'id_mappings',
      orderBy: 'local_id,entity_kind',
    ),
    'metadata': await store.notificationEvents.db.query(
      'sync_meta',
      orderBy: 'account_id,key',
    ),
    'notifications': await store.notificationEvents.db.query(
      'notification_events',
      orderBy: 'event_key',
    ),
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('c07d_visibility_');
    await open();
    await store.insert(root());
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });
  group('death before materialization', () {
    test(
      'reopen freezes recorded stop without completion or storage effects',
      () async {
        final request = await record();
        expect(await store.allCommands('a'), hasLength(1));
        expect(
          await store.readBundle(
            'a',
            manualStopMaterializationKey('w', 'root'),
          ),
          isNull,
        );
        final before = await snapshot();
        await store.close();
        await open();
        final first = await project();
        expect(first.businessState.name, 'stopRequested');
        expect(first.stopRequestedAt, request.requestedAt);
        expect(first.completedAt, isNull);
        expect(first.approvedAmountMinor, isNull);
        expect(first.businessState.isActive, isTrue);
        expect(first.totals.billableSeconds, 20);
        expect(first.totals.wallClockSeconds, 20);
        expect(
          await ActiveSessionProjector(store: store)
              .activeSessions('a', now: startAt.add(const Duration(days: 1))),
          hasLength(1),
        );
        final later = await project(now: startAt.add(const Duration(days: 2)));
        expect(later.totals.billableSeconds, 20);
        expect(later.totals.wallClockSeconds, 20);
        expect(await snapshot(), before);
      },
    );
    test('wrong account and wrong well cannot borrow the request', () async {
      await record();
      final p = ActiveSessionProjector(store: store);
      expect(await p.projectAll('other', now: stopAt), isEmpty);
      expect(await p.projectAll('a', wellId: 'other', now: stopAt), isEmpty);
    });
    for (final beforeStart in [false, true]) {
      test(
        'timing conflict remains visible beforeStart=$beforeStart',
        () async {
          final requested = beforeStart
              ? startAt.subtract(const Duration(seconds: 1))
              : stopAt;
          await record(at: requested);
          if (!beforeStart) {
            await store.insert(
              CommandEnvelope(
                accountId: 'a',
                wellId: 'w',
                localId: 'later-control',
                commandId: 'later-command',
                sequence: 2,
                type: CommandType.resumeIrrigationSession,
                aggregateLocalId: 'root',
                occurredAt: stopAt.add(const Duration(seconds: 10)),
                createdLocalAt: stopAt,
                payload: const {
                  'p_session_id': {r'$ref': 'root', r'$kind': 'session'},
                },
              ),
            );
          }
          final before = await snapshot();
          final result = await project();
          expect(result.businessState.name, 'stopRequested');
          expect(result.stopRequestedAt, requested);
          expect(
            result.timeIntegrityFlags,
            contains(TimeIntegrityFlag.impossibleEventOrdering),
          );
          expect(result.totals.billableSeconds, beforeStart ? 0 : 20);
          expect(result.completedAt, isNull);
          expect(await snapshot(), before);
        },
      );
    }
    test('request read failure is surfaced', () async {
      final failing = FailingReadStore();
      await failing.initialize();
      await failing.insert(root());
      addTearDown(failing.close);
      await expectLater(
        ActiveSessionProjector(store: failing).projectAll('a', now: stopAt),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'recorded_stop_read_failed',
          ),
        ),
      );
    });
  });
  group('materialization and accepted precedence', () {
    test(
      'materialization stays pending and accepted completion wins',
      () async {
        final request = await record();
        expect((await project()).businessState.name, 'stopRequested');
        final requests = ManualStopRequestStore(store);
        final completion = await requests.materializeRecordedRequest(request);
        expect((await project()).businessState.name, 'stopRequested');
        expect(
          (await requests.materializeRecordedRequest(request)).commandId,
          completion.commandId,
        );
        await store.putMapping(
          'a',
          IdMapping(
            localId: 'root',
            kind: EntityKind.session,
            serverId: 'server',
            resolvedAt: startAt,
          ),
        );
        final receipt = <String, Object?>{
          'session_id': 'server',
          'session_charge_id': 'charge',
          'status': 'closed',
          'ended_at': startAt
              .add(const Duration(seconds: 25))
              .toIso8601String(),
          'actual_seconds': 25,
          'billable_seconds': 23,
          'weighted_price_per_hour_minor': 3600,
          'amount_minor': 99,
          'segments': <Object?>[],
        };
        expect(
          await store.reconcileCompletionReceipt(completion, 'server', receipt),
          isTrue,
        );
        final before = await snapshot();
        for (var i = 0; i < 2; i++) {
          final result = await project();
          expect(result.businessState.name, 'completed');
          expect(result.stopRequestedAt, isNull);
          expect(result.completedAt, startAt.add(const Duration(seconds: 25)));
          expect(result.approvedAmountMinor, 99);
          expect(result.totals.billableSeconds, 23);
          expect(result.businessState.isActive, isFalse);
        }
        expect(
          (await requests.read(
            accountId: 'a',
            wellId: 'w',
            sessionLocalId: 'root',
          ))!.requestId,
          request.requestId,
        );
        expect(await snapshot(), before);
      },
    );
    test(
      'malformed confirmed completion cannot close stop or completed snapshot',
      () async {
        final request = await record();
        final completion = await ManualStopRequestStore(store)
            .materializeRecordedRequest(request);
        await store.markConfirmed(
          'a',
          completion.localId,
          attemptedAt: stopAt,
          serverResponse: const {
            'status': 'closed',
            'session_charge_id': 'charge',
            'amount_minor': 99,
          },
        );
        final before = await snapshot();
        final result = await project();
        expect(result.businessState.name, 'stopRequested');
        expect(result.completedAt, isNull);
        expect(result.approvedAmountMinor, isNull);
        final snap = await store.sessionSnapshot(
          accountId: 'a',
          wellId: 'w',
          localSessionId: 'root',
        );
        expect(
          ActiveSessionProjector(store: store)
              .projectCompletedSnapshot(snap!, now: stopAt),
          isNull,
        );
        expect(await snapshot(), before);
      },
    );
  });
}

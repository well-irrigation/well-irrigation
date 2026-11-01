import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

final at = DateTime.utc(2026, 10, 20, 9);
const humanKey = 'booking.manual_start.v1.well.booking';
DispatchClaimDecision humanOnly(DispatchClaimContext context) =>
    switch (context.intent.origin) {
      CommandIntentOrigin.provenHuman => DispatchClaimDecision.allow,
      CommandIntentOrigin.provenAutomatic =>
        DispatchClaimDecision.automaticSuspended,
      CommandIntentOrigin.unresolved => DispatchClaimDecision.originUnresolved,
    };

CommandEnvelope start({
  String localId = 'start',
  String commandId = 'start-command',
  List<String> prerequisites = const [],
  CommandType type = CommandType.startBookingSession,
  Map<String, Object?>? payload,
}) => CommandEnvelope(
  localId: localId,
  commandId: commandId,
  accountId: 'account',
  wellId: 'well',
  sequence: localId == 'start' ? 1 : 2,
  occurredAt: at,
  createdLocalAt: at,
  type: type,
  prerequisites: prerequisites,
  payload: payload ?? {'p_booking_id': 'booking'},
  localContext: {'manual_start': true, 'booking_id': 'booking'},
);

Future<void> seed(OutboxStore store, {bool human = true}) async {
  if (human) {
    await store.insertBundle(
      accountId: 'account',
      key: humanKey,
      value: jsonEncode({
        'start_local_id': 'start',
        'start_command_id': 'start-command',
      }),
      commands: [start()],
    );
  } else {
    await store.insert(start());
  }
}

Future<DispatchClaimResult> claim(
  OutboxStore store, {
  String localId = 'start',
  String commandId = 'start-command',
  DispatchClaimPolicy policy = humanOnly,
}) => (store as AtomicCommandDispatchStore).claimDispatch(
  accountId: 'account',
  wellId: 'well',
  localId: localId,
  commandId: commandId,
  attemptedAt: at,
  policy: policy,
);

Future<Map<String, Object?>> workerClaim(String path, SendPort ready) async {
  sqfliteFfiInit();
  final store = SqliteOutboxStore(
    databasePath: path,
    sqfliteFactory: databaseFactoryFfi,
    singleInstance: false,
  );
  final gate = ReceivePort();
  try {
    await store.initialize();
    ready.send(gate.sendPort);
    await gate.first;
    final result = await claim(store);
    return {'claimed': result.isClaimed, 'attempt': result.attempt?.attemptId};
  } finally {
    gate.close();
    await store.close();
  }
}

Future<Map<String, Object?>> isolatedClaim(String path, SendPort ready) =>
    Isolate.run(() => workerClaim(path, ready));

void main() {
  setUpAll(sqfliteFfiInit);
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite' : 'memory', () {
      late OutboxStore store;
      late Directory dir;
      setUp(() async {
        dir = await Directory.systemTemp.createTemp('q137-dispatch-');
        store = sqlite
            ? SqliteOutboxStore(
                databasePath: '${dir.path}/db',
                sqfliteFactory: databaseFactoryFfi,
                singleInstance: false,
              )
            : InMemoryOutboxStore();
        await store.initialize();
      });
      tearDown(() async {
        await store.close();
        await dir.delete(recursive: true);
      });

      test('claims current proven human row, preserving payload and business identities', () async {
        await seed(store);
        final result = await claim(store);
        expect(result.isClaimed, isTrue);
        expect(result.context!.intent.origin, CommandIntentOrigin.provenHuman);
        expect(result.command!.status, CommandStatus.dispatching);
        expect(result.command!.localId, 'start');
        expect(result.command!.commandId, 'start-command');
        expect(result.command!.payload, {'p_booking_id': 'booking'});
        expect(
          () => result.command!.payload['p_booking_id'] = 'other',
          throwsUnsupportedError,
        );
      });

      test(
        'unresolved and identity failures write neither status nor metadata',
        () async {
          await seed(store, human: false);
          final before = await store.commandByLocalId('account', 'start');
          expect(
            (await claim(store)).decision,
            DispatchClaimDecision.originUnresolved,
          );
          expect(
            (await claim(store, commandId: 'wrong')).decision,
            DispatchClaimDecision.identityMismatch,
          );
          final after = await store.commandByLocalId('account', 'start');
          expect(after!.status, before!.status);
          expect(after.retryCount, before.retryCount);
          expect(after.lastAttemptAt, isNull);
          expect(
            await store.readLocalValuesByPrefix('account', 'command.dispatch.'),
            isEmpty,
          );
        },
      );

      test('changed original evidence is checked inside claim, not an old classification', () async {
        await seed(store);
        final original = (await store.commandByLocalId('account', 'start'))!;
        expect(
          classifyCommandIntent(
            original,
            records: {
              humanKey: {
                'start_local_id': 'start',
                'start_command_id': 'start-command',
              },
            },
          ).origin,
          CommandIntentOrigin.provenHuman,
        );
        // أصل أحدث لنفس الحجز: المفتاح نفسه، والقديم لا يجوز أن يرثه.
        await store.insertBundle(
          accountId: 'account',
          key: 'test.change',
          value: 'x',
          commands: [],
          localValues: {
            humanKey: jsonEncode({
              'start_local_id': 'other',
              'start_command_id': 'other-command',
            }),
          },
        );
        expect(
          (await claim(store)).decision,
          DispatchClaimDecision.originUnresolved,
        );
        expect(
          (await store.commandByLocalId('account', 'start'))!.status,
          CommandStatus.pending,
        );
      });

      test(
        'confirmed row and legacy in-flight row cannot be claimed',
        () async {
          await seed(store);
          await store.claim('account', 'start', attemptedAt: at);
          expect(
            (await claim(store)).decision,
            DispatchClaimDecision.previousAttemptUnresolved,
          );
          await store.markConfirmed(
            'account',
            'start',
            attemptedAt: at,
            serverResponse: {'receipt': 'accepted'},
          );
          expect(
            (await claim(store)).decision,
            DispatchClaimDecision.notPending,
          );
        },
      );

      test('legacy timeout recovery is still unresolved, not proof of server failure', () async {
        await seed(store);
        await store.claim('account', 'start', attemptedAt: at);
        await store.releaseForRetry(
          'account',
          'start',
          attemptedAt: at,
          error: 'network unknown',
        );
        expect(
          (await claim(store)).decision,
          DispatchClaimDecision.previousAttemptUnresolved,
        );
        expect(
          await store.readLocalValuesByPrefix('account', 'command.dispatch.'),
          isEmpty,
        );
      });

      test('two concurrent claims yield only one durable owner', () async {
        await seed(store);
        final results = await Future.wait([claim(store), claim(store)]);
        expect(results.where((r) => r.isClaimed), hasLength(1));
        expect(results.where((r) => !r.isClaimed), hasLength(1));
      });

      test('old release and late result cannot overwrite newer owner even with same clock', () async {
        await seed(store);
        final api = store as AtomicCommandDispatchStore;
        final old = (await claim(store)).attempt!;
        expect(
          await api.releaseDispatchAttempt(
            old,
            reason: 'explicit_retry_request',
          ),
          isTrue,
        );
        final fresh = (await claim(store)).attempt!;
        expect(fresh.attemptId, isNot(old.attemptId));
        expect(fresh.startedAt, old.startedAt);
        expect(await api.releaseDispatchAttempt(old, reason: 'late'), isFalse);
        expect(
          await api.finishDispatchAttempt(
            old,
            status: CommandStatus.confirmed,
            serverResponse: {'receipt': 'old'},
          ),
          isFalse,
        );
        expect(
          await api.finishDispatchAttempt(
            fresh,
            status: CommandStatus.confirmed,
            serverResponse: {'receipt': 'fresh'},
          ),
          isTrue,
        );
        expect(
          await api.releaseDispatchAttempt(fresh, reason: 'after_final'),
          isFalse,
        );
        expect(
          (await store.commandByLocalId('account', 'start'))!.serverResponse,
          {'receipt': 'fresh'},
        );
      });

      test('unresolved dependency holds only its consumer, not independent payment', () async {
        await seed(store, human: false);
        await store.insert(
          start(
            localId: 'child',
            commandId: 'child-command',
            prerequisites: ['start'],
          ),
        );
        expect(
          (await claim(
            store,
            localId: 'child',
            commandId: 'child-command',
            policy: (_) => DispatchClaimDecision.allow,
          )).decision,
          DispatchClaimDecision.dependencyUnresolved,
        );
        await store.insert(
          start(
            localId: 'payment',
            commandId: 'payment-command',
            type: CommandType.recordPayment,
            payload: {
              'p_well_id': 'well',
              'p_farmer_well_account_id': 'farmer',
              'p_amount_minor': 10,
            },
          ),
        );
        expect(
          (await claim(
            store,
            localId: 'payment',
            commandId: 'payment-command',
            policy: (_) => DispatchClaimDecision.allow,
          )).isClaimed,
          isTrue,
        );
        expect(
          (await store.commandByLocalId('account', 'start'))!.status,
          CommandStatus.pending,
        );
      });

      test('wrong account and well cannot claim or read evidence from another scope', () async {
        await seed(store);
        final api = store as AtomicCommandDispatchStore;
        for (final (account, well) in [
          ('other', 'well'),
          ('account', 'other'),
        ]) {
          expect(
            (await api.claimDispatch(
              accountId: account,
              wellId: well,
              localId: 'start',
              commandId: 'start-command',
              attemptedAt: at,
              policy: humanOnly,
            )).isClaimed,
            isFalse,
          );
        }
      });

      test(
        'test policy can suspend a candidate without business review',
        () async {
          await seed(store);
          expect(
            (await claim(
              store,
              policy: (_) => DispatchClaimDecision.policySuspended,
            )).decision,
            DispatchClaimDecision.policySuspended,
          );
          expect(
            (await store.commandByLocalId('account', 'start'))!.status,
            CommandStatus.pending,
          );
          expect(
            await store.readLocalValuesByPrefix('account', 'command.dispatch.'),
            isEmpty,
          );
        },
      );

      test('automatic completion is suspended, and mismatched effect cannot prove origin', () async {
        await seed(store);
        await store.markConfirmed(
          'account',
          'start',
          attemptedAt: at,
          serverResponse: {'session_id': 'server'},
        );
        await store.putMapping(
          'account',
          IdMapping(
            localId: 'start',
            kind: EntityKind.session,
            serverId: 'server',
            resolvedAt: at,
          ),
        );
        final completion = CommandEnvelope(
          localId: 'complete',
          commandId: 'complete-command',
          type: CommandType.completeIrrigationSession,
          accountId: 'account',
          wellId: 'well',
          sequence: 2,
          occurredAt: at,
          createdLocalAt: at,
          aggregateLocalId: 'start',
          payload: {
            'p_session_id': {r'$ref': 'start', r'$kind': 'session'},
          },
        );
        final proof = {
          'version': 1,
          'provenance': 'session_completion_effect',
          'account_id': 'account',
          'well_id': 'well',
          'session_local_id': 'start',
          'completion_local_id': 'complete',
          'completion_command_id': 'complete-command',
          'completed_at': at.toIso8601String(),
          'trigger': 'auto_due',
        };
        const key = 'session.completion.v1.well.start';
        await store.insertBundle(
          accountId: 'account',
          key: key,
          value: jsonEncode(proof),
          commands: [completion],
        );
        final denied = await claim(
          store,
          localId: 'complete',
          commandId: 'complete-command',
        );
        expect(denied.decision, DispatchClaimDecision.automaticSuspended);
        expect(
          denied.context!.intent.origin,
          CommandIntentOrigin.provenAutomatic,
        );
        expect(
          (await store.commandByLocalId('account', 'complete'))!.status,
          CommandStatus.pending,
        );
        await store.insertBundle(
          accountId: 'account',
          key: 'test.corrupt',
          value: 'x',
          commands: [],
          localValues: {
            key: jsonEncode({...proof, 'completion_command_id': 'different'}),
          },
        );
        expect(
          (await claim(
            store,
            localId: 'complete',
            commandId: 'complete-command',
          )).decision,
          DispatchClaimDecision.originUnresolved,
        );
        expect(
          await store.readLocalValuesByPrefix('account', 'command.dispatch.'),
          isEmpty,
        );
      });

      test('claim policy cannot mutate the command that would be returned for transport', () async {
        await seed(store);
        await expectLater(
          claim(
            store,
            policy: (context) {
              context.command.localContext['manual_start'] = false;
              return DispatchClaimDecision.allow;
            },
          ),
          throwsUnsupportedError,
        );
        expect(
          (await store.commandByLocalId('account', 'start'))!.status,
          CommandStatus.pending,
        );
        expect(
          await store.readLocalValuesByPrefix('account', 'command.dispatch.'),
          isEmpty,
        );
      });

      test('released attempt history is retained and terminal receipt cannot be overwritten', () async {
        await seed(store);
        final api = store as AtomicCommandDispatchStore;
        final old = (await claim(store)).attempt!;
        expect(
          await api.releaseDispatchAttempt(
            old,
            reason: 'explicit retry, outcome not inferred',
          ),
          isTrue,
        );
        final current = (await claim(store)).attempt!;
        expect(
          await store.readBundle(
            'account',
            dispatchAttemptHistoryKey('start', old.attemptId),
          ),
          isNotNull,
        );
        expect(
          await api.finishDispatchAttempt(
            current,
            status: CommandStatus.review,
            serverResponse: {'status': 'rejected', 'reason_code': 'semantic'},
          ),
          isTrue,
        );
        expect(
          await api.finishDispatchAttempt(
            old,
            status: CommandStatus.confirmed,
            serverResponse: {'receipt': 'late'},
          ),
          isFalse,
        );
        expect(
          (await store.commandByLocalId('account', 'start'))!.serverResponse,
          {'status': 'rejected', 'reason_code': 'semantic'},
        );
      });
    });
  }

  test('independent SQLite connections contend and unresolved attempt survives reopening', () async {
    final dir = await Directory.systemTemp.createTemp('q137-two-connections-');
    final path = '${dir.path}/db';
    SqliteOutboxStore open() => SqliteOutboxStore(
      databasePath: path,
      sqfliteFactory: databaseFactoryFfi,
      singleInstance: false,
    );
    final first = open(), second = open();
    await first.initialize();
    await second.initialize();
    await seed(first);
    final results = await Future.wait([claim(first), claim(second)]);
    final winner = results.singleWhere((r) => r.isClaimed).attempt!;
    expect(results.where((r) => r.isClaimed), hasLength(1));
    await first.close();
    await second.close();
    final reopened = open();
    try {
      await reopened.initialize();
      expect(
        (await claim(reopened)).decision,
        DispatchClaimDecision.previousAttemptUnresolved,
      );
      expect(
        await reopened.finishDispatchAttempt(
          winner,
          status: CommandStatus.confirmed,
          serverResponse: {'receipt': 'worker_without_callback'},
        ),
        isTrue,
      );
      expect(
        (await reopened.commandByLocalId('account', 'start'))!.serverResponse,
        {'receipt': 'worker_without_callback'},
      );
      expect(SqliteOutboxStore.schemaVersion, 11);
    } finally {
      await reopened.close();
      await dir.delete(recursive: true);
    }
  });

  test(
    'memory optimistic commit detects a legacy writer during evidence reads',
    () async {
      final store = InMemoryOutboxStore();
      await store.initialize();
      try {
        await seed(store);
        final pending = claim(store);
        final writing = store.markConfirmed(
          'account',
          'start',
          attemptedAt: at,
          serverResponse: {'accepted': true},
        );
        await writing;
        expect(
          (await pending).decision,
          DispatchClaimDecision.concurrentChange,
        );
        expect(
          (await store.commandByLocalId('account', 'start'))!.status,
          CommandStatus.confirmed,
        );
        expect(
          await store.readLocalValuesByPrefix('account', 'command.dispatch.'),
          isEmpty,
        );
      } finally {
        await store.close();
      }
    },
  );

  test('separate worker isolates race from a shared gate against the same SQLite file', () async {
    final dir = await Directory.systemTemp.createTemp('q137-worker-race-');
    final path = '${dir.path}/db';
    final setup = SqliteOutboxStore(
      databasePath: path,
      sqfliteFactory: databaseFactoryFfi,
      singleInstance: false,
    );
    await setup.initialize();
    await seed(setup);
    await setup.close();
    final ready = ReceivePort();
    try {
      final first = isolatedClaim(path, ready.sendPort),
          second = isolatedClaim(path, ready.sendPort);
      final gates = await ready.take(2).toList();
      for (final gate in gates) {
        (gate as SendPort).send('go');
      }
      final results = await Future.wait([first, second]);
      expect(results.where((r) => r['claimed'] == true), hasLength(1));
      expect(results.where((r) => r['claimed'] == false), hasLength(1));
    } finally {
      ready.close();
      await dir.delete(recursive: true);
    }
  });
}

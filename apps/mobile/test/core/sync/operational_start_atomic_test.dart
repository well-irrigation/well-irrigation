import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite' : 'memory', () {
      late OutboxStore store;
      Directory? dir;
      final at = DateTime.utc(2026);
      final command = CommandEnvelope(
        localId: 'local',
        commandId: 'command',
        accountId: 'account',
        wellId: 'well',
        type: CommandType.startOperationalSession,
        sequence: 1,
        occurredAt: DateTime.utc(2026),
        createdLocalAt: DateTime.utc(2026),
        payload: {'p_well_id': 'well'},
      );
      const receipt = {'id': 'session', 'occurrence_command_id': 'command'};
      Future<void> open() async {
        if (sqlite) {
          dir ??= await Directory.systemTemp.createTemp('r6ab_atomic_');
          store = SqliteOutboxStore(
            databasePath: '${dir!.path}/db',
            sqfliteFactory: databaseFactoryFfi,
            singleInstance: false,
          );
        } else {
          store = InMemoryOutboxStore();
        }
        await store.initialize();
      }

      setUp(open);
      tearDown(() async {
        await store.close();
        if (dir != null) await dir!.delete(recursive: true);
      });
      Future<CommandEnvelope> seed({String? evidence}) async {
        await store.insertBundle(
          accountId: 'account',
          key: humanCommandIntentBundleKey(command.localId),
          value: evidence ?? humanCommandIntentRecord(command),
          commands: [command],
        );
        final claim = await (store as AtomicCommandDispatchStore).claimDispatch(
          accountId: 'account',
          wellId: 'well',
          localId: 'local',
          commandId: 'command',
          attemptedAt: at,
          policy: (_) => DispatchClaimDecision.allow,
        );
        expect(claim.isClaimed, isTrue);
        return claim.command!;
      }

      test('operational start is available to session snapshot', () async {
        await seed();
        final snapshot = await store.sessionSnapshot(
          accountId: 'account',
          wellId: 'well',
          localSessionId: 'local',
        );
        expect(snapshot, isNotNull);
      });
      test('accepted adoption and same mapping idempotent', () async {
        final observed = await seed();
        expect(
          await (store as AtomicCommandDispatchStore)
              .reconcileOperationalStartReceipt(observed, receipt),
          isTrue,
        );
        expect(
          await (store as AtomicCommandDispatchStore)
              .reconcileOperationalStartReceipt(observed, receipt),
          isTrue,
        );
        if (sqlite) {
          await store.close();
          await open();
        }
        expect(
          (await store.commandByLocalId('account', 'local'))!.status,
          CommandStatus.confirmed,
        );
        expect(
          (await store.mapping(
            'account',
            'local',
            EntityKind.session,
          ))!.serverId,
          'session',
        );
      });
      test('review is durable and does not invent mapping', () async {
        final observed = await seed();
        expect(
          await (store as AtomicCommandDispatchStore).reviewOperationalStart(
            observed,
            'review_required',
          ),
          isTrue,
        );
        if (sqlite) {
          await store.close();
          await open();
        }
        expect(
          (await store.commandByLocalId('account', 'local'))!.status,
          CommandStatus.review,
        );
        expect(
          await store.mapping('account', 'local', EntityKind.session),
          isNull,
        );
      });
      test(
        'conflicting mapping remains unchanged and adoption is rejected',
        () async {
          final observed = await seed();
          await store.putMapping(
            'account',
            IdMapping(
              localId: 'local',
              kind: EntityKind.session,
              serverId: 'other',
              resolvedAt: at,
            ),
          );
          expect(
            await (store as AtomicCommandDispatchStore)
                .reconcileOperationalStartReceipt(observed, receipt),
            isFalse,
          );
          expect(
            await (store as AtomicCommandDispatchStore).reviewOperationalStart(
              observed,
              'review_required',
            ),
            isFalse,
          );
          expect(
            (await store.mapping(
              'account',
              'local',
              EntityKind.session,
            ))!.serverId,
            'other',
          );
          expect(
            (await store.commandByLocalId('account', 'local'))!.status,
            CommandStatus.dispatching,
          );
        },
      );
      test('changed fingerprint is rejected without mutation', () async {
        final observed = await seed();
        final changed = observed.copyWith(lastError: 'other');
        expect(
          await (store as AtomicCommandDispatchStore)
              .reconcileOperationalStartReceipt(changed, receipt),
          isFalse,
        );
        expect(
          await (store as AtomicCommandDispatchStore).reviewOperationalStart(
            changed,
            'review_required',
          ),
          isFalse,
        );
        expect(
          (await store.commandByLocalId('account', 'local'))!.status,
          CommandStatus.dispatching,
        );
        expect(
          await store.mapping('account', 'local', EntityKind.session),
          isNull,
        );
      });
      test('missing human proof rejects adoption and review', () async {
        await store.insert(command);
        final claim = await (store as AtomicCommandDispatchStore).claimDispatch(
          accountId: 'account',
          wellId: 'well',
          localId: 'local',
          commandId: 'command',
          attemptedAt: at,
          policy: (_) => DispatchClaimDecision.allow,
        );
        expect(claim.isClaimed, isTrue);
        final observed = claim.command!;
        expect(
          await (store as AtomicCommandDispatchStore)
              .reconcileOperationalStartReceipt(observed, receipt),
          isFalse,
        );
        expect(
          await (store as AtomicCommandDispatchStore).reviewOperationalStart(
            observed,
            'review_required',
          ),
          isFalse,
        );
        expect(
          (await store.commandByLocalId('account', 'local'))!.status,
          CommandStatus.dispatching,
        );
        expect(
          await store.mapping('account', 'local', EntityKind.session),
          isNull,
        );
      });
      test('incorrect human proof rejects adoption and review', () async {
        final observed = await seed(evidence: '{}');
        expect(
          await (store as AtomicCommandDispatchStore)
              .reconcileOperationalStartReceipt(observed, receipt),
          isFalse,
        );
        expect(
          await (store as AtomicCommandDispatchStore).reviewOperationalStart(
            observed,
            'review_required',
          ),
          isFalse,
        );
        expect(
          (await store.commandByLocalId('account', 'local'))!.status,
          CommandStatus.dispatching,
        );
        expect(
          await store.mapping('account', 'local', EntityKind.session),
          isNull,
        );
      });
    });
  }
}

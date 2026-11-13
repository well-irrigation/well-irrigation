import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/manual_session_entry.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';

import 'manual_session_entry_test.dart' as f;

Map<String, Object?> result(
  CommandEnvelope c,
  String state, {
  String? reason,
}) => {
  'contract': 'manual_session_entry',
  'version': 1,
  'well_id': c.wellId,
  'command_id': c.commandId,
  'entry_type': c.type == CommandType.recordHistoricalSession
      ? 'manual_historical_completed'
      : 'manual_external_active',
  'status': state,
  'reason': ?reason,
};
void main() {
  setUpAll(sqfliteFfiInit);
  for (final disk in [false, true]) {
    group(disk ? 'SQLite follow-up' : 'memory follow-up', () {
      late OutboxStore store;
      Directory? dir;
      Future<void> open() async {
        if (disk) {
          dir ??= await Directory.systemTemp.createTemp('manual_follow_up_');
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

      Future<void> reopen() async {
        if (disk) {
          await store.close();
          await open();
        }
      }

      setUp(open);
      tearDown(() async {
        await store.close();
        if (dir != null) await dir!.delete(recursive: true);
        dir = null;
      });
      Future<ManualSessionEntryFollowUp?> follow(
        CommandEnvelope c, {
        String account = f.account,
        String well = f.well,
      }) => OutboxRepository(store: store).readManualSessionEntryFollowUp(
        accountId: account,
        wellId: well,
        localId: c.localId,
      );
      Future<CommandEnvelope> seed(
        bool completed,
        String state, {
        String? reason,
      }) async {
        final c = await f.enqueue(store, completed);
        if (state == 'never_dispatched') return c;
        final t = f.Transport();
        if (state == 'accepted') {
          t.response = f.accepted(c);
        } else if (const {
          'ambiguous',
          'processing',
          'not_found',
          'unresolved',
        }.contains(state)) {
          t.throwWrite = true;
        } else {
          t.response = result(c, state, reason: reason);
        }
        await SyncEngine(
          store: store,
          transport: t,
          clock: () => f.now,
        ).run(f.account);
        if (const {'processing', 'not_found', 'unresolved'}.contains(state)) {
          t.status = state;
          await SyncEngine(
            store: store,
            transport: t,
            clock: () => f.now,
          ).run(f.account);
        }
        return c;
      }

      for (final completed in [true, false]) {
        final mode = completed ? 'completed' : 'active';
        for (final state in [
          'validation_error',
          'conflict_overlap',
          'conflict_active_resource',
        ]) {
          test('$mode $state eligible with exact facts after reopen', () async {
            final c = await seed(completed, state);
            final before = await store.commandByLocalId(f.account, c.localId);
            await reopen();
            final view = (await follow(c))!;
            expect(view.eligibility.name, 'eligibleTerminalNoSession');
            expect(view.binding.name, 'absent');
            expect(view.facts.payload, c.payload);
            expect(view.facts.type, c.type);
            expect(view.commandId, c.commandId);
            expect(view.localId, c.localId);
            final after = await store.commandByLocalId(f.account, c.localId);
            expect(after!.payload, before!.payload);
            expect(after.serverResponse, before.serverResponse);
            expect(after.status, before.status);
            expect(after.commandId, before.commandId);
            expect(await store.allCommands(f.account), hasLength(1));
          });
        }
        for (final state in [
          'never_dispatched',
          'ambiguous',
          'processing',
          'needs_review',
          'unresolved',
          'not_found',
          'accepted',
        ]) {
          test('$mode $state never permits correction', () async {
            final c = await seed(completed, state);
            await reopen();
            final view = (await follow(c))!;
            expect(view.eligibility.name, isNot('eligibleTerminalNoSession'));
            if (state == 'accepted') {
              expect(view.binding.name, 'present');
              expect(view.canonicalSessionId, f.session);
              expect(view.eligibility.name, 'ineligibleSessionExists');
            }
          });
        }
        test(
          '$mode accepted matching persisted binding remains ineligible after reopen',
          () async {
            final c = await seed(completed, 'accepted');
            await store.putMapping(
              f.account,
              IdMapping(
                localId: c.localId,
                kind: EntityKind.session,
                serverId: f.session,
                resolvedAt: f.now,
              ),
            );
            await reopen();
            final view = (await follow(c))!;
            expect(view.binding.name, 'present');
            expect(view.eligibility.name, 'ineligibleSessionExists');
          },
        );
        test('$mode accepted different binding is contradictory', () async {
          final c = await seed(completed, 'accepted');
          await store.putMapping(
            f.account,
            IdMapping(
              localId: c.localId,
              kind: EntityKind.session,
              serverId: f.pump,
              resolvedAt: f.now,
            ),
          );
          final view = (await follow(c))!;
          expect(view.binding.name, 'contradictory');
          expect(view.eligibility.name, 'ineligibleContradictoryEvidence');
        });
        test('$mode request_changed stays conservative', () async {
          final c = await seed(
            completed,
            'validation_error',
            reason: 'request_changed',
          );
          expect(
            (await follow(c))!.eligibility.name,
            'ineligibleUnsupportedOrUnknown',
          );
        });
        test(
          '$mode terminal result plus binding contradictory after reopen',
          () async {
            final c = await seed(completed, 'validation_error');
            await store.putMapping(
              f.account,
              IdMapping(
                localId: c.localId,
                kind: EntityKind.session,
                serverId: f.session,
                resolvedAt: f.now,
              ),
            );
            await reopen();
            final view = (await follow(c))!;
            expect(view.binding.name, 'contradictory');
            expect(view.eligibility.name, 'ineligibleContradictoryEvidence');
          },
        );
        for (final change in [
          'unknown',
          'malformed',
          'wrong_identity',
          'extra_session_evidence',
        ]) {
          test('$mode $change fails closed', () async {
            final c = await seed(completed, 'validation_error');
            final r = result(c, 'validation_error');
            if (change == 'unknown') r['status'] = 'future_status';
            if (change == 'malformed') r['version'] = '1';
            if (change == 'wrong_identity') r['command_id'] = f.farm;
            if (change == 'extra_session_evidence') r['session_id'] = f.session;
            await store.markNeedsReview(
              f.account,
              c.localId,
              error: 'test_corrupt_evidence',
              attemptedAt: f.now,
              serverResponse: r,
            );
            expect(
              (await follow(c))!.eligibility.name,
              isNot('eligibleTerminalNoSession'),
            );
          });
        }
        test('$mode scope mismatch reveals nothing', () async {
          final c = await seed(completed, 'validation_error');
          expect(await follow(c, account: f.farm), isNull);
          expect(await follow(c, well: f.pump), isNull);
        });
      }
      test(
        'coordinator exposes typed follow-up without sending or mutating',
        () async {
          final c = await seed(true, 'validation_error');
          final coordinator = OfflineSessionCoordinator(store: store);
          try {
            final view = await coordinator.readManualSessionEntryFollowUp(
              accountId: f.account,
              wellId: f.well,
              localId: c.localId,
            );
            expect(
              view!.eligibility,
              ManualEntryCorrectionEligibility.eligibleTerminalNoSession,
            );
            expect(view.facts.reason, f.facts(true).reason);
            expect(view.facts.notes, f.facts(true).notes);
            expect(await store.allCommands(f.account), hasLength(1));
          } finally {
            coordinator.dispose();
          }
        },
      );
      if (disk) {
        test(
          'separate SQLite writer cannot split command and binding snapshot',
          () async {
            final c = await seed(false, 'validation_error');
            final db = await databaseFactoryFfi.openDatabase(
              '${dir!.path}/db',
              options: OpenDatabaseOptions(singleInstance: false),
            );
            final entered = Completer<void>(), release = Completer<void>();
            final write = db.transaction((tx) async {
              await tx.insert(SqliteOutboxStore.mappingsTable, {
                'account_id': f.account,
                'local_id': c.localId,
                'entity_kind': EntityKind.session.storageValue,
                'server_id': f.session,
                'resolved_at': f.now.toIso8601String(),
                'matched_existing': 0,
              });
              await tx.update(
                SqliteOutboxStore.commandsTable,
                {
                  'status': 'confirmed',
                  'server_response': jsonEncode(f.accepted(c)),
                },
                where: 'account_id=? and local_id=?',
                whereArgs: [f.account, c.localId],
              );
              entered.complete();
              await release.future;
            });
            try {
              await entered.future;
              final read = follow(c);
              release.complete();
              await write;
              final view = (await read)!;
              expect(view.outcome, ManualSessionEntryState.accepted);
              expect(view.binding, ManualEntrySessionBinding.present);
              expect(
                view.eligibility,
                ManualEntryCorrectionEligibility.ineligibleSessionExists,
              );
            } finally {
              if (!release.isCompleted) release.complete();
              await write;
              await db.close();
            }
          },
        );
      }
      test('accepted external completed retains ineligible binding', () async {
        final c = await seed(false, 'accepted');
        final completion = await OutboxRepository(store: store).enqueue(
          accountId: f.account,
          wellId: f.well,
          type: CommandType.completeIrrigationSession,
          aggregateLocalId: c.localId,
          occurredAt: f.now,
          payload: {'p_session_id': f.session},
        );
        await store.markConfirmed(
          f.account,
          completion.localId,
          serverResponse: {'status': 'closed'},
          attemptedAt: f.now,
        );
        await reopen();
        final view = (await follow(c))!;
        expect(view.binding.name, 'present');
        expect(view.eligibility.name, 'ineligibleSessionExists');
      });
    });
  }
}

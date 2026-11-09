import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/manual_session_entry.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import 'manual_session_entry_test.dart' as f;

Map<String, Object?> rejection(CommandEnvelope c, String status, {String? reason}) => {
  'contract': 'manual_session_entry', 'version': 1,
  'well_id': c.wellId, 'command_id': c.commandId,
  'entry_type': 'manual_external_active', 'status': status,
  'reason': ?reason,
};

class _Transport extends f.Transport {
  Map<String, Object?>? receiptResult;
  @override
  Future<ManualSessionEntryRead> readManualSessionEntryReceipt(
    ManualSessionEntryReceiptRequest r,
  ) async {
    events.add('read');
    return parseManualSessionEntryReceipt(r, {
      'contract': 'get_manual_session_entry_receipt', 'version': 1,
      ...r.arguments.map((k,v) => MapEntry(k.substring(2),v)),
      'status': status, 'result': receiptResult, 'retry_authorized': false,
    });
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite start guard' : 'memory start guard', () {
      late OutboxStore store;
      Directory? dir;
      Future<void> open() async {
        if (sqlite) {
          dir ??= await Directory.systemTemp.createTemp('manual_entry_guard_');
          store = SqliteOutboxStore(databasePath: '${dir!.path}/db',
            sqfliteFactory: databaseFactoryFfi, singleInstance: false);
        } else {
          store = InMemoryOutboxStore();
        }
        await store.initialize();
      }
      Future<void> reopen() async {
        if (!sqlite) return;
        await store.close();
        await open();
      }
      setUp(open);
      tearDown(() async {
        await store.close();
        if (dir != null) await dir!.delete(recursive: true);
        dir = null;
      });

      Future<CommandEnvelope> attemptStart() async {
        final c = await OutboxRepository(store: store).prepare(
          accountId: f.account, wellId: f.well,
          type: CommandType.startOperationalSession, occurredAt: f.now,
          payload: {'p_well_id': f.well, 'p_pump_id': f.pump,
            'p_farm_id': f.farm, 'p_farmer_well_account_id': f.farmer,
            'p_energy_source': 'solar', 'p_crops': <String>[]});
        await store.insertBundle(accountId: f.account,
          key: humanCommandIntentBundleKey(c.localId),
          value: humanCommandIntentRecord(c), commands: [c]);
        return c;
      }

      Future<CommandEnvelope> seed(String state, {bool viaReceipt = false}) async {
        final c = await f.enqueue(store, false);
        final t = _Transport();
        if (state == 'never_dispatched') return c;
        if (state == 'accepted') {
          t.response = f.accepted(c);
        } else if (state == 'ambiguous' || viaReceipt ||
            const {'processing','not_found','unresolved'}.contains(state)) {
          t.throwWrite = true;
        } else {
          t.response = rejection(c, state,
            reason: state == 'validation_error' ? 'context_invalid'
              : state == 'needs_review' ? 'price_unavailable' : null);
        }
        final engine = SyncEngine(store: store, transport: t, clock: () => f.now);
        await engine.run(f.account);
        if (viaReceipt || const {'processing','not_found','unresolved'}.contains(state)) {
          t.status = state;
          t.receiptResult = const {'processing','not_found','unresolved'}.contains(state)
              ? null : rejection(c,state,
                reason: state == 'validation_error' ? 'context_invalid' : null);
          await engine.run(f.account);
          expect(t.events, ['write','read']);
        }
        return c;
      }

      for (final status in ['validation_error','conflict_overlap','conflict_active_resource']) {
        for (final viaReceipt in [false, true]) {
          test('$status ${viaReceipt ? 'receipt' : 'write'} releases ordinary start without deleting request', () async {
            final manual = await seed(status, viaReceipt: viaReceipt);
            expect((await store.commandByLocalId(f.account,manual.localId))!.status, CommandStatus.review);
            expect(await store.mapping(f.account,manual.localId,EntityKind.session), isNull);
            expect(await ActiveSessionProjector(store: store).activeSessions(f.account,now: f.now), isEmpty);
            await reopen();
            final ordinary = await attemptStart();
            expect(ordinary.type,CommandType.startOperationalSession);
            final retained = (await store.commandByLocalId(f.account,manual.localId))!;
            expect(retained.commandId,manual.commandId);
            expect(retained.payload,manual.payload);
            expect(retained.serverResponse!['status'],status);
            expect((await store.allCommands(f.account)),hasLength(2));
          });
        }
      }

      for (final state in ['never_dispatched','ambiguous','processing','accepted',
        'needs_review','unresolved','not_found']) {
        test('$state remains protected after reopen', () async {
          final manual = await seed(state);
          await reopen();
          await expectLater(attemptStart(),throwsA(isA<ExistingOperationalStart>()));
          expect((await store.allCommands(f.account)),hasLength(1));
          expect((await store.commandByLocalId(f.account,manual.localId))!.commandId,manual.commandId);
        });
      }

      test('changed-payload validation is not proof of no existing session', () async {
        final c = await f.enqueue(store,false);
        final t = _Transport()..response = rejection(c,'validation_error',reason:'request_changed');
        await SyncEngine(store:store,transport:t,clock: () => f.now).run(f.account);
        await reopen();
        await expectLater(attemptStart(),throwsA(isA<ExistingOperationalStart>()));
      });

      test('terminal-looking response cannot override a saved session binding', () async {
        final c = await seed('validation_error');
        // Contradictory local evidence must fail closed, even if the result looks terminal.
        await store.putMapping(f.account,IdMapping(localId:c.localId,kind:EntityKind.session,
          serverId:f.session,resolvedAt:f.now));
        await reopen();
        await expectLater(attemptStart(),throwsA(isA<ExistingOperationalStart>()));
      });

      test('terminal-looking response with session evidence remains protected', () async {
        final c = await f.enqueue(store,false);
        final t = _Transport()..response = {...f.accepted(c),'status':'validation_error'};
        await SyncEngine(store:store,transport:t,clock: () => f.now).run(f.account);
        await expectLater(attemptStart(),throwsA(isA<ExistingOperationalStart>()));
      });

      test('mismatched rejection identity remains ambiguous and protected', () async {
        final c = await f.enqueue(store,false);
        final t = _Transport()..response = {...rejection(c,'validation_error'),'command_id':f.farm};
        await SyncEngine(store:store,transport:t,clock: () => f.now).run(f.account);
        expect((await store.commandByLocalId(f.account,c.localId))!.status,CommandStatus.dispatching);
        await expectLater(attemptStart(),throwsA(isA<ExistingOperationalStart>()));
      });

      for (final state in ['validation_error','ambiguous','accepted']) {
        test('coordinator ordinary start after $state uses real reservation guard', () async {
          final c = await seed(state);
          await reopen();
          final coordinator = OfflineSessionCoordinator(store:store);
          try {
            final action = coordinator.startSession(accountId:f.account,wellId:f.well,
              pumpId:f.pump,farmId:f.farm,farmerAccountId:f.farmer,
              energySource:'solar',startedAt:f.now);
            if (state == 'validation_error') {
              expect((await action).type,CommandType.startOperationalSession);
              expect((await store.commandByLocalId(f.account,c.localId))!.status,CommandStatus.review);
            } else {
              await expectLater(action,throwsA(isA<OperationalStartConflict>()));
            }
          } finally {
            coordinator.dispose();
          }
        });
      }

      test('completed historical entry never participates in active start guard', () async {
        final c = await f.enqueue(store,true);
        final t = _Transport()..response = f.accepted(c);
        await SyncEngine(store:store,transport:t,clock: () => f.now).run(f.account);
        expect(c.type.produces,isNull);
        await attemptStart();
      });

      test('pending completion is not canonical closure; confirmed completion releases guard', () async {
        final c = await seed('accepted');
        final coordinator = OfflineSessionCoordinator(store:store);
        final completion = await coordinator.completeSession(accountId:f.account,
          sessionLocalId:c.localId,completedAt:f.end);
        coordinator.dispose();
        await expectLater(attemptStart(),throwsA(isA<ExistingOperationalStart>()));
        final receipt = <String,Object?>{
          'session_id':f.session,'status':'closed','session_charge_id':f.farm,
          'ended_at':f.end.toIso8601String(),'segments':<Object?>[],
          'actual_seconds':3600,'billable_seconds':3600,
          'weighted_price_per_hour_minor':500,'amount_minor':500,
        };
        final t = _Transport()..response = DispatchAccepted(response:receipt,entityId:f.farm);
        await SyncEngine(store:store,transport:t,clock: () => f.now).run(f.account);
        expect((await store.commandByLocalId(f.account,completion.localId))!.status,CommandStatus.confirmed);
        await reopen();
        await attemptStart();
      });

      for (final type in [CommandType.startOperationalSession,CommandType.startIrrigationSession,
        CommandType.startAdhocSession,CommandType.startBookingSession]) {
        test('existing ${type.name} pending blocker is unchanged', () async {
          final c = await OutboxRepository(store:store).prepare(accountId:f.account,
            wellId:f.well,type:type,occurredAt:f.now,payload:{type.scopeArgument:f.well});
          await store.insert(c);
          await expectLater(attemptStart(),throwsA(isA<ExistingOperationalStart>()));
        });
      }
    });
  }
}

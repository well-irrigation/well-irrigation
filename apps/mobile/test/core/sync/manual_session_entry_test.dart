import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/manual_session_entry.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

const account = '11111111-1111-4111-8111-111111111111';
const well = '22222222-2222-4222-8222-222222222222';
const session = '33333333-3333-4333-8333-333333333333';
const farm = '44444444-4444-4444-8444-444444444444';
const pump = '55555555-5555-4555-8555-555555555555';
const farmer = '66666666-6666-4666-8666-666666666666';
final start = DateTime.utc(2001, 1, 1, 5);
final end = start.add(const Duration(hours: 1));
final now = DateTime.utc(2026, 11, 9);

ManualSessionEntryFacts facts(bool completed) => ManualSessionEntryFacts(
  wellId: well, farmerWellAccountId: farmer, farmId: farm, pumpId: pump,
  startedAt: start, endedAt: completed ? end : null, energySource: 'solar',
  reason: 'إدخال جلسة فعلية', notes: 'تفاصيل محفوظة',
);

Map<String, Object?> accepted(CommandEnvelope c) => {
  'contract': 'manual_session_entry', 'version': 1, 'status': 'accepted',
  'tenant_id': account, 'well_id': well, 'command_id': c.commandId,
  'entry_type': c.type == CommandType.recordHistoricalSession
      ? 'manual_historical_completed' : 'manual_external_active',
  'session_id': session, 'started_at': start.toIso8601String(),
  'ended_at': c.type == CommandType.recordHistoricalSession ? end.toIso8601String() : null,
  'session_charge_id': c.type == CommandType.recordHistoricalSession ? farm : null,
  'amount_minor': c.type == CommandType.recordHistoricalSession ? 500 : null,
};

class Transport implements CommandTransport, ManualSessionEntryReceiptTransport {
  final events = <String>[];
  final writes = <DispatchRequest>[];
  Object? response;
  String status = 'accepted';
  bool failRead = false;
  bool throwWrite = false;
  Future<void>? writeGate;
  final entered = Completer<void>();
  @override
  Future<DispatchResult> dispatch(DispatchRequest r) async {
    events.add('write');
    writes.add(r);
    if (!entered.isCompleted) entered.complete();
    await writeGate;
    if (throwWrite) throw const SocketException('lost');
    return response is DispatchResult ? response as DispatchResult
      : DispatchAccepted(response: response as Map<String, Object?>, entityId: null);
  }
  @override
  Future<ManualSessionEntryRead> readManualSessionEntryReceipt(ManualSessionEntryReceiptRequest r) async {
    events.add('read');
    if (failRead) return const ManualSessionEntryReadFailure(ManualSessionEntryReadFailureKind.network);
    return parseManualSessionEntryReceipt(r, {
      'contract': 'get_manual_session_entry_receipt', 'version': 1,
      'well_id': r.command.wellId, 'command_id': r.command.commandId,
      'retry_authorized': false, 'status': status,
      'result': status == 'accepted' ? accepted(r.command)
          : const {'conflict_overlap','conflict_active_resource','validation_error','needs_review'}.contains(status)
              ? {...accepted(r.command), 'status': status} : null,
    });
  }
}

Future<CommandEnvelope> enqueue(OutboxStore s, bool completed) async {
  final repo = OutboxRepository(store: s, clock: () => now);
  final c = await repo.prepareManualSessionEntry(accountId: account, facts: facts(completed));
  return repo.saveManualSessionEntry(c);
}

void main() {
  setUpAll(sqfliteFfiInit);
  test('manual entry has distinct durable command types and public RPCs', () {
    final types = CommandType.values.where((t) => const {
      'recordHistoricalSession', 'adoptExternalSession',
    }.contains(t.name)).toList();
    expect(types.map((t) => t.rpcName), unorderedEquals([
      'record_historical_session', 'adopt_external_session',
    ]));
  });

  for (final completed in [true, false]) {
    group(completed ? 'completed' : 'active', () {
      test('one submission persists idempotently without booking authority', () async {
        final store = InMemoryOutboxStore();
        final repo = OutboxRepository(store: store, clock: () => now);
        final c = await repo.prepareManualSessionEntry(accountId: account, facts: facts(completed));
        final saved = await Future.wait([repo.saveManualSessionEntry(c), repo.saveManualSessionEntry(c)]);
        expect(saved.map((c) => c.commandId).toSet(), {c.commandId});
        expect((await store.allCommands(account)).length, 1);
        expect(c.payload.keys, unorderedEquals(['p_well_id', 'p_request']));
        expect((c.payload['p_request'] as Map).keys, unorderedEquals([
          'version','farmer_well_account_id','farm_id','pump_id','started_at',
          if (completed) 'ended_at','energy_source','reason','notes',
        ]));
        expect(() => (c.payload['p_request'] as Map)['reason'] = 'changed', throwsUnsupportedError);
      });
      test('offline queue sends once and accepted result is canonical', () async {
        final s = InMemoryOutboxStore();
        final c = await enqueue(s, completed);
        expect((await s.commandByLocalId(account, c.localId))!.status, CommandStatus.pending);
        final t = Transport()..response = accepted(c);
        final engine = SyncEngine(store: s, transport: t, clock: () => now);
        await engine.run(account);
        await engine.run(account);
        expect(t.events, ['write']);
        expect(t.writes.single.arguments, {...c.payload, 'p_command_id': c.commandId});
        expect((await s.commandByLocalId(account, c.localId))!.status, CommandStatus.confirmed);
        final projected = await ActiveSessionProjector(store: s).activeSessions(account, now: now);
        if (completed) {
          expect(projected, isEmpty);
        } else {
          expect(projected.single.serverSessionId, session);
          expect(projected.single.startedAt, start);
          expect(projected.single.pumpId, pump);
          expect(projected.single.segments.single.startedAt, start);
          expect(projected.single.bookingId, isNull);
        }
      });
      test('ambiguous write and retryable server error both recover read first', () async {
        for (final failure in [
          const DispatchFailed(disposition: FailureDisposition.retry, message: 'lost'),
          const DispatchFailed(disposition: FailureDisposition.retry, code: '40001', message: 'retry'),
          const DispatchFailed(disposition: FailureDisposition.review, message: 'decode failed'),
        ]) {
          final s = InMemoryOutboxStore();
          final c = await enqueue(s, completed);
          final t = Transport()..response = failure;
          final engine = SyncEngine(store: s, transport: t, clock: () => now);
          await engine.run(account);
          expect((await s.commandByLocalId(account, c.localId))!.status, CommandStatus.dispatching);
          await engine.run(account);
          expect(t.events, ['write','read']);
          expect((await s.commandByLocalId(account, c.localId))!.status, CommandStatus.confirmed);
        }
      });
      for (final state in ['processing','not_found','unresolved','conflict_overlap','conflict_active_resource','validation_error','needs_review']) {
        test('$state cannot authorize another write', () async {
          final s = InMemoryOutboxStore();
          final c = await enqueue(s, completed);
          final t = Transport()..throwWrite = true..status = state;
          final engine = SyncEngine(store: s, transport: t, clock: () => now);
          await engine.run(account);
          await engine.run(account);
          await engine.run(account);
          expect(t.writes.length, 1);
          final row = (await s.commandByLocalId(account, c.localId))!;
          expect(row.payload, c.payload);
          expect(row.status, const {'processing','not_found','unresolved'}.contains(state)
              ? CommandStatus.dispatching : CommandStatus.review);
          expect((await ActiveSessionProjector(store: s).activeSessions(account, now: now)), isEmpty);
        });
      }
      test('receipt network failure keeps durable ambiguity', () async {
        final s = InMemoryOutboxStore();
        final c = await enqueue(s, completed);
        final t = Transport()..throwWrite = true..failRead = true;
        final engine = SyncEngine(store: s, transport: t, clock: () => now);
        await engine.run(account);
        await engine.run(account);
        expect(t.events, ['write','read']);
        expect((await s.commandByLocalId(account,c.localId))!.status, CommandStatus.dispatching);
      });
      test('SQLite reopen preserves intent and attempts receipt before write', () async {
        final dir = await Directory.systemTemp.createTemp('manual_entry_');
        final path = '${dir.path}/outbox.db';
        var s = SqliteOutboxStore(databasePath: path, sqfliteFactory: databaseFactoryFfi);
        await s.initialize();
        final c = await enqueue(s, completed);
        final t = Transport()..throwWrite = true;
        await SyncEngine(store: s, transport: t,clock: () => now).run(account);
        await s.close();
        s = SqliteOutboxStore(databasePath: path,sqfliteFactory: databaseFactoryFfi);
        await s.initialize();
        try {
          final restored = (await s.commandByLocalId(account,c.localId))!;
          expect(restored.commandId,c.commandId);
          expect(restored.payload,c.payload);
          expect((restored.payload['p_request'] as Map)['notes'], 'تفاصيل محفوظة');
          expect(() => (restored.payload['p_request'] as Map)['reason'] = 'changed',throwsUnsupportedError);
          final observation = await OutboxRepository(store:s).observeManualSessionEntry(
            accountId:account,wellId:well,localId:c.localId);
          expect(observation!.isRecovering,isTrue);
          expect(observation.command.commandId,c.commandId);
          await SyncEngine(store: s, transport: t,clock: () => now.add(const Duration(days: 2))).run(account);
          expect(t.events,['write','read']);
          expect((await s.commandByLocalId(account,c.localId))!.status,CommandStatus.confirmed);
          expect(await s.allCommands('another-account'),isEmpty);
        } finally {
          await s.close();
          await dir.delete(recursive: true);
        }
      });
      test('invalid accepted proof is never confirmed', () async {
        for (final field in ['command_id','well_id','entry_type','session_id','started_at','ended_at','amount_minor']) {
          final s = InMemoryOutboxStore();
          final c = await enqueue(s,completed);
          final t = Transport()..response = {...accepted(c),field: 'wrong'};
          await SyncEngine(store: s, transport: t,clock: () => now).run(account);
          expect((await s.commandByLocalId(account,c.localId))!.status,CommandStatus.dispatching,reason:field);
        }
      });
      test('direct business result is persisted and inspectable without technical errors', () async {
        for (final state in ['conflict_overlap','conflict_active_resource','validation_error','needs_review']) {
          final s = InMemoryOutboxStore();
          final c = await enqueue(s,completed);
          final t = Transport()..response = {...accepted(c),'status': state};
          await SyncEngine(store:s,transport:t,clock: () => now).run(account);
          final outcome = await OutboxRepository(store:s).readManualSessionEntry(
            accountId: account, wellId:well, localId:c.localId);
          expect((outcome as ManualSessionEntryOutcome).state,
            ManualSessionEntryState.fromWire(state));
          expect(outcome.sessionId,isNull);
          expect(await OutboxRepository(store:s).readManualSessionEntry(
            accountId: account,wellId:farm,localId:c.localId),isNull);
        }
      });
      test('receipt identity and retry authorization are independently enforced', () async {
        final c = await enqueue(InMemoryOutboxStore(),completed);
        final r = ManualSessionEntryReceiptRequest.fromCommand(c)!;
        final envelope = <String,Object?>{
          'contract':'get_manual_session_entry_receipt','version':1,
          'well_id':well,'command_id':c.commandId,'retry_authorized':false,
          'status':'accepted','result':accepted(c),
        };
        for (final field in ['contract','version','well_id','command_id','retry_authorized','status','result']) {
          expect(parseManualSessionEntryReceipt(r,{...envelope,field:'wrong'}),
            isA<ManualSessionEntryReadFailure>(),reason:field);
        }
      });
    });
  }

  test('accepted active entry joins normal pause resume energy and completion commands', () async {
    final s = InMemoryOutboxStore();
    final c = await enqueue(s,false);
    final t = Transport()..response = accepted(c);
    await SyncEngine(store:s,transport:t,clock: () => now).run(account);
    final coordinator = OfflineSessionCoordinator(store:s);
    await coordinator.initialize();
    expect((await coordinator.freshProjectActiveSession(accountId:account,wellId:well))!.serverSessionId,session);
    final pause = await coordinator.pauseSession(accountId:account,sessionLocalId:c.localId,
      reason:'operator_pause',pausedAt:end);
    expect(coordinator.currentActiveSession!.businessState,SessionBusinessState.paused);
    final resume = await coordinator.resumeSession(accountId:account,sessionLocalId:c.localId,
      resumedAt:end.add(const Duration(minutes:5)));
    final energy = await coordinator.changeEnergySource(accountId:account,sessionLocalId:c.localId,
      newEnergySource:'well_diesel',changedAt:end.add(const Duration(minutes:6)));
    final completion = await coordinator.completeSession(accountId:account,sessionLocalId:c.localId,
      completedAt:end.add(const Duration(minutes:10)));
    expect([pause,resume,energy,completion].map((c) => c.aggregateLocalId).toSet(),{c.localId});
    expect([pause,resume,energy,completion].map((c) => (c.payload['p_session_id'] as Map)[r'$ref']).toSet(),{c.localId});
    expect((await s.sessionSnapshot(accountId:account,wellId:well,localSessionId:c.localId))?.commands,
      hasLength(5));
    coordinator.dispose();
  });

  test('completed submission never changes the selected active well', () async {
    final s = InMemoryOutboxStore();
    final active = await enqueue(s,false);
    final t = Transport()..response = accepted(active);
    await SyncEngine(store:s,transport:t,clock: () => now).run(account);
    final coordinator = OfflineSessionCoordinator(store:s);
    await coordinator.initialize();
    await coordinator.freshProjectActiveSession(accountId:account,wellId:well);
    final intent = await coordinator.prepareManualSessionEntry(accountId:account,
      facts:ManualSessionEntryFacts(wellId:farm,farmerWellAccountId:farmer,
        farmId:farm,pumpId:pump,startedAt:start,endedAt:end,energySource:'solar',reason:'إضافة'));
    await coordinator.submitManualSessionEntry(intent);
    expect(coordinator.currentActiveSession!.localId,active.localId);
    expect((await s.allCommands(account)).length,2);
    coordinator.dispose();
  });

  test('simultaneous engines cannot dispatch a second write', () async {
    final s = InMemoryOutboxStore();
    final c = await enqueue(s,false);
    final gate = Completer<void>();
    final t = Transport()..response = accepted(c)..writeGate = gate.future..status = 'processing';
    final first = SyncEngine(store:s,transport:t,clock: () => now).run(account);
    await t.entered.future;
    await SyncEngine(store:s,transport:t,clock: () => now).run(account);
    expect(t.events,['write','read']);
    gate.complete();
    await first;
    expect(t.writes,hasLength(1));
    expect((await s.commandByLocalId(account,c.localId))!.status,CommandStatus.confirmed);
  });

  test('changed facts cannot replace an already saved submission', () async {
    final s = InMemoryOutboxStore();
    final c = await enqueue(s,true);
    final changed = CommandEnvelope(localId:c.localId,commandId:c.commandId,
      accountId:c.accountId,wellId:c.wellId,sequence:c.sequence,type:c.type,
      occurredAt:c.occurredAt,createdLocalAt:c.createdLocalAt,
      payload:{...c.payload,'p_request':{...(c.payload['p_request'] as Map).cast<String,Object?>(),'notes':'changed'}});
    await expectLater(OutboxRepository(store:s).saveManualSessionEntry(changed),throwsStateError);
    expect((await s.commandByLocalId(account,c.localId))!.payload,c.payload);
  });

  for (final forbidden in ['booking_id','source_booking_id','actor_id','amount_minor','shift_id','collector_id']) {
    test('raw $forbidden cannot become client authority', () async {
      final s = InMemoryOutboxStore();
      final c = await OutboxRepository(store:s,clock: () => now)
        .prepareManualSessionEntry(accountId:account,facts:facts(true));
      final bad = CommandEnvelope(localId:c.localId,commandId:c.commandId,
        accountId:c.accountId,wellId:c.wellId,sequence:c.sequence,type:c.type,
        occurredAt:c.occurredAt,createdLocalAt:c.createdLocalAt,
        payload:{...c.payload,'p_request':{...(c.payload['p_request'] as Map).cast<String,Object?>(),forbidden:farmer}});
      expect(ManualSessionEntryReceiptRequest.fromCommand(bad),isNull);
      await s.insert(bad);
      final t = Transport();
      await SyncEngine(store:s,transport:t,clock: () => now).run(account);
      expect(t.events,isEmpty);
      expect((await s.commandByLocalId(account,c.localId))!.status,CommandStatus.review);
    });
  }

  test('future entry cannot be durably queued', () async {
    final s = InMemoryOutboxStore();
    await expectLater(OutboxRepository(store:s,clock: () => now).prepareManualSessionEntry(
      accountId:account,facts:ManualSessionEntryFacts(wellId:well,farmerWellAccountId:farmer,
        farmId:farm,pumpId:pump,startedAt:now.add(const Duration(days:1)),energySource:'solar',reason:'إضافة')),
      throwsArgumentError);
    expect(await s.allCommands(account),isEmpty);
  });

  test('proven pre-network rejection remains queued until a real first dispatch', () async {
    final s = InMemoryOutboxStore();
    final c = await enqueue(s,false);
    final t = Transport()..response = const DispatchFailed(
      disposition:FailureDisposition.retry,message:'no authenticated session',
      executionNotStarted:true);
    await SyncEngine(store:s,transport:t,clock: () => now).run(account);
    expect((await s.commandByLocalId(account,c.localId))!.status,CommandStatus.pending);
    t.response = accepted(c);
    await SyncEngine(store:s,transport:t,clock: () => now).run(account);
    expect(t.events,['write','write']); // first call never left the transport preflight
    expect(t.writes.map((r) => r.commandId).toSet(),{c.commandId});
    expect((await s.commandByLocalId(account,c.localId))!.status,CommandStatus.confirmed);
  });

  test('coordinator can read an accepted entry immediately after reopening SQLite', () async {
    final dir = await Directory.systemTemp.createTemp('manual_entry_read_');
    final path = '${dir.path}/outbox.db';
    var s = SqliteOutboxStore(databasePath:path,sqfliteFactory:databaseFactoryFfi);
    await s.initialize();
    final c = await enqueue(s,true);
    final t = Transport()..response = accepted(c);
    await SyncEngine(store:s,transport:t,clock: () => now).run(account);
    await s.close();
    s = SqliteOutboxStore(databasePath:path,sqfliteFactory:databaseFactoryFfi);
    final coordinator = OfflineSessionCoordinator(store:s);
    try {
      final read = await coordinator.readManualSessionEntry(accountId:account,wellId:well,localId:c.localId);
      expect((read as ManualSessionEntryOutcome).sessionId,session);
      expect(t.events,['write']);
    } finally {
      coordinator.dispose();
      await s.close();
      await dir.delete(recursive:true);
    }
  });

  test('offline queued request remains inspectable after coordinator reopen', () async {
    final dir = await Directory.systemTemp.createTemp('manual_entry_queued_');
    final path = '${dir.path}/outbox.db';
    var s = SqliteOutboxStore(databasePath:path,sqfliteFactory:databaseFactoryFfi);
    await s.initialize();
    final c = await enqueue(s,false);
    await s.close();
    s = SqliteOutboxStore(databasePath:path,sqfliteFactory:databaseFactoryFfi);
    final coordinator = OfflineSessionCoordinator(store:s);
    try {
      final view = await coordinator.observeManualSessionEntry(accountId:account,wellId:well,localId:c.localId);
      expect(view!.isQueued,isTrue);
      expect(view.isRecovering,isFalse);
      expect(view.outcome,isNull);
      expect(view.command.payload,c.payload);
      expect(view.command.commandId,c.commandId);
      expect(await coordinator.observeManualSessionEntry(accountId:farmer,wellId:well,localId:c.localId),isNull);
    } finally {
      coordinator.dispose();
      await s.close();
      await dir.delete(recursive:true);
    }
  });

  test('recovery never replaces a previously bound canonical session identity', () async {
    final s = InMemoryOutboxStore();
    final c = await enqueue(s,false);
    await s.claim(account,c.localId,attemptedAt:now);
    await s.putMapping(account,IdMapping(localId:c.localId,kind:EntityKind.session,
      serverId:farm,resolvedAt:now));
    final t = Transport();
    await SyncEngine(store:s,transport:t,clock: () => now).run(account);
    expect(t.events,['read']);
    expect((await s.mapping(account,c.localId,EntityKind.session))!.serverId,farm);
    expect((await s.commandByLocalId(account,c.localId))!.status,CommandStatus.review);
    expect(await ActiveSessionProjector(store:s).activeSessions(account,now:now),isEmpty);
  });
}

import 'dart:io';
import 'package:well_irrigation_mobile/core/sync/background_sync_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/operational_start_receipt.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';

import 'fake_command_transport.dart';
import 'sync_test_support.dart';

class RecoveryTransport extends FakeCommandTransport
    implements OperationalStartReceiptTransport {
  int reads = 0;
  bool initialMalformed = false;
  Object? initialId;
  @override
  Future<DispatchResult> dispatch(DispatchRequest request) async {
    if (!initialMalformed) return super.dispatch(request);
    requests.add(request);
    return normalizeAcceptedResponse(request.type, initialId);
  }

  OperationalStartReceiptFailureKind? failure;
  OperationalStartReceiptState state = OperationalStartReceiptState.accepted;
  @override
  Future<OperationalStartReceiptRead> readOperationalStartReceipt(
    OperationalStartReceiptRequest request,
  ) async {
    reads++;
    if (failure != null) return OperationalStartReceiptFailure(failure!);
    return OperationalStartReceiptResponse(
      state,
      state == OperationalStartReceiptState.accepted
          ? {'id': 'server-session', 'occurrence_command_id': request.commandId}
          : null,
    );
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  test('SQLite restart recovers original command without redispatch', () async {
    final dir = await Directory.systemTemp.createTemp('r6ab_restart_');
    SqliteOutboxStore open() => SqliteOutboxStore(
      databasePath: '${dir.path}/db',
      sqfliteFactory: databaseFactoryFfi,
      singleInstance: false,
    );
    var store = open();
    try {
      final repository = OutboxRepository(
        store: store,
        idGenerator: SequentialIdGenerator(),
        clock: () => DateTime.utc(2026),
      );
      await repository.initialize();
      final command = await repository.enqueue(
        accountId: 'a',
        wellId: 'w',
        type: CommandType.startOperationalSession,
        payload: {'p_well_id': 'w'},
        occurredAt: DateTime.utc(2026),
      );
      await store.insertLocalRecordOnce(
        accountId: 'a',
        key: humanCommandIntentBundleKey(command.localId),
        value: humanCommandIntentRecord(command),
      );
      final transport = RecoveryTransport()
        ..swallowAckOnce.add('start_operational_session');
      await SyncEngine(
        store: store,
        transport: transport,
        clock: () => DateTime.utc(2026),
      ).run('a');
      expect(transport.requests.length, 1);
      await store.close();
      store = open();
      await store.initialize();
      expect(
        (await store.commandByLocalId('a', command.localId))!.commandId,
        command.commandId,
      );
      await SyncEngine(
        store: store,
        transport: transport,
        clock: () => DateTime.utc(2026),
      ).run('a');
      expect(transport.requests.length, 1);
      expect(transport.reads, 1);
      expect(
        (await store.commandByLocalId('a', command.localId))!.status,
        CommandStatus.confirmed,
      );
      expect(
        (await store.mapping(
          'a',
          command.localId,
          EntityKind.session,
        ))!.serverId,
        'server-session',
      );
    } finally {
      await store.close();
      await dir.delete(recursive: true);
    }
  });
  test(
    'conflicting mapping remains held without repeated reads or dispatch',
    () async {
      final store = InMemoryOutboxStore();
      final repo = OutboxRepository(
        store: store,
        idGenerator: SequentialIdGenerator(),
        clock: () => DateTime.utc(2026),
      );
      await repo.initialize();
      final c = await repo.enqueue(
        accountId: 'a',
        wellId: 'w',
        type: CommandType.startOperationalSession,
        payload: {'p_well_id': 'w'},
        occurredAt: DateTime.utc(2026),
      );
      await store.insertLocalRecordOnce(
        accountId: 'a',
        key: humanCommandIntentBundleKey(c.localId),
        value: humanCommandIntentRecord(c),
      );
      final transport = RecoveryTransport()
        ..swallowAckOnce.add('start_operational_session');
      final engine = SyncEngine(
        store: store,
        transport: transport,
        clock: () => DateTime.utc(2026),
      );
      await engine.run('a');
      await store.putMapping(
        'a',
        IdMapping(
          localId: c.localId,
          kind: EntityKind.session,
          serverId: 'other',
          resolvedAt: DateTime.utc(2026),
        ),
      );
      await engine.run('a');
      await engine.run('a');
      expect(transport.requests.length, 1);
      expect(transport.reads, 1);
      expect(
        (await store.mapping('a', c.localId, EntityKind.session))!.serverId,
        'other',
      );
      expect(
        (await store.commandByLocalId('a', c.localId))!.status,
        isNot(CommandStatus.confirmed),
      );
      await store.close();
    },
  );
  test('fresh operational start dispatches once and maps session', () async {
    final store = InMemoryOutboxStore();
    final repo = OutboxRepository(
      store: store,
      idGenerator: SequentialIdGenerator(),
      clock: () => DateTime.utc(2026),
    );
    await repo.initialize();
    final c = await repo.enqueue(
      accountId: 'a',
      wellId: 'w',
      type: CommandType.startOperationalSession,
      payload: {'p_well_id': 'w'},
      occurredAt: DateTime.utc(2026),
    );
    await store.insertLocalRecordOnce(
      accountId: 'a',
      key: humanCommandIntentBundleKey(c.localId),
      value: humanCommandIntentRecord(c),
    );
    final transport = RecoveryTransport();
    await SyncEngine(
      store: store,
      transport: transport,
      clock: () => DateTime.utc(2026),
    ).run('a');
    expect(transport.requests.length, 1);
    expect(transport.reads, 0);
    expect(
      (await store.commandByLocalId('a', c.localId))!.status,
      CommandStatus.confirmed,
    );
    expect(await store.mapping('a', c.localId, EntityKind.session), isNotNull);
    await store.close();
  });
  for (final raw in [null, '', '   ', 42, <String,Object?>{}]) {
    test('malformed initial $raw recovers by receipt without redispatch', () async {
      final store = InMemoryOutboxStore();
      final repo = OutboxRepository(store:store,idGenerator:SequentialIdGenerator(),clock:()=>DateTime.utc(2026));
      await repo.initialize();
      final c = await repo.enqueue(accountId:'a',wellId:'w',type:CommandType.startOperationalSession,payload:{'p_well_id':'w'},occurredAt:DateTime.utc(2026));
      await store.insertLocalRecordOnce(accountId:'a',key:humanCommandIntentBundleKey(c.localId),value:humanCommandIntentRecord(c));
      final transport = RecoveryTransport()..initialMalformed = true..initialId = raw;
      final engine = SyncEngine(store:store,transport:transport,clock:()=>DateTime.utc(2026));
      await engine.run('a');
      expect((await store.commandByLocalId('a',c.localId))!.status,isNot(CommandStatus.confirmed));
      expect(await store.mapping('a',c.localId,EntityKind.session),isNull);
      transport.state = OperationalStartReceiptState.processing;
      for(var i=0;i<2;i++) {
        final report = await engine.run('a');
        expect(report.awaitsHumanDecision,isFalse);
        expect(report.canRetryWithoutHelp,isTrue);
      }
      transport.state = OperationalStartReceiptState.accepted;
      await engine.run('a');
      expect(transport.requests,hasLength(1)); expect(transport.reads,3);
      expect((await store.commandByLocalId('a',c.localId))!.commandId,c.commandId);
      expect((await store.mapping('a',c.localId,EntityKind.session))!.serverId,'server-session');
      await store.close();
    });
  }
  for (final kind in OperationalStartReceiptFailureKind.values) {
    test('receipt failure $kind never redispatches', () async {
      final store = InMemoryOutboxStore();
      final repo = OutboxRepository(
        store: store,
        idGenerator: SequentialIdGenerator(),
        clock: () => DateTime.utc(2026),
      );
      await repo.initialize();
      final c = await repo.enqueue(
        accountId: 'a',
        wellId: 'w',
        type: CommandType.startOperationalSession,
        payload: {'p_well_id': 'w'},
        occurredAt: DateTime.utc(2026),
      );
      await store.insertLocalRecordOnce(
        accountId: 'a',
        key: humanCommandIntentBundleKey(c.localId),
        value: humanCommandIntentRecord(c),
      );
      final transport = RecoveryTransport()
        ..swallowAckOnce.add('start_operational_session')
        ..failure = kind;
      final engine = SyncEngine(
        store: store,
        transport: transport,
        clock: () => DateTime.utc(2026),
      );
      await engine.run('a');
      final report = await engine.run('a');
      expect(transport.requests.length, 1);
      expect(transport.reads, 1);
      final row = (await store.commandByLocalId('a', c.localId))!;
      if (kind == OperationalStartReceiptFailureKind.forbidden ||
          kind == OperationalStartReceiptFailureKind.malformed) {
        expect(row.status, CommandStatus.review);
        expect(report.awaitsHumanDecision,isTrue);
        expect(const BackgroundSyncPolicy().decide(report:report).outcome,BackgroundSyncOutcome.awaitsHumanDecision);
      } else {
        expect(row.status, isNot(CommandStatus.review));
        expect(report.awaitsHumanDecision,isFalse);
        expect(const BackgroundSyncPolicy().decide(report:report).outcome,BackgroundSyncOutcome.retryLater);
      }
      expect(await store.mapping('a', c.localId, EntityKind.session), isNull);
      await store.close();
    });
  }
  for (final state in OperationalStartReceiptState.values) {
    test('lost response $state never redispatches', () async {
      final store = InMemoryOutboxStore();
      final repository = OutboxRepository(
        store: store,
        idGenerator: SequentialIdGenerator(),
        clock: () => DateTime.utc(2026),
      );
      await repository.initialize();
      final command = await repository.enqueue(
        accountId: 'a',
        wellId: 'w',
        type: CommandType.startOperationalSession,
        payload: {'p_well_id': 'w'},
        occurredAt: DateTime.utc(2026),
      );
      await store.insertLocalRecordOnce(
        accountId: 'a',
        key: humanCommandIntentBundleKey(command.localId),
        value: humanCommandIntentRecord(command),
      );
      final transport = RecoveryTransport()
        ..swallowAckOnce.add('start_operational_session')
        ..state = state;
      final engine = SyncEngine(
        store: store,
        transport: transport,
        clock: () => DateTime.utc(2026),
      );
      await engine.run('a');
      expect(transport.requests.length, 1);
      await engine.run('a');
      expect(transport.requests.length, 1);
      expect(transport.reads, 1);
      final row = (await store.commandByLocalId('a', command.localId))!;
      expect(row.commandId, command.commandId);
      if (state == OperationalStartReceiptState.accepted) {
        expect(row.status, CommandStatus.confirmed);
        expect(
          (await store.mapping(
            'a',
            command.localId,
            EntityKind.session,
          ))!.serverId,
          'server-session',
        );
      } else if (state != OperationalStartReceiptState.processing) {
        expect(row.status, CommandStatus.review);
        expect(
          await store.mapping('a', command.localId, EntityKind.session),
          isNull,
        );
      } else {
        expect(row.status, isNot(CommandStatus.confirmed));
        expect(
          await store.mapping('a', command.localId, EntityKind.session),
          isNull,
        );
      }
      await engine.run('a');
      expect(transport.requests.length, 1);
      if (state != OperationalStartReceiptState.processing) {
        expect(transport.reads, 1);
      }
      await store.close();
    });
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/operational_start_recovery.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/manual_stop_request_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/start_recovery_policy.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';
import 'package:well_irrigation_mobile/core/sync/operational_start_receipt.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';

import '../sync/fake_command_transport.dart';
import 'operational_start_guided_recovery_test.dart';

const historicalRoot = 'aaaaaaaa-1111-4111-8111-111111111111';
const historicalCommand = 'bbbbbbbb-2222-4222-8222-222222222222';

class HistoricalReceiptTransport extends FakeCommandTransport
    implements OperationalStartReceiptTransport {
  int reads = 0;
  final arguments = <Map<String, Object?>>[];
  String state = 'accepted';
  String type = 'start_irrigation_session',
      well = 'well',
      command = historicalCommand,
      server = 'server';
  bool network = false;
  bool unbound = false;
  @override
  Future<OperationalStartReceiptRead> readOperationalStartReceipt(
    OperationalStartReceiptRequest request,
  ) async {
    reads++;
    arguments.add(request.arguments);
    if (network) {
      return const OperationalStartReceiptFailure(
        OperationalStartReceiptFailureKind.network,
      );
    }
    final receipt = state == 'accepted'
        ? <String, Object?>{'id': server}
        : state == 'rejected'
        ? <String, Object?>{'status': 'rejected', 'reason': 'denied'}
        : null;
    if (unbound) {
      return OperationalStartReceiptResponse(
        OperationalStartReceiptState.accepted,
        receipt,
      );
    }
    return parseOperationalStartReceipt(request, {
      'contract': 'get_operational_start_receipt',
      'version': 1,
      'well_id': well,
      'command_id': command,
      'command_type': type,
      'status': state,
      'retry_authorized': false,
      'receipt': receipt,
    });
  }
}

class CorrectedHistoricalRepository extends GuidedRepository {
  @override
  Future<SessionDetailData> fetchSessionDetail(String id) async {
    final at = startTime.add(const Duration(minutes: 1));
    return SessionDetailData(
      canReadSessionCorrections: false,
      canCorrectSession: false,
      session: SessionHistoryItem(
        id: 'server',
        wellId: 'well',
        farmerName: 'المزارع',
        farmerCode: 'F',
        farmerAccountId: 'farmer',
        farmName: 'الأرض',
        pumpName: 'المضخة',
        operatorName: 'المشغل',
        startedAt: at,
        status: 'open',
        operationalRevision: 1,
        energySourceCode: 'solar',
      ),
      segments: [
        SessionSegmentItem(
          sequenceNumber: 1,
          segmentType: 'solar_run',
          isStop: false,
          isBillable: true,
          startedAt: at,
          energySourceCode: 'solar',
        ),
      ],
    );
  }
}

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqliteOutboxStore store;
  late CommandEnvelope root;
  late HistoricalReceiptTransport transport;
  late GuidedRepository repository;
  late OperationalStartRecovery recovery;
  String? account = 'account';
  SqliteOutboxStore open() => SqliteOutboxStore(
    databasePath: '${dir.path}/old.db',
    singleInstance: false,
    sqfliteFactory: databaseFactoryFfi,
  );
  OperationalStartRecovery service() => OperationalStartRecovery(
    store: store,
    transport: transport,
    repository: repository,
    currentAccountId: () => account,
  );
  Future<OperationalStartRecoveryObservation> check() => recovery.check(
    accountId: 'account',
    wellId: 'well',
    sessionLocalId: historicalRoot,
  );
  Future<void> reopen() async {
    await store.close();
    store = open();
    await store.initialize();
    recovery = service();
  }

  Future<void> editRoot(Map<String, Object?> values) async {
    await store.close();
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/old.db');
    await db.update(
      'outbox_commands',
      values,
      where: 'local_id=?',
      whereArgs: [historicalRoot],
    );
    await db.close();
    store = open();
    await store.initialize();
    recovery = service();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('historical-start-');
    store = open();
    await store.initialize();
    await store.close();
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/old.db');
    // Literal persisted ABI from the historical app. No enum-derived insertion.
    await db.rawInsert(
      '''insert into outbox_commands
      (local_id,command_id,command_type,account_id,well_id,sequence,occurred_at,created_local_at,payload,status,last_error,last_attempt_at)
      values(?,?,'startIrrigationSession','account','well',1,?,?,?,'review','uncertain',?)''',
      [
        historicalRoot,
        historicalCommand,
        startTime.toIso8601String(),
        startTime.toIso8601String(),
        jsonEncode({
          'p_well_id': 'well',
          'p_pump_id': 'pump',
          'p_farm_id': 'farm',
          'p_farmer_well_account_id': 'farmer',
          'p_energy_source': 'solar',
        }),
        startTime.toIso8601String(),
      ],
    );
    await db.rawInsert(
      "insert into sync_meta(account_id,key,value) values('account','sequence_counter','1')",
    );
    await db.close();
    // A fixture with explicit existing human evidence; its absence is tested separately.
    store = open();
    await store.initialize();
    root = (await store.commandByLocalId('account', historicalRoot))!;
    await store.insertLocalRecordOnce(
      accountId: 'account',
      key: humanCommandIntentBundleKey(historicalRoot),
      value: humanCommandIntentRecord(root),
    );
    await store.close();
    store = open();
    await store.initialize();
    transport = HistoricalReceiptTransport();
    repository = GuidedRepository();
    account = 'account';
    recovery = service();
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  test(
    'raw historical row reopens and uses its original receipt request type',
    () async {
      expect(root.type, CommandType.startIrrigationSession);
      final request = OperationalStartReceiptRequest.fromCommand(root);
      expect(request, isNotNull);
      expect(
        request!.arguments['p_expected_command_type'],
        'start_irrigation_session',
      );
      expect(request.arguments['p_command_id'], historicalCommand);
    },
  );
  test(
    'accepted historical server receipt offers adoption without dispatch',
    () async {
      final observed = await check();
      expect(observed.canAdopt, true);
      expect(transport.reads, 1);
      expect(
        transport.arguments.single['p_expected_command_type'],
        'start_irrigation_session',
      );
      expect(transport.requests, isEmpty);
    },
  );
  test(
    'historical check is read-only and preserves the original type',
    () async {
      final before = await store.readStartRecovery('account');
      expect((await check()).canAdopt, true);
      final after = await store.readStartRecovery('account');
      expect(after.records, before.records);
      expect(
        after.commands.map(dispatchCommandFingerprint),
        before.commands.map(dispatchCommandFingerprint),
      );
      expect(after.mappings, isEmpty);
      expect(transport.requests, isEmpty);
    },
  );
  test('accepted historical envelope is persisted atomically; type/intent survives reopen', () async {
    final before = root;
    final observed = await check();
    expect(
      (await recovery.adopt(observed)).state,
      OperationalStartRecoveryState.resolved,
    );
    expect(
      (await recovery.adopt(observed)).state,
      OperationalStartRecoveryState.resolved,
    );
    await reopen();
    final saved = (await store.commandByLocalId('account', historicalRoot))!;
    expect(saved.type, CommandType.startIrrigationSession);
    expect(saved.commandId, before.commandId);
    expect(saved.payload, before.payload);
    expect(saved.occurredAt, before.occurredAt);
    expect(saved.createdLocalAt, before.createdLocalAt);
    expect(saved.status, CommandStatus.confirmed);
    expect(saved.serverResponse, {'id': 'server'});
    final event = jsonDecode(
      (await store.readBundle('account', startRecoveryKey(historicalRoot)))!,
    ) as Map;
    expect(
      event['validated_envelope']['command_type'],
      'start_irrigation_session',
    );
    expect(event['validated_envelope']['command_id'], historicalCommand);
    expect(event['validated_envelope']['retry_authorized'], false);
    expect(event['validated_receipt'], {'id': 'server'});
    expect(
      jsonDecode(event['evidence'] as String),
      contains(startRecoveryCommandFingerprint(before)),
    );
    expect(jsonEncode(event), isNot(contains('startOperationalSession')));
    final policy = (await store.readStartRecovery('account')).policy;
    expect(
      policy.root(historicalRoot),
      StartRecoveryDisposition.adoptedServerPerspective,
    );
    final projected = (await ActiveSessionProjector(
      store: store,
    ).projectAll('account', now: startTime)).single;
    expect(projected.localId, historicalRoot);
    expect(projected.serverSessionId, 'server');
    expect(projected.businessState.name, 'running');
    await SyncEngine(store: store, transport: transport).run('account');
    expect(transport.requests, isEmpty);
  });
  test(
    'a bare legacy UUID result is not an accepted command association',
    () async {
      transport.unbound = true;
      expect((await check()).canAdopt, false);
      expect(
        await store.readBundle('account', startRecoveryKey(historicalRoot)),
        isNull,
      );
      expect(transport.requests, isEmpty);
    },
  );
  for (final state in [
    'not_found',
    'unresolved',
    'processing',
    'unknown',
    'rejected',
  ]) {
    test(
      '$state never proves legacy non-execution or creates resolution',
      () async {
        transport.state = state;
        final before = dispatchCommandFingerprint(root);
        final observed = await check();
        expect(observed.canAdopt, false);
        expect(observed.canResolveRejected, false);
        expect(
          (await recovery.resolveRejectedStart(
            observed,
            reason: 'reviewed',
            confirmed: true,
          )).state,
          isNot(OperationalStartRecoveryState.resolved),
        );
        expect(
          dispatchCommandFingerprint(
            await store.commandByLocalId('account', historicalRoot),
          ),
          before,
        );
        expect(
          await store.readBundle('account', startRecoveryKey(historicalRoot)),
          isNull,
        );
        expect(transport.requests, isEmpty);
      },
    );
  }
  test(
    'network error leaves historical review and every request fact intact',
    () async {
      transport.network = true;
      final before = dispatchCommandFingerprint(root);
      expect((await check()).state, OperationalStartRecoveryState.offline);
      await reopen();
      expect(
        dispatchCommandFingerprint(
          await store.commandByLocalId('account', historicalRoot),
        ),
        before,
      );
      expect(transport.requests, isEmpty);
    },
  );
  for (final mismatch in [
    'auth',
    'stored_account',
    'stored_well',
    'payload_well',
    'wire_well',
    'wire_command',
    'wire_type',
    'canonical_well',
    'session',
    'farmer',
  ]) {
    test('$mismatch remains fail closed with no dispatch', () async {
      if (mismatch == 'auth') account = 'other';
      if (mismatch == 'stored_account') await editRoot({'account_id': 'other'});
      if (mismatch == 'stored_well') await editRoot({'well_id': 'other'});
      if (mismatch == 'payload_well') {
        await editRoot({
          'payload': jsonEncode({...root.payload, 'p_well_id': 'other'}),
        });
      }
      if (mismatch == 'wire_well') transport.well = 'other';
      if (mismatch == 'wire_command') transport.command = 'other';
      if (mismatch == 'wire_type') transport.type = 'start_operational_session';
      if (mismatch == 'canonical_well') repository.wellId = 'other';
      if (mismatch == 'session') repository.sessionId = 'other';
      if (mismatch == 'farmer') repository.farmer = 'other';
      expect((await check()).canAdopt, false);
      expect(
        await store.readBundle('account', startRecoveryKey(historicalRoot)),
        isNull,
      );
      expect(transport.requests, isEmpty);
      if ([
        'auth',
        'stored_account',
        'stored_well',
        'payload_well',
      ].contains(mismatch)) {
        expect(transport.reads, 0);
      }
    });
  }
  test('missing old human intent is reported, never manufactured', () async {
    await store.close();
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/old.db');
    await db.delete(
      'sync_meta',
      where: 'account_id=? and key=?',
      whereArgs: ['account', humanCommandIntentBundleKey(historicalRoot)],
    );
    await db.close();
    store = open();
    await store.initialize();
    recovery = service();
    expect((await check()).canAdopt, false);
    expect(transport.reads, 0);
    expect(
      await store.readBundle(
        'account',
        humanCommandIntentBundleKey(historicalRoot),
      ),
      isNull,
    );
    expect(transport.requests, isEmpty);
  });
  test('old stop and pending completion stay isolated; no resend after adoption/reopen', () async {
    final stops = ManualStopRequestStore(store);
    final stop = await stops.recordHumanStopRequest(
      accountId: 'account',
      wellId: 'well',
      sessionLocalId: historicalRoot,
      requestedAt: startTime.add(const Duration(minutes: 3)),
    );
    final completion = await stops.materializeRecordedRequest(stop);
    final before = dispatchCommandFingerprint(completion);
    final key = ManualStopRequestStore.keyFor('well', historicalRoot);
    final raw = await store.readBundle('account', key);
    expect(
      (await recovery.adopt(await check())).state,
      OperationalStartRecoveryState.resolved,
    );
    await reopen();
    expect(await store.readBundle('account', key), raw);
    expect(
      await ManualStopRequestStore(store).recoverRecordedRequests('account'),
      0,
    );
    await SyncEngine(store: store, transport: transport).run('account');
    expect(transport.requests, isEmpty);
    expect(
      dispatchCommandFingerprint(
        await store.commandByLocalId('account', completion.localId),
      ),
      before,
    );
    expect(await OutboxRepository(store: store).pendingCount('account'), 0);
    final projected = (await ActiveSessionProjector(store: store).projectAll(
      'account',
      now: startTime.add(const Duration(minutes: 5)),
    )).single;
    expect(projected.hasPendingManualStop, false);
  });
  test(
    'late contradictory historical result is retained and blocks control',
    () async {
      expect(
        (await recovery.adopt(await check())).state,
        OperationalStartRecoveryState.resolved,
      );
      final before = dispatchCommandFingerprint(
        await store.commandByLocalId('account', historicalRoot),
      );
      await store.markConfirmed(
        'account',
        historicalRoot,
        serverResponse: {'id': 'different'},
        attemptedAt: startTime,
      );
      await reopen();
      expect(
        dispatchCommandFingerprint(
          await store.commandByLocalId('account', historicalRoot),
        ),
        before,
      );
      expect(
        await store.readBundle(
          'account',
          startRecoveryConflictKey(historicalRoot),
        ),
        isNotNull,
      );
      expect(
        (await store.readStartRecovery('account')).policy.root(historicalRoot),
        StartRecoveryDisposition.conflict,
      );
      expect(
        (await OutboxRepository(store: store).needingReview('account'))
            .single
            .localId,
        historicalRoot,
      );
      await SyncEngine(store: store, transport: transport).run('account');
      expect(transport.requests, isEmpty);
    },
  );
  test('stored old accepted response is not rewritten or used without a fresh receipt', () async {
    await editRoot({
      'server_response': jsonEncode({'id': 'server'}),
    });
    final before = (await store.commandByLocalId('account', historicalRoot))!;
    transport.network = true;
    expect((await check()).canAdopt, false);
    transport.network = false;
    expect(
      (await recovery.adopt(await check())).state,
      OperationalStartRecoveryState.resolved,
    );
    await reopen();
    final after = (await store.commandByLocalId('account', historicalRoot))!;
    expect(after.serverResponse, before.serverResponse);
    expect(after.type, before.type);
    expect(after.payload, before.payload);
    expect(transport.requests, isEmpty);
  });
  test('existing contradictory session mapping is never replaced', () async {
    await store.putMapping(
      'account',
      IdMapping(
        localId: historicalRoot,
        kind: EntityKind.session,
        serverId: 'different',
        resolvedAt: startTime,
      ),
    );
    expect((await check()).canAdopt, false);
    expect(
      (await store.mapping(
        'account',
        historicalRoot,
        EntityKind.session,
      ))!.serverId,
      'different',
    );
    expect(transport.requests, isEmpty);
  });
  test('other historical families are not implicitly enabled', () {
    expect(isRecoverySupportedStartType(CommandType.startAdhocSession), false);
    expect(
      isRecoverySupportedStartType(CommandType.startBookingSession),
      false,
    );
    expect(
      isRecoverySupportedStartType(CommandType.startIrrigationSession),
      true,
    );
    expect(
      isRecoverySupportedStartType(CommandType.startOperationalSession),
      true,
    );
  });
  for (final status in ['review', 'dispatching', 'pending']) {
    test(
      'existing sync never blindly resends attempted historical $status root',
      () async {
        await editRoot({'status': status, 'retry_count': 1});
        await SyncEngine(store: store, transport: transport).run('account');
        final saved = (await store.commandByLocalId(
          'account',
          historicalRoot,
        ))!;
        expect(saved.type, CommandType.startIrrigationSession);
        expect(saved.commandId, historicalCommand);
        expect(saved.payload, root.payload);
        expect(saved.serverResponse, isNull);
        expect(transport.requests, isEmpty);
        expect(transport.reads, 0);
      },
    );
  }
  test('missing or changed persisted historical association proof blocks after reopen', () async {
    expect(
      (await recovery.adopt(await check())).state,
      OperationalStartRecoveryState.resolved,
    );
    final key = startRecoveryKey(historicalRoot);
    final event = jsonDecode(
      (await store.readBundle('account', key))!,
    ) as Map<String, dynamic>;
    event.remove('validated_envelope');
    await store.close();
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/old.db');
    await db.update(
      'sync_meta',
      {'value': jsonEncode(event)},
      where: 'account_id=? and key=?',
      whereArgs: ['account', key],
    );
    await db.close();
    store = open();
    await store.initialize();
    recovery = service();
    final policy = (await store.readStartRecovery('account')).policy;
    expect(policy.root(historicalRoot), StartRecoveryDisposition.conflict);
    expect(policy.mayControl(historicalRoot), false);
    await SyncEngine(store: store, transport: transport).run('account');
    expect(transport.requests, isEmpty);
  });
  test(
    'a conflicting stored result is preserved rather than overwritten',
    () async {
      await editRoot({
        'server_response': jsonEncode({'id': 'different'}),
      });
      final before = dispatchCommandFingerprint(
        await store.commandByLocalId('account', historicalRoot),
      );
      expect((await check()).canAdopt, false);
      expect(
        dispatchCommandFingerprint(
          await store.commandByLocalId('account', historicalRoot),
        ),
        before,
      );
      expect(transport.requests, isEmpty);
    },
  );
  test(
    'shared policy has the same historical acceptance behavior in memory',
    () async {
      final memory = InMemoryOutboxStore();
      await memory.initialize();
      await memory.insert(root);
      await memory.insertLocalRecordOnce(
        accountId: 'account',
        key: humanCommandIntentBundleKey(historicalRoot),
        value: humanCommandIntentRecord(root),
      );
      final local = OperationalStartRecovery(
        store: memory,
        transport: transport,
        repository: repository,
        currentAccountId: () => account,
      );
      final observed = await local.check(
        accountId: 'account',
        wellId: 'well',
        sessionLocalId: historicalRoot,
      );
      expect(
        (await local.adopt(observed)).state,
        OperationalStartRecoveryState.resolved,
      );
      expect(
        (await memory.readStartRecovery('account')).policy.root(historicalRoot),
        StartRecoveryDisposition.adoptedServerPerspective,
      );
      expect(
        (await memory.commandByLocalId('account', historicalRoot))!.type,
        CommandType.startIrrigationSession,
      );
      expect(transport.requests, isEmpty);
      await memory.close();
    },
  );
  test(
    'command-bound historical receipt survives changed canonical start facts',
    () async {
      repository = CorrectedHistoricalRepository();
      recovery = service();
      expect(
        (await recovery.adopt(await check())).state,
        OperationalStartRecoveryState.resolved,
      );
      await reopen();
      final projected = (await ActiveSessionProjector(store: store).projectAll(
        'account',
        now: startTime.add(const Duration(minutes: 5)),
      )).single;
      expect(projected.startedAt, startTime.add(const Duration(minutes: 1)));
      expect(
        (await store.commandByLocalId('account', historicalRoot))!.occurredAt,
        startTime,
      );
      expect(transport.requests, isEmpty);
    },
  );
}

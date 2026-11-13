import 'dart:io';
import 'dart:async';

import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/manual_stop_request_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/operational_start_recovery.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/start_recovery_policy.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import 'operational_start_guided_recovery_test.dart';

class CurrentRepository extends GuidedRepository {
  @override
  Future<List<SessionHistoryItem>> fetchSessionHistory({
    required String wellId,
    String? farmerAccountId,
    String? filter,
  }) async => throw StateError('history_lookup_forbidden');
  bool hasActive = false;
  int currentReads = 0;
  @override
  Future<SessionDetailData?> fetchCurrentOperationalSession(String well) async {
    currentReads++;
    if (this.fail) throw const SocketException('offline');
    await barrier?.future;
    return hasActive ? super.fetchSessionDetail('server') : null;
  }
}

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqliteOutboxStore store;
  late CommandEnvelope root;
  late CurrentRepository repo;
  late GuidedReceiptTransport transport;
  late OperationalStartRecovery recovery;
  String? account = 'account';
  void service() {
    recovery = OperationalStartRecovery(
      store: store,
      transport: transport,
      repository: repo,
      currentAccountId: () => account,
    );
  }

  Future<void> reopen() async {
    await store.close();
    store = SqliteOutboxStore(
      databasePath: '${dir.path}/db',
      singleInstance: false,
      sqfliteFactory: databaseFactoryFfi,
    );
    await store.initialize();
    service();
  }

  Future<dynamic> repair() => (recovery as dynamic).repairLegacyStart(
    accountId: 'account',
    wellId: 'well',
    sessionLocalId: root.localId,
  );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('legacy-retire-');
    store = SqliteOutboxStore(
      databasePath: '${dir.path}/db',
      singleInstance: false,
      sqfliteFactory: databaseFactoryFfi,
    );
    await store.initialize();
    root = CommandEnvelope(
      localId: 'old',
      commandId: 'old-command',
      type: CommandType.startIrrigationSession,
      accountId: 'account',
      wellId: 'well',
      sequence: 1,
      occurredAt: startTime.subtract(const Duration(days: 13)),
      createdLocalAt: startTime.subtract(const Duration(days: 13)),
      payload: {
        'p_well_id': 'well',
        'p_pump_id': 'pump',
        'p_farmer_well_account_id': 'farmer',
        'p_farm_id': 'farm',
        'p_energy_source': 'solar',
      },
      status: CommandStatus.review,
      lastError: 'uncertain',
    );
    await store.insert(root);
    await store.nextSequence('account');
    repo = CurrentRepository();
    transport = GuidedReceiptTransport();
    account = 'account';
    service();
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });
  test(
    'no active: root preserved, no blocker or dispatch after reopen',
    () async {
      final before = startRecoveryCommandFingerprint(root);
      final result = await repair();
      expect(result.state, OperationalStartRecoveryState.resolved);
      await reopen();
      final policy = (await store.readStartRecovery('account')).policy;
      expect(policy.root('old').name, 'legacyRetired');
      expect(policy.mayDispatch(root), false);
      expect(policy.actionable(root), false);
      expect(
        startRecoveryCommandFingerprint(
          await store.commandByLocalId('account', 'old'),
        ),
        before,
      );
      expect(
        await ActiveSessionProjector(store: store)
            .projectAll('account', now: startTime),
        isEmpty,
      );
      expect(transport.requests, isEmpty);
    },
  );
  test('current active is separate from historical root', () async {
    repo.hasActive = true;
    await repair();
    await reopen();
    final projected = await ActiveSessionProjector(store: store)
        .projectAll('account', now: startTime);
    expect(projected.single.serverSessionId, 'server');
    expect(projected.single.localId, isNot('old'));
    expect(
      (await store.commandByLocalId('account', 'old'))!.status,
      CommandStatus.review,
    );
    expect(transport.reads, 0);
    expect(transport.requests, isEmpty);
  });
  Future<CommandEnvelope> child(
    String id, {
    String? aggregate,
    List<String> dependencies = const [],
    Map<String, Object?>? payload,
    CommandStatus status = CommandStatus.pending,
  }) async {
    final c = CommandEnvelope(
      localId: id,
      commandId: 'command-$id',
      type: CommandType.pauseIrrigationSession,
      accountId: 'account',
      wellId: 'well',
      sequence: await store.nextSequence('account'),
      occurredAt: startTime.add(const Duration(minutes: 1)),
      createdLocalAt: startTime,
      payload:
          payload ??
          {
            'p_session_id': {r'$ref': 'old', r'$kind': 'session'},
            'p_reason': 'operator_pause',
          },
      aggregateLocalId: aggregate,
      prerequisites: dependencies,
      status: status,
    );
    return store.insert(c);
  }

  test(
    'all descendant relationships and statuses are permanently fenced',
    () async {
      final children = [
        await child('aggregate', aggregate: 'old'),
        await child('dependency', dependencies: ['aggregate']),
        await child('reference', status: CommandStatus.dispatching),
        await child('review', aggregate: 'old', status: CommandStatus.review),
        await child(
          'accepted',
          aggregate: 'old',
          status: CommandStatus.confirmed,
        ),
      ];
      final before = {
        for (final c in [root, ...children])
          c.localId: startRecoveryCommandFingerprint(c),
      };
      await repair();
      await reopen();
      var policy = (await store.readStartRecovery('account')).policy;
      for (final c in [root, ...children]) {
        expect(policy.mayDispatch(c), false);
        expect(policy.actionable(c), false);
      }
      await SyncEngine(store: store, transport: transport).run('account');
      expect(transport.requests, isEmpty);
      expect(transport.reads, 0);
      for (final c in [root, ...children]) {
        expect(
          startRecoveryCommandFingerprint(
            await store.commandByLocalId('account', c.localId),
          ),
          before[c.localId],
        );
      }
      expect(await OutboxRepository(store: store).pendingCount('account'), 0);
      expect(
        await OutboxRepository(store: store).needingReview('account'),
        isEmpty,
      );
    },
  );
  test(
    'late acceptance and mapping are audit only, no resurrection after reopen',
    () async {
      await repair();
      await store.markConfirmed(
        'account',
        'old',
        serverResponse: {'id': 'late-server'},
        attemptedAt: startTime,
      );
      await store.putMapping(
        'account',
        IdMapping(
          localId: 'old',
          kind: EntityKind.session,
          serverId: 'late-server',
          resolvedAt: startTime,
        ),
      );
      await reopen();
      final state = await store.readStartRecovery('account');
      expect(state.policy.root('old'), StartRecoveryDisposition.legacyRetired);
      expect(state.records.keys.any((k) => k.contains('/evidence/')), true);
      expect(await store.mapping('account', 'old', EntityKind.session), isNull);
      expect(
        (await store.commandByLocalId('account', 'old'))!.status,
        CommandStatus.review,
      );
      expect(
        await ActiveSessionProjector(store: store)
            .projectAll('account', now: startTime),
        isEmpty,
      );
      await SyncEngine(store: store, transport: transport).run('account');
      expect(transport.requests, isEmpty);
    },
  );
  test(
    'late historical result does not replace independent current perspective',
    () async {
      repo.hasActive = true;
      await repair();
      await store.markConfirmed(
        'account',
        'old',
        serverResponse: {'id': 'different-historical'},
        attemptedAt: startTime,
      );
      await reopen();
      final result = await ActiveSessionProjector(store: store)
          .projectAll('account', now: startTime);
      expect(result.single.serverSessionId, 'server');
      expect(result.single.syncState.name, 'synced');
    },
  );
  test(
    'new start is a fresh human command and independent blockers remain',
    () async {
      await repair();
      final coordinator = OfflineSessionCoordinator(store: store);
      addTearDown(coordinator.dispose);
      final next = await coordinator.startSession(
        accountId: 'account',
        wellId: 'well',
        pumpId: 'pump',
        farmId: 'farm',
        farmerAccountId: 'farmer',
        energySource: 'solar',
        startedAt: startTime.add(const Duration(hours: 1)),
      );
      expect(next.commandId, isNot(root.commandId));
      expect(next.localId, isNot(root.localId));
      final again = await coordinator.startSession(
        accountId: 'account',
        wellId: 'well',
        pumpId: 'pump',
        farmId: 'farm',
        farmerAccountId: 'farmer',
        energySource: 'solar',
        startedAt: startTime.add(const Duration(hours: 2)),
      );
      expect(again.commandId, next.commandId);
    },
  );
  test('independent root still blocks start after retiring old root', () async {
    final independent = CommandEnvelope(
      localId: 'independent',
      commandId: 'independent-command',
      type: root.type,
      accountId: root.accountId,
      wellId: root.wellId,
      sequence: 2,
      occurredAt: root.occurredAt,
      createdLocalAt: root.createdLocalAt,
      payload: root.payload,
      status: CommandStatus.review,
    );
    await store.insert(independent);
    await repair();
    final policy = (await store.readStartRecovery('account')).policy;
    expect(policy.blocksOperationalStart(independent), true);
    expect(policy.blocksOperationalStart(root), false);
    final c = OfflineSessionCoordinator(store: store);
    addTearDown(c.dispose);
    await expectLater(
      c.startSession(
        accountId: 'account',
        wellId: 'well',
        pumpId: 'pump',
        farmId: 'farm',
        farmerAccountId: 'farmer',
        energySource: 'solar',
      ),
      throwsA(isA<OperationalStartConflict>()),
    );
  });
  test('network unavailable does not mutate any durable evidence', () async {
    repo.fail = true;
    final before = await store.readStartRecovery('account');
    expect((await repair()).state, OperationalStartRecoveryState.offline);
    final after = await store.readStartRecovery('account');
    expect(after.records, before.records);
    expect(after.evidence('old'), before.evidence('old'));
  });
  test('account mismatch cannot retire or read server', () async {
    account = 'other';
    expect(
      (await repair()).state,
      OperationalStartRecoveryState.unresolvedManualReview,
    );
    expect(repo.currentReads, 0);
    expect(
      (await store.readStartRecovery('account'))
          .records[startRecoveryKey('old')],
      isNull,
    );
  });
  test('requested well mismatch fails closed before network', () async {
    await recovery.repairLegacyStart(
      accountId: 'account',
      wellId: 'wrong',
      sessionLocalId: 'old',
    );
    expect(repo.currentReads, 0);
    expect(
      (await store.readStartRecovery('account'))
          .records[startRecoveryKey('old')],
      isNull,
    );
  });
  test('server session in another well does not mutate', () async {
    repo.hasActive = true;
    repo.wellId = 'wrong';
    await repair();
    expect(
      (await store.readStartRecovery('account'))
          .records[startRecoveryKey('old')],
      isNull,
    );
  });
  test('account switch during server read leaves evidence intact', () async {
    repo.barrier = Completer<void>();
    final work = repair();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    account = 'other';
    repo.barrier!.complete();
    await work;
    expect(
      (await store.readStartRecovery('account'))
          .records[startRecoveryKey('old')],
      isNull,
    );
  });
  test('actual departure while reading prevents retirement', () async {
    var current = true;
    repo.barrier = Completer<void>();
    final work = recovery.repairLegacyStart(
      accountId: 'account',
      wellId: 'well',
      sessionLocalId: 'old',
      isContextCurrent: () => current,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    current = false;
    repo.barrier!.complete();
    await work;
    expect(
      (await store.readStartRecovery('account'))
          .records[startRecoveryKey('old')],
      isNull,
    );
  });
  test(
    'double tap and repeated repair preserve first decision without reread',
    () async {
      repo.barrier = Completer<void>();
      final a = repair(), b = repair();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      repo.barrier!.complete();
      await Future.wait([a, b]);
      final first = (await store.readStartRecovery('account')).records;
      await repair();
      expect((await store.readStartRecovery('account')).records, first);
      expect(repo.currentReads, 1);
      await reopen();
      await repair();
      expect(repo.currentReads, 1);
    },
  );
  test(
    'old stop request stays isolated and new current-session controls work',
    () async {
      await ManualStopRequestStore(store).recordHumanStopRequest(
        accountId: 'account',
        wellId: 'well',
        sessionLocalId: 'old',
        requestedAt: startTime.add(const Duration(minutes: 5)),
      );
      repo.hasActive = true;
      await repair();
      await reopen();
      expect(
        await ManualStopRequestStore(store).recoverRecordedRequests('account'),
        0,
      );
      final c = OfflineSessionCoordinator(store: store);
      addTearDown(c.dispose);
      final current = (await c.freshProjectActiveSession(
        accountId: 'account',
        wellId: 'well',
      ))!;
      expect(current.hasPendingManualStop, false);
      final pause = await c.pauseSession(
        accountId: 'account',
        sessionLocalId: current.localId,
        reason: 'operator_pause',
        pausedAt: startTime.add(const Duration(minutes: 10)),
      );
      expect(pause.aggregateLocalId, current.localId);
      expect(pause.aggregateLocalId, isNot(root.localId));
      await SyncEngine(store: store, transport: transport).run('account');
      expect(transport.requests.length, 1);
      expect(
        transport.requests.single.type,
        CommandType.pauseIrrigationSession,
      );
      expect(transport.requests.single.arguments['p_session_id'], 'server');
      await reopen();
      final again = (await ActiveSessionProjector(store: store).projectAll(
        'account',
        now: startTime.add(const Duration(minutes: 11)),
      )).single;
      expect(again.businessState.name, 'paused');
    },
  );
  test('new completion uses new stop epoch and preserves old root', () async {
    repo.hasActive = true;
    await repair();
    final c = OfflineSessionCoordinator(store: store);
    addTearDown(c.dispose);
    final current = (await c.freshProjectActiveSession(
      accountId: 'account',
      wellId: 'well',
    ))!;
    final complete = await c.completeSession(
      accountId: 'account',
      sessionLocalId: current.localId,
      completedAt: startTime.add(const Duration(minutes: 20)),
    );
    expect(complete.aggregateLocalId, isNot('old'));
    expect(complete.type, CommandType.completeIrrigationSession);
    expect(
      (await store.commandByLocalId('account', 'old'))!.status,
      CommandStatus.review,
    );
  });
  test('active current perspective prevents new start', () async {
    repo.hasActive = true;
    await repair();
    final c = OfflineSessionCoordinator(store: store);
    addTearDown(c.dispose);
    await expectLater(
      c.startSession(
        accountId: 'account',
        wellId: 'well',
        pumpId: 'pump',
        farmId: 'farm',
        farmerAccountId: 'farmer',
        energySource: 'solar',
      ),
      throwsA(isA<OperationalStartConflict>()),
    );
  });
  test('no fabricated outbox source or mapping for old root', () async {
    repo.hasActive = true;
    await repair();
    final policy = (await store.readStartRecovery('account')).policy;
    final source = policy.controlSources.single;
    expect(await store.commandByLocalId('account', source.localId), isNull);
    expect(await store.allCommands('account'), hasLength(1));
    await expectLater(store.insert(source), throwsStateError);
    expect(policy.mayDispatch(source), false);
    expect(await store.mapping('account', 'old', EntityKind.session), isNull);
  });
  test(
    'in-memory parity of retirement and separate server perspective',
    () async {
      final memory = InMemoryOutboxStore();
      await memory.initialize();
      await memory.insert(root);
      repo.hasActive = true;
      final r = OperationalStartRecovery(
        store: memory,
        transport: transport,
        repository: repo,
        currentAccountId: () => account,
      );
      await r.repairLegacyStart(
        accountId: 'account',
        wellId: 'well',
        sessionLocalId: 'old',
      );
      expect(
        (await memory.readStartRecovery('account')).policy.root('old'),
        StartRecoveryDisposition.legacyRetired,
      );
      final view = await ActiveSessionProjector(store: memory)
          .projectAll('account', now: startTime);
      expect(view.single.serverSessionId, 'server');
      await memory.close();
    },
  );
  for (final status in [CommandStatus.pending, CommandStatus.dispatching]) {
    test(
      'retirement preserves historical ${status.name} root unchanged',
      () async {
        final c = CommandEnvelope(
          localId: 'status-root',
          commandId: 'status-command',
          type: root.type,
          accountId: 'account',
          wellId: 'well',
          sequence: await store.nextSequence('account'),
          occurredAt: root.occurredAt,
          createdLocalAt: root.createdLocalAt,
          payload: root.payload,
          status: status,
        );
        await store.insert(c);
        await recovery.repairLegacyStart(
          accountId: 'account',
          wellId: 'well',
          sessionLocalId: c.localId,
        );
        await reopen();
        final policy = (await store.readStartRecovery('account')).policy;
        expect(policy.root(c.localId), StartRecoveryDisposition.legacyRetired);
        expect(policy.mayDispatch(c), false);
        expect(
          (await store.commandByLocalId('account', c.localId))!.status,
          status,
        );
      },
    );
  }
  test('new descendant cannot be appended to a retired root', () async {
    await repair();
    await expectLater(child('late-child', aggregate: 'old'), throwsStateError);
    expect(await store.commandByLocalId('account', 'late-child'), isNull);
  });
  test(
    'changed local family during current read is not silently retired',
    () async {
      repo.barrier = Completer<void>();
      final work = repair();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await child('changed', aggregate: 'old');
      repo.barrier!.complete();
      final result = await work;
      expect(
        result.state,
        OperationalStartRecoveryState.unresolvedManualReview,
      );
      expect(
        (await store.readStartRecovery('account'))
            .records[startRecoveryKey('old')],
        isNull,
      );
    },
  );
  test('first retirement wins across two SQLite connections', () async {
    final second = SqliteOutboxStore(
      databasePath: '${dir.path}/db',
      singleInstance: false,
      sqfliteFactory: databaseFactoryFfi,
    );
    await second.initialize();
    try {
      repo.barrier = Completer<void>();
      final other = OperationalStartRecovery(
        store: second,
        transport: transport,
        repository: repo,
        currentAccountId: () => account,
      );
      final a = repair(),
          b = other.repairLegacyStart(
            accountId: 'account',
            wellId: 'well',
            sessionLocalId: 'old',
          );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      repo.barrier!.complete();
      final results = await Future.wait([a, b]);
      expect(
        results.every((r) => r.state == OperationalStartRecoveryState.resolved),
        true,
      );
      expect(
        (await store.readStartRecovery('account')).records.keys
            .where((k) => k == startRecoveryKey('old')),
        hasLength(1),
      );
    } finally {
      await second.close();
    }
  });
  test(
    'current server farmer and time need no historical relationship',
    () async {
      repo.hasActive = true;
      repo.farmer = 'different-current-farmer';
      final result = await repair();
      expect(result.state, OperationalStartRecoveryState.resolved);
      final current = (await ActiveSessionProjector(
        store: store,
      ).projectAll('account', now: startTime)).single;
      expect(current.farmerReference, 'different-current-farmer');
      expect(current.startedAt, isNot(root.occurredAt));
      expect(await store.mapping('account', 'old', EntityKind.session), isNull);
    },
  );
  test('retired linked booking cannot bypass generic dispatch guard', () async {
    final booking = CommandEnvelope(
      localId: 'linked-booking',
      commandId: 'linked-booking-command',
      type: CommandType.createBooking,
      accountId: 'account',
      wellId: 'well',
      aggregateLocalId: 'old',
      sequence: await store.nextSequence('account'),
      occurredAt: startTime,
      createdLocalAt: startTime,
      payload: {
        'p_well_id': 'well',
        'p_farm_id': 'farm',
        'p_farmer_well_account_id': 'farmer',
      },
    );
    await store.insert(booking);
    await repair();
    expect(
      await store.claimBookingCreate(
        'account',
        booking.localId,
        attemptedAt: DateTime.now(),
      ),
      false,
    );
    await SyncEngine(store: store, transport: transport).run('account');
    expect(transport.requests, isEmpty);
    expect(
      (await store.commandByLocalId('account', booking.localId))!.status,
      CommandStatus.pending,
    );
  });
  test(
    'retired descendant does not starve an independent current booking',
    () async {
      final payload = {
        'p_well_id': 'well',
        'p_farm_id': 'farm',
        'p_farmer_well_account_id': 'farmer',
      };
      final old = CommandEnvelope(
        localId: 'linked',
        commandId: 'linked-id',
        accountId: 'account',
        wellId: 'well',
        type: CommandType.createBooking,
        aggregateLocalId: 'old',
        sequence: await store.nextSequence('account'),
        occurredAt: startTime,
        createdLocalAt: startTime,
        payload: payload,
      );
      await store.insert(old);
      await repair();
      expect(
        await store.bookingCreateNextWake(
          'account',
          now: DateTime.now(),
          staleClaimTimeout: const Duration(minutes: 1),
        ),
        isNull,
      );
      final current = await OutboxRepository(store: store).enqueue(
        accountId: 'account',
        wellId: 'well',
        type: CommandType.createBooking,
        payload: payload,
        occurredAt: startTime,
      );
      expect(
        (await store.bookingCreatesReady(
          'account',
          now: DateTime.now(),
        )).map((c) => c.localId),
        [current.localId],
      );
      expect(
        await store.claimBookingCreate(
          'account',
          current.localId,
          attemptedAt: DateTime.now(),
        ),
        true,
      );
      expect(await OutboxRepository(store: store).pendingCount('account'), 1);
    },
  );
}

@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';

import '../sync/fake_command_transport.dart';
import '../sync/sync_test_support.dart';
import 'session_test_support.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory directory;
  late String path;
  late SequentialIdGenerator ids;
  final stores = <SqliteOutboxStore>[];
  final now = DateTime.utc(2026, 9, 17, 12);

  Future<SqliteOutboxStore> open() async {
    final store = SqliteOutboxStore(
      databasePath: path,
      sqfliteFactory: databaseFactoryFfi,
    );
    await store.initialize();
    stores.add(store);
    return store;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('recovery_query');
    path = '${directory.path}/outbox.db';
    ids = SequentialIdGenerator();
  });

  tearDown(() async {
    for (final store in stores) {
      await store.close();
    }
    stores.clear();
    await directory.delete(recursive: true);
  });

  test('fully confirmed completed chain is not recoverable', () async {
    final store = await open();
    final coordinator = OfflineSessionCoordinator(store: store);
    final start = await coordinator.startSession(
      accountId: sessionAccount,
      wellId: sessionWell,
      pumpId: 'pump-one',
      farmId: 'farm-one',
      farmerAccountId: 'farmer-one',
      energySource: 'solar',
      startedAt: now,
    );
    await coordinator.completeSession(
      accountId: sessionAccount,
      sessionLocalId: start.localId,
      completedAt: now.add(const Duration(seconds: 1)),
    );
    expect(
      await ActiveSessionProjector(store: store)
          .unresolvedSessions(sessionAccount, now: now),
      hasLength(1),
    );
    final report = await SyncEngine(
      store: store,
      transport: FakeCommandTransport(),
    ).run(sessionAccount);
    expect(report.confirmed, 2);
    expect(
      await ActiveSessionProjector(store: store)
          .unresolvedSessions(sessionAccount, now: now),
      isEmpty,
    );
    coordinator.dispose();
  });

  test(
    'query returns every account-owned active chain by START local id',
    () async {
      final store = await open();
      final repo = OutboxRepository(store: store, idGenerator: ids);
      final first = await startSession(repo, at: now, well: 'well-one');
      final second = await startSession(
        repo,
        at: now.add(const Duration(seconds: 1)),
        well: 'well-two',
      );
      await startSession(repo, at: now, account: 'account-other');
      final projector = ActiveSessionProjector(store: store);

      final chains = await projector.unresolvedSessions(
        sessionAccount,
        now: now,
      );
      expect(chains.map((chain) => chain.localId), [
        first.localId,
        second.localId,
      ]);
      expect(
        await projector.unresolvedSessions('account-other', now: now),
        hasLength(1),
      );
      expect(
        (await projector.unresolvedSession(
          sessionAccount,
          second.localId,
          now: now,
        ))?.localId,
        second.localId,
      );
      expect(
        await projector.unresolvedSession(sessionAccount, 'missing', now: now),
        isNull,
      );
      final coordinator = OfflineSessionCoordinator(store: store);
      expect(
        await coordinator.projectActiveSession(accountId: sessionAccount),
        isNull,
      );
      coordinator.dispose();
    },
  );

  test(
    'paused and locally completed pending chains survive store reopen',
    () async {
      final writer = await open();
      final repo = OutboxRepository(store: writer, idGenerator: ids);
      final paused = await startSession(repo, at: now, well: 'well-paused');
      await pause(
        repo,
        session: paused,
        at: now.add(const Duration(seconds: 5)),
      );
      final completed = await startSession(
        repo,
        at: now.add(const Duration(seconds: 10)),
        well: 'well-completed',
      );
      final end = await complete(
        repo,
        session: completed,
        at: now.add(const Duration(seconds: 20)),
      );
      await writer.close();
      stores.remove(writer);

      final reopened = await open();
      final projector = ActiveSessionProjector(store: reopened);
      final chains = await projector.unresolvedSessions(
        sessionAccount,
        now: now.add(const Duration(seconds: 30)),
      );

      expect(chains, hasLength(2));
      expect(chains[0].businessState, SessionBusinessState.paused);
      expect(chains[1].businessState, SessionBusinessState.completed);
      expect(chains[1].businessState.isActive, isFalse);
      expect(chains[1].localId, completed.localId);
      expect(
        (await reopened.commandByLocalId(
          sessionAccount,
          completed.localId,
        ))?.commandId,
        completed.commandId,
      );
      expect(
        (await reopened.commandByLocalId(
          sessionAccount,
          end.localId,
        ))?.commandId,
        end.commandId,
      );
    },
  );

  test(
    'pre-ACK child events keep START reference and order after reopen',
    () async {
      final writer = await open();
      final coordinator = OfflineSessionCoordinator(store: writer);
      final start = await coordinator.startSession(
        accountId: sessionAccount,
        wellId: sessionWell,
        pumpId: 'pump-one',
        farmId: 'farm-one',
        farmerAccountId: 'farmer-one',
        energySource: 'solar',
        startedAt: now,
      );
      await coordinator.pauseSession(
        accountId: sessionAccount,
        sessionLocalId: start.localId,
        reason: 'operator_pause',
        pausedAt: now.add(const Duration(seconds: 1)),
      );
      await coordinator.resumeSession(
        accountId: sessionAccount,
        sessionLocalId: start.localId,
        resumedAt: now.add(const Duration(seconds: 2)),
      );
      await coordinator.changeEnergySource(
        accountId: sessionAccount,
        sessionLocalId: start.localId,
        newEnergySource: 'well_diesel',
        changedAt: now.add(const Duration(seconds: 3)),
      );
      await coordinator.completeSession(
        accountId: sessionAccount,
        sessionLocalId: start.localId,
        completedAt: now.add(const Duration(seconds: 4)),
      );
      coordinator.dispose();
      await writer.close();
      stores.remove(writer);

      final reopened = await open();
      final rows = await reopened.allCommands(sessionAccount);
      expect(rows.map((row) => row.sequence), [1, 2, 3, 4, 5]);
      expect(rows.map((row) => row.type), [
        CommandType.startIrrigationSession,
        CommandType.pauseIrrigationSession,
        CommandType.resumeIrrigationSession,
        CommandType.changeSessionEnergySource,
        CommandType.completeIrrigationSession,
      ]);
      expect(rows.first.commandId, start.commandId);
      for (final child in rows.skip(1)) {
        expect(child.aggregateLocalId, start.localId);
        expect(child.payload['p_session_id'], {
          r'$ref': start.localId,
          r'$kind': 'session',
        });
      }
      final restored = await ActiveSessionProjector(store: reopened)
          .unresolvedSession(sessionAccount, start.localId, now: now);
      expect(restored?.businessState, SessionBusinessState.completed);
      final reader = OfflineSessionCoordinator(store: reopened);
      expect(
        (await reader.unresolvedSessions(sessionAccount)).map((s) => s.localId),
        [start.localId],
      );
      expect(
        (await reader.unresolvedSession(
          sessionAccount,
          start.localId,
        ))?.localId,
        start.localId,
      );
      reader.dispose();
    },
  );
}

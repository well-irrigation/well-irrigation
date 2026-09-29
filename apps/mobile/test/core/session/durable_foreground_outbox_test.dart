import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_database.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import '../sync/fake_command_transport.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  late Directory directory;
  late String previousPath;
  final coordinators = <OfflineSessionCoordinator>[];
  final stores = <SqliteOutboxStore>[];

  setUp(() async {
    previousPath = await databaseFactory.getDatabasesPath();
    directory = await Directory.systemTemp.createTemp('foreground_outbox');
    await databaseFactory.setDatabasesPath(directory.path);
  });

  tearDown(() async {
    for (final coordinator in coordinators) {
      coordinator.dispose();
    }
    coordinators.clear();
    for (final store in stores) {
      await store.close();
    }
    stores.clear();
    await databaseFactory.setDatabasesPath(previousPath);
    await directory.delete(recursive: true);
  });

  test(
    'أوامر المقدمة تبقى في ملف العامل بنفس الهوية والترتيب والعزل',
    () async {
      final foreground = OfflineSessionCoordinator.instance;
      coordinators.add(foreground);
      final start = await foreground.startSession(
        accountId: 'account-a',
        wellId: 'well-a',
        pumpId: 'pump-a',
        farmId: 'farm-a',
        farmerAccountId: 'farmer-a',
        energySource: 'solar',
      );
      final pause = await foreground.pauseSession(
        accountId: 'account-a',
        sessionLocalId: start.localId,
        reason: 'operator_pause',
      );

      final worker = SqliteOutboxStore(
        databasePath: await resolveOutboxDatabasePath(),
      );
      stores.add(worker);
      await worker.initialize();
      final pending = await worker.pendingCommands('account-a');
      expect(pending.map((c) => c.commandId), [
        start.commandId,
        pause.commandId,
      ]);
      expect(pending.map((c) => c.sequence), [1, 2]);
      expect(await worker.pendingCommands('account-b'), isEmpty);
      expect(foreground.usesDurableStore, isTrue);

      foreground.dispose();
      await worker.close();
      final reopened = OfflineSessionCoordinator.instance;
      coordinators.add(reopened);
      expect(await reopened.getPendingOperationsCount('account-a'), 2);
      expect(await reopened.getPendingOperationsCount('account-b'), 0);
      final resume = await reopened.resumeSession(
        accountId: 'account-a',
        sessionLocalId: start.localId,
      );
      expect(resume.sequence, 3);
      await worker.initialize();
      expect(
        (await worker.pendingCommands('account-a')).map((c) => c.commandId),
        [start.commandId, pause.commandId, resume.commandId],
      );
    },
  );

  test('فشل فتح الملف يمنع نجاح الأمر ولا يرجع إلى الذاكرة', () async {
    final blockedPath = File('${directory.path}/blocked');
    await blockedPath.writeAsString('ليس مجلدًا');
    await databaseFactory.setDatabasesPath(blockedPath.path);
    final foreground = OfflineSessionCoordinator.instance;
    coordinators.add(foreground);
    await expectLater(
      foreground.startSession(
        accountId: 'account-a',
        wellId: 'well-a',
        pumpId: 'pump-a',
        farmId: 'farm-a',
        farmerAccountId: 'farmer-a',
        energySource: 'solar',
      ),
      throwsA(isA<Exception>()),
    );
    expect(foreground.currentActiveSession, isNull);
  });

  test('فشل النقل يبقي الأمر المتين ثم يؤكده إقرار لاحق بنفس هويته', () async {
    final path = await resolveOutboxDatabasePath();
    final store = SqliteOutboxStore(databasePath: path);
    stores.add(store);
    final writer = OfflineSessionCoordinator(store: store);
    coordinators.add(writer);
    final command = await writer.startSession(
      accountId: 'account-a',
      wellId: 'well-a',
      pumpId: 'pump-a',
      farmId: 'farm-a',
      farmerAccountId: 'farmer-a',
      energySource: 'solar',
    );

    final transport = FakeCommandTransport()
      ..scheduleNetworkFailure(CommandType.startIrrigationSession);
    final wired = OfflineSessionCoordinator(
      store: store,
      commandTransport: transport,
    );
    coordinators.add(wired);
    expect(wired.canSyncNow, isTrue);

    final failed = await wired.syncNow('account-a');
    expect(failed.retryScheduled, 1);
    final pending = await store.commandByLocalId('account-a', command.localId);
    expect(pending!.status, CommandStatus.pending);
    expect(pending.commandId, command.commandId);

    final accepted = await wired.syncNow('account-a');
    expect(accepted.confirmed, 1);
    final confirmed = await store.commandByLocalId(
      'account-a',
      command.localId,
    );
    expect(confirmed!.status, CommandStatus.confirmed);
    expect(confirmed.commandId, command.commandId);
  });

  test('الأمر المتين يشغّل محرك المقدمة الموصول ويؤكده الرد فقط', () async {
    final store = SqliteOutboxStore(
      databasePath: await resolveOutboxDatabasePath(),
    );
    stores.add(store);
    final transport = FakeCommandTransport();
    final foreground = OfflineSessionCoordinator(
      store: store,
      commandTransport: transport,
    );
    coordinators.add(foreground);
    final syncProjection = foreground.activeSessionStream.skip(1).first;

    final command = await foreground.startSession(
      accountId: 'account-a',
      wellId: 'well-a',
      pumpId: 'pump-a',
      farmId: 'farm-a',
      farmerAccountId: 'farmer-a',
      energySource: 'solar',
    );
    await syncProjection;

    expect(transport.requests.single.commandId, command.commandId);
    expect(
      (await store.commandByLocalId('account-a', command.localId))!.status,
      CommandStatus.confirmed,
    );
  });
}

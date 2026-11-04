import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_database.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import '../sync/fake_command_transport.dart';

class _ReceiptTransport extends FakeCommandTransport
    implements CompletionReceiptTransport {
  final reads = <CompletionReceiptRequest>[];

  @override
  Future<CompletionReceiptRead> readCompletionReceipt(
    CompletionReceiptRequest request,
  ) async {
    reads.add(request);
    final accepted = executed[request.commandId] as DispatchAccepted;
    return CompletionReceiptResponse(
      CompletionReceiptState.accepted,
      accepted.response,
    );
  }
}

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
    final start = await writer.startSession(
      accountId: 'account-a',
      wellId: 'well-a',
      pumpId: 'pump-a',
      farmId: 'farm-a',
      farmerAccountId: 'farmer-a',
      energySource: 'solar',
    );

    // قبول البدء شرط سابق؛ محاولة الإكمال وحدها تفقد الرد بعد التنفيذ.
    final transport = _ReceiptTransport();
    final wired = OfflineSessionCoordinator(
      store: store,
      commandTransport: transport,
    );
    coordinators.add(wired);
    expect(wired.canSyncNow, isTrue);

    await wired.syncNow('account-a');
    expect(
      (await store.commandByLocalId('account-a', start.localId))!.status,
      CommandStatus.confirmed,
    );
    transport.requests.clear();
    transport.swallowAckOnce.add(CommandType.completeIrrigationSession.rpcName);
    final command = await writer.completeSession(
      accountId: 'account-a',
      sessionLocalId: start.localId,
      completedAt: start.occurredAt.add(const Duration(hours: 1)),
    );
    final failed = await wired.syncNow('account-a');
    expect(failed.retryScheduled, 0);
    expect(transport.requests, hasLength(1));
    final pending = await store.commandByLocalId('account-a', command.localId);
    expect(pending!.status, CommandStatus.dispatching);
    expect(pending.retryCount, 0);
    expect(pending.commandId, command.commandId);

    final accepted = await wired.syncNow('account-a');
    expect(accepted.confirmed, 1);
    final confirmed = await store.commandByLocalId(
      'account-a',
      command.localId,
    );
    expect(confirmed!.status, CommandStatus.confirmed);
    expect(confirmed.commandId, command.commandId);
    expect(confirmed.localId, command.localId);
    expect(confirmed.occurredAt, command.occurredAt);
    expect(confirmed.createdLocalAt, command.createdLocalAt);
    expect(confirmed.payload, command.payload);
    expect(transport.reads.single.commandId, command.commandId);
    expect(
      transport.reads.single.sessionId,
      (await store.mapping(
        'account-a',
        start.localId,
        EntityKind.session,
      ))!.serverId,
    );
    await wired.syncNow('account-a');
    expect(transport.requests, hasLength(1));
    expect(transport.requests.single.commandId, command.commandId);
    expect(
      transport.requests.single.arguments['p_ended_at'],
      command.occurredAt.toIso8601String(),
    );
    expect(await store.allCommands('account-a'), hasLength(2));
    expect(
      transport.executionCount,
      2,
    ); // البدء السابق والإكمال مرة واحدة لكل منهما.
    final events = await store.notificationEvents.db.query(
      'notification_events',
      where: "event_type='session.completed'",
    );
    expect(events, hasLength(1));
    expect(
      events.single['event_key'],
      'session.completed/${command.commandId}',
    );
    final projected = await ActiveSessionProjector(store: store)
        .projectSession('account-a', start.localId, now: command.occurredAt);
    expect(projected!.businessState.isActive, isFalse);
    expect(projected.completedAt, command.occurredAt);
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
    final syncProjection = foreground.activeSessionStream
        .firstWhere((session) => session?.serverSessionId != null)
        .timeout(const Duration(seconds: 10));

    final command = await foreground.startSession(
      accountId: 'account-a',
      wellId: 'well-a',
      pumpId: 'pump-a',
      farmId: 'farm-a',
      farmerAccountId: 'farmer-a',
      energySource: 'solar',
    );
    final observed = await syncProjection;

    expect(observed!.localId, command.localId);
    expect(
      observed.serverSessionId,
      (await store.mapping(
        'account-a',
        command.localId,
        EntityKind.session,
      ))!.serverId,
    );
    expect(transport.requests.single.commandId, command.commandId);
    await foreground.syncNow('account-a');
    expect(transport.requests, hasLength(1));
    expect(
      (await store.commandByLocalId('account-a', command.localId))!.status,
      CommandStatus.confirmed,
    );
  });
}

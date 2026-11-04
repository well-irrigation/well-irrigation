/// انحدار توافق أمر البدء الحرّ مع قاعدة المدة المشروطة (ق-132/750 /
/// M113-E2-e-c2): النوع القديم يبقى حرفيًا كما هو، والمدة الصريحة تسافر
/// إلى `start_adhoc_session` ببصمتها المستقلة، والأوامر المُسلسَلة قبل
/// التغيير تُحفظ دون إرسال عند غياب دليل بشري، ورفض المدة يصير مراجعة لا
/// حلقة إعادة.
///
/// الاختبارات على السلوك لا على نصّ الكود: المزيَّف يسجّل ما أُرسل
/// إليه، وقاعدة SQLite حقيقية تُفتح وتُغلق لإثبات الاستمرارية.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import '../../support/human_command_fixture.dart';
import '../sync/fake_command_transport.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const String accountA = 'account-adhoc-a';
  const String wellOne = 'well-adhoc-0001';
  const String pumpOne = 'pump-adhoc-0001';

  /// تجميعة اختبار واحدة: مخزن ذاكرة جديد ومنسق موصول بمزيَّف.
  /// المؤقّت اللحظي يُستصاف تلقائيًا بعد كل اختبار.
  Future<(InMemoryOutboxStore, OfflineSessionCoordinator)> harness(
    FakeCommandTransport transport,
  ) async {
    final store = InMemoryOutboxStore();
    final coordinator = OfflineSessionCoordinator(
      store: store,
      commandTransport: transport,
    );
    addTearDown(coordinator.dispose);
    await coordinator.initialize();
    return (store, coordinator);
  }

  Future<CommandEnvelope> startLegacy(
    OfflineSessionCoordinator coordinator, {
    DateTime? startedAt,
  }) => coordinator.startSession(
    accountId: accountA,
    wellId: wellOne,
    pumpId: pumpOne,
    farmId: 'farm-adhoc-0001',
    farmerAccountId: 'fwa-adhoc-0001',
    energySource: 'well_diesel',
    crops: const ['سمسم'],
    startedAt: startedAt ?? DateTime.utc(2026, 10, 3, 6),
  );

  Future<CommandEnvelope> startWithDuration(
    OfflineSessionCoordinator coordinator, {
    required int minutes,
  }) => coordinator.startSession(
    accountId: accountA,
    wellId: wellOne,
    pumpId: pumpOne,
    farmId: 'farm-adhoc-0001',
    farmerAccountId: 'fwa-adhoc-0001',
    energySource: 'well_diesel',
    crops: const ['سمسم'],
    startedAt: DateTime.utc(2026, 10, 3, 6),
    plannedDurationMinutes: minutes,
  );

  group('البدء الحرّ بلا مدة — العقد القديم حرفيًا', () {
    test('ينشئ النوع التاريخي نفسه والحمولة نفسها بلا أي مدة ضمنية', () async {
      final (store, coordinator) = await harness(FakeCommandTransport());

      final envelope = await startLegacy(coordinator);

      expect(envelope.type, CommandType.startIrrigationSession);
      expect(envelope.type.rpcName, 'start_irrigation_session');
      expect(envelope.payload, {
        'p_well_id': wellOne,
        'p_pump_id': pumpOne,
        'p_farm_id': 'farm-adhoc-0001',
        'p_farmer_well_account_id': 'fwa-adhoc-0001',
        'p_energy_source': 'well_diesel',
        'p_crops': <String>['سمسم'],
      });
      expect(
        envelope.payload.containsKey('p_planned_duration_minutes'),
        isFalse,
      );
      expect(await store.allCommands(accountA), hasLength(1));
    });

    test('المدة الصفرية والسالبة تُرفض محليًا قبل التسجيل', () async {
      final (store, coordinator) = await harness(FakeCommandTransport());

      await expectLater(
        startWithDuration(coordinator, minutes: 0),
        throwsArgumentError,
      );
      await expectLater(
        startWithDuration(coordinator, minutes: -5),
        throwsArgumentError,
      );
      expect(await store.allCommands(accountA), isEmpty);
    });
  });

  group('البدء الحرّ بمدة صريحة — عقد start_adhoc_session', () {
    test('ينشئ النوع الجديد بحمولة تحمل المدة فوق حقول العقد القديم', () async {
      final (_, coordinator) = await harness(FakeCommandTransport());

      final envelope = await startWithDuration(coordinator, minutes: 90);

      expect(envelope.type, CommandType.startAdhocSession);
      expect(envelope.type.rpcName, 'start_adhoc_session');
      expect(envelope.payload['p_planned_duration_minutes'], 90);
      expect(envelope.payload['p_well_id'], wellOne);
      expect(envelope.payload['p_pump_id'], pumpOne);
      expect(envelope.payload['p_farm_id'], 'farm-adhoc-0001');
      expect(envelope.payload['p_farmer_well_account_id'], 'fwa-adhoc-0001');
      expect(envelope.payload['p_energy_source'], 'well_diesel');
      expect(envelope.payload['p_crops'], <String>['سمسم']);
    });

    test('يُرسَل إلى start_adhoc_session بوسيط المدة ومعرّف العملية', () async {
      final transport = FakeCommandTransport();
      final (store, coordinator) = await harness(transport);

      final envelope = await startWithDuration(coordinator, minutes: 60);
      await SyncEngine(store: store, transport: transport).run(accountA);

      final request = transport.lastRequestFor(CommandType.startAdhocSession);
      expect(request.type.rpcName, 'start_adhoc_session');
      expect(request.commandId, envelope.commandId);
      expect(request.arguments['p_planned_duration_minutes'], 60);
      expect(request.arguments['p_command_id'], envelope.commandId);
      expect(request.arguments['p_started_at'], '2026-10-03T06:00:00.000Z');
      expect(transport.calledFunctions, ['start_adhoc_session']);
    });

    test('إعادة المحاولة تحمل معرّف العملية الأصلي نفسه', () async {
      final transport = FakeCommandTransport();
      transport.swallowAckOnce.add(CommandType.startAdhocSession.rpcName);
      final (store, coordinator) = await harness(transport);

      final envelope = await startWithDuration(coordinator, minutes: 45);
      final engine = SyncEngine(store: store, transport: transport);
      final first = await engine.run(accountA);
      final retry = await engine.run(accountA);

      final attempts = transport.requestsFor(CommandType.startAdhocSession);
      expect(attempts, hasLength(1));
      expect(attempts.single.commandId, envelope.commandId);
      expect(
        attempts.single.arguments['p_started_at'],
        envelope.occurredAt.toIso8601String(),
      );
      expect(first.retryScheduled, 0);
      expect(retry.retryScheduled, 0);
      final saved = (await store.allCommands(accountA)).single;
      expect(saved.localId, envelope.localId);
      expect(saved.commandId, envelope.commandId);
      expect(saved.occurredAt, envelope.occurredAt);
      expect(saved.createdLocalAt, envelope.createdLocalAt);
      expect(saved.payload, envelope.payload);
      expect(saved.status, CommandStatus.dispatching);
      expect(saved.retryCount, 0);
      expect(saved.serverResponse, isNull);
      // الرد المقبول مفقود: يبقى الأصل للتحقق، ولا يُستعاض عنه بإرسال آخر.
      expect(transport.executed[envelope.commandId], isA<DispatchAccepted>());
      expect(transport.executionCount, 1);
    });

    test('المدة تصمد في تسلسل SQLite وفكّه بلا أي هجرة مخطط', () async {
      final tempDir = await Directory.systemTemp.createTemp('outbox_adhoc');
      addTearDown(() => tempDir.delete(recursive: true));
      final databasePath = p.join(tempDir.path, 'outbox.db');

      final writer = SqliteOutboxStore(
        databasePath: databasePath,
        sqfliteFactory: databaseFactoryFfi,
      );
      await writer.initialize();

      final coordinator = OfflineSessionCoordinator(
        store: writer,
        commandTransport: FakeCommandTransport(),
      );
      await coordinator.initialize();
      final envelope = await startWithDuration(coordinator, minutes: 120);
      coordinator.dispose();
      await writer.close();

      // إعادة فتح كقاعدة موجودة بنفس الإصدار: بلا onCreate وبلا ترقية.
      final reader = SqliteOutboxStore(
        databasePath: databasePath,
        sqfliteFactory: databaseFactoryFfi,
      );
      await reader.initialize();
      addTearDown(reader.close);

      final commands = await reader.allCommands(accountA);
      expect(commands, hasLength(1));
      expect(commands.single.type, CommandType.startAdhocSession);
      expect(commands.single.commandId, envelope.commandId);
      expect(commands.single.payload['p_planned_duration_minutes'], 120);
    });
  });

  group('الأوامر القديمة المُسلسَلة قبل التغيير', () {
    /// الحمولة التاريخية كما تسلسلتها النسخة السابقة، حرفيًا.
    final Map<String, Object?> legacyPayload = {
      'p_well_id': wellOne,
      'p_pump_id': pumpOne,
      'p_farm_id': 'farm-legacy-0001',
      'p_farmer_well_account_id': 'fwa-legacy-0001',
      'p_energy_source': 'well_diesel',
      'p_crops': <Object?>['سمسم'],
    };

    Future<String> writeLegacyRow(String databasePath) async {
      final raw = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(version: SqliteOutboxStore.schemaVersion),
      );
      await raw.insert('outbox_commands', {
        'local_id': 'legacy-local-1',
        'command_id': 'legacy-command-1',
        'command_type': 'startIrrigationSession',
        'account_id': accountA,
        'well_id': wellOne,
        'aggregate_local_id': null,
        'sequence': 1,
        'occurred_at': '2026-08-01T05:00:00.000Z',
        'created_local_at': '2026-08-01T05:00:01.000Z',
        'payload': jsonEncode(legacyPayload),
        'status': 'pending',
        'retry_count': 0,
        'last_error': null,
        'last_attempt_at': null,
        'server_response': null,
      });
      await raw.close();
      return 'legacy-command-1';
    }

    /// قاعدة جديدة يبنيها الكود الحالي ثم يُحقن فيها صفّ قديم.
    Future<String> databaseWithLegacyRow() async {
      final tempDir = await Directory.systemTemp.createTemp('outbox_legacy');
      addTearDown(() => tempDir.delete(recursive: true));
      final databasePath = p.join(tempDir.path, 'outbox.db');

      final creator = SqliteOutboxStore(
        databasePath: databasePath,
        sqfliteFactory: databaseFactoryFfi,
      );
      await creator.initialize();
      await creator.close();
      await writeLegacyRow(databasePath);
      return databasePath;
    }

    test('صف قديم محفوظ على القرص يُقرأ كما هو ويُحجز بلا دليل بشري', () async {
      final databasePath = await databaseWithLegacyRow();

      final reader = SqliteOutboxStore(
        databasePath: databasePath,
        sqfliteFactory: databaseFactoryFfi,
      );
      await reader.initialize();
      addTearDown(reader.close);

      final commands = await reader.allCommands(accountA);
      expect(commands, hasLength(1));
      expect(commands.single.type, CommandType.startIrrigationSession);
      expect(commands.single.commandId, 'legacy-command-1');
      expect(commands.single.payload, legacyPayload);
      expect(
        commands.single.payload.containsKey('p_planned_duration_minutes'),
        isFalse,
      );

      final original = commands.single;
      final transport = FakeCommandTransport();
      final engine = SyncEngine(store: reader, transport: transport);
      await engine.run(accountA);
      await engine.run(accountA);

      expect(transport.requests, isEmpty);
      final saved = (await reader.allCommands(accountA)).single;
      expect(saved.localId, 'legacy-local-1');
      expect(saved.commandId, original.commandId);
      expect(saved.occurredAt, original.occurredAt);
      expect(saved.createdLocalAt, original.createdLocalAt);
      expect(saved.payload, legacyPayload);
      expect(saved.localContext, original.localContext);
      expect(saved.status, CommandStatus.pending);
      expect(saved.retryCount, 0);
      expect(
        await reader.readBundle(
          accountA,
          'command.q137.hold.v1.${saved.localId}',
        ),
        'originUnresolved',
      );
      expect(
        await reader.readBundle(
          accountA,
          'command.human_intent.v1.${saved.localId}',
        ),
        isNull,
      );
    });

    test('إعادة تشغيل الحلقة بعد القبول لا تنفّذ الأمر ثانية', () async {
      final databasePath = await databaseWithLegacyRow();

      final reader = SqliteOutboxStore(
        databasePath: databasePath,
        sqfliteFactory: databaseFactoryFfi,
      );
      await reader.initialize();
      addTearDown(reader.close);

      final original = (await reader.allCommands(accountA)).single;
      await recordTestHumanAction(reader, original);
      final transport = FakeCommandTransport();
      final engine = SyncEngine(store: reader, transport: transport);
      final first = await engine.run(accountA);
      expect(first.confirmed, 1);
      expect(transport.requests, hasLength(1));
      final second = await engine.run(accountA);
      expect(second.attempted, 0);

      expect(transport.requests, hasLength(1));
      expect(transport.executionCount, 1);
      final saved = (await reader.allCommands(accountA)).single;
      expect(saved.status, CommandStatus.confirmed);
      expect(saved.localId, original.localId);
      expect(saved.commandId, original.commandId);
      expect(saved.occurredAt, original.occurredAt);
      expect(saved.createdLocalAt, original.createdLocalAt);
      expect(saved.payload, original.payload);
      expect(transport.requests.single.commandId, original.commandId);
      expect(await reader.pendingCommands(accountA), isEmpty);
    });
  });

  group('رفض قاعدة المدة على الخادم', () {
    FakeCommandTransport rejectionTransport() {
      final transport = FakeCommandTransport();
      transport.scheduleFailure(
        CommandType.startAdhocSession,
        const DispatchFailed(
          disposition: FailureDisposition.review,
          code: '23514',
          message:
              '23514: بدء السقي الحر يتطلّب مدة مخطّطة لوجود حجز مؤكّد '
              'قادم على البئر',
        ),
      );
      return transport;
    }

    test('الرفض يصير مراجعة بلا إعادة تلقائية وبلا ربط خادمي', () async {
      final transport = rejectionTransport();
      final (store, coordinator) = await harness(transport);
      final engine = SyncEngine(store: store, transport: transport);

      final envelope = await startWithDuration(coordinator, minutes: 180);
      await engine.run(accountA);
      await engine.run(accountA);

      final command = await store.commandByLocalId(accountA, envelope.localId);
      expect(command!.status, CommandStatus.review);
      expect(command.lastError, contains('23514'));
      expect(command.lastError, contains('مدة مخطّطة'));
      expect(
        await store.mapping(accountA, envelope.localId, EntityKind.session),
        isNull,
      );
      expect(
        transport.requestsFor(CommandType.startAdhocSession),
        hasLength(1),
      );
    });

    test('الأمر المرفوض يبقى محفوظًا ولا يُحذف، والتابعون محجوبون', () async {
      final transport = rejectionTransport();
      final (store, coordinator) = await harness(transport);
      final engine = SyncEngine(store: store, transport: transport);

      final start = await startWithDuration(coordinator, minutes: 180);
      // أمر تابع لأمر البدء: إنهاء يشير إلى جلسته المحلية.
      await coordinator.completeSession(
        accountId: accountA,
        sessionLocalId: start.localId,
        completedAt: DateTime.utc(2026, 10, 3, 7),
      );

      await engine.run(accountA);

      // الرفض حيّ في الطابور، والتابع لم يُرسَل أصلًا.
      final all = await store.allCommands(accountA);
      expect(all.map((command) => command.localId), contains(start.localId));
      final statuses = {for (final c in all) c.localId: c.status};
      expect(statuses[start.localId], CommandStatus.review);
      expect(transport.calledFunctions, ['start_adhoc_session']);
      expect(
        transport.requestsFor(CommandType.completeIrrigationSession),
        isEmpty,
      );
      expect(await store.pendingCommands(accountA), isNotEmpty);
    });

    test('الإكمال التابع يتحرك بعد قبول البدء — لا حظر أبدى', () async {
      final transport = FakeCommandTransport();
      final (store, coordinator) = await harness(transport);
      final engine = SyncEngine(store: store, transport: transport);

      final start = await startWithDuration(coordinator, minutes: 30);
      await coordinator.completeSession(
        accountId: accountA,
        sessionLocalId: start.localId,
        completedAt: DateTime.utc(2026, 10, 3, 7),
      );

      await engine.run(accountA);

      expect(transport.calledFunctions, [
        'start_adhoc_session',
        'complete_irrigation_session',
      ]);
      final completion = transport
          .requestsFor(CommandType.completeIrrigationSession)
          .single;
      // مرجع الجلسة حُلّ إلى المعرّف الخادمي لأمر البدء، لا إلى المحلي.
      final startResult =
          transport.executed[start.commandId] as DispatchAccepted;
      expect(completion.arguments['p_session_id'], startResult.entityId);
    });
  });

  group('الاستعادة المحلية للأمر الجديد', () {
    test('المسقِط يعيد بناء جلسة جارية من أمر start_adhoc_session', () async {
      final (store, coordinator) = await harness(FakeCommandTransport());

      final start = await startWithDuration(coordinator, minutes: 60);

      final projected = await ActiveSessionProjector(store: store)
          .unresolvedSessions(accountA, now: DateTime.utc(2026, 10, 3, 6, 5));

      expect(projected, hasLength(1));
      expect(projected.single.localId, start.localId);
      expect(projected.single.businessState.isActive, isTrue);
      // الجلسة محلية غير مؤكدة: لا نجاح خادمي مُدّعى قبل ثبوته.
      expect(projected.single.serverSessionId, isNull);
      expect(projected.single.pendingCommandCount, greaterThan(0));
    });
  });
}

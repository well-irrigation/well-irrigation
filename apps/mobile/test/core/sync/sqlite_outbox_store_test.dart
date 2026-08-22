/// نفس السلوك على SQL الحقيقي.
///
/// ملف منفصل بنيّة: يحتاج مكتبة sqlite على الحاسب. إن غابت يسقط هذا
/// الملف وحده وتبقى بقية الحزمة صالحة.
///
/// هذه هي البرهنة الفعلية على «العملية لا تُفقد»: الكتابة تذهب إلى ملف
/// على القرص، ويُقرأ الملف من نسخة مخزن جديدة تمامًا — كما يحدث بعد
/// إغلاق التطبيق أو إعادة تشغيل الهاتف.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import 'fake_command_transport.dart';
import 'sync_test_support.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tempDir;
  late String databasePath;
  late SequentialIdGenerator ids;
  final opened = <SqliteOutboxStore>[];

  Future<SqliteOutboxStore> openStore() async {
    final store = SqliteOutboxStore(
      databasePath: databasePath,
      sqfliteFactory: databaseFactoryFfi,
    );

    await store.initialize();
    opened.add(store);

    return store;
  }

  /// مولّد واحد للاختبار كله، لا واحد لكل مستودع.
  ///
  /// المولّد الحقيقي `SecureIdGenerator` لا يعيد معرّفًا سبق توليده
  /// أبدًا. مولّد جديد لكل مستودع يعيد الترقيم من أوله، فيصطدم
  /// بشرط الفرادة على `command_id` — وهو اصطدام لا وجود له في
  /// التطبيق، وقد صنعه الاختبار لا الكود. (فرض الفرادة نفسه مُختبَر
  /// صريحًا في «إدخال معرّف مستخدَم يفشل».)
  OutboxRepository repositoryFor(SqliteOutboxStore store) =>
      OutboxRepository(store: store, idGenerator: ids, clock: clock);

  setUp(() async {
    testNow = DateTime.utc(2026, 8, 22, 6);
    ids = SequentialIdGenerator();
    tempDir = await Directory.systemTemp.createTemp('well_outbox');
    databasePath = p.join(tempDir.path, 'outbox.db');
  });

  tearDown(() async {
    for (final store in opened) {
      await store.close();
    }

    opened.clear();

    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('الحفظ على القرص', () {
    test('الأمر يُقرأ من نسخة مخزن جديدة بعد إغلاق الأولى', () async {
      final first = await openStore();
      final fieldTime = DateTime.utc(2026, 8, 22, 5, 30);
      final command = await repositoryFor(first).enqueue(
        accountId: accountA,
        type: CommandType.recordPayment,
        payload: recordPaymentPayload(farmerWellAccount: 'fwa-1'),
        occurredAt: fieldTime,
        wellId: wellOne,
      );

      await first.close();

      final second = await openStore();
      final rows = await second.pendingCommands(accountA);

      expect(rows, hasLength(1));
      expect(rows.single.localId, command.localId);
      expect(rows.single.commandId, command.commandId);
      expect(rows.single.sequence, command.sequence);
      expect(rows.single.type, CommandType.recordPayment);
      expect(rows.single.wellId, wellOne);
      expect(rows.single.status, CommandStatus.pending);
      expect(rows.single.payload['p_amount_minor'], 250000);
      expect(rows.single.occurredAt, fieldTime);
      expect(rows.single.occurredAt.isUtc, isTrue);
      expect(File(databasePath).existsSync(), isTrue);
    });

    test('عدّاد الترتيب يتابع من حيث انتهى لا من الصفر', () async {
      final first = await openStore();

      await repositoryFor(first).enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(),
        occurredAt: testNow,
      );
      await repositoryFor(first).enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(fullName: 'علي'),
        occurredAt: testNow,
      );
      await first.close();

      final second = await openStore();
      final third = await repositoryFor(second).enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(fullName: 'ناصر'),
        occurredAt: testNow,
      );

      expect(third.sequence, 3);
    });

    test('كل حساب يملك عدّاده', () async {
      final store = await openStore();

      expect(await store.nextSequence(accountA), 1);
      expect(await store.nextSequence(accountA), 2);
      expect(await store.nextSequence(accountB), 1);
    });
  });

  group('فرادة معرّف العملية مفروضة في المخطط', () {
    test('إدخال معرّف مستخدَم يفشل', () async {
      final store = await openStore();
      final envelope = CommandEnvelope(
        localId: 'local-1',
        commandId: 'command-1',
        type: CommandType.createFarmer,
        accountId: accountA,
        sequence: 1,
        occurredAt: testNow,
        createdLocalAt: testNow,
        payload: createFarmerPayload(),
      );

      await store.insert(envelope);

      final clashing = CommandEnvelope(
        localId: 'local-2',
        commandId: 'command-1',
        type: CommandType.createFarmer,
        accountId: accountA,
        sequence: 2,
        occurredAt: testNow,
        createdLocalAt: testNow,
        payload: createFarmerPayload(fullName: 'علي'),
      );

      await expectLater(
        store.insert(clashing),
        throwsA(isA<DuplicateCommandIdException>()),
      );
      expect(await store.allCommands(accountA), hasLength(1));
    });
  });

  group('الحجز الشرطي على SQL', () {
    test('حجز واحد ينجح والثاني يفشل', () async {
      final store = await openStore();
      final command = await repositoryFor(store).enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(),
        occurredAt: testNow,
        wellId: wellOne,
      );

      expect(
        await store.claim(accountA, command.localId, attemptedAt: testNow),
        isTrue,
      );
      expect(
        await store.claim(accountA, command.localId, attemptedAt: testNow),
        isFalse,
      );

      final held = await store.commandByLocalId(accountA, command.localId);

      expect(held!.status, CommandStatus.dispatching);
      expect(held.lastAttemptAt, testNow);
      expect(held.commandId, command.commandId);
    });

    test('حجز أمر بحساب آخر يفشل', () async {
      final store = await openStore();
      final command = await repositoryFor(store).enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(),
        occurredAt: testNow,
        wellId: wellOne,
      );

      expect(
        await store.claim(accountB, command.localId, attemptedAt: testNow),
        isFalse,
      );
    });
  });

  group('انتقالات الحالة تحفظ معرّف العملية', () {
    test('حجز ثم إعادة ثم تأكيد بلا تغيير المعرّف', () async {
      final store = await openStore();
      final command = await repositoryFor(store).enqueue(
        accountId: accountA,
        type: CommandType.recordPayment,
        payload: recordPaymentPayload(farmerWellAccount: 'fwa-1'),
        occurredAt: testNow,
        wellId: wellOne,
      );

      await store.claim(accountA, command.localId, attemptedAt: testNow);
      await store.releaseForRetry(
        accountA,
        command.localId,
        error: 'SocketException',
        attemptedAt: testNow,
      );

      var stored = await store.commandByLocalId(accountA, command.localId);

      expect(stored!.status, CommandStatus.pending);
      expect(stored.retryCount, 1);
      expect(stored.lastError, 'SocketException');
      expect(stored.commandId, command.commandId);
      expect(stored.statusText, 'فشل وستتم إعادة المحاولة');

      advanceClock(const Duration(minutes: 4));
      await store.claim(accountA, command.localId, attemptedAt: testNow);
      await store.markConfirmed(
        accountA,
        command.localId,
        serverResponse: const {'payment_id': 'payment-uuid', 'receipt': 12},
        attemptedAt: testNow,
      );

      stored = await store.commandByLocalId(accountA, command.localId);

      expect(stored!.status, CommandStatus.confirmed);
      expect(stored.commandId, command.commandId);
      expect(stored.retryCount, 1);
      expect(stored.lastError, isNull);
      expect(stored.serverResponse!['payment_id'], 'payment-uuid');
      expect(await store.pendingCommands(accountA), isEmpty);
      expect(await store.allCommands(accountA), hasLength(1));
    });

    test('المراجعة تُخزَّن مع سببها', () async {
      final store = await openStore();
      final command = await repositoryFor(store).enqueue(
        accountId: accountA,
        type: CommandType.pauseIrrigationSession,
        payload: sessionEventPayload(
          session: 'session-uuid',
          extra: const {'p_reason': 'صيانة'},
        ),
        occurredAt: testNow,
        wellId: wellOne,
      );

      await store.markNeedsReview(
        accountA,
        command.localId,
        error: 'P0001: الجلسة مغلقة أصلًا',
        attemptedAt: testNow,
      );

      final stored = await store.commandByLocalId(accountA, command.localId);

      expect(stored!.status, CommandStatus.review);
      expect(stored.statusText, 'يحتاج مراجعة');
      expect(stored.lastError, contains('P0001'));
    });
  });

  group('جدول الربط', () {
    test('يُكتب ويُقرأ ويُحدَّث بلا تكرار', () async {
      final store = await openStore();

      await store.putMapping(
        accountA,
        IdMapping(
          localId: 'local-1',
          kind: EntityKind.farmerWellAccount,
          serverId: 'fwa-uuid',
          resolvedAt: testNow,
          matchedExisting: true,
        ),
      );
      await store.putMapping(
        accountA,
        IdMapping(
          localId: 'local-1',
          kind: EntityKind.farmerWellAccount,
          serverId: 'fwa-uuid',
          resolvedAt: testNow,
        ),
      );

      final mapping = await store.mapping(
        accountA,
        'local-1',
        EntityKind.farmerWellAccount,
      );

      expect(mapping!.serverId, 'fwa-uuid');
      expect(mapping.matchedExisting, isFalse);
      expect(await store.mappings(accountA), hasLength(1));
      expect(await store.mapping(accountA, 'local-1', EntityKind.farm), isNull);
      expect(
        await store.mapping(accountB, 'local-1', EntityKind.farmerWellAccount),
        isNull,
      );
    });

    test('آخر مزامنة ناجحة تُحفظ لكل حساب', () async {
      final store = await openStore();

      expect(await store.lastSuccessfulSyncAt(accountA), isNull);

      await store.setLastSuccessfulSyncAt(accountA, testNow);

      expect(await store.lastSuccessfulSyncAt(accountA), testNow);
      expect(await store.lastSuccessfulSyncAt(accountB), isNull);
    });
  });

  group('عزل الحساب في SQL', () {
    test('أوامر حساب لا تظهر لحساب آخر', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(),
        occurredAt: testNow,
        wellId: wellOne,
      );
      await repository.enqueue(
        accountId: accountB,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(well: wellTwo, fullName: 'ناصر'),
        occurredAt: testNow,
        wellId: wellTwo,
      );

      expect(await store.pendingCommands(accountA), hasLength(1));
      expect(await store.pendingCommands(accountB), hasLength(1));
      expect((await store.pendingCommands(accountA)).single.wellId, wellOne);
    });
  });

  group('الحلقة كاملة فوق SQL', () {
    test('دورة ميدانية بلا شبكة تُرسل مرتَّبة ومحسومة المراجع', () async {
      final store = await openStore();
      final repository = repositoryFor(store);
      final transport = FakeCommandTransport();

      final farmer = await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(),
        occurredAt: DateTime.utc(2026, 8, 22, 4),
        wellId: wellOne,
      );
      final farm = await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarm,
        payload: createFarmPayload(
          farmerWellAccount: repository.referenceTo(farmer).toJson(),
        ),
        occurredAt: DateTime.utc(2026, 8, 22, 4, 10),
        wellId: wellOne,
      );
      final start = await repository.enqueue(
        accountId: accountA,
        type: CommandType.startIrrigationSession,
        payload: startSessionPayload(
          farm: repository.referenceTo(farm).toJson(),
          farmerWellAccount: repository.referenceTo(farmer).toJson(),
        ),
        occurredAt: DateTime.utc(2026, 8, 22, 4, 20),
        wellId: wellOne,
      );
      await repository.enqueue(
        accountId: accountA,
        type: CommandType.completeIrrigationSession,
        payload: sessionEventPayload(
          session: repository.referenceTo(start).toJson(),
        ),
        occurredAt: DateTime.utc(2026, 8, 22, 6, 40),
        wellId: wellOne,
        aggregateLocalId: start.localId,
      );

      // التطبيق مات قبل أي إرسال.
      await store.close();

      final reopened = await openStore();
      final report = await SyncEngine(
        store: reopened,
        transport: transport,
        clock: clock,
      ).run(accountA);

      expect(report.confirmed, 4);
      expect(transport.calledFunctions, [
        'create_farmer',
        'create_farm',
        'start_irrigation_session',
        'complete_irrigation_session',
      ]);

      final farmerId = (await reopened.mapping(
        accountA,
        farmer.localId,
        EntityKind.farmerWellAccount,
      ))!.serverId;

      expect(
        transport
            .lastRequestFor(CommandType.createFarm)
            .arguments['p_farmer_well_account_id'],
        farmerId,
      );
      expect(
        transport
            .lastRequestFor(CommandType.completeIrrigationSession)
            .arguments['p_ended_at'],
        '2026-08-22T06:40:00.000Z',
      );
      expect(await reopened.pendingCommands(accountA), isEmpty);
      expect(await reopened.lastSuccessfulSyncAt(accountA), testNow);

      // معرّفات العمليات لم تتغير عبر كل ذلك.
      final commandIds = (await reopened.allCommands(accountA))
          .map((command) => command.commandId)
          .toSet();

      expect(commandIds, hasLength(4));
      expect(
        transport.requests
            .map((request) => request.arguments[commandIdArgument])
            .toSet(),
        commandIds,
      );
    });
  });
}

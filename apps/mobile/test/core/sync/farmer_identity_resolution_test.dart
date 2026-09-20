@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/farmer_identity_review.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
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

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('farmer_resolution_test_');
    databasePath = p.join(tempDir.path, 'outbox.db');
    ids = SequentialIdGenerator(prefix: 'cmd');
  });

  tearDown(() async {
    for (final store in opened) {
      await store.close();
    }
    opened.clear();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Q-88 Batch 2 Mobile Resolution Tests', () {
    test(
      '1 & 2. requires_resolution becomes review, candidates and dependents survive SQLite reopen',
      () async {
        var store = await openStore();
        var outbox = OutboxRepository(store: store, idGenerator: ids);
        final transport = FakeCommandTransport();
        final engine = SyncEngine(store: store, transport: transport);

        // تسجيل أمر مزارع
        final farmerCmd = await outbox.enqueue(
          accountId: accountA,
          wellId: wellOne,
          type: CommandType.createFarmer,
          occurredAt: testNow,
          payload: {
            'p_well_id': wellOne,
            'p_full_name': 'محمد صالح القاسمي',
            'p_phone': '771234567',
          },
        );

        // تسجيل أرض تابعة وجلسة تابعة
        final farmCmd = await outbox.enqueue(
          accountId: accountA,
          wellId: wellOne,
          type: CommandType.createFarm,
          occurredAt: testNow,
          aggregateLocalId: farmerCmd.localId,
          payload: {
            'p_well_id': wellOne,
            'p_name': 'مزرعة الوادي',
            'p_farmer_well_account_id': outbox.referenceTo(farmerCmd).toJson(),
          },
        );

        await outbox.enqueue(
          accountId: accountA,
          wellId: wellOne,
          type: CommandType.startIrrigationSession,
          occurredAt: testNow,
          aggregateLocalId: farmerCmd.localId,
          payload: {
            'p_well_id': wellOne,
            'p_farm_id': outbox.referenceTo(farmCmd).toJson(),
            'p_farmer_well_account_id': outbox.referenceTo(farmerCmd).toJson(),
            'p_pump_id': 'pump-1',
            'p_energy_source': 'solar',
          },
        );

        // جدولة رد تعارض واشتباه تكرار
        transport.scheduleRawResponse(CommandType.createFarmer, {
          'status': 'requires_resolution',
          'conflict_type': 'suspect_duplicate',
          'message': 'يوجد اشتباه تكرار مع مزارع مسجل',
          'duplicate_candidates': [
            {
              'person_id': 'person-cand-001',
              'public_code': 'P-001',
              'full_name': 'محمد صالح القاسمي',
              'match_level': 'suspect',
              'matched_on': 'name',
            }
          ],
        });

        final report = await engine.run(accountA);
        expect(report.needsReview, 1);
        expect(report.blockedByReview, 2);

        // إغلاق المخزن وفتحه من القرص لمحاكاة إعادة تشغيل التطبيق
        await store.close();
        opened.remove(store);

        store = await openStore();
        outbox = OutboxRepository(store: store, idGenerator: ids);

        final pending = await store.pendingCommands(accountA);
        expect(pending.length, 3);

        final reloadedFarmer = pending.firstWhere(
          (c) => c.localId == farmerCmd.localId,
        );
        expect(reloadedFarmer.status, CommandStatus.review);
        expect(
          reloadedFarmer.serverResponse?['status'],
          'requires_resolution',
        );

        final review = FarmerIdentityReview.fromCommand(reloadedFarmer);
        expect(review, isNotNull);
        expect(review!.fullName, 'محمد صالح القاسمي');
        expect(review.phone, '771234567');
        expect(review.candidates.length, 1);
        expect(review.candidates.first.personId, 'person-cand-001');
        expect(review.candidates.first.publicCode, 'P-001');
        expect(
          review.candidates.first.matchedOnDescription,
          'تشابه في الاسم',
        );
      },
    );

    test('3. review parser rejects malformed candidate payload safely', () {
      final validEnvelope = CommandEnvelope(
        localId: 'loc-1',
        commandId: 'cmd-1',
        type: CommandType.createFarmer,
        accountId: accountA,
        sequence: 1,
        occurredAt: testNow,
        createdLocalAt: testNow,
        status: CommandStatus.review,
        payload: {'p_full_name': 'علي حسن', 'p_well_id': wellOne},
        serverResponse: {
          'status': 'requires_resolution',
          'duplicate_candidates': [
            {
              'person_id': 'p-1',
              'public_code': 'CODE-1',
              'full_name': 'علي حسن',
              'match_level': 'match',
              'matched_on': 'name',
            }
          ],
        },
      );

      expect(FarmerIdentityReview.fromCommand(validEnvelope), isNotNull);

      // 1. حالة ليست requires_resolution
      final invalidStatus = validEnvelope.copyWith(
        serverResponse: {'status': 'conflict'},
      );
      expect(FarmerIdentityReview.fromCommand(invalidStatus), isNull);

      // 2. قائمة المرشحين ليست List
      final notAList = validEnvelope.copyWith(
        serverResponse: {
          'status': 'requires_resolution',
          'duplicate_candidates': 'not_a_list',
        },
      );
      expect(FarmerIdentityReview.fromCommand(notAList), isNull);

      // 3. مرشح غير مكتمل
      final missingFields = validEnvelope.copyWith(
        serverResponse: {
          'status': 'requires_resolution',
          'duplicate_candidates': [
            {'person_id': 'p-1'}, // ناقص full_name, public_code
          ],
        },
      );
      final parsed = FarmerIdentityReview.fromCommand(missingFields);
      expect(parsed, isNotNull);
      expect(parsed!.candidates, isEmpty); // المرشح المشوه يسقط بأمان
    });

    test(
      '4 & 5. use-existing resolution command is durable, independent commandId, and prevents duplicate tap',
      () async {
        final store = await openStore();
        final outbox = OutboxRepository(store: store, idGenerator: ids);
        final coordinator = OfflineSessionCoordinator(
          store: store,
        );

        final farmerCmd = await outbox.enqueue(
          accountId: accountA,
          wellId: wellOne,
          type: CommandType.createFarmer,
          occurredAt: testNow,
          payload: {
            'p_well_id': wellOne,
            'p_full_name': 'أحمد خالد',
            'p_phone': '770000001',
          },
        );

        await store.markNeedsReview(
          accountA,
          farmerCmd.localId,
          error: 'اشتباه تكرار',
          serverResponse: {
            'status': 'requires_resolution',
            'duplicate_candidates': [
              {
                'person_id': 'person-existing-1',
                'public_code': 'P-002',
                'full_name': 'أحمد خالد',
                'match_level': 'suspect',
                'matched_on': 'name',
              }
            ],
          },
          attemptedAt: testNow,
        );

        final reviews = await coordinator.getFarmerIdentityReviews(
          accountA,
          wellId: wellOne,
        );
        expect(reviews.length, 1);
        final review = reviews.first;

        // إدراج أول أمر حسم
        final resolutionCmd = await coordinator.resolveFarmerWithExisting(
          accountId: accountA,
          review: review,
          selectedPersonId: 'person-existing-1',
        );

        expect(
          resolutionCmd.type,
          CommandType.resolveFarmerIdentity,
        );
        expect(resolutionCmd.commandId, isNot(equals(farmerCmd.commandId)));
        expect(resolutionCmd.aggregateLocalId, farmerCmd.localId);
        expect(
          resolutionCmd.payload['p_original_command_id'],
          farmerCmd.commandId,
        );
        expect(
          resolutionCmd.payload['p_resolution_action'],
          'use_existing',
        );
        expect(
          resolutionCmd.payload['p_selected_person_id'],
          'person-existing-1',
        );

        // محاولة تكرار النقر / الإدراج أثناء وجود أمر معلق
        expect(
          () => coordinator.resolveFarmerWithExisting(
            accountId: accountA,
            review: review,
            selectedPersonId: 'person-existing-1',
          ),
          throwsStateError,
        );
      },
    );

    test(
      '6 & 7. only dedicated resolution command can bypass target review; unrelated review aggregate remains blocked',
      () async {
        final store = await openStore();
        final outbox = OutboxRepository(store: store, idGenerator: ids);
        final transport = FakeCommandTransport();
        final engine = SyncEngine(store: store, transport: transport);

        // أمر مزارع أ
        final farmerA = await outbox.enqueue(
          accountId: accountA,
          wellId: wellOne,
          type: CommandType.createFarmer,
          occurredAt: testNow,
          payload: {'p_well_id': wellOne, 'p_full_name': 'مزارع أ'},
        );
        await store.markNeedsReview(
          accountA,
          farmerA.localId,
          error: 'اشتباه',
          serverResponse: {
            'status': 'requires_resolution',
            'duplicate_candidates': [],
          },
          attemptedAt: testNow,
        );

        // أمر مزارع ب
        final farmerB = await outbox.enqueue(
          accountId: accountA,
          wellId: wellOne,
          type: CommandType.createFarmer,
          occurredAt: testNow,
          payload: {'p_well_id': wellOne, 'p_full_name': 'مزارع ب'},
        );
        await store.markNeedsReview(
          accountA,
          farmerB.localId,
          error: 'اشتباه',
          serverResponse: {
            'status': 'requires_resolution',
            'duplicate_candidates': [],
          },
          attemptedAt: testNow,
        );

        // أمر عادي لأصل أ (أرض تابعة لأ)
        await outbox.enqueue(
          accountId: accountA,
          wellId: wellOne,
          type: CommandType.createFarm,
          occurredAt: testNow,
          aggregateLocalId: farmerA.localId,
          payload: {
            'p_well_id': wellOne,
            'p_name': 'أرض أ',
            'p_farmer_well_account_id': outbox.referenceTo(farmerA).toJson(),
          },
        );

        // أمر حسم مخصص لأصل أ وحده
        await outbox.enqueue(
          accountId: accountA,
          wellId: wellOne,
          type: CommandType.resolveFarmerIdentity,
          occurredAt: testNow,
          aggregateLocalId: farmerA.localId,
          payload: {
            'p_well_id': wellOne,
            'p_original_command_id': farmerA.commandId,
            'p_resolution_action': 'use_existing',
            'p_selected_person_id': 'person-a',
          },
        );

        // تشغيل المحرك
        final report = await engine.run(accountA);

        // أمر الحسم نفذ وتأكد
        expect(report.confirmed, greaterThanOrEqualTo(1));
        final executedTypes = transport.requests.map((r) => r.type).toList();
        expect(
          executedTypes.contains(CommandType.resolveFarmerIdentity),
          isTrue,
        );

        // بينما أصل ب بقي محظوراً بالكامل
        final reloadedB = await store.commandByLocalId(
          accountA,
          farmerB.localId,
        );
        expect(reloadedB?.status, CommandStatus.review);
      },
    );

    test(
      '8, 9, 10, 11. resolution writes mapping for ORIGINAL farmer localId, marks original review confirmed, and allows dependent createFarm & startSession',
      () async {
        final store = await openStore();
        final outbox = OutboxRepository(store: store, idGenerator: ids);
        final transport = FakeCommandTransport();
        final engine = SyncEngine(store: store, transport: transport);

        // 1. تسجيل مزارع
        final farmerCmd = await outbox.enqueue(
          accountId: accountA,
          wellId: wellOne,
          type: CommandType.createFarmer,
          occurredAt: testNow,
          payload: {'p_well_id': wellOne, 'p_full_name': 'عمر بن علي'},
        );

        // تحويله لمراجعة
        await store.markNeedsReview(
          accountA,
          farmerCmd.localId,
          error: 'اشتباه',
          serverResponse: {
            'status': 'requires_resolution',
            'duplicate_candidates': [
              {
                'person_id': 'person-omar',
                'public_code': 'P-099',
                'full_name': 'عمر بن علي',
                'match_level': 'suspect',
                'matched_on': 'name',
              }
            ],
          },
          attemptedAt: testNow,
        );

        // 2. أمر أرض تابعة للمزارع الأصلي (سُجلت في الحقل قبل المزامنة)
        final farmCmd = await outbox.enqueue(
          accountId: accountA,
          wellId: wellOne,
          type: CommandType.createFarm,
          occurredAt: testNow,
          aggregateLocalId: farmerCmd.localId,
          payload: {
            'p_well_id': wellOne,
            'p_name': 'أرض عمر',
            'p_farmer_well_account_id': outbox.referenceTo(farmerCmd).toJson(),
          },
        );

        // 3. أمر جلسة تابع للأرض والمزارع (سُجل في الحقل قبل المزامنة)
        final sessionCmd = await outbox.enqueue(
          accountId: accountA,
          wellId: wellOne,
          type: CommandType.startIrrigationSession,
          occurredAt: testNow,
          aggregateLocalId: farmerCmd.localId,
          payload: {
            'p_well_id': wellOne,
            'p_farm_id': outbox.referenceTo(farmCmd).toJson(),
            'p_farmer_well_account_id': outbox.referenceTo(farmerCmd).toJson(),
            'p_pump_id': 'pump-1',
            'p_energy_source': 'diesel',
          },
        );

        // 4. أمر حسم المزارع أُدرج لاحقًا بعد المراجعة البشرية (تسلسل متأخر)
        final resolveCmd = await outbox.enqueue(
          accountId: accountA,
          wellId: wellOne,
          type: CommandType.resolveFarmerIdentity,
          occurredAt: testNow,
          aggregateLocalId: farmerCmd.localId,
          payload: {
            'p_well_id': wellOne,
            'p_original_command_id': farmerCmd.commandId,
            'p_resolution_action': 'use_existing',
            'p_selected_person_id': 'person-omar',
          },
        );

        // جدولة رد الحسم بالمعرّف الكنسي لحساب المزارع
        const canonicalFwaId = 'fwa-canonical-omar-999';
        transport.scheduleRawResponse(CommandType.resolveFarmerIdentity, {
          'status': 'matched_existing',
          'farmer_well_account_id': canonicalFwaId,
          'person_id': 'person-omar',
          'farmer_profile_id': 'fp-omar',
        });

        // تشغيل المحرك
        final report = await engine.run(accountA);
        expect(report.confirmed, 3); // 3 أوامر أُرسلت للخادم (حسم + أرض + جلسة)، والمزارع الأصلي كُتب تأكيده محليًا
        expect(report.needsReview, 0);

        // 8. التحقق من كتابة الربط للأمر الأصلي وليس لأمر الحسم
        final farmerMapping = await store.mapping(
          accountA,
          farmerCmd.localId,
          EntityKind.farmerWellAccount,
        );
        expect(farmerMapping, isNotNull);
        expect(farmerMapping!.serverId, canonicalFwaId);

        final resolutionMapping = await store.mapping(
          accountA,
          resolveCmd.localId,
          EntityKind.farmerWellAccount,
        );
        expect(resolutionMapping, isNull); // أمر الحسم لا يملك ربطًا خاصًا

        // 9. أمر المزارع الأصلي تأكد
        final reloadedFarmer = await store.commandByLocalId(
          accountA,
          farmerCmd.localId,
        );
        expect(reloadedFarmer?.status, CommandStatus.confirmed);

        // 10 & 11. الأوامر التابعة أُرسلت بالمعرفات الكنسية
        final farmReq = transport.lastRequestFor(CommandType.createFarm);
        expect(
          farmReq.arguments['p_farmer_well_account_id'],
          canonicalFwaId,
        );

        // التحقق من التسلسل الحقيقي للأوامر الأربعة
        expect(farmerCmd.sequence, 1);
        expect(farmCmd.sequence, 2);
        expect(sessionCmd.sequence, 3);
        expect(resolveCmd.sequence, 4);

        // التحقق من ترتيب الإرسال الفعلي للخادم: الحسم أولاً ثم فك التوابع المتأخرة
        expect(transport.requests.length, 3);
        expect(transport.requests[0].type, CommandType.resolveFarmerIdentity);
        expect(transport.requests[1].type, CommandType.createFarm);
        expect(transport.requests[2].type, CommandType.startIrrigationSession);

        final sessionReq = transport.lastRequestFor(
          CommandType.startIrrigationSession,
        );
        expect(
          sessionReq.arguments['p_farmer_well_account_id'],
          canonicalFwaId,
        );
        expect(
          sessionReq.arguments['p_farm_id'],
          isNotNull,
        );
      },
    );

    test(
      '12. app death after server resolution but before full local confirmation recovers on retry without duplicate effect',
      () async {
        final store = await openStore();
        final outbox = OutboxRepository(store: store, idGenerator: ids);
        final transport = FakeCommandTransport();
        final engine = SyncEngine(store: store, transport: transport);

        final farmerCmd = await outbox.enqueue(
          accountId: accountA,
          wellId: wellOne,
          type: CommandType.createFarmer,
          occurredAt: testNow,
          payload: {'p_well_id': wellOne, 'p_full_name': 'مزارع صامد'},
        );

        await store.markNeedsReview(
          accountA,
          farmerCmd.localId,
          error: 'اشتباه',
          serverResponse: {
            'status': 'requires_resolution',
            'duplicate_candidates': [],
          },
          attemptedAt: testNow,
        );

        await outbox.enqueue(
          accountId: accountA,
          wellId: wellOne,
          type: CommandType.resolveFarmerIdentity,
          occurredAt: testNow,
          aggregateLocalId: farmerCmd.localId,
          payload: {
            'p_well_id': wellOne,
            'p_original_command_id': farmerCmd.commandId,
            'p_resolution_action': 'use_existing',
            'p_selected_person_id': 'person-samid',
          },
        );

        // محاكاة انقطاع الاتصال بعد تنفيذ الخادم للعملية (swallowAckOnce)
        transport.swallowAckOnce.add(
          CommandType.resolveFarmerIdentity.rpcName,
        );

        // المحاولة الأولى تفشل بشبكة بعد التنفيذ في الخادم
        var report = await engine.run(accountA);
        expect(report.retryScheduled, 1);
        expect(transport.executed.length, 1);

        // المحاولة الثانية تسترد النتيجة السابقة بتطابق تام ودون تنفيذ ثانٍ
        report = await engine.run(accountA);
        expect(report.confirmed, 1);
        expect(transport.executionCount, 1); // لم ينفذ مرتين
      },
    );

    test('17. normal create_farmer created/matched_existing does not regress',
        () async {
      final store = await openStore();
      final outbox = OutboxRepository(store: store, idGenerator: ids);
      final transport = FakeCommandTransport();
      final engine = SyncEngine(store: store, transport: transport);

      // مزارع طبيعي ينشأ بنجاح
      await outbox.enqueue(
        accountId: accountA,
        wellId: wellOne,
        type: CommandType.createFarmer,
        occurredAt: testNow,
        payload: {'p_well_id': wellOne, 'p_full_name': 'مزارع جديد تمامًا'},
      );

      final report = await engine.run(accountA);
      expect(report.confirmed, 1);
      expect(report.needsReview, 0);

      final mappings = await store.mappings(accountA);
      expect(mappings.length, 1);
      expect(mappings.first.kind, EntityKind.farmerWellAccount);
    });
  });
}

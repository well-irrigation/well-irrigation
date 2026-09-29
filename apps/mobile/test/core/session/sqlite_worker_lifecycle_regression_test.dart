/// اختبارات الانحدار لدورة حياة SQLite وتأكيد إنهاء الجلسة بعد تنظيف العامل — ق-129.
///
/// يثبت الاختباران الحاسمان:
/// 1. إتمام الجلسة (COMPLETE) بنجاح بعد إغلاق اتصال العامل الخلفي (WorkManager cleanup)
///    دون حدوث DatabaseException(database_closed 2).
/// 2. قدرة OfflineSessionCoordinator على الشفاء الذاتي عند إغلاق المخزن وإعادة استدعاء العمليات.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tempDir;
  late String dbPath;
  final storesToClose = <SqliteOutboxStore>[];
  final coordinatorsToDispose = <OfflineSessionCoordinator>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sqlite_worker_regr_test');
    dbPath = p.join(tempDir.path, 'outbox.db');
  });

  tearDown(() async {
    for (final coordinator in coordinatorsToDispose) {
      coordinator.dispose();
    }
    coordinatorsToDispose.clear();

    for (final store in storesToClose) {
      await store.close();
    }
    storesToClose.clear();

    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Q-129 Regression Tests: COMPLETE After Worker Cleanup & Coordinator Self-Heal', () {
    test(
      '5. COMPLETE AFTER WORKER CLEANUP: إنهاء الجلسة ينجح ويكتب في SQLite بعد إغلاق اتصال العامل الخلفي',
      () async {
        // المقدمة (Foreground): تستخدم الإعداد الافتراضي singleInstance = true
        final storeForeground = SqliteOutboxStore(
          databasePath: dbPath,
          singleInstance: true,
          sqfliteFactory: databaseFactoryFfi,
        );
        storesToClose.add(storeForeground);
        await storeForeground.initialize();

        final coordinator = OfflineSessionCoordinator(store: storeForeground);
        coordinatorsToDispose.add(coordinator);
        await coordinator.initialize();

        // 1. المقدمة تبدأ جلسة سقي محلياً (START command)
        final start = await coordinator.startSession(
          accountId: 'owner-1',
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );
        expect(start.type, CommandType.startIrrigationSession);

        // 2. العامل الخلفي (WorkManager) يفتح اتصالاً مستقلاً (singleInstance = false)
        final storeWorker = SqliteOutboxStore(
          databasePath: dbPath,
          singleInstance: false,
          sqfliteFactory: databaseFactoryFfi,
        );
        storesToClose.add(storeWorker);
        await storeWorker.initialize();

        // العامل يقرأ أمر البدء ويؤكده ويكتب الـ mapping
        final pending = await storeWorker.pendingCommands('owner-1');
        expect(pending.any((c) => c.localId == start.localId), isTrue);

        await storeWorker.markConfirmed(
          'owner-1',
          start.localId,
          serverResponse: {'p_session_id': 'srv-session-777'},
          attemptedAt: DateTime.now(),
        );
        await storeWorker.putMapping(
          'owner-1',
          IdMapping(
            localId: start.localId,
            kind: EntityKind.session,
            serverId: 'srv-session-777',
            resolvedAt: DateTime.now(),
          ),
        );

        // 3. انتهاء مهمة العامل وتشغيل تنظيف الاتصال: finally { await store?.close(); }
        await storeWorker.close();
        expect(storeWorker.isOpen, isFalse);

        // 4. الاختبار الحاسم: محاولة المقدمة إنهاء الجلسة بعد تنظيف العامل
        // قبل الإصلاح: كان هذا يفشل بـ DatabaseException(database_closed 2)
        final completeEnvelope = await coordinator.completeSession(
          accountId: 'owner-1',
          sessionLocalId: start.localId,
        );

        expect(completeEnvelope, isNotNull);
        expect(completeEnvelope.type, CommandType.completeIrrigationSession);
        expect(completeEnvelope.aggregateLocalId, start.localId);

        // التحقق من الحفظ الدائم لأمر الإكمال في SQLite
        final all = await storeForeground.allCommands('owner-1');
        expect(all.length, 2);
        expect(all.map((c) => c.type), containsAll([
          CommandType.startIrrigationSession,
          CommandType.completeIrrigationSession,
        ]));
      },
    );

    test(
      '4. COORDINATOR SELF-HEAL: المنسق يعيد فتح المخزن ويستأنف العمليات بنجاح إذا أُغلق المخزن تحته',
      () async {
        final store = SqliteOutboxStore(
          databasePath: dbPath,
          singleInstance: true,
          sqfliteFactory: databaseFactoryFfi,
        );
        storesToClose.add(store);
        await store.initialize();

        final coordinator = OfflineSessionCoordinator(store: store);
        coordinatorsToDispose.add(coordinator);
        await coordinator.initialize();

        // بدء جلسة
        final start = await coordinator.startSession(
          accountId: 'owner-2',
          wellId: 'well-2',
          pumpId: 'pump-2',
          farmId: 'farm-2',
          farmerAccountId: 'farmer-2',
          energySource: 'diesel',
        );

        // إغلاق المخزن تحته لمحاكاة فقدان المقبض
        await store.close();
        expect(store.isOpen, isFalse);

        // استدعاء عملية على المنسق (unresolvedSessions ينادي initialize() داخلياً)
        final unresolved = await coordinator.unresolvedSessions('owner-2');
        expect(store.isOpen, isTrue); // شُفي وأعيد فتحه تلقائياً
        expect(unresolved.length, 1);
        expect(unresolved.first.localId, start.localId);

        // عملية كتابة لاحقة تنجح أيضاً
        final pause = await coordinator.pauseSession(
          accountId: 'owner-2',
          sessionLocalId: start.localId,
          reason: 'operator_pause',
        );
        expect(pause.type, CommandType.pauseIrrigationSession);

        final all = await store.allCommands('owner-2');
        expect(all.length, 2);
      },
    );
  });
}

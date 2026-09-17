/// اختبار التأكيد الخارجي لقاعدة البيانات SQLite — ق-129.
///
/// يثبت عمل اتصالين مستقلين بملف SQLite نفسه:
/// اتصال المقدمة A واتصال عامل الخلفية B (محاكاة لـ WorkManager).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tempDir;
  late String dbPath;
  final stores = <SqliteOutboxStore>[];
  final coordinators = <OfflineSessionCoordinator>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ext_sqlite_confirm_test');
    dbPath = p.join(tempDir.path, 'outbox.db');
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
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('External SQLite Confirmation Tests (Goal 2 — ق-129)', () {
    test(
      'اتصالان مستقلان: تحديث WorkManager في اتصال منفصل يظهر فور استدعاء freshProjectActiveSession',
      () async {
        // اتصال A (واجهة المستخدم / المقدمة)
        final storeA = SqliteOutboxStore(
          databasePath: dbPath,
          sqfliteFactory: databaseFactoryFfi,
        );
        stores.add(storeA);
        await storeA.initialize();

        final coordinatorA = OfflineSessionCoordinator(store: storeA);
        coordinators.add(coordinatorA);
        await coordinatorA.initialize();

        // A. بدء جلسة سقي محلياً عبر المنسق A
        final start = await coordinatorA.startSession(
          accountId: 'owner-1',
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        // B. إسقاط المقدمة يظهر كـ localOnly / pending (غير مزامن)
        final initialProjection = await coordinatorA.projectActiveSession(
          accountId: 'owner-1',
          wellId: 'well-1',
        );
        expect(initialProjection, isNotNull);
        expect(initialProjection!.syncState, isNot(SessionSyncState.synced));

        // C. اتصال B يمثل WorkManager يعمل في عازل منفصل على نفس الملف
        final storeB = SqliteOutboxStore(
          databasePath: dbPath,
          sqfliteFactory: databaseFactoryFfi,
        );
        stores.add(storeB);
        await storeB.initialize();

        // تأكيد أمر البدء وكتابة الـ mapping عبر اتصال B
        await storeB.markConfirmed(
          'owner-1',
          start.localId,
          serverResponse: {'p_session_id': 'srv-sess-999'},
          attemptedAt: DateTime.now(),
        );
        await storeB.putMapping(
          'owner-1',
          IdMapping(
            localId: start.localId,
            kind: EntityKind.session,
            serverId: 'srv-sess-999',
            resolvedAt: DateTime.now(),
          ),
        );

        // D. لا نرسل أي إشعار لـ coordinatorA عبر الذاكرة

        // E. استدعاء freshProjectActiveSession من coordinatorA
        final refreshed = await coordinatorA.freshProjectActiveSession(
          accountId: 'owner-1',
          wellId: 'well-1',
        );

        // F. النتيجة تصبح synced ومعرّف الخادم محسوم
        expect(refreshed, isNotNull);
        expect(refreshed!.syncState, SessionSyncState.synced);
        expect(refreshed.serverSessionId, 'srv-sess-999');
      },
    );

    test(
      'تأكيد أمر البدء في اتصال B بدون mapping يُبقي الحالة غير مزامنة (pending)',
      () async {
        final storeA = SqliteOutboxStore(
          databasePath: dbPath,
          sqfliteFactory: databaseFactoryFfi,
        );
        stores.add(storeA);
        await storeA.initialize();

        final coordinatorA = OfflineSessionCoordinator(store: storeA);
        coordinators.add(coordinatorA);
        await coordinatorA.initialize();

        final start = await coordinatorA.startSession(
          accountId: 'owner-1',
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        final storeB = SqliteOutboxStore(
          databasePath: dbPath,
          sqfliteFactory: databaseFactoryFfi,
        );
        stores.add(storeB);
        await storeB.initialize();

        // تأكيد الأمر فقط دون كتابة mapping
        await storeB.markConfirmed(
          'owner-1',
          start.localId,
          serverResponse: {'p_session_id': 'srv-sess-999'},
          attemptedAt: DateTime.now(),
        );

        final refreshed = await coordinatorA.freshProjectActiveSession(
          accountId: 'owner-1',
          wellId: 'well-1',
        );

        expect(refreshed, isNotNull);
        expect(refreshed!.syncState, isNot(SessionSyncState.synced));
        expect(refreshed.syncState, SessionSyncState.pending);
      },
    );

    test(
      'تأكيد البدء مع mapping لكن مع وجود أمر فرعي معلق يُبقي الحالة غير مزامنة',
      () async {
        final storeA = SqliteOutboxStore(
          databasePath: dbPath,
          sqfliteFactory: databaseFactoryFfi,
        );
        stores.add(storeA);
        await storeA.initialize();

        final coordinatorA = OfflineSessionCoordinator(store: storeA);
        coordinators.add(coordinatorA);
        await coordinatorA.initialize();

        final start = await coordinatorA.startSession(
          accountId: 'owner-1',
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        // إضافة أمر إيقاف معلق في الواجهة
        await coordinatorA.pauseSession(
          accountId: 'owner-1',
          sessionLocalId: start.localId,
          reason: 'operator_pause',
        );

        final storeB = SqliteOutboxStore(
          databasePath: dbPath,
          sqfliteFactory: databaseFactoryFfi,
        );
        stores.add(storeB);
        await storeB.initialize();

        // B أكد البدء وكتب الـ mapping فقط، لكن أمر الإيقاف ما زال معلقاً
        await storeB.markConfirmed(
          'owner-1',
          start.localId,
          serverResponse: {'p_session_id': 'srv-sess-999'},
          attemptedAt: DateTime.now(),
        );
        await storeB.putMapping(
          'owner-1',
          IdMapping(
            localId: start.localId,
            kind: EntityKind.session,
            serverId: 'srv-sess-999',
            resolvedAt: DateTime.now(),
          ),
        );

        final refreshed = await coordinatorA.freshProjectActiveSession(
          accountId: 'owner-1',
          wellId: 'well-1',
        );

        expect(refreshed, isNotNull);
        expect(refreshed!.syncState, isNot(SessionSyncState.synced));
      },
    );
  });
}

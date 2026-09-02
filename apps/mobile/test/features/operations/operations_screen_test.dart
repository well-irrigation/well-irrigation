import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';
import '../../support/identity_fixture.dart';

void main() {
  group('OperationsScreen Widget Tests (UX-07 / UX-08 / UX-10 / ق-89 / ق-114)', () {
    /// مفتاح صاحب الطابور: نفسه في الكتابة والقراءة، وإلا ظهرت الجلسة
    /// الجارية كأنها غير موجودة (ق-113).
    const accountId = 'owner-1';

    const well = WellSummary(
      id: 'well-1',
      tenantId: 'tenant-1',
      name: 'بئر الخير الرئيسي',
      status: 'active',
      roles: ['owner', 'operator'],
    );

    late InMemoryOutboxStore store;
    late OfflineSessionCoordinator coordinator;

    setUp(() async {
      store = InMemoryOutboxStore();
      coordinator = OfflineSessionCoordinator(store: store);
      await coordinator.initialize();
    });

    tearDown(() {
      coordinator.dispose();
    });

    testWidgets('1. عرض شاشة التشغيل ومحددات السقي والعداد المباشر', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: OperationsScreen(
            identity: testIdentity(accountId: accountId, wells: const [well]),
            coordinator: coordinator,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('بيانات ومحددات السقي'), findsOneWidget);
      expect(find.text('المزارع المستفيد *'), findsOneWidget);
      expect(find.text('الأرض الزراعية *'), findsOneWidget);
      expect(find.text('بدء جلسة سقي جديدة'), findsOneWidget);
      expect(find.text('لا توجد جلسة سقي نشطة'), findsOneWidget);
    });

    testWidgets('2. استعادة الجلسة الجارية تلقائياً فور فتح الشاشة (Active Session Recovery)', (tester) async {
      // محاكاة وجود جلسة جارية تم بدؤها قبل فتح الشاشة
      final now = DateTime.now().subtract(const Duration(minutes: 15));
      await coordinator.startSession(
        accountId: accountId,
        wellId: 'well-1',
        pumpId: 'pump-1',
        farmId: 'farm-1',
        farmerAccountId: 'farmer-1',
        energySource: 'طاقة شمسية',
        startedAt: now,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: OperationsScreen(
            identity: testIdentity(accountId: accountId, wells: const [well]),
            coordinator: coordinator,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // التحقق من أن الشاشة استعادت الجلسة فوراً
      expect(find.text('جلسة سقي جارية الآن'), findsOneWidget);
      expect(find.text('إنهاء واحتساب'), findsOneWidget);
      expect(find.text('إيقاف مؤقت'), findsOneWidget);
      expect(find.text('مزامن'), findsOneWidget);

    });
  });
}

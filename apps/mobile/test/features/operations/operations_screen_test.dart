import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/widgets/smart_lookup_field.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';

import '../../support/identity_fixture.dart';

class _LayoutOperationsRepository extends OperationsRepository {
  const _LayoutOperationsRepository();

  @override
  Future<List<Pump>> fetchPumps(String wellId) async => const [
    Pump(
      id: 'pump-1',
      wellId: 'well-1',
      name: 'المضخة الرئيسية ذات الاسم الطويل للاختبار الميداني',
      publicCode: 'PUMP-0001-LONG',
    ),
  ];

  @override
  Future<List<FarmerAccount>> fetchFarmers(
    String wellId, {
    String? query,
  }) async => const [
    FarmerAccount(
      id: 'farmer-1',
      fullName: 'مزارع اختباري',
      publicCode: 'F-001',
    ),
  ];
}

void main() {
  group(
    'OperationsScreen Widget Tests (UX-07 / UX-08 / UX-10 / ق-89 / ق-114)',
    () {
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

      testWidgets('1. عرض شاشة التشغيل ومحددات السقي والعداد المباشر', (
        tester,
      ) async {
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

      testWidgets(
        '2. استعادة الجلسة الجارية تلقائياً فور فتح الشاشة (Active Session Recovery)',
        (tester) async {
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
                identity: testIdentity(
                  accountId: accountId,
                  wells: const [well],
                ),
                coordinator: coordinator,
              ),
            ),
          );
          await tester.pumpAndSettle();

          // التحقق من أن الشاشة استعادت الجلسة فوراً وفق ق-129
          expect(find.text('جاري'), findsOneWidget);
          expect(find.text('تفاصيل الجلسة الحالية'), findsOneWidget);
          expect(find.text('إنهاء الجلسة'), findsOneWidget);
          expect(find.text('إيقاف مؤقت'), findsOneWidget);
          expect(find.text('محفوظ على الجهاز'), findsOneWidget);
          expect(find.text('مزامن'), findsNothing);
        },
      );

      testWidgets('3. اسم المضخة الطويل يلتزم بعرض الحقل', (tester) async {
        tester.view.physicalSize = const Size(800, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Directionality(
              textDirection: TextDirection.rtl,
              child: OperationsScreen(
                identity: testIdentity(
                  accountId: accountId,
                  wells: const [well],
                ),
                coordinator: coordinator,
                repository: const _LayoutOperationsRepository(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final dropdown = tester.widget<DropdownButton<Pump>>(
          find.descendant(
            of: find.byType(DropdownButtonFormField<Pump>),
            matching: find.byType(DropdownButton<Pump>),
          ),
        );
        expect(dropdown.isExpanded, isTrue);
        expect(tester.takeException(), isNull);
      });

      testWidgets('4. لوحة البحث تبقى سليمة عند ظهور لوحة المفاتيح', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(720, 1600);
        tester.view.devicePixelRatio = 2;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetViewInsets();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SmartLookupField<FarmerAccount>(
                label: 'المزارع المستفيد *',
                hintText: 'ابحث باسم المزارع',
                itemLabel: (farmer) => farmer.fullName,
                searchFunction:
                    const _LayoutOperationsRepository().fetchFarmers,
                onChanged: (_) {},
              ),
            ),
          ),
        );
        await tester.tap(find.byType(InkWell));
        await tester.pumpAndSettle();
        expect(find.text('اختيار المزارع المستفيد *'), findsOneWidget);

        tester.view.viewInsets = const FakeViewPadding(bottom: 600);
        await tester.pumpAndSettle();

        expect(find.text('اختيار المزارع المستفيد *'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    },
  );
}

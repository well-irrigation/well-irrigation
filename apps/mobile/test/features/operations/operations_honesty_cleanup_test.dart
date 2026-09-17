/// اختبارات الصدق المرئي ونظافة واجهة التشغيل — F3 و F4 (ق-129).
///
/// F3: صدق نص المبلغ في حالة الخمول (غياب الجلسة لا يدعي بانتظار المزامنة)
/// F4: تسميات مصادر الطاقة أثناء التوقف المؤقت وتحويل المصدر المعلق
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';

import '../../support/identity_fixture.dart';

class _FakePriceRepository extends WellManagementRepository {
  _FakePriceRepository({this.schedule});

  final PriceScheduleModel? schedule;

  @override
  Future<PriceScheduleModel?> fetchActivePriceSchedule(
    String wellId, {
    DateTime? at,
  }) async {
    return schedule;
  }
}

class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository({
    this.farmers = const [],
    this.farms = const [],
    this.pumps = const [],
  });

  final List<FarmerAccount> farmers;
  final List<Farm> farms;
  final List<Pump> pumps;

  @override
  Future<List<FarmerAccount>> fetchFarmers(String wellId, {String? query}) async =>
      farmers;

  @override
  Future<List<Farm>> fetchFarms(String wellId, {String? farmerAccountId}) async =>
      farms;

  @override
  Future<List<Pump>> fetchPumps(String wellId) async => pumps;
}

void main() {
  const accountId = 'owner-1';
  const well = WellSummary(
    id: 'well-1',
    tenantId: 'tenant-1',
    name: 'بئر الخير الرئيسي',
    status: 'active',
    roles: ['owner', 'operator'],
  );

  const testFarmer = FarmerAccount(
    id: 'farmer-1',
    fullName: 'مزارع الخير',
    publicCode: 'F-001',
  );

  const testFarm = Farm(
    id: 'farm-1',
    wellId: 'well-1',
    name: 'مزرعة الوادي',
    farmerAccountId: 'farmer-1',
  );

  const testPump = Pump(
    id: 'pump-1',
    wellId: 'well-1',
    name: 'المضخة الرئيسية',
    publicCode: 'PUMP-01',
  );

  final testSchedule = PriceScheduleModel(
    id: 'sched-1',
    wellId: 'well-1',
    name: 'تعرفة 2026',
    status: 'active',
    effectiveFrom: DateTime(2026, 1, 1),
    rules: [
      PriceRuleModel(
        id: 'rule-solar',
        energySource: 'solar',
        hourlyRateMinor: 3500, // 3500 ريال / ساعة
      ),
      PriceRuleModel(
        id: 'rule-well-diesel',
        energySource: 'well_diesel',
        hourlyRateMinor: 5000, // 5000 ريال / ساعة
      ),
    ],
  );

  late InMemoryOutboxStore store;
  late OfflineSessionCoordinator coordinator;
  late _FakeOperationsRepository opsRepo;

  setUp(() async {
    store = InMemoryOutboxStore();
    coordinator = OfflineSessionCoordinator(store: store);
    await coordinator.initialize();

    opsRepo = _FakeOperationsRepository(
      farmers: [testFarmer],
      farms: [testFarm],
      pumps: [testPump],
    );
  });

  tearDown(() {
    coordinator.dispose();
  });

  Widget buildScreen({
    PriceScheduleModel? schedule,
    DateTime Function()? clock,
  }) {
    return MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: OperationsScreen(
          identity: testIdentity(accountId: accountId, wells: const [well]),
          coordinator: coordinator,
          repository: opsRepo,
          priceRepository: _FakePriceRepository(schedule: schedule),
          clock: clock,
        ),
      ),
    );
  }

  group('F3 — صدق نص المبلغ في حالة الخمول والمبالغ النشطة (ق-129)', () {
    testWidgets('1. غياب الجلسة النشطة: الواجهة لا تحتوي على «التكلفة بانتظار المزامنة»', (
      tester,
    ) async {
      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      expect(find.text('لا توجد جلسة سقي نشطة'), findsOneWidget);
      expect(find.text(SessionStateText.pricingPending), findsNothing);
    });

    testWidgets('2. غياب الجلسة النشطة: الواجهة تعرض النص الصادق «لا مبلغ لجلسة نشطة»', (
      tester,
    ) async {
      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      expect(find.text('المبلغ: '), findsOneWidget);
      expect(find.text('لا مبلغ لجلسة نشطة'), findsOneWidget);
    });

    testWidgets(
      '3. جلسة نشطة بمبلغ غير محسوم (بلا تسعيرة): يظهر نص «التكلفة بانتظار المزامنة»',
      (tester) async {
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        // فتح الشاشة بلا جدول تسعير
        await tester.pumpWidget(buildScreen(schedule: null));
        await tester.pumpAndSettle();

        expect(find.text('تفاصيل الجلسة الحالية'), findsOneWidget);
        expect(find.text('جاري'), findsOneWidget);
        expect(find.text(SessionStateText.pricingPending), findsOneWidget);
        expect(find.text('لا مبلغ لجلسة نشطة'), findsNothing);
      },
    );

    testWidgets('4. جلسة نشطة بمبلغ معروف: المبلغ والتفقيط يظهران كما هما دون تغيير', (
      tester,
    ) async {
      final t0 = DateTime.utc(2026, 9, 15, 8);
      coordinator.updatePricing([
        PricingSnapshot(
          hourlyRateMinor: 3500,
          effectiveFrom: DateTime(2026, 1, 1),
          energySource: 'solar',
          ruleId: 'rule-solar',
        ),
      ]);

      await coordinator.startSession(
        accountId: accountId,
        wellId: 'well-1',
        pumpId: 'pump-1',
        farmId: 'farm-1',
        farmerAccountId: 'farmer-1',
        energySource: 'solar',
        startedAt: t0,
      );

      // ساعة كاملة = 3,500 ريال
      await tester.pumpWidget(
        buildScreen(
          schedule: testSchedule,
          clock: () => t0.add(const Duration(hours: 1)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('3,500'), findsOneWidget);
      expect(find.text('ريال'), findsWidgets);
      expect(find.text('ثلاثة آلاف وخمسمائة ريال'), findsOneWidget);
      expect(find.text(SessionStateText.pricingPending), findsNothing);
      expect(find.text('لا مبلغ لجلسة نشطة'), findsNothing);
    });
  });

  group('F4 — تسميات مصدر الطاقة في تفاصيل الجلسة أثناء الإيقاف والتحويل (ق-129)', () {
    testWidgets('5. جلسة جارية (running): التسمية في التفاصيل هي «مصدر الطاقة الحالي»', (
      tester,
    ) async {
      await coordinator.startSession(
        accountId: accountId,
        wellId: 'well-1',
        pumpId: 'pump-1',
        farmId: 'farm-1',
        farmerAccountId: 'farmer-1',
        energySource: 'solar',
      );

      await tester.pumpWidget(buildScreen(schedule: testSchedule));
      await tester.pumpAndSettle();

      expect(find.text('تفاصيل الجلسة الحالية'), findsOneWidget);
      expect(find.text('مصدر الطاقة الحالي:'), findsOneWidget);
      expect(find.textContaining('طاقة شمسية ☀️'), findsOneWidget);
    });

    testWidgets(
      '6. جلسة موقوفة بلا تغيير مصدر معلق: التسمية هي «آخر مصدر طاقة مستخدم»',
      (tester) async {
        final start = await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        await coordinator.pauseSession(
          accountId: accountId,
          sessionLocalId: start.localId,
          reason: 'operator_pause',
        );

        await tester.pumpWidget(buildScreen(schedule: testSchedule));
        await tester.pumpAndSettle();

        expect(find.text('توقف مؤقت'), findsOneWidget);
        expect(find.text('آخر مصدر طاقة مستخدم:'), findsOneWidget);
        expect(find.text('مصدر الطاقة الحالي:'), findsNothing);
        expect(find.text('مصدر الطاقة عند الاستئناف:'), findsNothing);
        expect(find.textContaining('طاقة شمسية ☀️'), findsOneWidget);
      },
    );

    testWidgets(
      '7-9. جلسة موقوفة + تحويل معلق: تسمية التفاصيل «مصدر الطاقة عند الاستئناف» والشارة العلوية دون مساس بالفوترة',
      (tester) async {
        final t0 = DateTime.utc(2026, 9, 15, 8);
        coordinator.updatePricing([
          PricingSnapshot(
            hourlyRateMinor: 3500,
            effectiveFrom: DateTime(2026, 1, 1),
            energySource: 'solar',
            ruleId: 'rule-solar',
          ),
          PricingSnapshot(
            hourlyRateMinor: 5000,
            effectiveFrom: DateTime(2026, 1, 1),
            energySource: 'well_diesel',
            ruleId: 'rule-well-diesel',
          ),
        ]);

        final start = await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
          startedAt: t0,
        );

        // إيقاف مؤقت بعد 10 دقائق
        await coordinator.pauseSession(
          accountId: accountId,
          sessionLocalId: start.localId,
          reason: 'operator_pause',
          pausedAt: t0.add(const Duration(minutes: 10)),
        );

        // فتح الشاشة
        await tester.pumpWidget(
          buildScreen(
            schedule: testSchedule,
            clock: () => t0.add(const Duration(minutes: 15)),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('توقف مؤقت'), findsOneWidget);

        // إجراء تحويل الطاقة إلى ديزل البئر عبر الزر
        final switchBtn = find.text('تحويل مصدر الطاقة');
        await tester.ensureVisible(switchBtn);
        await tester.tap(switchBtn);
        await tester.pumpAndSettle();

        await tester.tap(find.text('ديزل البئر'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('تأكيد التحويل'));
        await tester.pumpAndSettle();

        // 7. صف التفاصيل يعرض صراحة: «مصدر الطاقة عند الاستئناف:»
        expect(find.text('مصدر الطاقة عند الاستئناف:'), findsOneWidget);
        expect(find.text('مصدر الطاقة الحالي:'), findsNothing);
        expect(find.text('آخر مصدر طاقة مستخدم:'), findsNothing);

        // 8. القيمة المعروضة تعكس المصدر المرتقب (ديزل البئر)
        expect(find.textContaining('ديزل البئر'), findsWidgets);
        expect(find.textContaining('⛽'), findsWidgets);

        // 9. الشارة العلوية تعرض «عند الاستئناف: ديزل البئر» كما هي
        expect(find.textContaining('عند الاستئناف: ديزل البئر'), findsOneWidget);

        // والعداد مجمد على 10 دقائق (لم يتغير)
        expect(find.text('00:10:00'), findsOneWidget);
      },
    );
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/compact_energy_selector.dart';

import '../../support/identity_fixture.dart';

/// مستودع تسعير مُتحكَّم به: يُعيد ما يُعيده العقد أو يفشل مثله، ويعدّ
/// النداءات ليُقاس أن «إعادة المحاولة» قراءة جديدة لا تجميل شاشة.
class _FakePriceRepository extends WellManagementRepository {
  _FakePriceRepository({this.schedule, this.failure});

  final PriceScheduleModel? schedule;
  final Object? failure;
  int calls = 0;

  @override
  Future<PriceScheduleModel?> fetchActivePriceSchedule(
    String wellId, {
    DateTime? at,
  }) async {
    calls += 1;
    final error = failure;
    if (error != null) throw error;
    return schedule;
  }
}

/// منسّق يسجّل ما تُسلِّمه الشاشة من لقطات تسعير، ليُقاس أن مصدر مال
/// المُسقط هو الجدول الساري وحده.
class _RecordingCoordinator extends OfflineSessionCoordinator {
  _RecordingCoordinator({super.store});

  final List<List<PricingSnapshot>> pricingUpdates = [];

  @override
  void updatePricing(List<PricingSnapshot> snapshots) {
    pricingUpdates.add(snapshots);
    super.updatePricing(snapshots);
  }
}

class _DeferredPriceRepository extends WellManagementRepository {
  final requests = <String, Completer<PriceScheduleModel?>>{};

  @override
  Future<PriceScheduleModel?> fetchActivePriceSchedule(
    String wellId, {
    DateTime? at,
  }) => requests.putIfAbsent(wellId, Completer.new).future;
}

class _DeferredOperationsRepository extends OperationsRepository {
  final requests = <String, Completer<List<Pump>>>{};

  @override
  Future<List<Pump>> fetchPumps(String wellId) =>
      requests.putIfAbsent(wellId, Completer.new).future;
}

PriceScheduleModel _schedule(List<PriceRuleModel> rules) => PriceScheduleModel(
  id: 'sched-092',
  wellId: 'well-1',
  name: 'تعرفة 2026',
  status: 'active',
  effectiveFrom: DateTime(2026, 1, 1),
  rules: rules,
);

/// تسعيرة شاشة التشغيل تأتي من `api.get_active_price_schedule` وحده
/// (م-41D6 / ق-99 / القرار 341).
///
/// كانت الشاشة تكتب سعرين في مصدرها — 3500 للشمسي و5000 لـ«ديزل» واحدة
/// تجمع مصدرين مختلفَي السعر — فيرى المشغّل مستحقًّا وسندًا بمبلغ لم
/// يُسعّره جدول البئر، ويُرسل إلى القاعدة رمز مصدر لا تقبله.
void main() {
  /// مفتاح صاحب العملية في هذا الاختبار: الشاشة تكتب في الطابور بمفتاح
  /// هويتها، فلو خالف مفتاح القراءة ظهرت الجلسة كأنها غير موجودة.
  const accountId = 'owner-1';

  const well = WellSummary(
    id: 'well-1',
    tenantId: 'tenant-1',
    name: 'بئر الخير الرئيسي',
    status: 'active',
    roles: ['owner', 'operator'],
  );

  const solarRule = PriceRuleModel(
    id: 'rule-solar',
    energySource: 'solar',
    hourlyRateMinor: 4200,
  );
  const wellDieselRule = PriceRuleModel(
    id: 'rule-well-diesel',
    energySource: 'well_diesel',
    hourlyRateMinor: 6100,
  );

  /// ديزل المزارع بتسعير الوقود: لا سعر ساعي أصلًا، وهذه حالة مشروعة.
  const farmerDieselRule = PriceRuleModel(
    id: 'rule-farmer-diesel',
    energySource: 'farmer_diesel',
    dieselPricingModel: 'fuel_based',
    fuelPricePerLiterMinor: 1400,
  );

  /// المنسّق يُبنى في `setUp` خارج جسم الاختبار: مؤقّته الدوري حقيقي لا
  /// `FakeTimer`، وإلا اعترض إطار الاختبار على مؤقّت معلّق بعد التخلص.
  late _RecordingCoordinator coordinator;

  Future<void> startActiveSession() async {
    await coordinator.startSession(
      accountId: accountId,
      wellId: 'well-1',
      pumpId: 'pump-1',
      farmId: 'farm-1',
      farmerAccountId: 'farmer-1',
      energySource: 'solar',
      startedAt: DateTime.now().subtract(const Duration(minutes: 30)),
    );
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    required _FakePriceRepository repo,
    required OfflineSessionCoordinator coordinator,
    DateTime Function()? clock,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OperationsScreen(
          identity: testIdentity(accountId: accountId, wells: const [well]),
          coordinator: coordinator,
          priceRepository: repo,
          clock: clock,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() async {
    coordinator = _RecordingCoordinator(store: InMemoryOutboxStore());
    await coordinator.initialize();
  });

  tearDown(() {
    coordinator.dispose();
  });

  testWidgets('1. الأسعار المعروضة هي أسعار العقد لا أسعار مكتوبة في العميل', (
    tester,
  ) async {
    final repo = _FakePriceRepository(
      schedule: _schedule(const [solarRule, wellDieselRule]),
    );
    await pumpScreen(tester, repo: repo, coordinator: coordinator);

    final selector = find.byType(CompactEnergySelector);
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();

    expect(find.text('طاقة شمسية'), findsWidgets);
    expect(find.text('ديزل البئر'), findsWidgets);
    expect(find.text('4,200 ريال / ساعة'), findsOneWidget);
    expect(find.text('6,100 ريال / ساعة'), findsOneWidget);

    // السعران القديمان لم يبقَ لهما أثر، و«ديزل شامل» الجامعة لمصدرين زالت.
    expect(find.textContaining('3,500'), findsNothing);
    expect(find.textContaining('5,000'), findsNothing);
    expect(find.textContaining('ديزل شامل'), findsNothing);

    // خيارات المصدر مصادر القاعدة الثلاثة: المصدر قرار تشغيلي، فمصدر لا
    // يُسعّره الجدول يبقى قابلًا للاختيار وسعره يُعلن غيابه.
    expect(find.text('ديزل المزارع'), findsWidgets);
    expect(find.text('التسعيرة غير متوفرة'), findsOneWidget);
    expect(repo.calls, 1);
  });

  testWidgets('2. قاعدة بلا سعر ساعي تُعلن الغياب ولا تُسلَّم للمُسقط', (
    tester,
  ) async {
    final repo = _FakePriceRepository(
      schedule: _schedule(const [solarRule, farmerDieselRule]),
    );
    await pumpScreen(tester, repo: repo, coordinator: coordinator);

    final selector = find.byType(CompactEnergySelector);
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();

    expect(find.text('ديزل المزارع'), findsWidgets);
    // اثنان بلا سعر: قاعدة ديزل المزارع بتسعير الوقود، وديزل البئر بلا قاعدة.
    expect(find.text('التسعيرة غير متوفرة'), findsNWidgets(2));

    // اللقطات المُسلَّمة للمُسقط قاعدة واحدة: الأخرى بلا سعر فتبقى المقاطع
    // «بانتظار المزامنة» بدل أن تُسعَّر بصفر.
    expect(coordinator.pricingUpdates, hasLength(1));
    final snapshots = coordinator.pricingUpdates.single;
    expect(snapshots, hasLength(1));
    expect(snapshots.single.energySource, 'solar');
    expect(snapshots.single.hourlyRateMinor, 4200);
    expect(snapshots.single.ruleId, 'rule-solar');
  });

  testWidgets('3. غياب الجدول الساري يُعرض كغياب ولا يُخمَّن سعر', (
    tester,
  ) async {
    final repo = _FakePriceRepository();
    await pumpScreen(tester, repo: repo, coordinator: coordinator);

    expect(
      find.textContaining('لا جدول تسعير ساري لهذا البئر'),
      findsOneWidget,
    );
    expect(find.textContaining('ريال / ساعة'), findsNothing);
    expect(coordinator.pricingUpdates.single, isEmpty);

    final selector = find.byType(CompactEnergySelector);
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();

    // غياب السعر لا يسحب أزرار المصدر: الخادم لا يطلب سعرًا من العميل
    // لبدء الجلسة، فمنع البدء هنا منعٌ لعمل مصرَّح به.
    expect(find.text('طاقة شمسية'), findsWidgets);
    expect(find.text('ديزل البئر'), findsWidgets);
    expect(find.text('ديزل المزارع'), findsWidgets);
    expect(find.text('التسعيرة غير متوفرة'), findsNWidgets(3));
  });

  testWidgets('استجابات البئر القديمة لا تستبدل مضخات وتسعير البئر الحالي', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const well2 = WellSummary(
      id: 'well-2',
      tenantId: 'tenant-1',
      name: 'البئر الثانية',
      status: 'active',
      roles: ['owner'],
    );
    final prices = _DeferredPriceRepository();
    final operations = _DeferredOperationsRepository();

    var activeWell = well;
    late StateSetter rebuildHost;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuildHost = setState;
            return OperationsScreen(
              identity: testIdentity(
                accountId: accountId,
                wells: const [well, well2],
                activeWell: activeWell,
              ),
              coordinator: coordinator,
              repository: operations,
              priceRepository: prices,
            );
          },
        ),
      ),
    );
    await tester.pump();

    rebuildHost(() => activeWell = well2);
    await tester.pump();

    operations.requests['well-2']!.complete(const [
      Pump(
        id: 'pump-2',
        wellId: 'well-2',
        name: 'مضخة البئر الثانية',
        publicCode: 'INTERNAL-2',
        status: 'maintenance',
      ),
    ]);
    prices.requests['well-2']!.complete(
      PriceScheduleModel(
        id: 'schedule-2',
        wellId: 'well-2',
        name: 'تسعير 2',
        status: 'active',
        effectiveFrom: DateTime(2026),
        rules: const [
          PriceRuleModel(
            id: 'rule-2',
            energySource: 'solar',
            hourlyRateMinor: 2222,
          ),
        ],
      ),
    );
    await tester.pump();

    operations.requests['well-1']!.complete(const [
      Pump(
        id: 'pump-1',
        wellId: 'well-1',
        name: 'مضخة البئر الأولى',
        publicCode: 'INTERNAL-1',
      ),
    ]);
    prices.requests['well-1']!.complete(
      PriceScheduleModel(
        id: 'schedule-1',
        wellId: 'well-1',
        name: 'تسعير 1',
        status: 'active',
        effectiveFrom: DateTime(2026),
        rules: const [
          PriceRuleModel(
            id: 'rule-1',
            energySource: 'solar',
            hourlyRateMinor: 1111,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('مضخة البئر الثانية'), findsOneWidget);
    expect(find.textContaining('تحت الصيانة'), findsOneWidget);
    expect(find.text('مضخة البئر الأولى'), findsNothing);
    expect(find.textContaining('INTERNAL-'), findsNothing);
    expect(coordinator.pricingUpdates, hasLength(1));
    expect(coordinator.pricingUpdates.single.single.hourlyRateMinor, 2222);
  });

  testWidgets('4. فشل قراءة التسعيرة يُعلن، و«إعادة المحاولة» قراءة جديدة', (
    tester,
  ) async {
    final repo = _FakePriceRepository(
      failure: StateError('Supabase client is unavailable'),
    );
    await pumpScreen(tester, repo: repo, coordinator: coordinator);

    expect(find.textContaining('تعذر قراءة التسعيرة السارية'), findsOneWidget);
    expect(find.textContaining('ريال / ساعة'), findsNothing);
    expect(coordinator.pricingUpdates.single, isEmpty);

    final retry = find.text('إعادة المحاولة');
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();

    expect(repo.calls, 2);
  });

  testWidgets('5. المستحق الحيّ بلا تسعيرة نصٌّ معتمد لا صفر', (tester) async {
    final repo = _FakePriceRepository();
    await startActiveSession();

    await pumpScreen(tester, repo: repo, coordinator: coordinator);

    expect(find.text(SessionStateText.running), findsOneWidget);
    expect(find.text(SessionStateText.pricingPending), findsOneWidget);
    expect(find.textContaining('0 ريال'), findsNothing);

    // رمز المصدر يُعرض بالاسم المعتمد لا بالرمز الخام ولا بنصّ مُخترع.
    expect(find.textContaining('طاقة شمسية'), findsWidgets);
  });

  testWidgets('6. رفض 42501 حالة صلاحية معلنة لا فشل ولا منع تشغيل', (
    tester,
  ) async {
    // `price.manage` للمالك وحده (هجرة 091) بينما `session.start` للمشغل،
    // و`ops.start_irrigation_session` لا تأخذ سعرًا — فالمشغل يشغّل بلا
    // تسعيرة، ويُسعّر الخادم المقطع عند المزامنة.
    final repo = _FakePriceRepository(
      failure: PostgrestException(
        message: 'قراءة التسعير متاحة لمن يملك صلاحية إدارة الأسعار',
        code: '42501',
      ),
    );
    await pumpScreen(tester, repo: repo, coordinator: coordinator);

    expect(
      find.textContaining('التسعيرة السارية متاحة لمن يملك إدارة الأسعار'),
      findsOneWidget,
    );

    // ليست فشلًا: لا نصّ فشل ولا زرّ إعادة محاولة لصلاحية لن تتغير بالتكرار.
    expect(find.textContaining('تعذر قراءة التسعيرة السارية'), findsNothing);
    expect(find.text('إعادة المحاولة'), findsNothing);

    // ولا سعر مُخمَّن، ومنتقي الطاقة يتيح الخيارات الثلاثة.
    expect(find.textContaining('ريال / ساعة'), findsNothing);

    final selector = find.byType(CompactEnergySelector);
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();

    expect(find.text('طاقة شمسية'), findsWidgets);
    expect(find.text('ديزل البئر'), findsWidgets);
    expect(find.text('ديزل المزارع'), findsWidgets);
    expect(coordinator.pricingUpdates.single, isEmpty);
  });

  testWidgets('7. FIN-001 يعرض وينهي الجلسة المختلطة بمجموع المقاطع', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final t0 = DateTime.utc(2026, 9, 15, 6);
    final now = t0.add(const Duration(seconds: 2451));
    const solar = PriceRuleModel(
      id: 'solar-5000',
      energySource: 'solar',
      hourlyRateMinor: 5000,
    );
    const diesel = PriceRuleModel(
      id: 'diesel-10000',
      energySource: 'well_diesel',
      hourlyRateMinor: 10000,
    );
    coordinator.updatePricing([
      PricingSnapshot(
        hourlyRateMinor: 5000,
        effectiveFrom: t0,
        energySource: 'solar',
      ),
      PricingSnapshot(
        hourlyRateMinor: 10000,
        effectiveFrom: t0,
        energySource: 'well_diesel',
      ),
    ]);
    final session = await coordinator.startSession(
      accountId: accountId,
      wellId: 'well-1',
      pumpId: 'pump-1',
      farmId: 'farm-1',
      farmerAccountId: 'farmer-1',
      energySource: 'solar',
      startedAt: t0,
    );
    await coordinator.changeEnergySource(
      accountId: accountId,
      sessionLocalId: session.localId,
      newEnergySource: 'well_diesel',
      changedAt: t0.add(const Duration(seconds: 2386)),
    );

    await pumpScreen(
      tester,
      repo: _FakePriceRepository(schedule: _schedule(const [solar, diesel])),
      coordinator: coordinator,
      clock: () => now,
    );

    expect(find.text('3,493'), findsOneWidget);
    expect(find.text('6,808'), findsNothing);

    final end = find.text('إنهاء الجلسة');
    await tester.ensureVisible(end);
    await tester.tap(end);
    await tester.pumpAndSettle();

    expect(find.text('3,493'), findsWidgets);
    expect(find.text('تأكيد الإنهاء'), findsOneWidget);

    await tester.tap(find.text('تأكيد الإنهاء'));
    await tester.pumpAndSettle();

    expect(find.text('3,493'), findsWidgets);
    expect(find.text('منتهي'), findsOneWidget);
    expect(find.textContaining('سعر الساعة ('), findsNothing);
  });
}

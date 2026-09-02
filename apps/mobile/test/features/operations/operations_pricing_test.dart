import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';

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
      accountId: OfflineSessionCoordinator.placeholderAccountKey,
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
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OperationsScreen(
          wellName: 'بئر الخير الرئيسي',
          wellId: 'well-1',
          wells: const [well],
          coordinator: coordinator,
          priceRepository: repo,
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

  testWidgets('1. الأسعار المعروضة هي أسعار العقد لا أسعار مكتوبة في العميل',
      (tester) async {
    final repo = _FakePriceRepository(
      schedule: _schedule(const [solarRule, wellDieselRule]),
    );
    await pumpScreen(tester, repo: repo, coordinator: coordinator);

    expect(find.text('طاقة شمسية ☀️'), findsOneWidget);
    expect(find.text('ديزل البئر ⛽'), findsOneWidget);
    expect(find.text('4,200 ريال / ساعة'), findsOneWidget);
    expect(find.text('6,100 ريال / ساعة'), findsOneWidget);

    // السعران القديمان لم يبقَ لهما أثر، و«ديزل شامل» الجامعة لمصدرين زالت.
    expect(find.textContaining('3,500'), findsNothing);
    expect(find.textContaining('5,000'), findsNothing);
    expect(find.textContaining('ديزل شامل'), findsNothing);

    // خيارات المصدر مصادر القاعدة الثلاثة: المصدر قرار تشغيلي، فمصدر لا
    // يُسعّره الجدول يبقى قابلًا للاختيار وسعره يُعلن غيابه.
    expect(find.text('ديزل المزارع ⛽'), findsOneWidget);
    expect(find.text('التسعيرة غير متوفرة'), findsOneWidget);
    expect(repo.calls, 1);
  });

  testWidgets('2. قاعدة بلا سعر ساعي تُعلن الغياب ولا تُسلَّم للمُسقط',
      (tester) async {
    final repo = _FakePriceRepository(
      schedule: _schedule(const [solarRule, farmerDieselRule]),
    );
    await pumpScreen(tester, repo: repo, coordinator: coordinator);

    expect(find.text('ديزل المزارع ⛽'), findsOneWidget);
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

  testWidgets('3. غياب الجدول الساري يُعرض كغياب ولا يُخمَّن سعر',
      (tester) async {
    final repo = _FakePriceRepository();
    await pumpScreen(tester, repo: repo, coordinator: coordinator);

    expect(
      find.textContaining('لا جدول تسعير ساري لهذا البئر'),
      findsOneWidget,
    );
    expect(find.textContaining('ريال / ساعة'), findsNothing);
    expect(coordinator.pricingUpdates.single, isEmpty);

    // غياب السعر لا يسحب أزرار المصدر: الخادم لا يطلب سعرًا من العميل
    // لبدء الجلسة، فمنع البدء هنا منعٌ لعمل مصرَّح به.
    expect(find.text('طاقة شمسية ☀️'), findsOneWidget);
    expect(find.text('ديزل البئر ⛽'), findsOneWidget);
    expect(find.text('ديزل المزارع ⛽'), findsOneWidget);
    expect(find.text('التسعيرة غير متوفرة'), findsNWidgets(3));
  });

  testWidgets('4. فشل قراءة التسعيرة يُعلن، و«إعادة المحاولة» قراءة جديدة',
      (tester) async {
    final repo = _FakePriceRepository(
      failure: StateError('Supabase client is unavailable'),
    );
    await pumpScreen(tester, repo: repo, coordinator: coordinator);

    expect(
      find.textContaining('تعذر قراءة التسعيرة السارية'),
      findsOneWidget,
    );
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

    expect(find.text('جلسة سقي جارية الآن'), findsOneWidget);
    expect(find.text(SessionStateText.pricingPending), findsOneWidget);
    expect(find.textContaining('0 ريال'), findsNothing);

    // رمز المصدر يُعرض بالاسم المعتمد لا بالرمز الخام ولا بنصّ مُخترع.
    expect(find.text('طاقة شمسية'), findsOneWidget);
  });

  testWidgets('6. رفض 42501 حالة صلاحية معلنة لا فشل ولا منع تشغيل',
      (tester) async {
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

    // ولا سعر مُخمَّن، والأزرار الثلاثة قائمة مع مصدر مختار.
    expect(find.textContaining('ريال / ساعة'), findsNothing);
    expect(find.text('طاقة شمسية ☀️'), findsOneWidget);
    expect(find.text('ديزل البئر ⛽'), findsOneWidget);
    expect(find.text('ديزل المزارع ⛽'), findsOneWidget);
    expect(coordinator.pricingUpdates.single, isEmpty);
  });
}

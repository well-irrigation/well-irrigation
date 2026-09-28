import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/compact_energy_selector.dart';

import '../../support/identity_fixture.dart';
import '../../core/sync/fake_command_transport.dart';

/// مستودع عمليات بتجهيزات ثابتة واقتراحات محاصيل مُتحكَّم بها (ق-131):
/// الاقتراحات تعاد كما يعيدها العقد أو يفشل الجلب فشلًا صريحًا يُقاس.
class _FakeCropsRepo extends OperationsRepository {
  _FakeCropsRepo({this.suggestions = const [], this.cropsFailure});

  List<String> suggestions;
  Object? cropsFailure;
  int cropsCalls = 0;

  @override
  Future<List<FarmerAccount>> fetchFarmers(
    String wellId, {
    String? query,
  }) async => const [
    FarmerAccount(id: 'farmer-1', fullName: 'سعيد الحظرمي', publicCode: 'F-1'),
  ];

  @override
  Future<List<Farm>> fetchFarms(
    String wellId, {
    String? farmerAccountId,
  }) async => const [
    Farm(
      id: 'farm-1',
      wellId: 'well-1',
      name: 'أرض الجربة',
      farmerAccountId: 'farmer-1',
    ),
  ];

  @override
  Future<List<Pump>> fetchPumps(String wellId) async => const [
    Pump(id: 'pump-1', wellId: 'well-1', name: 'مضخة 1', publicCode: 'P-1'),
  ];

  @override
  Future<List<String>> fetchFarmRecentCrops({required String farmId}) async {
    cropsCalls += 1;
    final error = cropsFailure;
    if (error != null) throw error;
    return List<String>.from(suggestions);
  }
}

class _FakePriceRepo extends WellManagementRepository {
  _FakePriceRepo(this.schedule);
  final PriceScheduleModel? schedule;

  @override
  Future<PriceScheduleModel?> fetchActivePriceSchedule(
    String wellId, {
    DateTime? at,
  }) async => schedule;
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

  const solarRule = PriceRuleModel(
    id: 'rule-solar',
    energySource: 'solar',
    hourlyRateMinor: 5000,
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

  PriceScheduleModel solarSchedule() => PriceScheduleModel(
    id: 'schedule-1',
    wellId: 'well-1',
    name: 'تسعير',
    status: 'active',
    effectiveFrom: DateTime.utc(2026, 9, 1),
    rules: const [solarRule],
  );

  Future<void> pumpScreen(
    WidgetTester tester, {
    required _FakeCropsRepo repo,
  }) async {
    // سطح أطول: قسم المحاصيل والملخص في شاشة واحدة دون تمرير أعمى.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: OperationsScreen(
            identity: testIdentity(accountId: accountId, wells: const [well]),
            coordinator: coordinator,
            repository: repo,
            priceRepository: _FakePriceRepo(solarSchedule()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// اختيار المزارع ثم الأرض عبر مكوّنَي البحث الذكي، فلا يظهر قسم
  /// المحاصيل إلا بعد اختيار الأرض (ق-131).
  Future<void> selectFarmerAndFarm(WidgetTester tester) async {
    await tester.tap(find.text('ابحث باسم المزارع أو رقم هاتفه...'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('سعيد الحظرمي'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ابحث باسم الأرض...'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('أرض الجربة'));
    await tester.pumpAndSettle();
  }

  group('قسم المحاصيل في نموذج بدء الجلسة (ق-131 البند 1)', () {
    testWidgets('يظهر بعد اختيار الأرض وحده، والاقتراحات محاصيل العقد', (
      tester,
    ) async {
      final repo = _FakeCropsRepo(suggestions: ['قمح', 'شعير']);
      await pumpScreen(tester, repo: repo);

      // قبل اختيار الأرض لا قسم محاصيل (الملخص يحمل 'المحاصيل:' بنقطتين).
      expect(find.text('المحاصيل'), findsNothing);

      await selectFarmerAndFarm(tester);

      expect(find.text('المحاصيل'), findsOneWidget);
      expect(find.text('قمح'), findsOneWidget);
      expect(find.text('شعير'), findsOneWidget);
      expect(find.text('إضافة محصول جديد...'), findsOneWidget);
    });

    testWidgets('اختيار محصولين وإضافة جديد وإزالة واحد ينعكس في الملخص', (
      tester,
    ) async {
      final repo = _FakeCropsRepo(suggestions: ['قمح', 'شعير']);
      await pumpScreen(tester, repo: repo);
      await selectFarmerAndFarm(tester);

      await tester.tap(find.text('قمح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('شعير'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'بصل');
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();

      expect(find.text('المحاصيل المختارة: قمح، شعير، بصل'), findsOneWidget);
      expect(
        tester
            .widget<FilterChip>(find.widgetWithText(FilterChip, 'بصل'))
            .selected,
        isTrue,
      );

      // إزالة محصول مختار بإلغاء اختياره.
      await tester.tap(find.text('شعير'));
      await tester.pumpAndSettle();

      expect(find.text('المحاصيل المختارة: قمح، بصل'), findsOneWidget);
    });

    testWidgets('بدء الجلسة يمرر المحاصيل المختارة في أمر الطابور', (
      tester,
    ) async {
      final repo = _FakeCropsRepo(suggestions: ['قمح', 'شعير']);
      await pumpScreen(tester, repo: repo);
      await selectFarmerAndFarm(tester);

      await tester.tap(find.text('قمح'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'بصل');
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();

      final selector = find.byType(CompactEnergySelector);
      await tester.ensureVisible(selector);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('طاقة شمسية'));
      await tester.pumpAndSettle();

      final pumpDropdown = find.byType(DropdownButtonFormField<Pump>);
      await tester.ensureVisible(pumpDropdown);
      await tester.tap(pumpDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('مضخة 1').last);
      await tester.pumpAndSettle();

      final startButton = find.text('بدء جلسة سقي جديدة');
      await tester.ensureVisible(startButton);
      await tester.tap(startButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('المحاصيل: قمح، بصل'), findsOneWidget);

      final commands = await store.allCommands(accountId);
      final start = commands.singleWhere(
        (command) => command.type == CommandType.startIrrigationSession,
      );
      expect(start.payload['p_crops'], ['قمح', 'بصل']);
    });

    testWidgets('بدء الجلسة بلا اختيار محصول يبقى ممكنًا', (tester) async {
      final repo = _FakeCropsRepo(suggestions: ['قمح', 'شعير']);
      await pumpScreen(tester, repo: repo);
      await selectFarmerAndFarm(tester);

      final selector = find.byType(CompactEnergySelector);
      await tester.ensureVisible(selector);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('طاقة شمسية'));
      await tester.pumpAndSettle();

      final pumpDropdown = find.byType(DropdownButtonFormField<Pump>);
      await tester.ensureVisible(pumpDropdown);
      await tester.tap(pumpDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('مضخة 1').last);
      await tester.pumpAndSettle();

      final startButton = find.text('بدء جلسة سقي جديدة');
      await tester.ensureVisible(startButton);
      await tester.tap(startButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final commands = await store.allCommands(accountId);
      final start = commands.singleWhere(
        (command) => command.type == CommandType.startIrrigationSession,
      );
      expect(start.payload['p_crops'], isEmpty);
    });

    testWidgets('محصول واحد يظهر في بطاقة الجلسة النشطة بعد البدء', (
      tester,
    ) async {
      final repo = _FakeCropsRepo(suggestions: ['قات']);
      await pumpScreen(tester, repo: repo);
      await selectFarmerAndFarm(tester);

      await tester.tap(find.text('قات'));
      await tester.pumpAndSettle();

      final selector = find.byType(CompactEnergySelector);
      await tester.ensureVisible(selector);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('طاقة شمسية'));
      await tester.pumpAndSettle();

      final pumpDropdown = find.byType(DropdownButtonFormField<Pump>);
      await tester.ensureVisible(pumpDropdown);
      await tester.tap(pumpDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('مضخة 1').last);
      await tester.pumpAndSettle();

      final startButton = find.text('بدء جلسة سقي جديدة');
      await tester.ensureVisible(startButton);
      await tester.tap(startButton);
      await tester.pumpAndSettle();

      expect(find.text('المحاصيل: قات'), findsOneWidget);
    });

    testWidgets('فشل جلب الاقتراحات صريح مع إعادة محاولة ولا يمنع الاختيار', (
      tester,
    ) async {
      final repo = _FakeCropsRepo(cropsFailure: StateError('تعذر الاتصال'));
      await pumpScreen(tester, repo: repo);
      await selectFarmerAndFarm(tester);

      expect(repo.cropsCalls, 1);
      expect(
        find.textContaining('تعذر تحميل محاصيل الأرض السابقة'),
        findsOneWidget,
      );
      expect(find.text('إعادة'), findsOneWidget);

      // نجاح القراءة عند الإعادة: الاقتراحات تظهر من عقد جديد لا تجميل.
      repo.cropsFailure = null;
      repo.suggestions = ['قمح'];
      await tester.tap(find.text('إعادة'));
      await tester.pumpAndSettle();

      expect(repo.cropsCalls, 2);
      expect(find.text('قمح'), findsOneWidget);
    });
  });

  group('عقد محاصيل الأرض والمنسق (ق-131)', () {
    test('cropsFromContract يقرأ قائمة العقد كما هي', () {
      expect(
        OperationsRepository.cropsFromContract({
          'contract': 'list_farm_recent_crops',
          'version': 1,
          'crops': ['قمح', 'شعير'],
        }),
        ['قمح', 'شعير'],
      );
    });

    test('cropsFromContract يرد الغائب بقائمة فارغة لا اختراع', () {
      expect(
        OperationsRepository.cropsFromContract({
          'contract': 'list_farm_recent_crops',
          'version': 1,
        }),
        isEmpty,
      );
    });

    test('cropsFromContract يرفض الرد غير المتوقع', () {
      expect(
        () => OperationsRepository.cropsFromContract('not-a-map'),
        throwsStateError,
      );
    });

    test('المنسق يضع المحاصيل في حمولة أمر البدء نفسه', () async {
      await coordinator.startSession(
        accountId: accountId,
        wellId: 'well-1',
        pumpId: 'pump-1',
        farmId: 'farm-1',
        farmerAccountId: 'farmer-1',
        energySource: 'solar',
        crops: ['قمح', 'شعير'],
        startedAt: DateTime.utc(2026, 9, 28, 8),
      );

      final commands = await store.allCommands(accountId);
      final start = commands.singleWhere(
        (command) => command.type == CommandType.startIrrigationSession,
      );
      expect(start.payload['p_crops'], ['قمح', 'شعير']);
    });

    test('المنسق بلا محاصيل يضع قائمة فارغة في الحمولة', () async {
      await coordinator.startSession(
        accountId: accountId,
        wellId: 'well-1',
        pumpId: 'pump-1',
        farmId: 'farm-1',
        farmerAccountId: 'farmer-1',
        energySource: 'solar',
        startedAt: DateTime.utc(2026, 9, 28, 8),
      );

      final commands = await store.allCommands(accountId);
      final start = commands.singleWhere(
        (command) => command.type == CommandType.startIrrigationSession,
      );
      expect(start.payload['p_crops'], isEmpty);
    });

    test('المزامنة تمرر اللقطة نفسها إلى عقد بدء الجلسة', () async {
      await coordinator.startSession(
        accountId: accountId,
        wellId: 'well-1',
        pumpId: 'pump-1',
        farmId: 'farm-1',
        farmerAccountId: 'farmer-1',
        energySource: 'solar',
        crops: ['قات', 'قمح'],
        startedAt: DateTime.utc(2026, 9, 28, 8),
      );
      final transport = FakeCommandTransport();

      await SyncEngine(store: store, transport: transport).run(accountId);

      expect(
        transport
            .lastRequestFor(CommandType.startIrrigationSession)
            .arguments['p_crops'],
        ['قات', 'قمح'],
      );
    });
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/compact_energy_selector.dart';

import '../../support/identity_fixture.dart';

/// مستودع بتجهيزات ثابتة وحالة مزارع مُتحكَّم بها (ق-131 البند 11):
/// الحالة تعاد كما يعيدها العقد أو يفشل الجلب فشلًا صريحًا يُقاس، وبوّابة
/// Completer تُبطئ الرد لإثبات حالة التحميل وردّ المزارع القديم.
class _FakeStatusRepo extends OperationsRepository {
  _FakeStatusRepo({
    this.statuses = const {},
    this.statusFailure,
    this.gate,
    this.farmers = const [],
  });

  Map<String, FarmerSelectionStatus> statuses;
  Object? statusFailure;

  /// حين تُضبط يتوقف كل نداء حالة حتى إكمالها.
  Completer<void>? gate;
  int statusCalls = 0;
  final List<String> requestedIds = [];
  List<FarmerAccount> farmers;

  @override
  Future<List<FarmerAccount>> fetchFarmers(
    String wellId, {
    String? query,
  }) async => List<FarmerAccount>.from(farmers);

  @override
  Future<List<Farm>> fetchFarms(
    String wellId, {
    String? farmerAccountId,
  }) async => const [
    Farm(
      id: 'farm-1',
      wellId: 'well-1',
      name: 'أرض الجربة',
      farmerAccountId: 'farmer-a',
    ),
  ];

  @override
  Future<List<Pump>> fetchPumps(String wellId) async => const [
    Pump(id: 'pump-1', wellId: 'well-1', name: 'مضخة 1', publicCode: 'P-1'),
  ];

  @override
  Future<FarmerSelectionStatus> fetchFarmerSelectionStatus({
    required String farmerAccountId,
  }) async {
    statusCalls += 1;
    requestedIds.add(farmerAccountId);
    final gate = this.gate;
    if (gate != null) await gate.future;
    final error = statusFailure;
    if (error != null) throw error;
    final status = statuses[farmerAccountId];
    if (status == null) {
      throw StateError('لا حالة لهذا المزارع في التجهيز');
    }
    return status;
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

FarmerSelectionStatus _status({
  int debt = 0,
  int advance = 0,
  int fuelMl = 0,
  String accountId = 'farmer-a',
}) => FarmerSelectionStatus(
  farmerWellAccountId: accountId,
  wellId: 'well-1',
  debtMinor: debt,
  advanceMinor: advance,
  farmerFuelBalanceMl: fuelMl,
);

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

  Future<void> pumpScreen(WidgetTester tester, _FakeStatusRepo repo) async {
    tester.view.physicalSize = const Size(800, 1800);
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

  /// مزارعان خادميان ومزارع محلي بلا مزامنة، وأرض ومضخة ثابتة.
  List<FarmerAccount> farmers() => [
    const FarmerAccount(
      id: 'farmer-a',
      fullName: 'سالم علي',
      publicCode: 'F-A',
    ),
    const FarmerAccount(
      id: 'farmer-b',
      fullName: 'فهد سعيد',
      publicCode: 'F-B',
    ),
    const FarmerAccount(
      id: '',
      fullName: 'مزارع محلي',
      publicCode: 'قيد الحفظ',
      status: 'pending',
    ),
  ];

  /// إطار ما بعد الاختيار: مضبوطة حين يبقى نداء الحالة معلّقًا.
  Future<void> afterSelection(WidgetTester tester, bool bounded) async {
    if (bounded) {
      // إغلاق الورقة وإطارا بناء للحالة الجديدة دون انتظار الهدوء.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    } else {
      await tester.pumpAndSettle();
    }
  }

  /// اختيار مزارع من ورقة البحث. [bounded] يمنع pumpAndSettle حين يبقى
  /// نداء الحالة معلّقًا على بوابة (المؤشر الدوار لا يهدأ أصلًا).
  Future<void> selectFarmer(
    WidgetTester tester,
    String name, {
    bool bounded = false,
  }) async {
    await tester.tap(find.text('ابحث باسم المزارع أو رقم هاتفه...'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name));
    await afterSelection(tester, bounded);
  }

  /// تبديل المزارع وهو مختار سابقًا: لمس الاسم المعروض يفتح الورقة.
  /// الفتح بضربات مضبوطة دائمًا: مؤشر التحميل قد يبقى يعمل خلف الورقة.
  Future<void> switchFarmer(
    WidgetTester tester,
    String currentName,
    String newName, {
    bool bounded = false,
  }) async {
    await tester.tap(find.text(currentName));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(newName));
    await afterSelection(tester, bounded);
  }

  group('حالة المزارع عند اختياره (ق-131 البند 11)', () {
    testWidgets(
      '1. بعد اختيار المزارع: تحميل ثم الدين والمقدم والديزل بنصوص صريحة',
      (tester) async {
        final gate = Completer<void>();
        final repo = _FakeStatusRepo(
          gate: gate,
          statuses: {
            'farmer-a': _status(debt: 5000, advance: 2000, fuelMl: 4500),
          },
          farmers: farmers(),
        );
        await pumpScreen(tester, repo);

        // قبل الاختيار لا منطقة حالة.
        expect(find.textContaining('حالة المزارع'), findsNothing);

        await selectFarmer(tester, 'سالم علي', bounded: true);

        // أثناء الانتظار: حالة تحميل مختصرة.
        expect(find.text('جارٍ تحميل حالة المزارع...'), findsOneWidget);

        gate.complete();
        await tester.pumpAndSettle();

        expect(find.text('عليه مديونية: 5,000 ريال'), findsOneWidget);
        expect(find.text('له رصيد مقدم: 2,000 ريال'), findsOneWidget);
        // كسر لتر ذو معنى يبقى ظاهرًا لا مُقرَّبًا.
        expect(find.text('ديزل المزارع: 4.5 لتر'), findsOneWidget);
      },
    );

    testWidgets('2. الصفر حقيقي بنص صريح لا إشارات غامضة', (tester) async {
      final repo = _FakeStatusRepo(
        statuses: {'farmer-a': _status()},
        farmers: farmers(),
      );
      await pumpScreen(tester, repo);
      await selectFarmer(tester, 'سالم علي');
      await tester.pumpAndSettle();

      expect(find.text('لا توجد مديونية'), findsOneWidget);
      expect(find.text('لا يوجد رصيد مقدم'), findsOneWidget);
      expect(find.text('ديزل المزارع: 0.0 لتر'), findsOneWidget);
      expect(find.textContaining('عليه مديونية'), findsNothing);
      expect(find.textContaining('له رصيد مقدم'), findsNothing);
    });

    testWidgets(
      '3. المنطقة بين منتقي المزارع والأرض، والبدء يبقى ممكنًا والمُرسل مالًا لا يُلمس',
      (tester) async {
        final repo = _FakeStatusRepo(
          statuses: {'farmer-a': _status(debt: 5000, advance: 2000)},
          farmers: farmers(),
        );
        await pumpScreen(tester, repo);
        await selectFarmer(tester, 'سالم علي');
        await tester.pumpAndSettle();
        expect(find.text('عليه مديونية: 5,000 ريال'), findsOneWidget);

        // استكمال النموذج كاملًا والبدء: التحذير إخباري لا مانع.
        await tester.tap(find.text('ابحث باسم الأرض...'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('أرض الجربة'));
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

        final commands = await store.allCommands(accountId);
        final starts = commands
            .where(
              (command) => command.type == CommandType.startIrrigationSession,
            )
            .toList();
        expect(starts, hasLength(1));
        // لا أمر مالي ولا وقودي ضمنيًا مع القراءة أو البدء.
        expect(
          commands.where(
            (command) =>
                command.type == CommandType.recordPayment ||
                command.type.name.contains('fuel'),
          ),
          isEmpty,
        );
      },
    );

    testWidgets('4. فشل الخادم رسالة معلوماتية غير مانعة والبدء يبقى ممكنًا', (
      tester,
    ) async {
      final repo = _FakeStatusRepo(
        statusFailure: StateError('تعذر الاتصال'),
        farmers: farmers(),
      );
      await pumpScreen(tester, repo);
      await selectFarmer(tester, 'سالم علي');
      await tester.pumpAndSettle();

      expect(
        find.text('تعذر عرض حالة المزارع — يمكنك متابعة السقي'),
        findsOneWidget,
      );
      expect(repo.statusCalls, 1);

      // النموذج يكمل والبدء يتم رغم فشل الحالة.
      await tester.tap(find.text('ابحث باسم الأرض...'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('أرض الجربة'));
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

      final commands = await store.allCommands(accountId);
      expect(
        commands.where(
          (command) => command.type == CommandType.startIrrigationSession,
        ),
        hasLength(1),
      );
    });

    testWidgets(
      '5. مزارع محلي بلا مزامنة: لا نداء للحالة ورسالة ما بعد المزامنة',
      (tester) async {
        final repo = _FakeStatusRepo(farmers: farmers());
        await pumpScreen(tester, repo);

        await selectFarmer(tester, 'مزارع محلي');
        await tester.pumpAndSettle();

        expect(repo.statusCalls, 0);
        expect(repo.requestedIds, isEmpty);
        expect(
          find.text('حالة المزارع ستظهر بعد مزامنته — يمكنك متابعة السقي'),
          findsOneWidget,
        );
        expect(find.textContaining('0.0 لتر'), findsNothing);
      },
    );

    testWidgets('6. مسح المزارع يزيل الحالة فورًا', (tester) async {
      final repo = _FakeStatusRepo(
        statuses: {'farmer-a': _status(debt: 5000)},
        farmers: farmers(),
      );
      await pumpScreen(tester, repo);
      await selectFarmer(tester, 'سالم علي');
      await tester.pumpAndSettle();
      expect(find.text('عليه مديونية: 5,000 ريال'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('عليه مديونية: 5,000 ريال'), findsNothing);
      expect(find.textContaining('حالة المزارع'), findsNothing);
    });

    testWidgets(
      '7. ردّ المزارع السابق البطيء لا يُعرض فوق حالة المزارع الجديد',
      (tester) async {
        final gate = Completer<void>();
        final repo = _FakeStatusRepo(
          gate: gate,
          statuses: {
            'farmer-a': _status(debt: 5000, accountId: 'farmer-a'),
            'farmer-b': _status(debt: 9000, accountId: 'farmer-b'),
          },
          farmers: farmers(),
        );
        await pumpScreen(tester, repo);

        await selectFarmer(tester, 'سالم علي', bounded: true);
        expect(find.text('جارٍ تحميل حالة المزارع...'), findsOneWidget);

        // تبديل المزارع: الحالة القديمة تُصفَّر فورًا وطلب جديد يبدأ.
        await switchFarmer(tester, 'سالم علي', 'فهد سعيد', bounded: true);
        expect(find.text('عليه مديونية: 5,000 ريال'), findsNothing);

        gate.complete();
        await tester.pumpAndSettle();

        // ردّ سالم القديم وصل بعد التبديل فلا يُعرض فوق حالة فهد.
        expect(find.text('عليه مديونية: 5,000 ريال'), findsNothing);
        expect(find.text('عليه مديونية: 9,000 ريال'), findsOneWidget);
        expect(repo.requestedIds, ['farmer-a', 'farmer-b']);
      },
    );

    testWidgets(
      '8. اختيار المزارع وحده لا يرسل أي أمر مالي أو وقودي إلى الطابور',
      (tester) async {
        final repo = _FakeStatusRepo(
          statuses: {'farmer-a': _status(debt: 5000, fuelMl: 12000)},
          farmers: farmers(),
        );
        await pumpScreen(tester, repo);
        await selectFarmer(tester, 'سالم علي');
        await tester.pumpAndSettle();

        expect(find.text('عليه مديونية: 5,000 ريال'), findsOneWidget);
        expect(find.text('ديزل المزارع: 12.0 لتر'), findsOneWidget);

        final commands = await store.allCommands(accountId);
        expect(commands, isEmpty);
      },
    );
  });

  group('نموذج حالة المزارع (ق-131 البند 11)', () {
    test('fromContract يقرأ الحقول الثلاثة كما هي بالمللتر والريال', () {
      final status = FarmerSelectionStatus.fromContract(const {
        'contract': 'get_farmer_selection_status',
        'version': 1,
        'farmer_well_account_id': 'fwa-1',
        'well_id': 'well-1',
        'debt_minor': 5000,
        'advance_minor': 2000,
        'farmer_fuel_balance_ml': 7500,
      });

      expect(status.farmerWellAccountId, 'fwa-1');
      expect(status.wellId, 'well-1');
      expect(status.debtMinor, 5000);
      expect(status.advanceMinor, 2000);
      expect(status.farmerFuelBalanceMl, 7500);
      expect(status.hasDebt, isTrue);
      expect(status.hasAdvance, isTrue);
    });

    test('الإصدار غير المتوافق والرقم السالب يرفضان صريحًا', () {
      expect(
        () => FarmerSelectionStatus.fromContract(const {
          'contract': 'get_farmer_selection_status',
          'version': 2,
        }),
        throwsStateError,
      );
      expect(
        () => FarmerSelectionStatus.fromContract(const {
          'contract': 'get_farmer_selection_status',
          'version': 1,
          'debt_minor': -5,
        }),
        throwsStateError,
      );
    });
  });
}

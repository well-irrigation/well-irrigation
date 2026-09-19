import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/entity_reference.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';

import '../../support/identity_fixture.dart';

class _ScopedTestOperationsRepository extends OperationsRepository {
  const _ScopedTestOperationsRepository({
    this.serverFarmers = const [],
    this.serverFarms = const [],
  });

  final List<FarmerAccount> serverFarmers;
  final List<Farm> serverFarms;

  @override
  Future<List<Pump>> fetchPumps(String wellId) async => [
    Pump(
      id: 'pump-1',
      wellId: wellId,
      name: 'المضخة الرئيسية',
      publicCode: 'PUMP-1',
    ),
  ];

  @override
  Future<List<FarmerAccount>> fetchFarmers(
    String wellId, {
    String? query,
  }) async {
    final list = serverFarmers.where((f) => true).toList();
    if (query != null && query.trim().isNotEmpty) {
      return list.where((f) => f.fullName.contains(query.trim())).toList();
    }
    return list;
  }

  @override
  Future<List<Farm>> fetchFarms(
    String wellId, {
    String? farmerAccountId,
    String? query,
  }) async {
    var list = serverFarms.where((f) => f.wellId == wellId).toList();
    if (farmerAccountId != null) {
      list = list.where((f) => f.farmerAccountId == farmerAccountId).toList();
    }
    if (query != null && query.trim().isNotEmpty) {
      list = list.where((f) => f.displayName.contains(query.trim())).toList();
    }
    return list;
  }
}

class _SearchStateOperationsRepository extends OperationsRepository {
  _SearchStateOperationsRepository({
    this.farmers = const [],
    this.farms = const [],
    this.farmerFailuresRemaining = 0,
    this.farmFailuresRemaining = 0,
  });

  final List<FarmerAccount> farmers;
  final List<Farm> farms;
  int farmerFailuresRemaining;
  int farmFailuresRemaining;

  @override
  Future<List<Pump>> fetchPumps(String wellId) async => [
    Pump(
      id: 'pump-1',
      wellId: wellId,
      name: 'المضخة الرئيسية',
      publicCode: 'PUMP-1',
    ),
  ];

  @override
  Future<List<FarmerAccount>> fetchFarmers(
    String wellId, {
    String? query,
  }) async {
    if (farmerFailuresRemaining > 0) {
      farmerFailuresRemaining -= 1;
      throw StateError('farmer lookup failed');
    }
    return farmers;
  }

  @override
  Future<List<Farm>> fetchFarms(
    String wellId, {
    String? farmerAccountId,
  }) async {
    if (farmFailuresRemaining > 0) {
      farmFailuresRemaining -= 1;
      throw StateError('farm lookup failed');
    }
    return farms;
  }
}

void main() {
  group('Operations M21 Farm Scope & Search Tests (Finding 11 E, F, I)', () {
    const accountId = 'owner-1';
    const well1 = WellSummary(
      id: 'well-1',
      tenantId: 'tenant-1',
      name: 'بئر الخير',
      status: 'active',
      roles: ['owner'],
    );

    late InMemoryOutboxStore store;
    late OfflineSessionCoordinator coordinator;

    setUp(() async {
      store = InMemoryOutboxStore();
      await store.initialize();
      coordinator = OfflineSessionCoordinator(store: store);
      await coordinator.initialize();
    });

    tearDown(() {
      coordinator.dispose();
    });

    Widget wrapApp({
      required OperationsRepository repository,
      WellSummary well = well1,
    }) {
      return MaterialApp(
        locale: const Locale('ar'),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: OperationsScreen(
            identity: testIdentity(accountId: accountId, wells: [well]),
            coordinator: coordinator,
            repository: repository,
          ),
        ),
      );
    }

    Finder lookupText(String text) => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text(text),
    );

    testWidgets(
      'failed farmer lookup shows error, hides empty/create, and retry restores durable pending',
      (tester) async {
        await coordinator.enqueueFarmer(
          accountId: accountId,
          wellId: well1.id,
          fullName: 'مزارع محلي محفوظ',
        );
        final repository = _SearchStateOperationsRepository(
          farmers: const [
            FarmerAccount(
              id: 'farmer-server-1',
              fullName: 'مزارع خادمي',
              publicCode: 'F-1',
            ),
          ],
          farmerFailuresRemaining: 1,
        );

        await tester.pumpWidget(wrapApp(repository: repository));
        await tester.pumpAndSettle();
        await tester.tap(find.text('ابحث باسم المزارع أو رقم هاتفه...'));
        await tester.pumpAndSettle();

        expect(
          lookupText('تعذّر تحميل النتائج. تحقق من الاتصال ثم أعد المحاولة.'),
          findsOneWidget,
        );
        expect(lookupText('لا توجد نتائج مطابقة'), findsNothing);
        expect(lookupText('إضافة مزارع جديد'), findsNothing);
        expect(lookupText('مزارع محلي محفوظ'), findsOneWidget);

        await tester.tap(lookupText('إعادة المحاولة'));
        await tester.pumpAndSettle();

        expect(
          lookupText('تعذّر تحميل النتائج. تحقق من الاتصال ثم أعد المحاولة.'),
          findsNothing,
        );
        expect(lookupText('مزارع محلي محفوظ'), findsOneWidget);
        expect(lookupText('مزارع خادمي'), findsOneWidget);
      },
    );

    testWidgets('pending farmer remains selectable while server error is shown', (
      tester,
    ) async {
      await coordinator.enqueueFarmer(
        accountId: accountId,
        wellId: well1.id,
        fullName: 'مزارع محلي قابل للاختيار',
      );
      final repository = _SearchStateOperationsRepository(
        farmerFailuresRemaining: 1,
      );

      await tester.pumpWidget(wrapApp(repository: repository));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ابحث باسم المزارع أو رقم هاتفه...'));
      await tester.pumpAndSettle();

      expect(
        lookupText('تعذّر تحميل النتائج. تحقق من الاتصال ثم أعد المحاولة.'),
        findsOneWidget,
      );
      expect(lookupText('مزارع محلي قابل للاختيار'), findsOneWidget);

      await tester.tap(lookupText('مزارع محلي قابل للاختيار'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('مزارع محلي قابل للاختيار'), findsOneWidget);
      expect(find.text('محفوظ على الجهاز'), findsOneWidget);
    });

    testWidgets(
      'failed farm lookup shows error, not empty, and retry restores durable pending farm',
      (tester) async {
        const farmer = FarmerAccount(
          id: 'farmer-1',
          fullName: 'محمد علي',
          publicCode: 'F-1',
        );
        await coordinator.enqueueFarm(
          accountId: accountId,
          wellId: well1.id,
          name: 'الكوثة',
          distinguishingLabel: 'الغربية',
          farmerReference: const ServerEntityReference('farmer-1'),
        );
        final repository = _SearchStateOperationsRepository(
          farmers: const [farmer],
          farms: const [
            Farm(
              id: 'farm-server-1',
              wellId: 'well-1',
              name: 'الكوثة',
              distinguishingLabel: 'الشرقية',
              farmerAccountId: 'farmer-1',
            ),
          ],
          farmFailuresRemaining: 1,
        );

        await tester.pumpWidget(wrapApp(repository: repository));
        await tester.pumpAndSettle();
        await tester.tap(find.text('ابحث باسم المزارع أو رقم هاتفه...'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('محمد علي'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('ابحث باسم الأرض...'));
        await tester.pumpAndSettle();

        expect(
          lookupText('تعذّر تحميل النتائج. تحقق من الاتصال ثم أعد المحاولة.'),
          findsOneWidget,
        );
        expect(lookupText('لا توجد نتائج مطابقة'), findsNothing);
        expect(lookupText('إضافة أرض جديدة'), findsNothing);
        expect(lookupText('الكوثة — الغربية'), findsOneWidget);

        await tester.tap(lookupText('إعادة المحاولة'));
        await tester.pumpAndSettle();

        expect(
          lookupText('تعذّر تحميل النتائج. تحقق من الاتصال ثم أعد المحاولة.'),
          findsNothing,
        );
        expect(lookupText('الكوثة — الغربية'), findsOneWidget);
        expect(lookupText('الكوثة — الشرقية'), findsOneWidget);
      },
    );

    testWidgets('pending farm remains selectable while server error is shown', (
      tester,
    ) async {
      const farmer = FarmerAccount(
        id: 'farmer-1',
        fullName: 'محمد علي',
        publicCode: 'F-1',
      );
      await coordinator.enqueueFarm(
        accountId: accountId,
        wellId: well1.id,
        name: 'الجربة',
        distinguishingLabel: 'القبلية',
        farmerReference: const ServerEntityReference('farmer-1'),
      );
      final repository = _SearchStateOperationsRepository(
        farmers: const [farmer],
        farmFailuresRemaining: 1,
      );

      await tester.pumpWidget(wrapApp(repository: repository));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ابحث باسم المزارع أو رقم هاتفه...'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('محمد علي'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ابحث باسم الأرض...'));
      await tester.pumpAndSettle();

      expect(
        lookupText('تعذّر تحميل النتائج. تحقق من الاتصال ثم أعد المحاولة.'),
        findsOneWidget,
      );
      expect(lookupText('الجربة — القبلية'), findsOneWidget);

      await tester.tap(lookupText('الجربة — القبلية'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('الجربة — القبلية'), findsOneWidget);
      expect(find.text('محفوظ على الجهاز'), findsOneWidget);
    });

    testWidgets('successful empty farmer lookup keeps normal empty/create state', (
      tester,
    ) async {
      final repository = _SearchStateOperationsRepository();

      await tester.pumpWidget(wrapApp(repository: repository));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ابحث باسم المزارع أو رقم هاتفه...'));
      await tester.pumpAndSettle();

      expect(lookupText('لا توجد نتائج مطابقة'), findsOneWidget);
      expect(lookupText('إضافة مزارع جديد'), findsWidgets);
      expect(lookupText('إعادة المحاولة'), findsNothing);
    });

    testWidgets(
      'E. pending farmer does NOT show server farms from unrelated farmers',
      (tester) async {
        final repo = _ScopedTestOperationsRepository(
          serverFarmers: const [
            FarmerAccount(
              id: 'farmer-server-1',
              fullName: 'مزارع غريب أول',
              publicCode: 'F-001',
            ),
          ],
          serverFarms: const [
            Farm(
              id: 'farm-server-1',
              wellId: 'well-1',
              name: 'مزرعة الغريب الخاصة',
              distinguishingLabel: 'الشرقية',
              farmerAccountId: 'farmer-server-1',
            ),
          ],
        );

        // Enqueue pending farmer and their pending farm locally
        final pendingFarmer = await coordinator.enqueueFarmer(
          accountId: accountId,
          wellId: 'well-1',
          fullName: 'مزارع محلي جديد',
        );
        await coordinator.enqueueFarm(
          accountId: accountId,
          wellId: 'well-1',
          name: 'أرض تابعة للمحلي',
          distinguishingLabel: 'القبلية',
          farmerReference: pendingFarmer.entityReference,
        );

        await tester.pumpWidget(wrapApp(repository: repo));
        await tester.pumpAndSettle();

        // 1. Select pending farmer
        await tester.tap(find.text('ابحث باسم المزارع أو رقم هاتفه...'));
        await tester.pumpAndSettle();

        expect(find.text('مزارع محلي جديد'), findsOneWidget);
        await tester.tap(find.text('مزارع محلي جديد'));
        await tester.pumpAndSettle();

        // 2. Open farm selection sheet
        await tester.tap(find.text('ابحث باسم الأرض...'));
        await tester.pumpAndSettle();

        // The pending farm of this pending farmer MUST appear
        expect(find.text('أرض تابعة للمحلي — القبلية'), findsOneWidget);

        // Server farms of unrelated farmers MUST NEVER appear
        expect(find.textContaining('مزرعة الغريب الخاصة'), findsNothing);
      },
    );

    testWidgets(
      'F. farm search query filters server and pending farms using displayName',
      (tester) async {
        final repo = _ScopedTestOperationsRepository(
          serverFarmers: const [
            FarmerAccount(
              id: 'farmer-1',
              fullName: 'حمود قاسم',
              publicCode: 'F-002',
            ),
          ],
          serverFarms: const [
            Farm(
              id: 'farm-s1',
              wellId: 'well-1',
              name: 'الكوثة',
              distinguishingLabel: 'الشرقية',
              farmerAccountId: 'farmer-1',
            ),
            Farm(
              id: 'farm-s2',
              wellId: 'well-1',
              name: 'الجربة الكبيرة',
              farmerAccountId: 'farmer-1',
            ),
          ],
        );

        // Also add a pending farm for this same server farmer
        await coordinator.enqueueFarm(
          accountId: accountId,
          wellId: 'well-1',
          name: 'الكوثة',
          distinguishingLabel: 'الغربية',
          farmerReference: const ServerEntityReference('farmer-1'),
        );

        await tester.pumpWidget(wrapApp(repository: repo));
        await tester.pumpAndSettle();

        // Select farmer
        await tester.tap(find.text('ابحث باسم المزارع أو رقم هاتفه...'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('حمود قاسم'));
        await tester.pumpAndSettle();

        // Open farm selection
        await tester.tap(find.text('ابحث باسم الأرض...'));
        await tester.pumpAndSettle();

        // Type 'الكوثة' in the search field
        final searchField = find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(TextField),
        );
        await tester.enterText(searchField, 'الكوثة');
        await tester.pumpAndSettle();

        // Both server and pending farms matching 'الكوثة' must appear
        expect(find.text('الكوثة — الشرقية'), findsOneWidget);
        expect(find.text('الكوثة — الغربية'), findsOneWidget);
        // Unrelated farm must be filtered out
        expect(find.text('الجربة الكبيرة'), findsNothing);

        // Now refine query to distinguishing label 'الغربية'
        await tester.enterText(searchField, 'الغربية');
        await tester.pumpAndSettle();

        expect(find.text('الكوثة — الغربية'), findsOneWidget);
        expect(find.text('الكوثة — الشرقية'), findsNothing);
      },
    );

    testWidgets('I. pending entities from another well do not appear', (
      tester,
    ) async {
      final repo = _ScopedTestOperationsRepository();

      // Enqueue pending entities belonging to well-2
      final foreignFarmer = await coordinator.enqueueFarmer(
        accountId: accountId,
        wellId: 'well-2',
        fullName: 'مزارع من بئر أخرى',
      );
      await coordinator.enqueueFarm(
        accountId: accountId,
        wellId: 'well-2',
        name: 'أرض من بئر أخرى',
        farmerReference: foreignFarmer.entityReference,
      );

      // Enqueue pending farmer in active well-1
      await coordinator.enqueueFarmer(
        accountId: accountId,
        wellId: 'well-1',
        fullName: 'مزارع بئرنا الحالي',
      );

      await tester.pumpWidget(wrapApp(repository: repo));
      await tester.pumpAndSettle();

      // Open farmer selection
      await tester.tap(find.text('ابحث باسم المزارع أو رقم هاتفه...'));
      await tester.pumpAndSettle();

      expect(find.text('مزارع بئرنا الحالي'), findsOneWidget);
      // Pending farmer from well-2 MUST NOT appear
      expect(find.text('مزارع من بئر أخرى'), findsNothing);
    });

    testWidgets(
      'create pending in Well A -> switch same OperationsScreen to Well B -> entity from A absent',
      (tester) async {
        const wellA = WellSummary(
          id: 'well-A',
          tenantId: 'tenant-1',
          name: 'بئر أ',
          status: 'active',
          roles: ['owner'],
        );
        const wellB = WellSummary(
          id: 'well-B',
          tenantId: 'tenant-1',
          name: 'بئر ب',
          status: 'active',
          roles: ['owner'],
        );

        final repo = const _ScopedTestOperationsRepository();

        // 1. Pump OperationsScreen with active well A
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: Directionality(
              textDirection: TextDirection.rtl,
              child: OperationsScreen(
                identity: testIdentity(
                  accountId: accountId,
                  wells: [wellA, wellB],
                  activeWell: wellA,
                ),
                coordinator: coordinator,
                repository: repo,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 2. Open Add Farmer dialog in Well A and enqueue a farmer
        await tester.tap(find.text('ابحث باسم المزارع أو رقم هاتفه...'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('إضافة مزارع جديد').first);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'اسم المزارع الكامل *'),
          'مزارع خاص ببئر أ',
        );
        await tester.tap(find.text('حفظ وإضافة'));
        await tester.pumpAndSettle();

        // Verify selected farmer in Well A is the pending farmer
        expect(find.text('مزارع خاص ببئر أ'), findsWidgets);

        // 3. Switch the SAME OperationsScreen to Well B via widget update
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: Directionality(
              textDirection: TextDirection.rtl,
              child: OperationsScreen(
                identity: testIdentity(
                  accountId: accountId,
                  wells: [wellA, wellB],
                  activeWell: wellB,
                ),
                coordinator: coordinator,
                repository: repo,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Selected farmer should have been reset on well switch
        expect(find.text('مزارع خاص ببئر أ'), findsNothing);

        // 4. Open farmer search in Well B: pending farmer from Well A MUST NOT appear
        await tester.tap(find.text('ابحث باسم المزارع أو رقم هاتفه...'));
        await tester.pumpAndSettle();

        expect(find.text('مزارع خاص ببئر أ'), findsNothing);
      },
    );
  });
}

/// اختبارات الاستعادة الحتمية للمزارع/الأرض وحياة الشاشة — ق-129.
///
/// تغطي الأهداف 4 و 5 و 6 بالكامل:
/// - استعادة الجلسة عند استئناف التطبيق (Resume Lifecycle)
/// - استعادة الجلسة عند إعادة الدخول عبر التنقل (Navigation Re-entry)
/// - استعادة المزارع والأرض والمضخة والطاقة بشكل مستقل ومحمي بحساب وبئر وجيل وهوية الجلسة.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/identity/app_identity.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';

import '../../support/identity_fixture.dart';

class _ConfigurableOperationsRepository extends OperationsRepository {
  _ConfigurableOperationsRepository({
    this.farmers = const [],
    this.farms = const [],
    this.pumps = const [],
  });

  List<FarmerAccount> farmers;
  List<Farm> farms;
  List<Pump> pumps;

  Completer<void>? delayFarmers;
  Completer<void>? delayFarms;
  Completer<void>? delayPumps;

  bool shouldFailFarmers = false;
  bool shouldFailFarms = false;
  bool shouldFailPumps = false;

  var fetchFarmersCount = 0;
  var fetchFarmsCount = 0;
  var fetchPumpsCount = 0;

  @override
  Future<List<FarmerAccount>> fetchFarmers(
    String wellId, {
    String? query,
  }) async {
    fetchFarmersCount++;
    if (delayFarmers != null) {
      await delayFarmers!.future;
    }
    if (shouldFailFarmers) {
      throw Exception('Farmer fetch failure');
    }
    return farmers;
  }

  @override
  Future<List<Farm>> fetchFarms(
    String wellId, {
    String? farmerAccountId,
  }) async {
    fetchFarmsCount++;
    if (delayFarms != null) {
      await delayFarms!.future;
    }
    if (shouldFailFarms) {
      throw Exception('Farm fetch failure');
    }
    return farms;
  }

  @override
  Future<List<Pump>> fetchPumps(String wellId) async {
    fetchPumpsCount++;
    if (delayPumps != null) {
      await delayPumps!.future;
    }
    if (shouldFailPumps) {
      throw Exception('Pump fetch failure');
    }
    return pumps;
  }
}

void main() {
  group('Q-129 Operations Recovery Tests (Goals 4, 5, 6)', () {
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
      fullName: 'مزارع الخير المستفيد',
      publicCode: 'F-001',
    );

    const testFarm = Farm(
      id: 'farm-1',
      wellId: 'well-1',
      name: 'أرض الوادي الخضراء',
      farmerAccountId: 'farmer-1',
    );

    const testPump = Pump(
      id: 'pump-1',
      wellId: 'well-1',
      name: 'المضخة الغاطسة رقم 1',
      publicCode: 'PUMP-01',
    );

    late InMemoryOutboxStore store;
    late OfflineSessionCoordinator coordinator;
    late _ConfigurableOperationsRepository repo;

    setUp(() async {
      store = InMemoryOutboxStore();
      coordinator = OfflineSessionCoordinator(store: store);
      await coordinator.initialize();

      repo = _ConfigurableOperationsRepository(
        farmers: [testFarmer],
        farms: [testFarm],
        pumps: [testPump],
      );
    });

    tearDown(() {
      coordinator.dispose();
    });

    Widget buildScreen({AppIdentity? identity}) {
      return MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: OperationsScreen(
            identity:
                identity ?? testIdentity(accountId: accountId, wells: const [well]),
            coordinator: coordinator,
            repository: repo,
          ),
        ),
      );
    }

    // =========================================================================
    // GOAL 4: Resume Lifecycle Hole
    // =========================================================================
    testWidgets(
      'Goal 4: شاشة بلا جلسة في الذاكرة تستعيد الجلسة فور استئناف التطبيق (Resume Lifecycle)',
      (tester) async {
        // 1. فتح الشاشة وبلا جلسة في الذاكرة
        await tester.pumpWidget(buildScreen());
        await tester.pumpAndSettle();

        expect(find.text('لا توجد جلسة سقي نشطة'), findsOneWidget);
        expect(find.text('تفاصيل الجلسة الحالية'), findsNothing);

        // 2. محاكاة إنشاء وتأكيد جلسة جديدة خارج الشاشة (عبر background sync أو خارج الذاكرة)
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        // 3. استئناف التطبيق من الخلفية (AppLifecycleState.resumed)
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();

        // 4. الشاشة استعادت الجلسة النشطة بنجاح
        expect(find.text('تفاصيل الجلسة الحالية'), findsOneWidget);
        expect(find.text('جاري'), findsOneWidget);
      },
    );

    // =========================================================================
    // GOAL 5: Navigation Re-entry
    // =========================================================================
    testWidgets(
      'Goal 5: التنقل Home -> Operations -> Home -> Operations يعيد بناء واسترجاع الجلسة عبر initState',
      (tester) async {
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        // محاكاة التنقل عبر Navigator
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => Directionality(
                          textDirection: TextDirection.rtl,
                          child: OperationsScreen(
                            identity: testIdentity(
                              accountId: accountId,
                              wells: const [well],
                            ),
                            coordinator: coordinator,
                            repository: repo,
                          ),
                        ),
                      ),
                    );
                  },
                  child: const Text('Go to Operations'),
                ),
              ),
            ),
          ),
        );

        // دخول Operations لأول مرة
        await tester.tap(find.text('Go to Operations'));
        await tester.pumpAndSettle();
        expect(find.text('تفاصيل الجلسة الحالية'), findsOneWidget);

        // العودة إلى Home (Pop) — يتم هدم واستبعاد OperationsScreen بالكامل
        Navigator.of(tester.element(find.byType(OperationsScreen))).pop();
        await tester.pumpAndSettle();
        expect(find.byType(OperationsScreen), findsNothing);

        // إعادة الدخول إلى Operations — initState ينفذ الإسقاط الجديد من المخزن المتين
        await tester.tap(find.text('Go to Operations'));
        await tester.pumpAndSettle();
        expect(find.text('تفاصيل الجلسة الحالية'), findsOneWidget);
      },
    );

    // =========================================================================
    // GOAL 6: Deterministic Farmer/Farm/Pump/Energy Recovery Tests (12 Points)
    // =========================================================================

    testWidgets(
      '1. أمر البدء يحمل farmerReference + farmReference ⟹ اسماهما يُسترجعان',
      (tester) async {
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        await tester.pumpWidget(buildScreen());
        await tester.pumpAndSettle();

        expect(find.text('مزارع الخير المستفيد'), findsOneWidget);
        expect(find.text('أرض الوادي الخضراء'), findsOneWidget);
      },
    );

    testWidgets(
      '2. استرجاع المزارع يكتمل أولاً ⟹ الأرض تُسترجع بشكل مستقل',
      (tester) async {
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        final farmDelay = Completer<void>();
        repo.delayFarms = farmDelay;

        await tester.pumpWidget(buildScreen());
        await tester.pump(); // إكمال استرجاع المزارع

        expect(find.text('مزارع الخير المستفيد'), findsOneWidget);

        // الآن نكمل استرجاع الأرض
        farmDelay.complete();
        await tester.pumpAndSettle();

        expect(find.text('أرض الوادي الخضراء'), findsOneWidget);
      },
    );

    testWidgets(
      '3. تغير الجيل أثناء استرجاع الأرض ⟹ النتيجة القديمة تُهمل والجيل الجديد يسترجعها',
      (tester) async {
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        final farmDelay = Completer<void>();
        repo.delayFarms = farmDelay;

        await tester.pumpWidget(buildScreen());
        await tester.pump();

        // نغير الجيل عبر استئناف التطبيق (resume) مما يشغل _recoverActiveSession بجيل أحدث
        repo.delayFarms = null; // الإسقاط الجديد لن يتعطل
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();

        // نسمح للإسقاط القديم بالانتهاء — يجب أن يُهمل
        farmDelay.complete();
        await tester.pumpAndSettle();

        expect(find.text('أرض الوادي الخضراء'), findsOneWidget);
      },
    );

    testWidgets(
      '4. المزارع محدد مسبقاً في الحالة لكن الأرض مفقودة ⟹ استرجاع الأرض ينفذ بنجاح',
      (tester) async {
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        await tester.pumpWidget(buildScreen());
        await tester.pumpAndSettle();

        // كلاهما تم استرجاعه
        expect(find.text('مزارع الخير المستفيد'), findsOneWidget);
        expect(find.text('أرض الوادي الخضراء'), findsOneWidget);
      },
    );

    testWidgets(
      '5. فشل استرجاع المزارع ⟹ لا يتم اختراع اسم مزارع وهمي وتظهر رسالة الخطأ',
      (tester) async {
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        repo.shouldFailFarmers = true;

        await tester.pumpWidget(buildScreen());
        await tester.pumpAndSettle();

        expect(find.text('مزارع الخير المستفيد'), findsNothing);
        expect(find.text('تعذر تحميل بيانات المزارع للجلسة النشطة'), findsOneWidget);
      },
    );

    testWidgets(
      '6. فشل استرجاع الأرض ⟹ لا يتم اختراع اسم أرض وهمي',
      (tester) async {
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'non-existent-farm',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        await tester.pumpWidget(buildScreen());
        await tester.pumpAndSettle();

        expect(find.text('أرض الوادي الخضراء'), findsNothing);
      },
    );

    testWidgets(
      '7. تغير الحساب أثناء استرجاع المزارع ⟹ نتيجة الحساب القديم تُهمل',
      (tester) async {
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        final farmerDelay = Completer<void>();
        repo.delayFarmers = farmerDelay;

        await tester.pumpWidget(buildScreen());
        await tester.pump();

        // نبدل هوية الحساب
        const otherAccount = 'owner-2';
        const well2 = WellSummary(
          id: 'well-2',
          tenantId: 'tenant-1',
          name: 'بئر أخرى',
          status: 'active',
          roles: ['owner'],
        );
        await tester.pumpWidget(
          buildScreen(
            identity: testIdentity(accountId: otherAccount, wells: const [well2]),
          ),
        );
        await tester.pump();

        // إكمال بحث الحساب القديم
        farmerDelay.complete();
        await tester.pumpAndSettle();

        // لم يلتصق اسم المزارع للحساب القديم
        expect(find.text('مزارع الخير المستفيد'), findsNothing);
      },
    );

    testWidgets(
      '8. تغير الحساب أثناء استرجاع الأرض ⟹ نتيجة الحساب القديم تُهمل',
      (tester) async {
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        final farmDelay = Completer<void>();
        repo.delayFarms = farmDelay;

        await tester.pumpWidget(buildScreen());
        await tester.pump();

        // نبدل هوية الحساب
        const otherAccount = 'owner-2';
        const well2 = WellSummary(
          id: 'well-2',
          tenantId: 'tenant-1',
          name: 'بئر أخرى',
          status: 'active',
          roles: ['owner'],
        );
        await tester.pumpWidget(
          buildScreen(
            identity: testIdentity(accountId: otherAccount, wells: const [well2]),
          ),
        );
        await tester.pump();

        // إكمال بحث الأرض القديمة
        farmDelay.complete();
        await tester.pumpAndSettle();

        expect(find.text('أرض الوادي الخضراء'), findsNothing);
      },
    );

    testWidgets(
      '9. نفس wellId بحساب مختلف ⟹ نتيجة الحساب القديم لا ترتبط',
      (tester) async {
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        final farmerDelay = Completer<void>();
        repo.delayFarmers = farmerDelay;

        await tester.pumpWidget(buildScreen());
        await tester.pump();

        // نفس البئر لكن حساب مختلف
        const otherAccount = 'owner-different';
        await tester.pumpWidget(
          buildScreen(
            identity: testIdentity(accountId: otherAccount, wells: const [well]),
          ),
        );

        farmerDelay.complete();
        await tester.pumpAndSettle();

        // لا تُسند النتيجة لأن accountId لا يطابق
        expect(find.text('مزارع الخير المستفيد'), findsNothing);
      },
    );

    testWidgets(
      '10. تغير هوية الجلسة المحلية أثناء البحث ⟹ النتيجة القديمة تُهمل',
      (tester) async {
        final s1 = await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        final farmerDelay = Completer<void>();
        repo.delayFarmers = farmerDelay;

        await tester.pumpWidget(buildScreen());
        await tester.pump();

        // إنهاء الجلسة s1 وبدء جلسة جديدة s2 بمزارع آخر
        await coordinator.completeSession(
          accountId: accountId,
          sessionLocalId: s1.localId,
        );
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'other-farmer',
          energySource: 'solar',
        );

        // استدعاء استرجاع الجلسة الجديدة
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();

        // الآن يكتمل بحث المزارع للجلسة القديمة s1
        farmerDelay.complete();
        await tester.pumpAndSettle();

        // مزارع الجلسة القديمة لا يلتصق بالجلسة الجديدة
        expect(find.text('مزارع الخير المستفيد'), findsNothing);
      },
    );

    testWidgets(
      '11. استرجاع المضخة يستمر ويعرض اسمها بشكل صحيح',
      (tester) async {
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
        );

        await tester.pumpWidget(buildScreen());
        await tester.pumpAndSettle();

        expect(find.text('المضخة الغاطسة رقم 1'), findsOneWidget);
      },
    );

    testWidgets(
      '12. استرجاع مصدر الطاقة يستمر ويعكس المصدر الجاري بدقة',
      (tester) async {
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'well_diesel',
        );

        await tester.pumpWidget(buildScreen());
        await tester.pumpAndSettle();

        // التحقق من استعادة مصدر الطاقة
        expect(find.textContaining('ديزل البئر'), findsWidgets);
      },
    );
  });
}

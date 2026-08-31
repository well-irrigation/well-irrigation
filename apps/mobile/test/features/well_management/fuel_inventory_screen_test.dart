import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/well_management/fuel_inventory_screen.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';

/// مستودع مزيَّف يعيد ما يعيده عقد api.list_well_fuel_tanks بالمليلتر.
///
/// الشاشة صارت تعتمد المستودع الحقيقي في كل الحالات (لا بيانات تجريبية
/// داخلها)، فكل اختبار يجب أن يمرر هذا المزيَّف صراحة.
class _FakeWellManagementRepository extends WellManagementRepository {
  _FakeWellManagementRepository({
    this.failPhysicalCount = false,
  });

  final bool failPhysicalCount;

  String? recordedWellId;
  String? recordedTankId;
  int? recordedMeasuredBalanceMl;
  String? recordedNotes;

  @override
  Future<List<FuelTankModel>> fetchFuelTanks(
    String wellId, {
    bool includeInactive = false,
  }) async {
    return [
      FuelTankModel(
        id: 'tank-test-1',
        wellId: wellId,
        publicCode: 'TNK-001',
        name: 'الخزان الرئيسي لمولد الديزل',
        capacityMl: 1000000,
        currentBalanceMl: 250000,
        measurementMethod: 'estimated',
        status: 'active',
        lastMeasuredAt: DateTime(2026, 8, 30),
      ),
      FuelTankModel(
        id: 'tank-test-2',
        wellId: wellId,
        publicCode: 'TNK-002',
        name: 'خزان الديزل الاحتياطي',
        capacityMl: 500000,
        currentBalanceMl: 120000,
        measurementMethod: 'actual',
        status: 'active',
      ),
    ];
  }

  @override
  Future<void> recordPhysicalFuelCount({
    required String wellId,
    required String tankId,
    required int measuredBalanceMl,
    String? notes,
  }) async {
    recordedWellId = wellId;
    recordedTankId = tankId;
    recordedMeasuredBalanceMl = measuredBalanceMl;
    recordedNotes = notes;

    if (failPhysicalCount) {
      throw Exception('backend unavailable');
    }
  }
}

void main() {
  group('FuelInventoryScreen Tests (UX-15 / 478–490)', () {
    testWidgets('1. عرض رصيد ديزل البئر الإجمالي والخزانات والحالات', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: FuelInventoryScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            repository: _FakeWellManagementRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('إدارة الوقود والخزانات'), findsOneWidget);
      expect(find.text('رصيد ديزل البئر المتاح'), findsOneWidget);
      expect(find.textContaining('خزانات الوقود'), findsOneWidget);
      expect(find.text('الخزان الرئيسي لمولد الديزل'), findsOneWidget);
      expect(find.text('خزان الديزل الاحتياطي'), findsOneWidget);
      expect(find.text('تسجيل شراء ديزل'), findsWidgets);
      expect(find.textContaining('فصل ملكية الوقود'), findsOneWidget);
      // 370 لتر = 370000 مل من الخزانين، والتحويل عرضي فقط.
      expect(find.text('370'), findsOneWidget);
    });

    testWidgets('2. فتح حوار تسجيل شراء ديزل جديد', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: FuelInventoryScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            repository: _FakeWellManagementRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('تسجيل شراء ديزل').first);
      await tester.pumpAndSettle();

      expect(find.text('تسجيل شراء ديزل جديد'), findsOneWidget);
      expect(find.text('الكمية المشتراة (باللتر) *'), findsOneWidget);
      expect(find.text('التكلفة الإجمالية (ريال يمني) *'), findsOneWidget);
      expect(find.text('تأكيد وإضافة للمخزون'), findsOneWidget);
      // العقد لا يأخذ خزانًا ولا مورّدًا، فلا حقل لأيٍّ منهما.
      expect(find.text('الخزان المستهدف *'), findsNothing);
      expect(find.text('اسم المورد / المحطة (اختياري)'), findsNothing);
    });

    testWidgets('3. فتح حوار الجرد الفعلي وتسوية الفروقات', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: FuelInventoryScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            repository: _FakeWellManagementRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('جرد وقياس فعلي').first);
      await tester.pumpAndSettle();

      expect(find.text('تسجيل جرد وقياس فعلي'), findsOneWidget);
      expect(find.text('القياس الفعلي بالخزان (لتر) *'), findsOneWidget);
      expect(find.text('فرق التسوية المحتسب:'), findsOneWidget);
      expect(find.text('سبب تسوية الفرق *'), findsOneWidget);
      expect(find.text('اعتماد الجرد والتسوية'), findsOneWidget);
    });

    testWidgets(
      '4. الجرد يمرر البئر والخزان والقياس بالمليلتر',
      (tester) async {
        final repository = _FakeWellManagementRepository();

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: FuelInventoryScreen(
              wellName: 'بئر الاختبار',
              wellId: 'well-real-1',
              repository: repository,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.text('جرد وقياس فعلي').first,
        );
        await tester.pumpAndSettle();

        final fields = find.byType(TextFormField);
        expect(fields, findsNWidgets(2));

        await tester.enterText(fields.at(0), '321');
        await tester.enterText(
          fields.at(1),
          'جرد ميداني',
        );

        await tester.tap(
          find.text('اعتماد الجرد والتسوية'),
        );
        await tester.pumpAndSettle();

        expect(repository.recordedWellId, 'well-real-1');
        expect(repository.recordedTankId, 'tank-test-1');
        expect(
          repository.recordedMeasuredBalanceMl,
          321000,
        );
        expect(repository.recordedNotes, 'جرد ميداني');

        expect(
          find.textContaining(
            'تم تسجيل الجرد الفعلي واعتماد تسوية الفروقات',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '5. فشل backend لا يغلق الحوار ولا يعرض نجاحًا',
      (tester) async {
        final repository = _FakeWellManagementRepository(
          failPhysicalCount: true,
        );

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: FuelInventoryScreen(
              wellName: 'بئر الاختبار',
              wellId: 'well-real-1',
              repository: repository,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.text('جرد وقياس فعلي').first,
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.text('اعتماد الجرد والتسوية'),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('تسجيل جرد وقياس فعلي'),
          findsOneWidget,
        );
        expect(
          find.textContaining('backend unavailable'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'تم تسجيل الجرد الفعلي واعتماد تسوية الفروقات',
          ),
          findsNothing,
        );
      },
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/well_management/fuel_inventory_screen.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';

class _FakeWellManagementRepository
    extends WellManagementRepository {
  _FakeWellManagementRepository({
    this.failPhysicalCount = false,
  });

  final bool failPhysicalCount;

  String? recordedWellId;
  String? recordedTankId;
  int? recordedMeasuredBalanceLiters;
  String? recordedReason;

  @override
  Future<List<FuelTankModel>> fetchFuelTanks(String wellId) async {
    return [
      FuelTankModel(
        id: 'tank-test-1',
        wellId: wellId,
        name: 'خزان الاختبار',
        capacityLiters: 1000,
        currentBalanceLiters: 250,
        measurementMethod: 'estimated',
        status: 'active',
        lastMeasuredAt: DateTime(2026, 8, 30),
      ),
    ];
  }

  @override
  Future<void> recordPhysicalFuelCount({
    required String wellId,
    required String tankId,
    required int measuredBalanceLiters,
    required String adjustmentReason,
  }) async {
    recordedWellId = wellId;
    recordedTankId = tankId;
    recordedMeasuredBalanceLiters = measuredBalanceLiters;
    recordedReason = adjustmentReason;

    if (failPhysicalCount) {
      throw Exception('backend unavailable');
    }
  }
}

void main() {
  group('FuelInventoryScreen Tests (UX-15 / 478–490)', () {
    testWidgets('1. عرض رصيد ديزل البئر الإجمالي والخزانات والحالات', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: FuelInventoryScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
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
    });

    testWidgets('2. فتح حوار تسجيل شراء ديزل جديد', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: FuelInventoryScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // فتح حوار تسجيل شراء ديزل
      await tester.tap(find.text('تسجيل شراء ديزل').first);
      await tester.pumpAndSettle();

      expect(find.text('تسجيل شراء ديزل جديد'), findsOneWidget);
      expect(find.text('الخزان المستهدف *'), findsOneWidget);
      expect(find.text('الكمية المشتراة (باللتر) *'), findsOneWidget);
      expect(find.text('التكلفة الإجمالية (ريال يمني) *'), findsOneWidget);
      expect(find.text('تأكيد وإضافة للمخزون'), findsOneWidget);
    });

    testWidgets('3. فتح حوار الجرد الفعلي وتسوية الفروقات', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: FuelInventoryScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // فتح حوار جرد وقياس فعلي
      await tester.tap(find.text('جرد وقياس فعلي').first);
      await tester.pumpAndSettle();

      expect(find.text('تسجيل جرد وقياس فعلي'), findsOneWidget);
      expect(find.text('القياس الفعلي بالخزان (لتر) *'), findsOneWidget);
      expect(find.text('فرق التسوية المحتسب:'), findsOneWidget);
      expect(find.text('سبب تسوية الفرق *'), findsOneWidget);
      expect(find.text('اعتماد الجرد والتسوية'), findsOneWidget);
    });
    testWidgets(
      '4. الجرد يمرر البئر والخزان والقياس الصحيح',
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
          repository.recordedMeasuredBalanceLiters,
          321,
        );
        expect(repository.recordedReason, 'جرد ميداني');

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

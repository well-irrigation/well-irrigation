import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';
import 'package:well_irrigation_mobile/features/well_management/pricing_tariff_screen.dart';

/// مستودع مزيَّف يعيد جدول تسعير ساريًا كما يعيده عقد
/// api.get_active_price_schedule، بمبالغ *_minor بريالات كاملة (ق-77).
class _FakeWellManagementRepository extends WellManagementRepository {
  _FakeWellManagementRepository({this.schedule});

  final PriceScheduleModel? schedule;

  String? createdName;
  String? createdReason;

  @override
  Future<PriceScheduleModel?> fetchActivePriceSchedule(
    String wellId, {
    DateTime? at,
  }) async {
    return schedule;
  }

  @override
  Future<({DateTime effectiveFrom, String scheduleId})> createPriceSchedule({
    required String wellId,
    required String name,
    DateTime? effectiveFrom,
    String? reason,
    int? solarRateMinor,
    int? wellDieselRateMinor,
    int? farmerDieselRateMinor,
  }) async {
    createdName = name;
    createdReason = reason;
    return (
      scheduleId: 'sched-new',
      effectiveFrom: effectiveFrom ?? DateTime(2026, 9, 1),
    );
  }
}

PriceScheduleModel _activeSchedule() {
  return PriceScheduleModel(
    id: 'sched-1',
    wellId: 'well-1',
    name: 'تعرفة موسم 2026',
    status: 'active',
    reason: 'مراجعة سنوية',
    effectiveFrom: DateTime(2026, 8, 1),
    rules: const [
      PriceRuleModel(
        id: 'rule-solar',
        energySource: 'solar',
        hourlyRateMinor: 2500,
      ),
      PriceRuleModel(
        id: 'rule-well-diesel',
        energySource: 'well_diesel',
        dieselPricingModel: 'all_inclusive',
        hourlyRateMinor: 5200,
      ),
      PriceRuleModel(
        id: 'rule-farmer-diesel',
        energySource: 'farmer_diesel',
        hourlyRateMinor: 1800,
      ),
    ],
  );
}

void main() {
  group('PricingTariffScreen Tests (UX-15 / 491–497)', () {
    testWidgets('1. عرض التعرفة النشطة وأسعار ساعات الطاقة والتنبيه التاريخي', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: PricingTariffScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            repository: _FakeWellManagementRepository(
              schedule: _activeSchedule(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('تعرفة الطاقة والأسعار'), findsOneWidget);
      expect(find.text('التعرفة النشطة حالياً'), findsOneWidget);
      expect(find.text('معتمدة وسارية ✅'), findsOneWidget);
      expect(find.textContaining('الطاقة الشمسية'), findsWidgets);
      expect(find.textContaining('ديزل البئر'), findsWidgets);
      expect(find.textContaining('ديزل المزارع'), findsWidgets);
      expect(find.text('تحديث جدول الأسعار'), findsOneWidget);
      expect(find.textContaining('مبدأ الأسعار التاريخية'), findsOneWidget);
    });

    testWidgets('2. فتح حوار تحديث تعرفة الأسعار والتحقق من الحقول', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: PricingTariffScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            repository: _FakeWellManagementRepository(
              schedule: _activeSchedule(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('تحديث جدول الأسعار'));
      await tester.pumpAndSettle();

      expect(find.text('تحديث تعرفة الأسعار'), findsOneWidget);
      expect(find.text('اسم جدول التعرفة *'), findsOneWidget);
      expect(find.text('سبب تعديل الأسعار *'), findsOneWidget);
      expect(find.text('سعر ساعة الطاقة الشمسية (ريال/ساعة) *'), findsOneWidget);
      expect(find.text('سعر ساعة ديزل البئر الشامل (ريال/ساعة) *'), findsOneWidget);
      expect(find.text('سعر ساعة ديزل المزارع (ريال/ساعة) *'), findsOneWidget);
      expect(find.text('اعتماد وسريان التعرفة'), findsOneWidget);
    });

    testWidgets('3. غياب جدول ساري يُعرض كحالة صريحة لا كأسعار صفرية', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: PricingTariffScreen(
            wellName: 'بئر بلا تسعير',
            wellId: 'well-2',
            repository: _FakeWellManagementRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('غير مُسعَّر ⚠️'), findsOneWidget);
      expect(find.text('لا يوجد جدول تسعير ساري'), findsOneWidget);
      expect(find.text('معتمدة وسارية ✅'), findsNothing);
      // الحوار يبقى متاحًا لاعتماد أول جدول.
      expect(find.text('تحديث جدول الأسعار'), findsOneWidget);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/well_management/pricing_tariff_screen.dart';

void main() {
  group('PricingTariffScreen Tests (UX-15 / 491–497)', () {
    testWidgets('1. عرض التعرفة النشطة وأسعار ساعات الطاقة والتنبيه التاريخي', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: PricingTariffScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
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
        const MaterialApp(
          locale: Locale('ar'),
          home: PricingTariffScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // فتح حوار تحديث الأسعار
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
  });
}

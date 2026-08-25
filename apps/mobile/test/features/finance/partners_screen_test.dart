import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/finance/partner_detail_financial_screen.dart';
import 'package:well_irrigation_mobile/features/finance/partners_screen.dart';

void main() {
  group('Partners & Financial Statement Tests (UX-14 / 432–438)', () {
    testWidgets('1. عرض هيكل الشركاء ونسب الملكية والأرباح ومجموع 100%', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: PartnersScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('هيكل الشركاء والأرباح'), findsOneWidget);
      expect(find.text('مجموع النسب: 100%'), findsOneWidget);
      expect(find.text('عبدالرحمن باجعفر'), findsOneWidget);
      expect(find.text('صالح مهدي العامري'), findsOneWidget);
      expect(find.text('قاسم محمد الكندي'), findsOneWidget);
      expect(find.text('دورات وتوزيع الأرباح'), findsOneWidget);
    });

    testWidgets('2. فتح كشف حساب الشريك وتفكيك معادلة المستحق الصافي', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: PartnerDetailFinancialScreen(
            wellId: 'well-1',
            partnerId: 'partner-1',
            wellName: 'بئر الخير الرئيسي',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('عبدالرحمن باجعفر'), findsWidgets);
      expect(find.text('المتبقي المستحق للشريك حالياً'), findsOneWidget);
      expect(find.text('تفكيك المستحقات المالية (المعادلة المعتمدة):'), findsOneWidget);
      expect(find.text('الحصة الإجمالية من الأرباح المعتمدة (+):'), findsOneWidget);
      expect(find.text('تعويض مصروفات دفعها من جيبه (+):'), findsOneWidget);
      expect(find.text('استقطاع سقي أرضه الزراعية (-):'), findsOneWidget);
      expect(find.text('صرف أرباح للشريك'), findsOneWidget);

      // فتح حوار صرف الأرباح
      await tester.tap(find.text('صرف أرباح للشريك'));
      await tester.pumpAndSettle();

      expect(find.text('صرف مستحقات الشريك'), findsOneWidget);
      expect(find.text('مبلغ الصرف (ريال يمني) *'), findsOneWidget);
      expect(find.text('تأكيد الصرف'), findsOneWidget);
    });
  });
}

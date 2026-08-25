import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/finance/profit_distribution_screen.dart';

void main() {
  group('ProfitDistributionScreen Tests (UX-14 / 439–447)', () {
    testWidgets('1. عرض دورات توزيع الأرباح وتفكيك المعادلة المحاسبية المعتمدة', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: ProfitDistributionScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('دورات وتوزيع الأرباح'), findsOneWidget);
      expect(find.text('صافي الأرباح القابلة للتوزيع:'), findsOneWidget);
      expect(find.text('تفكيك المعادلة المحاسبية المعتمدة:'), findsOneWidget);
      expect(find.text('المقبوضات المؤهلة (+):'), findsOneWidget);
      expect(find.text('المصروفات المؤهلة (-):'), findsOneWidget);
      expect(find.text('احتياطي الصيانة (-):'), findsOneWidget);
      expect(find.text('أنصبة الشركاء في هذه الدورة:'), findsOneWidget);
      expect(find.text('احتساب دورة أرباح جديدة'), findsOneWidget);
    });

    testWidgets('2. فتح نافذة احتساب دورة أرباح جديدة واختيار الفترة والاحتياطي', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: ProfitDistributionScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // الضغط على زر احتساب دورة أرباح جديدة
      await tester.tap(find.text('احتساب دورة أرباح جديدة'));
      await tester.pumpAndSettle();

      expect(find.text('احتساب دورة توزيع الأرباح'), findsOneWidget);
      expect(find.text('الفترة المحاسبية المراد احتساب أرباحها:'), findsOneWidget);
      expect(find.text('احتياطي الصيانة المحتجز (ريال يمني)'), findsOneWidget);
      expect(find.text('احتساب وتجهيز الدورة'), findsOneWidget);
    });
  });
}

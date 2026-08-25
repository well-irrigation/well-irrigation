import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/finance/farmer_financial_account_screen.dart';

void main() {
  group('FarmerFinancialAccountScreen Tests (UX-14 / 408–424 / No Silent Netting)', () {
    testWidgets('1. عرض فصل الديون عن الرصيد المقدم وتطبيق مبدأ ق-99', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: FarmerFinancialAccountScreen(
            wellId: 'well-1',
            farmerAccountId: 'mock-farmer-1',
            wellName: 'بئر الخير الرئيسي',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('الحساب المالي: محمد علي الحبيشي'), findsOneWidget);
      expect(find.text('إجمالي الديون المستحقة'), findsOneWidget);
      expect(find.text('الرصيد المقدم بحسابه'), findsOneWidget);
      expect(find.textContaining('مبدأ ق-99'), findsOneWidget);
      expect(find.textContaining('الفواتير المستحقة'), findsOneWidget);
      expect(find.textContaining('سجل سندات القبض'), findsOneWidget);
      expect(find.text('تسجيل دفعة / سند قبض'), findsOneWidget);
      expect(find.text('استخدام الرصيد المقدم'), findsOneWidget);
    });

    testWidgets('2. فتح حوار تسجيل دفعة وسند قبض جديد', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: FarmerFinancialAccountScreen(
            wellId: 'well-1',
            farmerAccountId: 'mock-farmer-1',
            wellName: 'بئر الخير الرئيسي',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // الضغط على زر تسجيل دفعة
      await tester.tap(find.text('تسجيل دفعة / سند قبض'));
      await tester.pumpAndSettle();

      expect(find.text('تسجيل دفعة وسند قبض'), findsOneWidget);
      expect(find.text('المبلغ المدفوع (ريال يمني) *'), findsOneWidget);
      expect(find.text('طريقة الدفع *'), findsOneWidget);
      expect(find.text('إصدار سند القبض'), findsOneWidget);
    });

    testWidgets('3. فتح حوار استخدام الرصيد المقدم لتسديد أقدم الفواتير', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: FarmerFinancialAccountScreen(
            wellId: 'well-1',
            farmerAccountId: 'mock-farmer-1',
            wellName: 'بئر الخير الرئيسي',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // الضغط على زر استخدام الرصيد المقدم
      await tester.tap(find.text('استخدام الرصيد المقدم'));
      await tester.pumpAndSettle();

      expect(find.text('استخدام الرصيد المقدم'), findsWidgets);
      expect(find.text('الرصيد المقدم المتاح:'), findsOneWidget);
      expect(find.text('تأكيد التسديد من المقدم'), findsOneWidget);
    });
  });
}

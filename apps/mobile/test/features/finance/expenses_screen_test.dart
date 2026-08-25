import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/finance/expenses_screen.dart';

void main() {
  group('ExpensesScreen Tests (UX-14 / 425–431)', () {
    testWidgets('1. عرض عناصر شاشة المصروفات والتبويبات والملخص المالي', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: ExpensesScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.textContaining('المصروفات'), findsWidgets);
      expect(find.textContaining('اليوم'), findsOneWidget);
      expect(find.textContaining('بانتظار الاعتماد'), findsWidgets);
      expect(find.textContaining('السجل'), findsOneWidget);
      expect(find.text('إجمالي المصروفات المعتمدة'), findsOneWidget);
      expect(find.text('تسجيل مصروف'), findsOneWidget);
    });

    testWidgets('2. فتح حوار تسجيل مصروف جديد والتحقق من الحقول وخيار تخطي المرفق', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: ExpensesScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // الضغط على زر تسجيل مصروف
      await tester.tap(find.text('تسجيل مصروف'));
      await tester.pumpAndSettle();

      expect(find.text('تسجيل مصروف جديد'), findsOneWidget);
      expect(find.text('فئة المصروف *'), findsOneWidget);
      expect(find.text('المبلغ (ريال يمني) *'), findsOneWidget);
      expect(find.text('مصدر سداد المصروف *'), findsOneWidget);
      expect(find.text('بيان وتفاصيل المصروف *'), findsOneWidget);
      expect(find.text('تخطي إرفاق صورة السند / الفاتورة'), findsOneWidget);
      expect(find.text('حفظ المصروف'), findsOneWidget);

      // تفعيل تخطي المرفق
      await tester.tap(find.text('تخطي إرفاق صورة السند / الفاتورة'));
      await tester.pumpAndSettle();

      expect(find.text('سبب عدم توفر المرفق *'), findsOneWidget);
    });

    testWidgets('3. التبديل إلى تبويب بانتظار الاعتماد وفتح نافذة القرار للمالك', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: ExpensesScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // التبديل لتبويب بانتظار الاعتماد
      await tester.tap(find.textContaining('بانتظار الاعتماد').first);
      await tester.pumpAndSettle();

      expect(find.text('مراجعة وقرار الاعتماد'), findsOneWidget);

      // فتح نافذة القرار
      await tester.tap(find.text('مراجعة وقرار الاعتماد'));
      await tester.pumpAndSettle();

      expect(find.text('مراجعة المصروف والاعتماد'), findsOneWidget);
      expect(find.text('اعتماد المصروف'), findsOneWidget);
      expect(find.text('رفض'), findsOneWidget);
    });
  });
}

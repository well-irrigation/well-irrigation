import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/well_management/reports_analytics_screen.dart';

void main() {
  group('ReportsAnalyticsScreen Tests (UX-15 / 498–521)', () {
    testWidgets('1. عرض مؤشرات الأداء والرسوم البيانية البسيطة V1', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: ReportsAnalyticsScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('التقارير والمؤشرات العامة'), findsOneWidget);
      expect(find.text('اليوم'), findsWidgets);
      expect(find.text('هذا الأسبوع'), findsOneWidget);
      expect(find.text('هذا الشهر'), findsOneWidget);
      expect(find.text('جلسات السقي'), findsOneWidget);
      expect(find.text('استهلاك الديزل'), findsOneWidget);
      expect(find.text('المقبوضات المحصلة'), findsOneWidget);
      expect(find.text('المصروفات المعتمدة'), findsOneWidget);
      expect(find.textContaining('ساعات السقي اليومية'), findsOneWidget);
      expect(find.textContaining('توزيع ساعات السقي حسب مصدر الطاقة'), findsOneWidget);
      expect(find.textContaining('التحصيل مقابل المصروفات'), findsOneWidget);
    });

    testWidgets('2. التبديل بين الفترات الزمنية وتحديث المؤشرات', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: ReportsAnalyticsScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // التبديل إلى "اليوم"
      await tester.tap(find.text('اليوم').first);
      await tester.pumpAndSettle();

      expect(find.text('جلسات السقي'), findsOneWidget);

      // التبديل إلى "هذا الأسبوع"
      await tester.tap(find.text('هذا الأسبوع'));
      await tester.pumpAndSettle();

      expect(find.text('جلسات السقي'), findsOneWidget);
    });
  });
}

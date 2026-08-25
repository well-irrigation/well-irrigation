import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/well_management/pumps_management_screen.dart';

void main() {
  group('PumpsManagementScreen Tests (UX-15 / 466–472)', () {
    testWidgets('1. عرض قائمة المضخات وحالاتها ومواصفاتها الفنية', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: PumpsManagementScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('إدارة المضخات والمعدات'), findsOneWidget);
      expect(find.textContaining('المضخات المسجلة'), findsOneWidget);
      expect(find.textContaining('Frankline 75HP'), findsOneWidget);
      expect(find.textContaining('Caprari 50HP'), findsOneWidget);
      expect(find.text('إضافة مضخة جديدة'), findsOneWidget);
    });

    testWidgets('2. فتح نافذة إضافة مضخة جديدة والتحقق من الحقول والخيارات', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: PumpsManagementScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // فتح حوار إضافة مضخة
      await tester.tap(find.text('إضافة مضخة جديدة'));
      await tester.pumpAndSettle();

      expect(find.text('إضافة مضخة جديدة'), findsWidgets);
      expect(find.text('اسم / نوع المضخة *'), findsOneWidget);
      expect(find.text('نوع المضخة'), findsOneWidget);
      expect(find.text('القدرة (حصان) *'), findsOneWidget);
      expect(find.text('التدفق (لتر/ث)'), findsOneWidget);
      expect(find.text('معدل استهلاك الديزل التقديري (لتر/ساعة)'), findsOneWidget);
      expect(find.text('إضافة المضخة'), findsOneWidget);
    });
  });
}

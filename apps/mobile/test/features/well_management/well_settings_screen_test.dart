import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/well_management/well_settings_screen.dart';

void main() {
  group('WellSettingsScreen Tests (UX-15 / 460–465)', () {
    testWidgets('1. عرض بيانات البئر ومحدد البئر والحالة التشغيلية', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: WellSettingsScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('بيانات وإعدادات البئر'), findsOneWidget);
      expect(find.text('حالة البئر: نشط وتشغيلي'), findsOneWidget);
      expect(find.text('اسم البئر المعتمد *'), findsOneWidget);
      expect(find.text('الموقع الجغرافي / الحوض / المنطقة'), findsOneWidget);
      expect(find.text('العمق الكلي (متر)'), findsOneWidget);
      expect(find.text('منسوب المياه الساكن (متر)'), findsOneWidget);
      expect(find.text('حفظ التغييرات صراحة'), findsOneWidget);
      expect(find.textContaining('ضوابط السلامة'), findsOneWidget);
    });

    testWidgets('2. تعديل الاسم والعمق والضغط على حفظ التغييرات صراحة', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: WellSettingsScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // تغيير العمق
      final depthFinder = find.widgetWithText(TextFormField, 'العمق الكلي (متر)');
      await tester.enterText(depthFinder, '210');
      await tester.pumpAndSettle();

      // الضغط على حفظ التغييرات
      await tester.tap(find.text('حفظ التغييرات صراحة'));
      await tester.pumpAndSettle();

      expect(find.text('تم حفظ بيانات البئر بنجاح ✅'), findsOneWidget);
    });
  });
}

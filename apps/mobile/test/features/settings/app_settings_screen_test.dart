import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/settings/app_settings_screen.dart';

void main() {
  group('AppSettingsScreen Tests (UX-16A / القرارات 568–590)', () {
    testWidgets('1. عرض إعدادات المظهر والطباعة الحرارية وتفضيلات الإشعارات', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: AppSettingsScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('تفضيلات التطبيق والطباعة'), findsOneWidget);
      expect(find.text('مظهر الواجهة (Theme)'), findsOneWidget);
      expect(find.text('إعدادات الطابعة الحرارية الميدانية'), findsOneWidget);
      expect(find.text('58 مم (محمولة جيب)'), findsOneWidget);
      expect(find.text('80 مم (قياسية مكتبية)'), findsOneWidget);
      expect(find.text('تفضيلات الإشعارات والتنبيهات'), findsOneWidget);
    });

    testWidgets('2. تغيير عرض ورق الطابعة وحفظ التفضيل', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: AppSettingsScreen(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('80 مم (قياسية مكتبية)'));
      await tester.pumpAndSettle();

      expect(find.text('تم حفظ التفضيلات بنجاح ✅'), findsOneWidget);
    });
  });
}

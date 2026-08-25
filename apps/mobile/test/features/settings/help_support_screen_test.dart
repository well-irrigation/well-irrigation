import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/settings/help_support_screen.dart';

void main() {
  group('HelpSupportScreen Tests (UX-16A / القرارات 574–577)', () {
    testWidgets('1. عرض معلومات التطبيق وقنوات الدعم وسياق التشخيص', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: HelpSupportScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('نظام إدارة وتشغيل آبار الري'), findsOneWidget);
      expect(find.text('المحادثة المباشرة عبر واتساب'), findsOneWidget);
      expect(find.text('الاتصال الهاتفي المباشر'), findsOneWidget);
      expect(find.text('سياق التشخيص الفني والتقني'), findsOneWidget);
      expect(find.text('الشروط وسياسة الخصوصية'), findsOneWidget);
    });

    testWidgets('2. فتح نافذة سياق التشخيص الآمن ونسخ التقرير', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: HelpSupportScreen(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('سياق التشخيص الفني والتقني'));
      await tester.pumpAndSettle();

      expect(find.text('سياق التشخيص الآمن'), findsOneWidget);
      expect(find.text('نسخ التقرير'), findsOneWidget);
    });
  });
}

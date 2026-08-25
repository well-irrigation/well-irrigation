import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/settings/team_permissions_screen.dart';

void main() {
  group('TeamPermissionsScreen Tests (UX-16A / القرارات 546–555)', () {
    testWidgets('1. عرض قائمة أعضاء الفريق وحالاتهم وضوابط البئر', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: TeamPermissionsScreen(
            wellId: 'well-1',
            wellName: 'بئر الخير الرئيسي',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('الفريق والصلاحيات'), findsOneWidget);
      expect(find.text('بئر الخير الرئيسي'), findsOneWidget);
      expect(find.text('أعضاء الفريق المسجلون (4)'), findsOneWidget);
      expect(find.text('محمد عبدالله الشامي'), findsOneWidget);
      expect(find.text('أحمد علي الريمي'), findsOneWidget);
    });

    testWidgets('2. فتح نافذة إضافة وتعيين عضو فريق جديد', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: TeamPermissionsScreen(
            wellId: 'well-1',
            wellName: 'بئر الخير الرئيسي',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final addBtn = find.text('إضافة عضو للفريق');
      await tester.tap(addBtn);
      await tester.pumpAndSettle();

      expect(find.text('إضافة عضو جديد للفريق'), findsOneWidget);
      expect(find.text('الاسم الكامل *'), findsOneWidget);
      expect(find.text('رقم الهاتف (7xxxxxxxx) *'), findsOneWidget);
      expect(find.text('الدور التشغيلي بالبئر *'), findsOneWidget);
      expect(find.text('إضافة وتعيين'), findsOneWidget);
    });
  });
}

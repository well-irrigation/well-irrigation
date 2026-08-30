import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/settings/team_permissions_screen.dart';

void main() {
  group('TeamPermissionsScreen — Stabilization Gate', () {
    testWidgets(
      '1. لا يعرض أعضاء وهميين عند غياب عقد الفريق',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            locale: Locale('ar'),
            home: TeamPermissionsScreen(
              wellId: 'well-1',
              wellName: 'بئر الاختبار',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('الفريق والصلاحيات'),
          findsOneWidget,
        );
        expect(
          find.text('بئر الاختبار'),
          findsOneWidget,
        );
        expect(
          find.text('إدارة الفريق غير متاحة في هذه النسخة'),
          findsOneWidget,
        );
        expect(
          find.text(
            'لم يتم تغيير أي بيانات فريق من هذه الشاشة.',
          ),
          findsOneWidget,
        );

        expect(
          find.text('محمد عبدالله الشامي'),
          findsNothing,
        );
        expect(
          find.text('أحمد علي الريمي'),
          findsNothing,
        );
        expect(
          find.textContaining('أعضاء الفريق المسجلون'),
          findsNothing,
        );
      },
    );

    testWidgets(
      '2. لا يعرض أزرار إضافة أو تعطيل غير مدعومة',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            locale: Locale('ar'),
            home: TeamPermissionsScreen(
              wellId: 'well-1',
              wellName: 'بئر الاختبار',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('إضافة عضو للفريق'),
          findsNothing,
        );
        expect(
          find.text('إضافة وتعيين'),
          findsNothing,
        );
        expect(
          find.byIcon(Icons.pause_circle_outline),
          findsNothing,
        );
        expect(
          find.byIcon(Icons.play_circle_outline),
          findsNothing,
        );
      },
    );
  });
}

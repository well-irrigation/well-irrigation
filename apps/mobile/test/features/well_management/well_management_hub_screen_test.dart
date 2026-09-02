import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/well_management/well_management_hub_screen.dart';
import '../../support/identity_fixture.dart';

void main() {
  group('WellManagementHubScreen Tests (UX-15 / 460–461)', () {
    testWidgets('1. عرض أقسام إدارة البئر الأربعة والتنقل', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: WellManagementHubScreen(
            identity: testIdentity(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('إدارة البئر والمعدات والتشغيل'), findsOneWidget);
      expect(find.text('أقسام الإدارة والتشغيل:'), findsOneWidget);
      expect(find.text('بيانات وإعدادات البئر'), findsOneWidget);
      expect(find.text('المضخات والمعدات'), findsOneWidget);
      expect(find.text('تعرفة الطاقة والأسعار التاريخية'), findsOneWidget);
      expect(find.text('الوقود والخزانات والجرد'), findsOneWidget);
    });
  });
}

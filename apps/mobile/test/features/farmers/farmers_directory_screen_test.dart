import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/features/farmers/farmers_directory_screen.dart';

void main() {
  group('FarmersDirectoryScreen Tests (UX-13 / 380)', () {
    const well = WellSummary(
      id: 'well-1',
      tenantId: 'tenant-1',
      name: 'بئر الخير الرئيسي',
      status: 'active',
      roles: ['owner', 'operator'],
    );

    testWidgets('1. عرض عناصر دليل المزارعين وشريط البحث وزر الإضافة', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: FarmersDirectoryScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            wells: [well],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('دليل المزارعين والأراضي'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('مزارع جديد'), findsOneWidget);
    });

    testWidgets('2. فتح حوار إضافة مزارع جديد عند الضغط على الزر العائم', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: FarmersDirectoryScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            wells: [well],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // الضغط على زر إضافة مزارع
      await tester.tap(find.text('مزارع جديد'));
      await tester.pumpAndSettle();

      expect(find.text('إضافة مزارع جديد'), findsOneWidget);
      expect(find.text('الاسم الكامل للمزارع *'), findsOneWidget);
      expect(find.text('حفظ المزارع'), findsOneWidget);
    });
  });
}

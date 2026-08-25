import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/farmers/farmer_detail_screen.dart';

void main() {
  group('FarmerDetailScreen Tests (UX-13 / 380)', () {
    testWidgets('1. عرض الملف الشخصي للمزارع والتبويبات الثلاث', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: FarmerDetailScreen(
            wellId: 'well-1',
            farmerAccountId: 'mock-farmer-1',
            wellName: 'بئر الخير الرئيسي',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('محمد علي الحبيشي'), findsWidgets);
      expect(find.text('F-001'), findsOneWidget);
      expect(find.textContaining('الأراضي'), findsOneWidget);
      expect(find.textContaining('الجلسات'), findsOneWidget);
      expect(find.text('كشف الحساب'), findsOneWidget);
      expect(find.text('إضافة أرض'), findsOneWidget);
    });

    testWidgets('2. فتح حوار إضافة أرض جديدة للمزارع', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: FarmerDetailScreen(
            wellId: 'well-1',
            farmerAccountId: 'mock-farmer-1',
            wellName: 'بئر الخير الرئيسي',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // الضغط على زر إضافة أرض
      await tester.tap(find.text('إضافة أرض'));
      await tester.pumpAndSettle();

      expect(find.text('إضافة أرض زراعية جديدة'), findsOneWidget);
      expect(find.text('اسم الأرض أو القطعة الزراعية *'), findsOneWidget);
      expect(find.text('حفظ الأرض'), findsOneWidget);
    });

    testWidgets('3. التبديل إلى تبويب كشف الحساب والمالية', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: FarmerDetailScreen(
            wellId: 'well-1',
            farmerAccountId: 'mock-farmer-1',
            wellName: 'بئر الخير الرئيسي',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // الضغط على تبويب كشف الحساب
      await tester.tap(find.text('كشف الحساب'));
      await tester.pumpAndSettle();

      expect(find.text('إجمالي فواتير السقي:'), findsOneWidget);
      expect(find.text('إجمالي المدفوعات المسددة:'), findsOneWidget);
      expect(find.text('صافي الرصيد المتبقي:'), findsOneWidget);
    });
  });
}

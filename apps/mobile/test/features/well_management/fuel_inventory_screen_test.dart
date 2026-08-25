import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/well_management/fuel_inventory_screen.dart';

void main() {
  group('FuelInventoryScreen Tests (UX-15 / 478–490)', () {
    testWidgets('1. عرض رصيد ديزل البئر الإجمالي والخزانات والحالات', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: FuelInventoryScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('إدارة الوقود والخزانات'), findsOneWidget);
      expect(find.text('رصيد ديزل البئر المتاح'), findsOneWidget);
      expect(find.textContaining('خزانات الوقود'), findsOneWidget);
      expect(find.text('الخزان الرئيسي لمولد الديزل'), findsOneWidget);
      expect(find.text('خزان الديزل الاحتياطي'), findsOneWidget);
      expect(find.text('تسجيل شراء ديزل'), findsWidgets);
      expect(find.textContaining('فصل ملكية الوقود'), findsOneWidget);
    });

    testWidgets('2. فتح حوار تسجيل شراء ديزل جديد', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: FuelInventoryScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // فتح حوار تسجيل شراء ديزل
      await tester.tap(find.text('تسجيل شراء ديزل').first);
      await tester.pumpAndSettle();

      expect(find.text('تسجيل شراء ديزل جديد'), findsOneWidget);
      expect(find.text('الخزان المستهدف *'), findsOneWidget);
      expect(find.text('الكمية المشتراة (باللتر) *'), findsOneWidget);
      expect(find.text('التكلفة الإجمالية (ريال يمني) *'), findsOneWidget);
      expect(find.text('تأكيد وإضافة للمخزون'), findsOneWidget);
    });

    testWidgets('3. فتح حوار الجرد الفعلي وتسوية الفروقات', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: FuelInventoryScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // فتح حوار جرد وقياس فعلي
      await tester.tap(find.text('جرد وقياس فعلي').first);
      await tester.pumpAndSettle();

      expect(find.text('تسجيل جرد وقياس فعلي'), findsOneWidget);
      expect(find.text('القياس الفعلي بالخزان (لتر) *'), findsOneWidget);
      expect(find.text('فرق التسوية المحتسب:'), findsOneWidget);
      expect(find.text('سبب تسوية الفرق *'), findsOneWidget);
      expect(find.text('اعتماد الجرد والتسوية'), findsOneWidget);
    });
  });
}

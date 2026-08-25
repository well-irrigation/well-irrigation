import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/features/history/session_history_screen.dart';

void main() {
  group('SessionHistoryScreen Tests (UX-13 / 373–376)', () {
    const well = WellSummary(
      id: 'well-1',
      tenantId: 'tenant-1',
      name: 'بئر الخير الرئيسي',
      status: 'active',
      roles: ['owner', 'operator'],
    );

    testWidgets('1. عرض عناصر شاشة سجل الجلسات وشريط البحث والفلاتر', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: SessionHistoryScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            wells: [well],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('سجل جلسات السقي والتاريخ'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('الكل'), findsOneWidget);
      expect(find.text('اليوم'), findsOneWidget);
      expect(find.text('هذا الأسبوع'), findsOneWidget);
      expect(find.text('هذا الشهر'), findsOneWidget);
      expect(find.text('غير مسددة'), findsOneWidget);
    });

    testWidgets('2. عرض بطاقات الجلسات ومؤشرات السداد والمدة والمبالغ', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: SessionHistoryScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            wells: [well],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // التحقق من ظهور بطاقات الجلسات
      expect(find.text('محمد علي الحبيشي'), findsWidgets);
      expect(find.text('صالح أحمد الشامي'), findsOneWidget);
      expect(find.text('خالص بالكامل ✅'), findsWidgets);
      expect(find.text('طاقة شمسية'), findsWidgets);
      expect(find.text('ديزل'), findsWidgets);
    });

    testWidgets('3. البحث الفوري بالاسم يقلص القائمة', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: SessionHistoryScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            wells: [well],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // كتابة اسم في مربع البحث
      await tester.enterText(find.byType(TextField), 'صالح');
      await tester.pumpAndSettle();

      expect(find.text('صالح أحمد الشامي'), findsOneWidget);
      expect(find.text('عبدالله مسعد القادري'), findsNothing);
    });
  });
}

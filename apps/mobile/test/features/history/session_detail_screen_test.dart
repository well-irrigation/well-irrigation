import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/history/session_detail_screen.dart';

void main() {
  group('SessionDetailScreen Tests (UX-13 / 377)', () {
    testWidgets('1. عرض تفاصيل الجلسة والخط الزمني والمستحق المالي', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: SessionDetailScreen(
            sessionId: 'mock-session-1',
            wellName: 'بئر الخير الرئيسي',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('محمد علي الحبيشي'), findsOneWidget);
      expect(find.text('بئر الخير الرئيسي'), findsOneWidget);
      expect(find.text('المضخة الرئيسية 1'), findsOneWidget);
      expect(find.text('خالد النجحي'), findsOneWidget);
      expect(find.text('الخط الزمني وتغيرات الطاقة (Timeline)'), findsOneWidget);
      expect(find.text('تشغيل عبر طاقة شمسية'), findsOneWidget);
      expect(find.text('توقف مؤقت للسقي'), findsOneWidget);
      expect(find.text('تشغيل عبر ديزل'), findsOneWidget);
      expect(find.text('تفاصيل السداد وسند القبض'), findsOneWidget);
      expect(find.text('طباعة الفاتورة'), findsOneWidget);
      expect(find.text('مشاركة الإيصال'), findsOneWidget);
    });

    testWidgets('2. فتح نافذة معاينة الفاتورة الحرارية عند الضغط على طباعة', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: SessionDetailScreen(
            sessionId: 'mock-session-1',
            wellName: 'بئر الخير الرئيسي',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // الضغط على زر طباعة الفاتورة
      await tester.tap(find.text('طباعة الفاتورة'));
      await tester.pumpAndSettle();

      expect(find.text('معاينة الفاتورة الحرارية (58mm)'), findsOneWidget);
      expect(find.text('إرسال للطابعة'), findsOneWidget);
    });
  });
}

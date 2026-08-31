import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/features/history/session_detail_screen.dart';

/// مستودع اختبار يحاكي عقد `api.get_session_detail` (م-41C2).
/// الشاشة لم تعد تملك تفصيلًا وهميًا: عقد حقيقي أو فشل صريح.
class _FakeOperationsRepository extends OperationsRepository {
  const _FakeOperationsRepository({
    this.shouldFail = false,
    this.billed = true,
  });

  final bool shouldFail;
  final bool billed;

  @override
  Future<SessionDetailData> fetchSessionDetail(String sessionId) async {
    if (shouldFail) {
      throw StateError('backend unavailable');
    }

    final started = DateTime(2026, 8, 31, 9);

    return SessionDetailData(
      session: SessionHistoryItem(
        id: sessionId,
        wellId: 'well-1',
        farmerName: 'محمد علي الحبيشي',
        farmerCode: 'F-001',
        farmerAccountId: 'acc-1',
        farmName: 'مزرعة الوادي الشرقية',
        pumpName: 'المضخة الرئيسية 1',
        operatorName: 'خالد النجحي',
        startedAt: started,
        endedAt: started.add(const Duration(hours: 1)),
        energySourceCode: 'solar',
        billableSeconds: billed ? 3000 : 0,
        totalAmountYER: billed ? 2917 : 0,
        paidAmountYER: billed ? 2917 : 0,
        paymentStatus: billed ? 'settled' : 'not_billed',
        hasCharge: billed,
        hasInvoice: billed,
      ),
      segments: [
        SessionSegmentItem(
          sequenceNumber: 1,
          segmentType: 'solar_run',
          isStop: false,
          isBillable: true,
          energySourceCode: 'solar',
          startedAt: started,
          endedAt: started.add(const Duration(minutes: 50)),
          actualSeconds: 3000,
          billableSeconds: 3000,
          appliedRateYER: 3500,
          timeChargeYER: 2917,
          totalChargeYER: 2917,
        ),
        SessionSegmentItem(
          sequenceNumber: 2,
          segmentType: 'operator_pause',
          isStop: true,
          isBillable: false,
          startedAt: started.add(const Duration(minutes: 50)),
          endedAt: started.add(const Duration(hours: 1)),
          actualSeconds: 600,
        ),
        SessionSegmentItem(
          sequenceNumber: 3,
          segmentType: 'well_diesel_run',
          isStop: false,
          isBillable: true,
          energySourceCode: 'well_diesel',
          startedAt: started.add(const Duration(hours: 1)),
          actualSeconds: 1800,
          billableSeconds: 1800,
          appliedRateYER: 3500,
          timeChargeYER: 1750,
          totalChargeYER: 1750,
        ),
      ],
      paymentMethod: billed ? 'cash' : null,
      paymentReference: billed ? 'PMT-090-A' : null,
      paidAt: billed ? started.add(const Duration(hours: 2)) : null,
    );
  }
}

Widget _wrap({bool shouldFail = false, bool billed = true}) {
  return MaterialApp(
    locale: const Locale('ar'),
    home: SessionDetailScreen(
      sessionId: 'ses-090-a',
      wellName: 'بئر الخير الرئيسي',
      repository: _FakeOperationsRepository(
        shouldFail: shouldFail,
        billed: billed,
      ),
    ),
  );
}

void main() {
  group('SessionDetailScreen Tests (UX-13 / 377)', () {
    testWidgets('1. عرض تفاصيل الجلسة والخط الزمني والمستحق المالي', (tester) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      expect(find.text('محمد علي الحبيشي'), findsOneWidget);
      expect(find.text('بئر الخير الرئيسي'), findsOneWidget);
      expect(find.text('المضخة الرئيسية 1'), findsOneWidget);
      expect(find.text('خالد النجحي'), findsOneWidget);
      expect(find.text('الخط الزمني وتغيرات الطاقة (Timeline)'), findsOneWidget);
      expect(find.text('تشغيل عبر طاقة شمسية'), findsOneWidget);
      expect(find.text('إيقاف من المشغل'), findsOneWidget);
      expect(find.text('تشغيل عبر ديزل البئر'), findsOneWidget);
      expect(find.text('تفاصيل السداد وسند القبض'), findsOneWidget);
      expect(find.text('طباعة الفاتورة'), findsOneWidget);
      expect(find.text('مشاركة الإيصال'), findsOneWidget);
    });

    testWidgets('2. المقطع يعرض المبلغ المخزّن والتسعيرة المثبتة بلا حساب محلي', (tester) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      expect(find.textContaining('2,917 ريال'), findsWidgets);
      expect(find.textContaining('التسعيرة المثبتة'), findsWidgets);
      expect(find.textContaining('محسوب على المزارع: لا'), findsOneWidget);
    });

    testWidgets('3. فتح نافذة معاينة الفاتورة الحرارية عند الضغط على طباعة', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('طباعة الفاتورة'));
      await tester.pumpAndSettle();

      expect(find.text('معاينة الفاتورة الحرارية (58mm)'), findsOneWidget);
      expect(find.text('إرسال للطابعة'), findsOneWidget);
    });

    testWidgets('4. الجلسة غير المفوترة لا تُطبع ولا تُفقَّط (ق-99)', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(_wrap(billed: false));
      await tester.pumpAndSettle();

      expect(find.text('غير مفوترة بعد'), findsOneWidget);
      expect(find.text('لم تُفوتر بعد'), findsOneWidget);
      expect(find.textContaining('فقط '), findsNothing);
      expect(find.text('طريقة السداد: غير مسجلة'), findsOneWidget);

      await tester.tap(find.text('طباعة الفاتورة'));
      await tester.pumpAndSettle();

      expect(find.text('معاينة الفاتورة الحرارية (58mm)'), findsNothing);
      expect(
        find.textContaining('هذه الجلسة غير مفوترة بعد'),
        findsOneWidget,
      );
    });

    testWidgets('5. فشل العقد يظهر خطأً صريحًا مع إعادة المحاولة', (tester) async {
      await tester.pumpWidget(_wrap(shouldFail: true));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('تعذّر تحميل تفاصيل الجلسة'),
        findsOneWidget,
      );
      expect(find.text('إعادة المحاولة'), findsOneWidget);
    });
  });
}

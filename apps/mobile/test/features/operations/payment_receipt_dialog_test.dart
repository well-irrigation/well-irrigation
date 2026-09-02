import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/payment_receipt_dialog.dart';

void main() {
  group('PaymentReceiptDialog Widget Tests (UX-10 / ق-91 / esc-pos-printer)', () {
    testWidgets('عرض تفاصيل الفاتورة والمستحق والتفقيط بالريال والطباعة ومعاينة الإيصال', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      int? capturedPaidAmount;
      String? capturedMethod;
      bool? capturedSettled;

      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: PaymentReceiptDialog(
                wellName: 'بئر الوادي الحديث',
                operatorName: 'خالد النجحي',
                farmerName: 'محمد عبدالله الشامي',
                farmName: 'أرض الجربة',
                energySource: 'طاقة شمسية',
                hourlyRateYER: 3500,
                billableSeconds: 7200, // ساعتان
                totalAmountYER: 7000,
                onConfirmPayment: ({
                  required int paidAmountYER,
                  required String paymentMethod,
                  required bool isFullySettled,
                }) async {
                  capturedPaidAmount = paidAmountYER;
                  capturedMethod = paymentMethod;
                  capturedSettled = isFullySettled;
                },
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // التحقق من الحقول الأساسية
      expect(find.text('اعتماد الجلسة وسند السداد'), findsOneWidget);
      expect(find.text('المزارع: محمد عبدالله الشامي'), findsOneWidget);
      expect(find.text('سبعة آلاف ريال'), findsWidgets);
      expect(find.text('خالص بالكامل ✅'), findsOneWidget);

      // معاينة الإيصال الحراري
      final previewFinder = find.text('معاينة قالب الإيصال الحراري (58mm)');
      expect(previewFinder, findsOneWidget);
      await tester.ensureVisible(previewFinder);
      await tester.tap(previewFinder);
      await tester.pumpAndSettle();

      expect(find.text('إخفاء معاينة الإيصال'), findsOneWidget);

      // اختبار النقر على حفظ واعتماد
      final saveFinder = find.text('حفظ واعتماد');
      await tester.ensureVisible(saveFinder);
      await tester.tap(saveFinder);
      await tester.pumpAndSettle();


      expect(capturedPaidAmount, 7000);
      expect(capturedMethod, 'نقد');
      expect(capturedSettled, isTrue);
    });

    testWidgets('زر الطباعة يعلن عدم توفرها ولا يدّعي إرسال أمر طباعة (ق-113 / م-41D4)',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: PaymentReceiptDialog(
                wellName: 'بئر الوادي الحديث',
                operatorName: 'خالد النجحي',
                farmerName: 'محمد عبدالله الشامي',
                farmName: 'أرض الجربة',
                energySource: 'طاقة شمسية',
                hourlyRateYER: 3500,
                billableSeconds: 7200,
                totalAmountYER: 7000,
                onConfirmPayment: ({
                  required int paidAmountYER,
                  required String paymentMethod,
                  required bool isFullySettled,
                }) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final printFinder = find.text('طباعة حرارية (غير متاحة)');
      expect(printFinder, findsOneWidget);
      await tester.ensureVisible(printFinder);
      await tester.tap(printFinder);
      await tester.pumpAndSettle();

      // لا «تم إرسال أمر الطباعة» بعد الآن: لا تكامل بلوتوث في هذا الإصدار.
      expect(
        find.text(
          'الطباعة الحرارية غير متاحة في هذا الإصدار — لم يُرسل أمر طباعة',
        ),
        findsOneWidget,
      );
    });
  });
}

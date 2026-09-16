import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/payment_receipt_dialog.dart';

void main() {
  group('PaymentReceiptDialog Widget Tests (UX-10 / ق-91 / esc-pos-printer)', () {
    testWidgets(
      'عرض تفاصيل الفاتورة والمستحق والتفقيط بالريال والطباعة ومعاينة الإيصال',
      (tester) async {
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
                  onConfirmPayment:
                      ({
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
        expect(find.text('تسجيل دفعة'), findsOneWidget);
        expect(find.text('اعتماد الجلسة وسند السداد'), findsNothing);
        expect(find.text('المزارع: محمد عبدالله الشامي'), findsOneWidget);
        expect(find.text('سبعة آلاف ريال'), findsWidgets);
        expect(find.text('خالص بالكامل ✅'), findsOneWidget);
        expect(find.textContaining('ريال يمني'), findsNothing);
        expect(find.textContaining('ثلاثة آلاف وخمسمائة ريال'), findsOneWidget);

        // معاينة الإيصال الحراري
        final previewFinder = find.text('معاينة قالب الإيصال الحراري (58mm)');
        expect(previewFinder, findsOneWidget);
        await tester.ensureVisible(previewFinder);
        await tester.tap(previewFinder);
        await tester.pumpAndSettle();

        expect(find.text('إخفاء معاينة الإيصال'), findsOneWidget);
        expect(find.textContaining('ريال يمني'), findsNothing);
        expect(
          find.textContaining('سعر الساعة كتابة: ثلاثة آلاف وخمسمائة ريال'),
          findsOneWidget,
        );
        expect(
          find.textContaining('المدفوع كتابة: سبعة آلاف ريال'),
          findsOneWidget,
        );

        // اختبار النقر على حفظ واعتماد
        final saveFinder = find.text('حفظ واعتماد');
        await tester.ensureVisible(saveFinder);
        await tester.tap(saveFinder);
        await tester.pumpAndSettle();

        expect(capturedPaidAmount, 7000);
        expect(capturedMethod, 'cash');
        expect(capturedSettled, isTrue);
      },
    );

    testWidgets('يفرّق بين الدين والسداد المطابق والرصيد المقدم', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: PaymentReceiptDialog(
                wellName: 'بئر 1',
                operatorName: 'مشغل',
                farmerName: 'مزارع',
                farmName: 'أرض',
                energySource: 'شمسي',
                hourlyRateYER: 3500,
                billableSeconds: 7200,
                totalAmountYER: 7000,
                onConfirmPayment: ({
                  required paidAmountYER,
                  required paymentMethod,
                  required isFullySettled,
                }) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final input = find.byType(TextFormField);
      await tester.enterText(input, '5000');
      await tester.pump();
      expect(find.text('المتبقي (دين على المزارع):'), findsOneWidget);
      expect(find.textContaining('2,000'), findsOneWidget);
      expect(find.textContaining('ألفان ريال'), findsOneWidget);

      await tester.enterText(input, '7000');
      await tester.pump();
      expect(find.text('خالص بالكامل ✅'), findsOneWidget);

      await tester.enterText(input, '8000');
      await tester.pump();
      expect(find.text('رصيد مقدم:'), findsOneWidget);
      expect(find.textContaining('1,000'), findsOneWidget);
      expect(find.textContaining('ألف ريال'), findsOneWidget);
    });

    testWidgets('الحفظ المتكرر أثناء الانتظار يسجل دفعة واحدة فقط', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      final gate = Completer<void>();
      var calls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: PaymentReceiptDialog(
                wellName: 'بئر 1',
                operatorName: 'مشغل',
                farmerName: 'مزارع',
                farmName: 'أرض',
                energySource: 'شمسي',
                hourlyRateYER: 3500,
                billableSeconds: 7200,
                totalAmountYER: 7000,
                onConfirmPayment:
                    ({
                      required paidAmountYER,
                      required paymentMethod,
                      required isFullySettled,
                    }) async {
                      calls += 1;
                      await gate.future;
                    },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final save = find.text('حفظ واعتماد');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pump();
      await tester.tap(save, warnIfMissed: false);
      await tester.pump();
      expect(calls, 1);

      gate.complete();
      await tester.pumpAndSettle();
      expect(calls, 1);
    });

    testWidgets(
      'زر الطباعة يعلن عدم توفرها ولا يدّعي إرسال أمر طباعة (ق-113 / م-41D4)',
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
      },
    );
  });
}

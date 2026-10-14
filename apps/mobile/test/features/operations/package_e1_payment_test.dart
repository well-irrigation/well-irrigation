import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/payment_receipt_dialog.dart';

void main() {
  testWidgets('فشل حفظ الدفعة يبقي الطلب مفتوحا ولا يدعي السداد', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaymentReceiptDialog(
            wellName: 'بئر',
            operatorName: 'مشغل',
            farmerName: 'مزارع',
            farmName: 'أرض',
            energySource: 'شمسي',
            hourlyRateYER: null,
            billableSeconds: 60,
            totalAmountYER: 60,
            onConfirmPayment:
                ({
                  required paidAmountYER,
                  required paymentMethod,
                  required isFullySettled,
                }) async {
                  throw StateError('تعذر الحفظ');
                },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('حفظ طلب الدفعة'));
    await tester.tap(find.text('حفظ طلب الدفعة'));
    await tester.pumpAndSettle();
    expect(find.byType(PaymentReceiptDialog), findsOneWidget);
    expect(find.textContaining('خطأ أثناء الحفظ'), findsOneWidget);
    expect(find.textContaining('خالص'), findsNothing);
    expect(find.textContaining('تم إصدار سند'), findsNothing);
  });
  testWidgets('طلب الدفعة لا يدعي الخلوص أو يصنع فاتورة قبل الإقرار', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaymentReceiptDialog(
            wellName: 'بئر',
            operatorName: 'مشغل',
            farmerName: 'مزارع',
            farmName: 'أرض',
            energySource: 'شمسي',
            hourlyRateYER: 3600,
            billableSeconds: 60,
            totalAmountYER: 60,
            onConfirmPayment: ({
              required paidAmountYER,
              required paymentMethod,
              required isFullySettled,
            }) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('خالص'), findsNothing);
    await tester.tap(find.text('معاينة ملخص طلب الدفعة'));
    await tester.pumpAndSettle();
    expect(find.textContaining('INV-'), findsNothing);
    expect(find.textContaining('ليس سند قبض'), findsOneWidget);
  });
}

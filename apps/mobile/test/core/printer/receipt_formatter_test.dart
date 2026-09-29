import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/printer/receipt_formatter.dart';

void main() {
  group('ReceiptFormatter Tests (esc-pos-printer)', () {
    test('توليد قالب فاتورة السقي قياس 58mm', () {
      final text = ReceiptFormatter.formatSessionInvoice(
        wellName: 'بئر النور الحديث',
        invoiceNumber: 'INV-2026-001',
        date: DateTime(2026, 8, 25, 10, 30),
        operatorName: 'خالد النجحي',
        farmerName: 'محمد عبدالله الشامي',
        farmName: 'أرض الوادي',
        energySource: 'طاقة شمسية',
        hourlyRateYER: 3500,
        billableSeconds: 7200,
        totalAmountYER: 7000,
        paidAmountYER: 7000,
      );

      expect(text, contains('بئر النور الحديث'));
      expect(text, contains('فاتورة جلسة سقي ومياه'));
      expect(text, contains('رقم الفاتورة: INV-2026-001'));
      expect(text, contains('المزارع: محمد عبدالله الشامي'));
      expect(text, contains('المبلغ الإجمالي: 7,000 ريال يمني'));
      expect(text, contains('المبلغ كتابة: سبعة آلاف ريال'));
      expect(text, contains('المدفوع نقداً: 7,000 ريال'));
      expect(text, contains('المتبقي: 0 ريال'));
    });

    test('توليد قالب سند قبض نقدي', () {
      final text = ReceiptFormatter.formatPaymentReceipt(
        wellName: 'بئر النور الحديث',
        receiptNumber: 'REC-101',
        date: DateTime(2026, 8, 25, 11, 0),
        operatorName: 'خالد النجحي',
        farmerName: 'صالح أحمد الشامي',
        amountYER: 15000,
        paymentMethod: 'نقد',
        reference: 'دفعة حساب سابق',
      );

      expect(text, contains('سند قبض نقدي'));
      expect(text, contains('رقم السند: REC-101'));
      expect(text, contains('المستلم منه: صالح أحمد الشامي'));
      expect(text, contains('المبلغ المقبوض: 15,000 ريال يمني'));
      expect(text, contains('خمسة عشر ألف ريال'));
      expect(text, contains('البيان / المرجع: دفعة حساب سابق'));
    });

    test('الفعلي أولًا والمفوتر مميزًا حين يختلفان (ق-131 البند 7)', () {
      // 50 دقيقة تشغيل فعلية + 10 دقائق توقف: فعلي 3600 ومفوتر 3000.
      final text = ReceiptFormatter.formatSessionInvoice(
        wellName: 'بئر النور الحديث',
        invoiceNumber: 'INV-ACT-001',
        date: DateTime(2026, 9, 10, 9, 0),
        operatorName: 'خالد النجحي',
        farmerName: 'محمد عبدالله الشامي',
        farmName: 'أرض الوادي',
        energySource: 'طاقة شمسية',
        hourlyRateYER: 3600,
        actualSeconds: 3600,
        billableSeconds: 3000,
        totalAmountYER: 3000,
        paidAmountYER: 0,
      );

      expect(text, contains('- مدة التنفيذ الفعلية: 1 ساعة و 0 دقيقة'));
      expect(text, contains('- الوقت المفوتر: 0 ساعة و 50 دقيقة'));
      // لا يظهر المفوتر بوصفه «المدة» ولا العكس.
      expect(text, isNot(contains('- المدة:')));
      // المبلغ من المفوتر المخزَّن لا من الفعلي.
      expect(text, contains('المبلغ الإجمالي: 3,000 ريال يمني'));
    });

    test('تطابق الفعلي والمفوتر يعرض سطر الفعلي وحده بلا سطر مفوتر', () {
      final text = ReceiptFormatter.formatSessionInvoice(
        wellName: 'بئر النور الحديث',
        invoiceNumber: 'INV-ACT-002',
        date: DateTime(2026, 9, 10, 9, 0),
        operatorName: 'خالد النجحي',
        farmerName: 'محمد عبدالله الشامي',
        farmName: 'أرض الوادي',
        energySource: 'طاقة شمسية',
        hourlyRateYER: 3600,
        actualSeconds: 7200,
        billableSeconds: 7200,
        totalAmountYER: 7200,
        paidAmountYER: 7200,
      );

      expect(text, contains('- مدة التنفيذ الفعلية: 2 ساعة و 0 دقيقة'));
      expect(text, isNot(contains('الوقت المفوتر')));
    });

    test('غياب الفعلي: المفوتر بعنوانه الصريح ولا «المدة» العامة (ق-131)', () {
      final text = ReceiptFormatter.formatSessionInvoice(
        wellName: 'بئر النور الحديث',
        invoiceNumber: 'INV-ACT-003',
        date: DateTime(2026, 9, 10, 9, 0),
        operatorName: 'خالد النجحي',
        farmerName: 'محمد عبدالله الشامي',
        farmName: 'أرض الوادي',
        energySource: 'طاقة شمسية',
        hourlyRateYER: 3600,
        billableSeconds: 7200,
        totalAmountYER: 7200,
        paidAmountYER: 7200,
      );

      expect(text, contains('- الوقت المفوتر: 2 ساعة و 0 دقيقة'));
      // التسمية العامة الملتبسة زالت من كل المسارات.
      expect(text, isNot(contains('- المدة:')));
      expect(text, isNot(contains('مدة التنفيذ الفعلية')));
      expect(text, isNot(contains('مدة السقي الفعلية')));
    });
  });
}

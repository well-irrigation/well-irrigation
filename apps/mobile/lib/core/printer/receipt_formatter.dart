import '../utils/currency_utils.dart';
import '../utils/tafqeet_utils.dart';

/// تنسيق وقوالب الفواتير وسندات القبض الحرارية (ESC/POS Thermal Printer - قياس 58mm و 80mm)
class ReceiptFormatter {
  /// توليد قالب نصي لفاتورة جلسة سقي مكتملة
  static String formatSessionInvoice({
    required String wellName,
    required String invoiceNumber,
    required DateTime date,
    required String operatorName,
    required String farmerName,
    required String farmName,
    required String energySource,
    required int hourlyRateYER,
    required int billableSeconds,
    required int totalAmountYER,
    required int paidAmountYER,
    int widthChars = 32, // 32 لـ 58mm، 48 لـ 80mm
  }) {
    final separator = '=' * widthChars;
    final subSeparator = '-' * widthChars;
    final hours = billableSeconds ~/ 3600;
    final minutes = (billableSeconds % 3600) ~/ 60;
    final remainingAmount = totalAmountYER - paidAmountYER;
    final tafqeetText = Tafqeet.format(totalAmountYER);

    final dateStr = '${date.year}-${_twoDigits(date.month)}-${_twoDigits(date.day)}';
    final timeStr = '${_twoDigits(date.hour)}:${_twoDigits(date.minute)}';

    final buffer = StringBuffer();
    buffer.writeln(separator);
    buffer.writeln(_centerText(wellName, widthChars));
    buffer.writeln(_centerText('فاتورة جلسة سقي ومياه', widthChars));
    buffer.writeln(separator);

    buffer.writeln('رقم الفاتورة: $invoiceNumber');
    buffer.writeln('التاريخ: $dateStr  الوقت: $timeStr');
    buffer.writeln('المشغل: $operatorName');
    buffer.writeln('المزارع: $farmerName');
    buffer.writeln('الأرض: $farmName');
    buffer.writeln(subSeparator);

    buffer.writeln('تفاصيل التشغيل:');
    buffer.writeln('- المدة: $hours ساعة و $minutes دقيقة');
    buffer.writeln('- المصدر: $energySource');
    buffer.writeln('- سعر الساعة: ${CurrencyUtils.formatAmount(hourlyRateYER)} ريال');
    buffer.writeln(subSeparator);

    buffer.writeln('المبلغ الإجمالي: ${CurrencyUtils.formatAmount(totalAmountYER)} ريال يمني');
    buffer.writeln('المبلغ كتابة: $tafqeetText');
    buffer.writeln(subSeparator);

    buffer.writeln('المدفوع نقداً: ${CurrencyUtils.formatAmount(paidAmountYER)} ريال');
    buffer.writeln('المتبقي: ${CurrencyUtils.formatAmount(remainingAmount)} ريال');
    buffer.writeln(separator);
    buffer.writeln(_centerText('شكراً لتعاملكم معنا', widthChars));
    buffer.writeln(separator);

    return buffer.toString();
  }

  /// توليد قالب نصي لسند قبض دفعة مالية
  static String formatPaymentReceipt({
    required String wellName,
    required String receiptNumber,
    required DateTime date,
    required String operatorName,
    required String farmerName,
    required int amountYER,
    required String paymentMethod,
    String? reference,
    int widthChars = 32,
  }) {
    final separator = '=' * widthChars;
    final subSeparator = '-' * widthChars;
    final tafqeetText = Tafqeet.format(amountYER);

    final dateStr = '${date.year}-${_twoDigits(date.month)}-${_twoDigits(date.day)}';
    final timeStr = '${_twoDigits(date.hour)}:${_twoDigits(date.minute)}';

    final buffer = StringBuffer();
    buffer.writeln(separator);
    buffer.writeln(_centerText(wellName, widthChars));
    buffer.writeln(_centerText('سند قبض نقدي', widthChars));
    buffer.writeln(separator);

    buffer.writeln('رقم السند: $receiptNumber');
    buffer.writeln('التاريخ: $dateStr  الوقت: $timeStr');
    buffer.writeln('المشغل: $operatorName');
    buffer.writeln('المستلم منه: $farmerName');
    buffer.writeln(subSeparator);

    buffer.writeln('المبلغ المقبوض: ${CurrencyUtils.formatAmount(amountYER)} ريال يمني');
    buffer.writeln('المبلغ كتابة: $tafqeetText');
    buffer.writeln('طريقة الدفع: $paymentMethod');
    if (reference != null && reference.isNotEmpty) {
      buffer.writeln('البيان / المرجع: $reference');
    }
    buffer.writeln(separator);
    buffer.writeln(_centerText('توقيع المشغل / الختم', widthChars));
    buffer.writeln('\n');
    buffer.writeln(separator);

    return buffer.toString();
  }


  static String _centerText(String text, int width) {
    if (text.length >= width) return text;
    final padding = (width - text.length) ~/ 2;
    return ' ' * padding + text;
  }

  static String _twoDigits(int n) => n.toString().padLeft(2, '0');
}

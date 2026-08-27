import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'digit_utils.dart';

/// أدوات تنسيق العملات والمبالغ المالية
class CurrencyUtils {
  /// تنسيق رقم بإضافة فواصل الآلاف (مثال: 3500 -> "3,500")
  static String formatAmount(num amount) {
    if (amount == 0) return '0';

    final isNegative = amount < 0;
    final absAmount = amount.abs();

    final parts = absAmount.toString().split('.');
    final integerPart = parts[0];
    final decimalPart = parts.length > 1 && parts[1] != '0' ? parts[1] : null;

    final buffer = StringBuffer();
    final length = integerPart.length;

    for (var i = 0; i < length; i++) {
      if (i > 0 && (length - i) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(integerPart[i]);
    }

    if (decimalPart != null && decimalPart.isNotEmpty) {
      buffer.write('.');
      buffer.write(decimalPart);
    }

    final formatted = buffer.toString();
    return isNegative ? '-$formatted' : formatted;
  }

  /// تحويل نص منسق بالفواصل إلى عدد صحيح نظيف (مثال: "10,000" -> 10000)
  static int parseRawInt(String input) {
    final cleaned = normalizeArabicDigits(input).replaceAll(RegExp(r'[^\d]'), '');
    return int.tryParse(cleaned) ?? 0;
  }

}

/// مُنسِّق إدخال ديناميكي يضيف الفواصل الألفية لحظياً أثناء الكتابة
/// ويحافظ على موضع المؤشر بدقة متناهية
class ThousandsSeparatorInputFormatter extends TextInputFormatter {
  const ThousandsSeparatorInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // 1. تحويل الأرقام العربية إلى إنجليزية وتجريد أي رموز غير رقمية
    final normalizedText = normalizeArabicDigits(newValue.text);
    final rawDigits = normalizedText.replaceAll(RegExp(r'[^\d]'), '');

    if (rawDigits.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }

    // 2. تنسيق الأرقام بإضافة الفواصل
    final buffer = StringBuffer();
    final len = rawDigits.length;

    for (var i = 0; i < len; i++) {
      if (i > 0 && (len - i) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(rawDigits[i]);
    }

    final formattedText = buffer.toString();

    // 3. حساب موضع المؤشر الذكي الجديد
    // نحدد كم رقم حقيقي كان قبل المؤشر في النص الجديد
    final rawCursorPosition = newValue.selection.baseOffset;
    final textBeforeCursor = newValue.text.substring(
      0,
      math.min(rawCursorPosition, newValue.text.length),
    );
    final digitsBeforeCursor =
        normalizeArabicDigits(textBeforeCursor).replaceAll(RegExp(r'[^\d]'), '').length;

    // الآن نجد الموضع المقابل في النص المنسق الجديد
    var newCursorOffset = 0;
    var countedDigits = 0;

    for (var i = 0; i < formattedText.length; i++) {
      if (formattedText[i] != ',') {
        countedDigits++;
      }
      if (countedDigits == digitsBeforeCursor) {
        newCursorOffset = i + 1;
        break;
      }
    }

    if (digitsBeforeCursor == 0) {
      newCursorOffset = 0;
    } else if (newCursorOffset == 0) {
      newCursorOffset = formattedText.length;
    }

    newCursorOffset = newCursorOffset.clamp(0, formattedText.length);

    return TextEditingValue(
      text: formattedText,
      selection: TextSelection.collapsed(offset: newCursorOffset),
    );
  }
}

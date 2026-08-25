import 'package:flutter/services.dart';

/// تحويل الأرقام العربية والفارسية إلى أرقام إنجليزية موحدة (0-9)
String normalizeArabicDigits(String input) {
  const arabicDigits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
  const easternArabicDigits = [
    '۰',
    '۱',
    '۲',
    '۳',
    '۴',
    '۵',
    '۶',
    '۷',
    '۸',
    '۹'
  ];

  var result = input;
  for (var i = 0; i < 10; i++) {
    result = result
        .replaceAll(arabicDigits[i], '$i')
        .replaceAll(easternArabicDigits[i], '$i');
  }
  return result;
}

/// مُنسّق حقول الإدخال: يحوّل الأرقام العربية إلى إنجليزية لحظياً أثناء الكتابة ويعرضها بالإنجليزية
class ArabicToEnglishDigitsFormatter extends TextInputFormatter {
  const ArabicToEnglishDigitsFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final converted = normalizeArabicDigits(newValue.text);
    if (converted == newValue.text) {
      return newValue;
    }
    return TextEditingValue(
      text: converted,
      selection: TextSelection.collapsed(
        offset: newValue.selection.baseOffset.clamp(0, converted.length),
      ),
    );
  }
}

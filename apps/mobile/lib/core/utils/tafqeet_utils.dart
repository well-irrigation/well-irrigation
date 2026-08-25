/// خوارزمية التفقيط المالي الذكية بالريال اليمني
///
/// تحويل المبالغ الرقمية إلى نصوص عربية مالية فصيحة ومألوفة لحظياً وفق الاستخدام المالي اليمني.
class Tafqeet {
  static const List<String> _ones = [
    '',
    'واحد',
    'اثنان',
    'ثلاثة',
    'أربعة',
    'خمسة',
    'ستة',
    'سبعة',
    'ثمانية',
    'تسعة',
  ];

  static const List<String> _tens = [
    '',
    'عشرة',
    'عشرون',
    'ثلاثون',
    'أربعون',
    'خمسون',
    'ستون',
    'سبعون',
    'ثمانون',
    'تسعون',
  ];

  static const List<String> _hundreds = [
    '',
    'مائة',
    'مائتان',
    'ثلاثمائة',
    'أربعمائة',
    'خمسمائة',
    'ستمائة',
    'سبعمائة',
    'ثمانمائة',
    'تسعمائة',
  ];

  /// تفقيط عدد مكون من 1 إلى 3 خانات (0 - 999)
  static String _convertThreeDigits(int number) {
    if (number == 0) return '';

    final parts = <String>[];

    final hundred = number ~/ 100;
    final remainder = number % 100;

    if (hundred > 0) {
      parts.add(_hundreds[hundred]);
    }

    if (remainder > 0) {
      if (remainder == 1) {
        parts.add('واحد');
      } else if (remainder == 2) {
        parts.add('اثنان');
      } else if (remainder == 11) {
        parts.add('أحد عشر');
      } else if (remainder == 12) {
        parts.add('اثنا عشر');
      } else if (remainder > 12 && remainder < 20) {
        final unit = remainder % 10;
        parts.add('${_ones[unit]} عشر');
      } else {
        final unit = remainder % 10;
        final ten = remainder ~/ 10;

        final subParts = <String>[];
        if (unit > 0) {
          subParts.add(_ones[unit]);
        }
        if (ten > 0) {
          subParts.add(_tens[ten]);
        }
        parts.add(subParts.join(' و'));
      }
    }

    return parts.join(' و');
  }

  /// تحويل رقم صحيح إلى نص عربي بالريال اليمني
  static String format(int amount, {bool appendCurrency = true}) {
    if (amount <= 0) {
      return appendCurrency ? 'صفر ريال' : 'صفر';
    }

    final billions = (amount ~/ 1000000000) % 1000;
    final millions = (amount ~/ 1000000) % 1000;
    final thousands = (amount ~/ 1000) % 1000;
    final units = amount % 1000;

    final resultParts = <String>[];

    // 1. المليارات
    if (billions > 0) {
      if (billions == 1) {
        resultParts.add('مليار');
      } else if (billions == 2) {
        resultParts.add('ملياران');
      } else if (billions >= 3 && billions <= 10) {
        resultParts.add('${_convertThreeDigits(billions)} مليارات');
      } else {
        resultParts.add('${_convertThreeDigits(billions)} مليار');
      }
    }

    // 2. الملايين
    if (millions > 0) {
      if (millions == 1) {
        resultParts.add('مليون');
      } else if (millions == 2) {
        resultParts.add('مليونان');
      } else if (millions >= 3 && millions <= 10) {
        resultParts.add('${_convertThreeDigits(millions)} ملايين');
      } else {
        resultParts.add('${_convertThreeDigits(millions)} مليون');
      }
    }

    // 3. الآلاف
    if (thousands > 0) {
      if (thousands == 1) {
        resultParts.add('ألف');
      } else if (thousands == 2) {
        resultParts.add('ألفان');
      } else if (thousands >= 3 && thousands <= 10) {
        resultParts.add('${_convertThreeDigits(thousands)} آلاف');
      } else {
        resultParts.add('${_convertThreeDigits(thousands)} ألف');
      }
    }

    // 4. الآحاد والعشرات والمئات
    if (units > 0) {
      resultParts.add(_convertThreeDigits(units));
    }

    final text = resultParts.join(' و');

    if (!appendCurrency) {
      return text;
    }

    // التسمية المالية المعتمدة للريال اليمني
    if (amount == 1) {
      return 'ريال واحد';
    } else if (amount == 2) {
      return 'ريالان';
    } else {
      return '$text ريال';
    }
  }
}

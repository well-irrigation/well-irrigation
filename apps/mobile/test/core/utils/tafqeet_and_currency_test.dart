import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/utils/currency_utils.dart';
import 'package:well_irrigation_mobile/core/utils/tafqeet_utils.dart';

void main() {
  group('Tafqeet (التفقيط المالي بالريال اليمني)', () {
    test('الأرقام الفردية والعشرات والمئات', () {
      expect(Tafqeet.format(0), 'صفر ريال');
      expect(Tafqeet.format(1), 'ريال واحد');
      expect(Tafqeet.format(2), 'ريالان');
      expect(Tafqeet.format(3), 'ثلاثة ريال');
      expect(Tafqeet.format(10), 'عشرة ريال');
      expect(Tafqeet.format(11), 'أحد عشر ريال');
      expect(Tafqeet.format(12), 'اثنا عشر ريال');
      expect(Tafqeet.format(15), 'خمسة عشر ريال');
      expect(Tafqeet.format(20), 'عشرون ريال');
      expect(Tafqeet.format(25), 'خمسة وعشرون ريال');
      expect(Tafqeet.format(100), 'مائة ريال');
      expect(Tafqeet.format(200), 'مائتان ريال');
      expect(Tafqeet.format(350), 'ثلاثمائة وخمسون ريال');
    });

    test('الآلاف وعشرات الآلاف ومئات الآلاف', () {
      expect(Tafqeet.format(1000), 'ألف ريال');
      expect(Tafqeet.format(2000), 'ألفان ريال');
      expect(Tafqeet.format(3500), 'ثلاثة آلاف وخمسمائة ريال');
      expect(Tafqeet.format(6000), 'ستة آلاف ريال');
      expect(Tafqeet.format(7000), 'سبعة آلاف ريال');
      expect(Tafqeet.format(10000), 'عشرة آلاف ريال');
      expect(Tafqeet.format(12500), 'اثنا عشر ألف وخمسمائة ريال');
      expect(Tafqeet.format(50000), 'خمسون ألف ريال');
      expect(Tafqeet.format(100000), 'مائة ألف ريال');
      expect(Tafqeet.format(150000), 'مائة وخمسون ألف ريال');
      expect(Tafqeet.format(1000000), 'مليون ريال');
      expect(Tafqeet.format(2500000), 'مليونان وخمسمائة ألف ريال');
    });
  });

  group('CurrencyUtils (الفواصل والتحويل)', () {
    test('تنسيق الأرقام بالفواصل الألفية', () {
      expect(CurrencyUtils.formatAmount(0), '0');
      expect(CurrencyUtils.formatAmount(1), '1');
      expect(CurrencyUtils.formatAmount(10), '10');
      expect(CurrencyUtils.formatAmount(100), '100');
      expect(CurrencyUtils.formatAmount(1000), '1,000');
      expect(CurrencyUtils.formatAmount(3500), '3,500');
      expect(CurrencyUtils.formatAmount(10000), '10,000');
      expect(CurrencyUtils.formatAmount(1000000), '1,000,000');
    });

    test('استخراج الأرقام من النصوص المنسقة والعربية', () {
      expect(CurrencyUtils.parseRawInt('3,500'), 3500);
      expect(CurrencyUtils.parseRawInt('١٠,٠٠٠'), 10000);
      expect(CurrencyUtils.parseRawInt('10,000 ريال'), 10000);
    });
  });
}

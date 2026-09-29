import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/utils/contact_picker.dart';

void main() {
  group('normalizeContactPhone — تطبيع رقم جهة الاتصال', () {
    test('الصيغة المحلية التسعية تبقى كما هي', () {
      expect(normalizeContactPhone('712345678'), '712345678');
    });

    test('الصيغة الدولية E.164 تسقط مقدمة +967', () {
      expect(normalizeContactPhone('+967 712 345 678'), '712345678');
      expect(normalizeContactPhone('967712345678'), '712345678');
    });

    test('مقدمة 00967 تسقط', () {
      expect(normalizeContactPhone('00967712345678'), '712345678');
    });

    test('الصفر الافتتاحي المحلي يسقط', () {
      expect(normalizeContactPhone('0712345678'), '712345678');
    });

    test('الأرقام العربية والفارسية توحَّد إلى إنجليزية', () {
      expect(normalizeContactPhone('٧١٢٣٤٥٦٧٨'), '712345678');
    });

    test('الفواصل والمسافات والرموز تُهمَل', () {
      expect(normalizeContactPhone('(712) 345-678'), '712345678');
    });

    test('الأطول من تسع خانات تأخذ آخر تسع', () {
      expect(normalizeContactPhone('999712345678'), '712345678');
    });

    test('القصيرة تعاد كما هي والحقل يتحقق منها', () {
      expect(normalizeContactPhone('12345'), '12345');
    });

    test('بلا أرقام يعيد null', () {
      expect(normalizeContactPhone(''), isNull);
      expect(normalizeContactPhone('abc'), isNull);
    });
  });
}

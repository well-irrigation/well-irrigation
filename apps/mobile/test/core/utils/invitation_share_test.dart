import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:well_irrigation_mobile/core/utils/invitation_share.dart';

void main() {
  group('InvitationShareLauncher.toIntlPhone — الصيغة الدولية', () {
    test('المحلية التسعية تسابق بـ967', () {
      expect(InvitationShareLauncher.toIntlPhone('771234567'), '967771234567');
    });

    test('المقدمة الدولية تمر كما هي', () {
      expect(
        InvitationShareLauncher.toIntlPhone('967771234567'),
        '967771234567',
      );
      expect(
        InvitationShareLauncher.toIntlPhone('+967771234567'),
        '967771234567',
      );
    });

    test('مقدمة 00967 تختصر إلى 967', () {
      expect(
        InvitationShareLauncher.toIntlPhone('00967771234567'),
        '967771234567',
      );
    });

    test('الفواصل والأرقام العربية تُطبَّع', () {
      expect(
        InvitationShareLauncher.toIntlPhone('+٩٦٧ ٧٧١ ٢٣٤ ٥٦٧'),
        '967771234567',
      );
    });
  });

  group('InvitationShareLauncher — روابط الفتح المباشر', () {
    test('واتساب يفتح مخططه بمحادثة الرقم والنص المشفر', () async {
      final launched = <Uri>[];
      final launcher = InvitationShareLauncher(
        launch: (uri, mode) async {
          launched.add(uri);
          expect(mode, LaunchMode.externalApplication);
          return true;
        },
      );

      final opened = await launcher.openWhatsApp(
        intlPhone: '967771234567',
        message: 'مرحبا\nرمز الدعوة:\n482915',
      );

      expect(opened, isTrue);
      expect(launched.single.scheme, 'whatsapp');
      expect(launched.single.host, 'send');
      expect(launched.single.queryParameters['phone'], '967771234567');
      expect(
        launched.single.queryParameters['text'],
        'مرحبا\nرمز الدعوة:\n482915',
      );
    });

    test('الرسائل تفتح sms بالرقم الدولي والنص جاهزًا', () async {
      final launched = <Uri>[];
      final launcher = InvitationShareLauncher(
        launch: (uri, mode) async {
          launched.add(uri);
          return true;
        },
      );

      final opened = await launcher.openSms(
        intlPhone: '967771234567',
        message: 'رمز الدعوة:\n482915',
      );

      expect(opened, isTrue);
      expect(launched.single.scheme, 'sms');
      expect(launched.single.path, '+967771234567');
      expect(
        launched.single.queryParameters['body'],
        'رمز الدعوة:\n482915',
      );
    });

    test('نتيجة false تمرّ كما هي ليرجع المستدعي إلى المشاركة العامة', () async {
      final launcher = InvitationShareLauncher(
        launch: (uri, mode) async => false,
      );

      final opened = await launcher.openWhatsApp(
        intlPhone: '967771234567',
        message: 'x',
      );

      expect(opened, isFalse);
    });
  });
}

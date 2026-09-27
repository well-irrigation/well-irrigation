import 'package:url_launcher/url_launcher.dart';

import 'digit_utils.dart';

/// فتح محادثة مباشرة لمشاركة رمز الدعوة عبر واتساب أو الرسائل.
///
/// النتيجة صادقة: `false` تعني أن الجهاز لا يدعم الفتح المباشر (لا واتساب
/// مثبتًا، أو لا معالج للرابط)، فيرجع المستدعي إلى قائمة المشاركة العامة
/// بدل الادعاء بالنجاح.
class InvitationShareLauncher {
  const InvitationShareLauncher({this.launch = _defaultLaunchUrl});

  /// يُحقَن في الاختبارات؛ الافتراضي url_launcher.
  final Future<bool> Function(Uri uri, LaunchMode mode) launch;

  static Future<bool> _defaultLaunchUrl(Uri uri, LaunchMode mode) =>
      launchUrl(uri, mode: mode);

  /// واتساب يفتح محادثة الرقم مباشرة: مخطط `whatsapp://` لا يردّه إلا
  /// واتساب نفسه — فغيابه يعود `false` بلا متصفح وسيط.
  Future<bool> openWhatsApp({
    required String intlPhone,
    required String message,
  }) {
    final uri = Uri.parse(
      'whatsapp://send?phone=$intlPhone&text=${Uri.encodeComponent(message)}',
    );
    return launch(uri, LaunchMode.externalApplication);
  }

  /// الرسائل تفتح المحادثة بالرقم والنص جاهزًا.
  Future<bool> openSms({required String intlPhone, required String message}) {
    final uri = Uri.parse(
      'sms:+$intlPhone?body=${Uri.encodeComponent(message)}',
    );
    return launch(uri, LaunchMode.platformDefault);
  }

  /// الصيغة الدولية بلا `+` ولا أصفار افتتاحية — صيغة مدخلي واتساب
  /// والرسائل: محلية 9 خانات تسابق بـ`967`، ومقدمة `00967` تختصر إلى
  /// `967`، والرقم الدولي الكامل يمر كما هو.
  static String toIntlPhone(String rawPhone) {
    final digits = normalizeArabicDigits(
      rawPhone,
    ).replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('00967')) {
      return digits.substring(2);
    }
    if (digits.startsWith('967') && digits.length > 9) {
      return digits;
    }
    return '967$digits';
  }
}

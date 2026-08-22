/// توليد المعرّفات الفريدة للطابور المحلي.
///
/// المعرّف يُولَّد **مرة واحدة لكل عملية ميدانية** عند الإدخال في
/// الطابور، ويُعاد إرساله بلا تغيير عبر كل محاولة. القسم 2 من
/// `ANDROID_OFFLINE_BACKGROUND_SYNC.md` يعدّ «إعادة إنشاء Command ID
/// في كل Retry» ممنوعًا مطلقًا: توليد معرّف جديد لكل محاولة يُبطل
/// حماية التكرار الخادمية (ق-114) كلها.
///
/// لذلك التوليد محصور في هذا الملف، ويُستدعى من `OutboxRepository`
/// عند الإدخال فقط. `SyncEngine` لا يملك مولّدًا ولا يستطيع الكتابة
/// على `commandId`.
library;

import 'dart:math';

/// بوابة توليد المعرّفات — قابلة للحقن حتى تكون الاختبارات حتمية.
abstract interface class IdGenerator {
  /// يُعيد UUID جديدًا بصيغة نصية بأحرف صغيرة.
  String newId();
}

/// التنفيذ الإنتاجي: UUID الإصدار الرابع من مصدر عشوائي مشفَّر.
///
/// لا يعتمد على حزمة خارجية: `Random.secure()` كافٍ، والصيغة تتبع
/// RFC 4122 (نسخة 4، متغيّر 10xx) لأن الخادم يستقبلها كنوع `uuid`.
class SecureIdGenerator implements IdGenerator {
  SecureIdGenerator([Random? random]) : _random = random ?? Random.secure();

  final Random _random;

  @override
  String newId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));

    // النسخة 4.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // المتغيّر RFC 4122.
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();

    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}

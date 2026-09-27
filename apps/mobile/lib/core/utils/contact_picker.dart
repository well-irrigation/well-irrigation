import 'package:flutter_contacts/flutter_contacts.dart';

import 'digit_utils.dart';

/// نتيجة اختيار جهة اتصال: كل نهاية مُعلَنة بلا نجاح ملفق — الإلغاء ليس
/// خطأ، والرفض وفشل القراءة يُعلَمان لمن يستدعي ليعرض رسالته.
enum ContactPickStatus { picked, cancelled, permissionDenied, failed }

class ContactPickResult {
  const ContactPickResult(this.status, {this.phone});

  final ContactPickStatus status;

  /// الرقم بعد تطبيعه إلى الصيغة المحلية «7xxxxxxxx»، أو null عند غيابه.
  final String? phone;
}

/// يفتح منتقي جهات الاتصال النظامي ويعيد رقمًا واحدًا جاهزًا للحقل.
///
/// الصلاحية تُطلب زمن التشغيل لحظة الاستدعاء وحدها، وإن رُفضت فالنتيجة
/// [ContactPickStatus.permissionDenied] والإدخال اليدوي يبقى كاملًا —
/// منعُ اختيارٍ ممكنٍ في حالة صلاحية «فشل كاذب» لا نُنفِّذه.
Future<ContactPickResult> pickContactPhone() async {
  try {
    if (!await FlutterContacts.permissions.has(PermissionType.read)) {
      final status = await FlutterContacts.permissions.request(
        PermissionType.read,
      );
      if (status != PermissionStatus.granted &&
          status != PermissionStatus.limited) {
        return const ContactPickResult(ContactPickStatus.permissionDenied);
      }
    }

    final contact = await FlutterContacts.native.showPicker(
      properties: {ContactProperty.phone},
    );
    if (contact == null) {
      return const ContactPickResult(ContactPickStatus.cancelled);
    }

    final raw = contact.phones.isEmpty
        ? null
        : (contact.phones.first.normalizedNumber ?? contact.phones.first.number);
    final phone = raw == null ? null : normalizeContactPhone(raw);
    if (phone == null || phone.isEmpty) {
      return const ContactPickResult(ContactPickStatus.failed);
    }
    return ContactPickResult(ContactPickStatus.picked, phone: phone);
  } catch (_) {
    // فشل المنمصة أو القراءة حالة صريحة، لا اختيار صامت ولا رقم مُلفَّق.
    return const ContactPickResult(ContactPickStatus.failed);
  }
}

/// تطبيع رقم من جهة اتصال إلى الصيغة المحلية التي يقرأها العقد: خانات
/// إنجليزية وحدها، وسقوط مقدّمة الدولة «+967»/«00967»، وآخر 9 خانات من
/// الأطول — والمالك يقرأ الرقم الناتج حرفًا حرفًا في خطوة التأكيد قبل
/// منح أي وصول (ق-123).
String? normalizeContactPhone(String raw) {
  final digits = normalizeArabicDigits(raw).replaceAll(RegExp(r'[^0-9]'), '');
  var local = digits;
  if (local.startsWith('00967')) {
    local = local.substring(5);
  } else if (local.startsWith('967') && local.length > 9) {
    local = local.substring(3);
  }
  if (local.length > 9) {
    local = local.substring(local.length - 9);
  }
  return local.isEmpty ? null : local;
}

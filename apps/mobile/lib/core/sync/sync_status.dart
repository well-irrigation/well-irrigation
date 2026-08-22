/// حالة الأمر في الطابور، ونصّها المعروض للمستخدم.
///
/// النصوص هي نصوص ق-108 الحرفية في
/// `docs/technical/SYNC_ARCHITECTURE.md` — لا تُصَغ من جديد هنا ولا
/// تُعرض أكواد تقنية للمستخدم (ق-90 بند 12).
library;

/// الحالة الداخلية المخزَّنة في الطابور.
///
/// أربع حالات فقط. لا حالة «فشل» مخزَّنة: فشل الشبكة يُبقي الأمر
/// `pending` ويزيد عدّاد المحاولات، فالعملية لا تُفقد ولا تحتاج
/// تدخلًا. أما الرفض العملي فيصير `review` ولا يعود يُحاول تلقائيًا
/// (ق-90 بند 20: «business conflicts لا تدخل Retry Loop غير محدود»).
enum CommandStatus {
  /// محفوظ على الجهاز وينتظر دوره في الإرسال.
  pending,

  /// محجوز الآن لمحاولة إرسال جارية.
  ///
  /// الحجز يمنع إرسال الأمر مرتين من حلقتين متزامنتين.
  dispatching,

  /// قَبِله الخادم ونتيجته مخزَّنة محليًا.
  confirmed,

  /// يحتاج تدخلًا بشريًا — رفض عملي أو صلاحية أو لبس.
  review;

  String get storageValue => name;

  static CommandStatus fromStorage(String value) =>
      CommandStatus.values.firstWhere((status) => status.name == value);
}

/// النصوص المعتمدة لعرض حالة المزامنة (ق-108 وق-90 بند 11).
abstract final class SyncStatusText {
  static const String localDurable = 'محفوظ على الجهاز';
  static const String pending = 'بانتظار المزامنة';
  static const String dispatching = 'جارٍ الإرسال';
  static const String confirmed = 'تمت المزامنة';
  static const String retrying = 'فشل وستتم إعادة المحاولة';
  static const String needsReview = 'يحتاج مراجعة';
}

/// يحوّل حالة أمر إلى نصّها المعروض.
///
/// [attempted] يعني أن محاولة إرسال واحدة على الأقل جرت وفشلت. أمرٌ
/// لم يُحاول بعد يُعرض «بانتظار المزامنة» لا «فشل»: محاولة فاشلة
/// واحدة لا ترفع الحالة إلى حرجة (القسم 32 من وثيقة Android).
String syncStatusText(CommandStatus status, {bool attempted = false}) {
  return switch (status) {
    CommandStatus.pending =>
      attempted ? SyncStatusText.retrying : SyncStatusText.pending,
    CommandStatus.dispatching => SyncStatusText.dispatching,
    CommandStatus.confirmed => SyncStatusText.confirmed,
    CommandStatus.review => SyncStatusText.needsReview,
  };
}

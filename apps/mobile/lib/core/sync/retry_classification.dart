/// تصنيف فشل الإرسال: هل يُعاد تلقائيًا أم يحتاج مراجعة بشرية؟
///
/// القسم 20 من `SYNC_ARCHITECTURE.md`: أخطاء الشبكة والمهلة تُعاد،
/// والرفض العملي والصلاحية واللبس لا تُعاد بل تُعرض للمراجعة (ق-90
/// بند 20: «business conflicts لا تدخل Retry Loop غير محدود»).
///
/// ملاحظة دقيقة من ق-114: رفض العمل يُلغي صفّ الحجز معه في نفس
/// المعاملة، فإعادة المحاولة **آمنة** لكنها ستفشل بنفس السبب. إعادتها
/// إلى ما لا نهاية استهلاك بطارية بلا نتيجة، ولذلك تصير «مراجعة».
///
/// الملف Dart خالص: لا يعرف `PostgrestException` ولا `dart:io`. يستقبل
/// رمز الخطأ ونصّه، فيبقى قابلًا للاختبار بلا شبكة ولا حزمة Supabase.
library;

import 'dart:async';

/// ما يفعله المحرك بعد فشل محاولة.
enum FailureDisposition {
  /// يبقى الأمر `pending` ويزيد عدّاد المحاولات — لا تدخّل بشري.
  retry,

  /// يصير الأمر `review` ويخرج من الإعادة التلقائية.
  review,
}

/// أرقام أخطاء PostgreSQL/PostgREST المعروفة بأنها عابرة.
///
/// قائمة سماح مقصودة: ما ليس فيها يُعرض للمراجعة. العكس — إعادة كل
/// خطأ غير معروف — يعني حلقة إعادة أبدية على عملية مالية مرفوضة.
const Set<String> _retryableSqlStates = {
  '08000', // connection_exception
  '08003', // connection_does_not_exist
  '08006', // connection_failure
  '08001', // sqlclient_unable_to_establish_sqlconnection
  '08004', // sqlserver_rejected_establishment_of_sqlconnection
  '40001', // serialization_failure
  '40P01', // deadlock_detected
  '53300', // too_many_connections
  '53400', // configuration_limit_exceeded
  '57014', // query_canceled
  '57P01', // admin_shutdown
  '57P02', // crash_shutdown
  '57P03', // cannot_connect_now
  '58030', // io_error
  'PGRST301', // JWT انتهى — يصلح بعد تجديد الجلسة، ولا يغيّر حالة عمل
};

/// أنواع استثناءات الشبكة كما تظهر من طبقات HTTP المختلفة.
///
/// المطابقة بالاسم لا بالنوع حتى يبقى الملف بلا `dart:io` ولا `http`،
/// فيعمل التصنيف في الاختبار على الحاسب كما يعمل على الهاتف.
const Set<String> _retryableErrorTypeNames = {
  'SocketException',
  'HttpException',
  'ClientException',
  'HandshakeException',
  'TlsException',
  'WebSocketException',
  'TimeoutException',
};

const List<String> _retryableMessageFragments = [
  'failed host lookup',
  'connection refused',
  'connection reset',
  'connection closed',
  'connection terminated',
  'network is unreachable',
  'no address associated with hostname',
  'operation timed out',
  'software caused connection abort',
  'socketexception',
  'clientexception',
  'timeout',
];

/// يصنّف خطأً أعادته طبقة `api` برمز SQL.
FailureDisposition classifySqlFailure(String? code, String message) {
  if (code != null && _retryableSqlStates.contains(code.toUpperCase())) {
    return FailureDisposition.retry;
  }

  // رمز غائب مع نصّ شبكة: بعض طبقات النقل تُبلّغ الانقطاع بلا رمز.
  if (code == null || code.isEmpty) {
    return _looksLikeNetworkMessage(message)
        ? FailureDisposition.retry
        : FailureDisposition.review;
  }

  return FailureDisposition.review;
}

/// يصنّف استثناءً مرفوعًا من طبقة النقل نفسها (شبكة، مهلة، غير ذلك).
FailureDisposition classifyThrownFailure(Object error) {
  if (error is TimeoutException) {
    return FailureDisposition.retry;
  }

  if (_retryableErrorTypeNames.contains(error.runtimeType.toString())) {
    return FailureDisposition.retry;
  }

  return _looksLikeNetworkMessage(error.toString())
      ? FailureDisposition.retry
      : FailureDisposition.review;
}

bool _looksLikeNetworkMessage(String message) {
  final lowered = message.toLowerCase();

  return _retryableMessageFragments.any(lowered.contains);
}

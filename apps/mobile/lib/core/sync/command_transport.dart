/// بوابة الإرسال إلى طبقة `api`.
///
/// المنطق فوق هذه البوابة لا يعرف Supabase ولا HTTP. تنفيذان:
/// `SupabaseCommandTransport` للجهاز، ومزيَّف في الاختبار يسجّل ما
/// استُدعي به — وهو ما يُثبت أن `p_command_id` لم يتغير بين المحاولات.
///
/// كل الإرسال يمرّ عبر دوال `api.*` حصرًا. لا `Direct DML` (ق-79).
library;

import 'command_envelope.dart';
import 'command_type.dart';
import 'retry_classification.dart';

/// طلب إرسال واحد: كل ما يحتاجه الخادم، محسوم المراجع.
class DispatchRequest {
  const DispatchRequest({
    required this.type,
    required this.commandId,
    required this.arguments,
  });

  final CommandType type;

  /// معرّف العملية الثابت. نفسه في كل محاولة إعادة.
  final String commandId;

  /// وسائط الدالة كاملة، بلا مراجع، ومعها `p_command_id` ووقت الحدث.
  final Map<String, Object?> arguments;

  @override
  String toString() => 'DispatchRequest(${type.rpcName} command=$commandId)';
}

/// نتيجة محاولة إرسال.
sealed class DispatchResult {
  const DispatchResult();
}

/// الخادم قَبِل العملية — أو أعاد نتيجتها المخزونة لأنها مكرَّرة.
///
/// الحالتان واحدة عند العميل بفضل ق-114، وهذا هو بيت القصيد: التطبيق
/// لا يحتاج أن يعرف أيّهما حدث.
final class DispatchAccepted extends DispatchResult {
  const DispatchAccepted({
    required this.response,
    required this.entityId,
    this.matchedExisting = false,
  });

  /// ردّ الخادم موحَّدًا كخريطة. الردود التي تُرجِع `uuid` مجردًا
  /// تُلَفّ في `{'id': '<uuid>'}` حتى يكون للتخزين شكل واحد.
  final Map<String, Object?> response;

  /// معرّف الكيان المستخرج من الردّ، أو `null` إن لم يُنتج الأمر كيانًا.
  final String? entityId;

  /// طابق الخادم كيانًا قائمًا بدل إنشاء جديد (`already_exists`).
  final bool matchedExisting;
}

/// فشلت المحاولة. [disposition] يحدد: إعادة أم مراجعة.
final class DispatchFailed extends DispatchResult {
  const DispatchFailed({
    required this.disposition,
    required this.message,
    this.code,
  });

  final FailureDisposition disposition;

  /// نصّ تشخيصي يُخزَّن في `last_error`.
  ///
  /// لا يُعرض للمستخدم كما هو: ق-90 بند 12 يمنع عرض الأكواد التقنية.
  /// المعروض هو نصّ الحالة من `sync_status.dart`.
  final String message;

  final String? code;

  bool get isRetryable => disposition == FailureDisposition.retry;
}

abstract interface class CommandTransport {
  Future<DispatchResult> dispatch(DispatchRequest request);
}

/// يبني وسائط الدالة النهائية.
///
/// نقطة التركيب الوحيدة لثلاثة مصادر: حمولة الأمر بعد حَل مراجعها،
/// و`p_command_id` من المغلَّف، ووقت الحدث من المغلَّف.
///
/// وقت الحدث يُضاف **دائمًا** إن كان للنوع وسيط وقت: الأغلفة كلها
/// تستخدم `default clock_timestamp()`، أي وقت الخادم. عملية وقعت في
/// الحقل قبل ساعات وحُسِبت بسعر لحظة المزامنة = فاتورة خاطئة (القسم 18).
Map<String, Object?> buildRpcArguments({
  required CommandType type,
  required String commandId,
  required DateTime occurredAt,
  required Map<String, Object?> resolvedPayload,
}) {
  final eventTimeArgument = type.eventTimeArgument;

  return {
    ...resolvedPayload,
    commandIdArgument: commandId,
    ?eventTimeArgument: occurredAt.toUtc().toIso8601String(),
  };
}

/// يحوّل ردّ الخادم الخام إلى نتيجة قبول موحَّدة.
///
/// يستوعب الشكلين الفعليين: `uuid` مجرد من أربع دوال، و`jsonb` من
/// الأربع الأخرى بمفتاح مختلف لكل واحدة.
DispatchAccepted normalizeAcceptedResponse(
  CommandType type,
  Object? rawResponse,
) {
  if (!type.returnsJson) {
    final id = rawResponse?.toString();

    return DispatchAccepted(response: {'id': id}, entityId: id);
  }

  if (rawResponse is! Map) {
    throw FormatException(
      'ردّ ${type.rpcName} متوقَّع أن يكون jsonb لا ${rawResponse.runtimeType}',
    );
  }

  final response = rawResponse.map(
    (key, value) => MapEntry(key.toString(), value),
  );
  final resultKey = type.resultKey;
  final entityId = resultKey == null ? null : response[resultKey]?.toString();

  return DispatchAccepted(
    response: response,
    entityId: entityId,
    matchedExisting: response['already_exists'] == true,
  );
}

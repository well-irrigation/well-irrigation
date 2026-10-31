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
    required this.accountId,
    required this.type,
    required this.commandId,
    required this.arguments,
  });

  /// مالك الأمر المحلي؛ يُستخدم لحراسة الهوية عند الإرسال ولا يُرسل للخادم.
  final String accountId;

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
    this.serverResponse,
  });

  final FailureDisposition disposition;

  /// نصّ تشخيصي يُخزَّن في `last_error`.
  ///
  /// لا يُعرض للمستخدم كما هو: ق-90 بند 12 يمنع عرض الأكواد التقنية.
  /// المعروض هو نصّ الحالة من `sync_status.dart`.
  final String message;

  final String? code;

  /// الرد المهيكل من الخادم عند التعارض أو فشل الفحص
  final Map<String, Object?>? serverResponse;

  bool get isRetryable => disposition == FailureDisposition.retry;
}

abstract interface class CommandTransport {
  Future<DispatchResult> dispatch(DispatchRequest request);
}

/// قدرة قراءة اختيارية؛ لا تكسر تطبيقات النقل التي توفر الإرسال فقط.
abstract interface class CompletionReceiptTransport {
  Future<CompletionReceiptRead> readCompletionReceipt(
    CompletionReceiptRequest request,
  );
}

class CompletionReceiptRequest {
  const CompletionReceiptRequest({
    required this.accountId,
    required this.wellId,
    required this.sessionId,
    required this.commandId,
    required this.commandType,
  });
  final String accountId, wellId, sessionId, commandId, commandType;
  Map<String, Object?> get arguments => {
    'p_well_id': wellId,
    'p_session_id': sessionId,
    'p_command_id': commandId,
    'p_expected_command_type': commandType,
  };
}

enum CompletionReceiptState { accepted, processing, notFound, unresolved }

enum CompletionReceiptFailureKind {
  authentication,
  forbidden,
  network,
  malformed,
  unavailable,
}

sealed class CompletionReceiptRead {
  const CompletionReceiptRead();
}

class CompletionReceiptResponse extends CompletionReceiptRead {
  const CompletionReceiptResponse(this.state, this.receipt);
  final CompletionReceiptState state;
  final Map<String, Object?>? receipt;
}

class CompletionReceiptFailure extends CompletionReceiptRead {
  const CompletionReceiptFailure(this.kind);
  final CompletionReceiptFailureKind kind;
}

/// نجاح HTTP لا يثبت النتيجة؛ تُطابق الهوية الكاملة قبل قبول الإقرار.
CompletionReceiptRead parseCompletionReceipt(
  CompletionReceiptRequest request,
  Object? raw,
) {
  const invalid = CompletionReceiptFailure(
    CompletionReceiptFailureKind.malformed,
  );
  if (raw is! Map ||
      raw['contract'] != 'get_completion_receipt' ||
      raw['version'] != 1 ||
      raw['retry_authorized'] != false ||
      raw['well_id'] != request.wellId ||
      raw['session_id'] != request.sessionId ||
      raw['command_id'] != request.commandId ||
      raw['command_type'] != request.commandType ||
      !const {
        'complete_irrigation_session',
        'complete_booking_session',
      }.contains(request.commandType)) {
    return invalid;
  }
  final state = switch (raw['status']) {
    'accepted' => CompletionReceiptState.accepted,
    'processing' => CompletionReceiptState.processing,
    'not_found' => CompletionReceiptState.notFound,
    'unresolved' => CompletionReceiptState.unresolved,
    _ => null,
  };
  if (state == null) {
    return invalid;
  }
  final receipt = raw['receipt'];
  if (state != CompletionReceiptState.accepted) {
    return receipt == null ? CompletionReceiptResponse(state, null) : invalid;
  }
  if (receipt is! Map ||
      receipt['session_id'] != request.sessionId ||
      receipt['status'] != 'closed' ||
      receipt['segments'] is! List ||
      receipt['session_charge_id'] is! String ||
      (receipt['session_charge_id'] as String).isEmpty ||
      receipt['ended_at'] is! String ||
      DateTime.tryParse(receipt['ended_at'] as String) == null) {
    return invalid;
  }
  for (final key in [
    'actual_seconds',
    'billable_seconds',
    'weighted_price_per_hour_minor',
    'amount_minor',
  ]) {
    if (receipt[key] is! int || (receipt[key] as int) < 0) {
      return invalid;
    }
  }
  if ((receipt['billable_seconds'] as int) >
      (receipt['actual_seconds'] as int)) {
    return invalid;
  }
  return CompletionReceiptResponse(
    state,
    Map<String, Object?>.unmodifiable(receipt.cast<String, Object?>()),
  );
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

/// يحوّل ردّ الخادم الخام إلى نتيجة موحَّدة (قبول أو مراجعة/تعارض).
///
/// يستوعب الشكلين الفعليين: `uuid` مجرد من أربع دوال، و`jsonb` من
/// الأربع الأخرى بمفتاح مختلف لكل واحدة، أو رد تعارض/نزاع مهيكل.
DispatchResult normalizeAcceptedResponse(
  CommandType type,
  Object? rawResponse,
) {
  if (type == CommandType.createBooking) {
    final response = rawResponse is Map
        ? Map<String, Object?>.from(rawResponse)
        : null;
    final status = response?['status'];
    if (response != null && (status == 'conflict' || status == 'rejected')) {
      return DispatchFailed(
        disposition: FailureDisposition.review,
        message: 'طلب الحجز يحتاج مراجعة',
        code: (response['reason_code'] ?? response['conflict_code'] ?? status)
            ?.toString(),
        serverResponse: response,
      );
    }
    bool text(String key) =>
        response?[key] is String && (response![key] as String).isNotEmpty;
    final start = DateTime.tryParse(
      response?['scheduled_start']?.toString() ?? '',
    );
    final end = DateTime.tryParse(response?['scheduled_end']?.toString() ?? '');
    if (status != 'confirmed' ||
        !text('booking_id') ||
        !text('public_code') ||
        !text('well_id') ||
        start == null ||
        end == null ||
        !end.isAfter(start)) {
      return const DispatchFailed(
        disposition: FailureDisposition.retry,
        code: 'booking_result_unknown',
        message: 'نتيجة طلب الحجز غير معلومة',
      );
    }
    return DispatchAccepted(
      response: response!,
      entityId: response['booking_id'] as String,
    );
  }
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

  final status = response['status']?.toString();
  if (status == 'requires_resolution' ||
      status == 'requires_disambiguation' ||
      ((type == CommandType.startBookingSession ||
              type == CommandType.endBookingTransitionChain) &&
          const {'conflict', 'rejected', 'requires_review'}.contains(status))) {
    final message =
        response['message']?.toString() ??
        'العملية تتطلب مراجعة أو فض نزاع ($status)';
    return DispatchFailed(
      disposition: FailureDisposition.review,
      message: message,
      code:
          response['reason_code']?.toString() ??
          response['conflict_type']?.toString() ??
          status,
      serverResponse: response,
    );
  }

  final resultKey = type.resultKey;
  if (type == CommandType.endBookingTransitionChain &&
      (response['contract'] != 'end_booking_transition_chain' ||
          response['version'] != 1 ||
          status != 'ended')) {
    return DispatchFailed(
      disposition: FailureDisposition.review,
      message: 'رد إنهاء سلسلة الحجوزات غير مؤكد',
      code: 'invalid_end_chain_response',
      serverResponse: response,
    );
  }
  final entityId = resultKey == null ? null : response[resultKey]?.toString();

  // أي أمر يتوقع معرّف كيان ولكنه يعود فارغاً يحوّل للمراجعة ولا يقبل بـ entityId=null
  if (resultKey != null && (entityId == null || entityId.isEmpty)) {
    final message =
        response['message']?.toString() ??
        'ردّ ${type.rpcName} خلا من المعرّف المتوقَّع $resultKey';
    return DispatchFailed(
      disposition: FailureDisposition.review,
      message: message,
      code: status,
      serverResponse: response,
    );
  }

  return DispatchAccepted(
    response: response,
    entityId: entityId,
    matchedExisting: response['already_exists'] == true,
  );
}

/// تنفيذ الإرسال فوق Supabase.
///
/// يتبع نمط [ApiHealthRepository] القائم حرفيًا:
/// `_client.schema('api').rpc(...)` مع نفس تصنيف الاستثناءات الثلاثة
/// (`PostgrestException` / `AuthException` / غير ذلك).
///
/// هذا الملف هو الوحيد في مجلد المزامنة الذي يعرف Supabase. كل ما
/// عداه Dart خالص يُختبر بلا شبكة.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'command_transport.dart';
import 'booking_start_receipt.dart';
import 'operational_start_receipt.dart';
import 'session_correction_receipt.dart';
import 'retry_classification.dart';

class SupabaseCommandTransport
    implements
        CommandTransport,
        CompletionReceiptTransport,
        BookingStartReceiptTransport,
        OperationalStartReceiptTransport,
        SessionCorrectionReceiptTransport {
  const SupabaseCommandTransport(this._client);

  final SupabaseClient _client;

  @override
  Future<SessionCorrectionReceiptRead> readSessionCorrectionReceipt(
    SessionCorrectionReceiptRequest request,
  ) async {
    final session = _client.auth.currentSession;
    if (session == null ||
        session.isExpired ||
        session.user.id != request.accountId) {
      return const SessionCorrectionReceiptFailure(
        SessionCorrectionReceiptFailureKind.authentication,
      );
    }
    try {
      final raw = await _client
          .schema('api')
          .rpc('get_session_correction_receipt', params: request.arguments)
          .timeout(const Duration(seconds: 20));
      return parseSessionCorrectionReceipt(request, raw);
    } on PostgrestException catch (error) {
      return SessionCorrectionReceiptFailure(switch (error.code) {
        '42501' => SessionCorrectionReceiptFailureKind.forbidden,
        '28000' ||
        'PGRST301' ||
        'PGRST302' => SessionCorrectionReceiptFailureKind.authentication,
        '22023' => SessionCorrectionReceiptFailureKind.malformed,
        _ => SessionCorrectionReceiptFailureKind.network,
      });
    } on AuthException {
      return const SessionCorrectionReceiptFailure(
        SessionCorrectionReceiptFailureKind.authentication,
      );
    } on Object {
      return const SessionCorrectionReceiptFailure(
        SessionCorrectionReceiptFailureKind.network,
      );
    }
  }

  @override
  Future<OperationalStartReceiptRead> readOperationalStartReceipt(
    OperationalStartReceiptRequest request,
  ) async {
    final session = _client.auth.currentSession;
    if (session == null ||
        session.isExpired ||
        session.user.id != request.accountId) {
      return const OperationalStartReceiptFailure(
        OperationalStartReceiptFailureKind.authentication,
      );
    }
    try {
      final raw = await _client
          .schema('api')
          .rpc('get_operational_start_receipt', params: request.arguments)
          .timeout(const Duration(seconds: 20));
      return parseOperationalStartReceipt(request, raw);
    } on PostgrestException catch (error) {
      return OperationalStartReceiptFailure(switch (error.code) {
        '42501' => OperationalStartReceiptFailureKind.forbidden,
        '28000' ||
        'PGRST301' ||
        'PGRST302' => OperationalStartReceiptFailureKind.authentication,
        '22023' => OperationalStartReceiptFailureKind.malformed,
        _ => OperationalStartReceiptFailureKind.network,
      });
    } on AuthException {
      return const OperationalStartReceiptFailure(
        OperationalStartReceiptFailureKind.authentication,
      );
    } on Object {
      return const OperationalStartReceiptFailure(
        OperationalStartReceiptFailureKind.network,
      );
    }
  }

  @override
  Future<BookingStartReceiptRead> readBookingStartReceipt(
    BookingStartReceiptRequest request,
  ) async {
    final session = _client.auth.currentSession;
    if (session == null ||
        session.isExpired ||
        session.user.id != request.accountId) {
      return const BookingStartReceiptFailure(
        BookingStartReceiptFailureKind.authentication,
      );
    }
    try {
      final raw = await _client
          .schema('api')
          .rpc('get_booking_start_receipt', params: request.arguments)
          .timeout(const Duration(seconds: 20));
      return parseBookingStartReceipt(request, raw);
    } on PostgrestException catch (error) {
      return BookingStartReceiptFailure(switch (error.code) {
        '42501' => BookingStartReceiptFailureKind.forbidden,
        '28000' ||
        'PGRST301' ||
        'PGRST302' => BookingStartReceiptFailureKind.authentication,
        '22023' => BookingStartReceiptFailureKind.malformed,
        _ => BookingStartReceiptFailureKind.network,
      });
    } on AuthException {
      return const BookingStartReceiptFailure(
        BookingStartReceiptFailureKind.authentication,
      );
    } on Object {
      return const BookingStartReceiptFailure(
        BookingStartReceiptFailureKind.network,
      );
    }
  }

  @override
  Future<CompletionReceiptRead> readCompletionReceipt(
    CompletionReceiptRequest request,
  ) async {
    final session = _client.auth.currentSession;
    if (session == null ||
        session.isExpired ||
        session.user.id != request.accountId) {
      return const CompletionReceiptFailure(
        CompletionReceiptFailureKind.authentication,
      );
    }
    try {
      final raw = await _client
          .schema('api')
          .rpc('get_completion_receipt', params: request.arguments)
          .timeout(const Duration(seconds: 20));
      return parseCompletionReceipt(request, raw);
    } on PostgrestException catch (error) {
      return CompletionReceiptFailure(switch (error.code) {
        '42501' => CompletionReceiptFailureKind.forbidden,
        '28000' ||
        'PGRST301' ||
        'PGRST302' => CompletionReceiptFailureKind.authentication,
        '22023' => CompletionReceiptFailureKind.malformed,
        _ => CompletionReceiptFailureKind.network,
      });
    } on AuthException {
      return const CompletionReceiptFailure(
        CompletionReceiptFailureKind.authentication,
      );
    } on Object {
      return const CompletionReceiptFailure(
        CompletionReceiptFailureKind.network,
      );
    }
  }

  @override
  Future<DispatchResult> dispatch(DispatchRequest request) async {
    // الخادم يقرأ المنفِّذ من `auth.uid()`، فبلا جلسة دخول لا يمكن
    // إرسال شيء. الأمر يبقى محفوظًا ويُرسل بعد الدخول — لا يُفقد ولا
    // يُعرض كخطأ يحتاج مراجعة.
    final session = _client.auth.currentSession;
    if (session == null || session.isExpired) {
      return const DispatchFailed(
        executionNotStarted: true,
        disposition: FailureDisposition.retry,
        message: 'لا توجد جلسة دخول؛ يُعاد الإرسال بعد الدخول',
      );
    }

    if (request.accountId.isEmpty || session.user.id != request.accountId) {
      return const DispatchFailed(
        executionNotStarted: true,
        disposition: FailureDisposition.retry,
        message: 'هوية جلسة الدخول لا تطابق مالك الأمر المحلي',
      );
    }

    final Object? raw;

    try {
      raw = await _client
          .schema('api')
          .rpc(request.type.rpcName, params: request.arguments);
    } on PostgrestException catch (error) {
      return DispatchFailed(
        disposition: classifySqlFailure(error.code, error.message),
        message: '${error.code}: ${error.message}',
        code: error.code,
      );
    } on AuthException catch (error) {
      return DispatchFailed(
        disposition: FailureDisposition.retry,
        message: error.message,
      );
    } catch (error) {
      return DispatchFailed(
        disposition: classifyThrownFailure(error),
        message: error.toString(),
      );
    }

    // الخادم قَبِل بالفعل، لكن شكل الردّ غير متوقَّع. لا تُعاد المحاولة
    // عمياء: الكتابة نجحت، والمطلوب مراجعة لا تكرار.
    try {
      return normalizeAcceptedResponse(request.type, raw);
    } on FormatException catch (error) {
      return DispatchFailed(
        disposition: FailureDisposition.review,
        message: 'ردّ غير متوقَّع من ${request.type.rpcName}: ${error.message}',
      );
    }
  }
}

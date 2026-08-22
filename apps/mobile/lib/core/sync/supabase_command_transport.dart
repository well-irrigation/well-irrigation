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
import 'retry_classification.dart';

class SupabaseCommandTransport implements CommandTransport {
  const SupabaseCommandTransport(this._client);

  final SupabaseClient _client;

  @override
  Future<DispatchResult> dispatch(DispatchRequest request) async {
    // الخادم يقرأ المنفِّذ من `auth.uid()`، فبلا جلسة دخول لا يمكن
    // إرسال شيء. الأمر يبقى محفوظًا ويُرسل بعد الدخول — لا يُفقد ولا
    // يُعرض كخطأ يحتاج مراجعة.
    if (_client.auth.currentSession == null) {
      return const DispatchFailed(
        disposition: FailureDisposition.retry,
        message: 'لا توجد جلسة دخول؛ يُعاد الإرسال بعد الدخول',
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

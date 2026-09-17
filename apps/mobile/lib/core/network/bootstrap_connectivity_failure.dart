import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// قائمة سماح ضيقة لفتح الاستعادة المحلية؛ غير المعروف يفشل مغلقًا.
bool isBootstrapConnectivityFailure(Object error) {
  if (error is SocketException || error is TimeoutException) return true;

  // GoTrue يلفّ فشل المقبس أثناء تحديث رمز منتهٍ بهذا النوع نفسه الذي
  // يستعمله لأخطاء خادم قابلة للإعادة. حالة HTTP تمنع خلط الاثنين.
  if (error is AuthRetryableFetchException) {
    return error.statusCode == null &&
        _isKnownWrappedTransportFailure(error.message);
  }

  // مكتبة HTTP تغلّف خطأ DNS/Socket داخل ClientException. لا يكفي اسم
  // الاستثناء وحده: أخطاء استجابة الخادم قد تحمل النوع نفسه.
  if (error.runtimeType.toString() != 'ClientException') return false;
  final detail = error.toString().toLowerCase();
  return detail.contains('socketexception') ||
      detail.contains('failed host lookup') ||
      detail.contains('network is unreachable') ||
      detail.contains('connection refused') ||
      detail.contains('connection reset') ||
      detail.contains('connection closed') ||
      detail.contains('connection timed out');
}

bool _isKnownWrappedTransportFailure(String message) {
  final detail = message.toLowerCase();
  if (detail.startsWith('clientexception with socketexception:')) {
    return true;
  }

  const signatures = [
    'failed host lookup:',
    'network is unreachable',
    'connection refused',
    'connection reset',
    'connection closed',
    'connection timed out',
  ];
  return signatures.any(
    (signature) =>
        detail == signature ||
        detail.startsWith('$signature ') ||
        detail.startsWith('$signature,') ||
        detail.startsWith('$signature:'),
  );
}

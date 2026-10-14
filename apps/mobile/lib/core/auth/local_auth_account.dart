import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// مفتاح عزل محلي فقط؛ لا يحمل بئرًا أو دورًا أو تفويضًا خادميًا.
class LocalAuthAccount {
  const LocalAuthAccount(
    this.id, {
    required this.isExpired,
    this.sessionId,
    this.expiresAt,
  });

  final String id;
  final bool isExpired;
  final String? sessionId;
  final DateTime? expiresAt;
  bool get canUseOfflineIdentity =>
      id.isNotEmpty &&
      !isExpired &&
      sessionId != null &&
      sessionId!.isNotEmpty &&
      (expiresAt == null || DateTime.now().isBefore(expiresAt!));

  /// هوية من جلسة SDK المحفوظة، مرتبطة بجلسة الدخول التي أثبتها bootstrap.
  /// لا يتحقق العميل من توقيع JWT دون الخادم ولا يستخرج منه صلاحيات البئر.
  static LocalAuthAccount? fromSession(Session? session) {
    if (session == null || session.user.id.isEmpty) return null;
    try {
      final parts = session.accessToken.split('.');
      if (parts.length != 3 || parts.any((p) => p.isEmpty)) return null;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is! Map<String, dynamic> ||
          payload['sub'] != session.user.id ||
          payload['role'] != 'authenticated' ||
          payload['exp'] is! int) {
        return null;
      }
      final expiry = DateTime.fromMillisecondsSinceEpoch(
        (payload['exp'] as int) * 1000,
        isUtc: true,
      );
      final sessionId = payload['session_id'];
      return LocalAuthAccount(
        session.user.id,
        isExpired: session.isExpired || !DateTime.now().isBefore(expiry),
        sessionId: sessionId is String && sessionId.isNotEmpty
            ? sessionId
            : null,
        expiresAt: expiry,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on RangeError {
      return null;
    }
  }
}

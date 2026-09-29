import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Snapshot of local auth presence only. No identity, token, or payload escapes.
class Q129AuthSnapshot {
  const Q129AuthSnapshot({
    required this.sessionPresent,
    required this.currentUserPresent,
    required this.sessionExpired,
  });

  final bool? sessionPresent;
  final bool? currentUserPresent;
  final bool? sessionExpired;

  static Q129AuthSnapshot capture() {
    try {
      final auth = Supabase.instance.client.auth;
      final session = auth.currentSession;
      return Q129AuthSnapshot(
        sessionPresent: session != null,
        currentUserPresent: auth.currentUser != null,
        sessionExpired: session?.isExpired,
      );
    } catch (_) {
      return const Q129AuthSnapshot(
        sessionPresent: null,
        currentUserPresent: null,
        sessionExpired: null,
      );
    }
  }
}

Map<String, Object?> q129BootstrapFailureFields(
  Object error, {
  required bool connectivityClassified,
  required Q129AuthSnapshot auth,
}) => {
  'event': 'q129_offline_recovery_bootstrap_failure',
  'exceptionType': error.runtimeType.toString(),
  'connectivityClassified': connectivityClassified,
  'sessionPresent': auth.sessionPresent,
  'currentUserPresent': auth.currentUserPresent,
  'sessionExpired': auth.sessionExpired,
  'authStatusCode': error is AuthException
      ? int.tryParse(error.statusCode ?? '')
      : null,
};

Map<String, Object?> q129RecoveryQueryFields({
  required int candidateCount,
  required bool expiredReadOnly,
}) => {
  'event': 'q129_offline_recovery_query',
  'candidateCount': candidateCount,
  'expiredReadOnly': expiredReadOnly,
};

Map<String, Object?> q129RecoveryQueryFailureFields(Object error) => {
  'event': 'q129_offline_recovery_query_failure',
  'stage': 'unresolved_sessions',
  'exceptionType': error.runtimeType.toString(),
};

/// Only allowlisted primitive fields reach debug output. Release emits nothing.
void logQ129Diagnostic(Map<String, Object?> fields) {
  if (kDebugMode) debugPrint(jsonEncode(fields));
}

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/diagnostics/q129_recovery_diagnostic.dart';

void main() {
  test('bootstrap event contains only allowlisted structured facts', () {
    const secret = 'https://example.supabase.co/token?secret=do-not-log';
    final fields = q129BootstrapFailureFields(
      AuthRetryableFetchException(message: secret),
      connectivityClassified: false,
      auth: const Q129AuthSnapshot(
        sessionPresent: true,
        currentUserPresent: true,
        sessionExpired: true,
      ),
    );
    expect(fields, {
      'event': 'q129_offline_recovery_bootstrap_failure',
      'exceptionType': 'AuthRetryableFetchException',
      'connectivityClassified': false,
      'sessionPresent': true,
      'currentUserPresent': true,
      'sessionExpired': true,
      'authStatusCode': null,
    });
    expect(fields.toString(), isNot(contains(secret)));
  });

  test('auth status is read only from the structured property', () {
    final fields = q129BootstrapFailureFields(
      const AuthApiException('https://example.supabase.co', statusCode: '403'),
      connectivityClassified: false,
      auth: const Q129AuthSnapshot(
        sessionPresent: false,
        currentUserPresent: false,
        sessionExpired: null,
      ),
    );
    expect(fields['authStatusCode'], 403);
    expect(fields.toString(), isNot(contains('example.supabase.co')));
  });

  test('query events expose count or failure type without IDs or message', () {
    expect(q129RecoveryQueryFields(candidateCount: 2, expiredReadOnly: true), {
      'event': 'q129_offline_recovery_query',
      'candidateCount': 2,
      'expiredReadOnly': true,
    });
    final failure = q129RecoveryQueryFailureFields(
      StateError('https://example.supabase.co/account-id'),
    );
    expect(failure, {
      'event': 'q129_offline_recovery_query_failure',
      'stage': 'unresolved_sessions',
      'exceptionType': 'StateError',
    });
    expect(failure.toString(), isNot(contains('example.supabase.co')));
  });
}

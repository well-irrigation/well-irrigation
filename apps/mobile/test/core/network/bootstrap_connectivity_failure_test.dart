import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/network/bootstrap_connectivity_failure.dart';

void main() {
  test('field-shaped offline auth refresh wrapper is connectivity', () {
    final error = AuthRetryableFetchException(
      message:
          'ClientException with SocketException: Failed host lookup: '
          'example.supabase.co, uri=https://example.supabase.co/auth/v1/token',
    );
    expect(isBootstrapConnectivityFailure(error), isTrue);
  });

  for (final message in [
    'Network is unreachable',
    'Failed host lookup: example.supabase.co',
    'Connection refused',
    'Connection reset',
    'Connection closed',
    'Connection timed out',
  ]) {
    test('known low-level transport signature is connectivity: $message', () {
      expect(
        isBootstrapConnectivityFailure(
          AuthRetryableFetchException(message: message),
        ),
        isTrue,
      );
    });
  }

  for (final status in ['500', '502', '503']) {
    test('retryable HTTP $status fails closed despite socket text', () {
      expect(
        isBootstrapConnectivityFailure(
          AuthRetryableFetchException(
            message:
                'ClientException with SocketException: Failed host lookup:',
            statusCode: status,
          ),
        ),
        isFalse,
      );
    });
  }

  for (final status in ['401', '403']) {
    test('real AuthApiException $status remains unclassified', () {
      expect(
        isBootstrapConnectivityFailure(
          AuthApiException('authorization denied', statusCode: status),
        ),
        isFalse,
      );
    });
  }

  test('generic auth and unknown errors remain unclassified', () {
    expect(
      isBootstrapConnectivityFailure(const AuthException('unknown')),
      isFalse,
    );
    expect(isBootstrapConnectivityFailure(Exception('malformed')), isFalse);
    expect(isBootstrapConnectivityFailure(Exception('network')), isFalse);
    expect(
      isBootstrapConnectivityFailure(
        AuthRetryableFetchException(message: 'network failed'),
      ),
      isFalse,
    );
    expect(
      isBootstrapConnectivityFailure(
        AuthUnknownException(
          message: 'Network is unreachable',
          originalError: Exception('network'),
        ),
      ),
      isFalse,
    );
    expect(
      isBootstrapConnectivityFailure(
        const PostgrestException(message: 'permission denied', code: '42501'),
      ),
      isFalse,
    );
    expect(
      isBootstrapConnectivityFailure(const FormatException('malformed')),
      isFalse,
    );
  });

  test('existing socket and timeout cases remain classified', () {
    expect(
      isBootstrapConnectivityFailure(const SocketException('offline')),
      isTrue,
    );
    expect(isBootstrapConnectivityFailure(TimeoutException('offline')), isTrue);
  });
}

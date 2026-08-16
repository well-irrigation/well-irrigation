import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/config/app_config.dart';

void main() {
  group('AppConfig', () {
    test('accepts valid values', () {
      final config = AppConfig.fromValues(
        supabaseUrl: 'http://127.0.0.1:54321',
        supabasePublishableKey: 'test-publishable-key',
      );

      expect(config.supabaseUrl, 'http://127.0.0.1:54321');

      expect(config.supabasePublishableKey, 'test-publishable-key');
    });

    test('rejects empty URL', () {
      expect(
        () => AppConfig.fromValues(
          supabaseUrl: '',
          supabasePublishableKey: 'key',
        ),
        throwsFormatException,
      );
    });

    test('rejects invalid URL scheme', () {
      expect(
        () => AppConfig.fromValues(
          supabaseUrl: 'ftp://example.test',
          supabasePublishableKey: 'key',
        ),
        throwsFormatException,
      );
    });

    test('rejects empty publishable key', () {
      expect(
        () => AppConfig.fromValues(
          supabaseUrl: 'https://example.test',
          supabasePublishableKey: '',
        ),
        throwsFormatException,
      );
    });
  });
}

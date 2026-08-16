class AppConfig {
  const AppConfig({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
  });

  final String supabaseUrl;
  final String supabasePublishableKey;

  factory AppConfig.fromEnvironment() {
    return AppConfig.fromValues(
      supabaseUrl: const String.fromEnvironment('SUPABASE_URL'),
      supabasePublishableKey: const String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
      ),
    );
  }

  factory AppConfig.fromValues({
    required String supabaseUrl,
    required String supabasePublishableKey,
  }) {
    final url = supabaseUrl.trim();
    final key = supabasePublishableKey.trim();

    if (url.isEmpty) {
      throw const FormatException('SUPABASE_URL is required.');
    }

    final uri = Uri.tryParse(url);

    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('SUPABASE_URL must be an http/https URL.');
    }

    if (key.isEmpty) {
      throw const FormatException('SUPABASE_PUBLISHABLE_KEY is required.');
    }

    return AppConfig(supabaseUrl: url, supabasePublishableKey: key);
  }
}

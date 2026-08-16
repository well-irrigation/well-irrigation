import 'package:supabase_flutter/supabase_flutter.dart';

enum ApiHealthStatus { authenticationRequired, healthy, failed }

class ApiHealthResult {
  const ApiHealthResult._({required this.status, this.payload, this.message});

  const ApiHealthResult.authenticationRequired()
    : this._(status: ApiHealthStatus.authenticationRequired);

  const ApiHealthResult.healthy(Object? payload)
    : this._(status: ApiHealthStatus.healthy, payload: payload);

  const ApiHealthResult.failed(String message)
    : this._(status: ApiHealthStatus.failed, message: message);

  final ApiHealthStatus status;
  final Object? payload;
  final String? message;
}

class ApiHealthRepository {
  ApiHealthRepository(this._client);

  final SupabaseClient _client;

  Future<ApiHealthResult> probe() async {
    final session = _client.auth.currentSession;

    if (session == null) {
      return const ApiHealthResult.authenticationRequired();
    }

    try {
      final payload = await _client.schema('api').rpc('health');

      return ApiHealthResult.healthy(payload);
    } on PostgrestException catch (error) {
      return ApiHealthResult.failed('${error.code}: ${error.message}');
    } on AuthException catch (error) {
      return ApiHealthResult.failed(error.message);
    } catch (error) {
      return ApiHealthResult.failed(error.toString());
    }
  }
}

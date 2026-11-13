import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';

import '../session/operational_start_guided_recovery_test.dart'
    show GuidedRepository;

class CurrentReadRepository extends OperationsRepository {
  CurrentReadRepository(super.client);
  int detailReads = 0;
  final detail = GuidedRepository();
  @override
  Future<SessionDetailData> fetchSessionDetail(String id) {
    detailReads++;
    return detail.fetchSessionDetail(id);
  }
}

void main() {
  late SupabaseClient client;
  late CurrentReadRepository repo;
  late Map<String, Object?> raw;
  final requests = <http.Request>[];
  Completer<void>? gate;
  late Completer<void> entered;
  Future<void> login(String account) => client.auth.recoverSession(
    jsonEncode({
      'access_token': 'test-token',
      'refresh_token': 'test-refresh',
      'token_type': 'bearer',
      'user': {'id': account, 'aud': 'authenticated', 'created_at': ''},
    }),
  );
  setUp(() async {
    gate = null;
    entered = Completer<void>();
    requests.clear();
    raw = {'status': 'ok', 'well_id': 'well', 'current_session': null};
    client = SupabaseClient(
      'https://current-session.invalid',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((r) async {
        requests.add(r);
        if (!entered.isCompleted) entered.complete();
        await gate?.future;
        return http.Response(
          jsonEncode(raw),
          200,
          headers: {'content-type': 'application/json'},
          request: r,
        );
      }),
    );
    repo = CurrentReadRepository(client);
    await login('account');
  });
  tearDown(() => client.dispose());
  Map<String, Object?> active() => {
    'session_id': 'server',
    'well_id': 'well',
    'status': 'open',
    'ended_at': null,
  };
  test(
    'fresh current read never invokes history or receipt and null is explicit',
    () async {
      expect(await repo.fetchCurrentOperationalSession('well'), isNull);
      expect(repo.detailReads, 0);
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/rest/v1/rpc/get_well_day_schedule');
      expect(jsonDecode(requests.single.body), {'p_well_id': 'well'});
    },
  );
  test('only current-session identity is used for canonical detail', () async {
    raw['current_session'] = active();
    final s = await repo.fetchCurrentOperationalSession('well');
    expect(s!.session.id, 'server');
    expect(repo.detailReads, 1);
  });
  test(
    'missing current key cannot masquerade as absent active session',
    () async {
      raw.remove('current_session');
      await expectLater(
        repo.fetchCurrentOperationalSession('well'),
        throwsFormatException,
      );
      expect(repo.detailReads, 0);
    },
  );
  test('wrong well is rejected', () async {
    raw['well_id'] = 'other';
    await expectLater(
      repo.fetchCurrentOperationalSession('well'),
      throwsFormatException,
    );
  });
  test('wrong canonical session is rejected', () async {
    raw['current_session'] = active();
    repo.detail.sessionId = 'other';
    await expectLater(
      repo.fetchCurrentOperationalSession('well'),
      throwsStateError,
    );
  });
  test('account change after first read prevents detail adoption', () async {
    raw['current_session'] = active();
    gate = Completer<void>();
    final work = repo.fetchCurrentOperationalSession('well');
    final checked = expectLater(work, throwsStateError);
    await entered.future;
    await login('other');
    gate!.complete();
    await checked;
    expect(repo.detailReads, 0);
  });
  test('a closed detail cannot become current active control', () async {
    raw['current_session'] = active();
    repo.detail.status = 'closed';
    repo.detail.endedAt = DateTime.now();
    await expectLater(
      repo.fetchCurrentOperationalSession('well'),
      throwsStateError,
    );
  });
}

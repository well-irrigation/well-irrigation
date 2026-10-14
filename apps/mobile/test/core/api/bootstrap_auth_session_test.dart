import 'dart:convert';
import 'dart:io';

import 'package:http/testing.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/auth/local_auth_account.dart';

String jwt(Map<String, Object?> claims) =>
    '${base64Url.encode(utf8.encode('{"alg":"HS256"}')).replaceAll('=', '')}.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.fixture-signature';
Session session({
  String sub = 'account',
  String? login = 'login',
  bool expired = false,
  String? token,
}) => Session(
  accessToken:
      token ??
      jwt({
        'sub': sub,
        'role': 'authenticated',
        'session_id': login,
        'exp':
            DateTime.now().millisecondsSinceEpoch ~/ 1000 +
            (expired ? -3600 : 3600),
      }),
  tokenType: 'bearer',
  refreshToken: 'fixture-refresh',
  user: User(
    id: 'account',
    appMetadata: {},
    userMetadata: {},
    aud: 'authenticated',
    createdAt: '2026-10-08T00:00:00Z',
  ),
);

void main() {
  test('SDK local auth must have valid matching token identity, expiry and login binding', () {
    expect(
      LocalAuthAccount.fromSession(session())!.canUseOfflineIdentity,
      isTrue,
    );
    expect(
      LocalAuthAccount.fromSession(session(expired: true))!
          .canUseOfflineIdentity,
      isFalse,
    );
    expect(LocalAuthAccount.fromSession(session(sub: 'other')), isNull);
    expect(LocalAuthAccount.fromSession(session(token: 'broken')), isNull);
    expect(
      LocalAuthAccount.fromSession(session(login: null))!.canUseOfflineIdentity,
      isFalse,
    );
    expect(LocalAuthAccount.fromSession(null), isNull);
    expect(
      LocalAuthAccount.fromSession(
        session(
          token: jwt({
            'sub': 'account',
            'role': 'authenticated',
            'session_id': 'login',
            'exp': 999999999999999999,
          }),
        ),
      ),
      isNull,
    );
  });
  test('network-only token refresh failure retains the SDK local session', () {
    fakeAsync((clock) {
      final client = GoTrueClient(
        url: 'https://offline.invalid/auth/v1',
        autoRefreshToken: false,
        httpClient: MockClient(
          (_) async => throw const SocketException(
            'Failed host lookup: offline.invalid',
          ),
        ),
      );
      final original = session();
      client.setInitialSession(jsonEncode(original.toJson()));
      clock.flushMicrotasks();
      final events = <AuthChangeEvent>[];
      final subscription = client.onAuthStateChange.listen(
        (event) => events.add(event.event),
        onError: (Object _) {},
      );
      Object? failure;
      var finished = false;
      client.refreshSession().then(
        (_) {
          finished = true;
        },
        onError: (Object error) {
          failure = error;
          finished = true;
        },
      );
      for (var i = 0; i < 12 && !finished; i++) {
        clock.elapse(const Duration(seconds: 10));
      }
      expect(finished, isTrue);
      expect(failure, isA<AuthRetryableFetchException>());
      expect(client.currentSession?.user.id, 'account');
      expect(client.currentSession?.accessToken, original.accessToken);
      expect(events, isNot(contains(AuthChangeEvent.signedOut)));
      expect(
        LocalAuthAccount.fromSession(client.currentSession)!
            .canUseOfflineIdentity,
        isTrue,
      );
      subscription.cancel();
      client.dispose();
    });
  });
}

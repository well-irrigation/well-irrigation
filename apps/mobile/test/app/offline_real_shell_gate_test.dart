import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/app/identity_gate.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/bootstrap_identity_cache.dart';
import 'package:well_irrigation_mobile/core/auth/local_auth_account.dart';
import 'package:well_irrigation_mobile/core/identity/app_identity.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

import '../support/identity_fixture.dart';

/// مخزن قيم محلي في الذاكرة لعزل اختبار البوابة عن sqflite.
class _MemoryCacheStore extends SqliteOutboxStore {
  final _values = <String, String>{};
  @override
  Future<void> writeLocalValue(String a, String k, String v) async =>
      _values['$a:$k'] = v;
  @override
  Future<String?> readLocalValue(String a, String k) async => _values['$a:$k'];
}

BootstrapData _data() => BootstrapData(
  profile: testProfile(id: 'account'),
  wells: [
    testWell(id: 'saved-well', name: 'بئر محفوظ', roles: const ['operator']),
  ],
);

Widget _gate({
  required BootstrapIdentityCache cache,
  required LocalAuthAccount? Function() auth,
  required Future<BootstrapData> Function() load,
  required void Function(bool flag, AppIdentity identity) onBuild,
}) {
  return MaterialApp(
    home: IdentityGate(
      bootstrapCache: cache,
      localAuthAccount: auth,
      loadBootstrap: load,
      builder: (_, identity, _, {bool isTrustedOfflineBootstrap = false}) {
        onBuild(isTrustedOfflineBootstrap, identity);
        return Scaffold(body: Text('الغلاف: ${identity.activeWell.name}'));
      },
    ),
  );
}

void main() {
  testWidgets(
    'trusted cached scope + connectivity failure enters the real shell',
    (tester) async {
      final cache = BootstrapIdentityCache(_MemoryCacheStore());
      const auth = LocalAuthAccount(
        'account',
        isExpired: false,
        sessionId: 'login',
      );
      await cache.save(auth, _data());
      bool? flag;
      await tester.pumpWidget(
        _gate(
          cache: cache,
          auth: () => auth,
          load: () async => throw const SocketException('Failed host lookup:'),
          onBuild: (f, _) => flag = f,
        ),
      );
      await tester.pumpAndSettle();
      // الغلاف الحقيقي نفسه دُخِل عبر builder بعلم الإقلاع الموثوق، ببئر
      // اللقطة — لا الغلاف المصغّر المرفوض ولا شاشة خطأ.
      expect(flag, isTrue);
      expect(find.text('الغلاف: بئر محفوظ'), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('تعذر تحميل بيانات حسابك'), findsNothing);
    },
  );

  testWidgets('missing trusted cache fails closed (no shell)', (tester) async {
    final cache = BootstrapIdentityCache(_MemoryCacheStore());
    const auth = LocalAuthAccount(
      'account',
      isExpired: false,
      sessionId: 'login',
    );
    var built = false;
    await tester.pumpWidget(
      _gate(
        cache: cache,
        auth: () => auth,
        load: () async => throw const SocketException('Failed host lookup:'),
        onBuild: (_, _) => built = true,
      ),
    );
    await tester.pumpAndSettle();
    expect(built, isFalse);
    expect(find.text('تعذر تحميل بيانات حسابك'), findsOneWidget);
  });

  testWidgets('expired auth cannot open the cached shell', (tester) async {
    final cache = BootstrapIdentityCache(_MemoryCacheStore());
    const valid = LocalAuthAccount(
      'account',
      isExpired: false,
      sessionId: 'login',
    );
    await cache.save(valid, _data());
    const expired = LocalAuthAccount(
      'account',
      isExpired: true,
      sessionId: 'login',
    );
    var built = false;
    await tester.pumpWidget(
      _gate(
        cache: cache,
        auth: () => expired,
        load: () async => throw const SocketException('Failed host lookup:'),
        onBuild: (_, _) => built = true,
      ),
    );
    await tester.pumpAndSettle();
    expect(built, isFalse);
    expect(find.text('تعذر تحميل بيانات حسابك'), findsOneWidget);
  });

  testWidgets('mismatched account cannot open another account cached shell', (
    tester,
  ) async {
    final cache = BootstrapIdentityCache(_MemoryCacheStore());
    const owner = LocalAuthAccount(
      'account',
      isExpired: false,
      sessionId: 'login',
    );
    await cache.save(owner, _data());
    const other = LocalAuthAccount(
      'other',
      isExpired: false,
      sessionId: 'login',
    );
    var built = false;
    await tester.pumpWidget(
      _gate(
        cache: cache,
        auth: () => other,
        load: () async => throw const SocketException('Failed host lookup:'),
        onBuild: (_, _) => built = true,
      ),
    );
    await tester.pumpAndSettle();
    expect(built, isFalse);
    expect(find.text('تعذر تحميل بيانات حسابك'), findsOneWidget);
  });

  testWidgets('server rejection (non-connectivity) never opens cached shell', (
    tester,
  ) async {
    final cache = BootstrapIdentityCache(_MemoryCacheStore());
    const auth = LocalAuthAccount(
      'account',
      isExpired: false,
      sessionId: 'login',
    );
    await cache.save(auth, _data());
    var built = false;
    await tester.pumpWidget(
      _gate(
        cache: cache,
        auth: () => auth,
        load: () async =>
            throw const PostgrestException(message: 'forbidden', code: '42501'),
        onBuild: (_, _) => built = true,
      ),
    );
    await tester.pumpAndSettle();
    expect(built, isFalse);
    expect(find.text('تعذر تحميل بيانات حسابك'), findsOneWidget);
  });
}

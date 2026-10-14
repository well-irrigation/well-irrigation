import 'dart:io';
import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:well_irrigation_mobile/core/api/bootstrap_identity_cache.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/app/identity_gate.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/auth/local_auth_account.dart';

import '../support/identity_fixture.dart';

class LocalValues extends SqliteOutboxStore {
  final values = <String, String>{};
  @override
  Future<void> writeLocalValue(
    String accountId,
    String key,
    String value,
  ) async {
    values['$accountId:$key'] = value;
  }

  @override
  Future<String?> readLocalValue(String accountId, String key) async =>
      values['$accountId:$key'];
}

class DeferredWriteValues extends LocalValues {
  final barrier = Completer<void>();
  @override
  Future<void> writeLocalValue(
    String accountId,
    String key,
    String value,
  ) async {
    await barrier.future;
    await super.writeLocalValue(accountId, key, value);
  }
}

class ReadCoordinator extends OfflineSessionCoordinator {
  ReadCoordinator() : super(store: InMemoryOutboxStore());
  @override
  Future<LocalProvisionalBookingSession?> restoreProvisionalBookingSession({
    required String accountId,
    required String wellId,
  }) async => LocalProvisionalBookingSession(
    localSessionId: 'local-B',
    wellId: wellId,
    chainId: 'chain',
    serverSessionId: 'previous-server-A',
    nextBookingId: 'booking-B',
    commandId: 'stable-command',
    transitionKey: 'intent',
    closedLocallyAt: DateTime.utc(2026, 10, 8),
    startedLocallyAt: DateTime.utc(2026, 10, 8),
    decisionRevision: 0,
    automationRevision: 3,
  );
}

void main() {
  testWidgets(
    'successful identity followed by offline bootstrap keeps a restricted cached entry',
    (tester) async {
      var online = true;
      final key = GlobalKey<IdentityGateState>();
      final cache = BootstrapIdentityCache(LocalValues());
      await tester.pumpWidget(
        MaterialApp(
          home: IdentityGate(
            key: key,
            bootstrapCache: cache,
            localAuthAccount: () => const LocalAuthAccount(
              'account',
              isExpired: false,
              sessionId: 'login',
            ),
            loadBootstrap: () async {
              if (!online) throw const SocketException('Failed host lookup:');
              return BootstrapData(
                profile: testProfile(id: 'account'),
                wells: [testWell(id: 'well')],
              );
            },
            builder:
                (_, identity, _, {bool isTrustedOfflineBootstrap = false}) =>
                    Scaffold(
                      body: Text(
                        isTrustedOfflineBootstrap
                            ? 'غلاف مخبّأ: ${identity.activeWell.name}'
                            : 'server-authoritative',
                      ),
                    ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('server-authoritative'), findsOneWidget);
      online = false;
      key.currentState!.reload();
      await tester.pumpAndSettle();
      // البدء البارد الموثوق يدخل الغلاف الحقيقي نفسه عبر builder مع
      // isTrustedOfflineBootstrap=true، لا الغلاف المصغّر المرفوض.
      expect(find.textContaining('غلاف مخبّأ:'), findsOneWidget);
      expect(find.text('server-authoritative'), findsNothing);
    },
  );
  for (final scenario in [
    'trusted',
    'missing',
    'expired',
    'absent_auth',
    'other_account',
    'other_login',
    'rejected',
    'reconnect',
    'auth_switch',
    'expires',
    'relogin',
  ]) {
    testWidgets('cold startup scope gate: $scenario', (tester) async {
      final cache = BootstrapIdentityCache(LocalValues());
      LocalAuthAccount? auth = const LocalAuthAccount(
        'account',
        isExpired: false,
        sessionId: 'login',
      );
      final source = BootstrapData(
        profile: testProfile(id: 'account'),
        wells: [
          testWell(
            id: 'saved-well',
            name: 'البئر المحفوظ',
            roles: ['operator'],
          ),
        ],
      );
      if (scenario != 'missing') await cache.save(auth, source);
      if (scenario == 'expired') {
        auth = const LocalAuthAccount(
          'account',
          isExpired: true,
          sessionId: 'login',
        );
      }
      if (scenario == 'absent_auth') auth = null;
      if (scenario == 'other_account') {
        auth = const LocalAuthAccount(
          'other',
          isExpired: false,
          sessionId: 'login',
        );
      }
      if (scenario == 'other_login') {
        auth = const LocalAuthAccount(
          'account',
          isExpired: false,
          sessionId: 'new-login',
        );
      }
      final coordinator = ReadCoordinator();
      final connectivity = StreamController<void>.broadcast();
      final authEvents = StreamController<void>.broadcast();
      var online = false;
      Widget gate() => MaterialApp(
        home: IdentityGate(
          bootstrapCache: cache,
          localAuthAccount: () => auth,
          recoveryCoordinator: coordinator,
          connectivityRestored: connectivity.stream,
          authChanges: authEvents.stream,
          loadBootstrap: () async {
            if (scenario == 'rejected') {
              throw const PostgrestException(
                message: 'forbidden',
                code: '42501',
              );
            }
            if (!online) throw const SocketException('Failed host lookup:');
            return BootstrapData(
              profile: testProfile(id: 'account'),
              wells: [testWell(id: 'new-well', name: 'البئر الخادمي')],
            );
          },
          builder:
              (_, identity, _, {bool isTrustedOfflineBootstrap = false}) =>
                  Scaffold(
                    body: Text(
                      '${isTrustedOfflineBootstrap ? 'مخبّأ' : 'خادم'}: '
                      '${identity.activeWell.name}',
                    ),
                  ),
        ),
      );
      await tester.pumpWidget(gate());
      await tester.pumpAndSettle();
      if ([
        'trusted',
        'reconnect',
        'auth_switch',
        'expires',
        'relogin',
      ].contains(scenario)) {
        // البدء البارد الموثوق يدخل الغلاف الحقيقي عبر builder مع
        // isTrustedOfflineBootstrap=true، ببئر اللقطة الموثوقة، لا الغلاف
        // المصغّر ولا أي مصدر خادمي حاكم.
        expect(find.text('مخبّأ: البئر المحفوظ'), findsOneWidget);
        expect(find.textContaining('خادم:'), findsNothing);
        // Process rebuild uses persisted payload, not the previous Gate state.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(gate());
        await tester.pumpAndSettle();
        expect(find.text('مخبّأ: البئر المحفوظ'), findsOneWidget);
        if (scenario == 'reconnect') {
          online = true;
          connectivity.add(null);
          await tester.pumpAndSettle();
          expect(find.text('خادم: البئر الخادمي'), findsOneWidget);
          expect(find.textContaining('مخبّأ:'), findsNothing);
          expect((await cache.load(auth!))!.data.wells.single.id, 'new-well');
        }
        if (['auth_switch', 'expires', 'relogin'].contains(scenario)) {
          auth = LocalAuthAccount(
            scenario == 'auth_switch' ? 'other' : 'account',
            isExpired: scenario == 'expires',
            sessionId: scenario == 'relogin'
                ? 'new-login'
                : scenario == 'auth_switch'
                ? 'other-login'
                : 'login',
          );
          authEvents.add(null);
          await tester.pumpAndSettle();
          expect(find.textContaining('مخبّأ:'), findsNothing);
          expect(find.text('تعذر تحميل بيانات حسابك'), findsOneWidget);
        }
      } else {
        expect(find.text('تعذر تحميل بيانات حسابك'), findsOneWidget);
        expect(find.textContaining('البئر المحفوظ'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      coordinator.dispose();
      await connectivity.close();
      await authEvents.close();
    });
  }
  testWidgets(
    'account switch while successful bootstrap is persisting cannot paint the old account',
    (tester) async {
      final values = DeferredWriteValues();
      final cache = BootstrapIdentityCache(values);
      LocalAuthAccount auth = const LocalAuthAccount(
        'account',
        isExpired: false,
        sessionId: 'login',
      );
      final built = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: IdentityGate(
            bootstrapCache: cache,
            localAuthAccount: () => auth,
            loadBootstrap: () async => BootstrapData(
              profile: testProfile(id: 'account'),
              wells: [testWell(id: 'well')],
            ),
            builder:
                (_, identity, _, {bool isTrustedOfflineBootstrap = false}) {
                  built.add(identity.accountId);
                  return const Text('normal shell');
                },
          ),
        ),
      );
      await tester.pump();
      auth = const LocalAuthAccount(
        'other',
        isExpired: false,
        sessionId: 'other-login',
      );
      values.barrier.complete();
      await tester.pumpAndSettle();
      expect(built, isEmpty);
      expect(find.text('تعذر تحميل بيانات حسابك'), findsOneWidget);
      expect(await cache.load(auth), isNull);
    },
  );
  testWidgets(
    'trusted offline bootstrap enters the real shell, not the rejected mini-shell',
    (tester) async {
      final cache = BootstrapIdentityCache(LocalValues());
      const auth = LocalAuthAccount(
        'account',
        isExpired: false,
        sessionId: 'login',
      );
      await cache.save(
        auth,
        BootstrapData(
          profile: testProfile(id: 'account'),
          wells: [
            testWell(
              id: 'saved-well',
              name: 'البئر المحفوظ',
              roles: ['operator'],
            ),
          ],
        ),
      );
      final coordinator = ReadCoordinator();
      bool? seenFlag;
      await tester.pumpWidget(
        MaterialApp(
          home: IdentityGate(
            bootstrapCache: cache,
            localAuthAccount: () => auth,
            recoveryCoordinator: coordinator,
            loadBootstrap: () async =>
                throw const SocketException('Failed host lookup:'),
            builder:
                (_, identity, _, {bool isTrustedOfflineBootstrap = false}) {
                  seenFlag = isTrustedOfflineBootstrap;
                  return Scaffold(
                    body: Text('غلاف: ${identity.activeWell.name}'),
                  );
                },
          ),
        ),
      );
      await tester.pumpAndSettle();
      // دخل الغلاف الحقيقي نفسه عبر builder بعلم isTrustedOfflineBootstrap=true،
      // ببئر اللقطة الموثوقة — لا شاشة خطأ، ولا الغلاف المصغّر المرفوض (لا
      // NavigationBar ولا banner «للقراءة فقط»)، ولا نضارة خادمية مُختلقة.
      expect(seenFlag, isTrue);
      expect(find.text('غلاف: البئر المحفوظ'), findsOneWidget);
      expect(find.text('تعذر تحميل بيانات حسابك'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(
        find.text('بيانات حساب محفوظة — وضع محلي للقراءة فقط'),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox());
      coordinator.dispose();
    },
  );
}

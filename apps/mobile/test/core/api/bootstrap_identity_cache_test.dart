@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/bootstrap_identity_cache.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/auth/local_auth_account.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

import '../../support/identity_fixture.dart';

void main() {
  late Directory directory;
  late SqliteOutboxStore store;
  late BootstrapIdentityCache cache;
  const auth = LocalAuthAccount(
    'account',
    isExpired: false,
    sessionId: 'login-a',
  );
  BootstrapData data() => BootstrapData(
    profile: testProfile(id: 'account'),
    wells: [
      testWell(id: 'well', roles: ['operator']),
    ],
  );
  SqliteOutboxStore open() => SqliteOutboxStore(
    databasePath: '${directory.path}/outbox.db',
    singleInstance: false,
    sqfliteFactory: databaseFactoryFfiNoIsolate,
  );
  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('bootstrap-cache-');
    store = open();
    cache = BootstrapIdentityCache(store);
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });
  test(
    'account/profile/well role snapshot survives actual SQLite restart',
    () async {
      await cache.save(auth, data());
      await store.close();
      store = open();
      cache = BootstrapIdentityCache(store);
      final snapshot = (await cache.load(auth))!;
      expect(snapshot.data.profile.id, 'account');
      expect(snapshot.data.wells.single.id, 'well');
      expect(snapshot.data.wells.single.roles, ['operator']);
      expect(snapshot.sessionId, 'login-a');
      expect(snapshot.fetchedAt.isUtc, isTrue);
    },
  );
  test('missing, expired, different account and different login cannot load snapshot', () async {
    expect(await cache.load(auth), isNull);
    await cache.save(auth, data());
    for (final blocked in [
      const LocalAuthAccount('account', isExpired: true, sessionId: 'login-a'),
      const LocalAuthAccount('other', isExpired: false, sessionId: 'login-a'),
      const LocalAuthAccount('account', isExpired: false, sessionId: 'login-b'),
      const LocalAuthAccount('account', isExpired: false),
    ]) {
      expect(await cache.load(blocked), isNull);
    }
  });
  test(
    'corruption or malformed scopes fail closed without fabricated defaults',
    () async {
      await cache.save(auth, data());
      final raw = (await store.readLocalValue(
        'account',
        BootstrapIdentityCache.key,
      ))!;
      for (final corrupt in [
        '{broken',
        raw.replaceFirst('"status":"active"', '"missing_status":"active"'),
        raw.replaceFirst('"account_id":"account"', '"account_id":"other"'),
        raw.replaceFirst('"session_id":"login-a"', '"session_id":"other"'),
      ]) {
        await store.writeLocalValue(
          'account',
          BootstrapIdentityCache.key,
          corrupt,
        );
        expect(await cache.load(auth), isNull);
      }
    },
  );
  test('new authoritative empty well scope replaces old scope; rejection invalidates cache', () async {
    await cache.save(auth, data());
    await cache.save(
      auth,
      BootstrapData(
        profile: testProfile(id: 'account'),
        wells: [],
      ),
    );
    expect((await cache.load(auth))!.data.wells, isEmpty);
    await cache.invalidate(auth.id);
    expect(await cache.load(auth), isNull);
  });
  test('same-file process restart restores account scope, pending intent and provisional booking evidence together', () async {
    await cache.save(auth, data());
    final ledger = BookingLocalLedger(store);
    const intent = BookingTransitionIntent(
      commandId: 'stable-command',
      wellId: 'well',
      transitionKey: 'transition',
      chainId: 'chain',
      currentSessionId: 'server-A',
      nextBookingId: 'booking-B',
      decisionRevision: 0,
      automationRevision: 3,
      state: BookingIntentState.awaitingReconciliation,
    );
    await ledger.recordOperationalTransition(
      accountId: 'account',
      intent: intent,
      localSessionId: 'local-B',
      occurredAt: DateTime.utc(2026, 10, 8, 20, 47),
    );
    await store.close();
    store = open();
    cache = BootstrapIdentityCache(store);
    final coordinator = OfflineSessionCoordinator(store: store);
    final identity = (await cache.load(auth))!;
    final provisional = await coordinator.restoreProvisionalBookingSession(
      accountId: identity.data.profile.id,
      wellId: identity.data.wells.single.id,
    );
    expect(provisional!.localSessionId, 'local-B');
    expect(provisional.commandId, 'stable-command');
    expect(provisional.reconciliationState, 'awaiting_reconciliation');
    expect(provisional.startedLocallyAt, DateTime.utc(2026, 10, 8, 20, 47));
    expect(
      (await BookingLocalLedger(
        store,
      ).loadAwaitingIntents('account', 'well')).single.commandId,
      'stable-command',
    );
    expect(
      await coordinator.restoreProvisionalBookingSession(
        accountId: 'other',
        wellId: 'well',
      ),
      isNull,
    );
    coordinator.dispose();
  });
}

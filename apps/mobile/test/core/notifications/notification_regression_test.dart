import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_delivery_coordinator.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_event_store.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_host.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_permission_coordinator.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_router.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_services.dart';
import 'package:well_irrigation_mobile/core/notifications/operational_notification_event_factory.dart';
import 'package:well_irrigation_mobile/core/notifications/operational_notification_scheduler.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

import 'notification_host_test.dart' show EmptyStore;
import 'notification_routing_permission_test.dart' show Permission;
import 'operational_notification_cache_test.dart' show day;
import 'operational_notification_integration_test.dart' show NotificationClock;
import 'operational_notification_scheduler_test.dart' show PlatformFake;

class GatedEventStore extends SqliteNotificationEventStore {
  GatedEventStore(super.db);
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> reconcileSchedules(
    String account, String well, String entityType,
    List<ScheduledNotificationIntent> intents, Set<String> eligibleKeys,
    DateTime now, {bool reactivate = false, String? routeDay,
    bool Function()? isCurrent,
    Future<bool> Function(DatabaseExecutor)? validateEligibility,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    await super.reconcileSchedules(account, well, entityType, intents,
      eligibleKeys, now, reactivate: reactivate, routeDay: routeDay,
      isCurrent: isCurrent, validateEligibility: validateEligibility);
  }
}

class GatedPlatform extends PlatformFake {
  Completer<void> gate = Completer<void>();
  @override
  Future<void> initialize() async {
    initialized++;
    await gate.future;
  }
}

class RunFailureScheduler extends OperationalNotificationScheduler {
  RunFailureScheduler(SqliteNotificationEventStore store, PlatformFake platform)
    : super(store: store, presenter: platform);
  final entered = Completer<void>();
  @override
  Future<void> run(String account, {required String wellId,
    required DateTime trustedNow, required DateTime wallNow,
    required Set<String> eligibleKeys, bool rearm = false,
    String? entityType, bool Function()? isCurrent}) async {
    entered.complete();
    throw StateError('injected scheduler failure');
  }
}

class HungRunScheduler extends OperationalNotificationScheduler {
  HungRunScheduler(SqliteNotificationEventStore store)
    : super(store: store, presenter: PlatformFake());
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> run(String account, {required String wellId,
    required DateTime trustedNow, required DateTime wallNow,
    required Set<String> eligibleKeys, bool rearm = false,
    String? entityType, bool Function()? isCurrent}) async {
    entered.complete();
    await release.future;
  }
}

NotificationServices services({
  OperationalNotificationScheduler? scheduling,
  Future<void> Function(String, String)? recover,
}) => NotificationServices(
  scheduling: scheduling,
  recoverSchedules: recover,
  delivery: NotificationDeliveryCoordinator(
    store: EmptyStore(), presenter: PlatformFake()),
  permission: NotificationPermissionCoordinator(gateway: Permission(),
    wasExplained: (_) async => true, markExplained: (_) async {}),
  router: NotificationRouter(load: (_, _) async => null),
);

void main() {
  setUpAll(sqfliteFfiInit);
  tearDown(() => NotificationServices.current = null);

  for (final explicitDay in [false, true]) {
    for (final fail in [false, true]) {
      test('schedule explicitDay=$explicitDay returns before intent persistence; failure=$fail is isolated', () async {
        final outbox = SqliteOutboxStore(databasePath: inMemoryDatabasePath,
          sqfliteFactory: databaseFactoryFfi);
        await outbox.initialize();
        addTearDown(outbox.close);
        final ledger = BookingLocalLedger(outbox);
        final events = GatedEventStore(outbox.notificationEvents.db);
        final platform = PlatformFake();
        final scheduler = OperationalNotificationScheduler(store: events,
          presenter: platform);
        NotificationServices.current = services(scheduling: scheduler);
        final client = SupabaseClient('https://example.invalid', 'test-key',
          httpClient: MockClient((request) async => http.Response(jsonEncode({
            ...day('2027-01-01'), 'server_time': '2027-01-01T00:00:00Z',
          }), 200, request: request, headers: {'content-type': 'application/json'})));
        addTearDown(client.dispose);
        final repo = BookingRepository(client, null, ledger, NotificationClock());
        bool returned = false;
        final fetch = explicitDay
          ? repo.fetchDayScheduleView(accountId: 'a', wellId: 'w', day: DateTime(2027))
          : repo.fetchScheduleView(accountId: 'a', wellId: 'w');
        final observed = fetch.then((value) { returned = true; return value; });
        await events.entered.future.timeout(const Duration(seconds: 2));
        try {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(returned, isTrue);
          expect(await ledger.loadSchedule('a', 'w', '2027-01-01'), isNotNull);
        } finally {
          if (fail) { events.release.completeError(StateError('intent failure')); }
          else { events.release.complete(); }
          expect((await observed).isCached, isFalse);
          // Let isolated persistence and OS work settle before closing the DB.
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      });
    }
  }

  test('asynchronous scheduler exception cannot escape schedule fetch', () async {
    final outbox = SqliteOutboxStore(databasePath: inMemoryDatabasePath,
      sqfliteFactory: databaseFactoryFfi);
    await outbox.initialize();
    addTearDown(outbox.close);
    final scheduler = RunFailureScheduler(outbox.notificationEvents, PlatformFake());
    NotificationServices.current = services(scheduling: scheduler);
    final client = SupabaseClient('https://example.invalid', 'test-key',
      httpClient: MockClient((request) async => http.Response(jsonEncode({
        ...day('2027-01-01'), 'server_time': '2027-01-01T00:00:00Z',
      }), 200, request: request, headers: {'content-type': 'application/json'})));
    addTearDown(client.dispose);
    final repo = BookingRepository(client, null, BookingLocalLedger(outbox), NotificationClock());
    expect((await repo.fetchScheduleView(accountId: 'a', wellId: 'w')).isCached, isFalse);
    await scheduler.entered.future;
    await Future<void>.delayed(Duration.zero);
  });

  for (final explicitDay in [false, true]) {
    test('hung scheduler does not hold explicitDay=$explicitDay schedule result', () async {
      final outbox = SqliteOutboxStore(databasePath: inMemoryDatabasePath,
        sqfliteFactory: databaseFactoryFfi);
      await outbox.initialize();
      addTearDown(outbox.close);
      final scheduler = HungRunScheduler(outbox.notificationEvents);
      NotificationServices.current = services(scheduling: scheduler);
      final client = SupabaseClient('https://example.invalid', 'test-key',
        httpClient: MockClient((request) async => http.Response(jsonEncode({
          ...day('2027-01-01'), 'server_time': '2027-01-01T00:00:00Z',
        }), 200, request: request, headers: {'content-type': 'application/json'})));
      addTearDown(client.dispose);
      final repo = BookingRepository(client, null, BookingLocalLedger(outbox), NotificationClock());
      try {
        final fetch = explicitDay
          ? repo.fetchDayScheduleView(accountId: 'a', wellId: 'w', day: DateTime(2027))
          : repo.fetchScheduleView(accountId: 'a', wellId: 'w');
        expect((await fetch.timeout(const Duration(seconds: 2))).schedule.wellId, 'w');
        await scheduler.entered.future.timeout(const Duration(seconds: 2));
        expect(scheduler.release.isCompleted, isFalse);
      } finally {
        scheduler.release.complete();
        await Future<void>.delayed(Duration.zero);
      }
    });
  }

  for (final fail in [false, true]) {
    testWidgets('startup/resume recovery shares account flight and clears after failure=$fail', (tester) async {
      final gates = <String, Completer<void>>{'a': Completer<void>(), 'b': Completer<void>()};
      final calls = <String, int>{};
      final service = services(recover: (account, well) async {
        calls.update(account, (value) => value + 1, ifAbsent: () => 1);
        await gates[account]!.future;
      });
      Widget app(String account) => MaterialApp(home: NotificationHost(
        accountId: account, wellIds: {'w'}, activeWellId: 'w',
        services: service, onRoute: (_) {}, child: const Scaffold()));
      await tester.pumpWidget(app('a'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls['a'], 1);
      await tester.pumpWidget(app('b'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls['b'], 1);
      if (fail) { gates['a']!.completeError(StateError('recovery')); }
      else { gates['a']!.complete(); }
      gates['b']!.complete();
      await tester.pump();
      await tester.pumpWidget(app('a'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls['a'], 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    test('scheduler shares account flight, isolates accounts, clears after failure=$fail', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await SqliteNotificationEventStore.createSchema(db);
      final platform = GatedPlatform();
      final scheduler = OperationalNotificationScheduler(
        store: SqliteNotificationEventStore(db), presenter: platform);
      Future<void> run(String account) => scheduler.run(account, wellId: 'w',
        trustedNow: DateTime.utc(2027), wallNow: DateTime.utc(2027), eligibleKeys: {});
      final first = run('a'), overlap = run('a'), other = run('b');
      try {
        await Future<void>.delayed(Duration.zero);
        expect(platform.initialized, 2);
      } finally {
        if (fail) { platform.gate.completeError(StateError('platform')); }
        else { platform.gate.complete(); }
        await Future.wait([first, overlap, other]);
      }
      final before = platform.initialized;
      platform.gate = Completer<void>();
      final next = run('a');
      await Future<void>.delayed(Duration.zero);
      expect(platform.initialized, before + 1);
      platform.gate.complete();
      await next;
    });
  }

}

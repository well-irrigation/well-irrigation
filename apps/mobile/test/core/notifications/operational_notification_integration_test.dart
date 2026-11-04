import 'dart:io';
import 'dart:async';

import 'package:well_irrigation_mobile/core/notifications/notification_event_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/session/time_integrity.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_services.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_permission_coordinator.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_router.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_delivery_coordinator.dart';
import 'package:well_irrigation_mobile/core/notifications/operational_notification_scheduler.dart';
import 'package:well_irrigation_mobile/core/notifications/operational_notification_event_factory.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

import 'operational_notification_cache_test.dart' show day;
import 'operational_notification_scheduler_test.dart' show PlatformFake;
import 'notification_routing_permission_test.dart' show Permission;

class NotificationClock implements TimeIntegritySource {
  DateTime get wallNow => DateTime.utc(2027).add(elapsed);
  String boot = 'boot';
  Duration elapsed = Duration.zero;
  @override
  Future<TimeReading> read() async => TimeReading(
    wallClock: DateTime.utc(2027).add(elapsed),
    monotonic: const Duration(minutes: 1) + elapsed,
    bootId: boot,
  );
}

class ScheduleRepo extends BookingRepository {
  ScheduleRepo(BookingLocalLedger ledger, NotificationClock clock)
    : super(null, null, ledger, clock);
  int hour = 1;
  int bookingCount = 1;
  String status = 'confirmed';
  @override
  Future<WellDaySchedule> fetchTodaySchedule(String well) async =>
      WellDaySchedule.fromContract({
        ...day('2027-01-01'),
        'server_time': '2027-01-01T00:00:00Z',
        'bookings': [
          for (var i = 0; i < bookingCount; i++)
            {
              'id': i == 0 ? 'booking' : 'booking-$i',
              'public_code': 'B',
              'well_id': 'w',
              'farmer_well_account_id': 'farmer',
              'farm_id': 'farm',
              'scheduled_start':
                  '2027-01-01T${hour.toString().padLeft(2, '0')}:00:00Z',
              'scheduled_end': '2027-01-01T03:00:00Z',
              'scheduled_day': '2027-01-01',
              'expected_duration_minutes': 60,
              'status': status,
              'priority': 0,
              'status_group': 'upcoming',
            },
        ],
      });
}

class ObservedScheduler extends OperationalNotificationScheduler {
  ObservedScheduler(
    SqliteNotificationEventStore store,
    PlatformFake presenter,
    NotificationClock timeline,
  ) : super(
        store: store,
        presenter: presenter,
        isAccountActive: (a) => a == 'a',
        clock: () => timeline.wallNow,
      );
  final runs = <Future<void>>[];
  Completer<void> entered = Completer<void>();
  @override
  Future<void> run(
    String account, {
    required String wellId,
    required DateTime trustedNow,
    required DateTime wallNow,
    required Set<String> eligibleKeys,
    bool rearm = false,
    String? entityType,
    bool Function()? isCurrent,
  }) {
    final future = super.run(
      account,
      wellId: wellId,
      trustedNow: trustedNow,
      wallNow: wallNow,
      eligibleKeys: eligibleKeys,
      rearm: rearm,
      entityType: entityType,
      isCurrent: isCurrent,
    );
    runs.add(future);
    if (!entered.isCompleted) entered.complete();
    return future;
  }

  Future<void> settle() async {
    await Future.wait(runs.toList());
    runs.clear();
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late SqliteOutboxStore store;
  late PlatformFake platform;
  late NotificationClock clock;
  late ScheduleRepo repo;
  late ObservedScheduler scheduler;
  Future<void> open() async {
    store = SqliteOutboxStore(
      databasePath: '${dir.path}/db',
      sqfliteFactory: databaseFactoryFfi,
      singleInstance: false,
    );
    await store.initialize();
    platform = PlatformFake();
    final events = store.notificationEvents;
    scheduler = ObservedScheduler(events, platform, clock);
    NotificationServices.current = NotificationServices(
      scheduling: scheduler,
      delivery: NotificationDeliveryCoordinator(
        store: events,
        presenter: platform,
        policies: appNotificationPolicies,
        scheduledCleanup: scheduler.cancelPending,
      ),
      permission: NotificationPermissionCoordinator(
        gateway: Permission(),
        wasExplained: (a) async => true,
        markExplained: (a) async {},
      ),
      router: NotificationRouter(load: events.eventById),
    );
    repo = ScheduleRepo(BookingLocalLedger(store), clock);
  }

  Future<void> read() async {
    scheduler.entered = Completer<void>();
    await repo.fetchScheduleView(accountId: 'a', wellId: 'w');
    await scheduler.entered.future.timeout(const Duration(seconds: 5));
    await scheduler.settle();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('notification_integration');
    clock = NotificationClock();
    await open();
  });
  tearDown(() async {
    NotificationServices.current = null;
    await store.close();
    await dir.delete(recursive: true);
  });
  test(
    'all eligible cached bookings persist; OS opportunities remain bounded',
    () async {
      repo.bookingCount = 12;
      await read();
      final rows = await store.notificationEvents.db.query(
        'notification_events',
      );
      expect(rows, hasLength(24));
      expect(platform.scheduled, hasLength(20));
      await read();
      expect(platform.scheduled, hasLength(24));
      expect(platform.scheduled.toSet(), hasLength(24));
    },
  );
  test('rescheduling back to the same future identity reactivates its original IDs', () async {
    await read();
    repo.hour = 2;
    await read();
    repo.hour = 1;
    await read();
    final rows = await store.notificationEvents.db.query(
      'notification_events',
      orderBy: 'local_id',
    );
    expect(rows, hasLength(4));
    expect(rows.take(2).map((r) => r['schedule_state']), ['armed', 'armed']);
    expect(rows.take(2).map((r) => r['local_id']), [1, 2]);
    expect(rows.skip(2).every((r) => r['schedule_state'] == 'cancelled'), true);
  });
  test('canonical read arms once per stable ID; reschedule and cancellation retire old alarms', () async {
    await read();
    var rows = await store.notificationEvents.db.query(
      'notification_events',
      orderBy: 'local_id',
    );
    expect(rows.map((r) => r['due_at']), [1798764600000000, 1798765200000000]);
    expect(rows.map((r) => r['schedule_state']), ['armed', 'armed']);
    await read();
    expect(platform.scheduled.toSet(), {1, 2});
    expect(
      await store.notificationEvents.db.query('notification_events'),
      hasLength(2),
    );
    repo.hour = 2;
    await read();
    rows = await store.notificationEvents.db.query(
      'notification_events',
      orderBy: 'local_id',
    );
    expect(rows.map((r) => r['schedule_state']), [
      'cancelled',
      'cancelled',
      'armed',
      'armed',
    ]);
    expect(platform.cancelled, {1, 2});
    repo.status = 'cancelled';
    await read();
    rows = await store.notificationEvents.db.query('notification_events');
    expect(rows.every((r) => r['schedule_state'] == 'cancelled'), true);
  });
  test(
    'reopen reuses IDs; reboot cannot rearm until trusted current time exists',
    () async {
      await read();
      await store.close();
      await open();
      await repo.recoverNotificationSchedules('a', 'w');
      expect(platform.scheduled, {1, 2});
      platform.scheduled.clear();
      clock.boot = 'new-boot';
      await repo.recoverNotificationSchedules('a', 'w');
      expect(platform.scheduled, isEmpty);
      await read();
      expect(platform.scheduled.toSet(), {1, 2});
    },
  );
  test(
    'missed alarms become elapsed after reopen without retrospective replay',
    () async {
      await read();
      await store.close();
      await open();
      clock.elapsed = const Duration(hours: 2);
      await repo.recoverNotificationSchedules('a', 'w');
      expect(platform.scheduled, isEmpty);
      final rows = await store.notificationEvents.db.query(
        'notification_events',
      );
      expect(rows.map((r) => r['schedule_state']), ['elapsed', 'elapsed']);
      expect(rows.map((r) => r['state']), ['pending', 'pending']);
    },
  );
}

import 'package:flutter_test/flutter_test.dart';

import 'dart:async';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_event_store.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_presenter.dart';
import 'package:well_irrigation_mobile/core/notifications/app_notification_event.dart';
import 'package:well_irrigation_mobile/core/notifications/operational_notification_scheduler.dart';

import 'notification_delivery_test.dart' show event;

class PlatformFake implements ScheduledNotificationPresenter {
  final scheduled = <int>[], cancelled = <int>[];
  final shown = <int>[];
  int initialized = 0;
  bool fail = false, allowed = true;
  @override
  Future<void> initialize() async {
    initialized++;
  }

  @override
  Future<bool> permissionGranted() async => allowed;
  @override
  Future<void> show(
    int id,
    AppNotificationEvent e,
    NotificationPresentation p,
  ) async {
    shown.add(id);
  }

  @override
  Future<void> schedule(
    int id,
    AppNotificationEvent e,
    NotificationPresentation p,
    DateTime at,
  ) async {
    scheduled.add(id);
    if (fail) throw StateError('OS');
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    if (fail) throw StateError('OS');
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  test(
    'opportunity arms at most twenty and never drains recursively',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await SqliteNotificationEventStore.createSchema(db);
      final store = SqliteNotificationEventStore(db),
          platform = PlatformFake(),
          now = DateTime.utc(2027);
      final keys = {for (var i = 0; i < 25; i++) 'future-$i'};
      for (final key in keys) {
        await store.saveSchedule(
          event(key),
          now.add(const Duration(hours: 1)),
          now,
        );
      }
      final scheduler = OperationalNotificationScheduler(
        store: store,
        presenter: platform,
        clock: () => now,
      );
      await scheduler.run(
        'a',
        wellId: 'w',
        trustedNow: now,
        wallNow: now,
        eligibleKeys: keys,
      );
      expect(platform.scheduled, hasLength(20));
      expect(
        await db.query(
          'notification_events',
          where: "schedule_state='arm_pending'",
        ),
        hasLength(5),
      );
      await scheduler.run(
        'a',
        wellId: 'w',
        trustedNow: now,
        wallNow: now,
        eligibleKeys: keys,
        rearm: true,
      );
      expect(platform.scheduled, hasLength(25));
      expect(platform.scheduled.toSet(), hasLength(25));
    },
  );
  test('cancellation during OS arm cleans up the same platform ID after arm settles', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await SqliteNotificationEventStore.createSchema(db);
    final store = SqliteNotificationEventStore(db),
        platform = BlockingPlatform(),
        now = DateTime.utc(2027);
    await store.saveSchedule(
      event('race'),
      now.add(const Duration(hours: 1)),
      now,
    );
    final scheduler = OperationalNotificationScheduler(
      store: store,
      presenter: platform,
      clock: () => now,
    );
    final work = scheduler.run(
      'a',
      wellId: 'w',
      trustedNow: now,
      wallNow: now,
      eligibleKeys: {'race'},
    );
    await platform.entered.future;
    await store.cancelSchedules(
      'a',
      'w',
      'booking_request',
      'r',
      'booking_cancelled',
      now,
    );
    platform.release.complete();
    await work;
    expect(platform.scheduled, [1]);
    expect(platform.cancelled, [1]);
    expect(
      (await db.query('notification_events')).single['schedule_state'],
      'cancelled',
    );
  });
  test(
    'failed cancel is attempted once per opportunity and stops after three',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await SqliteNotificationEventStore.createSchema(db);
      final store = SqliteNotificationEventStore(db),
          platform = PlatformFake()..fail = true;
      final now = DateTime.utc(2027);
      await store.saveSchedule(
        event('cancel'),
        now.add(const Duration(hours: 1)),
        now,
      );
      await store.cancelSchedules(
        'a',
        'w',
        'booking_request',
        'r',
        'cancelled',
        now,
      );
      final scheduler = OperationalNotificationScheduler(
        store: store,
        presenter: platform,
        clock: () => now,
      );
      for (var attempt = 1; attempt <= 4; attempt++) {
        await scheduler.run(
          'a',
          wellId: 'w',
          trustedNow: now,
          wallNow: now,
          eligibleKeys: {},
        );
        expect(platform.cancelled.length, attempt > 3 ? 3 : attempt);
      }
      expect(
        (await db.query('notification_events'))
            .single['schedule_attempt_count'],
        3,
      );
    },
  );
  test(
    'bounded arm failures clean up independently and retries retain ID',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await SqliteNotificationEventStore.createSchema(db);
      final store = SqliteNotificationEventStore(db),
          presenter = PlatformFake();
      final now = DateTime.utc(2027);
      await store.saveSchedule(
        event('future'),
        now.add(const Duration(hours: 1)),
        now,
      );
      final scheduler = OperationalNotificationScheduler(
        store: store,
        presenter: presenter,
        clock: () => now,
      );
      presenter.fail = true;
      for (var i = 0; i < 3; i++) {
        await scheduler.run(
          'a',
          wellId: 'w',
          trustedNow: now,
          wallNow: now,
          eligibleKeys: {'future'},
        );
      }
      final row = (await db.query('notification_events')).single;
      expect(row['state'], 'suppressed');
      expect(row['schedule_state'], 'cancel_pending');
      expect(row['suppressed_reason'], 'schedule_arm_failed');
      expect(row['schedule_attempt_count'], 1);
      expect(presenter.scheduled, [1, 1, 1]);
      presenter.fail = false;
      await scheduler.run(
        'a',
        wellId: 'w',
        trustedNow: now,
        wallNow: now,
        eligibleKeys: {},
      );
      expect(presenter.cancelled, [1, 1]);
      expect(
        (await db.query('notification_events')).single['schedule_state'],
        'cancelled',
      );
    },
  );
  test(
    'past reminder elapses without platform display or scheduling',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await SqliteNotificationEventStore.createSchema(db);
      final store = SqliteNotificationEventStore(db),
          presenter = PlatformFake();
      final now = DateTime.utc(2027);
      await store.saveSchedule(
        event('past'),
        now.add(const Duration(minutes: 1)),
        now,
      );
      await OperationalNotificationScheduler(
        store: store,
        presenter: presenter,
      ).run(
        'a',
        wellId: 'w',
        trustedNow: now.add(const Duration(minutes: 2)),
        wallNow: now,
        eligibleKeys: {'past'},
      );
      expect(presenter.scheduled, isEmpty);
      expect(
        (await db.query('notification_events')).single['schedule_state'],
        'elapsed',
      );
    },
  );
}

class BlockingPlatform extends PlatformFake {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> schedule(
    int id,
    AppNotificationEvent e,
    NotificationPresentation p,
    DateTime at,
  ) async {
    scheduled.add(id);
    entered.complete();
    await release.future;
  }
}

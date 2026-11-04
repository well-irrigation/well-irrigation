import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_event_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

import 'notification_delivery_test.dart' show event;

import 'dart:io';

void main() {
  setUpAll(sqfliteFfiInit);
  test('two SQLite connections cannot own the same schedule claim; reopen keeps ID', () async {
    final dir = await Directory.systemTemp.createTemp('schedule_race');
    addTearDown(() => dir.delete(recursive: true));
    SqliteOutboxStore open() => SqliteOutboxStore(
      databasePath: '${dir.path}/db',
      sqfliteFactory: databaseFactoryFfi,
      singleInstance: false,
    );
    final first = open(), second = open();
    await first.initialize();
    await second.initialize();
    final a = first.notificationEvents,
        b = second.notificationEvents,
        now = DateTime.utc(2027);
    await a.saveSchedule(event('race'), now.add(const Duration(hours: 1)), now);
    final lease = now.add(const Duration(minutes: 1));
    final claims = await Future.wait([
      a.claimSchedule('a', 1, 'arm_pending', now, lease),
      b.claimSchedule('a', 1, 'arm_pending', now, lease),
    ]);
    expect(claims.where((v) => v), hasLength(1));
    await first.close();
    await second.close();
    final reopened = open();
    await reopened.initialize();
    addTearDown(reopened.close);
    final store = reopened.notificationEvents;
    await store.recoverScheduleLeases('a', now.add(const Duration(minutes: 2)));
    final row = (await store.scheduleWork(
      'a',
      now.add(const Duration(minutes: 2)),
    )).single;
    expect(row['local_id'], 1);
    expect(row['schedule_attempt_count'], 1);
    expect(row['attempt_count'], 0);
    expect(row['schedule_state'], 'arm_pending');
  });
  test('schedule queries are indexed, bounded and account isolated', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await SqliteNotificationEventStore.createSchema(db);
    final store = SqliteNotificationEventStore(db), now = DateTime.utc(2027);
    for (var i = 0; i < 25; i++) {
      await store.saveSchedule(
        event('a-$i'),
        now.add(const Duration(hours: 1)),
        now,
      );
      await store.saveSchedule(
        event('b-$i', account: 'b'),
        now.add(const Duration(hours: 1)),
        now,
      );
    }
    expect(await store.scheduleWork('a', now), hasLength(20));
    for (final row in await store.scheduleWork('a', now)) {
      expect(row['account_id'], 'a');
    }
    for (final query in [
      (
        SqliteNotificationEventStore.elapsedPageSql,
        <Object?>['a', now.microsecondsSinceEpoch],
        'notification_schedule_due_idx',
      ),
      (
        SqliteNotificationEventStore.entityScheduleSql,
        <Object?>['a', 'w', 'booking_request', 'r'],
        'notification_schedule_entity_idx',
      ),
      (
        SqliteNotificationEventStore.scheduleLeaseSql,
        <Object?>['a', now.toIso8601String()],
        'notification_schedule_lease_idx',
      ),
      (
        SqliteNotificationEventStore.pendingSql,
        <Object?>['a', now.toIso8601String()],
        'notification_pending_idx',
      ),
    ]) {
      final plan = await db.rawQuery(
        'explain query plan ${query.$1}',
        query.$2,
      );
      expect(
        plan.map((r) => r['detail']).join(' '),
        contains('INDEX ${query.$3}'),
      );
      expect(
        plan.map((r) => r['detail']).join(' '),
        isNot(contains('SCAN notification_events')),
      );
    }
  });
  test(
    'third cancel failure is degraded and cannot enter another retry loop',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await SqliteNotificationEventStore.createSchema(db);
      final store = SqliteNotificationEventStore(db), now = DateTime.utc(2027);
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
        'session_paused',
        now,
      );
      final lease = now.add(const Duration(minutes: 1));
      for (var i = 0; i < 3; i++) {
        expect(
          await store.claimSchedule('a', 1, 'cancel_pending', now, lease),
          true,
        );
        await store.finishSchedule(
          'a',
          1,
          'cancelling',
          lease,
          success: false,
          now: now,
        );
      }
      expect(await store.scheduleWork('a', now), isEmpty);
      expect(
        await store.claimSchedule('a', 1, 'cancel_pending', now, lease),
        false,
      );
      final row = (await db.query('notification_events')).single;
      expect(row['schedule_attempt_count'], 3);
      expect(row['schedule_state'], 'cancel_pending');
      expect(row['attempt_count'], 0);
    },
  );
  test('expired arm and cancel leases are recoverable without changing immediate attempts', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await SqliteNotificationEventStore.createSchema(db);
    final store = SqliteNotificationEventStore(db), now = DateTime.utc(2027);
    await store.saveSchedule(
      event('lease'),
      now.add(const Duration(hours: 1)),
      now,
    );
    final lease = now.add(const Duration(minutes: 1));
    await store.claimSchedule('a', 1, 'arm_pending', now, lease);
    await store.recoverScheduleLeases('a', now.add(const Duration(minutes: 2)));
    var row = (await db.query('notification_events')).single;
    expect(row['schedule_state'], 'arm_pending');
    expect(row['schedule_attempt_count'], 1);
    await store.cancelSchedules(
      'a',
      'w',
      'booking_request',
      'r',
      'session_paused',
      now,
    );
    await store.claimSchedule('a', 1, 'cancel_pending', now, lease);
    await store.recoverScheduleLeases('a', now.add(const Duration(minutes: 2)));
    row = (await db.query('notification_events')).single;
    expect(row['schedule_state'], 'cancel_pending');
    expect(row['schedule_attempt_count'], 1);
    expect(row['attempt_count'], 0);
  });
  test('scheduled rows cannot enter immediate delivery and schema enforces scheduling identity', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await SqliteNotificationEventStore.createSchema(db);
    expect(SqliteOutboxStore.schemaVersion, 11);
    final store = SqliteNotificationEventStore(db);
    await store.insertEvent(event('immediate'));
    await db.insert('notification_events', {
      ...event('future').toRow(),
      'due_at': 2000000000000000,
      'schedule_state': 'arm_pending',
    });
    expect(
      (await store.pending(
        'a',
        DateTime.utc(2027),
      )).map((e) => e.event.eventKey),
      ['immediate'],
    );
    final future = (await db.query(
      'notification_events',
      where: 'event_key=?',
      whereArgs: ['future'],
    )).single;
    expect(
      await store.claim(
        'a',
        future['local_id'] as int,
        DateTime.utc(2027),
        DateTime.utc(2027, 1, 1, 0, 1),
      ),
      isFalse,
    );
    await expectLater(
      db.insert('notification_events', {
        ...event('invalid').toRow(),
        'due_at': 1,
      }),
      throwsA(isA<DatabaseException>()),
    );
    await expectLater(
      db.rawUpdate('update notification_events set schedule_attempt_count=4'),
      throwsA(isA<DatabaseException>()),
    );
  });
  test('schedule claims, retries, cancellation and future reactivation preserve platform ID', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await SqliteNotificationEventStore.createSchema(db);
    final store = SqliteNotificationEventStore(db);
    final now = DateTime.utc(2027);
    final due = now.add(const Duration(hours: 1));
    await store.saveSchedule(event('scheduled'), due, now);
    final row = (await store.scheduleWork('a', now)).single;
    final id = row['local_id'] as int;
    final lease = now.add(const Duration(minutes: 1));
    expect(await store.claimSchedule('a', id, 'arm_pending', now, lease), true);
    expect(
      await store.claimSchedule('a', id, 'arm_pending', now, lease),
      false,
    );
    await store.finishSchedule(
      'a',
      id,
      'arming',
      lease,
      success: false,
      now: now,
    );
    expect(
      (await store.scheduleWork('a', now)).single['schedule_attempt_count'],
      1,
    );
    expect(await store.claimSchedule('a', id, 'arm_pending', now, lease), true);
    await store.finishSchedule(
      'a',
      id,
      'arming',
      lease,
      success: true,
      now: now,
    );
    expect(
      (await db.query('notification_events')).single['schedule_state'],
      'armed',
    );
    await store.cancelSchedules(
      'a',
      'different-well',
      'booking_request',
      'r',
      'cancelled',
      now,
    );
    // The fixture has no well, so a different well must not cancel it.
    expect(
      (await db.query('notification_events')).single['schedule_state'],
      'armed',
    );
    await store.cancelSchedules(
      'a',
      'w',
      'booking_request',
      'r',
      'cancelled',
      now,
    );
    expect(
      await store.claimSchedule('a', id, 'cancel_pending', now, lease),
      true,
    );
    await store.finishSchedule(
      'a',
      id,
      'cancelling',
      lease,
      success: true,
      now: now,
    );
    await store.saveSchedule(event('scheduled'), due, now, eligible: true);
    final rearmed = (await store.scheduleWork('a', now)).single;
    expect(rearmed['local_id'], id);
    expect(rearmed['state'], 'pending');
    expect(rearmed['schedule_state'], 'arm_pending');
    expect(rearmed['attempt_count'], 0);
  });
}

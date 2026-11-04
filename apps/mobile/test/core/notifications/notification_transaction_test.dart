import 'dart:io';
import 'dart:convert';

import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/booking/local_booking_request.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import '../sync/booking_dispatch_c2a_test.dart' show booking, epoch;
import 'package:well_irrigation_mobile/core/notifications/app_notification_event.dart';
import '../sync/booking_pending_farm_test.dart' show pendingFarm;

AppNotificationEvent event(
  String key, {
  String account = 'a',
  String well = 'w',
  String type = 'booking.confirmed',
}) => AppNotificationEvent(
  eventKey: key,
  accountId: account,
  wellId: well,
  category: 'booking_results',
  presentationPolicy: 'always_alert',
  eventType: type,
  entityType: 'booking_request',
  entityId: 'r',
  routeType: 'bookings',
  routePayload: {'day': '2026-10-16', 'request_id': 'r'},
  createdAt: DateTime.utc(2026, 10, 16),
);

Future<void> seedAcceptedState(SqliteOutboxStore store) async {
  final a = LocalBookingRequest(
    accountId: 'a',
    wellId: 'well-0',
    requestId: 'A',
    commandId: 'cmd-A',
    createdLocalAt: epoch,
    scheduledDay: '2027-01-01',
    payloadJson: jsonEncode(booking(0).payload),
    contextJson: '{"farmer_name":"أحمد"}',
  );
  await store.saveBookingRequest(a);
  await store.claimBookingCreate('a', a.commandId, attemptedAt: epoch);
  await store.finishBookingCreate(
    'a',
    a.commandId,
    claimedAt: epoch,
    status: CommandStatus.review,
    response: {'status': 'rejected', 'reason_code': 'retained'},
  );
  final b = LocalBookingRequest(
    accountId: 'a',
    wellId: 'well-0',
    requestId: 'B',
    commandId: 'cmd-B',
    createdLocalAt: epoch,
    scheduledDay: '2027-01-01',
    payloadJson: a.payloadJson,
    contextJson: a.contextJson,
    replacesRequestId: 'A',
  );
  await store.saveBookingRequest(b);
  await store.claimBookingCreate('a', b.commandId, attemptedAt: epoch);
  await store.finishBookingCreate(
    'a',
    b.commandId,
    claimedAt: epoch,
    status: CommandStatus.pending,
    nextAttemptAt: epoch.add(const Duration(hours: 1)),
    error: 'retained retry',
  );
  await store.writeLocalValue(
    'a',
    'booking-choice-cache',
    '{"farmers":[{"id":"f"}]}',
  );
  final farm = await pendingFarm(store);
  await store.putMapping(
    'a',
    IdMapping(
      localId: farm.entityReference.localReference!.localId,
      kind: EntityKind.farm,
      serverId: 'canonical-farm',
      resolvedAt: epoch,
    ),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);
  test('real file 9 to 10 preserves rows and IDs; fresh and upgraded schemas agree', () async {
    final dir = await Directory.systemTemp.createTemp('schedule_upgrade');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/db';
    SqliteOutboxStore open() => SqliteOutboxStore(
      databasePath: path,
      sqfliteFactory: databaseFactoryFfi,
      singleInstance: false,
    );
    var store = open();
    await store.initialize();
    await seedAcceptedState(store);
    await store.close();
    var db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    final freshColumns = await db.rawQuery(
      'pragma table_info(notification_events)',
    );
    final freshIndexes = await db.rawQuery(
      "select name,sql from sqlite_master where type='index' and tbl_name='notification_events' order by name",
    );
    await db.execute('drop table notification_events');
    await db.execute('''create table notification_events (
      local_id integer primary key autoincrement,
      account_id text not null, well_id text,
      event_key text not null, category text not null, event_type text not null,
      entity_type text not null, entity_id text,
      route_type text not null, route_payload_json text not null,
      privacy_class text not null, presentation_policy text not null,
      state text not null default 'pending' check(state in ('pending','presenting','delivered','suppressed')),
      attempt_count integer not null default 0,
      lease_until text, delivered_at text, suppressed_at text, suppressed_reason text,
      created_at text not null, unique(account_id,event_key))''');
    await db.execute(
      "create index notification_pending_idx on notification_events(account_id,local_id) where state in ('pending','presenting')",
    );
    for (final state in ['pending', 'presenting', 'delivered', 'suppressed']) {
      await db.insert('notification_events', {
        ...event(state).toRow(),
        'presentation_policy': 'always_silent',
        'state': state,
        'attempt_count': 2,
        'lease_until': '2027-01-01T00:00:00.000Z',
        'delivered_at': 'retained-delivery',
        'suppressed_at': 'retained-suppression',
        'suppressed_reason': 'retained-reason',
      });
    }
    final before = await db.query('notification_events', orderBy: 'local_id');
    final tables = (await db.rawQuery(
      "select name from sqlite_master where type='table' and name not like 'sqlite_%' and name not in ('android_metadata','notification_events')",
    )).map((r) => r['name'] as String).toList();
    final beforeBusiness = {
      for (final table in tables) table: await db.query(table),
    };
    await db.setVersion(9);
    await db.close();
    store = open();
    await store.initialize();
    db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    expect(await db.getVersion(), 11);
    final after = await db.query('notification_events', orderBy: 'local_id');
    for (var i = 0; i < before.length; i++) {
      expect({for (final key in before[i].keys) key: after[i][key]}, before[i]);
      expect(after[i]['due_at'], null);
      expect(after[i]['schedule_state'], 'none');
      expect(after[i]['schedule_attempt_count'], 0);
    }
    for (final table in tables) {
      expect(await db.query(table), beforeBusiness[table], reason: table);
    }
    expect(
      await db.rawQuery('pragma table_info(notification_events)'),
      freshColumns,
    );
    expect(
      await db.rawQuery(
        "select name,sql from sqlite_master where type='index' and tbl_name='notification_events' order by name",
      ),
      freshIndexes,
    );
    await db.close();
    await store.close();
  });
  test(
    'terminal booking result atomically creates one generic durable event',
    () async {
      final dir = await Directory.systemTemp.createTemp('c3');
      final path = '${dir.path}/outbox.db';
      final store = SqliteOutboxStore(
        databasePath: path,
        sqfliteFactory: databaseFactoryFfi,
        singleInstance: false,
      );
      await store.initialize();
      final db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      try {
        await store.insert(booking(0));
        await store.claimBookingCreate('a', 'a-local-0', attemptedAt: epoch);
        await store.finishBookingCreate(
          'a',
          'a-local-0',
          claimedAt: epoch,
          status: CommandStatus.review,
          response: {'status': 'rejected'},
        );
        final tables = await db.rawQuery(
          "select name from sqlite_master where type='table' and name='notification_events'",
        );
        expect(
          tables,
          hasLength(1),
          reason: 'terminal results need an atomic generic event ledger',
        );
        final events = await db.query('notification_events');
        expect(events, hasLength(1));
        expect(
          events.single['event_key'],
          'booking-result/a-command-0/rejected',
        );
        expect(events.single['event_type'], 'booking.rejected');
        expect(events.single['attempt_count'], 0);
      } finally {
        await db.close();
        await store.close();
        await dir.delete(recursive: true);
      }
    },
  );
  for (final entry in <(CommandStatus, Map<String, Object?>?, String?)>[
    (CommandStatus.confirmed, {'status': 'confirmed'}, 'booking.confirmed'),
    (CommandStatus.review, {'status': 'conflict'}, 'booking.time_unavailable'),
    (CommandStatus.review, {'status': 'rejected'}, 'booking.rejected'),
    (CommandStatus.review, null, 'booking.review_required'),
    (CommandStatus.pending, null, null),
  ]) {
    test(
      'durable result ${entry.$1}/${entry.$2} maps without inventing a server status',
      () async {
        final dir = await Directory.systemTemp.createTemp('c3_result');
        final store = SqliteOutboxStore(
          databasePath: '${dir.path}/db',
          sqfliteFactory: databaseFactoryFfi,
          singleInstance: false,
        );
        await store.initialize();
        final db = await databaseFactoryFfi.openDatabase(
          '${dir.path}/db',
          options: OpenDatabaseOptions(singleInstance: false),
        );
        try {
          await store.insert(booking(0));
          await store.claimBookingCreate('a', 'a-local-0', attemptedAt: epoch);
          await store.finishBookingCreate(
            'a',
            'a-local-0',
            claimedAt: epoch,
            status: entry.$1,
            response: entry.$2,
          );
          final rows = await db.query('notification_events');
          expect(rows, hasLength(entry.$3 == null ? 0 : 1));
          if (rows.isNotEmpty) expect(rows.single['event_type'], entry.$3);
          expect(
            (await store.commandByLocalId('a', 'a-local-0'))!.commandId,
            'a-command-0',
          );
        } finally {
          await db.close();
          await store.close();
          await dir.delete(recursive: true);
        }
      },
    );
  }
  test('event insert failure rolls back result, reopen retries same command, duplicate event is benign', () async {
    final dir = await Directory.systemTemp.createTemp('c3_atomic');
    final path = '${dir.path}/db';
    SqliteOutboxStore open() => SqliteOutboxStore(
      databasePath: path,
      sqfliteFactory: databaseFactoryFfi,
      singleInstance: false,
    );
    var store = open();
    await store.initialize();
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      await store.insert(booking(0));
      await store.claimBookingCreate('a', 'a-local-0', attemptedAt: epoch);
      await db.execute(
        "create trigger injected_failure before insert on notification_events begin select raise(abort,'injected'); end",
      );
      await expectLater(
        store.finishBookingCreate(
          'a',
          'a-local-0',
          claimedAt: epoch,
          status: CommandStatus.confirmed,
          response: {'status': 'confirmed'},
          entityId: 'b',
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        (await store.commandByLocalId('a', 'a-local-0'))!.status,
        CommandStatus.dispatching,
      );
      expect(await db.query('notification_events'), isEmpty);
      expect(await store.mapping('a', 'a-local-0', EntityKind.booking), isNull);
      await db.execute('drop trigger injected_failure');
      await store.close();
      store = open();
      await store.initialize();
      expect(
        (await store.commandByLocalId('a', 'a-local-0'))!.commandId,
        'a-command-0',
      );
      await store.finishBookingCreate(
        'a',
        'a-local-0',
        claimedAt: epoch,
        status: CommandStatus.confirmed,
        response: {'status': 'confirmed'},
        entityId: 'b',
      );
      await db.rawUpdate(
        "update outbox_commands set status='dispatching' where local_id='a-local-0'",
      );
      expect(
        await store.finishBookingCreate(
          'a',
          'a-local-0',
          claimedAt: epoch,
          status: CommandStatus.confirmed,
          response: {'status': 'confirmed'},
          entityId: 'b',
        ),
        isTrue,
      );
      expect(await db.query('notification_events'), hasLength(1));
      expect(
        (await store.commandByLocalId('a', 'a-local-0'))!.status,
        CommandStatus.confirmed,
      );
    } finally {
      await db.close();
      await store.close();
      await dir.delete(recursive: true);
    }
  });
  test(
    'real 8 to 10 file upgrade preserves every existing table byte-for-byte',
    () async {
      final dir = await Directory.systemTemp.createTemp('c3_upgrade');
      final path = '${dir.path}/db';
      SqliteOutboxStore open() => SqliteOutboxStore(
        databasePath: path,
        sqfliteFactory: databaseFactoryFfi,
        singleInstance: false,
      );
      var store = open();
      await store.initialize();
      await seedAcceptedState(store);
      await store.close();
      var db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await db.execute('drop table notification_events');
      await db.setVersion(8);
      final tables = (await db.rawQuery(
        "select name from sqlite_master where type='table' and name not like 'sqlite_%' and name!='android_metadata'",
      )).map((r) => r['name'] as String).toList();
      final before = {for (final t in tables) t: await db.query(t)};
      await db.close();
      store = open();
      await store.initialize();
      db = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      expect(await db.getVersion(), 11);
      for (final t in tables) {
        expect(await db.query(t), before[t], reason: t);
      }
      await db.close();
      await store.close();
      await dir.delete(recursive: true);
    },
  );
}

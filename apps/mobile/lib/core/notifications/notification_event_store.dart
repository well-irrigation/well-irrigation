import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'app_notification_event.dart';

class SqliteNotificationEventStore {
  SqliteNotificationEventStore(this.db);
  final Database db;
  static Future<void> createSchema(DatabaseExecutor tx) async {
    await tx.execute('''create table notification_events (
      local_id integer primary key autoincrement,
      account_id text not null, well_id text,
      event_key text not null, category text not null, event_type text not null,
      entity_type text not null, entity_id text,
      route_type text not null, route_payload_json text not null,
      privacy_class text not null, presentation_policy text not null,
      state text not null default 'pending' check(state in ('pending','presenting','delivered','suppressed')),
      attempt_count integer not null default 0,
      lease_until text, delivered_at text, suppressed_at text, suppressed_reason text,
      created_at text not null,
      due_at integer,
      schedule_state text not null default 'none'
        check(schedule_state in ('none','arm_pending','arming','armed','cancel_pending','cancelling','cancelled','elapsed'))
        check((due_at is null and schedule_state='none') or (due_at is not null and schedule_state!='none')),
      schedule_attempt_count integer not null default 0 check(schedule_attempt_count between 0 and 3),
      route_day text,
      unique(account_id,event_key)
    )''');
    await _createIndexes(tx);
    await _createReconciliationSchema(tx);
  }

  static Future<void> upgradeFrom9(DatabaseExecutor tx) async {
    await tx.execute(
      'alter table notification_events add column due_at integer',
    );
    await tx.execute(
      """alter table notification_events add column schedule_state text not null default 'none'
      check(schedule_state in ('none','arm_pending','arming','armed','cancel_pending','cancelling','cancelled','elapsed'))
      check((due_at is null and schedule_state='none') or (due_at is not null and schedule_state!='none'))""",
    );
    await tx.execute(
      'alter table notification_events add column schedule_attempt_count integer not null default 0 check(schedule_attempt_count between 0 and 3)',
    );
    await tx.execute('drop index notification_pending_idx');
    await _createIndexes(tx);
  }

  static Future<void> _createReconciliationSchema(DatabaseExecutor tx) async {
    await tx.execute("""create table if not exists notification_reconcile_keys (
      account_id text not null, well_id text not null, entity_type text not null,
      scope_day text not null, event_key text not null,
      primary key(account_id,well_id,entity_type,scope_day,event_key))""");
    await tx.execute("""create index if not exists notification_schedule_scope_idx
      on notification_events(account_id,well_id,entity_type,route_day,entity_id,local_id)
      where due_at is not null and schedule_state in ('arm_pending','arming','armed','cancel_pending','cancelling')""");
  }

  static Future<void> upgradeTo11(DatabaseExecutor tx) async {
    final columns = await tx.rawQuery('pragma table_info(notification_events)');
    if (!columns.any((row) => row['name'] == 'route_day')) {
      await tx.execute('alter table notification_events add column route_day text');
    }
    int? cursor;
    while (true) {
      final rows = await tx.query('notification_events', columns: ['local_id','route_payload_json'],
        where: cursor == null ? null : 'local_id>?', whereArgs: cursor == null ? null : [cursor],
        orderBy: 'local_id', limit: 200);
      if (rows.isEmpty) break;
      for (final row in rows) {
        await tx.update('notification_events', {'route_day': _routeDay(row['route_payload_json'] as String)},
          where: 'local_id=?', whereArgs: [row['local_id']]);
      }
      cursor = rows.last['local_id'] as int;
    }
    await _createReconciliationSchema(tx);
  }

  static String? _routeDay(String payload) {
    final route = jsonDecode(payload) as Map<String,dynamic>;
    return route['day'] as String?;
  }

  /// Core SQLite INSERT: ignore only a verified event identity collision.
  /// Unlike INSERT OR IGNORE, invalid rows still abort their business transaction.
  static Future<void> _insertIdentity(DatabaseExecutor tx, Map<String,Object?> row) async {
    try {
      await tx.insert('notification_events', row);
    } on DatabaseException catch (error) {
      if (!error.isUniqueConstraintError()) rethrow;
      final existing = await tx.query('notification_events', columns: ['local_id'],
        where: 'account_id=? and event_key=?', whereArgs: [row['account_id'],row['event_key']], limit: 1);
      if (existing.isEmpty) rethrow;
    }
  }

  static Future<void> _createIndexes(DatabaseExecutor tx) async {
    await tx.execute(
      "create index notification_pending_idx on notification_events(account_id,local_id) where due_at is null and state in ('pending','presenting')",
    );
    await tx.execute(
      'create index notification_schedule_due_idx on notification_events(account_id,schedule_state,due_at,local_id) where due_at is not null',
    );
    await tx.execute(
      "create index notification_schedule_lease_idx on notification_events(account_id,schedule_state,lease_until,local_id) where due_at is not null and schedule_state in ('arming','cancel_pending','cancelling')",
    );
    await tx.execute(
      "create index notification_schedule_entity_idx on notification_events(account_id,well_id,entity_type,entity_id,local_id) where due_at is not null and schedule_state in ('arm_pending','arming','armed','cancel_pending','cancelling')",
    );
  }

  static Future<void> insertEventTx(
    DatabaseExecutor tx,
    AppNotificationEvent event, {
    String? suppression,
  }) async {
    final row = {
      ...event.toRow(),
      'route_day': _routeDay(event.toRow()['route_payload_json'] as String),
      'state': suppression == null ? 'pending' : 'suppressed',
      'suppressed_reason': suppression,
      if (suppression != null)
        'suppressed_at': event.createdAt.toUtc().toIso8601String(),
    };
    await _insertIdentity(tx, row);
  }

  Future<void> insertEvent(AppNotificationEvent event) =>
      insertEventTx(db, event);
}

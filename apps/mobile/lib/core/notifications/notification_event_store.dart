import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'app_notification_event.dart';

abstract interface class NotificationEventStore {
  Future<void> insertEvent(AppNotificationEvent event);
  Future<List<NotificationDelivery>> pending(String accountId, DateTime now);
  Future<bool> hasOutstanding(String accountId);
  Future<bool> claim(
    String accountId,
    int id,
    DateTime now,
    DateTime leaseUntil,
  );
  Future<bool> beginPresentation(String accountId, int id, DateTime leaseUntil);
  Future<void> complete(
    String accountId,
    int id,
    DateTime leaseUntil,
    DateTime now, {
    String? suppressedReason,
    bool retry = false,
  });
}

class SqliteNotificationEventStore implements NotificationEventStore {
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

  @override
  Future<void> insertEvent(AppNotificationEvent event) =>
      insertEventTx(db, event);
  static const pendingSql =
      "select * from notification_events indexed by notification_pending_idx where due_at is null and account_id=? and state in ('pending','presenting') and (state='pending' or lease_until<=?) order by local_id limit 20";
  @override
  Future<List<NotificationDelivery>> pending(
    String accountId,
    DateTime now,
  ) async => (await db.rawQuery(pendingSql, [
    accountId,
    _time(now),
  ])).map(NotificationDelivery.fromRow).toList();
  @override
  Future<bool> hasOutstanding(String accountId) async => (await db.rawQuery(
    "select local_id from notification_events indexed by notification_pending_idx where due_at is null and account_id=? and state in ('pending','presenting') limit 1",
    [accountId],
  )).isNotEmpty;
  Future<AppNotificationEvent?> eventById(String accountId, int id) async {
    final rows = await db.query(
      'notification_events',
      where: 'account_id=? and local_id=?',
      whereArgs: [accountId, id],
      limit: 1,
    );
    return rows.isEmpty ? null : AppNotificationEvent.fromRow(rows.single);
  }

  @override
  Future<bool> claim(
    String accountId,
    int id,
    DateTime now,
    DateTime leaseUntil,
  ) async =>
      await db.rawUpdate(
        "update notification_events set state='presenting',lease_until=? where due_at is null and account_id=? and local_id=? and (state='pending' or (state='presenting' and lease_until<=?))",
        [_time(leaseUntil), accountId, id, _time(now)],
      ) ==
      1;
  @override
  Future<bool> beginPresentation(
    String accountId,
    int id,
    DateTime leaseUntil,
  ) async =>
      await db.rawUpdate(
        "update notification_events set attempt_count=attempt_count+1 where due_at is null and account_id=? and local_id=? and state='presenting' and lease_until=? and attempt_count<3",
        [accountId, id, _time(leaseUntil)],
      ) ==
      1;
  @override
  Future<void> complete(
    String accountId,
    int id,
    DateTime leaseUntil,
    DateTime now, {
    String? suppressedReason,
    bool retry = false,
  }) async {
    await db.rawUpdate(
      '''update notification_events set state=?,lease_until=null,
      delivered_at=?,suppressed_at=?,suppressed_reason=?
      where due_at is null and account_id=? and local_id=? and state='presenting' and lease_until=?''',
      [
        retry
            ? 'pending'
            : suppressedReason == null
            ? 'delivered'
            : 'suppressed',
        !retry && suppressedReason == null ? _time(now) : null,
        suppressedReason == null ? null : _time(now),
        suppressedReason,
        accountId,
        id,
        _time(leaseUntil),
      ],
    );
  }

  Future<bool> rationaleSeen(String account) async => (await db.query(
    'sync_meta',
    columns: ['value'],
    where: 'account_id=? and key=?',
    whereArgs: [account, 'notification_rationale_seen'],
    limit: 1,
  )).isNotEmpty;
  Future<void> markRationaleSeen(String account) => db.insert('sync_meta', {
    'account_id': account,
    'key': 'notification_rationale_seen',
    'value': '1',
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
  static String _time(DateTime time) => time.toUtc().toIso8601String();

  /// Eligibility and trusted time are supplied by the domain, never inferred
  /// from a notification row or from the device wall clock.
  Future<void> saveSchedule(
    AppNotificationEvent event,
    DateTime due,
    DateTime trustedNow, {
    bool eligible = true,
  }) => db.transaction((tx) async {
    if (!eligible || !due.isAfter(trustedNow)) return;
    await _saveScheduleTx(tx, event, due, trustedNow);
  });
  static Future<void> _saveScheduleTx(
    DatabaseExecutor tx,
    AppNotificationEvent event,
    DateTime due,
    DateTime trustedNow, {
    bool reactivate = true,
  }) async {
    final row = {
      ...event.toRow(),
      'route_day': _routeDay(event.toRow()['route_payload_json'] as String),
      'due_at': due.toUtc().microsecondsSinceEpoch,
      'schedule_state': 'arm_pending',
    };
    await _insertIdentity(tx, row);
    if (!reactivate) return;
    await tx.rawUpdate(
      """update notification_events set state='pending',
      schedule_state='arm_pending',schedule_attempt_count=0,
      suppressed_at=null,suppressed_reason=null,lease_until=null
      where account_id=? and event_key=? and due_at=? and due_at>?
      and state='suppressed' and schedule_state='cancelled'
      and coalesce(suppressed_reason,'') not in ('session_started','permission_denied','schedule_arm_failed')""",
      [
        event.accountId,
        event.eventKey,
        due.toUtc().microsecondsSinceEpoch,
        trustedNow.toUtc().microsecondsSinceEpoch,
      ],
    );
  }

  /// One bounded read and one transaction, rather than one mapping/query per reminder.
  Future<void> reconcileSchedules(
    String account,
    String well,
    String entityType,
    List<({AppNotificationEvent event, DateTime due})> intents,
    Set<String> eligibleKeys,
    DateTime now, {
    bool reactivate = false,
    String? routeDay,
    bool Function()? isCurrent,
    Future<bool> Function(DatabaseExecutor)? validateEligibility,
  }) => db.transaction((tx) async {
    if (isCurrent?.call() == false) {
      throw StateError('stale_notification_context');
    }
    final effectiveKeys =
        validateEligibility != null && !await validateEligibility(tx)
        ? <String>{}
        : eligibleKeys;
    final scope = [account, well, entityType, routeDay ?? ''];
    const scopeWhere = 'account_id=? and well_id=? and entity_type=? and scope_day=?';
    await tx.delete('notification_reconcile_keys', where: scopeWhere, whereArgs: scope);
    // The complete eligibility set may span many 20-intent pages. Membership
    // lives only in this transaction, with bounded batches and no bind-list cap.
    final keys = effectiveKeys.iterator;
    var more = keys.moveNext();
    while (more) {
      final batch = tx.batch();
      for (var count = 0; count < 200 && more; count++) {
        batch.insert('notification_reconcile_keys', {
          'account_id': account, 'well_id': well, 'entity_type': entityType,
          'scope_day': routeDay ?? '', 'event_key': keys.current,
        });
        more = keys.moveNext();
      }
      await batch.commit(noResult: true);
    }
    final rows = await tx.rawQuery(
      reconciliationSql(routeDay: routeDay),
      [account, well, entityType, ?routeDay, routeDay ?? '', now.toUtc().microsecondsSinceEpoch],
    );
    for (final row in rows) {
      if ((row['due_at'] as int) <= now.toUtc().microsecondsSinceEpoch &&
          row['state'] != 'suppressed' &&
          const {'arm_pending', 'armed'}.contains(row['schedule_state'])) {
        await tx.rawUpdate(
          "update notification_events set schedule_state='elapsed',lease_until=null where account_id=? and local_id=? and schedule_state in ('arm_pending','armed')",
          [account, row['local_id']],
        );
        continue;
      }
      if (!effectiveKeys.contains(row['event_key'])) {
        await tx.rawUpdate(
          """update notification_events set state='suppressed',
          suppressed_at=?,suppressed_reason='no_longer_eligible',schedule_state='cancel_pending',schedule_attempt_count=0
          where account_id=? and local_id=? and schedule_state in ('arm_pending','arming','armed')""",
          [_time(now), account, row['local_id']],
        );
      }
    }
    for (final intent in intents.take(20)) {
      if (intent.event.accountId != account ||
          intent.event.wellId != well ||
          intent.event.entityType != entityType) {
        throw ArgumentError('schedule_scope_mismatch');
      }
      if (effectiveKeys.contains(intent.event.eventKey) &&
          intent.due.isAfter(now)) {
        await _saveScheduleTx(
          tx,
          intent.event,
          intent.due,
          now,
          reactivate: reactivate,
        );
      }
    }
    if (isCurrent?.call() == false) {
      throw StateError('stale_notification_context');
    }
    await tx.delete('notification_reconcile_keys', where: scopeWhere, whereArgs: scope);
  });

  static String reconciliationSql({String? routeDay}) => """
    select n.local_id,n.event_key,n.due_at,n.state,n.schedule_state
    from notification_events n indexed by notification_schedule_scope_idx
    where n.account_id=? and n.well_id=? and n.entity_type=? and n.due_at is not null
      and n.schedule_state in ('arm_pending','arming','armed','cancel_pending','cancelling')
      ${routeDay == null ? '' : 'and n.route_day=?'}
      and n.schedule_state in ('arm_pending','arming','armed')
      and (not exists (select 1 from notification_reconcile_keys k
        where k.account_id=n.account_id and k.well_id=n.well_id and k.entity_type=n.entity_type
          and k.scope_day=? and k.event_key=n.event_key) or n.due_at<=?)
    order by n.entity_id,n.local_id limit 20
  """;

  Future<void> recoverSchedulesPage(
    String account,
    String well,
    List<Map<String, Object?>> rows,
    Set<String> eligibleKeys,
    DateTime trustedNow,
  ) => db.transaction((tx) async {
    if (rows.length > 20) throw ArgumentError('schedule_page_too_large');
    for (final row in rows) {
      if (row['account_id'] != account || row['well_id'] != well) {
        throw ArgumentError('schedule_scope_mismatch');
      }
      final past =
          (row['due_at'] as int) <= trustedNow.toUtc().microsecondsSinceEpoch;
      final eligible = eligibleKeys.contains(row['event_key']);
      await tx.rawUpdate(
        """update notification_events set schedule_state=?,
        state=case when ? then 'suppressed' else state end,
        suppressed_at=case when ? then ? else suppressed_at end,
        suppressed_reason=case when ? then 'no_longer_eligible' else suppressed_reason end,
        schedule_attempt_count=case when ? then 0 else schedule_attempt_count end
        where account_id=? and well_id=? and local_id=? and due_at is not null
        and schedule_state in ('armed','arm_pending')""",
        [
          past
              ? 'elapsed'
              : eligible
              ? 'arm_pending'
              : 'cancel_pending',
          !past && !eligible ? 1 : 0,
          !past && !eligible ? 1 : 0,
          _time(trustedNow),
          !past && !eligible ? 1 : 0,
          !past && !eligible ? 1 : 0,
          account,
          well,
          row['local_id'],
        ],
      );
    }
  });

  static const activeScheduleStates =
      "('arm_pending','arming','armed','cancel_pending','cancelling')";
  static const scheduleWorkSql = """select * from notification_events
    indexed by notification_schedule_due_idx where account_id=?
    and due_at is not null and schedule_state in ('arm_pending','cancel_pending')
    and schedule_attempt_count<3 and (lease_until is null or lease_until<=?)
    order by schedule_state desc,due_at,local_id limit 20""";
  Future<List<Map<String, Object?>>> scheduleWork(
    String account,
    DateTime now, {
    String? wellId,
    String? entityType,
  }) => db.rawQuery(
    scheduleWorkSql.replaceFirst(
      'order by',
      '${wellId == null ? '' : 'and well_id=?'} ${entityType == null ? '' : 'and entity_type=?'} order by',
    ),
    [account, _time(now), ?wellId, ?entityType],
  );

  static const scheduleLeaseSql = """select * from notification_events
    indexed by notification_schedule_lease_idx where account_id=?
    and due_at is not null and schedule_state in ('arming','cancel_pending','cancelling')
    and lease_until<=? order by lease_until,local_id limit 20""";
  static const elapsedPageSql = """select local_id from notification_events
    indexed by notification_schedule_due_idx where account_id=?
    and due_at is not null and schedule_state='armed' and due_at<=?
    order by due_at,local_id limit 20""";
  Future<void> expireSchedules(String account, DateTime trustedNow) async {
    final rows = await db.rawQuery(elapsedPageSql, [
      account,
      trustedNow.toUtc().microsecondsSinceEpoch,
    ]);
    for (final row in rows) {
      await markElapsed(account, row['local_id'] as int, trustedNow);
    }
  }

  Future<void> recoverScheduleLeases(String account, DateTime now) =>
      db.transaction((tx) async {
        final rows = await tx.rawQuery(scheduleLeaseSql, [account, _time(now)]);
        for (final row in rows) {
          final phase = row['schedule_state'];
          if (phase == 'cancel_pending') {
            await tx.rawUpdate(
              'update notification_events set lease_until=null where account_id=? and local_id=? and lease_until=?',
              [account, row['local_id'], row['lease_until']],
            );
          } else {
            await _finishScheduleTx(
              tx,
              account,
              row['local_id'] as int,
              phase as String,
              row['lease_until'] as String,
              success: false,
              now: now,
            );
          }
        }
      });

  Future<bool> claimSchedule(
    String account,
    int id,
    String phase,
    DateTime now,
    DateTime lease,
  ) async {
    if (phase != 'arm_pending' && phase != 'cancel_pending') return false;
    return await db.rawUpdate(
          """update notification_events
      set schedule_state=?,schedule_attempt_count=schedule_attempt_count+1,lease_until=?
      where account_id=? and local_id=? and due_at is not null
      and schedule_state=? and schedule_attempt_count<3
      and (lease_until is null or lease_until<=?)""",
          [
            phase == 'arm_pending' ? 'arming' : 'cancelling',
            _time(lease),
            account,
            id,
            phase,
            _time(now),
          ],
        ) ==
        1;
  }

  Future<void> finishSchedule(
    String account,
    int id,
    String phase,
    DateTime lease, {
    required bool success,
    required DateTime now,
  }) => db.transaction(
    (tx) => _finishScheduleTx(
      tx,
      account,
      id,
      phase,
      _time(lease),
      success: success,
      now: now,
    ),
  );

  Future<void> releaseCancellationLease(
    String account,
    int id,
    DateTime lease,
  ) async {
    await db.rawUpdate(
      """update notification_events set lease_until=null
      where account_id=? and local_id=? and due_at is not null
      and schedule_state='cancel_pending' and lease_until=?""",
      [account, id, _time(lease)],
    );
  }

  static Future<void> _finishScheduleTx(
    DatabaseExecutor tx,
    String account,
    int id,
    String phase,
    String lease, {
    required bool success,
    required DateTime now,
  }) async {
    if (phase != 'arming' && phase != 'cancelling') return;
    final rows = await tx.rawQuery(
      'select schedule_attempt_count from notification_events where account_id=? and local_id=? and due_at is not null and schedule_state=? and lease_until=?',
      [account, id, phase, lease],
    );
    if (rows.isEmpty) return;
    final exhausted = (rows.single['schedule_attempt_count'] as int) >= 3;
    final arm = phase == 'arming';
    await tx.rawUpdate(
      """update notification_events set schedule_state=?,
      schedule_attempt_count=?,lease_until=null,
      state=case when ? then 'suppressed' else state end,
      suppressed_reason=case when ? then 'schedule_arm_failed' else suppressed_reason end,
      suppressed_at=case when ? then ? else suppressed_at end
      where account_id=? and local_id=? and schedule_state=? and lease_until=?""",
      [
        success
            ? (arm ? 'armed' : 'cancelled')
            : (arm && !exhausted ? 'arm_pending' : 'cancel_pending'),
        success || (arm && exhausted)
            ? 0
            : rows.single['schedule_attempt_count'],
        arm && exhausted && !success ? 1 : 0,
        arm && exhausted && !success ? 1 : 0,
        arm && exhausted && !success ? 1 : 0,
        _time(now),
        account,
        id,
        phase,
        lease,
      ],
    );
  }

  static const entityScheduleSql = """select local_id from notification_events
    indexed by notification_schedule_entity_idx where account_id=? and well_id is ?
    and entity_type=? and entity_id is ? and due_at is not null
    and schedule_state in ('arm_pending','arming','armed','cancel_pending','cancelling')
    and schedule_state in ('arm_pending','arming','armed')
    order by local_id limit 20""";
  Future<void> cancelSchedules(
    String account,
    String? well,
    String entityType,
    String? entityId,
    String reason,
    DateTime now,
  ) => db.transaction(
    (tx) =>
        cancelSchedulesTx(tx, account, well, entityType, entityId, reason, now),
  );
  static Future<void> cancelSchedulesTx(
    DatabaseExecutor tx,
    String account,
    String? well,
    String entityType,
    String? entityId,
    String reason,
    DateTime now,
  ) async {
    final rows = await tx.rawQuery(entityScheduleSql, [
      account,
      well,
      entityType,
      entityId,
    ]);
    for (final row in rows) {
      // Keep an in-flight lease: cancellation must not overtake an OS arm call.
      await tx.rawUpdate(
        """update notification_events set state='suppressed',
        suppressed_reason=?,suppressed_at=?,schedule_state='cancel_pending',
        schedule_attempt_count=case when schedule_state in ('cancel_pending','cancelling') then schedule_attempt_count else 0 end
        where account_id=? and local_id=? and schedule_state in ('arm_pending','arming','armed')""",
        [reason, _time(now), account, row['local_id']],
      );
    }
  }

  Future<void> markElapsed(String account, int id, DateTime now) async {
    await db.rawUpdate(
      """update notification_events set schedule_state='elapsed',lease_until=null
      where account_id=? and local_id=? and due_at is not null and due_at<=?
      and schedule_state in ('arm_pending','armed')""",
      [account, id, now.toUtc().microsecondsSinceEpoch],
    );
  }
}

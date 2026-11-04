import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/notifications/app_notification_event.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_event_store.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

import '../../support/no_json_sqlite_factory.dart';

final now = DateTime.utc(2026, 10, 17, 9);
const projections = [
  'farmer_ref_kind',
  'farmer_ref_id',
  'farm_name',
  'farm_distinguishing_label',
  'booking_farm_local_id',
];
CommandEnvelope command(
  String id,
  CommandType type,
  Map<String, Object?> payload, {
  String account = 'a',
  String? well = 'w',
  int sequence = 1,
  CommandStatus status = CommandStatus.pending,
}) => CommandEnvelope(
  localId: id,
  commandId: 'cmd-$id',
  type: type,
  accountId: account,
  wellId: well,
  sequence: sequence,
  occurredAt: now,
  createdLocalAt: now,
  payload: {'p_well_id': well ?? 'w', ...payload},
  status: status,
);
AppNotificationEvent event(
  String key, {
  String account = 'a',
  String well = 'w',
  String day = '2026-10-17',
}) => AppNotificationEvent(
  eventKey: key,
  accountId: account,
  wellId: well,
  category: 'operational',
  eventType: 'booking.due',
  entityType: 'booking',
  entityId: key,
  routeType: 'operations',
  routePayload: {'day': day},
  createdAt: now,
);

/// Reproduce old DDL, without creating a JSON expression index. The failing
/// index was never committed on no-JSON devices; upgrades must tolerate this.
Future<void> legacySchema(
  DatabaseFactory factory,
  String path,
  List<Map<String, Object?>> schema,
  int version,
) async {
  final db = await factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: (db, _) async {
        for (final item in schema) {
          final name = item['name'] as String;
          if (name == 'notification_reconcile_keys' ||
              name == 'notification_schedule_scope_idx' ||
              name == 'outbox_farm_selection_idx') {
            continue;
          }
          if (version < 8 && name == 'farm_parent_mapping_idx') continue;
          if (version < 9 && name.startsWith('notification_')) continue;
          if (version < 4 &&
              (name == 'local_booking_requests' ||
                  name.startsWith('booking_requests_'))) {
            continue;
          }
          if (version < 5 && name.startsWith('outbox_booking_')) continue;
          if (version < 3 &&
              (name == 'outbox_commands_session_idx' ||
                  name == 'id_mappings_server_idx')) {
            continue;
          }
          if (version < 2 && name == 'outbox_commands_well_idx') continue;
          var sql = item['sql'] as String;
          if (name == 'outbox_commands') {
            for (final col in projections) {
              sql = sql.replaceAll(
                RegExp(',\\s*$col\\s+text', caseSensitive: false),
                '',
              );
            }
            if (version < 5) {
              sql = sql.replaceAll(
                RegExp(r'next_attempt_at\s+text,', caseSensitive: false),
                '',
              );
            }
            if (version < 2) {
              sql = sql.replaceAll(
                RegExp(
                  r"prerequisites\s+text not null default '\[\]',",
                  caseSensitive: false,
                ),
                '',
              );
              sql = sql.replaceAll(
                RegExp(
                  r"local_context\s+text not null default '\{\}',",
                  caseSensitive: false,
                ),
                '',
              );
            }
          }
          if (name == 'local_booking_requests') {
            if (version < 7) {
              sql = sql.replaceAll(
                RegExp(
                  r',?\s*replaces_request_id text,?',
                  caseSensitive: false,
                ),
                ',',
              );
              sql = sql.replaceAll(
                RegExp(
                  r',?\s*superseded_by_request_id text',
                  caseSensitive: false,
                ),
                '',
              );
            }
            if (version < 6) {
              sql = sql.replaceAll(
                RegExp(
                  r',?\s*dispatch_registered integer not null default 0',
                  caseSensitive: false,
                ),
                '',
              );
            }
          }
          if (version < 6 && name == 'booking_requests_registration_idx') {
            continue;
          }
          if (version < 7 && name == 'booking_requests_current_day_idx') {
            continue;
          }
          if (name == 'notification_events') {
            sql = sql.replaceAll(RegExp(r'route_day text,?\s*'), '');
            if (version < 10) {
              sql =
                  "${sql.substring(0, sql.indexOf('due_at integer'))}unique(account_id,event_key))";
            }
          }
          if (version < 10 && name.startsWith('notification_schedule_')) {
            continue;
          }
          if (version == 9 && name == 'notification_pending_idx') sql = "create index notification_pending_idx on notification_events(account_id,local_id) where state in ('pending','presenting')";
          await db.execute(sql);
        }
      },
    ),
  );
  await db.close();
}

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late DatabaseFactory factory;
  late SqliteOutboxStore store;
  late List<String> statements;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('no_json_');
    statements = [];
    factory = noJsonSqliteFactory(databaseFactoryFfi, onSql: statements.add);
    store = SqliteOutboxStore(
      databasePath: '${dir.path}/db',
      sqfliteFactory: factory,
    );
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });
  Future<List<Map<String, Object?>>> schema() async {
    await store.initialize();
    return store.notificationEvents.db.rawQuery(
      "select type,name,sql from sqlite_master where sql is not null and name not like 'sqlite_%' order by case type when 'table' then 0 else 1 end,rowid",
    );
  }

  test(
    'A fresh schema 11 initializes without optional SQLite JSON SQL',
    () async {
      await store.initialize();
      final db = store.notificationEvents.db;
      expect(await db.getVersion(), 11);
      final cols = await db.rawQuery('pragma table_info(outbox_commands)');
      expect(cols.map((r) => r['name']), containsAll(projections));
      expect(
        (await db.rawQuery('pragma table_info(notification_events)'))
            .map((r) => r['name']),
        contains('route_day'),
      );
    },
  );
  test('B migration 10 to 11 preserves exact durable data and backfills in bounded keyset pages', () async {
    final ddl = await schema();
    await legacySchema(factory, '${dir.path}/legacy', ddl, 10);
    var db = await factory.openDatabase('${dir.path}/legacy');
    for (var i = 0; i < 721; i++) {
      final type = i % 3 == 0
          ? CommandType.createFarm
          : i % 3 == 1
          ? CommandType.createBooking
          : CommandType.startAdhocSession;
      final payload = <String, Object?>{
        'p_well_id': 'w',
        if (type == CommandType.createFarm)
          'p_farmer_well_account_id': i.isEven
              ? 'farmer'
              : {r'$ref': 'pending-farmer', r'$kind': 'farmerWellAccount'},
        if (type == CommandType.createFarm) 'p_name': 'land $i',
        if (type == CommandType.createFarm)
          'p_distinguishing_label': 'label $i',
        if (type == CommandType.createBooking)
          'p_farmer_well_account_id': 'farmer',
        if (type == CommandType.createBooking)
          'p_farm_id': {r'$ref': 'farm-0', r'$kind': 'farm'},
      };
      await db.insert('outbox_commands', {
        'local_id': 'id-${i.toString().padLeft(4, '0')}',
        'command_id': 'cmd-$i',
        'command_type': type.storageValue,
        'account_id': 'a',
        'well_id': type == CommandType.startAdhocSession ? null : 'w',
        'aggregate_local_id': null,
        'sequence': i + 1,
        'occurred_at': now.toIso8601String(),
        'created_local_at': now.toIso8601String(),
        'payload': jsonEncode(payload),
        'prerequisites': '["original"]',
        'local_context': '{ "display": "original" }',
        'status': i % 4 == 0
            ? 'review'
            : i % 4 == 1
            ? 'confirmed'
            : 'pending',
        'retry_count': 2,
        'last_error': 'previous',
        'last_attempt_at': now.toIso8601String(),
        'next_attempt_at': now
            .add(const Duration(minutes: 3))
            .toIso8601String(),
        'server_response': '{ "status": "unchanged" }',
      });
    }
    await db.insert('id_mappings', {
      'account_id': 'a',
      'local_id': 'pending-farmer',
      'entity_kind': 'farmerWellAccount',
      'server_id': 'farmer',
      'resolved_at': now.toIso8601String(),
      'matched_existing': 1,
    });
    await db.insert('id_mappings', {
      'account_id': 'a',
      'local_id': 'id-0002',
      'entity_kind': 'session',
      'server_id': 'legacy-session',
      'resolved_at': now.toIso8601String(),
    });
    final lifecycleJson = jsonEncode({
      'state': 'waiting_for_next_due',
      'chain_id': null,
      'automation_revision': 11,
      'next_booking_id': 'old-booking',
      'complete_command_id': 'old-completion',
      'actual_transition_at': now
          .subtract(const Duration(days: 1))
          .toIso8601String(),
    });
    for (final key in [
      'booking.lifecycle.v1.w',
      'booking.lifecycle.history.v1.w.original',
      'sequence_counter',
      'other',
    ]) {
      await db.insert('sync_meta', {
        'account_id': 'a',
        'key': key,
        'value': key.startsWith('booking.lifecycle.')
            ? lifecycleJson
            : key == 'sequence_counter'
            ? '721'
            : '{ "unchanged": true }',
      });
    }
    await db.insert('local_booking_requests', {
      'account_id': 'a',
      'well_id': 'w',
      'request_id': 'request',
      'command_id': 'booking-command',
      'created_local_at': now.toIso8601String(),
      'scheduled_day': '2026-10-17',
      'payload': jsonEncode({
        'p_well_id': 'w',
        'p_farmer_well_account_id': 'farmer',
        'p_farm_id': 'canonical-farm',
        'p_scheduled_start': now.toIso8601String(),
        'p_scheduled_end': now.add(const Duration(hours: 1)).toIso8601String(),
        'p_expected_energy_source': 'well_diesel',
      }),
      'display_context': '{}',
      'response': '{"status":"rejected"}',
      'dispatch_registered': 1,
    });
    for (var i = 0; i < 721; i++) {
      await db.insert('notification_events', {
        ...event('event-$i').toRow(),
        'due_at': now.add(const Duration(hours: 1)).microsecondsSinceEpoch,
        'schedule_state': const [
          'arm_pending',
          'arming',
          'armed',
          'cancel_pending',
          'cancelling',
          'cancelled',
          'elapsed',
        ][i % 7],
        'state': const [
          'pending',
          'presenting',
          'delivered',
          'suppressed',
        ][i % 4],
        'schedule_attempt_count': i % 4,
        'lease_until': now.toIso8601String(),
      });
    }
    final tables = [
      'outbox_commands',
      'id_mappings',
      'sync_meta',
      'local_booking_requests',
      'notification_events',
    ];
    final before = {
      for (final table in tables)
        table: await db.rawQuery('select * from $table order by rowid'),
    };
    await db.close();
    final migrated = SqliteOutboxStore(
      databasePath: '${dir.path}/legacy',
      sqfliteFactory: factory,
    );
    try {
      await migrated.initialize();
      db = migrated.notificationEvents.db;
      expect(await db.getVersion(), 11);
      expect(
        await migrated.sessionSnapshot(
          accountId: 'a',
          wellId: 'w',
          serverSessionId: 'legacy-session',
        ),
        isNotNull,
      );
      for (final table in tables) {
        final after = await db.rawQuery('select * from $table order by rowid');
        expect(after.length, before[table]!.length);
        for (var i = 0; i < after.length; i++) {
          for (final field in before[table]![i].keys) {
            if (table == 'outbox_commands' &&
                field == 'well_id' &&
                before[table]![i][field] == null) {
              expect(after[i][field], 'w');
            } else {
              expect(
                after[i][field],
                before[table]![i][field],
                reason: '$table $i $field',
              );
            }
          }
        }
      }
      expect(
        (await db.query(
          'outbox_commands',
          where: "command_type='createFarm' and farmer_ref_kind='local'",
        )).isNotEmpty,
        true,
      );
      expect(
        (await db.query(
          'outbox_commands',
          where: "command_type='createBooking'",
        )).every((r) => r['booking_farm_local_id'] == 'farm-0'),
        true,
      );
      expect(
        (await db.query('notification_events'))
            .every((r) => r['route_day'] == '2026-10-17'),
        true,
      );
      expect(
        statements.where((s) => s.toLowerCase().contains('limit 200')).length,
        greaterThan(3),
      );
      expect(
        statements.any(
          (s) => RegExp(r'\boffset\b', caseSensitive: false).hasMatch(s),
        ),
        false,
      );
      await migrated.close();
      await migrated.initialize();
      expect(
        await migrated.readBundle(
          'a',
          'booking.lifecycle.history.v1.w.original',
        ),
        lifecycleJson,
      );
    } finally {
      await migrated.close();
    }
  });
  test('C failed legacy fresh creation rolls back version and schema; fixed reopen succeeds', () async {
    final path = '${dir.path}/failed';
    await expectLater(
      factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 10,
          onCreate: (db, _) async {
            await db.execute(
              'create table outbox_commands(local_id text primary key,account_id text,well_id text,payload text,sequence integer,command_type text)',
            );
            // Deliberately reproduce the historical failure, never a supported query.
            await db.execute(
              "create index outbox_farm_selection_idx on outbox_commands(json_extract(payload,'\$.p_farmer_well_account_id'))",
            );
          },
        ),
      ),
      throwsUnsupportedError,
    );
    final remaining = await factory.openDatabase(path);
    expect(await remaining.getVersion(), 0);
    expect(
      await remaining.rawQuery(
        "select name from sqlite_master where name not like 'sqlite_%'",
      ),
      isEmpty,
    );
    await remaining.close();
    final recovered = SqliteOutboxStore(
      databasePath: path,
      sqfliteFactory: factory,
    );
    await recovered.initialize();
    expect(await recovered.notificationEvents.db.getVersion(), 11);
    await recovered.close();
  });
  for (final version in [1, 2, 3, 4, 5, 6, 7, 8, 9]) {
    test('upgrade $version to 11 never invokes a legacy JSON index', () async {
      await legacySchema(factory, '${dir.path}/old', await schema(), version);
      final upgraded = SqliteOutboxStore(
        databasePath: '${dir.path}/old',
        sqfliteFactory: factory,
      );
      try {
        await upgraded.initialize();
        expect(await upgraded.notificationEvents.db.getVersion(), 11);
      } finally {
        await upgraded.close();
      }
    });
  }
  test(
    'malformed legacy payload fails closed and rolls back the whole migration',
    () async {
      await legacySchema(factory, '${dir.path}/bad', await schema(), 10);
      var db = await factory.openDatabase('${dir.path}/bad');
      await db.insert('outbox_commands', {
        'local_id': 'bad',
        'command_id': 'bad',
        'command_type': 'createFarm',
        'account_id': 'a',
        'well_id': 'w',
        'sequence': 1,
        'occurred_at': now.toIso8601String(),
        'created_local_at': now.toIso8601String(),
        'payload': 'broken JSON',
        'status': 'pending',
      });
      await db.close();
      final bad = SqliteOutboxStore(
        databasePath: '${dir.path}/bad',
        sqfliteFactory: factory,
      );
      await expectLater(bad.initialize(), throwsFormatException);
      db = await factory.openDatabase('${dir.path}/bad');
      expect(await db.getVersion(), 10);
      expect(
        (await db.query('outbox_commands')).single['payload'],
        'broken JSON',
      );
      expect(
        (await db.rawQuery('pragma table_info(outbox_commands)'))
            .map((r) => r['name']),
        isNot(contains('farmer_ref_kind')),
      );
      await db.close();
      await bad.close();
    },
  );
  test(
    'malformed notification route rolls back projections and version together',
    () async {
      await legacySchema(factory, '${dir.path}/bad-route', await schema(), 10);
      var db = await factory.openDatabase('${dir.path}/bad-route');
      await db.insert('notification_events', {
        ...event('bad-route').toRow(),
        'route_payload_json': 'not JSON',
      });
      await db.close();
      final bad = SqliteOutboxStore(
        databasePath: '${dir.path}/bad-route',
        sqfliteFactory: factory,
      );
      await expectLater(bad.initialize(), throwsFormatException);
      db = await factory.openDatabase('${dir.path}/bad-route');
      expect(await db.getVersion(), 10);
      expect(
        (await db.query('notification_events')).single['route_payload_json'],
        'not JSON',
      );
      expect(
        (await db.rawQuery('pragma table_info(notification_events)'))
            .map((r) => r['name']),
        isNot(contains('route_day')),
      );
      expect(
        (await db.rawQuery('pragma table_info(outbox_commands)'))
            .map((r) => r['name']),
        isNot(contains('farmer_ref_kind')),
      );
      await db.close();
      await bad.close();
    },
  );
  test('D indexed farm filter precedes LIMIT; canonical and mapped local parents remain isolated', () async {
    await store.initialize();
    for (var i = 0; i < 350; i++) {
      await store.insert(
        command(
          'noise-$i',
          CommandType.createFarm,
          {'p_farmer_well_account_id': 'farmer', 'p_name': 'noise'},
          sequence: i + 10,
          account: i % 3 == 0 ? 'other' : 'a',
          well: i % 2 == 0 ? 'other' : 'w',
        ),
      );
    }
    await store.insert(
      command('hit', CommandType.createFarm, {
        'p_farmer_well_account_id': 'farmer',
        'p_name': 'target',
        'p_distinguishing_label': 'north',
      }, sequence: 1),
    );
    await store.insert(
      command('mapped-hit', CommandType.createFarm, {
        'p_farmer_well_account_id': {
          r'$ref': 'pending',
          r'$kind': 'farmerWellAccount',
        },
        'p_name': 'target',
      }, sequence: 2),
    );
    await store.putMapping(
      'a',
      IdMapping(
        localId: 'pending',
        kind: EntityKind.farmerWellAccount,
        serverId: 'farmer',
        resolvedAt: now,
      ),
    );
    final hits = await store.farmCommands(
      accountId: 'a',
      wellId: 'w',
      farmer: 'farmer',
      query: 'target',
      limit: 2,
    );
    expect(hits.map((r) => r.command.localId), ['mapped-hit', 'hit']);
    expect(
      (await store.farmCommands(
        accountId: 'a',
        wellId: 'w',
        farmer: 'farmer',
        query: 'north',
        limit: 1,
      )).single.command.localId,
      'hit',
    );
    expect(
      (await store.farmCommands(
        accountId: 'a',
        wellId: 'w',
        farmer: {r'$ref': 'pending', r'$kind': 'farmerWellAccount'},
        query: 'target',
      )).single.command.localId,
      'mapped-hit',
    );
    expect(
      await store.farmCommands(
        accountId: 'other',
        wellId: 'w',
        farmer: 'farmer',
        query: 'target',
      ),
      isEmpty,
    );
    expect(
      await store.farmCommands(
        accountId: 'a',
        wellId: 'other',
        farmer: 'farmer',
        query: 'target',
      ),
      isEmpty,
    );
    final plan = await store.notificationEvents.db.rawQuery(
      'explain query plan ${SqliteOutboxStore.farmSelectionSql}',
      [
        'server',
        'farmer',
        'a',
        'farmer',
        'server',
        'a',
        'w',
        'target',
        'target',
        'target',
        2,
      ],
    );
    final details = plan.map((r) => r['detail']).join(' ');
    expect(details, contains('outbox_farm_selection_idx'));
    expect(details, contains('farm_parent_mapping_idx'));
    expect(details, contains('farmer_ref_kind=? AND farmer_ref_id=?'));
    expect(details, isNot(contains('SCAN c')));
  });
  test(
    'E F booking local farm readiness and next wake happen in SQL before LIMIT',
    () async {
      await store.initialize();
      for (var i = 0; i < 70; i++) {
        final well = 'blocked-$i';
        await store.insert(
          command('parent-$i', CommandType.createFarm, {
            'p_farmer_well_account_id': 'farmer',
            'p_name': 'farm',
          }, well: well),
        );
        await store.insert(
          command(
            'booking-$i',
            CommandType.createBooking,
            {
              'p_well_id': well,
              'p_farmer_well_account_id': 'farmer',
              'p_farm_id': {r'$ref': 'parent-$i', r'$kind': 'farm'},
            },
            well: well,
            sequence: i + 1,
          ),
        );
      }
      await store.insert(
        command('ready', CommandType.createBooking, {
          'p_well_id': 'w',
          'p_farmer_well_account_id': 'farmer',
          'p_farm_id': 'server-farm',
        }, sequence: 1000),
      );
      expect(
        (await store.bookingCreatesReady(
          'a',
          now: now,
          limit: 1,
        )).single.localId,
        'ready',
      );
      expect(await store.bookingCreatesReady('other', now: now), isEmpty);
      expect(
        await store.bookingCreateNextWake(
          'a',
          now: now,
          staleClaimTimeout: const Duration(minutes: 5),
        ),
        now,
      );
      await store.putMapping(
        'a',
        IdMapping(
          localId: 'parent-0',
          kind: EntityKind.farm,
          serverId: 'canonical',
          resolvedAt: now,
        ),
      );
      expect(
        (await store.bookingCreatesReady(
          'a',
          now: now,
          limit: 1,
        )).single.localId,
        'booking-0',
      );
      final plan = await store.notificationEvents.db.rawQuery(
        'explain query plan ${SqliteOutboxStore.bookingReadySql}',
        ['a', now.toIso8601String(), now.toIso8601String(), 1],
      );
      expect(
        plan.map((r) => r['detail']).join(' '),
        contains('outbox_booking_dispatch_idx'),
      );
    },
  );
  test(
    'G session snapshot uses explicit well column and survives reopen',
    () async {
      await store.initialize();
      await store.insert(
        command('session', CommandType.startAdhocSession, {
          'p_well_id': 'w',
        }, well: null),
      );
      expect(
        await store.sessionSnapshot(
          accountId: 'a',
          wellId: 'w',
          localSessionId: 'session',
        ),
        isNotNull,
      );
      expect(
        await store.sessionSnapshot(
          accountId: 'a',
          wellId: 'other',
          localSessionId: 'session',
        ),
        isNull,
      );
      expect(
        await store.sessionSnapshot(
          accountId: 'other',
          wellId: 'w',
          localSessionId: 'session',
        ),
        isNull,
      );
      await store.close();
      await store.initialize();
      expect(
        await store.sessionSnapshot(
          accountId: 'a',
          wellId: 'w',
          localSessionId: 'session',
        ),
        isNotNull,
      );
    },
  );
  test('H reconcile route/day, membership beyond 20, scoped cleanup, rollback and query plan', () async {
    await store.initialize();
    final notifications = store.notificationEvents;
    final due = now.add(const Duration(hours: 1));
    final keys = <String>{};
    for (var i = 0; i < 53; i++) {
      keys.add('eligible-$i');
      await notifications.saveSchedule(event('eligible-$i'), due, now);
    }
    await notifications.saveSchedule(event('obsolete'), due, now);
    await notifications.saveSchedule(
      event('other-day', day: '2026-10-18'),
      due,
      now,
    );
    await notifications.saveSchedule(
      event('other-account', account: 'other'),
      due,
      now,
    );
    await notifications.saveSchedule(
      event('other-well', well: 'other'),
      due,
      now,
    );
    await notifications.insertEvent(event('immediate'));
    await notifications.reconcileSchedules(
      'a',
      'w',
      'booking',
      [],
      keys,
      now,
      routeDay: '2026-10-17',
    );
    final rows = await notifications.db.query('notification_events');
    expect(
      rows
          .where((r) => (r['event_key'] as String).startsWith('eligible'))
          .every((r) => r['schedule_state'] == 'arm_pending'),
      true,
    );
    expect(
      rows.singleWhere((r) => r['event_key'] == 'obsolete')['schedule_state'],
      'cancel_pending',
    );
    expect(
      rows
          .where((r) => (r['event_key'] as String).startsWith('other-'))
          .every((r) => r['schedule_state'] == 'arm_pending'),
      true,
    );
    expect(
      rows.singleWhere((r) => r['event_key'] == 'immediate')['route_day'],
      '2026-10-17',
    );
    expect(
      await notifications.db.query('notification_reconcile_keys'),
      isEmpty,
    );
    var checks = 0;
    await expectLater(
      notifications.reconcileSchedules(
        'a',
        'w',
        'booking',
        [],
        {},
        now,
        routeDay: '2026-10-17',
        isCurrent: () => ++checks < 2,
      ),
      throwsStateError,
    );
    expect(
      await notifications.db.query('notification_reconcile_keys'),
      isEmpty,
    );
    expect(
      (await notifications.db.query(
        'notification_events',
        where: "event_key='eligible-0'",
      )).single['schedule_state'],
      'arm_pending',
    );
    final plan = await notifications.db.rawQuery(
      'explain query plan ${SqliteNotificationEventStore.reconciliationSql(routeDay: '2026-10-17')}',
      [
        'a',
        'w',
        'booking',
        '2026-10-17',
        '2026-10-17',
        now.microsecondsSinceEpoch,
      ],
    );
    final details = plan.map((r) => r['detail']).join(' ');
    expect(details, contains('notification_schedule_scope_idx'));
    expect(details, contains('sqlite_autoindex_notification_reconcile_keys_1'));
    expect(details, isNot(contains('SCAN n')));
  });
  test(
    'harness rejects generated executor, transaction, callback and batch SQL',
    () async {
      await store.initialize();
      final db = store.notificationEvents.db;
      await expectLater(
        db.rawQuery("select json_object('x',1)"),
        throwsUnsupportedError,
      );
      await expectLater(
        db.query('outbox_commands', columns: ["json_type(payload)"]),
        throwsUnsupportedError,
      );
      await expectLater(
        db.execute("select json_set('{}','\$.x',1)"),
        throwsUnsupportedError,
      );
      await expectLater(
        db.transaction((tx) => tx.rawQuery("select json_each('[]')")),
        throwsUnsupportedError,
      );
      final batch = db.batch();
      batch.rawQuery("select '{}' ->> 'x'");
      await expectLater(batch.commit(), throwsUnsupportedError);
      await db.execute('select ?', [
        "json_extract(payload,'x')",
      ]); // Data is not SQL.
    },
  );
  test('static gate forbids optional JSON SQL in every production Dart file', () {
    final forbidden = RegExp(
      r'\bjson(?:b)?(?:_[a-z_]+)?\s*\(|->',
      caseSensitive: false,
    );
    for (final file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      // JSON SQL identifiers are distinctive; ignore comments, but scan all
      // runtime strings (including assembled fragments), not a file allowlist.
      final source = file.readAsStringSync().replaceAll(
        RegExp(r'/\*[\s\S]*?\*/|//[^\n]*'),
        '',
      );
      expect(forbidden.hasMatch(source), false, reason: file.path);
    }
  });
}

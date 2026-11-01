/// تنفيذ الطابور على SQLite — التخزين الدائم الفعلي على الجهاز.
///
/// هذا هو ما يجعل «العملية لا تُفقد» صحيحًا حرفيًا: الأمر يُكتب على
/// القرص قبل أن يرى المستخدم أي تأكيد، فيبقى بعد إغلاق التطبيق وبعد
/// إعادة تشغيل الهاتف.
///
/// ثابتان مفروضان في المخطط نفسه لا في الكود:
///
/// 1. `command_id TEXT NOT NULL UNIQUE` — لا يمكن لصفّين أن يحملا نفس
///    معرّف العملية، والعمود لا يظهر في أي `UPDATE` في هذا الملف.
/// 2. الحجز `UPDATE ... WHERE local_id = ? AND status = 'pending'`
///    ويُعتمد على عدد الصفوف المتأثرة. آمن بين حلقتين متزامنتين، وهو
///    ما تحتاجه القاعدة «المزامنة اليدوية لا تكرّر عمل العامل
///    التلقائي» (القسم 35).
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../booking/local_booking_request.dart';
import '../booking/booking_reactivity.dart';
import '../notifications/app_notification_event.dart';
import '../notifications/booking_notification_event_factory.dart';
import '../notifications/notification_event_store.dart';
import 'command_envelope.dart';
import 'command_type.dart';
import 'outbox_database.dart';
import 'outbox_store.dart';
import 'sync_status.dart';

class SqliteOutboxStore implements OutboxStore, AtomicLocalRecordStore, BookingDispatchStore, FarmSelectionStore {
  SqliteOutboxStore({
    this.databasePath,
    this.singleInstance = true,
    DatabaseFactory? sqfliteFactory,
  }) : _factory = sqfliteFactory;

  /// عند غيابه يُستخدم مسار الطابور الموحد للمقدمة والعامل الخلفي.
  /// `inMemoryDatabasePath` مسموح في الاختبار.
  final String? databasePath;
  final bool singleInstance;

  final DatabaseFactory? _factory;

  static const int schemaVersion = 11;
  static const String commandsTable = 'outbox_commands';
  static const String mappingsTable = 'id_mappings';
  static const String metaTable = 'sync_meta';
  static const String _sequenceKey = 'sequence_counter';
  static const String _lastSyncKey = 'last_successful_sync_at';

  SqliteNotificationEventStore get notificationEvents => SqliteNotificationEventStore(_db);

  Database? _database;
  Future<void>? _initFuture;

  bool get isOpen => _database != null && _database!.isOpen;

  Database get _db {
    final database = _database;

    if (database == null || !database.isOpen) {
      throw StateError('نادِ initialize() قبل استخدام المخزن');
    }

    return database;
  }

  @override
  Future<void> initialize() async {
    final db = _database;
    if (db != null && db.isOpen) {
      return;
    }

    final activeInit = _initFuture;
    if (activeInit != null) {
      return activeInit;
    }

    final initFuture = _doInitialize();
    _initFuture = initFuture;
    try {
      await initFuture;
    } finally {
      if (identical(_initFuture, initFuture)) {
        _initFuture = null;
      }
    }
  }

  Future<void> _doInitialize() async {
    final db = _database;
    if (db != null && db.isOpen) {
      return;
    }

    final path = databasePath ?? await resolveOutboxDatabasePath();
    _database = await (_factory ?? databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        singleInstance: singleInstance,
        onConfigure: (db) => db.execute('pragma foreign_keys = on'),
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              "alter table $commandsTable add column prerequisites text not null default '[]'",
            );
            await db.execute(
              "alter table $commandsTable add column local_context text not null default '{}'",
            );
            await db.execute(
              'create index ${commandsTable}_well_idx on $commandsTable (account_id, well_id, sequence)',
            );
          }
          if (oldVersion < 3) await _createSessionIndexes(db);
          if (oldVersion < 4) await _createBookingRequests(db);
          if (oldVersion < 5) {
            await db.execute(
              'alter table $commandsTable add column next_attempt_at text',
            );
            await _createBookingDispatchIndexes(db);
          }
          if (oldVersion < 6) await _createBookingLinkage(db);
          if (oldVersion < 7) await _createBookingReplacement(db);
          if (oldVersion < 9) {
            await SqliteNotificationEventStore.createSchema(db);
          } else if (oldVersion < 10) {
            await SqliteNotificationEventStore.upgradeFrom9(db);
          }
          await _upgradeTo11(db);
        },
        onCreate: (db, version) async {
          await SqliteNotificationEventStore.createSchema(db);
          await _createBookingRequests(db);
          await _createBookingLinkage(db);
          await _createBookingReplacement(db);
          await db.execute('''
            create table $commandsTable (
              local_id           text primary key,
              command_id         text not null unique,
              command_type       text not null,
              account_id         text not null,
              well_id            text,
              aggregate_local_id text,
              sequence           integer not null,
              occurred_at        text not null,
              created_local_at   text not null,
              payload            text not null,
              prerequisites      text not null default '[]',
              local_context      text not null default '{}',
              status             text not null,
              retry_count        integer not null default 0,
              last_error         text,
              last_attempt_at    text,
              next_attempt_at    text,
              server_response    text,
              farmer_ref_kind text,
              farmer_ref_id text,
              farm_name text,
              farm_distinguishing_label text,
              booking_farm_local_id text
            )
          ''');

          await db.execute('''
            create index ${commandsTable}_dispatch_idx
              on $commandsTable (account_id, status, sequence)
          ''');

          await db.execute(
            'create index ${commandsTable}_well_idx on $commandsTable (account_id, well_id, sequence)',
          );

          await db.execute('''
            create table $mappingsTable (
              account_id       text not null,
              local_id         text not null,
              entity_kind      text not null,
              server_id        text not null,
              resolved_at      text not null,
              matched_existing integer not null default 0,
              primary key (account_id, local_id, entity_kind)
            )
          ''');

          await _createSessionIndexes(db);
          await _createBookingDispatchIndexes(db);
          await _createFarmIndexes(db);
          await db.execute('''
            create table $metaTable (
              account_id text not null,
              key        text not null,
              value      text not null,
              primary key (account_id, key)
            )
          ''');
        },
      ),
    );
  }

  static const migrationPageSize = 200;

  /// Runs inside sqflite's version-change transaction. Payloads are never rewritten.
  static Future<void> _upgradeTo11(DatabaseExecutor db) async {
    await db.execute('drop index if exists outbox_farm_selection_idx');
    final columns = (await db.rawQuery('pragma table_info(outbox_commands)'))
        .map((row) => row['name'])
        .toSet();
    for (final name in const [
      'farmer_ref_kind',
      'farmer_ref_id',
      'farm_name',
      'farm_distinguishing_label',
      'booking_farm_local_id',
    ]) {
      if (!columns.contains(name)) {
        await db.execute('alter table outbox_commands add column $name text');
      }
    }
    // One-time migration only: keyset traversal of relevant rows, never OFFSET.
    // The temporary index bounds each command type traversal, including old files.
    await db.execute(
      'create index outbox_projection_backfill_idx on outbox_commands(command_type,local_id)',
    );
    for (final type in CommandType.values.where(
      (type) => type.scope == CommandScope.well,
    )) {
      String? cursor;
      while (true) {
        final projected =
            type == CommandType.createFarm || type == CommandType.createBooking;
        final rows = await db.query(
          commandsTable,
          columns: ['local_id', 'payload', 'well_id'],
          where:
              'command_type=? ${projected ? '' : 'and well_id is null'} ${cursor == null ? '' : 'and local_id>?'}',
          whereArgs: [type.storageValue, ?cursor],
          orderBy: 'local_id',
          limit: migrationPageSize,
        );
        if (rows.isEmpty) break;
        for (final row in rows) {
          final payload =
              jsonDecode(row['payload'] as String) as Map<String, dynamic>;
          final values = <String, Object?>{
            if (projected) ..._projections(type.storageValue, payload),
            if (row['well_id'] == null && payload['p_well_id'] != null)
              'well_id': payload['p_well_id'] as String,
          };
          if (values.isNotEmpty) {
            await db.update(
              commandsTable,
              values,
              where: 'local_id=?',
              whereArgs: [row['local_id']],
            );
          }
        }
        cursor = rows.last['local_id'] as String;
      }
    }
    await db.execute('drop index outbox_projection_backfill_idx');
    await SqliteNotificationEventStore.upgradeTo11(db);
    await _createFarmIndexes(db);
  }

  /// Indexed projections only; the original envelope remains the audit truth.
  static Map<String, Object?> _projections(
    String type,
    Map<String, dynamic> payload,
  ) {
    final values = <String, Object?>{
      'farmer_ref_kind': null,
      'farmer_ref_id': null,
      'farm_name': null,
      'farm_distinguishing_label': null,
      'booking_farm_local_id': null,
    };
    if (type == CommandType.createFarm.storageValue) {
      final farmer = payload['p_farmer_well_account_id'];
      if (farmer is String) {
        values['farmer_ref_kind'] = 'server';
        values['farmer_ref_id'] = farmer;
      } else if (farmer != null) {
        final ref = farmer as Map;
        if (ref[r'$kind'] != 'farmerWellAccount' ||
            ref[r'$ref'] is! String ||
            (ref[r'$ref'] as String).isEmpty) {
          throw const FormatException('Invalid farmer reference projection');
        }
        values['farmer_ref_kind'] = 'local';
        values['farmer_ref_id'] = ref[r'$ref'];
      }
      values['farm_name'] = payload['p_name'] as String?;
      values['farm_distinguishing_label'] =
          payload['p_distinguishing_label'] as String?;
    } else if (type == CommandType.createBooking.storageValue) {
      final farm = payload['p_farm_id'];
      if (farm != null && farm is! String) {
        final ref = farm as Map;
        if (ref[r'$kind'] != 'farm' ||
            ref[r'$ref'] is! String ||
            (ref[r'$ref'] as String).isEmpty) {
          throw const FormatException('Invalid farm reference projection');
        }
        values['booking_farm_local_id'] = ref[r'$ref'];
      }
    }
    return values;
  }

  static Future<void> _createBookingDispatchIndexes(DatabaseExecutor db) async {
    await db.execute(
      "create index outbox_booking_dispatch_idx on $commandsTable(account_id, status, sequence, local_id) where command_type = 'createBooking'",
    );
    await db.execute(
      "create index outbox_booking_well_idx on $commandsTable(account_id, well_id, status, sequence) where command_type = 'createBooking'",
    );
    await db.execute(
      "create index outbox_booking_due_idx on $commandsTable(account_id, status, next_attempt_at) where command_type = 'createBooking'",
    );
    await db.execute(
      "create index outbox_booking_stale_idx on $commandsTable(account_id, status, last_attempt_at) where command_type = 'createBooking'",
    );
  }

  /// الاستعلام نفسه متاح لإثبات خطة التنفيذ؛ لا يقرأ أوامر العائلات الأخرى.

  static Future<void> _createFarmIndexes(DatabaseExecutor db) async {
    await db.execute(
      "create index if not exists outbox_farm_selection_idx on outbox_commands(account_id, well_id, farmer_ref_kind, farmer_ref_id, sequence, local_id) where command_type = 'createFarm'",
    );
    await db.execute(
      "create index if not exists farm_parent_mapping_idx on id_mappings(account_id,server_id,local_id) where entity_kind='farmerWellAccount'",
    );
  }

  static const farmSelectionSql = r"""
    with farmer_refs(kind,id) as (
      select ?,? union all
      select 'local',pm.local_id from id_mappings pm indexed by farm_parent_mapping_idx
      where pm.account_id=? and pm.entity_kind='farmerWellAccount' and pm.server_id=? and ?='server'
    )
    select c.*, fm.server_id as farm_server_id
    from farmer_refs r cross join outbox_commands c indexed by outbox_farm_selection_idx
    left join id_mappings fm on fm.account_id=c.account_id and fm.local_id=c.local_id and fm.entity_kind='farm'
    where c.farmer_ref_kind=r.kind and c.farmer_ref_id=r.id
      and c.command_type='createFarm' and c.account_id=? and c.well_id=?
      and c.status!='review'
      and (?='' or instr(c.farm_name,?)>0 or instr(coalesce(c.farm_distinguishing_label,''),?)>0)
    order by c.sequence desc, c.local_id limit ?
  """;
  @override
  Future<List<FarmCommandRow>> farmCommands({
    required String accountId,
    required String wellId,
    required Object farmer,
    int limit = 50,
    String query = '',
  }) async {
    if (limit < 1 || limit > 100) throw ArgumentError('حد الأراضي غير صالح');
    await initialize();
    final kind = farmer is String ? 'server' : 'local';
    final value = farmer is String
        ? farmer
        : (farmer as Map)[r'$ref'] as String;
    final rows = await _db.rawQuery(farmSelectionSql, [
      kind,
      value,
      accountId,
      value,
      kind,
      accountId,
      wellId,
      query.trim(),
      query.trim(),
      query.trim(),
      limit,
    ]);
    return rows
        .map(
          (r) => FarmCommandRow(
            command: _fromRow(r),
            serverId: r['farm_server_id'] as String?,
            farmerId: farmer is String
                ? farmer
                : farmer is Map
                ? farmer[r'$ref'] as String?
                : null,
          ),
        )
        .toList();
  }

  static const bookingFarmReadySql = r"""
    (c.booking_farm_local_id is null
     or exists(select 1 from id_mappings m where m.account_id=c.account_id and m.local_id=c.booking_farm_local_id and m.entity_kind='farm')
     or not exists(select 1 from outbox_commands p where p.account_id=c.account_id and p.local_id=c.booking_farm_local_id and p.status!='review'))
  """;
  static const bookingReadySql =
      """
    select c.* from outbox_commands c indexed by outbox_booking_dispatch_idx
    where c.account_id = ? and c.command_type = 'createBooking' and c.status = 'pending'
      and $bookingFarmReadySql
      and (c.next_attempt_at is null or c.next_attempt_at <= ?)
      and not exists (
        select 1 from outbox_commands earlier indexed by outbox_booking_well_idx
        where earlier.account_id = c.account_id and earlier.command_type = 'createBooking'
          and earlier.well_id = c.well_id and earlier.sequence < c.sequence
          and (earlier.status = 'dispatching' or
            (earlier.status = 'pending' and earlier.next_attempt_at > ?))
      )
    order by c.sequence, c.local_id limit ?
  """;

  @override
  Future<List<CommandEnvelope>> pendingLegacyCommands(String accountId) async {
    final rows = await _db.query(
      commandsTable,
      where:
          "account_id = ? and status != ? and command_type != 'createBooking'",
      whereArgs: [accountId, CommandStatus.confirmed.storageValue],
      orderBy: 'sequence asc',
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<List<CommandEnvelope>> bookingCreatesReady(
    String accountId, {
    required DateTime now,
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 20) throw ArgumentError.value(limit, 'limit');
    await _recoverBookingRegistrations(accountId);
    final rows = await _db.rawQuery(bookingReadySql, [
      accountId,
      _encodeTime(now),
      _encodeTime(now),
      limit,
    ]);
    return rows.map(_fromRow).toList(growable: false);
  }

  @override
  Future<List<CommandEnvelope>> bookingCreatesStale(
    String accountId, {
    required DateTime before,
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 20) throw ArgumentError.value(limit, 'limit');
    final rows = await _db.query(
      commandsTable,
      where: "account_id = ? and command_type = 'createBooking' and status = 'dispatching' and (last_attempt_at is null or last_attempt_at <= ?)",
      whereArgs: [accountId, _encodeTime(before)],
      orderBy: 'last_attempt_at, local_id',
      limit: limit,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  @override
  Future<bool> claimBookingCreate(
    String accountId,
    String localId, {
    required DateTime attemptedAt,
  }) async {
    // جملة ذرية واحدة بين اتصالات SQLite: لا بئران في المسار نفسه، ولا أكثر من ثلاث آبار.
    final changed = await _db.rawUpdate(
      """
      update outbox_commands set status = 'dispatching', last_attempt_at = ?
      where account_id = ? and local_id = ? and command_type = 'createBooking' and status = 'pending'
        and well_id is not null and well_id != ''
        and (next_attempt_at is null or next_attempt_at <= ?)
        and not exists (
          select 1 from outbox_commands e indexed by outbox_booking_well_idx
          where e.account_id = outbox_commands.account_id and e.command_type = 'createBooking'
            and e.well_id = outbox_commands.well_id
            and (e.status = 'dispatching' or (e.status = 'pending' and e.sequence < outbox_commands.sequence))
        )
        and (select count(*) from outbox_commands a indexed by outbox_booking_dispatch_idx
          where a.account_id = ? and a.command_type = 'createBooking' and a.status = 'dispatching') < 3
    """,
      [
        _encodeTime(attemptedAt),
        accountId,
        localId,
        _encodeTime(attemptedAt),
        accountId,
      ],
    );
    return changed == 1;
  }

  @override
  Future<bool> finishBookingCreate(
    String accountId,
    String localId, {
    required DateTime claimedAt,
    required CommandStatus status,
    DateTime? nextAttemptAt,
    String? error,
    Map<String, Object?>? response,
    String? entityId,
  }) async {
    if (status == CommandStatus.dispatching) {
      throw ArgumentError('نتيجة غير نهائية للمحاولة');
    }
    // المعاملة لا تحتوي شبكة. انشغال اتصال آخر يعاد محليًا بعد تحرير الحدث، بلا قفل عام.
    for (var attempt = 0; ; attempt++) {
      try {
        AppNotificationEvent? committedEvent;
        final applied = await _db.transaction((txn) async {
          final changed = await txn.rawUpdate(
            """
            update outbox_commands set status = ?, next_attempt_at = ?, last_error = ?,
              retry_count = retry_count + ?, server_response = ?
            where account_id = ? and local_id = ? and command_type = 'createBooking'
              and status = 'dispatching' and last_attempt_at = ?
          """,
            [
              status.storageValue,
              nextAttemptAt == null ? null : _encodeTime(nextAttemptAt),
              error,
              status == CommandStatus.pending ? 1 : 0,
              response == null ? null : jsonEncode(response),
              accountId,
              localId,
              _encodeTime(claimedAt),
            ],
          );
          if (changed != 1) return false;
          if (status == CommandStatus.confirmed ||
              (status == CommandStatus.review &&
                  const {
                    'conflict',
                    'rejected',
                  }.contains(response?['status']))) {
            await txn.rawUpdate(
              """
              update local_booking_requests set response = ?
              where account_id = ? and command_id = (
                select command_id from outbox_commands where account_id = ? and local_id = ?
              ) and response is null
            """,
              [jsonEncode(response), accountId, accountId, localId],
            );
          }

          if (status == CommandStatus.confirmed && entityId != null) {
            await txn.insert(mappingsTable, {
              'account_id': accountId,
              'local_id': localId,
              'entity_kind': EntityKind.booking.storageValue,
              'server_id': entityId,
              'resolved_at': _encodeTime(claimedAt),
              'matched_existing': 0,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
          if (status == CommandStatus.confirmed ||
              status == CommandStatus.review) {
            final commands = await txn.query(
              commandsTable,
              where: 'account_id=? and local_id=?',
              whereArgs: [accountId, localId],
              limit: 1,
            );
            final command = commands.single;
            final requests = await txn.query(
              'local_booking_requests',
              where: 'account_id=? and command_id=?',
              whereArgs: [accountId, command['command_id']],
              limit: 1,
            );
            final request = requests.isEmpty ? null : requests.single;
            final scheduled =
                request?['scheduled_day'] as String? ??
                DateTime.parse(
                      (jsonDecode(command['payload'] as String)
                              as Map)['p_scheduled_start']
                          as String,
                    )
                    .toUtc()
                    .add(const Duration(hours: 3))
                    .toIso8601String()
                    .substring(0, 10);
            final event = bookingNotificationEvent(
              accountId: accountId,
              wellId: command['well_id'] as String,
              commandId: command['command_id'] as String,
              requestId:
                  request?['request_id'] as String? ??
                  command['command_id'] as String,
              scheduledDay: scheduled,
              at: claimedAt,
              status: status,
              response: response,
              supersededBy: request?['superseded_by_request_id'] as String?,
            );
            if (event != null) {
              await SqliteNotificationEventStore.insertEventTx(
                txn,
                event.event,
                suppression: event.suppression,
              );
              committedEvent = event.event;
            }
          }
          return true;
        });
        final event = committedEvent;
        if (applied &&
            event != null &&
            status == CommandStatus.review &&
            !const {'conflict', 'rejected'}.contains(response?['status'])) {
          BookingReactivity.instance
              .scope(accountId, event.wellId!)
              .mutation(days: {event.routePayload['day'] as String});
        }
        return applied;
      } on DatabaseException catch (error) {
        if (attempt >= 9 || !error.toString().contains('database is locked')) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 5 * (attempt + 1)));
      }
    }
  }

  @override
  Future<DateTime?> bookingCreateNextWake(
    String accountId, {
    required DateTime now,
    required Duration staleClaimTimeout,
  }) async {
    final pending = await _db.rawQuery(
      "select c.next_attempt_at from outbox_commands c indexed by outbox_booking_due_idx where c.account_id=? and c.command_type='createBooking' and c.status='pending' and $bookingFarmReadySql order by c.next_attempt_at limit 1",
      [accountId],
    );
    final active = await _db.query(
      commandsTable,
      columns: ['last_attempt_at'],
      where: "account_id = ? and command_type = 'createBooking' and status = 'dispatching'",
      whereArgs: [accountId],
      orderBy: 'last_attempt_at',
      limit: 1,
    );
    final unregistered = await _db.query(
      'local_booking_requests',
      columns: ['request_id'],
      where: 'account_id = ? and dispatch_registered = 0',
      whereArgs: [accountId],
      limit: 1,
    );
    DateTime? wake = unregistered.isEmpty ? null : now;
    if (pending.isNotEmpty) {
      final due = pending.single['next_attempt_at'] == null
          ? now
          : _decodeTime(pending.single['next_attempt_at'] as String);
      if (wake == null || due.isBefore(wake)) wake = due;
    }
    if (active.isNotEmpty) {
      final expiry = active.single['last_attempt_at'] == null
          ? now
          : _decodeTime(active.single['last_attempt_at'] as String)
                .add(staleClaimTimeout);
      if (wake == null || expiry.isBefore(wake)) wake = expiry;
    }
    return wake;
  }

  static Future<void> _createBookingRequests(DatabaseExecutor db) async {
    await db.execute('''
      create table local_booking_requests (
        account_id text not null,
        well_id text not null,
        request_id text not null,
        command_id text not null unique,
        created_local_at text not null,
        scheduled_day text not null,
        payload text not null,
        display_context text not null,
        response text,
        primary key (account_id, well_id, request_id)
      )
    ''');
    await db.execute(
      'create index booking_requests_day_idx on local_booking_requests (account_id, well_id, scheduled_day, request_id)',
    );
  }

  static Future<void> _createBookingLinkage(DatabaseExecutor db) async {
    await db.execute(
      'alter table local_booking_requests add column dispatch_registered integer not null default 0',
    );
    await db.execute(
      'create index booking_requests_registration_idx on local_booking_requests (account_id, dispatch_registered, created_local_at, request_id)',
    );
    // نتائج C1 السابقة محفوظة بالفعل ولا تُرسل مرة أخرى.
    await db.update('local_booking_requests', {
      'dispatch_registered': 1,
    }, where: 'response is not null');
  }

  static Future<void> _createBookingReplacement(DatabaseExecutor db) async {
    await db.execute(
      'alter table local_booking_requests add column replaces_request_id text',
    );
    await db.execute(
      'alter table local_booking_requests add column superseded_by_request_id text',
    );
    await db.execute(
      'create index booking_requests_current_day_idx on local_booking_requests (account_id, well_id, scheduled_day, request_id) where superseded_by_request_id is null',
    );
  }

  Future<void> _registerBooking(
    DatabaseExecutor txn,
    LocalBookingRequest request,
  ) async {
    final existing = await txn.query(
      commandsTable,
      columns: ['command_id'],
      where: 'command_id = ?',
      whereArgs: [request.commandId],
      limit: 1,
    );
    if (existing.isEmpty) {
      final sequenceRows = await txn.query(
        metaTable,
        columns: ['value'],
        where: 'account_id = ? and key = ?',
        whereArgs: [request.accountId, _sequenceKey],
        limit: 1,
      );
      final sequence =
          (sequenceRows.isEmpty
              ? 0
              : int.parse(sequenceRows.single['value'] as String)) +
          1;
      await txn.insert(metaTable, {
        'account_id': request.accountId,
        'key': _sequenceKey,
        'value': '$sequence',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      final envelope = CommandEnvelope(
        localId: request.commandId,
        commandId: request.commandId,
        type: CommandType.createBooking,
        accountId: request.accountId,
        wellId: request.wellId,
        sequence: sequence,
        occurredAt: request.createdLocalAt,
        createdLocalAt: request.createdLocalAt,
        payload: request.payload,
        localContext: {
          'scheduled_day': request.scheduledDay,
          'request_id': request.requestId,
        },
      );
      await txn.insert(commandsTable, {
        ..._toRow(envelope),
        'payload': request.payloadJson,
      });
    }
    await txn.update(
      'local_booking_requests',
      {'dispatch_registered': 1},
      where: 'account_id = ? and well_id = ? and request_id = ?',
      whereArgs: [request.accountId, request.wellId, request.requestId],
    );
  }

  Future<T> _bookingTransaction<T>(
    Future<T> Function(Transaction txn) action,
  ) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _db.transaction(action);
      } on DatabaseException catch (error) {
        if (attempt >= 9 || !error.toString().contains('database is locked')) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 5 * (attempt + 1)));
      }
    }
  }

  /// إصلاح محدود لطلبات C1 السابقة فقط؛ الكتابات الجديدة ذرية دائمًا.
  Future<void> _recoverBookingRegistrations(String accountId) async {
    await _bookingTransaction((txn) async {
      final rows = await txn.query(
        'local_booking_requests',
        where: 'account_id = ? and dispatch_registered = 0',
        whereArgs: [accountId],
        orderBy: 'created_local_at, request_id',
        limit: 20,
      );
      for (final row in rows) {
        await _registerBooking(txn, LocalBookingRequest.fromRow(row));
      }
    });
  }

  /// الطلب وأمره يُعتمدان معًا؛ أول كتابة لنفس هوية الطلب تفوز.
  Future<LocalBookingRequest> saveBookingRequest(
    LocalBookingRequest request,
  ) async {
    await initialize();
    return _bookingTransaction((txn) async {
      final raw = request.payload['p_farm_id'];
      if (raw is Map) {
        final rows = await txn.query(
          commandsTable,
          where: 'account_id=? and local_id=? and well_id=? and command_type=?',
          whereArgs: [
            request.accountId,
            raw[r'$ref'],
            request.wellId,
            'createFarm',
          ],
          limit: 1,
        );
        if (rows.isEmpty ||
            _fromRow(rows.single).payload['p_farmer_well_account_id'] !=
                request.payload['p_farmer_well_account_id'] ||
            _fromRow(rows.single).status == CommandStatus.review) {
          throw ArgumentError('اختر أرضًا محفوظة لهذا المزارع.');
        }
      }
      await txn.insert(
        'local_booking_requests',
        request.toRow(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      final rows = await txn.query(
        'local_booking_requests',
        where: 'account_id = ? and well_id = ? and request_id = ?',
        whereArgs: [request.accountId, request.wellId, request.requestId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('معرّف طلب مستخدم');
      final stored = LocalBookingRequest.fromRow(rows.single);
      if (stored.payloadJson != request.payloadJson) {
        throw StateError('محتوى الطلب المحفوظ لا يُستبدل');
      }
      if (stored.replacesRequestId != request.replacesRequestId ||
          request.supersededByRequestId != null) {
        throw StateError('علاقة الطلب المحفوظ لا تُستبدل');
      }
      final previousId = stored.replacesRequestId;
      if (previousId != null) {
        final previousRows = await txn.query(
          'local_booking_requests',
          where: 'account_id = ? and well_id = ? and request_id = ?',
          whereArgs: [stored.accountId, stored.wellId, previousId],
          limit: 1,
        );
        if (previousRows.isEmpty || previousId == stored.requestId) {
          throw StateError('الحجز المطلوب تعديله غير متاح');
        }
        final previous = LocalBookingRequest.fromRow(previousRows.single);
        if (!const {
              'conflict',
              'rejected',
            }.contains(previous.response?['status']) ||
            (previous.supersededByRequestId != null &&
                previous.supersededByRequestId != stored.requestId)) {
          throw StateError('تم تعديل هذا الحجز مسبقًا');
        }
        if (previous.response?['status'] == 'conflict' &&
            previous.payload['p_scheduled_start'] ==
                stored.payload['p_scheduled_start'] &&
            previous.payload['p_scheduled_end'] ==
                stored.payload['p_scheduled_end']) {
          throw ArgumentError('اختر موعدًا آخر للحجز.');
        }
        if (previous.supersededByRequestId == null) {
          final count = await txn.update(
            'local_booking_requests',
            {'superseded_by_request_id': stored.requestId},
            where: 'account_id = ? and well_id = ? and request_id = ? and superseded_by_request_id is null',
            whereArgs: [stored.accountId, stored.wellId, previousId],
          );
          if (count != 1) throw StateError('تم تعديل هذا الحجز مسبقًا');
          await txn.rawUpdate(
            """update notification_events set state='suppressed',
            suppressed_reason='superseded',suppressed_at=?,lease_until=null
            where account_id=? and event_key in (?,?,?) and state in ('pending','presenting')""",
            [
              _encodeTime(stored.createdLocalAt),
              stored.accountId,
              'booking-result/${previous.commandId}/time_unavailable',
              'booking-result/${previous.commandId}/rejected',
              'booking-result/${previous.commandId}/review_required',
            ],
          );
        }
      }
      if (rows.single['dispatch_registered'] == 0) {
        await _registerBooking(txn, stored);
      }
      return stored;
    });
  }

  Future<LocalBookingRequest?> bookingRequest(
    String accountId,
    String wellId,
    String requestId,
  ) async {
    await initialize();
    final rows = await _db.query(
      'local_booking_requests',
      columns: [
        '*',
        "(select count(*) from outbox_commands c where c.command_id=local_booking_requests.command_id and c.account_id=local_booking_requests.account_id and c.status='review' and local_booking_requests.response is null) as review_required",
      ],
      where: 'account_id = ? and well_id = ? and request_id = ?',
      whereArgs: [accountId, wellId, requestId],
      limit: 1,
    );
    return rows.isEmpty ? null : LocalBookingRequest.fromRow(rows.single);
  }

  Future<List<LocalBookingRequest>> bookingRequestsForDay(
    String accountId,
    String wellId,
    String day, {
    int limit = 50,
    String afterRequestId = '',
  }) async {
    if (limit < 1 || limit > 100) throw ArgumentError.value(limit, 'limit');
    await initialize();
    final rows = await _db.query(
      'local_booking_requests',
      columns: [
        '*',
        "(select count(*) from outbox_commands c where c.command_id=local_booking_requests.command_id and c.account_id=local_booking_requests.account_id and c.status='review' and local_booking_requests.response is null) as review_required",
      ],
      where: 'account_id = ? and well_id = ? and scheduled_day = ? and superseded_by_request_id is null and request_id > ?',
      whereArgs: [accountId, wellId, day, afterRequestId],
      orderBy: 'request_id',
      limit: limit,
    );
    return rows.map(LocalBookingRequest.fromRow).toList(growable: false);
  }

  /// يحفظ النتيجة فقط؛ لا يبدّل الطلب الأصلي أو توقيته أو هويته.
  static Future<void> _createSessionIndexes(DatabaseExecutor db) async {
    await db.execute(
      'create index if not exists ${commandsTable}_session_idx on $commandsTable (account_id, aggregate_local_id, sequence)',
    );
    await db.execute(
      'create index if not exists ${mappingsTable}_server_idx on $mappingsTable (account_id, entity_kind, server_id)',
    );
  }

  static String _paymentReadKey(String well, String session) =>
      'session.payment.read:${jsonEncode([well, session])}';

  @override
  Future<SessionOutboxSnapshot?> sessionSnapshot({
    required String accountId,
    required String wellId,
    String? localSessionId,
    String? serverSessionId,
  }) async {
    await initialize();
    if ((localSessionId == null) == (serverSessionId == null)) {
      throw ArgumentError('يلزم معرف جلسة واحد');
    }
    // قراءة متسقة للصفوف والإقرارات والقراءة الخادمية، بلا N+1.
    return _db.transaction((txn) async {
      final roots = await txn.rawQuery(
        'select c.*, m.server_id as mapped_server_id, m.resolved_at as mapped_at '
        'from $commandsTable c '
        '${localSessionId == null ? 'join' : 'left join'} $mappingsTable m '
        "on m.account_id = c.account_id and m.local_id = c.local_id and m.entity_kind = 'session' "
        'where c.account_id = ? and '
        '${localSessionId == null ? 'm.server_id = ?' : 'c.local_id = ?'} '
        "and c.well_id = ? limit 2",
        [accountId, localSessionId ?? serverSessionId, wellId],
      );
      if (roots.length != 1) return null;
      final root = _fromRow(roots.single);
      if (root.type != CommandType.startIrrigationSession &&
          root.type != CommandType.startAdhocSession &&
          root.type != CommandType.startBookingSession) {
        return null;
      }
      final events = await txn.rawQuery(
        'select c.*, m.server_id as mapped_server_id, m.resolved_at as mapped_at '
        'from $commandsTable c left join $mappingsTable m '
        "on m.account_id = c.account_id and m.local_id = c.local_id and m.entity_kind = 'payment' "
        'where c.account_id = ? and c.aggregate_local_id = ? '
        'and (c.well_id = ? or c.well_id is null) order by c.sequence',
        [accountId, root.localId, wellId],
      );
      final rows = [roots.single, ...events];
      final read = await txn.query(
        metaTable,
        columns: ['value'],
        where: 'account_id = ? and key = ?',
        whereArgs: [accountId, _paymentReadKey(wellId, root.localId)],
      );
      return SessionOutboxSnapshot(
        commands: [root, ...events.map(_fromRow)],
        mappings: [
          for (final row in rows)
            if (row['mapped_server_id'] != null)
              IdMapping(
                localId: row['local_id'] as String,
                kind: row['local_id'] == root.localId
                    ? EntityKind.session
                    : EntityKind.payment,
                serverId: row['mapped_server_id'] as String,
                resolvedAt: _decodeTime(row['mapped_at'] as String),
              ),
        ],
        paymentRead: read.isEmpty
            ? null
            : Map<String, Object?>.from(
                jsonDecode(read.single['value'] as String) as Map,
              ),
      );
    });
  }

  @override
  Future<void> saveSessionPaymentRead({
    required String accountId,
    required String wellId,
    required String localSessionId,
    required Map<String, Object?> value,
  }) async {
    await writeLocalValue(
      accountId,
      _paymentReadKey(wellId, localSessionId),
      jsonEncode(value),
    );
  }

  @override
  Future<CommandEnvelope> insertSessionPayment(CommandEnvelope command) async {
    if (command.type != CommandType.recordPayment ||
        command.aggregateLocalId == null ||
        command.wellId == null) {
      throw ArgumentError('دفعة جلسة مطلوبة');
    }
    await initialize();
    return _db.transaction((txn) async {
      final unresolved = await txn.rawQuery(
        'select c.local_id from $commandsTable c left join $mappingsTable m '
        "on m.account_id = c.account_id and m.local_id = c.local_id and m.entity_kind = 'payment' "
        'where c.account_id = ? and c.aggregate_local_id = ? and c.command_type = ? '
        "and (c.status != 'confirmed' or m.server_id is null) limit 1",
        [
          command.accountId,
          command.aggregateLocalId,
          CommandType.recordPayment.storageValue,
        ],
      );
      if (unresolved.isNotEmpty) {
        throw StateError('توجد دفعة محفوظة أو تحتاج مراجعة لهذه الجلسة');
      }
      await txn.insert(commandsTable, _toRow(command));
      return command;
    });
  }

  /// مساحة بيانات محلية مرتبطة بالحساب داخل ملف الطابور نفسه.
  Future<String?> readLocalValue(String accountId, String key) async {
    await initialize();
    final rows = await _db.query(
      metaTable,
      columns: ['value'],
      where: 'account_id = ? and key = ?',
      whereArgs: [accountId, key],
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  Future<Map<String, String>> readLocalValuesByKeys(
    String accountId,
    List<String> keys,
  ) async {
    if (keys.length > 20) throw ArgumentError('metadata_page_too_large');
    if (keys.isEmpty) return {};
    await initialize();
    final rows = await _db.rawQuery(
      'select key,value from $metaTable where account_id=? and key in (${List.filled(keys.length, '?').join(',')}) limit 20',
      [accountId, ...keys],
    );
    return {
      for (final row in rows) row['key'] as String: row['value'] as String,
    };
  }

  Future<void> deleteLocalValue(String accountId, String key) async {
    await initialize();
    await _db.delete(
      metaTable,
      where: 'account_id = ? and key = ?',
      whereArgs: [accountId, key],
    );
  }

  Future<void> writeLocalValue(
    String accountId,
    String key,
    String value,
  ) async {
    await initialize();
    await _db.insert(metaTable, {
      'account_id': accountId,
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String> writeLocalValueOnce(
    String accountId,
    String key,
    String value,
  ) async {
    await initialize();
    return _db.transaction((txn) async {
      await txn.insert(metaTable, {
        'account_id': accountId,
        'key': key,
        'value': value,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final rows = await txn.query(
        metaTable,
        columns: ['value'],
        where: 'account_id = ? and key = ?',
        whereArgs: [accountId, key],
      );
      return rows.single['value'] as String;
    });
  }

  /// يحفظ النية ودليلها معًا؛ إبطال دورة الشاشة يرد المعاملة كلها.
  Future<(String, String)> writeLocalPairOnce({
    required String accountId,
    required String primaryKey,
    required String primaryValue,
    required String secondaryKey,
    required String Function(String) secondaryValue,
    bool Function()? isCurrent,
  }) async {
    await initialize();
    return _db.transaction((txn) async {
      void guard() {
        if (isCurrent != null && !isCurrent()) {
          throw StateError('stale_runtime');
        }
      }

      guard();
      await txn.insert(metaTable, {
        'account_id': accountId,
        'key': primaryKey,
        'value': primaryValue,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final primary =
          (await txn.query(
                metaTable,
                columns: ['value'],
                where: 'account_id = ? and key = ?',
                whereArgs: [accountId, primaryKey],
              )).single['value']
              as String;
      guard();
      await txn.insert(metaTable, {
        'account_id': accountId,
        'key': secondaryKey,
        'value': secondaryValue(primary),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final secondary =
          (await txn.query(
                metaTable,
                columns: ['value'],
                where: 'account_id = ? and key = ?',
                whereArgs: [accountId, secondaryKey],
              )).single['value']
              as String;
      guard();
      return (primary, secondary);
    });
  }

  /// قراءة مفاتيح المجال المحلي فقط ضمن الحساب نفسه. تستخدم المصالحة
  /// مفاتيح دفتر الحجوزات ولا تخلطها بصفوف طابور الأوامر.
  Future<List<String>> readLocalValuesByPrefix(
    String accountId,
    String prefix,
  ) async {
    await initialize();
    final rows = await _db.query(
      metaTable,
      columns: ['value'],
      where: 'account_id = ? and key like ?',
      whereArgs: [accountId, '$prefix%'],
      orderBy: 'key asc',
    );
    return rows.map((row) => row['value'] as String).toList(growable: false);
  }

  @override
  Future<String?> readBundle(String accountId, String key) =>
      readLocalValue(accountId, key);

  @override
  Future<String> insertLocalRecordOnce({
    required String accountId,
    required String key,
    required String value,
  }) => _withExecutionContentionRetry(
    () => insertBundle(
      accountId: accountId,
      key: key,
      value: value,
      commands: const [],
    ),
  );

  @override
  Future<String> insertBundle({
    required String accountId,
    required String key,
    required String value,
    required List<CommandEnvelope> commands,
    Map<String, String> localValues = const {},
    bool Function()? isCurrent,
  }) async {
    await initialize();
    return _db.transaction((txn) async {
      final existing = await txn.query(
        metaTable,
        columns: ['value'],
        where: 'account_id = ? and key = ?',
        whereArgs: [accountId, key],
      );
      if (existing.isNotEmpty) return existing.single['value'] as String;
      if (isCurrent != null && !isCurrent()) throw StateError('stale_runtime');
      for (final command in commands) {
        if (command.accountId != accountId) {
          throw StateError('bundle_account_mismatch');
        }
        await txn.insert(commandsTable, _toRow(command));
      }
      await txn.insert(metaTable, {
        'account_id': accountId,
        'key': key,
        'value': value,
      });
      for (final entry in localValues.entries) {
        await txn.insert(metaTable, {
          'account_id': accountId,
          'key': entry.key,
          'value': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (isCurrent != null && !isCurrent()) throw StateError('stale_runtime');
      return value;
    });
  }

  @override
  Future<CommandEnvelope> insert(CommandEnvelope envelope) async {
    try {
      await _db.insert(commandsTable, _toRow(envelope));
    } on DatabaseException catch (error) {
      if (error.isUniqueConstraintError()) {
        throw DuplicateCommandIdException(envelope.commandId);
      }

      rethrow;
    }

    return envelope;
  }

  @override
  Future<int> nextSequence(String accountId) async {
    return _db.transaction<int>((txn) async {
      final rows = await txn.query(
        metaTable,
        columns: ['value'],
        where: 'account_id = ? and key = ?',
        whereArgs: [accountId, _sequenceKey],
      );

      final current = rows.isEmpty
          ? 0
          : int.parse(rows.first['value']! as String);
      final next = current + 1;

      await txn.insert(metaTable, {
        'account_id': accountId,
        'key': _sequenceKey,
        'value': '$next',
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      return next;
    });
  }

  @override
  Future<List<CommandEnvelope>> pendingCommands(String accountId) async {
    final rows = await _db.query(
      commandsTable,
      where: 'account_id = ? and status != ?',
      whereArgs: [accountId, CommandStatus.confirmed.storageValue],
      orderBy: 'sequence asc',
    );

    return rows.map(_fromRow).toList();
  }

  @override
  Future<CommandEnvelope?> commandByLocalId(
    String accountId,
    String localId,
  ) async {
    final rows = await _db.query(
      commandsTable,
      where: 'account_id = ? and local_id = ?',
      whereArgs: [accountId, localId],
      limit: 1,
    );

    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  @override
  Future<List<CommandEnvelope>> allCommands(String accountId) async {
    final rows = await _db.query(
      commandsTable,
      where: 'account_id = ?',
      whereArgs: [accountId],
      orderBy: 'sequence asc',
    );

    return rows.map(_fromRow).toList();
  }

  @override
  Future<List<CommandEnvelope>> commandsForWell(
    String accountId,
    String wellId,
  ) async {
    // صفوف الإصدارات القديمة بلا well_id تبقى قابلة للاستعادة من حمولة البدء.
    final rows = await _db.query(
      commandsTable,
      where: 'account_id = ? and (well_id = ? or well_id is null)',
      whereArgs: [accountId, wellId],
      orderBy: 'sequence asc',
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<bool> claim(
    String accountId,
    String localId, {
    required DateTime attemptedAt,
  }) async {
    final affected = await _db.update(
      commandsTable,
      {
        'status': CommandStatus.dispatching.storageValue,
        'last_attempt_at': _encodeTime(attemptedAt),
      },
      where: 'account_id = ? and local_id = ? and status = ?',
      whereArgs: [accountId, localId, CommandStatus.pending.storageValue],
    );

    return affected == 1;
  }

  @override
  Future<void> releaseForRetry(
    String accountId,
    String localId, {
    required String error,
    required DateTime attemptedAt,
  }) async {
    await _db.rawUpdate(
      '''
      update $commandsTable
         set status = ?,
             retry_count = retry_count + 1,
             last_error = ?,
             last_attempt_at = ?
       where account_id = ? and local_id = ?
      ''',
      [
        CommandStatus.pending.storageValue,
        error,
        _encodeTime(attemptedAt),
        accountId,
        localId,
      ],
    );
  }

  @override
  Future<void> markConfirmed(
    String accountId,
    String localId, {
    required Map<String, Object?> serverResponse,
    required DateTime attemptedAt,
  }) async {
    await _db.update(
      commandsTable,
      {
        'status': CommandStatus.confirmed.storageValue,
        'last_error': null,
        'last_attempt_at': _encodeTime(attemptedAt),
        'server_response': jsonEncode(serverResponse),
      },
      where: 'account_id = ? and local_id = ?',
      whereArgs: [accountId, localId],
    );
  }

  @override
  Future<void> markNeedsReview(
    String accountId,
    String localId, {
    required String error,
    required DateTime attemptedAt,
    Map<String, Object?>? serverResponse,
  }) async {
    await _db.update(
      commandsTable,
      {
        'status': CommandStatus.review.storageValue,
        'last_error': error,
        'last_attempt_at': _encodeTime(attemptedAt),
        if (serverResponse != null)
          'server_response': jsonEncode(serverResponse),
      },
      where: 'account_id = ? and local_id = ?',
      whereArgs: [accountId, localId],
    );
  }

  @override
  Future<void> putMapping(String accountId, IdMapping mapping) async {
    await _db.insert(mappingsTable, {
      'account_id': accountId,
      'local_id': mapping.localId,
      'entity_kind': mapping.kind.storageValue,
      'server_id': mapping.serverId,
      'resolved_at': _encodeTime(mapping.resolvedAt),
      'matched_existing': mapping.matchedExisting ? 1 : 0,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<IdMapping?> mapping(
    String accountId,
    String localId,
    EntityKind kind,
  ) async {
    final rows = await _db.query(
      mappingsTable,
      where: 'account_id = ? and local_id = ? and entity_kind = ?',
      whereArgs: [accountId, localId, kind.storageValue],
      limit: 1,
    );

    return rows.isEmpty ? null : _mappingFromRow(rows.first);
  }

  @override
  Future<List<IdMapping>> mappings(String accountId) async {
    final rows = await _db.query(
      mappingsTable,
      where: 'account_id = ?',
      whereArgs: [accountId],
    );

    return rows.map(_mappingFromRow).toList();
  }

  @override
  Future<DateTime?> lastSuccessfulSyncAt(String accountId) async {
    final rows = await _db.query(
      metaTable,
      columns: ['value'],
      where: 'account_id = ? and key = ?',
      whereArgs: [accountId, _lastSyncKey],
    );

    return rows.isEmpty ? null : _decodeTime(rows.first['value']! as String);
  }

  @override
  Future<void> setLastSuccessfulSyncAt(String accountId, DateTime at) async {
    await _db.insert(metaTable, {
      'account_id': accountId,
      'key': _lastSyncKey,
      'value': _encodeTime(at),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> close() async {
    _initFuture = null;
    final db = _database;
    _database = null;
    if (db != null && db.isOpen) {
      await db.close();
    }
  }

  Map<String, Object?> _toRow(CommandEnvelope envelope) => {
    'local_id': envelope.localId,
    'command_id': envelope.commandId,
    'command_type': envelope.type.storageValue,
    'account_id': envelope.accountId,
    'well_id': envelope.wellId ?? envelope.payload['p_well_id'] as String?,
    ..._projections(envelope.type.storageValue, envelope.payload),
    'aggregate_local_id': envelope.aggregateLocalId,
    'sequence': envelope.sequence,
    'occurred_at': _encodeTime(envelope.occurredAt),
    'created_local_at': _encodeTime(envelope.createdLocalAt),
    'payload': jsonEncode(envelope.payload),
    'prerequisites': jsonEncode(envelope.prerequisites),
    'local_context': jsonEncode(envelope.localContext),
    'status': envelope.status.storageValue,
    'retry_count': envelope.retryCount,
    'last_error': envelope.lastError,
    'next_attempt_at': envelope.nextAttemptAt == null
        ? null
        : _encodeTime(envelope.nextAttemptAt!),
    'last_attempt_at': envelope.lastAttemptAt == null
        ? null
        : _encodeTime(envelope.lastAttemptAt!),
    'server_response': envelope.serverResponse == null
        ? null
        : jsonEncode(envelope.serverResponse),
  };

  CommandEnvelope _fromRow(Map<String, Object?> row) {
    final serverResponse = row['server_response'] as String?;
    final lastAttemptAt = row['last_attempt_at'] as String?;

    return CommandEnvelope(
      localId: row['local_id']! as String,
      commandId: row['command_id']! as String,
      type: CommandType.fromStorage(row['command_type']! as String),
      accountId: row['account_id']! as String,
      wellId: row['well_id'] as String?,
      aggregateLocalId: row['aggregate_local_id'] as String?,
      sequence: row['sequence']! as int,
      occurredAt: _decodeTime(row['occurred_at']! as String),
      createdLocalAt: _decodeTime(row['created_local_at']! as String),
      payload: (jsonDecode(row['payload']! as String) as Map<String, Object?>),
      prerequisites: (jsonDecode(row['prerequisites']! as String) as List)
          .cast<String>(),
      localContext:
          (jsonDecode(row['local_context']! as String) as Map<String, Object?>),
      status: CommandStatus.fromStorage(row['status']! as String),
      retryCount: row['retry_count']! as int,
      lastError: row['last_error'] as String?,
      nextAttemptAt: row['next_attempt_at'] == null
          ? null
          : _decodeTime(row['next_attempt_at'] as String),
      lastAttemptAt: lastAttemptAt == null ? null : _decodeTime(lastAttemptAt),
      serverResponse: serverResponse == null
          ? null
          : (jsonDecode(serverResponse) as Map<String, Object?>),
    );
  }

  IdMapping _mappingFromRow(Map<String, Object?> row) => IdMapping(
    localId: row['local_id']! as String,
    kind: EntityKind.fromStorage(row['entity_kind']! as String),
    serverId: row['server_id']! as String,
    resolvedAt: _decodeTime(row['resolved_at']! as String),
    matchedExisting: (row['matched_existing']! as int) == 1,
  );

  /// UTC دائمًا: تغيير المنطقة الزمنية على الجهاز لا يجوز أن يغيّر
  /// وقت حدث محفوظ (القسم 19 — Time integrity).
  static String _encodeTime(DateTime at) => at.toUtc().toIso8601String();

  static DateTime _decodeTime(String value) => DateTime.parse(value).toUtc();

  // حصر إعادة محاولة SQLITE_BUSY في الأساس الجديد؛ سياسة المزامنة لا تتغير.
  Future<T> _withExecutionContentionRetry<T>(
    Future<T> Function() operation,
  ) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await operation();
      } on DatabaseException catch (error) {
        final code = error.getResultCode();
        if (attempt >= 4 || (code != 5 && code != 6)) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 10 << attempt));
      }
    }
  }
}

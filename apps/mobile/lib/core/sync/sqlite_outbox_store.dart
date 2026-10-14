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

import 'command_envelope.dart';
import 'command_type.dart';
import 'outbox_database.dart';
import 'outbox_store.dart';
import 'sync_status.dart';

class SqliteOutboxStore implements OutboxStore {
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

  static const int schemaVersion = 3;
  static const String commandsTable = 'outbox_commands';
  static const String mappingsTable = 'id_mappings';
  static const String metaTable = 'sync_meta';
  static const String _sequenceKey = 'sequence_counter';
  static const String _lastSyncKey = 'last_successful_sync_at';

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
        },
        onCreate: (db, version) async {
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
              server_response    text
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
        "and coalesce(c.well_id, json_extract(c.payload, '\$.p_well_id')) = ? limit 2",
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
    'well_id': envelope.wellId,
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
}

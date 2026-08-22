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
import 'outbox_store.dart';
import 'sync_status.dart';

class SqliteOutboxStore implements OutboxStore {
  SqliteOutboxStore({
    required this.databasePath,
    DatabaseFactory? sqfliteFactory,
  }) : _factory = sqfliteFactory ?? databaseFactory;

  /// مسار ملف قاعدة البيانات. `inMemoryDatabasePath` مسموح في الاختبار.
  final String databasePath;

  final DatabaseFactory _factory;

  static const int schemaVersion = 1;
  static const String commandsTable = 'outbox_commands';
  static const String mappingsTable = 'id_mappings';
  static const String metaTable = 'sync_meta';
  static const String _sequenceKey = 'sequence_counter';
  static const String _lastSyncKey = 'last_successful_sync_at';

  Database? _database;

  Database get _db {
    final database = _database;

    if (database == null) {
      throw StateError('نادِ initialize() قبل استخدام المخزن');
    }

    return database;
  }

  @override
  Future<void> initialize() async {
    _database ??= await _factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) => db.execute('pragma foreign_keys = on'),
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
  }) async {
    await _db.update(
      commandsTable,
      {
        'status': CommandStatus.review.storageValue,
        'last_error': error,
        'last_attempt_at': _encodeTime(attemptedAt),
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
    await _database?.close();
    _database = null;
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

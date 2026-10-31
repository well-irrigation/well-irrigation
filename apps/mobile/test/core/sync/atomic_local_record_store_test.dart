import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

Future<String> record(OutboxStore store, String value, {
  String account = 'account', String key = 'record',
}) => (store as AtomicLocalRecordStore).insertLocalRecordOnce(
  accountId: account, key: key, value: value,
);

SqliteOutboxStore openStore(String path) => SqliteOutboxStore(
  databasePath: path, sqfliteFactory: databaseFactoryFfi, singleInstance: false,
);

// Exercise the existing public transaction guard after its real INSERT.
class RollbackStore extends SqliteOutboxStore {
  RollbackStore(String path) : super(databasePath: path,
    sqfliteFactory: databaseFactoryFfi, singleInstance: false);
  int guardChecks = 0;

  @override
  Future<String> insertBundle({
    required String accountId, required String key, required String value,
    required List<CommandEnvelope> commands,
    Map<String, String> localValues = const {}, bool Function()? isCurrent,
  }) => super.insertBundle(accountId: accountId, key: key, value: value,
    commands: commands, localValues: localValues,
    isCurrent: () => ++guardChecks == 1);
}

Future<void> recordWorker(List<Object> message) async {
  sqfliteFfiInit();
  final path = message[0] as String;
  final value = message[1] as String;
  final output = message[2] as SendPort;
  final gate = ReceivePort();
  final store = openStore(path);
  String? result;
  String? error;
  try {
    await store.initialize();
    output.send(gate.sendPort);
    await gate.first;
    result = await record(store, value);
  } catch (failure) {
    error = failure.toString();
  } finally {
    await store.close();
    gate.close();
  }
  output.send({'value': result, 'error': error});
}

class Worker {
  Worker(this.gate, this.result, this.dispose);
  final SendPort gate;
  final Future<String> result;
  final Future<void> Function() dispose;
}

Future<Worker> launchWorker(String path, String value) async {
  final output = ReceivePort();
  final ready = Completer<SendPort>();
  final result = Completer<String>();
  final subscription = output.listen((dynamic message) {
    if (message is SendPort) {
      ready.complete(message);
    } else if (message is Map) {
      if (message['error'] != null) {
        final error = StateError(message['error'] as String);
        if (!ready.isCompleted) {
          ready.completeError(error);
        } else {
          result.completeError(error);
        }
      } else {
        result.complete(message['value'] as String);
      }
    }
  });
  final isolate = await Isolate.spawn(recordWorker, <Object>[path, value, output.sendPort]);
  try {
    final gate = await ready.future.timeout(const Duration(seconds: 20));
    return Worker(gate, result.future, () async {
      isolate.kill(priority: Isolate.immediate);
      await subscription.cancel();
      output.close();
    });
  } catch (_) {
    isolate.kill(priority: Isolate.immediate);
    await subscription.cancel();
    output.close();
    rethrow;
  }
}

Future<void> createLegacy(String path, int version) async {
  final db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(
    version: version, singleInstance: false,
    onCreate: (db, _) async {
      await db.execute('''create table outbox_commands (
        local_id text primary key, command_id text not null unique,
        command_type text not null, account_id text not null, well_id text,
        aggregate_local_id text, sequence integer not null,
        occurred_at text not null, created_local_at text not null,
        payload text not null,
        ${version == 2 ? "prerequisites text not null default '[]', local_context text not null default '{}'," : ''}
        status text not null, retry_count integer not null default 0,
        last_error text, last_attempt_at text, server_response text)''');
      await db.execute('create index outbox_commands_dispatch_idx on outbox_commands(account_id,status,sequence)');
      if (version == 2) {
        await db.execute('create index outbox_commands_well_idx on outbox_commands(account_id,well_id,sequence)');
      }
      await db.execute('''create table id_mappings (
        account_id text not null,local_id text not null,entity_kind text not null,
        server_id text not null,resolved_at text not null,
        matched_existing integer not null default 0,
        primary key(account_id,local_id,entity_kind))''');
      await db.execute('''create table sync_meta(account_id text not null,
        key text not null,value text not null,primary key(account_id,key))''');
    },
  ));
  try {
    await db.insert('outbox_commands', {
      'local_id': 'legacy', 'command_id': 'legacy-command', 'command_type': 'createFarm',
      'account_id': 'account', 'well_id': 'well', 'sequence': 7,
      'occurred_at': '2026-10-31T07:00:00Z', 'created_local_at': '2026-10-31T07:00:00Z',
      'payload': '{"p_well_id":"well","p_name":"الأصل"}', 'status': 'pending',
    });
    await db.insert('id_mappings', {'account_id': 'account', 'local_id': 'legacy',
      'entity_kind': 'farm', 'server_id': 'server-farm', 'resolved_at': '2026-10-31T07:00:00Z'});
    await db.insert('sync_meta', {'account_id': 'account', 'key': 'sequence_counter', 'value': '7'});
    await db.insert('sync_meta', {'account_id': 'account', 'key': 'legacy-record', 'value': 'original'});
  } finally {
    await db.close();
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite' : 'memory', () {
      late OutboxStore store;
      Directory? dir;
      setUp(() async {
        if (sqlite) {
          dir = await Directory.systemTemp.createTemp('atomic-record-');
          store = openStore('${dir!.path}/db');
        } else {
          store = InMemoryOutboxStore();
        }
        await store.initialize();
      });
      tearDown(() async {
        await store.close();
        await dir?.delete(recursive: true);
      });

      test('first value wins over a different value for the same identity', () async {
        expect(await record(store, 'A'), 'A');
        expect(await record(store, 'B'), 'A');
        expect(await store.readBundle('account', 'record'), 'A');
      });
      test('same-value replay remains one stable record', () async {
        for (var i = 0; i < 3; i++) {
          expect(await record(store, 'A'), 'A');
        }
        expect(await store.readBundle('account', 'record'), 'A');
        if (sqlite) {
          final db = await databaseFactoryFfi.openDatabase('${dir!.path}/db',
            options: OpenDatabaseOptions(singleInstance: false));
          try {
            expect((await db.query('sync_meta', where: 'account_id=? and key=?',
              whereArgs: ['account', 'record'])), hasLength(1));
          } finally {
            await db.close();
          }
        }
      });
      test('same key in different accounts has independent first values', () async {
        expect(await record(store, 'A'), 'A');
        expect(await record(store, 'B', account: 'other'), 'B');
        expect(await record(store, 'C', account: 'other'), 'B');
        expect(await store.readBundle('account', 'record'), 'A');
        expect(await store.readBundle('other', 'record'), 'B');
      });
      test('different keys in the same account remain independent', () async {
        expect(await record(store, 'A'), 'A');
        expect(await record(store, 'B', key: 'second'), 'B');
        expect(await store.readBundle('account', 'record'), 'A');
        expect(await store.readBundle('account', 'second'), 'B');
      });
      test('empty outbox stays empty and record does not consume a sequence', () async {
        await record(store, 'A');
        expect(await store.allCommands('account'), isEmpty);
        expect(await store.mappings('account'), isEmpty);
        expect(await store.lastSuccessfulSyncAt('account'), isNull);
        expect(await store.nextSequence('account'), 1);
      });
      test('existing command, mapping, sequence and domain metadata stay unchanged', () async {
        final at = DateTime.utc(2026, 10, 31, 7);
        expect(await store.nextSequence('account'), 1);
        await store.insert(CommandEnvelope(localId: 'root', commandId: 'root-command',
          accountId: 'account', wellId: 'well', type: CommandType.startIrrigationSession,
          sequence: 1, occurredAt: at, createdLocalAt: at, payload: {'p_well_id': 'well'}));
        await store.putMapping('account', IdMapping(localId: 'root', kind: EntityKind.session,
          serverId: 'server-session', resolvedAt: at));
        await store.insertBundle(accountId: 'account', key: 'booking.lifecycle.v1.well',
          value: 'unchanged-booking-state', commands: [],
          localValues: {'session.execution.v1.well': 'unchanged-session-state'});
        await store.setLastSuccessfulSyncAt('account', at);
        await record(store, 'A');
        final rows = await store.allCommands('account');
        expect(rows, hasLength(1));
        expect(rows.single.commandId, 'root-command');
        expect(rows.single.status.storageValue, 'pending');
        expect(rows.single.retryCount, 0);
        expect(rows.single.lastAttemptAt, isNull);
        expect(rows.single.payload, {'p_well_id': 'well'});
        expect(rows.single.sequence, 1);
        expect(rows.single.occurredAt, at);
        expect(await store.mappings('account'), hasLength(1));
        expect((await store.mapping('account', 'root', EntityKind.session))!.serverId, 'server-session');
        expect(await store.nextSequence('account'), 2);
        expect(await store.lastSuccessfulSyncAt('account'), at);
        expect(await store.readBundle('account', 'booking.lifecycle.v1.well'), 'unchanged-booking-state');
        expect(await store.readBundle('account', 'session.execution.v1.well'), 'unchanged-session-state');
      });
      test('simultaneous calls return the same winner', () async {
        final values = await Future.wait([record(store, 'A'), record(store, 'B')]);
        expect(values.toSet(), hasLength(1));
        expect(['A', 'B'], contains(values.first));
        expect(await store.readBundle('account', 'record'), values.first);
      });
    });
  }

  test('SQLite close and fresh reopen preserve the original record and schema 3', () async {
    final dir = await Directory.systemTemp.createTemp('atomic-durable-');
    final path = '${dir.path}/db';
    var store = openStore(path);
    try {
      await store.initialize();
      await record(store, 'A');
      await store.close();
      store = openStore(path);
      await store.initialize();
      expect(await record(store, 'B'), 'A');
      expect(await store.readBundle('account', 'record'), 'A');
      final db = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
      try {
        expect(SqliteOutboxStore.schemaVersion, 3);
        expect(await db.getVersion(), 3);
        final tables = await db.rawQuery("select name from sqlite_master where type='table' and name not like 'sqlite_%' and name!='android_metadata'");
        expect(tables.map((r) => r['name']), unorderedEquals(['outbox_commands', 'id_mappings', 'sync_meta']));
        expect((await db.rawQuery('pragma table_info(outbox_commands)')).map((r) => r['name']),
          isNot(contains('next_attempt_at')));
      } finally {
        await db.close();
      }
    } finally {
      await store.close();
      await dir.delete(recursive: true);
    }
  });

  test('independent SQLite worker connections commit one stable winner', () async {
    final dir = await Directory.systemTemp.createTemp('atomic-race-');
    final path = '${dir.path}/db';
    final stores = <Worker>[];
    final seed = openStore(path);
    try {
      await seed.initialize();
      await seed.close();
      // Both connections finish initialization before either is released.
      stores.addAll(await Future.wait([launchWorker(path, 'A'), launchWorker(path, 'B')]));
      final results = Future.wait(stores.map((w) => w.result));
      for (final worker in stores) { worker.gate.send(true); }
      final values = await results.timeout(const Duration(seconds: 20));
      expect(values.toSet(), hasLength(1));
      expect(['A', 'B'], contains(values.first));
      final reopened = openStore(path);
      try {
        await reopened.initialize();
        expect(await record(reopened, 'C'), values.first);
        final db = await databaseFactoryFfi.openDatabase(path,
          options: OpenDatabaseOptions(singleInstance: false));
        try {
          final rows = await db.query('sync_meta', where: 'account_id=? and key=?',
            whereArgs: ['account', 'record']);
          expect(rows, hasLength(1));
          expect(rows.single['value'], values.first);
          expect(await db.getVersion(), 3);
        } finally { await db.close(); }
      } finally { await reopened.close(); }
    } finally {
      for (final worker in stores) { await worker.dispose(); }
      await seed.close();
      await dir.delete(recursive: true);
    }
  });

  test('failure after INSERT rolls back the record, including after reopen', () async {
    final dir = await Directory.systemTemp.createTemp('atomic-rollback-');
    final path = '${dir.path}/db';
    final failing = RollbackStore(path);
    final reopened = openStore(path);
    try {
      await failing.initialize();
      await expectLater(record(failing, 'failed'), throwsStateError);
      expect(failing.guardChecks, 2);
      expect(await failing.readBundle('account', 'record'), isNull);
      await failing.close();
      await reopened.initialize();
      expect(await reopened.readBundle('account', 'record'), isNull);
      expect(await record(reopened, 'committed'), 'committed');
      expect(await record(reopened, 'later'), 'committed');
      expect(await reopened.allCommands('account'), isEmpty);
    } finally {
      await failing.close(); await reopened.close();
      await dir.delete(recursive: true);
    }
  });

  for (final version in [1, 2]) {
    test('baseline v$version upgrade preserves records and commands at v3', () async {
      final dir = await Directory.systemTemp.createTemp('atomic-upgrade-');
      final path = '${dir.path}/db';
      final store = openStore(path);
      try {
        await createLegacy(path, version);
        await store.initialize();
        expect(await record(store, 'replacement', key: 'legacy-record'), 'original');
        expect(await record(store, 'new-value', key: 'new-record'), 'new-value');
        final row = (await store.commandByLocalId('account', 'legacy'))!;
        expect(row.commandId, 'legacy-command');
        expect(row.payload, {'p_well_id': 'well', 'p_name': 'الأصل'});
        expect(row.prerequisites, isEmpty);
        expect(row.localContext, isEmpty);
        expect(row.status.storageValue, 'pending');
        expect((await store.mapping('account', 'legacy', EntityKind.farm))!.serverId, 'server-farm');
        expect(await store.nextSequence('account'), 8);
        final db = await databaseFactoryFfi.openDatabase(path,
          options: OpenDatabaseOptions(singleInstance: false));
        try {
          expect(await db.getVersion(), 3);
          final columns = (await db.rawQuery('pragma table_info(outbox_commands)')).map((r) => r['name']);
          expect(columns, containsAll(['prerequisites', 'local_context']));
          expect(columns, isNot(contains('next_attempt_at')));
          final indexes = (await db.rawQuery("select name from sqlite_master where type='index'")).map((r) => r['name']);
          expect(indexes, containsAll(['outbox_commands_well_idx', 'outbox_commands_session_idx', 'id_mappings_server_idx']));
        } finally { await db.close(); }
      } finally { await store.close(); await dir.delete(recursive: true); }
    });
  }
}

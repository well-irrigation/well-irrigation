@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';

import 'package_a_outbox_test.dart' as f;

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late String path;
  late SqliteOutboxStore store;
  Future<void> open() async {
    store = SqliteOutboxStore(
      databasePath: path,
      sqfliteFactory: databaseFactoryFfi,
    );
    await store.initialize();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('package-a-upgrade-');
    path = '${dir.path}/old.db';
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });
  test('v1 commands, mappings, meta survive additive upgrade and new dependencies survive restart', () async {
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'create table outbox_commands (local_id text primary key, command_id text not null unique, command_type text not null, account_id text not null, well_id text, aggregate_local_id text, sequence integer not null, occurred_at text not null, created_local_at text not null, payload text not null, status text not null, retry_count integer not null default 0, last_error text, last_attempt_at text, server_response text)',
          );
          await db.execute(
            'create table id_mappings (account_id text not null,local_id text not null,entity_kind text not null,server_id text not null,resolved_at text not null,matched_existing integer not null default 0,primary key(account_id,local_id,entity_kind))',
          );
          await db.execute(
            'create table sync_meta(account_id text not null,key text not null,value text not null,primary key(account_id,key))',
          );
        },
      ),
    );
    await db.insert('outbox_commands', {
      'local_id': 'old',
      'command_id': 'old-command',
      'command_type': 'completeIrrigationSession',
      'account_id': 'account',
      'sequence': 1,
      'occurred_at': '2026-10-13T10:00:00Z',
      'created_local_at': '2026-10-13T10:00:00Z',
      'payload': '{"p_session_id":"old-server"}',
      'status': 'confirmed',
    });
    await db.insert('id_mappings', {
      'account_id': 'account',
      'local_id': 'old',
      'entity_kind': 'sessionCharge',
      'server_id': 'old-charge',
      'resolved_at': '2026-10-13T10:00:00Z',
    });
    await db.insert('sync_meta', {
      'account_id': 'account',
      'key': 'legacy',
      'value': 'kept',
    });
    await db.close();
    await open();
    expect(
      (await store.commandByLocalId('account', 'old'))?.commandId,
      'old-command',
    );
    expect(
      (await store.commandByLocalId('account', 'old'))?.prerequisites,
      isEmpty,
    );
    expect(
      (await store.mapping(
        'account',
        'old',
        EntityKind.sessionCharge,
      ))?.serverId,
      'old-charge',
    );
    expect(await store.readLocalValue('account', 'legacy'), 'kept');
    await store.insertBundle(
      accountId: 'account',
      key: 'bundle',
      value: 'record',
      commands: [
        f.command(
          'B',
          CommandType.startBookingSession,
          2,
          prerequisites: ['old'],
        ),
      ],
    );
    await store.close();
    await open();
    expect((await store.commandByLocalId('account', 'B'))?.prerequisites, [
      'old',
    ]);
    expect(
      (await store.commandByLocalId('account', 'B'))?.localContext['p_farm_id'],
      'farm',
    );
    expect(await store.readBundle('account', 'bundle'), 'record');
  });
  test('SQLite rollback before commit and competing bundles create one durable pair', () async {
    await open();
    final commands = [
      f.command('A', CommandType.completeIrrigationSession, 1),
      f.command('B', CommandType.startBookingSession, 2, prerequisites: ['A']),
    ];
    var guards = 0;
    await expectLater(
      store.insertBundle(
        accountId: 'account',
        key: 'bundle',
        value: 'record',
        commands: commands,
        isCurrent: () => ++guards < 2,
      ),
      throwsStateError,
    );
    expect(await store.allCommands('account'), isEmpty);
    expect(await store.readBundle('account', 'bundle'), isNull);
    final results = await Future.wait(
      List.generate(
        5,
        (_) => store.insertBundle(
          accountId: 'account',
          key: 'bundle',
          value: 'record',
          commands: commands,
        ),
      ),
    );
    expect(results.every((v) => v == 'record'), isTrue);
    expect(await store.allCommands('account'), hasLength(2));
  });
  test(
    'corrupt prerequisite fails closed while unrelated command dispatches',
    () async {
      await open();
      await store.insert(
        f.command('A', CommandType.completeIrrigationSession, 1),
      );
      await store.markConfirmed(
        'account',
        'A',
        serverResponse: {},
        attemptedAt: f.instant,
      );
      final db = await databaseFactoryFfi.openDatabase(path);
      await db.update(
        'outbox_commands',
        {'command_type': 'corrupt'},
        where: 'local_id = ?',
        whereArgs: ['A'],
      );
      await store.insert(
        f.command(
          'B',
          CommandType.startBookingSession,
          2,
          prerequisites: ['A'],
        ),
      );
      await store.insert(f.command('C', CommandType.startBookingSession, 3));
      final transport = f.PackageTransport();
      await SyncEngine(store: store, transport: transport).run('account');
      expect(transport.requests.map((r) => r.commandId), ['uuid-C']);
      expect(
        (await store.commandByLocalId('account', 'B'))?.status,
        CommandStatus.review,
      );
    },
  );
  test('lost start ACK replays same ID, creates one mapping and preserves actual start', () async {
    await open();
    await store.insert(
      f.command('A', CommandType.completeIrrigationSession, 1),
    );
    await store.insert(
      f.command('B', CommandType.startBookingSession, 2, prerequisites: ['A']),
    );
    final transport = ReplayTransport();
    final engine = SyncEngine(store: store, transport: transport);
    await engine.run('account');
    await store.close();
    await open();
    await SyncEngine(store: store, transport: transport).run('account');
    expect(transport.starts, 2);
    expect(transport.executions, 1);
    expect(
      (await store.mapping('account', 'B', EntityKind.session))?.serverId,
      'server-B',
    );
    expect(
      (await store.commandByLocalId('account', 'B'))?.occurredAt,
      f.instant,
    );
    expect(await store.mappings('account'), hasLength(2));
  });
}

class ReplayTransport implements CommandTransport {
  int starts = 0;
  int executions = 0;
  final accepted = <String, DispatchResult>{};
  @override
  Future<DispatchResult> dispatch(DispatchRequest request) async {
    if (request.type == CommandType.completeIrrigationSession) {
      return const DispatchAccepted(
        response: {'session_charge_id': 'charge'},
        entityId: 'charge',
      );
    }
    starts++;
    if (!accepted.containsKey(request.commandId)) {
      executions++;
      accepted[request.commandId] = normalizeAcceptedResponse(request.type, {
        'session_id': 'server-B',
      });
      return const DispatchFailed(
        disposition: FailureDisposition.retry,
        message: 'lost ack',
      );
    }
    return accepted[request.commandId]!;
  }
}

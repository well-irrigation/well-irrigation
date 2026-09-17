@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/sync/background_sync_worker.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/supabase_command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import 'sync_test_support.dart';

void main() {
  late HttpServer server;
  late SupabaseClient client;
  final received = <HttpRequest>[];

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    received.clear();
    server.listen((request) async {
      received.add(request);
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode('server-session'));
      await request.response.close();
    });
    client = SupabaseClient('http://127.0.0.1:${server.port}', 'test-key');
  });

  tearDown(() async {
    await client.dispose();
    await server.close(force: true);
  });

  Future<void> authenticate(String userId) async {
    await client.auth.recoverSession(
      jsonEncode({
        'access_token': 'test-token',
        'token_type': 'bearer',
        'refresh_token': 'refresh-token',
        'user': {'id': userId, 'aud': 'authenticated', 'created_at': ''},
      }),
    );
  }

  Future<(InMemoryOutboxStore, String)> pendingStart() async {
    final store = InMemoryOutboxStore();
    final repo = OutboxRepository(store: store);
    await repo.initialize();
    final command = await repo.enqueue(
      accountId: 'account-a',
      wellId: 'well-a',
      type: CommandType.startIrrigationSession,
      occurredAt: DateTime.utc(2026, 9, 17),
      payload: startSessionPayload(
        well: 'well-a',
        farm: 'farm-a',
        farmerWellAccount: 'farmer-a',
      ),
    );
    return (store, command.localId);
  }

  test('matching authenticated account dispatches its command', () async {
    await authenticate('account-a');
    final (store, localId) = await pendingStart();
    final report = await SyncEngine(
      store: store,
      transport: SupabaseCommandTransport(client),
    ).run('account-a');

    expect(received, hasLength(1));
    expect(report.confirmed, 1);
    expect(
      (await store.commandByLocalId('account-a', localId))!.status,
      CommandStatus.confirmed,
    );
  });

  test('other authenticated account never reaches RPC or confirms', () async {
    await authenticate('account-b');
    final (store, localId) = await pendingStart();
    final report = await SyncEngine(
      store: store,
      transport: SupabaseCommandTransport(client),
    ).run('account-a');

    expect(received, isEmpty);
    expect(report.retryScheduled, 1);
    expect(
      (await store.commandByLocalId('account-a', localId))!.status,
      CommandStatus.pending,
    );
  });

  test('no authenticated account never reaches RPC or confirms', () async {
    final (store, localId) = await pendingStart();
    final report = await SyncEngine(
      store: store,
      transport: SupabaseCommandTransport(client),
    ).run('account-a');

    expect(received, isEmpty);
    expect(report.retryScheduled, 1);
    expect(
      (await store.commandByLocalId('account-a', localId))!.status,
      CommandStatus.pending,
    );
  });

  test('worker gate blocks a scheduled A task under local B auth', () async {
    await authenticate('account-b');
    expect(canRunBackgroundAccount(client, 'account-a'), isFalse);
    expect(received, isEmpty);
  });
}

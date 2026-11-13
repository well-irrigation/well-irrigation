import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/manual_session_entry.dart';
import 'package:well_irrigation_mobile/core/sync/supabase_command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import 'manual_session_entry_test.dart' as fixture;

void main() {
  late SupabaseClient client;
  late SupabaseCommandTransport transport;
  final calls = <http.Request>[];
  Object? reply;
  var statusCode = 200;
  var networkFailure = false;
  Completer<void>? rpcStarted;
  Completer<void>? rpcResponse;

  Future<void> authenticate(String account) async {
    await client.auth.recoverSession(jsonEncode({
      'access_token':'test-token','token_type':'bearer','refresh_token':'test-refresh',
      'user':{'id':account,'aud':'authenticated','created_at':''},
    }));
  }

  setUp(() async {
    calls.clear();
    statusCode = 200;
    networkFailure = false;
    rpcStarted = null;
    rpcResponse = null;
    client = SupabaseClient('https://manual-entry.invalid','test-key',
      authOptions:const AuthClientOptions(autoRefreshToken:false),
      httpClient:MockClient((request) async {
        calls.add(request);
        if (request.url.path.startsWith('/rest/v1/rpc/')) {
          if (rpcStarted != null && !rpcStarted!.isCompleted) rpcStarted!.complete();
          await rpcResponse?.future;
        }
        if (networkFailure) throw http.ClientException('lost');
        return http.Response(jsonEncode(reply),statusCode,
          headers:{'content-type':'application/json'},request:request);
      }));
    transport = SupabaseCommandTransport(client);
    await authenticate(fixture.account);
  });
  tearDown(() async => client.dispose());

  for (final completed in [true,false]) {
    for (final receipt in [false, true]) {
      for (final signOut in [false, true]) {
        test('$completed receipt=$receipt signOut=$signOut rejects identity loss after RPC starts', () async {
          final c = await fixture.enqueue(InMemoryOutboxStore(), completed);
          reply = receipt ? {
            'contract': 'get_manual_session_entry_receipt', 'version': 1,
            'well_id': fixture.well, 'command_id': c.commandId,
            'status': 'accepted', 'retry_authorized': false,
            'result': fixture.accepted(c),
          } : fixture.accepted(c);
          rpcStarted = Completer<void>();
          rpcResponse = Completer<void>();
          final Future<Object> result = receipt
              ? transport.readManualSessionEntryReceipt(ManualSessionEntryReceiptRequest.fromCommand(c)!)
              : transport.dispatch(DispatchRequest(accountId: c.accountId,
                  type: c.type, commandId: c.commandId,
                  arguments: buildRpcArguments(type: c.type, commandId: c.commandId,
                    occurredAt: c.occurredAt, resolvedPayload: c.payload)));
          await rpcStarted!.future;
          if (signOut) {
            await client.auth.signOut(scope: SignOutScope.local);
            expect(client.auth.currentSession, isNull);
          } else {
            await authenticate(fixture.farm);
          }
          rpcResponse!.complete();
          final value = await result;
          if (receipt) {
            expect(value, isA<ManualSessionEntryReadFailure>());
            expect((value as ManualSessionEntryReadFailure).kind,
                ManualSessionEntryReadFailureKind.authentication);
          } else {
            expect(value, isA<DispatchFailed>());
            final failure = value as DispatchFailed;
            expect(failure.executionNotStarted, isFalse);
            expect(failure.serverResponse, isNull);
          }
          expect(calls.where((r) => r.url.path.startsWith('/rest/v1/rpc/')), hasLength(1));
        });
      }

      test('$completed receipt=$receipt sync retains identity-lost intent and recovers by receipt only', () async {
        final store = InMemoryOutboxStore();
        final c = await fixture.enqueue(store, completed);
        if (receipt) await store.claim(c.accountId, c.localId, attemptedAt: fixture.now);
        reply = receipt ? {
          'contract': 'get_manual_session_entry_receipt', 'version': 1,
          'well_id': fixture.well, 'command_id': c.commandId,
          'status': 'accepted', 'retry_authorized': false,
          'result': fixture.accepted(c),
        } : fixture.accepted(c);
        rpcStarted = Completer<void>();
        rpcResponse = Completer<void>();
        final engine = SyncEngine(store: store, transport: transport, clock: () => fixture.now);
        final run = engine.run(c.accountId);
        await rpcStarted!.future;
        await authenticate(fixture.farm);
        rpcResponse!.complete();
        expect((await run).confirmed, 0);
        var row = (await store.commandByLocalId(c.accountId, c.localId))!;
        expect(row.status, CommandStatus.dispatching);
        expect(row.commandId, c.commandId);
        expect(row.payload, c.payload);
        expect(row.occurredAt, c.occurredAt);
        expect(row.serverResponse, isNull);
        expect(await store.allCommands(c.accountId), hasLength(1));
        await engine.run(c.accountId);
        expect(calls, hasLength(1)); // Wrong account cannot start another RPC.
        await authenticate(c.accountId);
        reply = {
          'contract': 'get_manual_session_entry_receipt', 'version': 1,
          'well_id': fixture.well, 'command_id': c.commandId,
          'status': 'accepted', 'retry_authorized': false,
          'result': fixture.accepted(c),
        };
        expect((await engine.run(c.accountId)).confirmed, 1);
        expect(calls, hasLength(2));
        expect(calls.last.url.path, '/rest/v1/rpc/get_manual_session_entry_receipt');
        expect(calls.where((r) => r.url.path.endsWith('/${c.type.rpcName}')),
            hasLength(receipt ? 0 : 1));
        row = (await store.commandByLocalId(c.accountId, c.localId))!;
        expect(row.status, CommandStatus.confirmed);
        expect(row.commandId, c.commandId);
        expect(row.payload, c.payload);
        expect(row.occurredAt, c.occurredAt);
      });
    }
    test('${completed ? 'completed' : 'active'} write goes to exact public RPC with only legitimate facts', () async {
      final c = await fixture.enqueue(InMemoryOutboxStore(),completed);
      reply = fixture.accepted(c);
      final args = buildRpcArguments(type:c.type,commandId:c.commandId,
        occurredAt:c.occurredAt,resolvedPayload:c.payload);
      final result = await transport.dispatch(DispatchRequest(accountId:c.accountId,
        type:c.type,commandId:c.commandId,arguments:args));
      expect(result,isA<DispatchAccepted>(),
        reason:result is DispatchFailed ? result.message : null);
      expect(calls.single.url.path,'/rest/v1/rpc/${c.type.rpcName}');
      expect(calls.single.headers['content-profile'],'api');
      expect(jsonDecode(calls.single.body),args);
      expect(args.keys,unorderedEquals(['p_well_id','p_command_id','p_request']));
    });

    for (final state in ['accepted','processing','conflict_overlap','conflict_active_resource',
      'validation_error','needs_review','unresolved','not_found']) {
      test('${completed ? 'completed' : 'active'} receipt $state is typed and read only', () async {
        final c = await fixture.enqueue(InMemoryOutboxStore(),completed);
        final request = ManualSessionEntryReceiptRequest.fromCommand(c)!;
        reply = {
          'contract':'get_manual_session_entry_receipt','version':1,
          'well_id':fixture.well,'command_id':c.commandId,'status':state,
          'retry_authorized':false,
          'result':const {'processing','not_found','unresolved'}.contains(state)
            ? null : {...fixture.accepted(c),'status':state},
        };
        final result = await transport.readManualSessionEntryReceipt(request);
        expect(result,isA<ManualSessionEntryOutcome>());
        expect((result as ManualSessionEntryOutcome).state,ManualSessionEntryState.fromWire(state));
        if (state == 'accepted') {
          expect(result.sessionId,fixture.session);
          expect(result.isOpen,!completed);
          expect(result.amountMinor,completed ? 500 : null);
        }
        expect(calls.single.url.path,'/rest/v1/rpc/get_manual_session_entry_receipt');
        expect(calls.single.headers['content-profile'],'api');
        expect(jsonDecode(calls.single.body),request.arguments);
      });
    }
  }
  for (final error in ['42501','28000','PGRST301','22023','XX000']) {
    test('receipt error $error maps to safe category', () async {
      final c = await fixture.enqueue(InMemoryOutboxStore(),false);
      statusCode = 400;
      reply = {'code':error,'message':'internal SQL trigger name'};
      final result = await transport.readManualSessionEntryReceipt(
        ManualSessionEntryReceiptRequest.fromCommand(c)!);
      expect((result as ManualSessionEntryReadFailure).kind,switch(error) {
        '42501' => ManualSessionEntryReadFailureKind.forbidden,
        '28000' || 'PGRST301' => ManualSessionEntryReadFailureKind.authentication,
        '22023' => ManualSessionEntryReadFailureKind.malformed,
        _ => ManualSessionEntryReadFailureKind.network,
      });
    });
  }
  test('wrong account cannot read receipt or dispatch', () async {
    final c = await fixture.enqueue(InMemoryOutboxStore(),false);
    await authenticate(fixture.farm);
    final r = await transport.readManualSessionEntryReceipt(ManualSessionEntryReceiptRequest.fromCommand(c)!);
    expect((r as ManualSessionEntryReadFailure).kind,ManualSessionEntryReadFailureKind.authentication);
    final write = await transport.dispatch(DispatchRequest(accountId:c.accountId,
      type:c.type,commandId:c.commandId,arguments:c.payload));
    expect((write as DispatchFailed).executionNotStarted,isTrue);
    expect(calls,isEmpty);
  });
  test('receipt network failure is typed without technical leakage', () async {
    final c = await fixture.enqueue(InMemoryOutboxStore(),false);
    networkFailure = true;
    final r = await transport.readManualSessionEntryReceipt(ManualSessionEntryReceiptRequest.fromCommand(c)!);
    expect((r as ManualSessionEntryReadFailure).kind,ManualSessionEntryReadFailureKind.network);
  });
}

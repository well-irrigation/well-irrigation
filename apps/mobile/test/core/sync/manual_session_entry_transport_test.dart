import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/manual_session_entry.dart';
import 'package:well_irrigation_mobile/core/sync/supabase_command_transport.dart';

import 'manual_session_entry_test.dart' as fixture;

void main() {
  late SupabaseClient client;
  late SupabaseCommandTransport transport;
  final calls = <http.Request>[];
  Object? reply;
  var statusCode = 200;
  var networkFailure = false;

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
    client = SupabaseClient('https://manual-entry.invalid','test-key',
      authOptions:const AuthClientOptions(autoRefreshToken:false),
      httpClient:MockClient((request) async {
        calls.add(request);
        if (networkFailure) throw http.ClientException('lost');
        return http.Response(jsonEncode(reply),statusCode,
          headers:{'content-type':'application/json'},request:request);
      }));
    transport = SupabaseCommandTransport(client);
    await authenticate(fixture.account);
  });
  tearDown(() async => client.dispose());

  for (final completed in [true,false]) {
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

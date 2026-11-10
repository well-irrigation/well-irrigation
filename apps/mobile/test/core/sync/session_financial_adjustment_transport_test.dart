import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/session_financial_adjustment.dart';
import 'package:well_irrigation_mobile/core/sync/supabase_command_transport.dart';

CommandEnvelope _command() => CommandEnvelope(
  localId: 'local-a',
  commandId: '11111111-1111-4111-8111-111111111111',
  type: CommandType.adjustSessionFinancialAmount,
  accountId: 'account-a',
  wellId: 'well-a',
  sequence: 1,
  occurredAt: DateTime.utc(2026, 11, 10, 14, 30),
  createdLocalAt: DateTime.utc(2026, 11, 10, 14, 31),
  payload: const {
    'p_session_id': 'session-a',
    'p_base_operational_revision': 3,
    'p_base_system_financial_revision': 2,
    'p_base_manual_approval_revision': 1,
    'p_approved_amount_minor': 8500,
    'p_reason': 'اعتماد جديد',
  },
);

Map<String, Object?> _result(String status) => {
  'contract': 'session_financial_adjustment',
  'version': 1,
  'status': status,
  'session_id': 'session-a',
  'command_id': '11111111-1111-4111-8111-111111111111',
  if (status == 'accepted') ...{
    'adjustment_id': 'adjustment-a',
    'operational_revision': 3,
    'system_financial_revision': 3,
    'manual_approval_revision': 2,
    'previous_effective_minor': 9000,
    'approved_amount_minor': 8500,
    'effective_amount_minor': 8500,
    'delta_minor': -500,
    'accepted_at': '2026-11-10T14:30:01.123456Z',
  } else
    'reason_code': 'server_reason',
  'retry_authorized': false,
};

void main() {
  late SupabaseClient client;
  late SupabaseCommandTransport transport;
  final calls = <http.Request>[];
  Object? reply;
  var statusCode = 200;
  var networkFailure = false;
  Completer<void>? gate;
  late Completer<void> entered;

  Future<void> login(String account) => client.auth.recoverSession(
    jsonEncode({
      'access_token': 'token',
      'token_type': 'bearer',
      'refresh_token': 'refresh',
      'user': {'id': account, 'aud': 'authenticated', 'created_at': ''},
    }),
  );

  setUp(() async {
    calls.clear();
    gate = null;
    entered = Completer<void>();
    reply = _result('accepted');
    statusCode = 200;
    networkFailure = false;
    client = SupabaseClient(
      'https://financial-transport.invalid',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        calls.add(request);
        if (!entered.isCompleted) entered.complete();
        await gate?.future;
        if (networkFailure) throw http.ClientException('lost after send');
        return http.Response(
          jsonEncode(reply),
          statusCode,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    transport = SupabaseCommandTransport(client);
    await login('account-a');
  });

  tearDown(() => client.dispose());

  test(
    'write sends exact eight RPC arguments and returns typed acceptance',
    () async {
      final request = SessionFinancialAdjustmentRequest.fromCommand(
        _command(),
      )!;
      final result = await transport.adjustSessionFinancialAmount(request);
      expect(result, isA<SessionFinancialAdjustmentResponse>());
      expect(
        calls.single.url.path,
        '/rest/v1/rpc/adjust_session_financial_amount',
      );
      expect(calls.single.headers['content-profile'], 'api');
      expect(jsonDecode(calls.single.body), request.arguments);
      expect(
        (jsonDecode(calls.single.body) as Map).keys,
        unorderedEquals({
          'p_session_id',
          'p_command_id',
          'p_base_operational_revision',
          'p_base_system_financial_revision',
          'p_base_manual_approval_revision',
          'p_approved_amount_minor',
          'p_reason',
          'p_requested_at',
        }),
      );
    },
  );

  for (final status in [
    'accepted',
    'processing',
    'validation_error',
    'financial_review_required',
    'locked',
    'conflict_request',
    'conflict_revision',
    'permission_denied',
    'unresolved',
  ]) {
    test('write status $status is typed', () async {
      reply = _result(status);
      final result = await transport.adjustSessionFinancialAmount(
        SessionFinancialAdjustmentRequest.fromCommand(_command())!,
      );
      expect(
        (result as SessionFinancialAdjustmentResponse).state.wireValue,
        status,
      );
    });
  }

  for (final status in [
    'accepted',
    'processing',
    'validation_error',
    'financial_review_required',
    'locked',
    'conflict_request',
    'conflict_revision',
    'permission_denied',
    'unresolved',
    'not_found',
  ]) {
    test(
      'receipt status $status remains read-only and never authorizes retry',
      () async {
        final command = _command();
        final request = SessionFinancialAdjustmentReceiptRequest.fromCommand(
          command,
        )!;
        reply = {
          'contract': 'session_financial_adjustment_receipt',
          'version': 1,
          'session_id': 'session-a',
          'command_id': command.commandId,
          'status': status,
          'result':
              const {'processing', 'unresolved', 'not_found'}.contains(status)
              ? null
              : _result(status),
          'retry_authorized': false,
        };
        final read = await transport.readSessionFinancialAdjustmentReceipt(
          request,
        );
        expect(read, isA<SessionFinancialAdjustmentResponse>());
        expect(
          (read as SessionFinancialAdjustmentResponse).state.wireValue,
          status,
        );
        expect(
          calls.single.url.path,
          '/rest/v1/rpc/get_session_financial_adjustment_receipt',
        );
        expect(jsonDecode(calls.single.body), request.arguments);
      },
    );
  }

  test(
    'malformed receipt is typed failure and cannot authorize redispatch',
    () async {
      reply = {
        'contract': 'session_financial_adjustment_receipt',
        'version': 1,
        'session_id': 'session-b',
        'command_id': _command().commandId,
        'status': 'not_found',
        'result': null,
        'retry_authorized': false,
      };
      final read = await transport.readSessionFinancialAdjustmentReceipt(
        SessionFinancialAdjustmentReceiptRequest.fromCommand(_command())!,
      );
      expect(read, isA<SessionFinancialAdjustmentReadFailure>());
      expect(
        (read as SessionFinancialAdjustmentReadFailure).kind,
        SessionFinancialAdjustmentReadFailureKind.malformed,
      );
    },
  );

  test('identity change after RPC started invalidates result without retry authority', () async {
    gate = Completer<void>();
    final pending = transport.adjustSessionFinancialAmount(
      SessionFinancialAdjustmentRequest.fromCommand(_command())!,
    );
    await entered.future;
    await login('account-b');
    gate!.complete();
    final result = await pending;
    expect(result, isA<SessionFinancialAdjustmentReadFailure>());
    expect(
      (result as SessionFinancialAdjustmentReadFailure).executionNotStarted,
      isFalse,
    );
  });

  test(
    'persisted unresolved receipt result is a valid domain observation',
    () async {
      reply = {
        'contract': 'session_financial_adjustment_receipt',
        'version': 1,
        'session_id': 'session-a',
        'command_id': _command().commandId,
        'status': 'unresolved',
        'result': _result('unresolved'),
        'retry_authorized': false,
      };
      final read = await transport.readSessionFinancialAdjustmentReceipt(
        SessionFinancialAdjustmentReceiptRequest.fromCommand(_command())!,
      );
      expect(read, isA<SessionFinancialAdjustmentResponse>());
      expect(
        (read as SessionFinancialAdjustmentResponse).state,
        SessionFinancialAdjustmentState.unresolved,
      );
    },
  );

  test('network failure is ambiguous, never execution-not-started', () async {
    networkFailure = true;
    final result = await transport.adjustSessionFinancialAmount(
      SessionFinancialAdjustmentRequest.fromCommand(_command())!,
    );
    expect(result, isA<SessionFinancialAdjustmentReadFailure>());
    expect(
      (result as SessionFinancialAdjustmentReadFailure).kind,
      SessionFinancialAdjustmentReadFailureKind.network,
    );
    expect(result.executionNotStarted, isFalse);
  });

  test('wrong account proves local pre-RPC non-execution', () async {
    await login('account-b');
    final result = await transport.adjustSessionFinancialAmount(
      SessionFinancialAdjustmentRequest.fromCommand(_command())!,
    );
    expect(result, isA<SessionFinancialAdjustmentReadFailure>());
    expect(
      (result as SessionFinancialAdjustmentReadFailure).executionNotStarted,
      isTrue,
    );
    expect(calls, isEmpty);
  });
}

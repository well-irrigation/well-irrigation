import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/sync/booking_start_receipt.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/session_correction_receipt.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/supabase_command_transport.dart';

import 'c07_start_receipt_store_test.dart'
    show receiptStart, receiptAt, startReceipt;
import 'c07_completion_receipt_store_test.dart' show completionReceipt;

Map<String, Object?> startRead(String state) => {
  'contract': 'get_booking_start_receipt',
  'version': 1,
  'retry_authorized': false,
  'well_id': 'w',
  'booking_id': 'booking',
  'command_id': 'original-start',
  'command_type': 'start_irrigation_session_from_booking',
  'started_at': receiptAt.toIso8601String(),
  'crops': ['crop'],
  'status': state,
  'receipt': state == 'accepted' ? startReceipt() : null,
};
Map<String, Object?> completionRead(String state) => {
  'contract': 'get_completion_receipt',
  'version': 1,
  'retry_authorized': false,
  'well_id': 'w',
  'session_id': 'session',
  'command_id': 'original-completion',
  'command_type': 'complete_irrigation_session',
  'status': state,
  'receipt': state == 'accepted' ? completionReceipt() : null,
};

void main() {
  late SupabaseClient client;
  late SupabaseCommandTransport transport;
  final requests = <http.Request>[];
  Object? reply;
  int status = 200;
  bool fail = false;
  final start = BookingStartReceiptRequest.fromCommand(receiptStart())!;
  const completion = CompletionReceiptRequest(
    accountId: 'a',
    wellId: 'w',
    sessionId: 'session',
    commandId: 'original-completion',
    commandType: 'complete_irrigation_session',
  );
  Future<void> authenticate([String account = 'a']) =>
      client.auth.recoverSession(
        jsonEncode({
          'access_token': 'test-token',
          'token_type': 'bearer',
          'refresh_token': 'refresh-token',
          'user': {'id': account, 'aud': 'authenticated', 'created_at': ''},
        }),
      );
  setUp(() async {
    requests.clear();
    reply = null;
    status = 200;
    fail = false;
    client = SupabaseClient(
      'https://receipt.invalid',
      'test-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (fail) throw http.ClientException('injected transport failure');
        return http.Response(
          jsonEncode(reply),
          status,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    transport = SupabaseCommandTransport(client);
    await authenticate();
  });
  tearDown(() async {
    // No business RPC, token refresh, socket, or real network is used.
    expect(
      requests.every(
        (r) => const [
          '/rest/v1/rpc/get_booking_start_receipt',
          '/rest/v1/rpc/get_completion_receipt',
          '/rest/v1/rpc/get_session_correction_receipt',
          '/rest/v1/rpc/start_irrigation_session',
        ].contains(r.url.path),
      ),
      isTrue,
    );
    await client.dispose();
  });
  group('R6C-4C correction receipt read transport', () {
    late SessionCorrectionReceiptRequest correction;
    Map<String, Object?> accepted() => {
      'contract': 'session_correction', 'version': 1, 'status': 'accepted',
      'tenant_id': 'tenant', 'well_id': 'w', 'session_id': 'session',
      'command_id': 'correction-command', 'correction_id': 'correction',
      'previous_revision': 3, 'operational_revision': 4,
      'actual_started_at': '2026-11-06T05:30:00.000Z',
      'actual_ended_at': '2026-11-06T07:45:00.000Z',
      'accepted_at': '2026-11-06T08:15:00.000Z',
      'financial_status': 'pending',
    };
    Map<String, Object?> wrapper(String state) => {
      'contract': 'get_session_correction_receipt', 'version': 1,
      'session_id': 'session', 'command_id': 'correction-command',
      'command_type': 'correct_irrigation_session',
      'retry_authorized': false, 'status': state,
      'receipt': state == 'accepted' ? accepted() : null,
    };
    void exactRead() {
      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(requests.single.url.path, '/rest/v1/rpc/get_session_correction_receipt');
      expect(requests.single.headers['Content-Profile'] ??
        requests.single.headers['content-profile'], 'api');
      expect(jsonDecode(requests.single.body), correction.arguments);
      expect(jsonDecode(requests.single.body), {
        'p_session_id': 'session', 'p_command_id': 'correction-command',
      });
    }
    setUp(() {
      final request = SessionCorrectionReceiptRequest.fromCommand(CommandEnvelope(
        localId: 'local-correction', commandId: 'correction-command',
        accountId: 'a', wellId: 'w', sequence: 1,
        type: CommandType.correctIrrigationSession,
        occurredAt: DateTime.utc(2026, 11, 6, 8, 15),
        createdLocalAt: DateTime.utc(2026, 11, 6, 8, 16),
        payload: const {
          'p_session_id': 'session', 'p_base_revision': 3,
          'p_reason': 'تصحيح وقت التشغيل الفعلي',
          'p_desired_started_at': '2026-11-06T05:30:00.000Z',
          'p_desired_ended_at': '2026-11-06T07:45:00.000Z',
        },
      ));
      expect(request, isNotNull);
      correction = request!;
      // Validate fixture independently of the transport under test.
      expect(parseSessionCorrectionReceipt(correction, wrapper('accepted')),
        isA<SessionCorrectionReceiptResponse>());
    });
    tearDown(() {
      expect(requests.where((r) =>
        r.url.path != '/rest/v1/rpc/get_session_correction_receipt'), isEmpty,
        reason: 'correction receipt reads never issue a business write or retry');
    });

    test('implements the dedicated read-only correction receipt interface', () {
      expect(transport, isA<SessionCorrectionReceiptTransport>());
      expect(requests, isEmpty);
    });
    for (final entry in {
      'accepted': SessionCorrectionReceiptState.accepted,
      'processing': SessionCorrectionReceiptState.processing,
      'not_found': SessionCorrectionReceiptState.notFound,
      'unresolved': SessionCorrectionReceiptState.unresolved,
    }.entries) {
      test('correction ${entry.key} uses exact receipt RPC once', () async {
        reply = wrapper(entry.key);
        final result = await transport.readSessionCorrectionReceipt(correction);
        expect(result, isA<SessionCorrectionReceiptResponse>());
        final response = result as SessionCorrectionReceiptResponse;
        expect(response.state, entry.value);
        expect(response.receipt, entry.key == 'accepted' ? accepted() : isNull);
        exactRead();
      });
    }
    for (final scope in ['absent', 'wrong']) {
      test('correction auth $scope is rejected locally without HTTP', () async {
        if (scope == 'absent') {
          await client.auth.signOut(scope: SignOutScope.local);
          requests.clear(); // Fixture logout is not a receipt/business request.
        } else {
          await authenticate('other');
        }
        final read = await transport.readSessionCorrectionReceipt(correction);
        expect(read, isA<SessionCorrectionReceiptFailure>());
        expect((read as SessionCorrectionReceiptFailure).kind,
          SessionCorrectionReceiptFailureKind.authentication);
        expect(requests, isEmpty);
      });
    }
    test('correction client exception is network, with no business request', () async {
      fail = true;
      final read = await transport.readSessionCorrectionReceipt(correction);
      expect((read as SessionCorrectionReceiptFailure).kind,
        SessionCorrectionReceiptFailureKind.network);
      exactRead();
    });
    for (final entry in {
      '42501': SessionCorrectionReceiptFailureKind.forbidden,
      '28000': SessionCorrectionReceiptFailureKind.authentication,
      'PGRST301': SessionCorrectionReceiptFailureKind.authentication,
      'PGRST302': SessionCorrectionReceiptFailureKind.authentication,
      '22023': SessionCorrectionReceiptFailureKind.malformed,
      'unavailable': SessionCorrectionReceiptFailureKind.network,
    }.entries) {
      test('correction RPC error ${entry.key} retains failure taxonomy', () async {
        status = 400;
        reply = {'code': entry.key, 'message': 'injected', 'details': null, 'hint': null};
        final read = await transport.readSessionCorrectionReceipt(correction);
        expect(read, isA<SessionCorrectionReceiptFailure>());
        expect((read as SessionCorrectionReceiptFailure).kind, entry.value);
        exactRead();
      });
    }
    for (final entry in <String, Object?>{
      'command_id': 'other', 'retry_authorized': true,
    }.entries) {
      test('correction parser rejects malformed ${entry.key}, not network', () async {
        reply = wrapper('accepted')..[entry.key] = entry.value;
        final read = await transport.readSessionCorrectionReceipt(correction);
        expect((read as SessionCorrectionReceiptFailure).kind,
          SessionCorrectionReceiptFailureKind.malformed);
        exactRead();
      });
    }
    for (final raw in <Object?>[null, <Object?>[], 'invalid']) {
      test('correction non-object $raw is malformed without throwing', () async {
        reply = raw;
        final read = await transport.readSessionCorrectionReceipt(correction);
        expect((read as SessionCorrectionReceiptFailure).kind,
          SessionCorrectionReceiptFailureKind.malformed);
        exactRead();
      });
    }
    // No request outcome grants resend. Firewall and dedicated dispatch,
    // stale_revision handling, UI submit and Outbox mutation are out of scope.
  });

  for (final scope in ['absent', 'wrong', 'after_rpc']) {
    test('executionNotStarted proof $scope', () async {
      if (scope == 'absent') {
        await client.auth.signOut(scope: SignOutScope.local);
        requests.clear(); // Exclude the mocked auth logout used only for fixture setup.
      }
      if (scope == 'wrong') await authenticate('other');
      fail = true;
      final result = await transport.dispatch(const DispatchRequest(
        accountId: 'a', type: CommandType.startIrrigationSession,
        commandId: 'manual', arguments: {'p_well_id': 'w'},
      )) as DispatchFailed;
      expect(result.executionNotStarted, scope != 'after_rpc');
      expect(requests, hasLength(scope == 'after_rpc' ? 1 : 0));
    });
  }
  for (final state in ['accepted', 'processing', 'not_found', 'unresolved']) {
    test('start $state uses only exact original receipt RPC', () async {
      reply = startRead(state);
      final result = await transport.readBookingStartReceipt(
        start,
      ) as BookingStartReceiptResponse;
      expect(result.state, switch (state) {
        'accepted' => BookingStartReceiptState.accepted,
        'processing' => BookingStartReceiptState.processing,
        'not_found' => BookingStartReceiptState.notFound,
        _ => BookingStartReceiptState.unresolved,
      });
      expect(result.receipt, state == 'accepted' ? startReceipt() : isNull);
      expect(requests, hasLength(1));
      expect(
        requests.single.url.path,
        '/rest/v1/rpc/get_booking_start_receipt',
      );
      expect(requests.single.method, 'POST');
      expect(
        requests.single.headers['Content-Profile'] ??
            requests.single.headers['content-profile'],
        'api',
      );
      expect(jsonDecode(requests.single.body), start.arguments);
      expect((reply as Map)['retry_authorized'], isFalse);
    });
    test('completion $state reads only original command and session', () async {
      reply = completionRead(state);
      final result = await transport.readCompletionReceipt(
        completion,
      ) as CompletionReceiptResponse;
      expect(result.state, switch (state) {
        'accepted' => CompletionReceiptState.accepted,
        'processing' => CompletionReceiptState.processing,
        'not_found' => CompletionReceiptState.notFound,
        _ => CompletionReceiptState.unresolved,
      });
      expect(
        result.receipt,
        state == 'accepted' ? completionReceipt() : isNull,
      );
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/rest/v1/rpc/get_completion_receipt');
      expect(jsonDecode(requests.single.body), completion.arguments);
      expect((reply as Map)['retry_authorized'], isFalse);
    });
  }
  for (final (key, value) in <(String, Object?)>[
    ('command_id', 'replacement'),
    ('well_id', 'other'),
    ('booking_id', 'other'),
    ('started_at', receiptAt.add(const Duration(seconds: 1)).toIso8601String()),
    ('crops', ['other']),
    ('retry_authorized', true),
    ('receipt', {'session_id': 'session'}),
    ('status', 'unexpected'),
  ]) {
    test('start invalid $key response is malformed without dispatch', () async {
      reply = startRead('accepted')..[key] = value;
      final result = await transport.readBookingStartReceipt(
        start,
      ) as BookingStartReceiptFailure;
      expect(result.kind, BookingStartReceiptFailureKind.malformed);
      expect(requests, hasLength(1));
    });
  }
  for (final (key, value) in <(String, Object?)>[
    ('command_id', 'replacement'),
    ('session_id', 'other'),
    ('well_id', 'other'),
    ('command_type', 'other'),
    ('retry_authorized', true),
    ('receipt', {'session_id': 'session'}),
    ('status', 'unexpected'),
  ]) {
    test(
      'completion invalid $key response is malformed without dispatch',
      () async {
        reply = completionRead('accepted')..[key] = value;
        final result = await transport.readCompletionReceipt(
          completion,
        ) as CompletionReceiptFailure;
        expect(result.kind, CompletionReceiptFailureKind.malformed);
        expect(requests, hasLength(1));
      },
    );
  }
  for (final raw in [null, [], 'invalid']) {
    test('non-object response $raw cannot authorize either command', () async {
      reply = raw;
      expect(
        (await transport.readBookingStartReceipt(
          start,
        ) as BookingStartReceiptFailure).kind,
        BookingStartReceiptFailureKind.malformed,
      );
      expect(
        (await transport.readCompletionReceipt(
          completion,
        ) as CompletionReceiptFailure).kind,
        CompletionReceiptFailureKind.malformed,
      );
      expect(requests, hasLength(2));
    });
  }
  test('transport failure remains failure and sends no business RPC', () async {
    fail = true;
    expect(
      (await transport.readBookingStartReceipt(
        start,
      ) as BookingStartReceiptFailure).kind,
      BookingStartReceiptFailureKind.network,
    );
    expect(
      (await transport.readCompletionReceipt(
        completion,
      ) as CompletionReceiptFailure).kind,
      CompletionReceiptFailureKind.network,
    );
    expect(requests, hasLength(2));
  });
  for (final (code, sk, ck) in [
    (
      '42501',
      BookingStartReceiptFailureKind.forbidden,
      CompletionReceiptFailureKind.forbidden,
    ),
    (
      'PGRST301',
      BookingStartReceiptFailureKind.authentication,
      CompletionReceiptFailureKind.authentication,
    ),
    (
      '22023',
      BookingStartReceiptFailureKind.malformed,
      CompletionReceiptFailureKind.malformed,
    ),
    (
      'unavailable',
      BookingStartReceiptFailureKind.network,
      CompletionReceiptFailureKind.network,
    ),
  ]) {
    test('RPC failure $code is classified without a business retry', () async {
      status = 400;
      reply = {
        'code': code,
        'message': 'injected',
        'details': null,
        'hint': null,
      };
      expect(
        (await transport.readBookingStartReceipt(
          start,
        ) as BookingStartReceiptFailure).kind,
        sk,
      );
      expect(
        (await transport.readCompletionReceipt(
          completion,
        ) as CompletionReceiptFailure).kind,
        ck,
      );
      expect(requests, hasLength(2));
    });
  }
  test('wrong authenticated account makes no request', () async {
    await authenticate('other');
    expect(
      (await transport.readBookingStartReceipt(
        start,
      ) as BookingStartReceiptFailure).kind,
      BookingStartReceiptFailureKind.authentication,
    );
    expect(
      (await transport.readCompletionReceipt(
        completion,
      ) as CompletionReceiptFailure).kind,
      CompletionReceiptFailureKind.authentication,
    );
    expect(requests, isEmpty);
  });
}

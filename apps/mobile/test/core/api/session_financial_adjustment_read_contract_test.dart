import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/api/session_financial_adjustment.dart';

Map<String, Object?> _state({
  String contract = 'session_financial_state',
  String session = 'session-a',
  bool allowed = true,
  String financialStatus = 'ready',
  String? reasonCode,
  int? approved = 8500,
}) => {
  'contract': contract,
  'version': 1,
  'session_id': session,
  'well_id': 'well-a',
  'original_amount_minor': 10000,
  'system_amount_minor': 9000,
  'approved_amount_minor': approved,
  'effective_amount_minor': approved ?? 9000,
  'paid_amount_minor': 4000,
  'outstanding_amount_minor': (approved ?? 9000) - 4000,
  'operational_revision': 3,
  'system_financial_revision': 2,
  'manual_approval_revision': approved == null ? 0 : 1,
  'can_adjust': allowed,
  'financial_status': financialStatus,
  'reason_code': reasonCode,
  'adjustment_history': approved == null
      ? <Object?>[]
      : [
          {
            'manual_approval_revision': 1,
            'previous_effective_minor': 9000,
            'approved_amount_minor': approved,
            'delta_minor': approved - 9000,
            'reason': 'اعتماد ميداني',
            'actor_name': 'المشغل',
            'accepted_at': '2026-11-10T12:00:00.123456Z',
            'status': 'accepted',
          },
        ],
};

Matcher _failure(SessionFinancialAdjustmentReadFailure kind) =>
    isA<SessionFinancialAdjustmentReadUnavailable>().having(
      (error) => error.kind,
      'kind',
      kind,
    );

void main() {
  group('strict state and capability contracts', () {
    test('state preserves every server-owned amount and revision', () {
      final state = SessionFinancialState.fromContract(
        _state(),
        sessionId: 'session-a',
      );
      expect(state.originalAmountYER, 10000);
      expect(state.systemAmountYER, 9000);
      expect(state.approvedAmountYER, 8500);
      expect(state.effectiveAmountYER, 8500);
      expect(state.paidAmountYER, 4000);
      expect(state.outstandingAmountYER, 4500);
      expect(state.operationalRevision, 3);
      expect(state.systemFinancialRevision, 2);
      expect(state.manualApprovalRevision, 1);
      expect(state.canAdjust, isTrue);
      expect(state.adjustmentHistory.single.deltaYER, -500);
    });

    test('legitimate null financial evidence remains null, never zero', () {
      final raw = _state(approved: null)
        ..['original_amount_minor'] = null
        ..['system_amount_minor'] = null
        ..['effective_amount_minor'] = null
        ..['paid_amount_minor'] = null
        ..['outstanding_amount_minor'] = null
        ..['financial_status'] = 'financial_review_required'
        ..['reason_code'] = 'canonical_charge_required'
        ..['can_adjust'] = false;
      final state = SessionFinancialState.fromContract(
        raw,
        sessionId: 'session-a',
      );
      expect(state.originalAmountYER, isNull);
      expect(state.systemAmountYER, isNull);
      expect(state.effectiveAmountYER, isNull);
      expect(state.paidAmountYER, isNull);
      expect(state.outstandingAmountYER, isNull);
    });

    test(
      'reason cannot hide a missing financial status in the state contract',
      () {
        final raw = _state(reasonCode: 'permission_denied')
          ..remove('financial_status');
        expect(
          () => SessionFinancialState.fromContract(raw, sessionId: 'session-a'),
          throwsA(isA<SessionFinancialAdjustmentReadUnavailable>()),
        );
      },
    );

    test('missing reason field is malformed, not an implicit null', () {
      final raw = _state()..remove('reason_code');
      expect(
        () => SessionFinancialState.fromContract(raw, sessionId: 'session-a'),
        throwsA(isA<SessionFinancialAdjustmentReadUnavailable>()),
      );
    });

    test('PostgreSQL timestamp with explicit UTC offset is valid', () {
      final raw = _state();
      ((raw['adjustment_history'] as List).single as Map)['accepted_at'] =
          '2026-11-10T12:00:00.123456+00:00';
      final value = SessionFinancialState.fromContract(
        raw,
        sessionId: 'session-a',
      );
      expect(
        value.adjustmentHistory.single.acceptedAt,
        DateTime.parse('2026-11-10T12:00:00.123456Z'),
      );
    });

    test('invalid calendar date in history fails closed', () {
      final raw = _state();
      ((raw['adjustment_history'] as List).single as Map)['accepted_at'] =
          '2026-02-30T12:00:00Z';
      expect(
        () => SessionFinancialState.fromContract(raw, sessionId: 'session-a'),
        throwsA(isA<SessionFinancialAdjustmentReadUnavailable>()),
      );
    });

    test('partial financial nullability fails closed', () {
      final raw = _state()..['paid_amount_minor'] = null;
      expect(
        () => SessionFinancialState.fromContract(raw, sessionId: 'session-a'),
        throwsA(isA<SessionFinancialAdjustmentReadUnavailable>()),
      );
    });

    test('manual revision and history chain must agree', () {
      final raw = _state()..['manual_approval_revision'] = 2;
      expect(
        () => SessionFinancialState.fromContract(raw, sessionId: 'session-a'),
        throwsA(isA<SessionFinancialAdjustmentReadUnavailable>()),
      );
    });

    for (final status in {
      'ready': SessionFinancialStatus.ready,
      'locked': SessionFinancialStatus.locked,
      'financial_review_required': SessionFinancialStatus.reviewRequired,
    }.entries) {
      test('capability keeps domain status ${status.key}', () {
        final raw = _state(
          contract: 'session_financial_adjustment_capability',
          financialStatus: status.key,
          allowed: status.key == 'ready',
          reasonCode: status.key == 'ready' ? null : 'server_reason',
        );
        final value = SessionFinancialAdjustmentCapability.fromContract(
          raw,
          sessionId: 'session-a',
        );
        expect(value.status, status.value);
        expect(value.canAdjust, status.key == 'ready');
      });
    }

    test('typed permission denial is data, not a failed read', () {
      final value = SessionFinancialAdjustmentCapability.fromContract({
        'contract': 'session_financial_adjustment_capability',
        'version': 1,
        'session_id': 'session-a',
        'can_adjust': false,
        'reason_code': 'permission_denied',
      }, sessionId: 'session-a');
      expect(value.canAdjust, isFalse);
      expect(value.status, SessionFinancialStatus.permissionDenied);
      expect(value.wellId, isNull);
    });

    for (final mutation in <String, void Function(Map<String, Object?>)>{
      'wrong contract': (raw) => raw['contract'] = 'wrong',
      'wrong version': (raw) => raw['version'] = 2,
      'wrong session': (raw) => raw['session_id'] = 'session-b',
      'double amount': (raw) => raw['effective_amount_minor'] = 8500.0,
      'negative amount': (raw) => raw['paid_amount_minor'] = -1,
      'string revision': (raw) => raw['operational_revision'] = '3',
      'malformed history': (raw) => raw['adjustment_history'] = {'bad': true},
    }.entries) {
      test('${mutation.key} fails closed', () {
        final raw = _state();
        mutation.value(raw);
        expect(
          () => SessionFinancialState.fromContract(raw, sessionId: 'session-a'),
          throwsA(isA<SessionFinancialAdjustmentReadUnavailable>()),
        );
      });
    }
  });

  group('repository identity-safe reads', () {
    late SupabaseClient client;
    late OperationsRepository repository;
    late Object? reply;
    final requests = <http.Request>[];
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
      reply = _state();
      requests.clear();
      gate = null;
      entered = Completer<void>();
      client = SupabaseClient(
        'https://financial-state.invalid',
        'test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests.add(request);
          if (!entered.isCompleted) entered.complete();
          await gate?.future;
          return http.Response(
            jsonEncode(reply),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      repository = OperationsRepository(client);
      await login('account-a');
    });

    tearDown(() => client.dispose());

    test('state read sends only session identity to exact API RPC', () async {
      final state = await repository.getSessionFinancialState(
        accountId: 'account-a',
        sessionId: 'session-a',
      );
      expect(state.effectiveAmountYER, 8500);
      expect(
        requests.single.url.path,
        '/rest/v1/rpc/get_session_financial_state',
      );
      expect(requests.single.headers['content-profile'], 'api');
      expect(jsonDecode(requests.single.body), {'p_session_id': 'session-a'});
    });

    test('capability denial remains a loaded denial', () async {
      reply = _state(
        contract: 'session_financial_adjustment_capability',
        allowed: false,
        financialStatus: 'locked',
        reasonCode: 'protected_distribution',
      );
      final capability = await repository
          .getSessionFinancialAdjustmentCapability(
            accountId: 'account-a',
            sessionId: 'session-a',
          );
      expect(capability.canAdjust, isFalse);
      expect(capability.status, SessionFinancialStatus.locked);
    });

    test('wrong identity sends no request', () async {
      await expectLater(
        repository.getSessionFinancialState(
          accountId: 'account-b',
          sessionId: 'session-a',
        ),
        throwsA(_failure(SessionFinancialAdjustmentReadFailure.authentication)),
      );
      expect(requests, isEmpty);
    });

    test(
      'identity change while reading invalidates returned authority',
      () async {
        gate = Completer<void>();
        final pending = repository.getSessionFinancialState(
          accountId: 'account-a',
          sessionId: 'session-a',
        );
        final assertion = expectLater(
          pending,
          throwsA(
            _failure(SessionFinancialAdjustmentReadFailure.identityChanged),
          ),
        );
        await entered.future;
        await login('account-b');
        gate!.complete();
        await assertion;
      },
    );
  });
}

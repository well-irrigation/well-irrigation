import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/session_financial_adjustment.dart';

CommandEnvelope _command({
  int amount = 0,
  String reason = 'اعتماد صفر',
  Object? op = 3,
  Object? system = 2,
  Object? manual = 1,
}) => CommandEnvelope(
  localId: 'local-a',
  commandId: '11111111-1111-4111-8111-111111111111',
  type: CommandType.adjustSessionFinancialAmount,
  accountId: 'account-a',
  wellId: 'well-a',
  sequence: 1,
  occurredAt: DateTime.utc(2026, 11, 10, 14, 30),
  createdLocalAt: DateTime.utc(2026, 11, 10, 14, 31),
  payload: {
    'p_session_id': 'session-a',
    'p_base_operational_revision': op,
    'p_base_system_financial_revision': system,
    'p_base_manual_approval_revision': manual,
    'p_approved_amount_minor': amount,
    'p_reason': reason,
  },
);

Map<String, Object?> _accepted() => {
  'contract': 'session_financial_adjustment',
  'version': 1,
  'status': 'accepted',
  'session_id': 'session-a',
  'command_id': '11111111-1111-4111-8111-111111111111',
  'adjustment_id': 'adjustment-a',
  'operational_revision': 3,
  'system_financial_revision': 3,
  'manual_approval_revision': 2,
  'previous_effective_minor': 9000,
  'approved_amount_minor': 8500,
  'effective_amount_minor': 8500,
  'delta_minor': -500,
  'accepted_at': '2026-11-10T14:30:01.123456Z',
  'retry_authorized': false,
};

void main() {
  test(
    'command metadata is distinct and session scoped without production',
    () {
      expect(
        CommandType.adjustSessionFinancialAmount.rpcName,
        'adjust_session_financial_amount',
      );
      expect(
        CommandType.adjustSessionFinancialAmount.scope,
        CommandScope.session,
      );
      expect(
        CommandType.adjustSessionFinancialAmount.scopeArgument,
        'p_session_id',
      );
      expect(
        CommandType.adjustSessionFinancialAmount.eventTimeArgument,
        'p_requested_at',
      );
      expect(CommandType.adjustSessionFinancialAmount.produces, isNull);
      expect(
        sessionFinancialHistoryMutation(
          CommandType.adjustSessionFinancialAmount,
        ),
        isTrue,
      );
      expect(
        q137OperationalCommand(CommandType.adjustSessionFinancialAmount),
        isFalse,
      );
    },
  );

  test('request accepts zero and binds exact immutable client facts', () {
    final request = SessionFinancialAdjustmentRequest.fromCommand(_command())!;
    expect(request.approvedAmountYER, 0);
    expect(request.reason, 'اعتماد صفر');
    expect(request.baseOperationalRevision, 3);
    expect(request.baseSystemFinancialRevision, 2);
    expect(request.baseManualApprovalRevision, 1);
    expect(request.command.aggregateLocalId, isNull);
    expect(request.arguments, {
      ...request.command.payload,
      'p_command_id': request.command.commandId,
      'p_requested_at': '2026-11-10T14:30:00.000Z',
    });
    expect(
      request.command.payload.keys,
      unorderedEquals({
        'p_session_id',
        'p_base_operational_revision',
        'p_base_system_financial_revision',
        'p_base_manual_approval_revision',
        'p_approved_amount_minor',
        'p_reason',
      }),
    );
  });

  for (final invalid in <String, CommandEnvelope>{
    'negative amount': _command(amount: -1),
    'blank reason': _command(reason: ' '),
    'untrimmed reason': _command(reason: ' سبب '),
    'double operational revision': _command(op: 3.0),
    'string system revision': _command(system: '2'),
    'bigint max manual revision': _command(manual: 9223372036854775807),
    'negative manual revision': _command(manual: -1),
  }.entries) {
    test('${invalid.key} cannot become a financial request', () {
      expect(
        SessionFinancialAdjustmentRequest.fromCommand(invalid.value),
        isNull,
      );
    });
  }

  test('accepted PostgreSQL timestamp offset is preserved as UTC', () {
    final raw = _accepted()
      ..['accepted_at'] = '2026-11-10T14:30:01.123456+00:00';
    final result = parseSessionFinancialAdjustmentResult(
      SessionFinancialAdjustmentRequest.fromCommand(
        _command(amount: 8500, reason: 'اعتماد جديد'),
      )!,
      raw,
    );
    expect(
      result.accepted!.acceptedAt,
      DateTime.parse('2026-11-10T14:30:01.123456Z'),
    );
  });

  test('accepted parser preserves signed delta and actual fields only', () {
    final result = parseSessionFinancialAdjustmentResult(
      SessionFinancialAdjustmentRequest.fromCommand(
        _command(amount: 8500, reason: 'اعتماد جديد'),
      )!,
      _accepted(),
    );
    expect(result.state, SessionFinancialAdjustmentState.accepted);
    expect(result.accepted, isNotNull);
    expect(result.accepted!.deltaYER, -500);
    expect(result.accepted!.approvedAmountYER, 8500);
    expect(result.accepted!.manualApprovalRevision, 2);
  });

  for (final status in SessionFinancialAdjustmentState.values.where(
    (state) => state != SessionFinancialAdjustmentState.notFound,
  )) {
    test(
      'write state ${status.name} maps only from actual server vocabulary',
      () {
        final request = SessionFinancialAdjustmentRequest.fromCommand(
          _command(
            amount: status == SessionFinancialAdjustmentState.accepted
                ? 8500
                : 0,
            reason: status == SessionFinancialAdjustmentState.accepted
                ? 'اعتماد جديد'
                : 'اعتماد صفر',
          ),
        )!;
        final raw = status == SessionFinancialAdjustmentState.accepted
            ? _accepted()
            : {
                'contract': 'session_financial_adjustment',
                'version': 1,
                'status': status.wireValue,
                'session_id': request.sessionId,
                'command_id': request.commandId,
                'reason_code': 'server_reason',
                'retry_authorized': false,
              };
        final result = parseSessionFinancialAdjustmentResult(request, raw);
        expect(result.state, status);
      },
    );
  }

  for (final change in <String, void Function(Map<String, Object?>)>{
    'wrong contract': (raw) => raw['contract'] = 'wrong',
    'wrong version': (raw) => raw['version'] = 2,
    'wrong session': (raw) => raw['session_id'] = 'session-b',
    'wrong command': (raw) => raw['command_id'] = 'other',
    'invented financial status': (raw) => raw['financial_status'] = 'ready',
    'accepted revision mismatch': (raw) => raw['system_financial_revision'] = 2,
    'accepted amount mismatch': (raw) => raw['approved_amount_minor'] = 8400,
    'double approved amount': (raw) => raw['approved_amount_minor'] = 8500.0,
    'unsigned-only delta': (raw) => raw['delta_minor'] = '−500',
  }.entries) {
    test('${change.key} fails closed', () {
      final raw = _accepted();
      change.value(raw);
      expect(
        () => parseSessionFinancialAdjustmentResult(
          SessionFinancialAdjustmentRequest.fromCommand(
            _command(amount: 8500, reason: 'اعتماد جديد'),
          )!,
          raw,
        ),
        throwsFormatException,
      );
    });
  }
}

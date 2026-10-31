import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';

void main() {
  const request = CompletionReceiptRequest(
    accountId: 'account',
    wellId: 'well',
    sessionId: 'session',
    commandId: 'command',
    commandType: 'complete_irrigation_session',
  );
  Map<String, Object?> result(String state) => {
    'contract': 'get_completion_receipt',
    'version': 1,
    'well_id': 'well',
    'session_id': 'session',
    'command_id': 'command',
    'command_type': 'complete_irrigation_session',
    'status': state,
    'retry_authorized': false,
    'receipt': state == 'accepted'
        ? {
            'session_id': 'session',
            'session_charge_id': 'charge',
            'status': 'closed',
            'ended_at': '2026-10-20T10:00:00Z',
            'actual_seconds': 3600,
            'billable_seconds': 3500,
            'weighted_price_per_hour_minor': 3600,
            'amount_minor': 3500,
            'segments': <Object?>[],
          }
        : null,
  };
  for (final state in ['accepted', 'processing', 'not_found', 'unresolved']) {
    test('read result $state preserves state without authorizing writes', () {
      final read = parseCompletionReceipt(request, result(state));
      expect(read, isA<CompletionReceiptResponse>());
      expect(
        (read as CompletionReceiptResponse).state.name,
        state == 'not_found' ? 'notFound' : state,
      );
    });
  }
  for (final key in [
    'well_id',
    'session_id',
    'command_id',
    'command_type',
    'contract',
    'version',
    'retry_authorized',
  ]) {
    test('foreign or malformed $key never establishes accepted completion', () {
      expect(
        parseCompletionReceipt(request, {
          ...result('accepted'),
          key: 'foreign',
        }),
        isA<CompletionReceiptFailure>(),
      );
    });
  }
  for (final key in ['session_id', 'segments', 'ended_at', 'amount_minor']) {
    test('missing required receipt $key cannot establish success', () {
      final value = result('accepted');
      (value['receipt'] as Map).remove(key);
      expect(
        parseCompletionReceipt(request, value),
        isA<CompletionReceiptFailure>(),
      );
    });
  }
}

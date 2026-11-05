import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/operational_start_receipt.dart';

void main() {
  final command = CommandEnvelope(
    localId: 'local',
    commandId: 'command',
    accountId: 'account',
    wellId: 'well',
    type: CommandType.startOperationalSession,
    sequence: 1,
    occurredAt: DateTime.utc(2026),
    createdLocalAt: DateTime.utc(2026),
    payload: {'p_well_id': 'well'},
  );
  final request = OperationalStartReceiptRequest.fromCommand(command)!;
  Map<String, Object?> response(String status) => {
    'contract': 'get_operational_start_receipt',
    'version': 1,
    'well_id': 'well',
    'command_id': 'command',
    'command_type': 'start_operational_session',
    'retry_authorized': false,
    'status': status,
    'receipt': status == 'accepted'
        ? {'id': 'session', 'occurrence_command_id': 'command'}
        : status == 'rejected'
        ? {'status': 'rejected', 'reason': 'denied'}
        : null,
  };
  test('request carries only original command identity', () {
    expect(request.arguments, {
      'p_well_id': 'well',
      'p_command_id': 'command',
      'p_expected_command_type': 'start_operational_session',
    });
  });
  for (final status in [
    'accepted',
    'processing',
    'not_found',
    'unresolved',
    'rejected',
  ]) {
    test('valid $status never authorizes retry', () {
      expect(
        parseOperationalStartReceipt(request, response(status)),
        isA<OperationalStartReceiptResponse>(),
      );
    });
  }
  for (final key in [
    'contract',
    'version',
    'well_id',
    'command_id',
    'command_type',
    'retry_authorized',
  ]) {
    test('invalid $key is rejected', () {
      expect(
        parseOperationalStartReceipt(
          request,
          response('accepted')..[key] = 'wrong',
        ),
        isA<OperationalStartReceiptFailure>(),
      );
    });
  }
  test('mismatched occurrence rejected', () {
    final raw = response('accepted')
      ..['receipt'] = {'id': 'session', 'occurrence_command_id': 'other'};
    expect(
      parseOperationalStartReceipt(request, raw),
      isA<OperationalStartReceiptFailure>(),
    );
  });
  test('pending state cannot contain receipt', () {
    final raw = response('processing')..['receipt'] = {'id': 'session'};
    expect(
      parseOperationalStartReceipt(request, raw),
      isA<OperationalStartReceiptFailure>(),
    );
  });
  test('durable human intent binds operational start', () {
    expect(q137OperationalCommand(command.type), isTrue);
    final evidence = humanCommandIntentRecord(command);
    expect(jsonDecode(evidence)['action'], 'start_session');
    expect(
      classifyCommandIntent(
        command,
        records: {humanCommandIntentBundleKey(command.localId): evidence},
      ).origin,
      CommandIntentOrigin.provenHuman,
    );
    expect(
      classifyCommandIntent(command).origin,
      CommandIntentOrigin.unresolved,
    );
    expect(
      classifyCommandIntent(
        command,
        records: {humanCommandIntentBundleKey(command.localId): '{}'},
      ).origin,
      CommandIntentOrigin.unresolved,
    );
  });
  for (final key in [
    'well_id',
    'command_id',
    'command_type',
    'occurrence_command_id',
    'id',
    'session_id',
  ]) {
    test('rejected receipt rejects contradictory $key', () {
      final raw = response('rejected');
      (raw['receipt'] as Map<String, Object?>)[key] = 'wrong';
      expect(
        parseOperationalStartReceipt(request, raw),
        isA<OperationalStartReceiptFailure>(),
      );
    });
  }
}

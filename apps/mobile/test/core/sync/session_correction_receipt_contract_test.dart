import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_reference.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/session_correction_receipt.dart';

// Wire source: 20261108002900_session_correction_receipt_read.sql and
// 20261106_r6c2b_session_correction_write_receipt.test.sql.
// Public RPC: api.get_session_correction_receipt(p_session_id,p_command_id).
// No dispatch/transport is constructed: request identity is read-only and
// never authorizes retry, command creation, reservation or any mutation.
CommandEnvelope _command({
  CommandType type = CommandType.correctIrrigationSession,
  String account = 'account-a',
  String commandId = 'correction-command-1',
  Object? session = 'server-session-1',
}) => CommandEnvelope(
  localId: 'local-correction-1',
  commandId: commandId,
  type: type,
  accountId: account,
  wellId: 'well-a',
  sequence: 1,
  occurredAt: DateTime.utc(2026, 11, 6, 8, 15),
  createdLocalAt: DateTime.utc(2026, 11, 6, 8, 16),
  payload: {
    'p_session_id': session,
    'p_base_revision': 3,
    'p_reason': 'تصحيح وقت التشغيل الفعلي',
    'p_desired_started_at': '2026-11-06T05:30:00.000Z',
    'p_desired_ended_at': '2026-11-06T07:45:00.000Z',
  },
);

Map<String, Object?> _accepted() => {
  'contract': 'session_correction',
  'version': 1,
  'status': 'accepted',
  'tenant_id': 'tenant-a',
  'well_id': 'well-a',
  'session_id': 'server-session-1',
  'command_id': 'correction-command-1',
  'correction_id': 'correction-1',
  'previous_revision': 3,
  'operational_revision': 4,
  'actual_started_at': '2026-11-06T05:30:00.000Z',
  'actual_ended_at': '2026-11-06T07:45:00.000Z',
  'accepted_at': '2026-11-06T08:15:01.123456Z',
  'financial_status': 'pending',
};
Map<String, Object?> _wrapper(String status) => {
  'contract': 'get_session_correction_receipt',
  'version': 1,
  'session_id': 'server-session-1',
  'command_id': 'correction-command-1',
  'command_type': 'correct_irrigation_session',
  'status': status,
  'receipt': status == 'accepted' ? _accepted() : null,
  'retry_authorized': false,
};

void main() {
  late SessionCorrectionReceiptRequest request;
  setUp(
    () => request = SessionCorrectionReceiptRequest.fromCommand(_command())!,
  );

  void malformed(Object? raw) {
    final result = parseSessionCorrectionReceipt(request, raw);
    expect(result, isA<SessionCorrectionReceiptFailure>());
    expect(
      (result as SessionCorrectionReceiptFailure).kind,
      SessionCorrectionReceiptFailureKind.malformed,
    );
  }

  group('PostgreSQL bigint correction revision boundaries', () {
    const serverBigintMax = 9223372036854775807;
    const maxCorrectableBaseRevision = 9223372036854775806;

    CommandEnvelope withBase(int revision) =>
        _command()..payload['p_base_revision'] = revision;

    test('largest correctable base constructs a request without narrowing server range', () {
      final value = SessionCorrectionReceiptRequest.fromCommand(
        withBase(maxCorrectableBaseRevision),
      );
      expect(value, isNotNull);
      expect(value!.baseRevision, maxCorrectableBaseRevision);
    });

    test(
      'largest correctable base accepts the literal bigint-max next revision',
      () {
        final value = SessionCorrectionReceiptRequest.fromCommand(
          withBase(maxCorrectableBaseRevision),
        );
        expect(value, isNotNull);
        final receipt = _accepted()
          ..['previous_revision'] = maxCorrectableBaseRevision
          ..['operational_revision'] = serverBigintMax;
        final result = parseSessionCorrectionReceipt(
          value!,
          _wrapper('accepted')..['receipt'] = receipt,
        );
        expect(result, isA<SessionCorrectionReceiptResponse>());
        final response = result as SessionCorrectionReceiptResponse;
        expect(response.state, SessionCorrectionReceiptState.accepted);
        expect(
          response.receipt!['previous_revision'],
          maxCorrectableBaseRevision,
        );
        expect(response.receipt!['operational_revision'], serverBigintMax);
      },
    );

    test('bigint max base must not construct a receipt request', () {
      expect(
        SessionCorrectionReceiptRequest.fromCommand(withBase(serverBigintMax)),
        isNull,
        reason: 'baseRevision=9223372036854775807 has no representable next server revision',
      );
    });

    test('negative base remains invalid', () {
      expect(SessionCorrectionReceiptRequest.fromCommand(withBase(-1)), isNull);
    });

    for (final value in [-9223372036854775808, -1]) {
      test('valid request rejects negative operational revision $value', () {
        malformed(
          _wrapper('accepted')
            ..['receipt'] = (_accepted()..['operational_revision'] = value),
        );
      });
    }
    // Native Dart int cannot represent a positive integer above signed int64.
    // Do not substitute double/String/BigInt for the wire int contract.
    // Expected next revision above uses a literal, never baseRevision + 1.
  });

  test(
    'request preserves original identity and exact SQL read arguments only',
    () {
      final command = _command();
      final original = {...command.payload};
      final value = SessionCorrectionReceiptRequest.fromCommand(command)!;
      expect(value.accountId, 'account-a');
      expect(value.sessionId, 'server-session-1');
      expect(value.commandId, 'correction-command-1');
      expect(value.arguments, {
        'p_session_id': 'server-session-1',
        'p_command_id': 'correction-command-1',
      });
      expect(value.arguments, value.arguments);
      expect(command.payload, original);
      expect(command.commandId, 'correction-command-1');
      expect(command.occurredAt, DateTime.utc(2026, 11, 6, 8, 15));
    },
  );

  for (final entry in <String, CommandEnvelope Function()>{
    'wrong type': () => _command(type: CommandType.pauseIrrigationSession),
    'empty account': () => _command(account: ''),
    'blank account': () => _command(account: '  '),
    'empty command': () => _command(commandId: ''),
    'blank command': () => _command(commandId: '  '),
    'empty session': () => _command(session: ''),
    'blank session': () => _command(session: '  '),
    'null session': () => _command(session: null),
    'integer session': () => _command(session: 1),
    'local reference': () => _command(
      session: const CommandReference(
        localId: 'local-session',
        kind: EntityKind.session,
      ).toJson(),
    ),
    // Simulate malformed persisted payload after the generic scope guard.
    'missing session': () {
      final c = _command();
      c.payload.remove('p_session_id');
      return c;
    },
  }.entries) {
    test('invalid request ${entry.key} cannot become receipt identity', () {
      expect(
        SessionCorrectionReceiptRequest.fromCommand(entry.value()),
        isNull,
      );
    });
  }

  for (final entry in {
    'accepted': SessionCorrectionReceiptState.accepted,
    'processing': SessionCorrectionReceiptState.processing,
    'not_found': SessionCorrectionReceiptState.notFound,
    'unresolved': SessionCorrectionReceiptState.unresolved,
  }.entries) {
    test('valid ${entry.key} is distinct and never retry authorization', () {
      final SessionCorrectionReceiptRead read = parseSessionCorrectionReceipt(
        request,
        _wrapper(entry.key),
      );
      expect(read, isA<SessionCorrectionReceiptResponse>());
      final result = read as SessionCorrectionReceiptResponse;
      expect(result.state, entry.value);
      expect(result.receipt, entry.key == 'accepted' ? _accepted() : isNull);
      // Wire false is mandatory; true/missing/malformed are tested below.
    });
    for (final value in <Object?>[true, null, 'false', 0]) {
      test('${entry.key} refuses retry_authorized=$value', () {
        malformed(_wrapper(entry.key)..['retry_authorized'] = value);
      });
    }
    test('${entry.key} requires retry_authorized explicitly', () {
      malformed(_wrapper(entry.key)..remove('retry_authorized'));
    });
  }

  for (final status in ['processing', 'not_found', 'unresolved']) {
    test('$status cannot smuggle an accepted receipt', () {
      malformed(_wrapper(status)..['receipt'] = _accepted());
    });
  }
  for (final status in <Object?>['rejected', 'unknown', '', null, 1]) {
    test(
      'unknown/rejected state $status is malformed, never durable rejection',
      () {
        malformed(_wrapper('not_found')..['status'] = status);
      },
    );
  }
  for (final field in [
    'contract',
    'version',
    'session_id',
    'command_id',
    'command_type',
    'status',
    'receipt',
  ]) {
    test(
      'wrapper missing $field fails closed',
      () => malformed(_wrapper('accepted')..remove(field)),
    );
  }
  for (final entry in <String, Object?>{
    'contract': 'another_contract',
    'version': 2,
    'session_id': 'other-session',
    'command_id': 'other-command',
    'command_type': 'complete_irrigation_session',
  }.entries) {
    test(
      'wrapper contradictory ${entry.key} is malformed',
      () => malformed(_wrapper('accepted')..[entry.key] = entry.value),
    );
    for (final value in <Object?>[null, 1, true, <Object?>[]]) {
      // version=1 is valid; use a string instead for its wrong-type case.
      final wrong = entry.key == 'version' && value == 1 ? '1' : value;
      test(
        'wrapper ${entry.key} wrong type $wrong is malformed',
        () => malformed(_wrapper('accepted')..[entry.key] = wrong),
      );
    }
  }
  for (final raw in <Object?>[null, 'json', 1, <Object?>[]]) {
    test('non-object wrapper $raw is malformed', () => malformed(raw));
  }
  for (final raw in <Object?>[null, 'receipt', 1, <Object?>[]]) {
    test(
      'accepted requires object receipt: $raw',
      () => malformed(_wrapper('accepted')..['receipt'] = raw),
    );
  }

  for (final field in _accepted().keys) {
    test('accepted requires $field', () {
      malformed(
        _wrapper('accepted')..['receipt'] = (_accepted()..remove(field)),
      );
    });
    test('accepted rejects null $field', () {
      malformed(
        _wrapper('accepted')..['receipt'] = (_accepted()..[field] = null),
      );
    });
    test('accepted rejects wrong-type $field', () {
      malformed(
        _wrapper('accepted')
          ..['receipt'] = (_accepted()..[field] = <Object?>[]),
      );
    });
  }
  for (final entry in <String, Object?>{
    'contract': 'wrong',
    'version': '1',
    'status': 'applied',
    'tenant_id': '',
    'well_id': 'other-well',
    'correction_id': '',
    'session_id': 'other-session',
    'command_id': 'other-command',
    'previous_revision': 2,
    'operational_revision': 5,
    'financial_status': 'applied',
    'actual_started_at': '2026-11-06T05:30:01Z',
    'actual_ended_at': '2026-11-06T07:45:01Z',
  }.entries) {
    test('accepted contradicts original binding ${entry.key}', () {
      malformed(
        _wrapper('accepted')
          ..['receipt'] = (_accepted()..[entry.key] = entry.value),
      );
    });
  }
  for (final field in ['previous_revision', 'operational_revision']) {
    for (final value in <Object>[-1, 3.5, '3']) {
      test(
        'accepted $field must be a valid integer: $value',
        () => malformed(
          _wrapper('accepted')..['receipt'] = (_accepted()..[field] = value),
        ),
      );
    }
  }
  for (final field in ['actual_started_at', 'actual_ended_at', 'accepted_at']) {
    for (final value in [
      'bad-time',
      '2026-11-31T08:00:00Z',
      '2026-11-06T08:15:00',
    ]) {
      test(
        'strict receipt timestamp $field rejects $value',
        () => malformed(
          _wrapper('accepted')..['receipt'] = (_accepted()..[field] = value),
        ),
      );
    }
  }
  for (final status in ['processing', 'not_found', 'unresolved']) {
    test('$status requires an explicit null receipt field', () {
      malformed(_wrapper(status)..remove('receipt'));
    });
  }
  for (final version in <Object>[2, 1.0, true]) {
    test('accepted receipt version must be integer 1: $version', () {
      malformed(
        _wrapper('accepted')
          ..['receipt'] = (_accepted()..['version'] = version),
      );
    });
  }
  test(
    'review state cannot replace original historical pending financial status',
    () {
      malformed(
        _wrapper('accepted')
          ..['receipt'] = (_accepted()
            ..['financial_status'] = 'financial_review_required'),
      );
    },
  );
  test(
    'equivalent offsets bind by instant and preserve original historical JSON',
    () {
      final receipt = _accepted()
        ..['actual_started_at'] = '2026-11-06T08:30:00+03:00'
        ..['actual_ended_at'] = '2026-11-06T02:15:00-05:30'
        ..['accepted_at'] = '2026-11-06T11:15:01.123456+03:00';
      final read = parseSessionCorrectionReceipt(
        request,
        _wrapper('accepted')..['receipt'] = receipt,
      );
      expect(read, isA<SessionCorrectionReceiptResponse>());
      expect((read as SessionCorrectionReceiptResponse).receipt, receipt);
    },
  );
  test('accepted receipt is immutable and detached from caller input', () {
    final receipt = _accepted();
    final read = parseSessionCorrectionReceipt(
      request,
      _wrapper('accepted')..['receipt'] = receipt,
    ) as SessionCorrectionReceiptResponse;
    expect(
      () => read.receipt!['previous_revision'] = 100,
      throwsUnsupportedError,
    );
    receipt['previous_revision'] = 100;
    expect(read.receipt!['previous_revision'], 3);
  });
  test(
    'transport failure taxonomy remains separate from valid receipt states',
    () {
      expect(SessionCorrectionReceiptFailureKind.values.toSet(), {
        SessionCorrectionReceiptFailureKind.authentication,
        SessionCorrectionReceiptFailureKind.forbidden,
        SessionCorrectionReceiptFailureKind.network,
        SessionCorrectionReceiptFailureKind.malformed,
      });
      for (final kind in SessionCorrectionReceiptFailureKind.values) {
        final SessionCorrectionReceiptRead read =
            SessionCorrectionReceiptFailure(kind);
        expect(read, isNot(isA<SessionCorrectionReceiptResponse>()));
        expect((read as SessionCorrectionReceiptFailure).kind, kind);
      }
    },
  );
}

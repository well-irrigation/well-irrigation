import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/session_correction_receipt.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import '../sync/sync_test_support.dart' show SequentialIdGenerator;

final _now = DateTime.utc(2026, 11, 9, 9);
final _start = DateTime.utc(2026, 11, 8, 2, 30);
final _end = DateTime.utc(2026, 11, 8, 4, 45);
const _correctionId = '00000000-0000-4000-8000-000000000004';

// أي محاولة تعديل تُسجل حتى لو أخفاها خطأ يتوقعه اختبار fail-closed.
class _ReadGuardStore extends InMemoryOutboxStore {
  bool readOnly = false;
  final attemptedWrites = <String>[];
  void guard(String operation) {
    if (readOnly) {
      attemptedWrites.add(operation);
      throw StateError('observation_must_not_mutate:$operation');
    }
  }

  @override
  Future<int> nextSequence(String accountId) {
    guard('nextSequence');
    return super.nextSequence(accountId);
  }

  @override
  Future<CommandEnvelope> insert(CommandEnvelope command) {
    guard('insert');
    return super.insert(command);
  }

  @override
  Future<CommandEnvelope> insertSessionCorrection(CommandEnvelope command) {
    guard('insertSessionCorrection');
    return super.insertSessionCorrection(command);
  }

  @override
  Future<bool> claim(
    String accountId,
    String localId, {
    required DateTime attemptedAt,
  }) {
    guard('claim');
    return super.claim(accountId, localId, attemptedAt: attemptedAt);
  }

  @override
  Future<void> releaseForRetry(
    String accountId,
    String localId, {
    required String error,
    required DateTime attemptedAt,
  }) {
    guard('releaseForRetry');
    return super.releaseForRetry(
      accountId,
      localId,
      error: error,
      attemptedAt: attemptedAt,
    );
  }

  @override
  Future<void> markConfirmed(
    String accountId,
    String localId, {
    required Map<String, Object?> serverResponse,
    required DateTime attemptedAt,
  }) {
    guard('markConfirmed');
    return super.markConfirmed(
      accountId,
      localId,
      serverResponse: serverResponse,
      attemptedAt: attemptedAt,
    );
  }

  @override
  Future<void> markNeedsReview(
    String accountId,
    String localId, {
    required String error,
    required DateTime attemptedAt,
    Map<String, Object?>? serverResponse,
  }) {
    guard('markNeedsReview');
    return super.markNeedsReview(
      accountId,
      localId,
      error: error,
      attemptedAt: attemptedAt,
      serverResponse: serverResponse,
    );
  }
}

// لقطة قيم مستقلة تكشف التعديلات الموضعية أيضًا، لا مقارنة مراجع متغيرة.
String _snapshot(CommandEnvelope command) => jsonEncode({
  'localId': command.localId,
  'commandId': command.commandId,
  'accountId': command.accountId,
  'wellId': command.wellId,
  'type': command.type.storageValue,
  'sequence': command.sequence,
  'occurredAt': command.occurredAt.toIso8601String(),
  'createdLocalAt': command.createdLocalAt.toIso8601String(),
  'payload': command.payload,
  'aggregate': command.aggregateLocalId,
  'prerequisites': command.prerequisites,
  'localContext': command.localContext,
  'status': command.status.storageValue,
  'retryCount': command.retryCount,
  'lastError': command.lastError,
  'lastAttemptAt': command.lastAttemptAt?.toIso8601String(),
  'nextAttemptAt': command.nextAttemptAt?.toIso8601String(),
  'serverResponse': command.serverResponse,
});

Map<String, Object?> _receipt(CommandEnvelope command) => {
  'contract': 'session_correction', 'version': 1, 'status': 'accepted',
  'tenant_id': 'tenant-a',
  'well_id': 'well-1',
  'session_id': 'server-session-1',
  'command_id': command.commandId, 'correction_id': _correctionId,
  'previous_revision': 3, 'operational_revision': 4,
  'actual_started_at': _start.toIso8601String(),
  'actual_ended_at': _end.toIso8601String(),
  'accepted_at': '2026-11-09T09:01:00.000Z',
  // لقطة تاريخية وقت القبول؛ ليست الحالة المالية الحالية.
  'financial_status': 'pending',
};

SessionCorrectionReceiptRead _parse(CommandEnvelope command, Object? receipt) =>
    parseSessionCorrectionReceipt(
      SessionCorrectionReceiptRequest.fromCommand(command)!,
      {
        'contract': 'get_session_correction_receipt',
        'version': 1,
        'session_id': 'server-session-1',
        'command_id': command.commandId,
        'command_type': 'correct_irrigation_session',
        'retry_authorized': false,
        'status': 'accepted',
        'receipt': receipt,
      },
    );

// نموذج المشاهدة المستقبلي يعيد استخدام أنواع العقد القائم:
// command: CommandEnvelope
// request: SessionCorrectionReceiptRequest
// accepted: SessionCorrectionReceiptResponse? (accepted فقط، بعد parser)
Future<SessionCorrectionCommandObservation?> _read(
  OfflineSessionCoordinator coordinator,
  CommandEnvelope command, {
  String account = 'account-a',
  String well = 'well-1',
  String session = 'server-session-1',
  String? localId,
  String? commandId,
}) => coordinator.readSessionCorrectionCommand(
  accountId: account,
  wellId: well,
  sessionId: session,
  localId: localId ?? command.localId,
  commandId: commandId ?? command.commandId,
);

void main() {
  late _ReadGuardStore store;
  late OutboxRepository repository;
  late OfflineSessionCoordinator coordinator;
  late CommandEnvelope command;
  late List<String> before;
  var schedulerCalls = 0;
  var activeEvents = 0;
  var completionEvents = 0;

  setUp(() async {
    store = _ReadGuardStore();
    repository = OutboxRepository(
      store: store,
      idGenerator: SequentialIdGenerator(),
      clock: () => _now,
    );
    await repository.initialize();
    command = await repository.enqueueSessionCorrection(
      accountId: 'account-a',
      wellId: 'well-1',
      sessionId: 'server-session-1',
      baseRevision: 3,
      reason: 'تصحيح وقت التشغيل الفعلي',
      desiredStartedAt: _start,
      desiredEndedAt: _end,
    );
    schedulerCalls = activeEvents = completionEvents = 0;
    coordinator = OfflineSessionCoordinator(
      store: store,
      commandQueuedScheduler: (_) async {
        schedulerCalls++;
        return true;
      },
    );
    final active = coordinator.activeSessionStream.listen(
      (_) => activeEvents++,
    );
    final completion = coordinator.completionResultStream.listen(
      (_) => completionEvents++,
    );
    addTearDown(active.cancel);
    addTearDown(completion.cancel);
  });
  tearDown(() async {
    if (store.readOnly) {
      expect(
        (await store.allCommands('account-a')).map(_snapshot).toList(),
        before,
      );
    }
    expect(store.attemptedWrites, isEmpty);
    expect(schedulerCalls, 0);
    expect(activeEvents, 0);
    expect(completionEvents, 0);
    expect(coordinator.currentActiveSession, isNull);
    expect(coordinator.canSyncNow, isFalse);
    coordinator.dispose();
    await store.close();
  });

  Future<void> freeze() async {
    before = (await store.allCommands('account-a')).map(_snapshot).toList();
    store.readOnly = true;
  }

  Future<void> claim() async {
    expect(
      await store.claim('account-a', command.localId, attemptedAt: _now),
      isTrue,
    );
  }

  Future<void> confirm(Map<String, Object?> receipt) async {
    await claim();
    await store.markConfirmed(
      'account-a',
      command.localId,
      serverResponse: receipt,
      attemptedAt: _now,
    );
  }

  void identity(
    SessionCorrectionCommandObservation observation,
    CommandStatus status,
  ) {
    expect(observation.command.localId, command.localId);
    expect(observation.command.commandId, command.commandId);
    expect(observation.command.accountId, 'account-a');
    expect(observation.command.wellId, 'well-1');
    expect(observation.command.occurredAt, command.occurredAt);
    expect(observation.command.payload, command.payload);
    expect(observation.command.status, status);
    final request = observation.request;
    expect(request, isA<SessionCorrectionReceiptRequest>());
    expect(request.accountId, 'account-a');
    expect(request.wellId, 'well-1');
    expect(request.sessionId, 'server-session-1');
    expect(request.commandId, command.commandId);
    expect(request.baseRevision, 3);
    expect(request.desiredStartedAt, _start);
    expect(request.desiredEndedAt, _end);
  }

  test('A pending read exposes durable facts without acceptance', () async {
    await freeze();
    final value = (await _read(coordinator, command))!;
    identity(value, CommandStatus.pending);
    expect(value.accepted, isNull);
  });
  test(
    'B dispatching is not acceptance and read never releases or claims it',
    () async {
      await claim();
      await freeze();
      final value = (await _read(coordinator, command))!;
      identity(value, CommandStatus.dispatching);
      expect(value.accepted, isNull);
    },
  );
  test(
    'C review never exposes acceptance even with accepted-looking response',
    () async {
      await claim();
      await store.markNeedsReview(
        'account-a',
        command.localId,
        error: 'session_correction_receipt_unresolved',
        attemptedAt: _now,
        serverResponse: _receipt(command),
      );
      await freeze();
      final value = (await _read(coordinator, command))!;
      identity(value, CommandStatus.review);
      expect(value.accepted, isNull);
      expect(value.command.lastError, 'session_correction_receipt_unresolved');
    },
  );
  test(
    'D confirmed read exposes parser-bound historical acceptance evidence',
    () async {
      final raw = _receipt(command);
      final parsed = _parse(command, raw);
      expect(parsed, isA<SessionCorrectionReceiptResponse>());
      await confirm(raw);
      await freeze();
      final value = (await _read(coordinator, command))!;
      identity(value, CommandStatus.confirmed);
      expect(value.accepted, isA<SessionCorrectionReceiptResponse>());
      final accepted = value.accepted!;
      expect(accepted.state, SessionCorrectionReceiptState.accepted);
      expect(
        accepted.receipt,
        (parsed as SessionCorrectionReceiptResponse).receipt,
      );
      final receipt = accepted.receipt!;
      expect(receipt['correction_id'], _correctionId);
      expect(receipt['command_id'], command.commandId);
      expect(receipt['previous_revision'], 3);
      expect(receipt['operational_revision'], 4);
      expect(DateTime.parse(receipt['actual_started_at'] as String), _start);
      expect(DateTime.parse(receipt['actual_ended_at'] as String), _end);
      expect(
        DateTime.parse(receipt['accepted_at'] as String),
        DateTime.utc(2026, 11, 9, 9, 1),
      );
      expect(
        receipt['financial_status'],
        'pending',
      ); // Historical evidence only.
      expect(
        () => receipt['correction_id'] = 'changed',
        throwsUnsupportedError,
      );
    },
  );

  for (final field in ['commandId', 'wellId', 'sessionId']) {
    test(
      'wrong $field fails closed without exposing or mutating row',
      () async {
        await freeze();
        await expectLater(
          _read(
            coordinator,
            command,
            commandId: field == 'commandId' ? 'another-command-id' : null,
            well: field == 'wellId' ? 'well-2' : 'well-1',
            session: field == 'sessionId'
                ? 'another-session'
                : 'server-session-1',
          ),
          throwsStateError,
        );
      },
    );
  }
  test('wrong account cannot leak the original row', () async {
    await freeze();
    expect(await _read(coordinator, command, account: 'account-b'), isNull);
  });
  test(
    'missing local row returns null rather than a synthetic state',
    () async {
      await freeze();
      expect(
        await _read(coordinator, command, localId: 'missing-local-id'),
        isNull,
      );
    },
  );
  test('another command type cannot be read as a correction', () async {
    final other = await repository.enqueue(
      accountId: 'account-a',
      wellId: 'well-1',
      type: CommandType.createFarmer,
      occurredAt: _now,
      payload: const {'p_well_id': 'well-1', 'p_full_name': 'مزارع'},
    );
    await freeze();
    await expectLater(_read(coordinator, other), throwsStateError);
  });

  final malformed = <String, Map<String, Object?>>{
    'missing contract': {},
    'command binding': {'command_id': 'other-command'},
    'session binding': {'session_id': 'other-session'},
    'well binding': {'well_id': 'well-2'},
    'previous revision': {'previous_revision': 2},
    'new revision': {'operational_revision': 5},
    'start instant': {'actual_started_at': '2026-11-08T02:31:00.000Z'},
    'end instant': {'actual_ended_at': '2026-11-08T04:46:00.000Z'},
    'invalid acceptedAt': {'accepted_at': 'not-a-time'},
    'financial snapshot rewritten': {'financial_status': 'applied'},
  };
  for (final entry in malformed.entries) {
    test(
      'confirmed malformed ${entry.key} has no usable acceptance proof',
      () async {
        final raw = entry.key == 'missing contract'
            ? <String, Object?>{}
            : {..._receipt(command), ...entry.value};
        expect(_parse(command, raw), isA<SessionCorrectionReceiptFailure>());
        await confirm(raw);
        await freeze();
        await expectLater(_read(coordinator, command), throwsStateError);
      },
    );
  }

  test('confirmed without serverResponse cannot imply acceptance', () async {
    // Fixture corruption: reuse the real enqueued identity in an isolated store.
    final isolated = _ReadGuardStore();
    await isolated.initialize();
    await isolated.insert(command.copyWith(status: CommandStatus.confirmed));
    final observer = OfflineSessionCoordinator(store: isolated);
    final snapshot = _snapshot(
      (await isolated.commandByLocalId('account-a', command.localId))!,
    );
    isolated.readOnly = true;
    try {
      await expectLater(_read(observer, command), throwsStateError);
      expect(
        _snapshot(
          (await isolated.commandByLocalId('account-a', command.localId))!,
        ),
        snapshot,
      );
      expect(isolated.attemptedWrites, isEmpty);
    } finally {
      observer.dispose();
      await isolated.close();
    }
  });

  test(
    'repeated reads see current durable state without returning cached pending',
    () async {
      final pending = (await _read(coordinator, command))!;
      expect(pending.command.status, CommandStatus.pending);
      await confirm(_receipt(command));
      await freeze();
      final confirmed = (await _read(coordinator, command))!;
      identity(confirmed, CommandStatus.confirmed);
      expect(confirmed.accepted, isNotNull);
      expect(pending.command.status, CommandStatus.pending);
    },
  );
}

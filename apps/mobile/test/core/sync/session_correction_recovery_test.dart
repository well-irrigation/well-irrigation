import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';
import 'package:well_irrigation_mobile/core/sync/session_correction_receipt.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

final _requestedAt = DateTime.utc(2026, 11, 6, 8, 15);
const _account = 'account-a';
const _commandId = 'correction-command-1';
const _payload = <String, Object?>{
  'p_session_id': 'server-session-1',
  'p_base_revision': 3,
  'p_reason': 'تصحيح وقت التشغيل الفعلي',
  'p_desired_started_at': '2026-11-06T05:30:00.000Z',
  'p_desired_ended_at': '2026-11-06T07:45:00.000Z',
};
CommandEnvelope _command() => CommandEnvelope(
  localId: 'local-correction-1',
  commandId: _commandId,
  accountId: _account,
  wellId: 'well-a',
  sequence: 1,
  type: CommandType.correctIrrigationSession,
  occurredAt: _requestedAt,
  createdLocalAt: _requestedAt,
  payload: _payload,
);
Map<String, Object?> _accepted() => {
  'contract': 'session_correction',
  'version': 1,
  'status': 'accepted',
  'tenant_id': 'tenant-a',
  'well_id': 'well-a',
  'session_id': 'server-session-1',
  'command_id': _commandId,
  'correction_id': 'correction-1',
  'previous_revision': 3,
  'operational_revision': 4,
  'actual_started_at': '2026-11-06T05:30:00.000Z',
  'actual_ended_at': '2026-11-06T07:45:00.000Z',
  'accepted_at': '2026-11-06T08:16:00.000Z',
  'financial_status': 'pending',
};
DispatchAccepted _directAccepted() =>
    DispatchAccepted(response: _accepted(), entityId: null);
SessionCorrectionReceiptRead _acceptedRead() => parseSessionCorrectionReceipt(
  SessionCorrectionReceiptRequest.fromCommand(_command())!,
  {
    'contract': 'get_session_correction_receipt',
    'version': 1,
    'session_id': 'server-session-1',
    'command_id': _commandId,
    'command_type': 'correct_irrigation_session',
    'retry_authorized': false,
    'status': 'accepted',
    'receipt': _accepted(),
  },
);
const _ambiguous = DispatchFailed(
  disposition: FailureDisposition.retry,
  executionNotStarted: false,
  message: 'ClientException: connection lost',
);

class _CorrectionTransport
    implements CommandTransport, SessionCorrectionReceiptTransport {
  final dispatchRequests = <DispatchRequest>[];
  final receiptRequests = <SessionCorrectionReceiptRequest>[];
  final events = <String>[];
  DispatchResult nextDispatch = _directAccepted();
  SessionCorrectionReceiptRead nextRead =
      const SessionCorrectionReceiptResponse(
        SessionCorrectionReceiptState.processing,
        null,
      );
  int get dispatchCount => dispatchRequests.length;
  int get receiptReadCount => receiptRequests.length;

  @override
  Future<DispatchResult> dispatch(DispatchRequest request) async {
    dispatchRequests.add(request);
    events.add('write');
    expect(request.type, CommandType.correctIrrigationSession);
    expect(request.commandId, _commandId);
    expect(request.accountId, _account);
    expect(request.arguments, {
      ..._payload,
      'p_command_id': _commandId,
      'p_requested_at': '2026-11-06T08:15:00.000Z',
    });
    return nextDispatch;
  }

  @override
  Future<SessionCorrectionReceiptRead> readSessionCorrectionReceipt(
    SessionCorrectionReceiptRequest request,
  ) async {
    receiptRequests.add(request);
    events.add('read');
    expect(request.accountId, _account);
    expect(request.wellId, 'well-a');
    expect(request.commandId, _commandId);
    expect(request.sessionId, 'server-session-1');
    expect(request.baseRevision, 3);
    expect(request.arguments, {
      'p_session_id': 'server-session-1',
      'p_command_id': _commandId,
    });
    return nextRead;
  }
}

Future<void> _identityPreserved(OutboxStore store) async {
  final row = await store.commandByLocalId(_account, 'local-correction-1');
  expect(row, isNotNull);
  expect(row!.localId, 'local-correction-1');
  expect(row.commandId, _commandId);
  expect(row.occurredAt, _requestedAt);
  expect(row.payload, _payload);
  // A correction does not produce a new entity mapping of any kind.
  expect(await store.mappings(_account), isEmpty);
}

void main() {
  late InMemoryOutboxStore store;
  late _CorrectionTransport transport;
  late SyncEngine engine;
  late DateTime now;
  setUp(() async {
    now = DateTime.utc(2026, 11, 6, 8, 16);
    store = InMemoryOutboxStore();
    await store.initialize();
    await store.insert(_command());
    transport = _CorrectionTransport();
    engine = SyncEngine(store: store, transport: transport, clock: () => now);
    expect(
      (await store.commandByLocalId(_account, 'local-correction-1'))!.status,
      CommandStatus.pending,
    );
  });
  tearDown(() => store.close());

  Future<CommandEnvelope> row() async =>
      (await store.commandByLocalId(_account, 'local-correction-1'))!;
  void later() => now = now.add(const Duration(minutes: 3));
  Future<void> uncertain() async {
    transport.nextDispatch = _ambiguous;
    await engine.run(_account);
    expect(
      transport.dispatchCount,
      1,
      reason: 'fresh correction must use dedicated write lane',
    );
    expect((await row()).status, isNot(CommandStatus.confirmed));
    expect((await row()).status, isNot(CommandStatus.review));
    await _identityPreserved(store);
  }

  test('fresh correction dispatches once and confirms only valid direct acceptance', () async {
    final report = await engine.run(_account);
    expect(
      transport.dispatchCount,
      1,
      reason: 'fresh correction expected dispatchCount=1',
    );
    expect(transport.receiptReadCount, 0);
    expect((await row()).status, CommandStatus.confirmed);
    expect((await row()).serverResponse, _accepted());
    expect(report.attempted, 1);
    expect(report.confirmed, 1);
    expect(report.retryScheduled, 0);
    expect(report.needsReview, 0);
    await _identityPreserved(store);
    later();
    await engine.run(_account);
    expect(transport.dispatchCount, 1);
  });

  test(
    'malformed direct accepted result requires receipt before any second write',
    () async {
      transport.nextDispatch = const DispatchAccepted(
        response: {'status': 'accepted'},
        entityId: null,
      );
      await engine.run(_account);
      expect(transport.dispatchCount, 1);
      expect((await row()).status, isNot(CommandStatus.confirmed));
      expect((await row()).status, isNot(CommandStatus.review));
      later();
      transport.nextRead = _acceptedRead();
      await engine.run(_account);
      expect(transport.dispatchCount, 1);
      expect(transport.receiptReadCount, greaterThanOrEqualTo(1));
      expect(transport.events.first, 'write');
      expect(transport.events.skip(1), everyElement('read'));
      expect((await row()).status, CommandStatus.confirmed);
      expect((await row()).serverResponse, _accepted());
      await _identityPreserved(store);
    },
  );

  test(
    'generic SQLSTATE 40001 remains retry even for stale_revision identity',
    () {
      expect(
        classifySqlFailure('40001', 'stale_revision'),
        FailureDisposition.retry,
      );
    },
  );

  test(
    'correction stale_revision is durable review with no retry or receipt',
    () async {
      transport.nextDispatch = const DispatchFailed(
        disposition: FailureDisposition.retry,
        code: '40001',
        message: '40001: stale_revision',
      );
      final report = await engine.run(_account);
      expect(transport.dispatchCount, 1);
      expect((await row()).status, CommandStatus.review);
      expect(report.retryScheduled, 0);
      expect(report.needsReview, 1);
      expect(report.canRetryWithoutHelp, isFalse);
      expect(report.awaitsHumanDecision, isTrue);
      expect(transport.receiptReadCount, 0);
      later();
      final second = await engine.run(_account);
      expect(transport.dispatchCount, 1);
      expect(transport.receiptReadCount, 0);
      expect((await row()).status, CommandStatus.review);
      expect(second.canRetryWithoutHelp, isFalse);
      await _identityPreserved(store);
    },
  );

  test(
    'non-stale retryable 40001 requires receipt-first recovery',
    () async {
      transport.nextDispatch = const DispatchFailed(
        disposition: FailureDisposition.retry,
        code: '40001',
        message: '40001: serialization_failure',
      );
      final report = await engine.run(_account);
      expect(transport.dispatchCount, 1);
      expect((await row()).status, CommandStatus.dispatching);
      expect(report.needsReview, 0);
      expect(report.awaitsHumanDecision, isFalse);
      expect(report.retryScheduled, 0);
      later();
      transport.nextRead = _acceptedRead();
      await engine.run(_account);
      expect(transport.events, ['write', 'read']);
      expect(transport.dispatchCount, 1);
      expect(transport.receiptReadCount, 1);
      expect((await row()).status, CommandStatus.confirmed);
      expect((await row()).serverResponse, _accepted());
      await _identityPreserved(store);
    },
  );

  for (final outcome in ['processing', 'not_found', 'unresolved', 'network', 'authentication']) {
    test('non-stale 40001 reads $outcome receipt before any second write', () async {
      transport.nextDispatch = const DispatchFailed(
        disposition: FailureDisposition.retry,
        code: '40001',
        message: '40001: serialization_failure',
      );
      await engine.run(_account);
      expect(transport.dispatchCount, 1);
      later();
      transport.nextRead = switch (outcome) {
        'processing' => const SessionCorrectionReceiptResponse(
            SessionCorrectionReceiptState.processing, null),
        'not_found' => const SessionCorrectionReceiptResponse(
            SessionCorrectionReceiptState.notFound, null),
        'unresolved' => const SessionCorrectionReceiptResponse(
            SessionCorrectionReceiptState.unresolved, null),
        'network' => const SessionCorrectionReceiptFailure(
            SessionCorrectionReceiptFailureKind.network),
        _ => const SessionCorrectionReceiptFailure(
            SessionCorrectionReceiptFailureKind.authentication),
      };
      await engine.run(_account);
      expect(transport.events, ['write', 'read']);
      expect(transport.dispatchCount, 1);
      expect(transport.receiptReadCount, 1);
      expect(
        (await row()).status,
        outcome == 'not_found' || outcome == 'unresolved'
            ? CommandStatus.review
            : CommandStatus.dispatching,
      );
      await _identityPreserved(store);
    });
  }

  test('executionNotStarted proof permits later same-command write without receipt', () async {
    transport.nextDispatch = const DispatchFailed(
      disposition: FailureDisposition.retry,
      executionNotStarted: true,
      message: 'authentication_not_started',
    );
    final first = await engine.run(_account);
    expect(transport.dispatchCount, 1);
    expect(transport.receiptReadCount, 0);
    expect((await row()).status, isNot(CommandStatus.review));
    expect((await row()).status, isNot(CommandStatus.confirmed));
    expect(first.needsReview, 0);
    later();
    transport.nextDispatch = _directAccepted();
    await engine.run(_account);
    expect(transport.dispatchCount, 2);
    expect(transport.receiptReadCount, 0);
    expect((await row()).status, CommandStatus.confirmed);
    expect(transport.events, ['write', 'write']);
    await _identityPreserved(store);
  });

  test('ambiguous write is reconciled from original accepted receipt, never resend', () async {
    await uncertain();
    transport.nextRead = _acceptedRead();
    later();
    final report = await engine.run(_account);
    expect(transport.dispatchCount, 1);
    expect(transport.receiptReadCount, greaterThanOrEqualTo(1));
    expect(transport.events.first, 'write');
    expect(transport.events.skip(1), everyElement('read'));
    expect((await row()).status, CommandStatus.confirmed);
    expect((await row()).serverResponse, _accepted());
    expect(report.needsReview, 0);
    await _identityPreserved(store);
  });

  for (final outcome in ['processing', 'network']) {
    test(
      '$outcome recovery remains readable later without any new write',
      () async {
        await uncertain();
        transport.nextRead = outcome == 'processing'
            ? const SessionCorrectionReceiptResponse(
                SessionCorrectionReceiptState.processing,
                null,
              )
            : const SessionCorrectionReceiptFailure(
                SessionCorrectionReceiptFailureKind.network,
              );
        later();
        final report = await engine.run(_account);
        final reads = transport.receiptReadCount;
        expect(reads, greaterThanOrEqualTo(1));
        expect(transport.dispatchCount, 1);
        expect((await row()).status, isNot(CommandStatus.confirmed));
        expect((await row()).status, isNot(CommandStatus.review));
        expect(report.canRetryWithoutHelp, isTrue);
        expect(report.awaitsHumanDecision, isFalse);
        later();
        await engine.run(_account);
        expect(transport.receiptReadCount, greaterThan(reads));
        expect(transport.dispatchCount, 1);
        expect((await row()).status, isNot(CommandStatus.review));
        await _identityPreserved(store);
      },
    );
  }

  for (final outcome in ['not_found', 'unresolved', 'forbidden', 'malformed']) {
    test(
      '$outcome receipt after uncertainty requires review, never resend',
      () async {
        await uncertain();
        transport.nextRead = switch (outcome) {
          'not_found' => const SessionCorrectionReceiptResponse(
            SessionCorrectionReceiptState.notFound,
            null,
          ),
          'unresolved' => const SessionCorrectionReceiptResponse(
            SessionCorrectionReceiptState.unresolved,
            null,
          ),
          'forbidden' => const SessionCorrectionReceiptFailure(
            SessionCorrectionReceiptFailureKind.forbidden,
          ),
          _ => const SessionCorrectionReceiptFailure(
            SessionCorrectionReceiptFailureKind.malformed,
          ),
        };
        later();
        final report = await engine.run(_account);
        expect(transport.receiptReadCount, greaterThanOrEqualTo(1));
        expect(transport.dispatchCount, 1);
        expect((await row()).status, CommandStatus.review);
        expect(report.awaitsHumanDecision, isTrue);
        expect(report.canRetryWithoutHelp, isFalse);
        final reads = transport.receiptReadCount;
        later();
        await engine.run(_account);
        expect(transport.dispatchCount, 1);
        expect(transport.receiptReadCount, reads);
        expect((await row()).status, CommandStatus.review);
        await _identityPreserved(store);
      },
    );
  }

  for (final processing in [false, true]) {
    test(
      'SQLite restart of stale dispatching uses receipt only: processing=$processing',
      () async {
        sqfliteFfiInit();
        final dir = await Directory.systemTemp.createTemp(
          'correction-recovery-',
        );
        SqliteOutboxStore open() => SqliteOutboxStore(
          databasePath: '${dir.path}/outbox.db',
          sqfliteFactory: databaseFactoryFfi,
          singleInstance: false,
        );
        var disk = open();
        try {
          await disk.initialize();
          await disk.insert(_command());
          final attempt = DateTime.utc(2026, 11, 6, 8, 16);
          expect(
            await disk.claim(
              _account,
              'local-correction-1',
              attemptedAt: attempt,
            ),
            isTrue,
          );
          final claimed = (await disk.commandByLocalId(
            _account,
            'local-correction-1',
          ))!;
          expect(claimed.status, CommandStatus.dispatching);
          expect(claimed.lastAttemptAt, attempt);
          await disk.close();
          disk = open();
          await disk.initialize();
          await _identityPreserved(disk);
          expect(
            (await disk.commandByLocalId(
              _account,
              'local-correction-1',
            ))!.status,
            CommandStatus.dispatching,
          );
          final recoveredTransport = _CorrectionTransport()
            ..nextRead = processing
                ? const SessionCorrectionReceiptResponse(
                    SessionCorrectionReceiptState.processing,
                    null,
                  )
                : _acceptedRead();
          var restartNow = attempt.add(const Duration(minutes: 3));
          final restarted = SyncEngine(
            store: disk,
            transport: recoveredTransport,
            clock: () => restartNow,
            staleClaimTimeout: const Duration(minutes: 2),
          );
          final report = await restarted.run(_account);
          expect(recoveredTransport.dispatchCount, 0);
          expect(
            recoveredTransport.receiptReadCount,
            1,
            reason: 'stale dispatching must read receipt after restart, never release for blind resend',
          );
          if (processing) {
            final pending = (await disk.commandByLocalId(
              _account,
              'local-correction-1',
            ))!;
            expect(pending.status, isNot(CommandStatus.confirmed));
            expect(pending.status, isNot(CommandStatus.review));
            expect(report.canRetryWithoutHelp, isTrue);
            restartNow = restartNow.add(const Duration(minutes: 3));
            await restarted.run(_account);
            expect(recoveredTransport.receiptReadCount, greaterThan(1));
            expect(recoveredTransport.dispatchCount, 0);
          } else {
            final confirmed = (await disk.commandByLocalId(
              _account,
              'local-correction-1',
            ))!;
            expect(confirmed.status, CommandStatus.confirmed);
            expect(confirmed.serverResponse, _accepted());
            expect(report.confirmed, 1);
          }
          await _identityPreserved(disk);
        } finally {
          await disk.close();
          await dir.delete(recursive: true);
        }
      },
    );
  }
  // Existing R6C-4A sync_engine_test.dart continues to guard the generic lane
  // with a transport lacking correction receipt capability, including an
  // independent payment behind the excluded correction. It is not modified.
  // No UI, finance, store schema or general SQLSTATE classification is changed.
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/command_id_generator.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/session_financial_adjustment.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

class _Ids implements IdGenerator {
  var next = 0;
  @override
  String newId() =>
      '00000000-0000-4000-8000-${(++next).toString().padLeft(12, '0')}';
}

Future<void> _matrix(
  OutboxStore Function() currentStore, {
  Future<void> Function()? reopen,
  required SessionFinancialAdjustmentState finalState,
}) async {
  var store = currentStore();
  await store.initialize();
  final repository = OutboxRepository(
    store: store,
    idGenerator: _Ids(),
    clock: () => DateTime.utc(2026, 11, 10, 15),
  );
  final command = await repository.enqueueSessionFinancialAdjustment(
    accountId: 'account-a',
    wellId: 'well-a',
    sessionId: 'session-a',
    baseOperationalRevision: 3,
    baseSystemFinancialRevision: 2,
    baseManualApprovalRevision: 1,
    approvedAmountYER: 0,
    reason: '  اعتماد صفر  ',
  );
  expect(command.status, CommandStatus.pending);
  expect(command.payload['p_reason'], 'اعتماد صفر');
  expect(command.payload['p_approved_amount_minor'], 0);
  expect(command.aggregateLocalId, isNull);
  await reopen?.call();
  store = currentStore();
  final pending = await store.commandByLocalId('account-a', command.localId);
  expect(pending!.status, CommandStatus.pending);
  expect(pending.payload, command.payload);
  expect(pending.commandId, command.commandId);
  expect(pending.occurredAt, command.occurredAt);

  expect(
    await store.claim(
      'account-a',
      command.localId,
      attemptedAt: DateTime.utc(2026, 11, 10, 15, 1),
    ),
    isTrue,
  );
  await store.releaseForRetry(
    'account-a',
    command.localId,
    error: 'financial_adjustment_preflight_not_sent',
    attemptedAt: DateTime.utc(2026, 11, 10, 15, 1),
  );
  expect(
    await store.claim(
      'account-a',
      command.localId,
      attemptedAt: DateTime.utc(2026, 11, 10, 15, 2),
    ),
    isTrue,
  );
  await store.recordSessionFinancialAdjustmentObservation(
    accountId: 'account-a',
    localId: command.localId,
    state: SessionFinancialAdjustmentState.processing,
    observedAt: DateTime.utc(2026, 11, 10, 15, 2),
  );

  await reopen?.call();
  store = currentStore();
  final processing = await store.commandByLocalId('account-a', command.localId);
  expect(processing, isNotNull);
  expect(processing!.status, CommandStatus.dispatching);
  expect(processing.commandId, command.commandId);
  expect(processing.occurredAt, command.occurredAt);
  expect(processing.payload, command.payload);
  expect(processing.serverResponse?['status'], 'processing');
  expect(processing.lastError, isNull);

  final response = SessionFinancialAdjustmentResponse(
    state: finalState,
    accepted: finalState == SessionFinancialAdjustmentState.accepted
        ? AcceptedSessionFinancialAdjustment(
            adjustmentId: 'adjustment-a',
            operationalRevision: 3,
            systemFinancialRevision: 3,
            manualApprovalRevision: 2,
            previousEffectiveYER: 9000,
            approvedAmountYER: 0,
            effectiveAmountYER: 0,
            deltaYER: -9000,
            acceptedAt: DateTime.utc(2026, 11, 10, 15, 3),
          )
        : null,
  );
  final result = sessionFinancialStoredResult(response);
  await store.recordSessionFinancialAdjustmentObservation(
    accountId: 'account-a',
    localId: command.localId,
    state: finalState,
    observedAt: DateTime.utc(2026, 11, 10, 15, 3),
    result: result,
  );
  await reopen?.call();
  store = currentStore();
  final terminal = await store.commandByLocalId('account-a', command.localId);
  expect(
    terminal!.status,
    finalState == SessionFinancialAdjustmentState.accepted
        ? CommandStatus.confirmed
        : finalState == SessionFinancialAdjustmentState.processing
        ? CommandStatus.dispatching
        : CommandStatus.review,
  );
  expect(terminal.serverResponse, result);
  expect(terminal.payload, command.payload);
  expect(terminal.commandId, command.commandId);
  expect(terminal.occurredAt, command.occurredAt);

  final second =
      await OutboxRepository(
        store: store,
        idGenerator: _Ids()..next = 2,
        clock: () => DateTime.utc(2026, 11, 10, 16),
      ).enqueueSessionFinancialAdjustment(
        accountId: 'account-a',
        wellId: 'well-a',
        sessionId: 'session-a',
        baseOperationalRevision: 4,
        baseSystemFinancialRevision: 3,
        baseManualApprovalRevision: 1,
        approvedAmountYER: 8000,
        reason: 'اعتماد جديد',
      );
  expect(second.commandId, isNot(command.commandId));
  expect(second.localId, isNot(command.localId));
  expect(terminal.payload['p_approved_amount_minor'], 0);
  expect(second.payload['p_approved_amount_minor'], 8000);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  for (final state in SessionFinancialAdjustmentState.values) {
    test('InMemory ${state.wireValue} survives reopen', () async {
      final store = InMemoryOutboxStore();
      await _matrix(() => store, reopen: store.reopen, finalState: state);
      await store.close();
    });

    test('SQLite ${state.wireValue} survives a new store instance', () async {
      final dir = await Directory.systemTemp.createTemp('financial-adjustment');
      final path = p.join(dir.path, 'outbox.db');
      var store = SqliteOutboxStore(
        databasePath: path,
        sqfliteFactory: databaseFactoryFfi,
      );
      final holders = <SqliteOutboxStore>[store];
      try {
        await _matrix(
          () => store,
          finalState: state,
          reopen: () async {
            await store.close();
            store = SqliteOutboxStore(
              databasePath: path,
              sqfliteFactory: databaseFactoryFfi,
            );
            holders.add(store);
            await store.initialize();
          },
        );
      } finally {
        for (final value in holders) {
          await value.close();
        }
        await dir.delete(recursive: true);
      }
    });
  }
}

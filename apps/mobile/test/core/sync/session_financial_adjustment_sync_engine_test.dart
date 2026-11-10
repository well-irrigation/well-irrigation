import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/sync/command_id_generator.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/session_financial_adjustment.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

class _Ids implements IdGenerator {
  var value = 0;
  @override
  String newId() =>
      '10000000-0000-4000-8000-${(++value).toString().padLeft(12, '0')}';
}

class _FinancialTransport
    implements CommandTransport, SessionFinancialAdjustmentTransport {
  final writes = <SessionFinancialAdjustmentRequest>[];
  final receipts = <SessionFinancialAdjustmentReceiptRequest>[];
  final writeResults = <SessionFinancialAdjustmentRead>[];
  final receiptResults = <SessionFinancialAdjustmentRead>[];

  @override
  Future<DispatchResult> dispatch(DispatchRequest request) =>
      throw StateError('generic dispatch forbidden');

  @override
  Future<SessionFinancialAdjustmentRead> adjustSessionFinancialAmount(
    SessionFinancialAdjustmentRequest request,
  ) async {
    writes.add(request);
    return writeResults.removeAt(0);
  }

  @override
  Future<SessionFinancialAdjustmentRead> readSessionFinancialAdjustmentReceipt(
    SessionFinancialAdjustmentReceiptRequest request,
  ) async {
    receipts.add(request);
    return receiptResults.removeAt(0);
  }
}

Map<String, Object?> _accepted(SessionFinancialAdjustmentRequest request) => {
  'contract': 'session_financial_adjustment',
  'version': 1,
  'status': 'accepted',
  'session_id': request.sessionId,
  'command_id': request.commandId,
  'adjustment_id': 'adjustment-a',
  'operational_revision': 3,
  'system_financial_revision': 3,
  'manual_approval_revision': 2,
  'previous_effective_minor': 9000,
  'approved_amount_minor': 8500,
  'effective_amount_minor': 8500,
  'delta_minor': -500,
  'accepted_at': '2026-11-10T16:00:00.000Z',
  'retry_authorized': false,
};

Future<({OutboxStore store, SyncEngine engine})> _fixture(
  _FinancialTransport transport, {
  required bool sqlite,
}) async {
  final dir = sqlite
      ? await Directory.systemTemp.createTemp('financial-sync')
      : null;
  final OutboxStore store = sqlite
      ? SqliteOutboxStore(
          databasePath: '${dir!.path}/outbox.db',
          sqfliteFactory: databaseFactoryFfi,
        )
      : InMemoryOutboxStore();
  addTearDown(() async {
    await store.close();
    await dir?.delete(recursive: true);
  });
  await store.initialize();
  await OutboxRepository(
    store: store,
    idGenerator: _Ids(),
    clock: () => DateTime.utc(2026, 11, 10, 15),
  ).enqueueSessionFinancialAdjustment(
    accountId: 'account-a',
    wellId: 'well-a',
    sessionId: 'session-a',
    baseOperationalRevision: 3,
    baseSystemFinancialRevision: 2,
    baseManualApprovalRevision: 1,
    approvedAmountYER: 8500,
    reason: 'اعتماد جديد',
  );
  return (
    store: store,
    engine: SyncEngine(
      store: store,
      transport: transport,
      clock: () => DateTime.utc(2026, 11, 10, 16),
      staleClaimTimeout: Duration.zero,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite engine' : 'InMemory engine', () {
      test(
        'restart before and after receipt never writes the request again',
        () async {
          final transport = _FinancialTransport()
            ..writeResults.add(
              const SessionFinancialAdjustmentReadFailure(
                SessionFinancialAdjustmentReadFailureKind.network,
              ),
            );
          final fixture = await _fixture(transport, sqlite: sqlite);
          await fixture.engine.run('account-a');
          OutboxStore store = fixture.store;
          Future<void> restart() async {
            if (store is SqliteOutboxStore) {
              final path = (store as SqliteOutboxStore).databasePath!;
              await store.close();
              store = SqliteOutboxStore(
                databasePath: path,
                sqfliteFactory: databaseFactoryFfi,
              );
              addTearDown(store.close);
              await store.initialize();
            } else {
              await (store as InMemoryOutboxStore).reopen();
            }
          }

          await restart();
          transport.receiptResults.add(
            const SessionFinancialAdjustmentResponse(
              state: SessionFinancialAdjustmentState.processing,
            ),
          );
          await SyncEngine(store: store, transport: transport).run('account-a');
          await restart();
          final command = (await store.allCommands('account-a')).single;
          final request = SessionFinancialAdjustmentRequest.fromCommand(
            command,
          )!;
          transport.receiptResults.add(
            parseSessionFinancialAdjustmentResult(request, _accepted(request)),
          );
          await SyncEngine(store: store, transport: transport).run('account-a');
          expect(transport.writes, hasLength(1));
          expect(transport.receipts, hasLength(2));
          expect(
            (await store.allCommands('account-a')).single.status,
            CommandStatus.confirmed,
          );
        },
      );

      test(
        'unresolved financial request does not block an ordinary human start',
        () async {
          final transport = _FinancialTransport()
            ..writeResults.add(
              const SessionFinancialAdjustmentResponse(
                state: SessionFinancialAdjustmentState.unresolved,
              ),
            );
          final fixture = await _fixture(transport, sqlite: sqlite);
          await fixture.engine.run('account-a');
          final start = await OutboxRepository(store: fixture.store).prepare(
            accountId: 'account-a',
            wellId: 'well-a',
            type: CommandType.startOperationalSession,
            occurredAt: DateTime.utc(2026, 11, 10, 17),
            payload: {
              'p_well_id': 'well-a',
              'p_pump_id': 'pump-a',
              'p_farm_id': 'farm-a',
              'p_farmer_well_account_id': 'farmer-a',
              'p_energy_source': 'solar',
              'p_crops': <String>[],
            },
          );
          await fixture.store.insertBundle(
            accountId: 'account-a',
            key: humanCommandIntentBundleKey(start.localId),
            value: humanCommandIntentRecord(start),
            commands: [start],
          );
          expect(await fixture.store.allCommands('account-a'), hasLength(2));
        },
      );

      test(
        'repeated local preflight failures still permit first actual dispatch',
        () async {
          final transport = _FinancialTransport()
            ..writeResults.addAll([
              const SessionFinancialAdjustmentReadFailure(
                SessionFinancialAdjustmentReadFailureKind.authentication,
                executionNotStarted: true,
              ),
              const SessionFinancialAdjustmentReadFailure(
                SessionFinancialAdjustmentReadFailureKind.authentication,
                executionNotStarted: true,
              ),
              const SessionFinancialAdjustmentResponse(
                state: SessionFinancialAdjustmentState.processing,
              ),
            ]);
          final fixture = await _fixture(transport, sqlite: sqlite);
          await fixture.engine.run('account-a');
          await fixture.engine.run('account-a');
          expect(
            (await fixture.store.allCommands('account-a')).single.status,
            CommandStatus.pending,
          );
          await fixture.engine.run('account-a');
          expect(transport.writes, hasLength(3));
          expect(transport.receipts, isEmpty);
          expect(
            transport.writes.map((r) => r.commandId).toSet(),
            hasLength(1),
          );
        },
      );

      test('ambiguous write retains uncertainty then reads receipt without second write', () async {
        final transport = _FinancialTransport()
          ..writeResults.add(
            const SessionFinancialAdjustmentReadFailure(
              SessionFinancialAdjustmentReadFailureKind.network,
            ),
          )
          ..receiptResults.add(
            const SessionFinancialAdjustmentResponse(
              state: SessionFinancialAdjustmentState.notFound,
            ),
          );
        final fixture = await _fixture(transport, sqlite: sqlite);
        await fixture.engine.run('account-a');
        var row = (await fixture.store.allCommands('account-a')).single;
        expect(row.status, CommandStatus.dispatching);
        expect(row.serverResponse, isNull);
        await fixture.engine.run('account-a');
        row = (await fixture.store.allCommands('account-a')).single;
        expect(transport.writes, hasLength(1));
        expect(transport.receipts, hasLength(1));
        expect(row.status, CommandStatus.review);
        expect(row.serverResponse?['status'], 'not_found');
      });

      test(
        'processing persists dispatching and later uses receipt only',
        () async {
          final transport = _FinancialTransport()
            ..writeResults.add(
              const SessionFinancialAdjustmentResponse(
                state: SessionFinancialAdjustmentState.processing,
              ),
            )
            ..receiptResults.add(
              const SessionFinancialAdjustmentResponse(
                state: SessionFinancialAdjustmentState.processing,
              ),
            );
          final fixture = await _fixture(transport, sqlite: sqlite);
          await fixture.engine.run('account-a');
          var row = (await fixture.store.allCommands('account-a')).single;
          expect(row.status, CommandStatus.dispatching);
          expect(row.serverResponse?['status'], 'processing');
          await fixture.engine.run('account-a');
          row = (await fixture.store.allCommands('account-a')).single;
          expect(transport.writes, hasLength(1));
          expect(transport.receipts, hasLength(1));
          expect(row.status, CommandStatus.dispatching);
        },
      );

      for (final state in [
        SessionFinancialAdjustmentState.notFound,
        SessionFinancialAdjustmentState.unresolved,
        SessionFinancialAdjustmentState.validationError,
        SessionFinancialAdjustmentState.conflictRequest,
        SessionFinancialAdjustmentState.conflictRevision,
        SessionFinancialAdjustmentState.financialReviewRequired,
        SessionFinancialAdjustmentState.locked,
        SessionFinancialAdjustmentState.permissionDenied,
      ]) {
        test(
          '${state.wireValue} becomes review and never writes again',
          () async {
            final transport = _FinancialTransport()
              ..writeResults.add(
                SessionFinancialAdjustmentResponse(state: state),
              );
            final fixture = await _fixture(transport, sqlite: sqlite);
            await fixture.engine.run('account-a');
            await fixture.engine.run('account-a');
            final row = (await fixture.store.allCommands('account-a')).single;
            expect(row.status, CommandStatus.review);
            expect(transport.writes, hasLength(1));
            expect(transport.receipts, isEmpty);
          },
        );
      }

      test('receipt authentication failure after prior attempt cannot release write', () async {
        final transport = _FinancialTransport()
          ..writeResults.add(
            const SessionFinancialAdjustmentResponse(
              state: SessionFinancialAdjustmentState.processing,
            ),
          )
          ..receiptResults.add(
            const SessionFinancialAdjustmentReadFailure(
              SessionFinancialAdjustmentReadFailureKind.authentication,
              executionNotStarted: true,
            ),
          );
        final fixture = await _fixture(transport, sqlite: sqlite);
        await fixture.engine.run('account-a');
        await fixture.engine.run('account-a');
        final row = (await fixture.store.allCommands('account-a')).single;
        expect(row.status, CommandStatus.dispatching);
        expect(row.serverResponse?['status'], 'processing');
        expect(transport.writes, hasLength(1));
      });

      test(
        'unresolved financial command is not an active-session producer',
        () async {
          final transport = _FinancialTransport();
          final fixture = await _fixture(transport, sqlite: sqlite);
          final command = (await fixture.store.allCommands('account-a')).single;
          expect(command.aggregateLocalId, isNull);
          expect(command.type.produces, isNull);
          expect(
            await ActiveSessionProjector(
              store: fixture.store,
            ).activeSessions('account-a', now: DateTime.utc(2026, 11, 10, 17)),
            isEmpty,
          );
        },
      );

      test(
        'accepted result is canonical and terminal without projection math',
        () async {
          final transport = _FinancialTransport();
          final fixture = await _fixture(transport, sqlite: sqlite);
          final command = (await fixture.store.allCommands('account-a')).single;
          final request = SessionFinancialAdjustmentRequest.fromCommand(
            command,
          )!;
          transport.writeResults.add(
            parseSessionFinancialAdjustmentResult(request, _accepted(request)),
          );
          await fixture.engine.run('account-a');
          final row = (await fixture.store.allCommands('account-a')).single;
          expect(row.status, CommandStatus.confirmed);
          expect(row.serverResponse?['status'], 'accepted');
          expect(row.serverResponse?['approved_amount_minor'], 8500);
          expect(row.serverResponse?['delta_minor'], -500);
          expect(transport.writes, hasLength(1));
        },
      );
    });
  }
}

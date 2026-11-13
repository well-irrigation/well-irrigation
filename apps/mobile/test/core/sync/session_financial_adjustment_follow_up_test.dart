import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/session_financial_adjustment.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite' : 'InMemory', () {
      late OutboxStore store;
      late OutboxRepository repository;
      Directory? directory;
      final now = DateTime.utc(2026, 11, 10, 15, 1, 2, 3, 4);
      void bind() =>
          repository = OutboxRepository(store: store, clock: () => now);
      setUp(() async {
        directory = sqlite
            ? await Directory.systemTemp.createTemp('financial-follow-up')
            : null;
        store = sqlite
            ? SqliteOutboxStore(
                databasePath: '${directory!.path}/outbox.db',
                sqfliteFactory: databaseFactoryFfi,
              )
            : InMemoryOutboxStore();
        await store.initialize();
        bind();
      });
      tearDown(() async {
        await store.close();
        await directory?.delete(recursive: true);
      });
      Future<void> reopen() async {
        await store.close();
        if (sqlite) {
          store = SqliteOutboxStore(
            databasePath: '${directory!.path}/outbox.db',
            sqfliteFactory: databaseFactoryFfi,
          );
          await store.initialize();
        } else {
          await (store as InMemoryOutboxStore).reopen();
        }
        bind();
      }

      Future<CommandEnvelope> seed({
        String account = 'account',
        String well = 'well',
        String session = 'session',
        String state = 'pending',
      }) async {
        final c = await repository.enqueueSessionFinancialAdjustment(
          accountId: account,
          wellId: well,
          sessionId: session,
          baseOperationalRevision: 3,
          baseSystemFinancialRevision: 2,
          baseManualApprovalRevision: 1,
          approvedAmountYER: 0,
          reason: '  اعتماد الصفر  ',
        );
        if (state == 'pending') return c;
        await store.claim(account, c.localId, attemptedAt: now);
        if (state == 'dispatching') return c;
        final outcome = SessionFinancialAdjustmentState.fromWire(state)!;
        final response = SessionFinancialAdjustmentResponse(
          state: outcome,
          accepted: outcome == SessionFinancialAdjustmentState.accepted
              ? AcceptedSessionFinancialAdjustment(
                  adjustmentId: 'adjustment',
                  operationalRevision: 3,
                  systemFinancialRevision: 3,
                  manualApprovalRevision: 2,
                  previousEffectiveYER: 9000,
                  approvedAmountYER: 0,
                  effectiveAmountYER: 0,
                  deltaYER: -9000,
                  acceptedAt: now,
                )
              : null,
        );
        await store.recordSessionFinancialAdjustmentObservation(
          accountId: account,
          localId: c.localId,
          state: outcome,
          observedAt: now,
          result: sessionFinancialStoredResult(response),
        );
        return c;
      }

      Future<CommandEnvelope> corruptScope(
        String? well,
        String state, {
        String account = 'account',
        String session = 'session',
        CommandType type = CommandType.adjustSessionFinancialAmount,
      }) async {
        final c = await repository.prepare(
          accountId: account,
          wellId: well,
          type: type,
          occurredAt: now,
          payload: {
            'p_session_id': session,
            'p_base_operational_revision': 3,
            'p_base_system_financial_revision': 2,
            'p_base_manual_approval_revision': 1,
            'p_approved_amount_minor': 0,
            'p_reason': 'اعتماد الصفر',
          },
        );
        await store.insert(c);
        if (state == 'pending') return c;
        await store.claim(account, c.localId, attemptedAt: now);
        if (state == 'dispatching') return c;
        final outcome = SessionFinancialAdjustmentState.fromWire(state)!;
        final response = SessionFinancialAdjustmentResponse(
          state: outcome,
          accepted: outcome == SessionFinancialAdjustmentState.accepted
              ? AcceptedSessionFinancialAdjustment(
                  adjustmentId: 'adjustment',
                  operationalRevision: 3,
                  systemFinancialRevision: 3,
                  manualApprovalRevision: 2,
                  previousEffectiveYER: 9000,
                  approvedAmountYER: 0,
                  effectiveAmountYER: 0,
                  deltaYER: -9000,
                  acceptedAt: now,
                )
              : null,
        );
        await store.recordSessionFinancialAdjustmentObservation(
          accountId: account,
          localId: c.localId,
          state: outcome,
          observedAt: now,
          result: sessionFinancialStoredResult(response),
        );
        return c;
      }

      Future<SessionFinancialAdjustmentFollowUpLookup> read(
        String id, {
        String account = 'account',
        String well = 'well',
        String session = 'session',
      }) => repository.readSessionFinancialAdjustmentFollowUp(
        accountId: account,
        wellId: well,
        sessionId: session,
        localId: id,
      );
      Future<SessionFinancialAdjustmentFollowUpLookup> blocking() =>
          repository.findBlockingSessionFinancialAdjustmentFollowUp(
            accountId: 'account',
            wellId: 'well',
            sessionId: 'session',
          );

      for (final well in <String?>[null, '', '   ', ' well ']) {
        for (final state in [
          'pending',
          'dispatching',
          'processing',
          'unresolved',
          'not_found',
          'accepted',
        ]) {
          test(
            'corrupt well $well $state blocks before and after reopen',
            () async {
              final c = await corruptScope(well, state);
              final before = await store.commandByLocalId('account', c.localId);
              for (var pass = 0; pass < 2; pass++) {
                if (pass == 1) await reopen();
                final known = await read(c.localId);
                final current = await blocking();
                expect(
                  known.status,
                  SessionFinancialAdjustmentLookupStatus.unavailable,
                );
                expect(known.blocksNewIntent, isTrue);
                expect(
                  current.status,
                  SessionFinancialAdjustmentLookupStatus.unavailable,
                );
                expect(current.blocksNewIntent, isTrue);
                final after = await store.commandByLocalId(
                  'account',
                  c.localId,
                );
                expect(after!.wellId, before!.wellId);
                expect(after.status, before.status);
                expect(after.payload, before.payload);
                expect(after.serverResponse, before.serverResponse);
                expect(after.commandId, before.commandId);
                expect(after.occurredAt, before.occurredAt);
              }
            },
          );
        }
      }
      test(
        'valid other well remains excluded with no matching blocker',
        () async {
          final c = await seed(well: 'other-well', state: 'unresolved');
          await reopen();
          expect(
            (await read(c.localId)).status,
            SessionFinancialAdjustmentLookupStatus.absent,
          );
          expect(
            (await blocking()).status,
            SessionFinancialAdjustmentLookupStatus.absent,
          );
          expect((await blocking()).blocksNewIntent, isFalse);
        },
      );
      test(
        'corrupt unrelated account, session or command type is excluded',
        () async {
          final other = await corruptScope(
            null,
            'unresolved',
            account: 'other',
          );
          final nonFinancial = await corruptScope(
            null,
            'dispatching',
            type: CommandType.correctIrrigationSession,
          );
          await reopen();
          expect(
            (await read(other.localId)).status,
            SessionFinancialAdjustmentLookupStatus.absent,
          );
          expect(
            (await read(nonFinancial.localId)).status,
            SessionFinancialAdjustmentLookupStatus.absent,
          );
          expect(
            (await blocking()).status,
            SessionFinancialAdjustmentLookupStatus.absent,
          );
        },
      );
      test(
        'accepted history cannot hide corrupt-well unresolved request',
        () async {
          await seed(state: 'accepted');
          await corruptScope(null, 'unresolved');
          await corruptScope(null, 'unresolved', session: 'other-session');
          await reopen();
          expect((await blocking()).blocksNewIntent, isTrue);
          expect(
            (await blocking()).status,
            SessionFinancialAdjustmentLookupStatus.unavailable,
          );
        },
      );

      final phases = {
        'pending': SessionFinancialAdjustmentFollowUpPhase.pendingFirstSend,
        'dispatching': SessionFinancialAdjustmentFollowUpPhase.inFlight,
        'processing': SessionFinancialAdjustmentFollowUpPhase.processing,
        'accepted': SessionFinancialAdjustmentFollowUpPhase.accepted,
        'validation_error': SessionFinancialAdjustmentFollowUpPhase.needsReview,
        'conflict_request': SessionFinancialAdjustmentFollowUpPhase.needsReview,
        'conflict_revision':
            SessionFinancialAdjustmentFollowUpPhase.needsReview,
        'financial_review_required':
            SessionFinancialAdjustmentFollowUpPhase.needsReview,
        'locked': SessionFinancialAdjustmentFollowUpPhase.needsReview,
        'permission_denied':
            SessionFinancialAdjustmentFollowUpPhase.needsReview,
        'unresolved': SessionFinancialAdjustmentFollowUpPhase.uncertain,
        'not_found': SessionFinancialAdjustmentFollowUpPhase.uncertain,
      };
      for (final entry in phases.entries) {
        test(
          '${entry.key} preserves typed evidence after reopen without mutation',
          () async {
            final c = await seed(state: entry.key);
            final before = await store.commandByLocalId('account', c.localId);
            await reopen();
            final result = await read(c.localId);
            expect(result.status, SessionFinancialAdjustmentLookupStatus.found);
            final view = result.followUp!;
            expect(view.localId, c.localId);
            expect(view.sessionId, 'session');
            expect(view.commandId, c.commandId);
            expect(view.requestedAt, now);
            expect(view.baseOperationalRevision, 3);
            expect(view.baseSystemFinancialRevision, 2);
            expect(view.baseManualApprovalRevision, 1);
            expect(view.approvedAmountYER, 0);
            expect(view.reason, 'اعتماد الصفر');
            expect(view.commandStatus, before!.status);
            expect(view.phase, entry.value);
            final isBlocking = const {
              'pending',
              'dispatching',
              'processing',
              'unresolved',
              'not_found',
            }.contains(entry.key);
            expect(view.blocksNewIntent, isBlocking);
            expect((await blocking()).blocksNewIntent, isBlocking);
            if (!const {'pending', 'dispatching'}.contains(entry.key)) {
              expect(view.outcome!.state.wireValue, entry.key);
            }
            if (entry.key == 'accepted') {
              expect(view.outcome!.accepted!.deltaYER, -9000);
            }
            final after = await store.commandByLocalId('account', c.localId);
            expect(after!.payload, before.payload);
            expect(after.serverResponse, before.serverResponse);
            expect(after.status, before.status);
            expect(after.retryCount, before.retryCount);
            expect(after.lastAttemptAt, before.lastAttemptAt);
            expect(after.lastError, before.lastError);
            expect(after.commandId, before.commandId);
          },
        );
      }
      test(
        'known lookup validates account, well, session, type and absence',
        () async {
          final c = await seed();
          for (final result in [
            await read(c.localId, account: 'other'),
            await read(c.localId, well: 'other'),
            await read(c.localId, session: 'other'),
            await read('absent'),
          ]) {
            expect(
              result.status,
              SessionFinancialAdjustmentLookupStatus.absent,
            );
            expect(result.followUp, isNull);
          }
          final other = await repository.enqueue(
            accountId: 'account',
            wellId: 'well',
            type: CommandType.correctIrrigationSession,
            payload: {'p_session_id': 'session'},
            occurredAt: now,
          );
          expect(
            (await read(other.localId)).status,
            SessionFinancialAdjustmentLookupStatus.absent,
          );
        },
      );
      test(
        'missing persisted session identity is unavailable, not absence',
        () async {
          final row = await repository.prepare(
            accountId: 'account',
            wellId: 'well',
            type: CommandType.adjustSessionFinancialAmount,
            occurredAt: now,
            payload: {'p_session_id': null, 'p_reason': 'سبب'},
          );
          await store.insert(row);
          final known = await read(row.localId);
          expect(
            known.status,
            SessionFinancialAdjustmentLookupStatus.unavailable,
          );
          expect(known.blocksNewIntent, isTrue);
          expect((await blocking()).blocksNewIntent, isTrue);
        },
      );

      test('historical accepted requests do not obscure an older unresolved blocker', () async {
        final b = await seed(state: 'unresolved');
        await seed(state: 'accepted');
        await seed(state: 'accepted');
        await seed(account: 'other', state: 'processing');
        await seed(well: 'other', state: 'processing');
        await seed(session: 'other', state: 'processing');
        await reopen();
        expect((await blocking()).followUp!.commandId, b.commandId);
      });
      test('accepted history alone does not block; explicit old selection is exact', () async {
        final a = await seed(state: 'accepted');
        final b = await seed(state: 'accepted');
        expect(
          (await blocking()).status,
          SessionFinancialAdjustmentLookupStatus.absent,
        );
        expect((await read(a.localId)).followUp!.commandId, a.commandId);
        expect((await read(b.localId)).followUp!.commandId, b.commandId);
      });
      test(
        'multiple blockers are typed ambiguity, never latest wins',
        () async {
          await seed(state: 'unresolved');
          await seed(state: 'processing');
          await reopen();
          final result = await blocking();
          expect(
            result.status,
            SessionFinancialAdjustmentLookupStatus.ambiguous,
          );
          expect(result.followUp, isNull);
          expect(result.blocksNewIntent, isTrue);
        },
      );
      for (final corrupt in [
        'observation',
        'missing_acceptance',
        'status_mismatch',
        'request',
        'unknown',
      ]) {
        test('$corrupt fails closed and remains read-only', () async {
          final c = await repository.prepare(
            accountId: 'account',
            wellId: 'well',
            type: CommandType.adjustSessionFinancialAmount,
            occurredAt: now,
            payload: {
              'p_session_id': 'session',
              'p_base_operational_revision': 3,
              'p_base_system_financial_revision': 2,
              'p_base_manual_approval_revision': 1,
              'p_approved_amount_minor': corrupt == 'request' ? '0' : 0,
              'p_reason': 'اعتماد الصفر',
            },
          );
          final row = c.copyWith(
            status: CommandStatus.confirmed,
            serverResponse: corrupt == 'missing_acceptance'
                ? null
                : {
                    'contract': corrupt == 'observation'
                        ? 'wrong'
                        : 'session_financial_adjustment_observation',
                    'version': 1,
                    'status': corrupt == 'unknown'
                        ? 'future_status'
                        : 'processing',
                    'retry_authorized': false,
                  },
          );
          await store.insert(row);
          final result = await read(c.localId);
          expect(result.blocksNewIntent, isTrue);
          if (corrupt == 'request') {
            expect(
              result.status,
              SessionFinancialAdjustmentLookupStatus.unavailable,
            );
          } else {
            expect(
              result.followUp!.phase,
              SessionFinancialAdjustmentFollowUpPhase.uncertain,
            );
          }
          expect((await blocking()).blocksNewIntent, isTrue);
          expect(
            (await store.commandByLocalId(
              'account',
              c.localId,
            ))!.serverResponse,
            row.serverResponse,
          );
        });
      }
      test(
        'coordinator exposes the same read-only model without transport',
        () async {
          final c = await seed(state: 'processing');
          final coordinator = OfflineSessionCoordinator(store: store);
          try {
            final result = await coordinator
                .readSessionFinancialAdjustmentFollowUp(
                  accountId: 'account',
                  wellId: 'well',
                  sessionId: 'session',
                  localId: c.localId,
                );
            expect(
              result.followUp!.phase,
              SessionFinancialAdjustmentFollowUpPhase.processing,
            );
            expect(
              (await coordinator.findBlockingSessionFinancialAdjustmentFollowUp(
                accountId: 'account',
                wellId: 'well',
                sessionId: 'session',
              )).blocksNewIntent,
              isTrue,
            );
          } finally {
            coordinator.dispose();
          }
        },
      );
    });
  }
}

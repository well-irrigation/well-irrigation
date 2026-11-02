import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';

import 'command_intent_dispatch_claim_test.dart' as facts;

import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';

import '../../support/human_command_fixture.dart';

class ProbeTransport implements CommandTransport, CompletionReceiptTransport {
  final writes = <DispatchRequest>[];
  final reads = <CompletionReceiptRequest>[];
  CompletionReceiptRead answer = const CompletionReceiptFailure(
    CompletionReceiptFailureKind.network,
  );
  Completer<void>? gate;
  DispatchResult Function(DispatchRequest)? handler;
  @override
  Future<DispatchResult> dispatch(DispatchRequest request) async {
    writes.add(request);
    await gate?.future;
    return handler?.call(request) ??
        const DispatchAccepted(
          response: {
            'session_id': 'server-session',
            'booking_id': 'booking',
            'well_id': 'well',
            'session_status': 'open',
            'booking_status': 'confirmed',
            'started_at': '2026-10-20T09:00:00Z',
            'booked_duration_minutes': 10,
            'operational_end_at': '2026-10-20T09:10:00Z',
          },
          entityId: 'server-session',
        );
  }

  @override
  Future<CompletionReceiptRead> readCompletionReceipt(
    CompletionReceiptRequest request,
  ) async {
    reads.add(request);
    return answer;
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite' : 'memory', () {
      late OutboxStore store;
      late ProbeTransport transport;
      Directory? dir;
      setUp(() async {
        if (sqlite) {
          dir = await Directory.systemTemp.createTemp('q137-integration-');
          store = SqliteOutboxStore(
            databasePath: '${dir!.path}/db',
            sqfliteFactory: databaseFactoryFfi,
            singleInstance: false,
          );
        } else {
          store = InMemoryOutboxStore();
        }
        await store.initialize();
        transport = ProbeTransport();
      });
      tearDown(() async {
        await store.close();
        if (dir != null) await dir!.delete(recursive: true);
      });
      for (final human in [true, false]) {
        test('only proven human start can dispatch: human=$human', () async {
          await facts.seed(store, human: human);
          await SyncEngine(store: store, transport: transport).run('account');
          expect(transport.writes, hasLength(human ? 1 : 0));
        });
      }
      test(
        'stored entity resolution never authorizes a second dispatch',
        () async {
          await facts.seed(store);
          await store.putMapping(
            'account',
            IdMapping(
              localId: 'start',
              kind: EntityKind.session,
              serverId: 'already-created',
              resolvedAt: facts.at,
            ),
          );
          await SyncEngine(store: store, transport: transport).run('account');
          expect(transport.writes, isEmpty);
          expect(
            (await store.commandByLocalId('account', 'start'))!.status,
            CommandStatus.pending,
          );
          expect(
            (await store.mapping(
              'account',
              'start',
              EntityKind.session,
            ))!.serverId,
            'already-created',
          );
        },
      );
      test('foreground and background share durable claim ownership', () async {
        await facts.seed(store);
        transport.gate = Completer<void>();
        OutboxStore workerStore = store;
        if (sqlite) {
          workerStore = SqliteOutboxStore(
            databasePath: '${dir!.path}/db',
            sqfliteFactory: databaseFactoryFfi,
            singleInstance: false,
          );
          await workerStore.initialize();
          addTearDown(workerStore.close);
        }
        final foreground = SyncEngine(
          store: store,
          transport: transport,
        ).run('account');
        while (transport.writes.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        await SyncEngine(
          store: workerStore,
          transport: transport,
        ).run('account');
        expect(transport.writes, hasLength(1));
        transport.gate!.complete();
        await foreground;
      });

      test(
        'ambiguous manual start keeps original identity and never retries',
        () async {
          await facts.seed(store);
          transport.handler = (_) => const DispatchFailed(
            disposition: FailureDisposition.retry,
            message: 'lost',
          );
          final engine = SyncEngine(
            store: store,
            transport: transport,
            clock: () => facts.at.add(const Duration(days: 1)),
          );
          await engine.run('account');
          await engine.run('account');
          expect(transport.writes, hasLength(1));
          final saved = (await store.commandByLocalId('account', 'start'))!;
          expect(saved.status, CommandStatus.dispatching);
          expect(saved.occurredAt, facts.at);
          expect(saved.commandId, 'start-command');
          expect(saved.retryCount, 0);
        },
      );
      test(
        'only preflight proof permits safe release and subsequent owned send',
        () async {
          await facts.seed(store);
          transport.handler = (_) => const DispatchFailed(
            disposition: FailureDisposition.retry,
            message: 'preflight',
            executionNotStarted: true,
          );
          final engine = SyncEngine(store: store, transport: transport);
          await engine.run('account');
          expect(
            (await store.commandByLocalId('account', 'start'))!.status,
            CommandStatus.pending,
          );
          transport.handler = null;
          await engine.run('account');
          expect(
            (await store.commandByLocalId('account', 'start'))!.status,
            CommandStatus.confirmed,
          );
          expect(transport.writes.map((r) => r.commandId).toSet(), {
            'start-command',
          });
        },
      );
      for (final type in [
        CommandType.recordBookingTransitionDecision,
        CommandType.executePendingBookingStart,
        CommandType.endBookingTransitionChain,
      ]) {
        test(
          'retired $type never sends even with planted human record',
          () async {
            final command = facts.start(type: type, payload: {type.scopeArgument: 'legacy-target'});
            await store.insertBundle(
              accountId: command.accountId,
              key: humanCommandIntentBundleKey(command.localId),
              value: humanCommandIntentRecord(command),
              commands: [command],
            );
            final engine = SyncEngine(store: store, transport: transport);
            await engine.run('account');
            await engine.run('account');
            expect(transport.writes, isEmpty);
            expect(transport.reads, isEmpty);
            expect(
              (await store.commandByLocalId('account', 'start'))!.retryCount,
              0,
            );
            expect(
              await store.readBundle('account', 'command.q137.hold.v1.start'),
              'retired_transition_write_disabled',
            );
          },
        );
      }
      test(
        'one coalesced followup sends work queued during current pass',
        () async {
          await facts.seed(store);
          transport.gate = Completer<void>();
          final engine = SyncEngine(store: store, transport: transport);
          final current = engine.run('account');
          while (transport.writes.isEmpty) {
            await Future<void>.delayed(Duration.zero);
          }
          final next = CommandEnvelope(accountId: 'account', wellId: 'other-well',
          localId: 'another', commandId: 'another-command', type: CommandType.startIrrigationSession,
          sequence: 2, occurredAt: facts.at, createdLocalAt: facts.at, payload: {'p_well_id': 'other-well'});
        await store.insert(next);
        await recordTestHumanAction(store, next);
          final followup = engine.runAfterCurrent('account');
          expect(
            identical(followup, engine.runAfterCurrent('account')),
            isTrue,
          );
          transport.gate!.complete();
          await current;
          final report = await followup;
          expect(report.alreadyRunning, isFalse);
          expect(transport.writes.map((r) => r.commandId), [
            'start-command',
            'another-command',
          ]);
        },
      );

      for (final lost in [false, true]) {
        test('completion accepted via ${lost ? 'receipt' : 'direct response'} keeps original identity and effects once', () async {
          final root = facts.start(type: CommandType.startIrrigationSession, payload: {'p_well_id': 'well'}).copyWith(status: CommandStatus.confirmed, serverResponse: {'session_id': 'server-session'});
          await store.insert(root);
          await store.putMapping('account', IdMapping(localId: root.localId, kind: EntityKind.session, serverId: 'server-session', resolvedAt: facts.at));
          final end = CommandEnvelope(accountId: 'account', wellId: 'well', localId: 'end', commandId: 'original-end',
            type: CommandType.completeIrrigationSession, aggregateLocalId: root.localId, sequence: 2,
            occurredAt: facts.at.add(const Duration(hours: 1)), createdLocalAt: facts.at,
            payload: {'p_session_id': {r'$ref': root.localId, r'$kind': 'session'}});
          await store.insert(end);
          await recordTestHumanAction(store, end);
          final receipt = <String, Object?>{'session_id': 'server-session', 'status': 'closed',
            'session_charge_id': 'real-charge', 'ended_at': end.occurredAt.toIso8601String(),
            'actual_seconds': 3600, 'billable_seconds': 3500, 'amount_minor': 1234,
            'weighted_price_per_hour_minor': 1250, 'segments': <Object?>[]};
          transport.handler = (_) => lost
            ? const DispatchFailed(disposition: FailureDisposition.retry, message: 'lost after execution')
            : DispatchAccepted(response: receipt, entityId: 'real-charge');
          final engine = SyncEngine(store: store, transport: transport);
          await engine.run('account');
          if (lost) {
            expect((await store.commandByLocalId('account', 'end'))!.status, CommandStatus.dispatching);
            transport.answer = CompletionReceiptResponse(CompletionReceiptState.accepted, receipt);
          }
          await engine.run('account');
          await engine.run('account');
          expect(transport.writes, hasLength(1));
          expect(transport.writes.single.commandId, end.commandId);
          expect(transport.writes.single.arguments['p_ended_at'], end.occurredAt.toIso8601String());
          expect((await store.commandByLocalId('account', 'end'))!.status, CommandStatus.confirmed);
          expect((await store.mapping('account', 'end', EntityKind.sessionCharge))!.serverId, 'real-charge');
          final projected = (await ActiveSessionProjector(store: store).projectSession('account', root.localId, now: end.occurredAt))!;
          expect(projected.completedAt, end.occurredAt);
          expect(projected.approvedAmountMinor, 1234);
          expect(projected.businessState.isActive, isFalse);
          expect(await store.allCommands('account'), hasLength(2));
          if (sqlite) {
            final events = await (store as SqliteOutboxStore).notificationEvents.db.query('notification_events', where: "event_type='session.completed'");
            expect(events, hasLength(1));
            expect(events.single['event_key'], 'session.completed/original-end');
          }
        });
      }
      for (final outcome
          in <
            ({
              String name,
              CompletionReceiptState? state,
              CompletionReceiptFailureKind? failure,
            })
          >[
            for (final state in CompletionReceiptState.values)
              (name: state.name, state: state, failure: null),
            for (final failure in CompletionReceiptFailureKind.values)
              (name: failure.name, state: null, failure: failure),
          ]) {
        test(
          'legacy ${outcome.name} is read only and never dispatches completion',
          () async {
            final state = outcome.state;
            final root = facts.start().copyWith(
              status: CommandStatus.confirmed,
            );
            await store.insert(root);
            await store.putMapping(
              'account',
              IdMapping(
                localId: root.localId,
                kind: EntityKind.session,
                serverId: 'server-session',
                resolvedAt: facts.at,
              ),
            );
            final command = CommandEnvelope(
              accountId: 'account',
              wellId: 'well',
              localId: 'complete',
              commandId: 'complete-command',
              type: CommandType.completeIrrigationSession,
              sequence: 2,
              occurredAt: facts.at.add(const Duration(hours: 1)),
              createdLocalAt: facts.at,
              aggregateLocalId: root.localId,
              status: CommandStatus.dispatching,
              lastAttemptAt: facts.at,
              payload: {
                'p_session_id': {r'$ref': root.localId, r'$kind': 'session'},
              },
            );
            await store.insert(command);
            final receipt = <String, Object?>{
              'session_id': 'server-session',
              'status': 'closed',
              'session_charge_id': 'charge',
              'ended_at': '2026-10-20T10:00:00Z',
              'actual_seconds': 3600,
              'billable_seconds': 3500,
              'amount_minor': 3500,
              'weighted_price_per_hour_minor': 3600,
              'segments': <Object?>[],
            };
            transport.answer = outcome.failure == null
                ? CompletionReceiptResponse(
                    state!,
                    state == CompletionReceiptState.accepted ? receipt : null,
                  )
                : CompletionReceiptFailure(outcome.failure!);
            await SyncEngine(store: store, transport: transport).run('account');
            expect(transport.writes, isEmpty);
            expect(transport.reads, hasLength(1));
            final saved = await store.commandByLocalId('account', 'complete');
            expect(saved!.commandId, command.commandId);
            expect(saved.payload, command.payload);
            expect(
              saved.status,
              state == CompletionReceiptState.accepted
                  ? CommandStatus.confirmed
                  : CommandStatus.dispatching,
            );
            if (state == CompletionReceiptState.accepted) {
              expect(saved.serverResponse, receipt);
            }
          },
        );
      }
    });
  }
}

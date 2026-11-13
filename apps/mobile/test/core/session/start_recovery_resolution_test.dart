import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/manual_stop_request_store.dart';
import 'package:well_irrigation_mobile/core/session/operational_start_recovery.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_reference.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/operational_start_receipt.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/start_recovery_policy.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';

import 'operational_start_guided_recovery_test.dart';

void main() {
  sqfliteFfiInit();
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite' : 'InMemory', () {
      late OutboxStore store;
      late Directory dir;
      late CommandEnvelope root;
      late GuidedReceiptTransport transport;
      late GuidedRepository repository;
      late OperationalStartRecovery recovery;
      String? account;
      OperationalStartRecovery service() => OperationalStartRecovery(
        store: store,
        transport: transport,
        repository: repository,
        currentAccountId: () => account,
      );
      Future<OperationalStartRecoveryObservation> check() => recovery.check(
        accountId: 'account',
        wellId: 'well',
        sessionLocalId: root.localId,
      );
      Future<OperationalStartRecoveryObservation> resolve(
        OperationalStartRecoveryObservation observed, {
        String reason = 'تمت المراجعة',
        bool confirmed = true,
      }) => recovery.resolveRejectedStart(
        observed,
        reason: reason,
        confirmed: confirmed,
      );
      Future<CommandEnvelope> child({String relation = 'aggregate'}) async {
        final c = await OutboxRepository(store: store).prepare(
          accountId: 'account',
          wellId: 'well',
          aggregateLocalId: relation == 'aggregate' ? root.localId : null,
          prerequisites: relation == 'dependency' ? [root.localId] : [],
          type: CommandType.pauseIrrigationSession,
          occurredAt: startTime.add(const Duration(minutes: 2)),
          payload: {
            'p_session_id': relation == 'reference'
                ? CommandReference(
                    localId: root.localId,
                    kind: EntityKind.session,
                  ).toJson()
                : 'server',
            'p_reason': 'operator_pause',
          },
        );
        await store.insert(c);
        await (store as AtomicLocalRecordStore).insertLocalRecordOnce(
          accountId: 'account',
          key: humanCommandIntentBundleKey(c.localId),
          value: humanCommandIntentRecord(c),
        );
        return c;
      }

      Future<void> reopen() async {
        if (!sqlite) return;
        await store.close();
        store = SqliteOutboxStore(
          databasePath: '${dir.path}/outbox.db',
          singleInstance: false,
          sqfliteFactory: databaseFactoryFfi,
        );
        await store.initialize();
        recovery = service();
      }

      setUp(() async {
        dir = await Directory.systemTemp.createTemp('start-resolution-');
        store = sqlite
            ? SqliteOutboxStore(
                databasePath: '${dir.path}/outbox.db',
                singleInstance: false,
                sqfliteFactory: databaseFactoryFfi,
              )
            : InMemoryOutboxStore();
        root = await reviewStart(store);
        account = 'account';
        transport = GuidedReceiptTransport()
          ..state = OperationalStartReceiptState.rejected;
        repository = GuidedRepository();
        recovery = service();
      });
      tearDown(() async {
        await store.close();
        await dir.delete(recursive: true);
      });

      test(
        'rejected resolution preserves original row, proof, and SQLite reopen',
        () async {
          final before = dispatchCommandFingerprint(root);
          expect(
            (await resolve(await check())).state,
            OperationalStartRecoveryState.resolved,
          );
          final event = await store.readBundle(
            'account',
            startRecoveryKey(root.localId),
          );
          expect(event, isNotNull);
          await reopen();
          expect(
            dispatchCommandFingerprint(
              await store.commandByLocalId('account', root.localId),
            ),
            before,
          );
          expect(
            await store.readBundle('account', startRecoveryKey(root.localId)),
            event,
          );
          expect(
            (await store.allCommands('account')).single.status,
            CommandStatus.review,
          );
          expect(
            await OutboxRepository(store: store).pendingCount('account'),
            0,
          );
          expect(
            await ActiveSessionProjector(store: store)
                .projectAll('account', now: startTime),
            isEmpty,
          );
          expect(transport.requests, isEmpty);
        },
      );
      for (final state in [
        OperationalStartReceiptState.notFound,
        OperationalStartReceiptState.unresolved,
        OperationalStartReceiptState.processing,
      ]) {
        test('$state is not proof of rejection', () async {
          transport.state = state;
          expect(
            (await resolve(await check())).state,
            isNot(OperationalStartRecoveryState.resolved),
          );
          expect(
            await store.readBundle('account', startRecoveryKey(root.localId)),
            isNull,
          );
        });
      }
      test('network/local review alone cannot close', () async {
        transport.failure = OperationalStartReceiptFailureKind.network;
        expect(
          (await resolve(await check())).state,
          isNot(OperationalStartRecoveryState.resolved),
        );
        expect(await OutboxRepository(store: store).pendingCount('account'), 1);
      });
      test('explicit confirmation and nonblank reason required', () async {
        final observed = await check();
        expect(
          (await resolve(observed, confirmed: false)).state,
          isNot(OperationalStartRecoveryState.resolved),
        );
        expect(
          (await resolve(observed, reason: '  ')).state,
          isNot(OperationalStartRecoveryState.resolved),
        );
        expect(
          await store.readBundle('account', startRecoveryKey(root.localId)),
          isNull,
        );
      });
      test('accepted mapping contradicts rejection', () async {
        final observed = await check();
        await store.putMapping(
          'account',
          IdMapping(
            localId: root.localId,
            kind: EntityKind.session,
            serverId: 'server',
            resolvedAt: startTime,
          ),
        );
        expect(
          (await resolve(observed)).state,
          isNot(OperationalStartRecoveryState.resolved),
        );
      });
      for (final relation in ['aggregate', 'reference', 'dependency']) {
        for (final state in [
          CommandStatus.dispatching,
          CommandStatus.review,
          CommandStatus.confirmed,
        ]) {
          test('$relation $state child blocks closure', () async {
            final c = await child(relation: relation);
            if (state == CommandStatus.dispatching) {
              await store.claim('account', c.localId, attemptedAt: startTime);
            }
            if (state == CommandStatus.review) {
              await store.markNeedsReview(
                'account',
                c.localId,
                error: 'uncertain',
                attemptedAt: startTime,
              );
            }
            if (state == CommandStatus.confirmed) {
              await store.markConfirmed(
                'account',
                c.localId,
                serverResponse: {'id': 'segment'},
                attemptedAt: startTime,
              );
            }
            expect(
              (await resolve(await check())).state,
              isNot(OperationalStartRecoveryState.resolved),
            );
            expect(
              await store.readBundle('account', startRecoveryKey(root.localId)),
              isNull,
            );
          });
        }
      }
      test('unsent child and old stop remain historical and cannot be restored or claimed', () async {
        final c = await child();
        final stops = ManualStopRequestStore(store);
        await stops.recordHumanStopRequest(
          accountId: 'account',
          wellId: 'well',
          sessionLocalId: root.localId,
          requestedAt: startTime.add(const Duration(minutes: 3)),
        );
        final key = ManualStopRequestStore.keyFor('well', root.localId);
        final old = await store.readBundle('account', key);
        expect(
          (await resolve(await check())).state,
          OperationalStartRecoveryState.resolved,
        );
        await reopen();
        expect(
          await ManualStopRequestStore(store)
              .recoverRecordedRequests('account'),
          0,
        );
        expect(await store.readBundle('account', key), old);
        expect(
          await store.claim('account', c.localId, attemptedAt: startTime),
          false,
        );
        expect(await OutboxRepository(store: store).pendingCount('account'), 0);
        expect(await store.allCommands('account'), hasLength(2));
        await SyncEngine(store: store, transport: transport).run('account');
        expect(transport.requests, isEmpty);
      });
      test('identical retry and double resolution are idempotent, reason/snapshot changes conflict', () async {
        final observed = await check();
        final both = await Future.wait([resolve(observed), resolve(observed)]);
        expect(
          both.every((r) => r.state == OperationalStartRecoveryState.resolved),
          true,
        );
        final old = await store.readBundle(
          'account',
          startRecoveryKey(root.localId),
        );
        expect(
          (await resolve(observed, reason: 'سبب آخر')).state,
          isNot(OperationalStartRecoveryState.resolved),
        );
        expect(
          await store.readBundle('account', startRecoveryKey(root.localId)),
          old,
        );
        expect(
          (await (store as StartRecoveryLocalStore).readStartRecovery(
            'account',
          )).records.keys.where((k) => k.startsWith(startRecoveryPrefix)),
          hasLength(1),
        );
      });
      test('changed local snapshot or human evidence cannot close', () async {
        final observed = await check();
        await store.markNeedsReview(
          'account',
          root.localId,
          error: 'newer-evidence',
          attemptedAt: startTime,
        );
        expect(
          (await resolve(observed)).state,
          isNot(OperationalStartRecoveryState.resolved),
        );
      });
      test('late contradictory accepted result is audited, original stays review, start remains blocked', () async {
        expect(
          (await resolve(await check())).state,
          OperationalStartRecoveryState.resolved,
        );
        final old = dispatchCommandFingerprint(
          await store.commandByLocalId('account', root.localId),
        );
        await store.markConfirmed(
          'account',
          root.localId,
          serverResponse: {
            'id': 'server',
            'occurrence_command_id': root.commandId,
          },
          attemptedAt: startTime,
        );
        expect(
          dispatchCommandFingerprint(
            await store.commandByLocalId('account', root.localId),
          ),
          old,
        );
        expect(
          await store.readBundle(
            'account',
            startRecoveryConflictKey(root.localId),
          ),
          isNotNull,
        );
        expect(await OutboxRepository(store: store).pendingCount('account'), 1);
        expect(
          (await ActiveSessionProjector(
            store: store,
          ).projectAll('account', now: startTime)).single.syncState.name,
          'conflict',
        );
      });
      test('resolution clears only its own start blocker', () async {
        final other = await reviewStart(store);
        final observed = await check();
        expect(
          (await resolve(observed)).state,
          OperationalStartRecoveryState.resolved,
        );
        final policy =
            (await (store as StartRecoveryLocalStore).readStartRecovery(
              'account',
            )).policy;
        final rows = await store.allCommands('account');
        expect(
          existingOperationalStart(
            rows.where(policy.blocksOperationalStart),
            'well',
            sessionBoundLocalIds: {},
          )!.localId,
          other.localId,
        );
        expect(await OutboxRepository(store: store).pendingCount('account'), 1);
      });
      for (final mismatch in ['account', 'well']) {
        test('$mismatch mismatch does not resolve or adopt', () async {
          final observed = await check();
          if (mismatch == 'account') {
            account = 'other';
          } else {
            repository.wellId = 'other';
            transport.state = OperationalStartReceiptState.accepted;
          }
          if (mismatch == 'account') {
            expect(
              (await resolve(observed)).state,
              isNot(OperationalStartRecoveryState.resolved),
            );
          }
          expect((await check()).canAdopt, false);
          expect(
            await store.readBundle('other', startRecoveryKey(root.localId)),
            isNull,
          );
        });
      }
      test('same receipt adopts canonical pause snapshot and isolates old stop across reopen', () async {
        transport.state = OperationalStartReceiptState.accepted;
        final oldChild = await child();
        final stop = ManualStopRequestStore(store);
        await stop.recordHumanStopRequest(
          accountId: 'account',
          wellId: 'well',
          sessionLocalId: root.localId,
          requestedAt: startTime.add(const Duration(minutes: 3)),
        );
        final stopKey = ManualStopRequestStore.keyFor('well', root.localId);
        final savedStop = await store.readBundle('account', stopKey);
        repository.suppliedSegments = [
          SessionSegmentItem(
            sequenceNumber: 1,
            segmentType: 'solar_run',
            isStop: false,
            isBillable: true,
            startedAt: startTime,
            endedAt: startTime.add(const Duration(minutes: 5)),
            energySourceCode: 'solar',
          ),
          SessionSegmentItem(
            sequenceNumber: 2,
            segmentType: 'operator_pause',
            isStop: true,
            isBillable: false,
            startedAt: startTime.add(const Duration(minutes: 5)),
            energySourceCode: 'solar',
          ),
        ];
        final observed = await check();
        expect(observed.canAdopt, true);
        expect(
          (await recovery.adopt(observed)).state,
          OperationalStartRecoveryState.resolved,
        );
        expect(
          (await recovery.adopt(observed)).state,
          OperationalStartRecoveryState.resolved,
        );
        await reopen();
        final projection =
            (await ActiveSessionProjector(store: store).projectAll(
              'account',
              now: startTime.add(const Duration(minutes: 8)),
            )).single;
        expect(projection.segments, hasLength(2));
        expect(projection.currentPauseReason, 'operator_pause');
        expect(projection.serverSessionId, 'server');
        expect(projection.hasPendingManualStop, false);
        expect(await store.readBundle('account', stopKey), savedStop);
        expect(
          await ManualStopRequestStore(store)
              .recoverRecordedRequests('account'),
          0,
        );
        expect(
          await store.claim(
            'account',
            oldChild.localId,
            attemptedAt: startTime,
          ),
          false,
        );
        expect(await OutboxRepository(store: store).pendingCount('account'), 0);
        await SyncEngine(store: store, transport: transport).run('account');
        expect(transport.requests, isEmpty);
        final freshStop = await ManualStopRequestStore(store)
            .recordHumanStopRequest(
              accountId: 'account',
              wellId: 'well',
              sessionLocalId: root.localId,
              requestedAt: startTime.add(const Duration(minutes: 9)),
            );
        expect(freshStop.controlAnchor, isNotNull);
        final completion = await ManualStopRequestStore(store)
            .materializeRecordedRequest(freshStop);
        expect(completion.occurredAt, freshStop.requestedAt);
        expect(await store.readBundle('account', stopKey), savedStop);
        expect(await store.allCommands('account'), hasLength(3));
        expect(transport.requests, isEmpty);
      });
      test('unresolved child blocks perspective adoption without discarding evidence', () async {
        final c = await child();
        await store.claim('account', c.localId, attemptedAt: startTime);
        transport.state = OperationalStartReceiptState.accepted;
        expect(
          (await recovery.adopt(await check())).state,
          isNot(OperationalStartRecoveryState.resolved),
        );
        expect(
          (await store.commandByLocalId('account', c.localId))!.status,
          CommandStatus.dispatching,
        );
      });
      for (final settledStop in [false, true]) {
        test(
          'completed server snapshot adopted; settled old stop=$settledStop stays historical',
          () async {
            final end = startTime.add(const Duration(minutes: 10));
            transport.state = OperationalStartReceiptState.accepted;
            repository.status = 'closed';
            repository.endedAt = end;
            repository.suppliedSegments = [
              SessionSegmentItem(
                sequenceNumber: 1,
                segmentType: 'solar_run',
                isStop: false,
                isBillable: true,
                startedAt: startTime,
                endedAt: end,
                energySourceCode: 'solar',
              ),
            ];
            CommandEnvelope? completion;
            if (settledStop) {
              completion = await OutboxRepository(store: store).enqueue(
                accountId: 'account',
                wellId: 'well',
                aggregateLocalId: root.localId,
                type: CommandType.completeIrrigationSession,
                occurredAt: end,
                payload: {'p_session_id': 'server'},
              );
              await store.markConfirmed(
                'account',
                completion.localId,
                serverResponse: {
                  'command_id': completion.commandId,
                  'command_type': completion.type.rpcName,
                  'well_id': 'well',
                  'session_id': 'server',
                  'status': 'closed',
                  'session_charge_id': 'charge',
                  'ended_at': end.toIso8601String(),
                  'segments': <Object?>[],
                  'actual_seconds': 600,
                  'billable_seconds': 600,
                  'weighted_price_per_hour_minor': 123,
                  'amount_minor': 20,
                },
                attemptedAt: end,
              );
              await store.putMapping(
                'account',
                IdMapping(
                  localId: completion.localId,
                  kind: EntityKind.sessionCharge,
                  serverId: 'charge',
                  resolvedAt: end,
                ),
              );
            }
            final observed = await check();
            expect(observed.canAdopt, true);
            expect(
              (await recovery.adopt(observed)).state,
              OperationalStartRecoveryState.resolved,
            );
            await reopen();
            final policy =
                (await (store as StartRecoveryLocalStore).readStartRecovery(
                  'account',
                )).policy;
            expect(
              policy.root(root.localId),
              StartRecoveryDisposition.adoptedServerPerspective,
            );
            final projected = (await ActiveSessionProjector(
              store: store,
            ).projectAll('account', now: end)).single;
            expect(projected.completedAt, end);
            expect(projected.segments, hasLength(1));
            expect(
              existingOperationalStart(
                (await store.allCommands('account'))
                    .where(policy.blocksOperationalStart),
                'well',
                sessionBoundLocalIds: {root.localId},
              ),
              isNull,
            );
            expect(
              await store.allCommands('account'),
              hasLength(settledStop ? 2 : 1),
            );
            expect(transport.requests, isEmpty);
          },
        );
      }
      test(
        'new start is blocked before resolution and allowed only after it',
        () async {
          final repo = OutboxRepository(store: store);
          Future<void> saveNew() async {
            final next = await repo.prepare(
              accountId: 'account',
              wellId: 'well',
              type: CommandType.startOperationalSession,
              occurredAt: startTime.add(const Duration(hours: 1)),
              payload: root.payload,
            );
            await store.insertBundle(
              accountId: 'account',
              key: 'new-start-${next.commandId}',
              value: 'human',
              commands: [next],
            );
          }

          await expectLater(
            saveNew(),
            throwsA(isA<ExistingOperationalStart>()),
          );
          expect(
            (await resolve(await check())).state,
            OperationalStartRecoveryState.resolved,
          );
          await saveNew();
          expect(await store.allCommands('account'), hasLength(2));
          expect(transport.requests, isEmpty);
        },
      );
      test(
        'a pre-adoption prepared child is not a new control intent',
        () async {
          transport.state = OperationalStartReceiptState.accepted;
          final prepared = await OutboxRepository(store: store).prepare(
            accountId: 'account',
            wellId: 'well',
            aggregateLocalId: root.localId,
            type: CommandType.pauseIrrigationSession,
            occurredAt: startTime.add(const Duration(minutes: 10)),
            payload: {'p_session_id': 'server', 'p_reason': 'operator_pause'},
          );
          expect(
            (await recovery.adopt(await check())).state,
            OperationalStartRecoveryState.resolved,
          );
          await expectLater(store.insert(prepared), throwsStateError);
          expect(await store.allCommands('account'), hasLength(1));
        },
      );
      test('a late isolated child acceptance creates durable conflict without rewriting it', () async {
        final c = await child();
        transport.state = OperationalStartReceiptState.accepted;
        expect(
          (await recovery.adopt(await check())).state,
          OperationalStartRecoveryState.resolved,
        );
        final old = dispatchCommandFingerprint(c);
        await store.markConfirmed(
          'account',
          c.localId,
          serverResponse: {'id': 'segment'},
          attemptedAt: startTime,
        );
        expect(
          dispatchCommandFingerprint(
            await store.commandByLocalId('account', c.localId),
          ),
          old,
        );
        expect(
          await store.readBundle(
            'account',
            startRecoveryConflictKey(root.localId),
          ),
          isNotNull,
        );
        expect(
          (await OutboxRepository(store: store).needingReview('account'))
              .any((r) => r.localId == root.localId),
          true,
        );
      });
      test(
        'a malformed or changed receipt never substitutes another session',
        () async {
          transport.state = OperationalStartReceiptState.accepted;
          transport.wrongCommand = 'wrong';
          expect((await check()).canAdopt, false);
          expect(
            await store.readBundle('account', startRecoveryKey(root.localId)),
            isNull,
          );
        },
      );
      test('late accepted receipt reconciliation cannot reopen a rejected resolution', () async {
        final observed = await check();
        expect(
          (await resolve(observed)).state,
          OperationalStartRecoveryState.resolved,
        );
        final receipt = {
          'id': 'server',
          'occurrence_command_id': root.commandId,
        };
        expect(
          await (store as AtomicCommandDispatchStore)
              .reconcileOperationalStartReceipt(root, receipt),
          false,
        );
        expect(
          (await store.commandByLocalId('account', root.localId))!.status,
          CommandStatus.review,
        );
        expect(
          await store.readBundle(
            'account',
            startRecoveryConflictKey(root.localId),
          ),
          isNotNull,
        );
      });
      test('human intent changed after review fails closed', () async {
        final observed = await check();
        await store.insertBundle(
          accountId: 'account',
          key: 'changed-human',
          value: 'test',
          commands: [],
          localValues: {humanCommandIntentBundleKey(root.localId): '{}'},
        );
        expect(
          (await resolve(observed)).state,
          isNot(OperationalStartRecoveryState.resolved),
        );
        expect(
          await store.readBundle('account', startRecoveryKey(root.localId)),
          isNull,
        );
      });
      if (sqlite) {
        test(
          'two SQLite instances share one first-winner resolution',
          () async {
            final observed = await check();
            final other = SqliteOutboxStore(
              databasePath: '${dir.path}/outbox.db',
              singleInstance: false,
              sqfliteFactory: databaseFactoryFfi,
            );
            await other.initialize();
            try {
              final second = OperationalStartRecovery(
                store: other,
                transport: transport,
                repository: repository,
                currentAccountId: () => account,
              );
              final results = await Future.wait([
                resolve(observed),
                second.resolveRejectedStart(
                  observed,
                  reason: 'تمت المراجعة',
                  confirmed: true,
                ),
              ]);
              expect(
                results.every(
                  (r) => r.state == OperationalStartRecoveryState.resolved,
                ),
                true,
              );
              expect(
                await other.readBundle(
                  'account',
                  startRecoveryKey(root.localId),
                ),
                await store.readBundle(
                  'account',
                  startRecoveryKey(root.localId),
                ),
              );
            } finally {
              await other.close();
            }
          },
        );
      }
      test('new control command dispatches once; historical child never dispatches', () async {
        final old = await child();
        transport.state = OperationalStartReceiptState.accepted;
        expect(
          (await recovery.adopt(await check())).state,
          OperationalStartRecoveryState.resolved,
        );
        final fresh = await OutboxRepository(store: store).prepare(
          accountId: 'account',
          wellId: 'well',
          aggregateLocalId: root.localId,
          type: CommandType.pauseIrrigationSession,
          occurredAt: startTime.add(const Duration(minutes: 11)),
          payload: {'p_session_id': 'server', 'p_reason': 'operator_pause'},
        );
        await store.insertBundle(
          accountId: 'account',
          key: humanCommandIntentBundleKey(fresh.localId),
          value: humanCommandIntentRecord(fresh),
          commands: [fresh],
        );
        expect(await OutboxRepository(store: store).pendingCount('account'), 1);
        await SyncEngine(store: store, transport: transport).run('account');
        expect(transport.requests.map((r) => r.commandId), [fresh.commandId]);
        expect(
          (await store.commandByLocalId('account', old.localId))!.status,
          CommandStatus.pending,
        );
        expect(await OutboxRepository(store: store).pendingCount('account'), 0);
      });
      test('corrupt recovery event fails closed', () async {
        await (store as AtomicLocalRecordStore).insertLocalRecordOnce(
          accountId: 'account',
          key: startRecoveryKey(root.localId),
          value: jsonEncode({'version': 99}),
        );
        final policy =
            (await (store as StartRecoveryLocalStore).readStartRecovery(
              'account',
            )).policy;
        expect(policy.root(root.localId), StartRecoveryDisposition.conflict);
        expect(policy.mayDispatch(root), false);
        expect(policy.blocksOperationalStart(root), true);
      });
    });
  }
}

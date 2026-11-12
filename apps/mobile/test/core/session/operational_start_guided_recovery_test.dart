import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/operational_start_recovery.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/session/manual_stop_request_store.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/operational_start_receipt.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/sync/start_recovery_policy.dart';

import '../sync/fake_command_transport.dart';

final startTime = DateTime.utc(2026, 11, 11, 8);

class GuidedReceiptTransport extends FakeCommandTransport
    implements OperationalStartReceiptTransport {
  int reads = 0;
  OperationalStartReceiptState state = OperationalStartReceiptState.accepted;
  OperationalStartReceiptFailureKind? failure;
  String serverId = 'server';
  String? wrongCommand;
  Completer<void>? barrier;
  @override
  Future<OperationalStartReceiptRead> readOperationalStartReceipt(
    OperationalStartReceiptRequest request,
  ) async {
    reads++;
    await barrier?.future;
    if (failure != null) return OperationalStartReceiptFailure(failure!);
    return OperationalStartReceiptResponse(state, switch (state) {
      OperationalStartReceiptState.accepted => {
        'id': serverId,
        'occurrence_command_id': wrongCommand ?? request.commandId,
      },
      OperationalStartReceiptState.rejected => {
        'status': 'rejected',
        'reason': 'terminal',
      },
      _ => null,
    });
  }
}

class GuidedRepository extends OperationsRepository {
  String sessionId = 'server',
      wellId = 'well',
      farmer = 'farmer',
      status = 'open';
  List<SessionSegmentItem>? suppliedSegments;
  DateTime? endedAt;
  int revision = 0;
  bool fail = false;
  int reads = 0;
  Completer<void>? barrier;
  @override
  Future<SessionDetailData> fetchSessionDetail(String id) async {
    reads++;
    await barrier?.future;
    if (fail) throw StateError('network');
    return SessionDetailData(
      canReadSessionCorrections: false,
      canCorrectSession: false,
      session: SessionHistoryItem(
        id: sessionId,
        wellId: wellId,
        farmerName: 'المزارع',
        farmerCode: 'F',
        farmerAccountId: farmer,
        farmName: 'الأرض',
        pumpName: 'المضخة',
        operatorName: 'المشغل',
        startedAt: startTime,
        status: status,
        endedAt: endedAt,
        operationalRevision: revision,
        energySourceCode: 'solar',
      ),
      segments:
          suppliedSegments ??
          [
            SessionSegmentItem(
              sequenceNumber: 1,
              segmentType: 'solar_run',
              isStop: false,
              isBillable: true,
              startedAt: startTime,
              energySourceCode: 'solar',
            ),
          ],
    );
  }
}

Future<CommandEnvelope> reviewStart(OutboxStore store) async {
  await store.initialize();
  final repo = OutboxRepository(store: store);
  final c = await repo.enqueue(
    accountId: 'account',
    wellId: 'well',
    type: CommandType.startOperationalSession,
    occurredAt: startTime,
    payload: {
      'p_well_id': 'well',
      'p_pump_id': 'pump',
      'p_farm_id': 'farm',
      'p_farmer_well_account_id': 'farmer',
      'p_energy_source': 'solar',
    },
  );
  await (store as AtomicLocalRecordStore).insertLocalRecordOnce(
    accountId: 'account',
    key: humanCommandIntentBundleKey(c.localId),
    value: humanCommandIntentRecord(c),
  );
  await store.markNeedsReview(
    'account',
    c.localId,
    error: 'operational_start_review_required',
    attemptedAt: startTime,
  );
  return (await store.commandByLocalId('account', c.localId))!;
}

class UnreadableRecoveryStore extends InMemoryOutboxStore {
  @override
  Future<CommandEnvelope?> commandByLocalId(
    String accountId,
    String localId,
  ) async => throw StateError('corrupt local evidence');
}

class AccountSwitchOnReconcileStore extends InMemoryOutboxStore {
  void Function()? afterCommit;
  @override
  Future<T> startRecoveryTransaction<T>(
    String accountId,
    StartRecoveryWrite<T> Function(StartRecoverySnapshot) decide,
  ) async {
    final result = await super.startRecoveryTransaction(accountId, decide);
    afterCommit?.call();
    return result;
  }
}

void main() {
  test('identity loss after local reconciliation cannot present success under another account', () async {
    String? current = 'account';
    final store = AccountSwitchOnReconcileStore();
    final command = await reviewStart(store);
    final transport = GuidedReceiptTransport();
    final recovery = OperationalStartRecovery(
      store: store,
      transport: transport,
      repository: GuidedRepository(),
      currentAccountId: () => current,
    );
    final observed = await recovery.check(
      accountId: 'account',
      wellId: 'well',
      sessionLocalId: command.localId,
    );
    store.afterCommit = () => current = 'other';
    expect(
      (await recovery.adopt(observed)).state,
      OperationalStartRecoveryState.unresolvedManualReview,
    );
    expect(await store.allCommands('other'), isEmpty);
    expect(transport.requests, isEmpty);
    await store.close();
  });

  test(
    'corrupt local evidence is manual review, not a network diagnosis',
    () async {
      final store = UnreadableRecoveryStore();
      final recovery = OperationalStartRecovery(
        store: store,
        transport: GuidedReceiptTransport(),
        repository: GuidedRepository(),
        currentAccountId: () => 'account',
      );
      expect(
        (await recovery.check(
          accountId: 'account',
          wellId: 'well',
          sessionLocalId: 'root',
        )).state,
        OperationalStartRecoveryState.unresolvedManualReview,
      );
      await store.close();
    },
  );

  setUpAll(sqfliteFfiInit);
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite' : 'InMemory', () {
      late OutboxStore store;
      late GuidedReceiptTransport transport;
      late GuidedRepository repository;
      late OperationalStartRecovery recovery;
      late CommandEnvelope command;
      String? account;
      Directory? dir;
      setUp(() async {
        account = 'account';
        if (sqlite) {
          dir = await Directory.systemTemp.createTemp('guided_start_');
        }
        store = sqlite
            ? SqliteOutboxStore(
                databasePath: '${dir!.path}/db',
                sqfliteFactory: databaseFactoryFfi,
                singleInstance: false,
              )
            : InMemoryOutboxStore();
        command = await reviewStart(store);
        transport = GuidedReceiptTransport();
        repository = GuidedRepository();
        recovery = OperationalStartRecovery(
          store: store,
          transport: transport,
          repository: repository,
          currentAccountId: () => account,
        );
      });
      tearDown(() async {
        await store.close();
        if (dir != null) {
          await dir!.delete(recursive: true);
          dir = null;
        }
      });
      Future<OperationalStartRecoveryObservation> check() => recovery.check(
        accountId: 'account',
        wellId: 'well',
        sessionLocalId: command.localId,
      );
      test(
        'found session requires explicit reconcile, never dispatch or create',
        () async {
          final observed = await check();
          expect(
            observed.state,
            OperationalStartRecoveryState.serverSessionFound,
          );
          expect(
            (await store.commandByLocalId('account', command.localId))!.status,
            CommandStatus.review,
          );
          final result = await recovery.adopt(observed);
          expect(result.state, OperationalStartRecoveryState.resolved);
          final saved = (await store.commandByLocalId(
            'account',
            command.localId,
          ))!;
          expect(saved.status, CommandStatus.confirmed);
          expect(saved.commandId, command.commandId);
          expect(saved.payload, command.payload);
          expect(saved.occurredAt, command.occurredAt);
          expect(await store.allCommands('account'), hasLength(1));
          expect(transport.requests, isEmpty);
          final projected = await ActiveSessionProjector(store: store)
              .projectSession('account', command.localId, now: startTime);
          expect(projected!.serverSessionId, 'server');
          expect(projected.syncState, SessionSyncState.synced);
          expect(
            await store.readBundle(
              'account',
              humanCommandIntentBundleKey(command.localId),
            ),
            isNotNull,
          );
        },
      );
      for (final state in [
        OperationalStartReceiptState.processing,
        OperationalStartReceiptState.notFound,
        OperationalStartReceiptState.unresolved,
        OperationalStartReceiptState.rejected,
      ]) {
        test(
          '$state preserves evidence and never authorizes replacement',
          () async {
            transport.state = state;
            final result = await check();
            expect(result.canAdopt, isFalse);
            final coordinator = OfflineSessionCoordinator(store: store);
            try {
              await expectLater(
                coordinator.startSession(
                  accountId: 'account',
                  wellId: 'well',
                  pumpId: 'pump',
                  farmId: 'different-farm',
                  farmerAccountId: 'farmer',
                  energySource: 'solar',
                ),
                throwsA(isA<OperationalStartConflict>()),
              );
            } finally {
              coordinator.dispose();
            }

            expect(
              result.state,
              state == OperationalStartReceiptState.processing
                  ? OperationalStartRecoveryState.stillProcessing
                  : OperationalStartRecoveryState.unresolvedManualReview,
            );
            expect(
              (await store.commandByLocalId(
                'account',
                command.localId,
              ))!.status,
              CommandStatus.review,
            );
            expect(await store.allCommands('account'), hasLength(1));
            expect(transport.requests, isEmpty);
          },
        );
      }
      test(
        'background confirmation requires a fresh reviewed snapshot',
        () async {
          final observed = await check();
          await (store as AtomicCommandDispatchStore)
              .reconcileOperationalStartReceipt(command, {
                'id': 'server',
                'occurrence_command_id': command.commandId,
              });
          expect(
            (await recovery.adopt(observed)).state,
            OperationalStartRecoveryState.unresolvedManualReview,
          );
          expect(
            (await recovery.adopt(await check())).state,
            OperationalStartRecoveryState.resolved,
          );
          expect(transport.requests, isEmpty);
        },
      );
      test('conflicting existing binding must not offer adoption', () async {
        await store.putMapping(
          'account',
          IdMapping(
            localId: command.localId,
            kind: EntityKind.session,
            serverId: 'different',
            resolvedAt: startTime,
          ),
        );
        expect((await check()).canAdopt, isFalse);
        expect(transport.requests, isEmpty);
      });
      test('recorded human stop survives receipt adoption exactly', () async {
        final stops = ManualStopRequestStore(store);
        final request = await stops.recordHumanStopRequest(
          accountId: 'account',
          wellId: 'well',
          sessionLocalId: command.localId,
          requestedAt: startTime.add(const Duration(minutes: 2)),
        );
        final key = ManualStopRequestStore.keyFor('well', command.localId);
        final before = await store.readBundle('account', key);
        final observed = await check();
        expect(
          (await recovery.adopt(observed)).state,
          OperationalStartRecoveryState.resolved,
        );
        expect(await store.readBundle('account', key), before);
        expect(
          (await stops.read(
            accountId: 'account',
            wellId: 'well',
            sessionLocalId: command.localId,
          )),
          isNull,
        );
        expect(request.requestId, isNotEmpty);
        final projected = await ActiveSessionProjector(store: store)
            .projectSession(
              'account',
              command.localId,
              now: startTime.add(const Duration(minutes: 5)),
            );
        expect(projected!.hasPendingManualStop, isFalse);
        expect(transport.requests, isEmpty);
      });
      test(
        'old stop recovery is isolated after adopting the server perspective',
        () async {
          final stops = ManualStopRequestStore(store);
          final at = startTime.add(const Duration(minutes: 2));
          await stops.recordHumanStopRequest(
            accountId: 'account',
            wellId: 'well',
            sessionLocalId: command.localId,
            requestedAt: at,
          );
          final observed = await check();
          expect(
            (await recovery.adopt(observed)).state,
            OperationalStartRecoveryState.resolved,
          );
          expect(await store.allCommands('account'), hasLength(1));
          expect(await stops.recoverRecordedRequests('account'), 0);
          final rows = await store.allCommands('account');
          expect(
            rows.where((c) => c.type == CommandType.startOperationalSession),
            hasLength(1),
          );
          expect(
            rows.where((c) => c.type == CommandType.completeIrrigationSession),
            isEmpty,
          );
          expect(transport.requests, isEmpty);
        },
      );
      test('identity loss during canonical read fails closed', () async {
        repository.barrier = Completer<void>();
        final pending = check();
        while (repository.reads == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        account = 'other';
        repository.barrier!.complete();
        expect((await pending).canAdopt, isFalse);
        expect(
          (await store.commandByLocalId('account', command.localId))!.status,
          CommandStatus.review,
        );
      });
      test(
        'canonical SQL pause history matching local events can be adopted',
        () async {
          final at = startTime.add(const Duration(minutes: 1));
          await OutboxRepository(store: store).enqueue(
            accountId: 'account',
            wellId: 'well',
            aggregateLocalId: command.localId,
            type: CommandType.pauseIrrigationSession,
            occurredAt: at,
            payload: {'p_session_id': 'server', 'p_reason': 'operator_pause'},
          );
          repository.suppliedSegments = [
            SessionSegmentItem(
              sequenceNumber: 1,
              segmentType: 'solar_run',
              isStop: false,
              isBillable: true,
              startedAt: startTime,
              endedAt: at,
              energySourceCode: 'solar',
            ),
            SessionSegmentItem(
              sequenceNumber: 2,
              segmentType: 'operator_pause',
              isStop: true,
              isBillable: false,
              startedAt: at,
              energySourceCode: 'solar',
            ),
          ];
          final observed = await check();
          expect(observed.canAdopt, isTrue);
          expect(
            (await recovery.adopt(observed)).state,
            OperationalStartRecoveryState.resolved,
          );
          expect(transport.requests, isEmpty);
        },
      );
      test(
        'same-identity canonical pause can replace the local perspective',
        () async {
          final at = startTime.add(const Duration(minutes: 1));
          repository.suppliedSegments = [
            SessionSegmentItem(
              sequenceNumber: 1,
              segmentType: 'solar_run',
              isStop: false,
              isBillable: true,
              startedAt: startTime,
              endedAt: at,
              energySourceCode: 'solar',
            ),
            SessionSegmentItem(
              sequenceNumber: 2,
              segmentType: 'operator_pause',
              isStop: true,
              isBillable: false,
              startedAt: at,
              energySourceCode: 'solar',
            ),
          ];
          expect((await check()).canAdopt, isTrue);
          expect(
            (await recovery.adopt(await check())).state,
            OperationalStartRecoveryState.resolved,
          );
          expect(transport.requests, isEmpty);
        },
      );
      test('pending local pause is retained when canonical history has not applied it', () async {
        await OutboxRepository(store: store).enqueue(
          accountId: 'account',
          wellId: 'well',
          aggregateLocalId: command.localId,
          type: CommandType.pauseIrrigationSession,
          occurredAt: startTime.add(const Duration(minutes: 1)),
          payload: {'p_session_id': 'server', 'p_reason': 'operator_pause'},
        );
        final observed = await check();
        expect(observed.canAdopt, isTrue);
        expect(
          (await recovery.adopt(observed)).state,
          OperationalStartRecoveryState.resolved,
        );
        expect(transport.requests, isEmpty);
      });
      test(
        'canonical history missing a confirmed local pause cannot be adopted',
        () async {
          final pause = await OutboxRepository(store: store).enqueue(
            accountId: 'account',
            wellId: 'well',
            aggregateLocalId: command.localId,
            type: CommandType.pauseIrrigationSession,
            occurredAt: startTime.add(const Duration(minutes: 1)),
            payload: {'p_session_id': 'server', 'p_reason': 'operator_pause'},
          );
          await store.markConfirmed(
            'account',
            pause.localId,
            serverResponse: {'id': 'segment'},
            attemptedAt: startTime,
          );
          expect((await check()).canAdopt, isFalse);
          expect(transport.requests, isEmpty);
        },
      );
      test('network read remains recoverable', () async {
        transport.failure = OperationalStartReceiptFailureKind.network;
        expect((await check()).state, OperationalStartRecoveryState.offline);
        transport.failure = null;
        expect((await check()).canAdopt, isTrue);
        expect(transport.requests, isEmpty);
      });
      test('account and well mismatches fail closed before network', () async {
        account = 'other';
        expect((await check()).canAdopt, isFalse);
        expect(transport.reads, 0);
        account = 'account';
        expect(
          (await recovery.check(
            accountId: 'account',
            wellId: 'other',
            sessionLocalId: command.localId,
          )).canAdopt,
          isFalse,
        );
        expect(transport.reads, 0);
      });
      test('account changes while receipt pending cannot adopt', () async {
        transport.barrier = Completer<void>();
        final pending = check();
        while (transport.reads == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        account = null;
        transport.barrier!.complete();
        expect((await pending).canAdopt, isFalse);
        expect(
          (await store.commandByLocalId('account', command.localId))!.status,
          CommandStatus.review,
        );
      });
      for (final mismatch in [
        'well',
        'session',
        'farmer',
        'command',
        'closed',
      ]) {
        test('$mismatch disagreement cannot be adopted', () async {
          switch (mismatch) {
            case 'well':
              repository.wellId = 'elsewhere';
            case 'session':
              repository.sessionId = 'elsewhere';
            case 'farmer':
              repository.farmer = 'elsewhere';
            case 'command':
              transport.wrongCommand = 'elsewhere';
            case 'closed':
              repository.status = 'closed';
          }
          expect((await check()).canAdopt, isFalse);
          expect(transport.requests, isEmpty);
        });
      }
      test(
        'double resolution shares one reconciliation and preserves identity',
        () async {
          final observed = await check();
          transport.barrier = Completer<void>();
          final a = recovery.adopt(observed);
          final b = recovery.adopt(observed);
          transport.barrier!.complete();
          expect((await a).state, OperationalStartRecoveryState.resolved);
          expect((await b).state, OperationalStartRecoveryState.resolved);
          expect(transport.reads, 1);
          expect(transport.requests, isEmpty);
          expect(await store.allCommands('account'), hasLength(1));
        },
      );
      if (sqlite) {
        test(
          'fresh SQLite reopen keeps the same review and read options',
          () async {
            await store.close();
            store = SqliteOutboxStore(
              databasePath: '${dir!.path}/db',
              sqfliteFactory: databaseFactoryFfi,
              singleInstance: false,
            );
            recovery = OperationalStartRecovery(
              store: store,
              transport: transport,
              repository: repository,
              currentAccountId: () => account,
            );
            final result = await check();
            expect(
              result.state,
              OperationalStartRecoveryState.serverSessionFound,
            );
            final saved = (await store.commandByLocalId(
              'account',
              command.localId,
            ))!;
            expect(saved.commandId, command.commandId);
            expect(saved.status, CommandStatus.review);
            expect(transport.requests, isEmpty);
          },
        );
      }
    });
  }
}

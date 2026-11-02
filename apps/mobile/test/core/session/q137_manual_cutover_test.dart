import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';

import '../sync/q137_integrated_dispatch_test.dart' show ProbeTransport;

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/manual_stop_request_store.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';

class FailingMaterializationStore extends InMemoryOutboxStore {
  bool fail = true;
  Future<void> Function()? beforeMaterialize;
  @override
  Future<T> sessionExecutionTransaction<T>({
    required String accountId,
    required String wellId,
    required String sessionLocalId,
    required SessionExecutionWrite<T> Function(SessionExecutionSnapshot) decide,
  }) async {
    await beforeMaterialize?.call();
    if (fail) throw StateError('injected_materialization_failure');
    return super.sessionExecutionTransaction(
      accountId: accountId,
      wellId: wellId,
      sessionLocalId: sessionLocalId,
      decide: decide,
    );
  }
}

void main() {
  test('materialization failure preserves visible request and engine recovers before send', () async {
    final store = FailingMaterializationStore();
    final c = OfflineSessionCoordinator(store: store);
    final start = await c.startSession(
      accountId: 'a',
      wellId: 'w',
      pumpId: 'pump',
      farmId: 'farm',
      farmerAccountId: 'farmer',
      energySource: 'solar',
      startedAt: DateTime.utc(2026, 10, 20, 9),
    );
    final at = DateTime.utc(2026, 10, 20, 10);
    var published = false;
    final sub = c.activeSessionStream.listen((record) {
      if (record?.hasPendingManualStop == true) published = true;
    });
    store.beforeMaterialize = () async {
      await Future<void>.delayed(Duration.zero);
      expect(published, isTrue);
      expect(
        (await store.allCommands('a'))
            .where((v) => v.type == CommandType.completeIrrigationSession),
        isEmpty,
      );
    };
    await expectLater(
      c.completeSession(
        accountId: 'a',
        sessionLocalId: start.localId,
        completedAt: at,
      ),
      throwsA(
        predicate(
          (Object e) => e.toString().contains(
            'manual_stop_recorded_materialization_pending',
          ),
        ),
      ),
    );
    final request = (await ManualStopRequestStore(store)
        .read(accountId: 'a', wellId: 'w', sessionLocalId: start.localId))!;
    expect(
      (await ActiveSessionProjector(
        store: store,
      ).projectSession('a', start.localId, now: at))!.hasPendingManualStop,
      isTrue,
    );
    store.fail = false;
    store.beforeMaterialize = null;
    // The first root can dispatch; recovery must already have created the stop command.
    final transport = ProbeTransport();
    // Use the default accepted start; stop still lacks a valid matching completion receipt.
    transport.handler = null;
    await SyncEngine(store: store, transport: transport).run('a');
    final end = (await store.allCommands('a'))
        .singleWhere((v) => v.type == CommandType.completeIrrigationSession);
    expect(end.occurredAt, request.requestedAt);
    expect(
      (await ActiveSessionProjector(
        store: store,
      ).projectSession('a', start.localId, now: at))!.hasPendingManualStop,
      isTrue,
    );
    await sub.cancel();
    c.dispose();
  });

  test(
    'human stop is durable and projected before completion acceptance',
    () async {
      final store = InMemoryOutboxStore();
      final coordinator = OfflineSessionCoordinator(store: store);
      final start = await coordinator.startSession(
        accountId: 'a',
        wellId: 'w',
        pumpId: 'pump',
        farmId: 'farm',
        farmerAccountId: 'farmer',
        energySource: 'solar',
        startedAt: DateTime.utc(2026, 10, 20, 9),
      );
      final stopAt = DateTime.utc(2026, 10, 20, 10);
      await coordinator.completeSession(
        accountId: 'a',
        sessionLocalId: start.localId,
        completedAt: stopAt,
      );
      final request = await ManualStopRequestStore(store)
          .read(accountId: 'a', wellId: 'w', sessionLocalId: start.localId);
      expect(request, isNotNull);
      expect(request!.requestedAt, stopAt);
      final projection = (await ActiveSessionProjector(store: store)
          .projectSession('a', start.localId, now: stopAt))!;
      expect(projection.hasPendingManualStop, isTrue);
      expect(projection.completedAt, isNull);
      expect(projection.approvedAmountMinor, isNull);
      expect(projection.businessState.isActive, isTrue);
      expect(
        (await store.allCommands('a'))
            .where((c) => c.type == CommandType.completeIrrigationSession),
        hasLength(1),
      );
      await expectLater(
        coordinator.resumeSession(
          accountId: 'a',
          sessionLocalId: start.localId,
        ),
        throwsStateError,
      );
      await expectLater(
        coordinator.completeSession(
          accountId: 'a',
          sessionLocalId: start.localId,
        ),
        throwsStateError,
      );
      coordinator.dispose();
    },
  );
}

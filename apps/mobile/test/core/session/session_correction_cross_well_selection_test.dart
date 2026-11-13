import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

// علامة إتمام التخزين الأخيرة في SyncEngine، قبل callback المنسق مباشرة.
class _ObservedStore extends InMemoryOutboxStore {
  final syncPersisted = Completer<void>();

  @override
  Future<void> setLastSuccessfulSyncAt(String accountId, DateTime at) async {
    await super.setLastSuccessfulSyncAt(accountId, at);
    if (!syncPersisted.isCompleted) syncPersisted.complete();
  }
}

class _GatedCorrectionTransport implements CommandTransport {
  final entered = Completer<DispatchRequest>();
  final response = Completer<DispatchResult>();
  final requests = <DispatchRequest>[];

  @override
  Future<DispatchResult> dispatch(DispatchRequest request) {
    requests.add(request);
    if (!entered.isCompleted) entered.complete(request);
    return response.future;
  }

  void accept(DispatchRequest request) {
    response.complete(
      DispatchAccepted(
        entityId: null,
        response: {
          'contract': 'session_correction',
          'version': 1,
          'status': 'accepted',
          'tenant_id': 'tenant-a',
          'well_id': 'well-a',
          'session_id': 'server-historical-session-a',
          'command_id': request.commandId,
          'correction_id': 'server-correction-a',
          'previous_revision': 3,
          'operational_revision': 4,
          'actual_started_at': '2026-11-08T02:30:00.000Z',
          'actual_ended_at': '2026-11-08T04:45:00.000Z',
          'accepted_at': '2026-11-09T09:01:00.000Z',
          'financial_status': 'pending',
        },
      ),
    );
  }
}

// فرصة عادية معلقة، ثم فرصة التصحيح في طابور المحرك نفسه.
class _GenerationRaceTransport implements CommandTransport {
  final normalEntered = Completer<DispatchRequest>();
  final normalResponse = Completer<DispatchResult>();
  final correction = _GatedCorrectionTransport();

  @override
  Future<DispatchResult> dispatch(DispatchRequest request) {
    if (request.type == CommandType.createFarmer) {
      normalEntered.complete(request);
      return normalResponse.future;
    }
    return correction.dispatch(request);
  }

  void releaseNormal() {
    if (!normalResponse.isCompleted) {
      normalResponse.complete(const DispatchAccepted(
        response: {'status': 'created', 'farmer_well_account_id': 'server-farmer-b'},
        entityId: 'server-farmer-b',
      ));
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'historical correction sync in well A preserves selected active session B',
    () async {
      final store = _ObservedStore();
      final transport = _GatedCorrectionTransport();
      final coordinator = OfflineSessionCoordinator(
        store: store,
        commandTransport: transport,
      );
      addTearDown(() async {
        if (!transport.response.isCompleted) {
          transport.response.completeError(StateError('test_cleanup'));
        }
        await pumpEventQueue(times: 20);
        coordinator.dispose();
        await store.close();
      });
      await store.initialize();
      final repository = OutboxRepository(store: store);
      final startedAt = DateTime.utc(2026, 11, 9, 8);
      final start = await repository.enqueue(
        accountId: 'account-a',
        wellId: 'well-b',
        type: CommandType.startOperationalSession,
        occurredAt: startedAt,
        payload: const {
          'p_well_id': 'well-b',
          'p_pump_id': 'pump-b',
          'p_farm_id': 'farm-b',
          'p_farmer_well_account_id': 'farmer-b',
          'p_energy_source': 'diesel',
        },
      );
      // الجلسة قائمة بالفعل؛ فرصة المزامنة التالية تخص التصحيح التاريخي.
      await store.markConfirmed(
        'account-a',
        start.localId,
        serverResponse: const {'id': 'server-active-session-b'},
        attemptedAt: startedAt,
      );
      final beforeStart = (await store.commandByLocalId(
        'account-a',
        start.localId,
      ))!;
      final selected = await coordinator.projectActiveSession(
        accountId: 'account-a',
        wellId: 'well-b',
      );
      expect(selected, isNotNull);
      expect(selected!.wellId, 'well-b');
      expect(selected.localId, start.localId);
      expect(selected.businessState, SessionBusinessState.running);
      expect(coordinator.currentActiveSession, isNotNull);
      expect(coordinator.currentActiveSession!.wellId, 'well-b');
      final originalLocalId = selected.localId;
      final originalState = selected.businessState;
      final originalStartedAt = selected.startedAt;

      final correction = await coordinator.submitSessionCorrection(
        accountId: 'account-a',
        wellId: 'well-a',
        sessionId: 'server-historical-session-a',
        baseRevision: 3,
        reason: 'تصحيح وقت التشغيل الفعلي',
        desiredStartedAt: DateTime.utc(2026, 11, 8, 2, 30),
        desiredEndedAt: DateTime.utc(2026, 11, 8, 4, 45),
      );
      final request = await transport.entered.future.timeout(
        const Duration(seconds: 2),
      );
      expect(request.type, CommandType.correctIrrigationSession);
      expect(request.commandId, correction.commandId);
      expect(request.arguments['p_session_id'], 'server-historical-session-a');
      final queued = (await store.commandByLocalId(
        'account-a',
        correction.localId,
      ))!;
      expect(queued.type, CommandType.correctIrrigationSession);
      expect(queued.accountId, 'account-a');
      expect(queued.wellId, 'well-a');
      expect(queued.aggregateLocalId, isNull);
      expect(queued.references, isEmpty);
      expect(queued.payload['p_session_id'], 'server-historical-session-a');
      expect(queued.payload['p_session_id'], isNot(start.localId));
      expect(queued.payload['p_session_id'], isNot('server-active-session-b'));
      expect(coordinator.currentActiveSession!.localId, originalLocalId);

      transport.accept(request);
      await store.syncPersisted.future.timeout(const Duration(seconds: 2));
      // تفريغ الأدوار بعد إتمام المحرك يتيح callback الإسقاط الحالية؛ بلا نوم ثابت.
      await pumpEventQueue(times: 20);
      final confirmed = (await store.commandByLocalId(
        'account-a',
        correction.localId,
      ))!;
      expect(
        confirmed.status,
        CommandStatus.confirmed,
        reason:
            'valid correction receipt must complete the real sync opportunity',
      );
      expect(transport.requests, hasLength(1));
      expect(await store.allCommands('account-a'), hasLength(2));

      final durableB = (await store.commandByLocalId(
        'account-a',
        originalLocalId,
      ))!;
      expect(durableB.localId, beforeStart.localId);
      expect(durableB.commandId, beforeStart.commandId);
      expect(durableB.wellId, 'well-b');
      expect(durableB.payload, beforeStart.payload);
      expect(durableB.occurredAt, beforeStart.occurredAt);
      expect(durableB.status, beforeStart.status);
      // إسقاط خالص لا يعيد ضبط اختيار المنسق ولا يخفي العيب.
      final projectedB = (await ActiveSessionProjector(store: store).projectAll(
        'account-a',
        wellId: 'well-b',
        now: DateTime.utc(2026, 11, 9, 9),
      )).single;
      expect(projectedB.businessState, originalState);
      expect(projectedB.startedAt, originalStartedAt);

      final after = coordinator.currentActiveSession;
      expect(
        after?.wellId,
        'well-b',
        reason: 'historical correction sync must preserve the existing well-B selection',
      );
      expect(after!.localId, originalLocalId);
      expect(after.businessState, originalState);
      expect(after.startedAt, originalStartedAt);
    },
  );
  test('non-projecting correction cannot invalidate a useful in-flight projection', () async {
    final store = _ObservedStore();
    final transport = _GenerationRaceTransport();
    var scheduled = 0;
    final coordinator = OfflineSessionCoordinator(
      store: store,
      commandTransport: transport,
      commandQueuedScheduler: (_) async { scheduled++; return true; },
    );
    addTearDown(() async {
      transport.releaseNormal();
      if (!transport.correction.response.isCompleted) {
        transport.correction.response.completeError(StateError('test_cleanup'));
      }
      await pumpEventQueue(times: 20);
      coordinator.dispose();
      await store.close();
    });
    await store.initialize();
    final repository = OutboxRepository(store: store);
    final start = await repository.enqueue(
      accountId: 'account-a', wellId: 'well-b',
      type: CommandType.startOperationalSession,
      occurredAt: DateTime.utc(2026, 11, 9, 8),
      payload: const {
        'p_well_id': 'well-b', 'p_pump_id': 'pump-b', 'p_farm_id': 'farm-b',
        'p_farmer_well_account_id': 'farmer-b', 'p_energy_source': 'diesel',
      },
    );
    await store.markConfirmed('account-a', start.localId,
      serverResponse: const {'id': 'server-active-session-b'}, attemptedAt: start.occurredAt);
    final selected = await coordinator.projectActiveSession(accountId: 'account-a', wellId: 'well-b');
    expect(selected!.businessState, SessionBusinessState.running);

    // هذا caller عادي يحتاج إعادة إسقاط B بعد انتهاء المزامنة.
    await coordinator.enqueueFarmer(accountId: 'account-a', wellId: 'well-b', fullName: 'مزارع ب');
    await transport.normalEntered.future.timeout(const Duration(seconds: 2));
    expect(scheduled, 1);

    // تغيير متين من مصدر محلي آخر؛ لا نعيد إسقاطه يدويًا في المنسق.
    final pause = await repository.enqueue(
      accountId: 'account-a', wellId: 'well-b', aggregateLocalId: start.localId,
      type: CommandType.pauseIrrigationSession,
      occurredAt: DateTime.utc(2026, 11, 9, 8, 10),
      payload: {'p_session_id': start.localId, 'p_reason': 'operator_pause'},
    );
    await store.markConfirmed('account-a', pause.localId,
      serverResponse: const {'id': 'server-pause-b'}, attemptedAt: pause.occurredAt);
    expect(coordinator.currentActiveSession!.businessState, SessionBusinessState.running);

    final correction = await coordinator.submitSessionCorrection(
      accountId: 'account-a', wellId: 'well-a', sessionId: 'server-historical-session-a',
      baseRevision: 3, reason: 'تصحيح وقت التشغيل الفعلي',
      desiredStartedAt: DateTime.utc(2026, 11, 8, 2, 30),
      desiredEndedAt: DateTime.utc(2026, 11, 8, 4, 45),
    );
    expect(scheduled, 2);
    expect(transport.normalResponse.isCompleted, isFalse);
    transport.releaseNormal();
    final correctionRequest = await transport.correction.entered.future.timeout(const Duration(seconds: 2));
    expect(correctionRequest.type, CommandType.correctIrrigationSession);
    await pumpEventQueue(times: 20);
    // التصحيح ما زال معلقًا؛ التحديث هنا يجب أن يأتي من الفرصة المفيدة الأولى.
    expect(transport.correction.response.isCompleted, isFalse);
    expect(coordinator.currentActiveSession?.localId, start.localId);
    expect(coordinator.currentActiveSession?.businessState, SessionBusinessState.paused,
      reason: 'correction opportunity must not invalidate the earlier useful projection');

    transport.correction.accept(correctionRequest);
    await pumpEventQueue(times: 20);
    expect((await store.commandByLocalId('account-a', correction.localId))!.status, CommandStatus.confirmed);
    expect(coordinator.currentActiveSession?.wellId, 'well-b');
    expect(coordinator.currentActiveSession?.businessState, SessionBusinessState.paused);
  });

}

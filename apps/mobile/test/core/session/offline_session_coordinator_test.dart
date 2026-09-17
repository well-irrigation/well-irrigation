import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_reference.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';

import '../sync/fake_command_transport.dart';

class _ControlledDelayOutboxStore implements OutboxStore {
  _ControlledDelayOutboxStore(this._inner);

  final InMemoryOutboxStore _inner;
  Completer<void>? delayNextAllCommands;
  var allCommandsCalls = 0;

  @override
  Future<void> initialize() => _inner.initialize();

  @override
  Future<CommandEnvelope> insert(CommandEnvelope envelope) =>
      _inner.insert(envelope);

  @override
  Future<int> nextSequence(String accountId) => _inner.nextSequence(accountId);

  @override
  Future<List<CommandEnvelope>> pendingCommands(String accountId) =>
      _inner.pendingCommands(accountId);

  @override
  Future<CommandEnvelope?> commandByLocalId(String accountId, String localId) =>
      _inner.commandByLocalId(accountId, localId);

  @override
  Future<List<CommandEnvelope>> allCommands(String accountId) async {
    allCommandsCalls++;
    if (delayNextAllCommands != null) {
      final completer = delayNextAllCommands;
      delayNextAllCommands = null;
      await completer!.future;
    }
    return _inner.allCommands(accountId);
  }

  @override
  Future<bool> claim(
    String accountId,
    String localId, {
    required DateTime attemptedAt,
  }) => _inner.claim(accountId, localId, attemptedAt: attemptedAt);

  @override
  Future<void> releaseForRetry(
    String accountId,
    String localId, {
    required String error,
    required DateTime attemptedAt,
  }) => _inner.releaseForRetry(
    accountId,
    localId,
    error: error,
    attemptedAt: attemptedAt,
  );

  @override
  Future<void> markConfirmed(
    String accountId,
    String localId, {
    required Map<String, Object?> serverResponse,
    required DateTime attemptedAt,
  }) => _inner.markConfirmed(
    accountId,
    localId,
    serverResponse: serverResponse,
    attemptedAt: attemptedAt,
  );

  @override
  Future<void> markNeedsReview(
    String accountId,
    String localId, {
    required String error,
    required DateTime attemptedAt,
  }) => _inner.markNeedsReview(
    accountId,
    localId,
    error: error,
    attemptedAt: attemptedAt,
  );

  @override
  Future<void> putMapping(String accountId, IdMapping mapping) =>
      _inner.putMapping(accountId, mapping);

  @override
  Future<IdMapping?> mapping(
    String accountId,
    String localId,
    EntityKind kind,
  ) => _inner.mapping(accountId, localId, kind);

  @override
  Future<List<IdMapping>> mappings(String accountId) =>
      _inner.mappings(accountId);

  @override
  Future<DateTime?> lastSuccessfulSyncAt(String accountId) =>
      _inner.lastSuccessfulSyncAt(accountId);

  @override
  Future<void> setLastSuccessfulSyncAt(String accountId, DateTime at) =>
      _inner.setLastSuccessfulSyncAt(accountId, at);

  @override
  Future<void> close() => _inner.close();
}

class _FirstDispatchGateTransport implements CommandTransport {
  final inner = FakeCommandTransport();
  final firstSeen = Completer<DispatchRequest>();
  final releaseFirst = Completer<void>();
  final firstFinished = Completer<void>();
  var _calls = 0;

  @override
  Future<DispatchResult> dispatch(DispatchRequest request) async {
    _calls += 1;
    final isFirst = _calls == 1;
    if (isFirst) {
      firstSeen.complete(request);
      await releaseFirst.future;
    }
    final result = await inner.dispatch(request);
    if (isFirst) firstFinished.complete();
    return result;
  }
}

void main() {
  group('OfflineSessionCoordinator Tests (ق-89 / ق-90 / ق-114)', () {
    late InMemoryOutboxStore store;
    late OfflineSessionCoordinator coordinator;

    setUp(() async {
      store = InMemoryOutboxStore();
      coordinator = OfflineSessionCoordinator(store: store);
      await coordinator.initialize();
    });

    tearDown(() {
      coordinator.dispose();
    });

    test('الجدولة ترى الأمر بعد حفظه وتستخدم حساب مالكه', () async {
      final seen = <String>[];
      coordinator.setCommandQueuedScheduler((accountId) async {
        final commands = await store.allCommands(accountId);
        expect(commands, hasLength(1));
        expect(commands.single.accountId, accountId);
        seen.add(accountId);
        return true;
      });

      await coordinator.startSession(
        accountId: 'A',
        wellId: 'well-01',
        pumpId: 'pump-01',
        farmId: 'farm-01',
        farmerAccountId: 'farmer-01',
        energySource: 'solar',
      );
      expect(seen, ['A']);
    });

    test('فشل المجدول بعد الحفظ لا يحذف الأمر ولا يفشل العملية', () async {
      coordinator.setCommandQueuedScheduler((_) async {
        throw StateError('scheduler unavailable');
      });

      final command = await coordinator.startSession(
        accountId: 'A',
        wellId: 'well-01',
        pumpId: 'pump-01',
        farmId: 'farm-01',
        farmerAccountId: 'farmer-01',
        energySource: 'solar',
      );
      final saved = await store.allCommands('A');
      expect(saved.single.commandId, command.commandId);
    });

    test('1. بدء جلسة سقي جديدة وحفظها محلياً وإسقاطها فوراً', () async {
      final now = DateTime.now();
      final envelope = await coordinator.startSession(
        accountId: 'acc-01',
        wellId: 'well-01',
        pumpId: 'pump-01',
        farmId: 'farm-01',
        farmerAccountId: 'farmer-01',
        energySource: 'طاقة شمسية',
        startedAt: now,
      );

      expect(envelope.localId, isNotEmpty);
      expect(envelope.commandId, isNotEmpty);

      final active = coordinator.currentActiveSession;
      expect(active, isNotNull);
      expect(active!.localId, envelope.localId);
      expect(active.businessState, SessionBusinessState.running);
      expect(active.segments.length, 1);
    });

    test('2. تغيير مصدر الطاقة أثناء السقي يضيف مقطعاً جديداً', () async {
      final start = DateTime.now();
      final startEnv = await coordinator.startSession(
        accountId: 'acc-01',
        wellId: 'well-01',
        pumpId: 'pump-01',
        farmId: 'farm-01',
        farmerAccountId: 'farmer-01',
        energySource: 'طاقة شمسية',
        startedAt: start,
      );

      final changeTime = start.add(const Duration(minutes: 30));
      await coordinator.changeEnergySource(
        accountId: 'acc-01',
        sessionLocalId: startEnv.localId,
        newEnergySource: 'ديزل',
        changedAt: changeTime,
      );

      final active = coordinator.currentActiveSession;
      expect(active, isNotNull);
      expect(active!.segments.length, 2);
      expect(active.segments.last.energySource, 'ديزل');
    });

    test('3. إيقاف الجلسة مؤقتاً ثم استئنافها يعكس حالة التوقف', () async {
      final start = DateTime.now();
      final startEnv = await coordinator.startSession(
        accountId: 'acc-01',
        wellId: 'well-01',
        pumpId: 'pump-01',
        farmId: 'farm-01',
        farmerAccountId: 'farmer-01',
        energySource: 'طاقة شمسية',
        startedAt: start,
      );

      final pauseTime = start.add(const Duration(minutes: 20));
      await coordinator.pauseSession(
        accountId: 'acc-01',
        sessionLocalId: startEnv.localId,
        reason: 'operator_pause',
        pausedAt: pauseTime,
      );

      var active = coordinator.currentActiveSession;
      expect(active, isNotNull);
      expect(active!.businessState, SessionBusinessState.paused);

      final resumeTime = pauseTime.add(const Duration(minutes: 10));
      await coordinator.resumeSession(
        accountId: 'acc-01',
        sessionLocalId: startEnv.localId,
        resumedAt: resumeTime,
      );

      active = coordinator.currentActiveSession;
      expect(active, isNotNull);
      expect(active!.businessState, SessionBusinessState.running);
    });

    test('4. إنهاء الجلسة يغلقها ويفرغ الجلسة النشطة', () async {
      final start = DateTime.now();
      final startEnv = await coordinator.startSession(
        accountId: 'acc-01',
        wellId: 'well-01',
        pumpId: 'pump-01',
        farmId: 'farm-01',
        farmerAccountId: 'farmer-01',
        energySource: 'طاقة شمسية',
        startedAt: start,
      );

      final completeTime = start.add(const Duration(hours: 1));
      await coordinator.completeSession(
        accountId: 'acc-01',
        sessionLocalId: startEnv.localId,
        completedAt: completeTime,
      );

      final active = coordinator.currentActiveSession;
      expect(active, isNull);
    });

    test('5. استعادة الجلسة الجارية بعد إغلاق التطبيق وموت العملية (Process Death)', () async {
      final start = DateTime.now();
      final startEnv = await coordinator.startSession(
        accountId: 'acc-01',
        wellId: 'well-01',
        pumpId: 'pump-01',
        farmId: 'farm-01',
        farmerAccountId: 'farmer-01',
        energySource: 'طاقة شمسية',
        startedAt: start,
      );

      // محاكاة إغلاق التطبيق وإعادة فتحه عبر منسق جديد بنفس المخزن
      final newCoordinator = OfflineSessionCoordinator(store: store);
      final restoredSession = await newCoordinator.projectActiveSession(
        accountId: 'acc-01',
        wellId: 'well-01',
      );

      expect(restoredSession, isNotNull);
      expect(restoredSession!.localId, startEnv.localId);
      expect(restoredSession.businessState, SessionBusinessState.running);
      expect(restoredSession.wellId, 'well-01');

      newCoordinator.dispose();
    });

    test('6. الدفعة تنتظر تكلفة الإنهاء وترسل معرّفها الخادمي', () async {
      final startedAt = DateTime.utc(2026, 9, 15, 8);
      final session = await coordinator.startSession(
        accountId: 'acc-01',
        wellId: 'well-01',
        pumpId: 'pump-01',
        farmId: 'farm-01',
        farmerAccountId: 'farmer-01',
        energySource: 'solar',
        startedAt: startedAt,
      );
      final completion = await coordinator.completeSession(
        accountId: 'acc-01',
        sessionLocalId: session.localId,
        completedAt: startedAt.add(const Duration(minutes: 30)),
      );
      final paymentEnv = await coordinator.recordPayment(
        accountId: 'acc-01',
        wellId: 'well-01',
        farmerAccountId: 'farmer-01',
        amountMinor: 10000,
        paymentMethod: 'cash',
        note: 'سند رقم 101',
        sessionLocalId: session.localId,
        sessionCompletionLocalId: completion.localId,
        paidAt: startedAt.add(const Duration(minutes: 31)),
      );

      expect(paymentEnv.localId, isNotEmpty);
      final allCommands = await store.allCommands('acc-01');
      final stored = allCommands.singleWhere(
        (command) => command.localId == paymentEnv.localId,
      );
      expect(stored.payload, {
        'p_well_id': 'well-01',
        'p_farmer_well_account_id': 'farmer-01',
        'p_amount_minor': 10000,
        'p_method': 'cash',
        'p_session_charge_id': CommandReference(
          localId: completion.localId,
          kind: EntityKind.sessionCharge,
        ).toJson(),
        'p_note': 'سند رقم 101',
      });

      final projected = await ActiveSessionProjector(store: store)
          .projectSession(
            'acc-01',
            session.localId,
            now: startedAt.add(const Duration(minutes: 31)),
          );
      expect(projected!.payments.single.amountMinor, 10000);
      expect(projected.payments.single.method, 'cash');

      final transport = FakeCommandTransport();
      await SyncEngine(store: store, transport: transport).run('acc-01');
      final completionMapping = await store.mapping(
        'acc-01',
        completion.localId,
        EntityKind.sessionCharge,
      );
      expect(completionMapping, isNotNull);
      expect(transport.calledFunctions, [
        'start_irrigation_session',
        'complete_irrigation_session',
        'record_payment',
      ]);
      final dispatched = transport.lastRequestFor(CommandType.recordPayment);
      expect(dispatched.commandId, paymentEnv.commandId);
      expect(dispatched.arguments, {
        'p_well_id': 'well-01',
        'p_farmer_well_account_id': 'farmer-01',
        'p_amount_minor': 10000,
        'p_method': 'cash',
        'p_session_charge_id': completionMapping!.serverId,
        'p_note': 'سند رقم 101',
        'p_command_id': paymentEnv.commandId,
        'p_paid_at': startedAt
            .add(const Duration(minutes: 31))
            .toIso8601String(),
      });
      expect(
        dispatched.arguments['p_session_charge_id'],
        isNot(
          transport
              .lastRequestFor(CommandType.completeIrrigationSession)
              .arguments['p_session_id'],
        ),
      );
    });

    test('طلب بئر بلا جلسة لا يسرّب جلسة بئر أخرى', () async {
      await coordinator.startSession(
        accountId: 'acc-01',
        wellId: 'well-01',
        pumpId: 'pump-01',
        farmId: 'farm-01',
        farmerAccountId: 'farmer-01',
        energySource: 'solar',
      );

      final result = await coordinator.projectActiveSession(
        accountId: 'acc-01',
        wellId: 'well-02',
      );

      expect(result, isNull);
      expect(coordinator.currentActiveSession, isNull);
    });

    test('أوامر الجلسة تُحل إلى معرّف الخادم نفسه وبالترتيب', () async {
      final t0 = DateTime.utc(2026, 9, 15, 8);
      final start = await coordinator.startSession(
        accountId: 'acc-01',
        wellId: 'well-01',
        pumpId: 'pump-01',
        farmId: 'farm-01',
        farmerAccountId: 'farmer-01',
        energySource: 'solar',
        startedAt: t0,
      );
      final pause = await coordinator.pauseSession(
        accountId: 'acc-01',
        sessionLocalId: start.localId,
        reason: 'operator_pause',
        pausedAt: t0.add(const Duration(minutes: 10)),
      );
      final resume = await coordinator.resumeSession(
        accountId: 'acc-01',
        sessionLocalId: start.localId,
        resumedAt: t0.add(const Duration(minutes: 11)),
      );
      final change = await coordinator.changeEnergySource(
        accountId: 'acc-01',
        sessionLocalId: start.localId,
        newEnergySource: 'well_diesel',
        changedAt: t0.add(const Duration(minutes: 12)),
      );
      final complete = await coordinator.completeSession(
        accountId: 'acc-01',
        sessionLocalId: start.localId,
        completedAt: t0.add(const Duration(minutes: 13)),
      );

      final reference = CommandReference(
        localId: start.localId,
        kind: EntityKind.session,
      );
      for (final command in [pause, resume, change, complete]) {
        expect(command.references, {reference});
        expect(command.payload['p_session_id'], reference.toJson());
      }

      final transport = FakeCommandTransport(idPrefix: 'canonical');
      await SyncEngine(store: store, transport: transport).run('acc-01');
      final serverSessionId = transport.requests.first.commandId.isNotEmpty
          ? 'canonical-start_irrigation_session-1'
          : fail('لم يرسل البدء');
      expect(serverSessionId, isNot(start.localId));
      for (final type in [
        CommandType.pauseIrrigationSession,
        CommandType.resumeIrrigationSession,
        CommandType.changeSessionEnergySource,
        CommandType.completeIrrigationSession,
      ]) {
        expect(
          transport.lastRequestFor(type).arguments['p_session_id'],
          serverSessionId,
        );
      }
      expect(
        transport.lastRequestFor(CommandType.pauseIrrigationSession).arguments,
        containsPair('p_reason', 'operator_pause'),
      );
      expect(transport.requests.map((request) => request.commandId), [
        start.commandId,
        pause.commandId,
        resume.commandId,
        change.commandId,
        complete.commandId,
      ]);
    });

    test('فشل البدء الشبكي يمنع إرسال أوامر الجلسة التابعة', () async {
      final t0 = DateTime.utc(2026, 9, 15, 8);
      final start = await coordinator.startSession(
        accountId: 'acc-01',
        wellId: 'well-01',
        pumpId: 'pump-01',
        farmId: 'farm-01',
        farmerAccountId: 'farmer-01',
        energySource: 'solar',
        startedAt: t0,
      );
      await coordinator.pauseSession(
        accountId: 'acc-01',
        sessionLocalId: start.localId,
        reason: 'operator_pause',
        pausedAt: t0.add(const Duration(minutes: 10)),
      );
      await coordinator.completeSession(
        accountId: 'acc-01',
        sessionLocalId: start.localId,
        completedAt: t0.add(const Duration(minutes: 11)),
      );

      final transport = FakeCommandTransport()
        ..scheduleNetworkFailure(CommandType.startIrrigationSession);
      final report = await SyncEngine(
        store: store,
        transport: transport,
      ).run('acc-01');

      expect(transport.calledFunctions, ['start_irrigation_session']);
      expect(report.retryScheduled, 1);
      expect(report.skipped, 2);
    });

    test('تغيير المصدر أثناء التوقف يحفظ المصدر المعلّق دون فوترة ويستأنف به (ق-100)', () async {
      final t0 = DateTime.utc(2026, 9, 15, 8);
      final start = await coordinator.startSession(
        accountId: 'acc-01',
        wellId: 'well-01',
        pumpId: 'pump-01',
        farmId: 'farm-01',
        farmerAccountId: 'farmer-01',
        energySource: 'solar',
        startedAt: t0,
      );
      await expectLater(
        coordinator.pauseSession(
          accountId: 'acc-01',
          sessionLocalId: start.localId,
          reason: 'نص مترجم',
          pausedAt: t0.add(const Duration(minutes: 1)),
        ),
        throwsArgumentError,
      );
      await coordinator.pauseSession(
        accountId: 'acc-01',
        sessionLocalId: start.localId,
        reason: 'operator_pause',
        pausedAt: t0.add(const Duration(minutes: 1)),
      );

      final billableBefore =
          coordinator.currentActiveSession?.totals.billableSeconds;
      expect(billableBefore, isNotNull);

      final changeEnv = await coordinator.changeEnergySource(
        accountId: 'acc-01',
        sessionLocalId: start.localId,
        newEnergySource: 'well_diesel',
        changedAt: t0.add(const Duration(minutes: 2)),
      );

      final commands = await store.allCommands('acc-01');
      final changeCommands = commands
          .where((c) => c.type == CommandType.changeSessionEnergySource)
          .toList();
      expect(changeCommands, hasLength(1));
      expect(changeCommands.single.localId, changeEnv.localId);

      // الجلسة تبقى متوقفة مؤقتاً
      final pausedSession = coordinator.currentActiveSession;
      expect(pausedSession, isNotNull);
      expect(pausedSession!.businessState, SessionBusinessState.paused);
      expect(pausedSession.totals.billableSeconds, billableBefore);
      expect(pausedSession.currentEnergySource, 'well_diesel');

      // لا استئناف تلقائي
      expect(
        commands.where((c) => c.type == CommandType.resumeIrrigationSession),
        isEmpty,
      );

      // الاستئناف يفتح مقطع تشغيل بالمصدر الجديد
      await coordinator.resumeSession(
        accountId: 'acc-01',
        sessionLocalId: start.localId,
        resumedAt: t0.add(const Duration(minutes: 3)),
      );

      final resumedSession = coordinator.currentActiveSession;
      expect(resumedSession, isNotNull);
      expect(resumedSession!.businessState, SessionBusinessState.running);
      expect(resumedSession.currentEnergySource, 'well_diesel');
      expect(resumedSession.segments.last.energySource, 'well_diesel');
      expect(resumedSession.segments.last.kind.isBillable, isTrue);
    });

    test('يرفض دفعة منسوبة إلى جلسة بلا مرجع تكلفة الإنهاء', () async {
      final start = await coordinator.startSession(
        accountId: 'acc-01',
        wellId: 'well-01',
        pumpId: 'pump-01',
        farmId: 'farm-01',
        farmerAccountId: 'farmer-01',
        energySource: 'solar',
      );

      await expectLater(
        coordinator.recordPayment(
          accountId: 'acc-01',
          wellId: 'well-01',
          farmerAccountId: 'farmer-01',
          amountMinor: 1000,
          paymentMethod: 'cash',
          sessionLocalId: start.localId,
        ),
        throwsStateError,
      );
      expect(
        (await store.allCommands('acc-01'))
            .where((command) => command.type == CommandType.recordPayment),
        isEmpty,
      );
    });

    test(
      'كل فعل يعيد إسقاط جلسة البئر المقصودة في حساب متعدد الآبار',
      () async {
        final t0 = DateTime.utc(2026, 9, 15, 8);
        await coordinator.startSession(
          accountId: 'acc-01',
          wellId: 'well-01',
          pumpId: 'pump-01',
          farmId: 'farm-01',
          farmerAccountId: 'farmer-01',
          energySource: 'solar',
          startedAt: t0,
        );
        final w2 = await coordinator.startSession(
          accountId: 'acc-01',
          wellId: 'well-02',
          pumpId: 'pump-02',
          farmId: 'farm-02',
          farmerAccountId: 'farmer-02',
          energySource: 'solar',
          startedAt: t0.add(const Duration(seconds: 1)),
        );
        final emitted = <ActiveSessionRecord?>[];
        final subscription = coordinator.activeSessionStream.listen(
          emitted.add,
        );
        addTearDown(subscription.cancel);

        await coordinator.pauseSession(
          accountId: 'acc-01',
          sessionLocalId: w2.localId,
          reason: 'operator_pause',
          pausedAt: t0.add(const Duration(minutes: 1)),
        );
        expect(coordinator.currentActiveSession?.wellId, 'well-02');
        expect(
          coordinator.currentActiveSession?.businessState,
          SessionBusinessState.paused,
        );
        await Future<void>.delayed(Duration.zero);
        expect(emitted.last?.wellId, 'well-02');
        await coordinator.resumeSession(
          accountId: 'acc-01',
          sessionLocalId: w2.localId,
          resumedAt: t0.add(const Duration(minutes: 2)),
        );
        expect(coordinator.currentActiveSession?.wellId, 'well-02');
        await Future<void>.delayed(Duration.zero);
        expect(emitted.last?.wellId, 'well-02');
        await coordinator.changeEnergySource(
          accountId: 'acc-01',
          sessionLocalId: w2.localId,
          newEnergySource: 'well_diesel',
          changedAt: t0.add(const Duration(minutes: 3)),
        );
        expect(coordinator.currentActiveSession?.wellId, 'well-02');
        await Future<void>.delayed(Duration.zero);
        expect(emitted.last?.wellId, 'well-02');
        await coordinator.completeSession(
          accountId: 'acc-01',
          sessionLocalId: w2.localId,
          completedAt: t0.add(const Duration(minutes: 4)),
        );
        expect(coordinator.currentActiveSession, isNull);
        await Future<void>.delayed(Duration.zero);
        expect(emitted.last, isNull);
      },
    );

    test('اكتمال مزامنة أقدم لا يعيد الحالة من W2 إلى W1', () async {
      final localStore = InMemoryOutboxStore();
      final transport = _FirstDispatchGateTransport();
      final wired = OfflineSessionCoordinator(
        store: localStore,
        commandTransport: transport,
      );
      await wired.initialize();
      addTearDown(wired.dispose);
      final t0 = DateTime.utc(2026, 9, 15, 8);

      await wired.startSession(
        accountId: 'acc-01',
        wellId: 'well-01',
        pumpId: 'pump-01',
        farmId: 'farm-01',
        farmerAccountId: 'farmer-01',
        energySource: 'solar',
        startedAt: t0,
      );
      await transport.firstSeen.future;
      await wired.startSession(
        accountId: 'acc-01',
        wellId: 'well-02',
        pumpId: 'pump-02',
        farmId: 'farm-02',
        farmerAccountId: 'farmer-02',
        energySource: 'solar',
        startedAt: t0.add(const Duration(seconds: 1)),
      );
      expect(wired.currentActiveSession?.wellId, 'well-02');

      transport.releaseFirst.complete();
      await transport.firstFinished.future;
      await Future<void>.delayed(Duration.zero);

      expect(wired.currentActiveSession?.wellId, 'well-02');
    });

    test(
      'إسقاط جديد قديم بدأ أولاً لا يكتب على إسقاط أحدث بدأ لاحقاً واكتمل قبله (Goal 3 — Stale Projection Ordering)',
      () async {
        final innerStore = InMemoryOutboxStore();
        final controlledStore = _ControlledDelayOutboxStore(innerStore);
        final coord = OfflineSessionCoordinator(store: controlledStore);
        await coord.initialize();
        addTearDown(coord.dispose);

        // نبدأ جلسة على البئر الأول
        final s1 = await coord.startSession(
          accountId: 'acc-01',
          wellId: 'well-01',
          pumpId: 'pump-01',
          farmId: 'farm-01',
          farmerAccountId: 'farmer-01',
          energySource: 'solar',
        );
        expect(coord.currentActiveSession?.localId, s1.localId);

        // نراقب ما يُبث عبر activeSessionStream
        final emitted = <ActiveSessionRecord?>[];
        final sub = coord.activeSessionStream.listen(emitted.add);
        addTearDown(sub.cancel);

        // نجهز تأخير الاستدعاء التالي لـ allCommands
        final delayFirst = Completer<void>();
        controlledStore.delayNextAllCommands = delayFirst;

        // 1. نبدأ الإسقاط القديم (جيل 1)
        final futureOld = coord.freshProjectActiveSession(
          accountId: 'acc-01',
          wellId: 'well-01',
        );

        // 2. نبدأ جلسة على البئر الثاني
        final s2 = await coord.startSession(
          accountId: 'acc-01',
          wellId: 'well-02',
          pumpId: 'pump-02',
          farmId: 'farm-02',
          farmerAccountId: 'farmer-02',
          energySource: 'diesel',
        );

        // 3. نشغل إسقاطاً جديداً للبئر الثاني (جيل 2)
        // لن يتأخر لأن allCommandsCalls صار 2
        final recent = await coord.freshProjectActiveSession(
          accountId: 'acc-01',
          wellId: 'well-02',
        );
        await Future<void>.delayed(Duration.zero);

        expect(recent?.localId, s2.localId);
        expect(coord.currentActiveSession?.localId, s2.localId);
        final emittedCountAfterNew = emitted.length;
        expect(emitted.last?.localId, s2.localId);

        // 4. الآن نسمح للإسقاط القديم (جيل 1) بالاكتمال
        delayFirst.complete();
        final oldResult = await futureOld;
        await Future<void>.delayed(Duration.zero);

        // النتيجة المعادة من الدالة القديمة هي الحالة الأحدث،
        // ولم تكتب s1 على s2، ولم تبث s1 في الـ stream!
        expect(oldResult?.localId, s2.localId);
        expect(coord.currentActiveSession?.localId, s2.localId);
        expect(emitted.length, emittedCountAfterNew);
        expect(emitted.last?.localId, s2.localId);
      },
    );

    group('حل تعارض وترشيح الجلسات النشطة (Goal 7 — ق-129)', () {
      test('صفر مرشحين (zero candidates) ⟹ null', () async {
        final res = await coordinator.projectActiveSession(
          accountId: 'acc-01',
          wellId: 'well-non-existent',
        );
        expect(res, isNull);
        expect(coordinator.currentActiveSession, isNull);
      });

      test('مرشح واحد مطابق (one candidate) ⟹ يُعاد بنجاح', () async {
        final s1 = await coordinator.startSession(
          accountId: 'acc-01',
          wellId: 'well-01',
          pumpId: 'pump-01',
          farmId: 'farm-01',
          farmerAccountId: 'farmer-01',
          energySource: 'solar',
        );

        final res = await coordinator.projectActiveSession(
          accountId: 'acc-01',
          wellId: 'well-01',
        );
        expect(res, isNotNull);
        expect(res!.localId, s1.localId);
        expect(coordinator.currentActiveSession?.localId, s1.localId);
      });

      test(
        'مرشحان اثنان لنفس البئر (two candidates) ⟹ null ولا يُختار أي منهما ضمنياً',
        () async {
          await coordinator.startSession(
            accountId: 'acc-01',
            wellId: 'well-01',
            pumpId: 'pump-01',
            farmId: 'farm-01',
            farmerAccountId: 'farmer-01',
            energySource: 'solar',
          );
          // ندخل أمراً ثانياً على نفس البئر
          await store.insert(
            CommandEnvelope(
              commandId: 'cmd-dup-start',
              accountId: 'acc-01',
              type: CommandType.startIrrigationSession,
              wellId: 'well-01',
              localId: 'local-dup-start',
              occurredAt: DateTime.now().add(const Duration(seconds: 1)),
              createdLocalAt: DateTime.now().add(const Duration(seconds: 1)),
              sequence: 99,
              payload: {
                'p_well_id': 'well-01',
                'p_pump_id': 'pump-01',
                'p_farm_id': 'farm-01',
                'p_farmer_well_account_id': 'farmer-01',
                'p_energy_source': 'solar',
              },
            ),
          );

          final res = await coordinator.projectActiveSession(
            accountId: 'acc-01',
            wellId: 'well-01',
          );
          // لا اختيار عشوائي أو ضمني لأحدهما عند الغموض
          expect(res, isNull);
          expect(coordinator.currentActiveSession, isNull);
        },
      );

      test(
        'مرشحان لبئرين مختلفين وبحث عام بلا wellId ⟹ null لغموض الطلب',
        () async {
          await coordinator.startSession(
            accountId: 'acc-01',
            wellId: 'well-01',
            pumpId: 'pump-01',
            farmId: 'farm-01',
            farmerAccountId: 'farmer-01',
            energySource: 'solar',
          );
          await coordinator.startSession(
            accountId: 'acc-01',
            wellId: 'well-02',
            pumpId: 'pump-02',
            farmId: 'farm-02',
            farmerAccountId: 'farmer-02',
            energySource: 'diesel',
          );

          final res = await coordinator.projectActiveSession(
            accountId: 'acc-01',
            wellId: null,
          );
          expect(res, isNull);
        },
      );
    });
  });
}

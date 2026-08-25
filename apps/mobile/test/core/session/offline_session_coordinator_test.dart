import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';


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
        reason: 'صيانة القناة',
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

    test('6. تسجيل دفعة مالية وسند قبض', () async {
      final paymentEnv = await coordinator.recordPayment(
        accountId: 'acc-01',
        wellId: 'well-01',
        farmerAccountId: 'farmer-01',
        amountMinor: 10000,
        paymentMethod: 'نقد',
        reference: 'سند رقم 101',
      );

      expect(paymentEnv.localId, isNotEmpty);
      final allCommands = await store.allCommands('acc-01');
      expect(allCommands.any((c) => c.localId == paymentEnv.localId), isTrue);
    });
  });
}

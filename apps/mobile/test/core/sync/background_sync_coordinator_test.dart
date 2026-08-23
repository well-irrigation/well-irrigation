/// الإرسال الخلفي من طرفه إلى طرفه — بطابور حقيقي وخادم مزيَّف.
///
/// كل اختبار هنا يجيب سؤالًا يخصّ المستخدم لا الكود: هل تصل عملياته وهو
/// لا يفتح التطبيق؟ هل يُوقظ هاتفه بلا فائدة؟ هل تُرسل عملية مرتين؟
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/background_sync_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/background_sync_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import 'fake_background_sync_scheduler.dart';
import 'fake_command_transport.dart';
import 'sync_test_support.dart';

void main() {
  late InMemoryOutboxStore store;
  late OutboxRepository repository;
  late FakeCommandTransport transport;
  late SyncEngine engine;
  late FakeBackgroundSyncScheduler scheduler;
  late BackgroundSyncCoordinator coordinator;

  setUp(() async {
    testNow = DateTime.utc(2026, 8, 23, 6);
    store = InMemoryOutboxStore();
    repository = OutboxRepository(
      store: store,
      idGenerator: SequentialIdGenerator(),
      clock: clock,
    );
    transport = FakeCommandTransport();
    engine = SyncEngine(store: store, transport: transport, clock: clock);
    scheduler = FakeBackgroundSyncScheduler();
    coordinator = BackgroundSyncCoordinator(
      engine: engine,
      scheduler: scheduler,
    );
    await repository.initialize();
  });

  Future<CommandEnvelope> enqueuePayment({int amountMinor = 250000}) =>
      repository.enqueue(
        accountId: accountA,
        type: CommandType.recordPayment,
        payload: recordPaymentPayload(
          farmerWellAccount: 'fwa-1',
          amountMinor: amountMinor,
        ),
        occurredAt: testNow,
        wellId: wellOne,
      );

  group('الإرسال بلا فتح التطبيق', () {
    test('عملية سُجّلت والتطبيق مغلق تُرسل ثم لا يُوقظ الهاتف', () async {
      await enqueuePayment();

      final decision = await coordinator.runFromWorker(accountA);

      expect(transport.executionCount, 1);
      expect(decision.outcome, BackgroundSyncOutcome.allSent);
      expect(decision.shouldRetry, isFalse);
      // العامل لا يجدول بنفسه؛ قيمة الإرجاع وحدها تحاور النظام.
      expect(scheduler.scheduled, isEmpty);
    });

    test('طابور فارغ: لا إرسال ولا موعد جديد', () async {
      final decision = await coordinator.runFromWorker(accountA);

      expect(transport.requests, isEmpty);
      expect(decision.outcome, BackgroundSyncOutcome.nothingToSend);
      expect(decision.shouldRetry, isFalse);
    });

    test('انقطاع الشبكة يبقي العملية ويطلب موعدًا لاحقًا', () async {
      await enqueuePayment();
      transport.scheduleNetworkFailure(CommandType.recordPayment);

      final decision = await coordinator.runFromWorker(accountA);

      expect(transport.executionCount, 0, reason: 'لم يُنفّذ الخادم شيئًا');
      expect(decision.outcome, BackgroundSyncOutcome.retryLater);
      expect(decision.retryDelay, const Duration(seconds: 30));

      final pending = await store.pendingCommands(accountA);
      expect(pending.single.status, CommandStatus.pending);
      expect(pending.single.retryCount, 1);
    });

    test('المحاولة الثالثة تنتظر أطول من الأولى', () async {
      await enqueuePayment();
      transport.scheduleNetworkFailure(CommandType.recordPayment, times: 3);

      final first = await coordinator.runFromWorker(accountA, attempt: 1);
      final third = await coordinator.runFromWorker(accountA, attempt: 3);

      expect(first.retryDelay, const Duration(seconds: 30));
      expect(third.retryDelay, const Duration(minutes: 2));
      expect(third.nextAttempt, 4);
    });

    test('الشبكة تعود في المحاولة الثانية فتصل العملية مرة واحدة', () async {
      await enqueuePayment();
      transport.scheduleNetworkFailure(CommandType.recordPayment);

      final first = await coordinator.runFromWorker(accountA);
      final second = await coordinator.runFromWorker(accountA, attempt: 2);

      expect(first.shouldRetry, isTrue);
      expect(second.outcome, BackgroundSyncOutcome.allSent);
      expect(transport.requests.length, 2, reason: 'محاولتان');
      expect(transport.executionCount, 1, reason: 'تنفيذ واحد');
    });
  });

  group('لا إيقاظ بلا فائدة', () {
    test('رفض عملي لا يُوقظ الهاتف مرة أخرى', () async {
      await enqueuePayment();
      transport.scheduleBusinessRejection(CommandType.recordPayment);

      final decision = await coordinator.runFromWorker(accountA);

      expect(decision.outcome, BackgroundSyncOutcome.awaitsHumanDecision);
      expect(decision.shouldRetry, isFalse);
      expect(
        (await store.pendingCommands(accountA)).single.status,
        CommandStatus.review,
      );
    });

    test('تشغيلٌ تالٍ على طابورٍ كله مراجعة يبقى بلا موعد', () async {
      // الحالة التي كانت ستصير حلقة أبدية: أوامر لاحقة موقوفة خلف أمرٍ
      // يحتاج مراجعة، فـ`skipped` أكبر من صفر في كل تشغيل إلى الأبد.
      final start = await repository.enqueue(
        accountId: accountA,
        type: CommandType.startIrrigationSession,
        payload: startSessionPayload(
          farm: 'farm-1',
          farmerWellAccount: 'fwa-1',
        ),
        occurredAt: testNow,
        wellId: wellOne,
      );

      await repository.enqueue(
        accountId: accountA,
        type: CommandType.completeIrrigationSession,
        payload: sessionEventPayload(
          session: repository.referenceTo(start).toJson(),
        ),
        occurredAt: testNow.add(const Duration(hours: 1)),
        wellId: wellOne,
        aggregateLocalId: start.localId,
      );

      transport.scheduleBusinessRejection(CommandType.startIrrigationSession);

      final first = await coordinator.runFromWorker(accountA);
      final second = await coordinator.runFromWorker(accountA, attempt: 2);

      expect(first.outcome, BackgroundSyncOutcome.awaitsHumanDecision);
      expect(second.outcome, BackgroundSyncOutcome.awaitsHumanDecision);
      expect(second.shouldRetry, isFalse);
      expect(scheduler.scheduled, isEmpty);
    });

    test('مرجعٌ معلَّق خلف أمرٍ للمراجعة لا يُعاد إلى الأبد', () async {
      // المزارع رُفض إنشاؤه، والأرض تشير إليه. المرجع لن يُحلّ أبدًا بلا
      // إنسان — وهما أصلان مختلفان، فلا يكفي حجب الأصل الواحد.
      final farmer = await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(),
        occurredAt: testNow,
        wellId: wellOne,
      );

      await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarm,
        payload: createFarmPayload(
          farmerWellAccount: repository.referenceTo(farmer).toJson(),
        ),
        occurredAt: testNow.add(const Duration(minutes: 5)),
        wellId: wellOne,
      );

      transport.scheduleBusinessRejection(CommandType.createFarmer);

      await coordinator.runFromWorker(accountA);
      final second = await coordinator.runFromWorker(accountA, attempt: 2);

      expect(second.outcome, BackgroundSyncOutcome.awaitsHumanDecision);
      expect(second.shouldRetry, isFalse);
    });

    test('بئرٌ للمراجعة لا تُوقف بئرًا أخرى تنتظر الشبكة', () async {
      await repository.enqueue(
        accountId: accountA,
        type: CommandType.startIrrigationSession,
        payload: startSessionPayload(
          farm: 'farm-1',
          farmerWellAccount: 'fwa-1',
          well: wellOne,
        ),
        occurredAt: testNow,
        wellId: wellOne,
      );

      await enqueuePayment();

      transport.scheduleBusinessRejection(CommandType.startIrrigationSession);
      transport.scheduleNetworkFailure(CommandType.recordPayment);

      final decision = await coordinator.runFromWorker(accountA);

      expect(decision.outcome, BackgroundSyncOutcome.retryLater);
      expect(decision.shouldRetry, isTrue);
    });
  });

  group('تفريغ الطابور في نافذة واحدة', () {
    test('عشر عمليات تُرسل كلها في تشغيل خلفي واحد', () async {
      for (var index = 0; index < 10; index += 1) {
        await enqueuePayment(amountMinor: 1000 * (index + 1));
      }

      final decision = await coordinator.runFromWorker(accountA);

      expect(transport.executionCount, 10);
      expect(decision.outcome, BackgroundSyncOutcome.allSent);
      expect(coordinator.passesInLastRun, 1, reason: 'تمريرة واحدة تكفي');
    });

    test('فشلٌ في منتصف طابور طويل يُعاد التمرير بعد التقدّم', () async {
      // ثلاث جلسات على ثلاث آبار: الأولى تفشل شبكيًا مرة، والبقية تنجح.
      // التمريرة الأولى تُنجز ما استطاعت، والثانية تُنجز الباقي — بلا
      // انتظار نافذة تراجع جديدة لكل أمر.
      for (final well in [wellOne, wellTwo, 'well-0000-0000-0003']) {
        await repository.enqueue(
          accountId: accountA,
          type: CommandType.startIrrigationSession,
          payload: startSessionPayload(
            farm: 'farm-$well',
            farmerWellAccount: 'fwa-$well',
            well: well,
          ),
          occurredAt: testNow,
          wellId: well,
        );
      }

      transport.scheduleNetworkFailure(CommandType.startIrrigationSession);

      final decision = await coordinator.runFromWorker(accountA);

      expect(coordinator.passesInLastRun, greaterThan(1));
      expect(transport.executionCount, 3);
      expect(decision.outcome, BackgroundSyncOutcome.allSent);
    });

    test('بلا تقدّم لا تتكرر التمريرة', () async {
      await enqueuePayment();
      transport.scheduleNetworkFailure(CommandType.recordPayment, times: 5);

      await coordinator.runFromWorker(accountA);

      expect(coordinator.passesInLastRun, 1);
      expect(transport.requests.length, 1);
    });
  });

  group('العامل والتطبيق معًا', () {
    test('العامل لا يُرسل ما يُرسله التطبيق الآن', () async {
      await enqueuePayment();

      // حلقة التطبيق شغّالة، والعامل استُدعي في نفس اللحظة.
      final appRun = engine.run(accountA);
      final workerDecision = await coordinator.runFromWorker(accountA);

      await appRun;

      expect(workerDecision.outcome, BackgroundSyncOutcome.alreadyRunning);
      expect(workerDecision.retryDelay, const Duration(minutes: 1));
      expect(transport.executionCount, 1, reason: 'تنفيذ واحد لا اثنان');
    });

    test('التشغيل من التطبيق يجدول العمل الخلفي بنفسه', () async {
      await enqueuePayment();
      transport.scheduleNetworkFailure(CommandType.recordPayment);

      final decision = await coordinator.runFromApp(accountA);

      expect(decision.shouldRetry, isTrue);
      expect(scheduler.count, 1);
      expect(scheduler.last.accountId, accountA);
      expect(scheduler.last.delay, const Duration(seconds: 30));
      expect(scheduler.last.attempt, 2);
      expect(scheduler.last.replaceExisting, isFalse);
    });

    test('نجاح كامل من التطبيق لا يجدول عملًا خلفيًا', () async {
      await enqueuePayment();

      final decision = await coordinator.runFromApp(accountA);

      expect(decision.outcome, BackgroundSyncOutcome.allSent);
      expect(scheduler.scheduled, isEmpty);
    });

    test('حجزٌ مات العامل في منتصفه يُستعاد بلا تنفيذ ثانٍ', () async {
      await enqueuePayment();

      // الخادم نفّذ العملية ثم قُتل العامل قبل أن يسجّل التأكيد.
      transport.swallowAckOnce.add(CommandType.recordPayment.rpcName);
      final first = await coordinator.runFromWorker(accountA);

      expect(first.shouldRetry, isTrue);
      expect(transport.executionCount, 1);

      advanceClock(const Duration(minutes: 3));
      final second = await coordinator.runFromWorker(accountA, attempt: 2);

      expect(second.outcome, BackgroundSyncOutcome.allSent);
      expect(transport.executionCount, 1, reason: 'نفس معرّف العملية');
      expect(
        (await store.allCommands(accountA)).single.status,
        CommandStatus.confirmed,
      );
    });

    test('السياسة مضبوطة من الخارج فتُغيَّر بلا تعديل الحلقة', () async {
      await enqueuePayment();
      transport.scheduleNetworkFailure(CommandType.recordPayment);

      final slow = BackgroundSyncCoordinator(
        engine: engine,
        scheduler: scheduler,
        policy: const BackgroundSyncPolicy(
          firstDelay: Duration(minutes: 5),
          maxDelay: Duration(minutes: 20),
        ),
      );

      final decision = await slow.runFromWorker(accountA, attempt: 4);

      expect(decision.retryDelay, const Duration(minutes: 20));
    });
  });
}

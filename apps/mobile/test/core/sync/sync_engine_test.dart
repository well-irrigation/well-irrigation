/// الترتيب والحجب وحلّ المراجع والحجز — سلوك حلقة الإرسال.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_reference.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import 'fake_command_transport.dart';
import 'sync_test_support.dart';

void main() {
  late InMemoryOutboxStore store;
  late OutboxRepository repository;
  late FakeCommandTransport transport;
  late SyncEngine engine;

  setUp(() async {
    testNow = DateTime.utc(2026, 8, 22, 6);
    store = InMemoryOutboxStore();
    repository = OutboxRepository(
      store: store,
      idGenerator: SequentialIdGenerator(),
      clock: clock,
    );
    transport = FakeCommandTransport();
    engine = SyncEngine(store: store, transport: transport, clock: clock);
    await repository.initialize();
  });

  /// جلسة كاملة على بئر واحدة: بدء ثم إيقاف ثم استئناف ثم إنهاء.
  Future<List<CommandEnvelope>> enqueueFullSession({
    String well = wellOne,
  }) async {
    final start = await repository.enqueue(
      accountId: accountA,
      type: CommandType.startIrrigationSession,
      payload: startSessionPayload(
        farm: 'farm-1',
        farmerWellAccount: 'fwa-1',
        well: well,
      ),
      occurredAt: DateTime.utc(2026, 8, 22, 5),
      wellId: well,
    );

    final session = repository.referenceTo(start).toJson();

    final pause = await repository.enqueue(
      accountId: accountA,
      type: CommandType.pauseIrrigationSession,
      payload: sessionEventPayload(
        session: session,
        extra: const {'p_reason': 'نفد الوقود'},
      ),
      occurredAt: DateTime.utc(2026, 8, 22, 5, 30),
      wellId: well,
      aggregateLocalId: start.localId,
    );

    final resume = await repository.enqueue(
      accountId: accountA,
      type: CommandType.resumeIrrigationSession,
      payload: sessionEventPayload(session: session),
      occurredAt: DateTime.utc(2026, 8, 22, 5, 50),
      wellId: well,
      aggregateLocalId: start.localId,
    );

    final complete = await repository.enqueue(
      accountId: accountA,
      type: CommandType.completeIrrigationSession,
      payload: sessionEventPayload(session: session),
      occurredAt: DateTime.utc(2026, 8, 22, 6, 20),
      wellId: well,
      aggregateLocalId: start.localId,
    );

    return [start, pause, resume, complete];
  }

  group('الترتيب داخل الجلسة', () {
    test('تُرسل بترتيب وقوعها لا بترتيب وصول الشبكة', () async {
      final commands = await enqueueFullSession();

      expect(transport.requests, isEmpty);

      final report = await engine.run(accountA);

      expect(report.confirmed, 4);
      expect(transport.calledFunctions, [
        'start_irrigation_session',
        'pause_irrigation_session',
        'resume_irrigation_session',
        'complete_irrigation_session',
      ]);

      for (final command in commands) {
        final stored = await repository.byLocalId(accountA, command.localId);

        expect(stored!.status, CommandStatus.confirmed);
      }

      expect(await repository.pending(accountA), isEmpty);
    });

    test('حدث لجلسة لم تُحسم لا يُرسل، وبئر أخرى تكمل', () async {
      final sessionOne = await enqueueFullSession();
      final startTwo = await repository.enqueue(
        accountId: accountA,
        type: CommandType.startIrrigationSession,
        payload: startSessionPayload(
          farm: 'farm-2',
          farmerWellAccount: 'fwa-2',
          well: wellTwo,
        ),
        occurredAt: DateTime.utc(2026, 8, 22, 5, 10),
        wellId: wellTwo,
      );

      // أول محاولة بدء تفشل — وهي بدء الجلسة الأولى (الأدنى ترتيبًا).
      transport.scheduleNetworkFailure(CommandType.startIrrigationSession);

      final first = await engine.run(accountA);

      expect(first.retryScheduled, 1);
      expect(first.confirmed, 1);
      expect(first.skipped, 3);
      expect(transport.calledFunctions, [
        'start_irrigation_session',
        'start_irrigation_session',
      ]);
      expect(transport.requestsFor(CommandType.pauseIrrigationSession), isEmpty);

      final startedTwo = await repository.byLocalId(accountA, startTwo.localId);

      expect(startedTwo!.status, CommandStatus.confirmed);

      // التشغيل التالي يُكمل الجلسة الأولى بالترتيب.
      advanceClock(const Duration(minutes: 4));
      final second = await engine.run(accountA);

      expect(second.confirmed, 4);
      expect(transport.calledFunctions.sublist(2), [
        'start_irrigation_session',
        'pause_irrigation_session',
        'resume_irrigation_session',
        'complete_irrigation_session',
      ]);

      final start = await repository.byLocalId(
        accountA,
        sessionOne.first.localId,
      );

      expect(start!.retryCount, 1);
      expect(start.status, CommandStatus.confirmed);
    });

    test('رفض عملي يوقف الجلسة ولا يُعاد إرساله', () async {
      final commands = await enqueueFullSession();

      transport.scheduleBusinessRejection(CommandType.pauseIrrigationSession);

      final first = await engine.run(accountA);

      expect(first.confirmed, 1);
      expect(first.needsReview, 1);
      expect(first.skipped, 2);

      final paused = await repository.byLocalId(accountA, commands[1].localId);

      expect(paused!.status, CommandStatus.review);
      expect(paused.statusText, 'يحتاج مراجعة');
      expect(await repository.needingReview(accountA), hasLength(1));

      // لا إعادة عمياء: التشغيل التالي لا يحاول شيئًا.
      advanceClock(const Duration(minutes: 10));
      final second = await engine.run(accountA);

      expect(second.attempted, 0);
      expect(second.skipped, 3);
      expect(
        transport.requestsFor(CommandType.pauseIrrigationSession),
        hasLength(1),
      );
      expect(
        transport.requestsFor(CommandType.completeIrrigationSession),
        isEmpty,
      );
    });
  });

  group('حلّ المراجع عبر الأصول', () {
    test('دورة كاملة بلا شبكة ثم تُحسم مراجعها عند الإرسال', () async {
      final farmer = await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(),
        occurredAt: DateTime.utc(2026, 8, 22, 4),
        wellId: wellOne,
      );
      final farm = await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarm,
        payload: createFarmPayload(
          farmerWellAccount: repository.referenceTo(farmer).toJson(),
        ),
        occurredAt: DateTime.utc(2026, 8, 22, 4, 10),
        wellId: wellOne,
      );
      final start = await repository.enqueue(
        accountId: accountA,
        type: CommandType.startIrrigationSession,
        payload: startSessionPayload(
          farm: repository.referenceTo(farm).toJson(),
          farmerWellAccount: repository.referenceTo(farmer).toJson(),
        ),
        occurredAt: DateTime.utc(2026, 8, 22, 4, 20),
        wellId: wellOne,
      );
      final payment = await repository.enqueue(
        accountId: accountA,
        type: CommandType.recordPayment,
        payload: recordPaymentPayload(
          farmerWellAccount: repository.referenceTo(farmer).toJson(),
        ),
        occurredAt: DateTime.utc(2026, 8, 22, 6, 30),
        wellId: wellOne,
      );

      expect(transport.requests, isEmpty);
      expect(await repository.pendingCount(accountA), 4);

      final report = await engine.run(accountA);

      expect(report.confirmed, 4);

      final farmerId = await repository.serverIdFor(
        accountA,
        farmer.localId,
        EntityKind.farmerWellAccount,
      );
      final farmId = await repository.serverIdFor(
        accountA,
        farm.localId,
        EntityKind.farm,
      );
      final sessionId = await repository.serverIdFor(
        accountA,
        start.localId,
        EntityKind.session,
      );

      expect(farmerId, isNotNull);
      expect(farmId, isNotNull);
      expect(sessionId, isNotNull);

      expect(
        transport
            .lastRequestFor(CommandType.createFarm)
            .arguments['p_farmer_well_account_id'],
        farmerId,
      );

      final startArguments = transport
          .lastRequestFor(CommandType.startIrrigationSession)
          .arguments;

      expect(startArguments['p_farm_id'], farmId);
      expect(startArguments['p_farmer_well_account_id'], farmerId);

      expect(
        transport
            .lastRequestFor(CommandType.recordPayment)
            .arguments['p_farmer_well_account_id'],
        farmerId,
      );

      // لا مرجع غير محسوم بقي في أي وسيط مُرسَل.
      for (final request in transport.requests) {
        for (final value in request.arguments.values) {
          expect(CommandReference.isReference(value), isFalse);
        }
      }

      expect(payment.references, hasLength(1));
    });

    test('أمر بمرجع غير محسوم لا يُرسل أبدًا', () async {
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
        occurredAt: testNow,
        wellId: wellOne,
      );

      transport.scheduleNetworkFailure(CommandType.createFarmer);

      final report = await engine.run(accountA);

      expect(report.retryScheduled, 1);
      expect(report.skipped, 1);
      expect(transport.requestsFor(CommandType.createFarm), isEmpty);
    });

    test('الخادم يطابق مزارعًا قائمًا فيُربط به بلا إنشاء مكرَّر', () async {
      transport.matchExistingFarmer = true;

      final farmer = await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(),
        occurredAt: testNow,
        wellId: wellOne,
      );
      final farm = await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarm,
        payload: createFarmPayload(
          farmerWellAccount: repository.referenceTo(farmer).toJson(),
        ),
        occurredAt: testNow,
        wellId: wellOne,
      );

      final report = await engine.run(accountA);

      expect(report.confirmed, 2);
      expect(transport.requestsFor(CommandType.createFarmer), hasLength(1));

      final mapping = await store.mapping(
        accountA,
        farmer.localId,
        EntityKind.farmerWellAccount,
      );

      expect(mapping, isNotNull);
      expect(mapping!.matchedExisting, isTrue);
      expect(mapping.serverId, isNotEmpty);

      final stored = await repository.byLocalId(accountA, farmer.localId);

      expect(stored!.serverResponse!['already_exists'], isTrue);

      // الأرض ارتبطت بالحساب القائم لا بحساب جديد.
      expect(
        transport
            .lastRequestFor(CommandType.createFarm)
            .arguments['p_farmer_well_account_id'],
        mapping.serverId,
      );
      expect(farm.references.single.kind, EntityKind.farmerWellAccount);
    });

    test('لا يمكن بناء مرجع إلى أمر لا يُنتج كيانًا', () async {
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
      final pause = await repository.enqueue(
        accountId: accountA,
        type: CommandType.pauseIrrigationSession,
        payload: sessionEventPayload(
          session: repository.referenceTo(start).toJson(),
          extra: const {'p_reason': 'صيانة'},
        ),
        occurredAt: testNow,
        wellId: wellOne,
        aggregateLocalId: start.localId,
      );

      expect(() => repository.referenceTo(pause), throwsArgumentError);
    });
  });

  group('الحجز يمنع الإرسال المزدوج', () {
    test('حلقتان متزامنتان تُرسلان الأمر مرة واحدة', () async {
      await repository.enqueue(
        accountId: accountA,
        type: CommandType.recordPayment,
        payload: recordPaymentPayload(farmerWellAccount: 'fwa-1'),
        occurredAt: testNow,
        wellId: wellOne,
      );

      final other = SyncEngine(
        store: store,
        transport: transport,
        clock: clock,
      );

      final reports = await Future.wait([
        engine.run(accountA),
        other.run(accountA),
      ]);

      expect(transport.requests, hasLength(1));
      expect(transport.executionCount, 1);
      expect(
        reports.fold<int>(0, (total, report) => total + report.attempted),
        1,
      );
    });

    test('حجز مات التطبيق في منتصفه يُستعاد بنفس المعرّف', () async {
      final command = await repository.enqueue(
        accountId: accountA,
        type: CommandType.recordPayment,
        payload: recordPaymentPayload(farmerWellAccount: 'fwa-1'),
        occurredAt: testNow,
        wellId: wellOne,
      );

      expect(
        await store.claim(accountA, command.localId, attemptedAt: testNow),
        isTrue,
      );

      final held = await repository.byLocalId(accountA, command.localId);

      expect(held!.status, CommandStatus.dispatching);
      expect(held.statusText, 'جارٍ الإرسال');

      // حجز حديث لا يُمَس: قد تكون محاولة جارية الآن.
      final immediate = await engine.run(accountA);

      expect(immediate.recoveredClaims, 0);
      expect(transport.requests, isEmpty);

      advanceClock(const Duration(minutes: 3));
      final later = await engine.run(accountA);

      expect(later.recoveredClaims, 1);
      expect(later.confirmed, 1);
      expect(transport.requests, hasLength(1));
      expect(
        transport.requests.single.arguments[commandIdArgument],
        command.commandId,
      );
    });

    test('حلقة ثانية أثناء تشغيل جارٍ لا تبدأ', () async {
      await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(),
        occurredAt: testNow,
        wellId: wellOne,
      );

      final first = engine.run(accountA);
      final second = await engine.run(accountA);

      expect(second.alreadyRunning, isTrue);
      expect((await first).confirmed, 1);
      expect(engine.isRunning, isFalse);
    });
  });
}

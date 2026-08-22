/// «العملية لا تُفقد»: الحفظ الدائم، وثبات معرّف العملية، وعدم
/// التنفيذ المزدوج، وصحة وقت الحدث، وعزل الحساب.
///
/// كل شيء هنا بلا هاتف وبلا شبكة وبلا قاعدة بيانات.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
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

  group('ثبات معرّف العملية', () {
    test('ثلاث محاولات إرسال بمعرّف واحد وتنفيذ واحد', () async {
      final command = await repository.enqueue(
        accountId: accountA,
        type: CommandType.startIrrigationSession,
        payload: startSessionPayload(
          farm: 'farm-1',
          farmerWellAccount: 'fwa-1',
        ),
        occurredAt: DateTime.utc(2026, 8, 22, 5),
        wellId: wellOne,
      );

      transport.scheduleNetworkFailure(
        CommandType.startIrrigationSession,
        times: 2,
      );

      await engine.run(accountA);
      advanceClock(const Duration(minutes: 4));
      await engine.run(accountA);
      advanceClock(const Duration(minutes: 4));
      final report = await engine.run(accountA);

      expect(
        transport.requestsFor(CommandType.startIrrigationSession),
        hasLength(3),
      );
      expect(
        transport.requests
            .map((request) => request.arguments[commandIdArgument])
            .toSet(),
        {command.commandId},
      );
      expect(transport.executionCount, 1);
      expect(report.confirmed, 1);

      final stored = await repository.byLocalId(accountA, command.localId);

      expect(stored!.status, CommandStatus.confirmed);
      expect(stored.commandId, command.commandId);
      expect(stored.retryCount, 2);
    });

    test('كل عملية ميدانية تحمل معرّفًا مختلفًا', () async {
      final first = await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(),
        occurredAt: testNow,
        wellId: wellOne,
      );
      final second = await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(fullName: 'سالم بن علي'),
        occurredAt: testNow,
        wellId: wellOne,
      );

      expect(first.commandId, isNot(second.commandId));
      expect(first.localId, isNot(second.localId));
      expect(first.commandId, isNot(first.localId));
    });
  });

  group('البقاء بعد إغلاق التطبيق', () {
    test('الأمر يُقرأ كما هو من مخزن أُعيد فتحه', () async {
      final fieldTime = DateTime.utc(2026, 8, 22, 5, 30);
      final command = await repository.enqueue(
        accountId: accountA,
        type: CommandType.recordPayment,
        payload: recordPaymentPayload(farmerWellAccount: 'fwa-1'),
        occurredAt: fieldTime,
        wellId: wellOne,
      );

      await store.close();
      await store.reopen();

      final rows = await repository.pending(accountA);

      expect(rows, hasLength(1));
      expect(rows.single.commandId, command.commandId);
      expect(rows.single.sequence, command.sequence);
      expect(rows.single.occurredAt, fieldTime);
      expect(rows.single.status, CommandStatus.pending);
      expect(rows.single.statusText, 'بانتظار المزامنة');
      expect(rows.single.payload['p_amount_minor'], 250000);
    });

    test('عدّاد الترتيب لا يتراجع بعد إعادة الفتح', () async {
      final first = await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(),
        occurredAt: testNow,
      );

      await store.close();
      await store.reopen();

      final second = await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(fullName: 'علي'),
        occurredAt: testNow,
      );

      expect(second.sequence, greaterThan(first.sequence));
    });
  });

  group('ردّ الخادم يضيع بعد التنفيذ', () {
    test('إعادة الإرسال تُرجِع النتيجة المخزونة بلا خصم مرتين', () async {
      final payment = await repository.enqueue(
        accountId: accountA,
        type: CommandType.recordPayment,
        payload: recordPaymentPayload(farmerWellAccount: 'fwa-1'),
        occurredAt: DateTime.utc(2026, 8, 22, 5, 45),
        wellId: wellOne,
      );

      // الخادم ينفّذ الدفعة ثم ينقطع الردّ.
      transport.swallowAckOnce.add(CommandType.recordPayment.rpcName);

      final first = await engine.run(accountA);

      expect(first.retryScheduled, 1);
      expect(transport.executionCount, 1);

      var stored = await repository.byLocalId(accountA, payment.localId);

      expect(stored!.status, CommandStatus.pending);
      expect(stored.statusText, 'فشل وستتم إعادة المحاولة');

      // التطبيق مات هنا، ثم فُتح من جديد.
      await store.close();
      await store.reopen();

      final second = await engine.run(accountA);

      expect(second.confirmed, 1);
      expect(transport.requestsFor(CommandType.recordPayment), hasLength(2));

      // تنفيذ واحد فقط: مبلغ واحد، سجل واحد.
      expect(transport.executionCount, 1);
      expect(await repository.all(accountA), hasLength(1));

      stored = await repository.byLocalId(accountA, payment.localId);

      expect(stored!.status, CommandStatus.confirmed);
      expect(stored.statusText, 'تمت المزامنة');
      expect(stored.serverResponse!['payment_id'], isNotNull);
      expect(stored.commandId, payment.commandId);
    });
  });

  group('وقت الحدث', () {
    test('المُرسَل هو وقت الحقل لا وقت المزامنة', () async {
      final fieldTime = DateTime.utc(2026, 8, 22, 5, 30);
      await repository.enqueue(
        accountId: accountA,
        type: CommandType.startIrrigationSession,
        payload: startSessionPayload(
          farm: 'farm-1',
          farmerWellAccount: 'fwa-1',
        ),
        occurredAt: fieldTime,
        wellId: wellOne,
      );

      // المزامنة جرت بعد خمس ساعات ونصف.
      testNow = DateTime.utc(2026, 8, 22, 11);

      await engine.run(accountA);

      final arguments = transport
          .lastRequestFor(CommandType.startIrrigationSession)
          .arguments;

      expect(arguments['p_started_at'], fieldTime.toIso8601String());
      expect(arguments['p_started_at'], isNot(testNow.toIso8601String()));
    });

    test('وقت محلي يُخزَّن كنفس اللحظة بلا انزياح', () async {
      final fieldTime = DateTime.utc(2026, 8, 22, 5, 30);
      final command = await repository.enqueue(
        accountId: accountA,
        type: CommandType.completeIrrigationSession,
        payload: sessionEventPayload(session: 'session-1'),
        occurredAt: fieldTime.toLocal(),
        wellId: wellOne,
      );

      final stored = await repository.byLocalId(accountA, command.localId);

      expect(stored!.occurredAt.isAtSameMomentAs(fieldTime), isTrue);
      expect(stored.occurredAt.isUtc, isTrue);
    });
  });

  group('عزل الحساب (ق-101)', () {
    test('طابور حساب لا يُقرأ ولا يُرسل من حساب آخر', () async {
      await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(),
        occurredAt: testNow,
        wellId: wellOne,
      );
      final other = await repository.enqueue(
        accountId: accountB,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(well: wellTwo, fullName: 'ناصر'),
        occurredAt: testNow,
        wellId: wellTwo,
      );

      expect(await repository.pending(accountA), hasLength(1));
      expect(await repository.pending(accountB), hasLength(1));

      final report = await engine.run(accountA);

      expect(report.confirmed, 1);
      expect(transport.requests, hasLength(1));

      final untouched = await repository.byLocalId(accountB, other.localId);

      expect(untouched!.status, CommandStatus.pending);
      expect(await repository.byLocalId(accountA, other.localId), isNull);
    });

    test('الترتيب مستقل لكل حساب', () async {
      final first = await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(),
        occurredAt: testNow,
      );
      final second = await repository.enqueue(
        accountId: accountB,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(well: wellTwo, fullName: 'ناصر'),
        occurredAt: testNow,
      );

      expect(first.sequence, second.sequence);
    });

    test('الدخول بحساب آخر لا يحذف طابور الحساب الأول', () async {
      final pendingBefore = await repository.enqueue(
        accountId: accountA,
        type: CommandType.recordPayment,
        payload: recordPaymentPayload(farmerWellAccount: 'fwa-1'),
        occurredAt: testNow,
        wellId: wellOne,
      );

      // خروج ثم دخول بحساب آخر.
      await store.close();
      await store.reopen();
      await repository.enqueue(
        accountId: accountB,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(well: wellTwo, fullName: 'ناصر'),
        occurredAt: testNow,
        wellId: wellTwo,
      );

      final rows = await repository.pending(accountA);

      expect(rows, hasLength(1));
      expect(rows.single.commandId, pendingBefore.commandId);
    });
  });

  group('آخر مزامنة ناجحة', () {
    test('تُسجَّل بعد قبول عملية ولا تُسجَّل بعد فشل شبكة', () async {
      await repository.enqueue(
        accountId: accountA,
        type: CommandType.createFarmer,
        payload: createFarmerPayload(),
        occurredAt: testNow,
        wellId: wellOne,
      );

      transport.scheduleNetworkFailure(CommandType.createFarmer);

      await engine.run(accountA);

      expect(await repository.lastSuccessfulSyncAt(accountA), isNull);

      advanceClock(const Duration(minutes: 5));
      await engine.run(accountA);

      expect(await repository.lastSuccessfulSyncAt(accountA), testNow);
    });
  });
}

/// اختبارات إعادة بناء الجلسة من الطابور — القسم 16 «Local recovery».
///
/// ملف منفصل بنيّة لأنه يحتاج مكتبة sqlite على الحاسب: إن غابت يسقط
/// وحده وتبقى بقية الحزمة صالحة (نفس قاعدة `sqlite_outbox_store_test`).
///
/// وهو يجري على **ملف قرص حقيقي**، لأن ما يُبرهن هنا لا معنى له على
/// مخزن ذاكرة: الاستعادة تعني أن التطبيق مات وأن البيانات نجت. لذلك كل
/// اختبار استعادة يُغلق المخزن ويفتح **نسخة جديدة تمامًا** من نفس
/// الملف — كما يحدث بعد Process Death أو إعادة إقلاع الهاتف.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/session/time_integrity.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import '../sync/fake_command_transport.dart';
import '../sync/sync_test_support.dart';
import 'session_test_support.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tempDir;
  late String databasePath;
  late SequentialIdGenerator ids;
  final opened = <SqliteOutboxStore>[];

  final t0 = DateTime.utc(2026, 8, 23, 6);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  Future<SqliteOutboxStore> openStore() async {
    final store = SqliteOutboxStore(
      databasePath: databasePath,
      sqfliteFactory: databaseFactoryFfi,
    );

    await store.initialize();
    opened.add(store);

    return store;
  }

  /// مولّد واحد لكل اختبار، لا واحد لكل مستودع: مولّد جديد يعيد الترقيم
  /// من أوله فيصطدم بشرط الفرادة على `command_id`، وهو اصطدام يصنعه
  /// الاختبار ولا وجود له في التطبيق.
  OutboxRepository repositoryFor(SqliteOutboxStore store) =>
      OutboxRepository(store: store, idGenerator: ids, clock: clock);

  ActiveSessionProjector projectorFor(
    OutboxStore store, {
    PricingResolver? pricing,
  }) => ActiveSessionProjector(
    store: store,
    pricing: pricing ?? pricingAt(t0),
  );

  setUp(() async {
    testNow = t0;
    ids = SequentialIdGenerator();
    tempDir = await Directory.systemTemp.createTemp('active_session_test');
    databasePath = p.join(tempDir.path, 'outbox.db');
  });

  tearDown(() async {
    for (final store in opened) {
      await store.close();
    }

    opened.clear();
    await tempDir.delete(recursive: true);
  });

  group('الاستعادة بعد موت التطبيق', () {
    test('جلسة جارية تُستعاد كاملة من ملف على القرص', () async {
      final writer = await openStore();
      final repository = repositoryFor(writer);

      final session = await startSession(repository, at: t0);
      await pause(repository, session: session, at: at(600));
      await resume(repository, session: session, at: at(900));

      // مات التطبيق هنا: لا ذاكرة ولا مؤقّت ولا كائن حالة.
      await writer.close();
      opened.remove(writer);

      final reopened = await openStore();
      final restored = await projectorFor(reopened).activeSessions(
        sessionAccount,
        now: at(1200),
      );

      expect(restored, hasLength(1));

      final record = restored.single;

      expect(record.localId, session.localId);
      expect(record.businessState, SessionBusinessState.running);
      expect(record.businessStateText, SessionStateText.running);
      expect(
        record.totals.billableSeconds,
        900,
        reason: '600 قبل التوقف + 300 بعد الاستئناف',
      );
      expect(record.totals.totalPausedSeconds, 300);
      expect(record.totals.accruedMinor, 900);
      expect(record.currentEnergySource, 'diesel');
      expect(record.segments, hasLength(3));
      expect(record.pendingCommandCount, 3);
    });

    test('العدّاد يُبنى من الأحداث لا من مؤقّت في الذاكرة', () async {
      final writer = await openStore();
      final repository = repositoryFor(writer);

      await startSession(repository, at: t0);
      await writer.close();
      opened.remove(writer);

      final reopened = await openStore();
      final projector = projectorFor(reopened);

      // نفس الملف، لحظتان مختلفتان: العدّاد يتقدم بلا أي كائن حيّ.
      final early = await projector.activeSessions(sessionAccount, now: at(60));
      final later = await projector.activeSessions(
        sessionAccount,
        now: at(3600),
      );

      expect(early.single.totals.billableSeconds, 60);
      expect(later.single.totals.billableSeconds, 3600);
      expect(later.single.totals.accruedMinor, 3600);
    });

    test('جلسة موقوفة تُستعاد موقوفة مع سببها ومدة توقفها', () async {
      final writer = await openStore();
      final repository = repositoryFor(writer);

      final session = await startSession(repository, at: t0);
      await pause(
        repository,
        session: session,
        at: at(300),
        reason: 'عطل بالمضخة',
      );

      await writer.close();
      opened.remove(writer);

      final reopened = await openStore();
      final record = (await projectorFor(reopened).projectSession(
        sessionAccount,
        session.localId,
        now: at(1060),
      ))!;

      expect(record.businessState, SessionBusinessState.paused);
      expect(record.businessStateText, SessionStateText.paused);
      expect(record.currentPauseReason, 'عطل بالمضخة');
      expect(record.totals.currentPauseSeconds, 760);
      expect(
        record.totals.billableSeconds,
        300,
        reason: 'الوقت المحتسب متجمّد منذ الإيقاف',
      );
      expect(record.totals.accruedMinor, 300);
    });

    test('جلسة أُنهيت محليًا تُستعاد منتهية ولا تظهر ضمن الجارية', () async {
      final writer = await openStore();
      final repository = repositoryFor(writer);

      final session = await startSession(repository, at: t0);
      await complete(repository, session: session, at: at(1800));

      await writer.close();
      opened.remove(writer);

      final reopened = await openStore();
      final projector = projectorFor(reopened);

      expect(
        await projector.activeSessions(sessionAccount, now: at(5000)),
        isEmpty,
      );

      final record = (await projector.projectSession(
        sessionAccount,
        session.localId,
        now: at(5000),
      ))!;

      expect(record.businessState, SessionBusinessState.completed);
      expect(record.businessStateText, SessionStateText.completed);
      expect(record.completedAt, at(1800));
      expect(
        record.totals.billableSeconds,
        1800,
        reason: 'المحتسب توقف عند الإنهاء ولا يزيد بمرور الوقت بعده',
      );
      expect(record.totals.accruedMinor, 1800);
    });

    test('الدفعات المستلمة محليًا تُستعاد وتُعرض غير مُرحَّلة', () async {
      final writer = await openStore();
      final repository = repositoryFor(writer);

      final session = await startSession(repository, at: t0);
      await payInSession(
        repository,
        session: session,
        at: at(400),
        amountMinor: 20000,
      );

      await writer.close();
      opened.remove(writer);

      final reopened = await openStore();
      final record = (await projectorFor(reopened).projectSession(
        sessionAccount,
        session.localId,
        now: at(600),
      ))!;

      expect(record.payments, hasLength(1));
      expect(record.receivedLocallyMinor, 20000);
      expect(
        record.postedMinor,
        0,
        reason: 'القسم 20: لا يقال Posted قبل قبول الخادم',
      );
      expect(record.payments.single.isPosted, isFalse);
      expect(
        record.remainingMinor,
        600 - 20000,
        reason: 'ق-99: لا مقاصّة صامتة؛ الزيادة تبقى ظاهرة ولا تُقصَّر لصفر',
      );
    });
  });

  group('مصدر الطاقة عبر المقاطع', () {
    test('تغيير الطاقة يُغلق مقطعًا ويفتح آخر بالمصدر الجديد', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      final session = await startSession(
        repository,
        at: t0,
        energySource: 'diesel',
      );
      await changeEnergy(
        repository,
        session: session,
        at: at(600),
        newSource: 'grid',
      );

      final record = (await projectorFor(store).projectSession(
        sessionAccount,
        session.localId,
        now: at(900),
      ))!;

      expect(record.currentEnergySource, 'grid');
      expect(record.segments, hasLength(2));
      expect(record.segments.first.energySource, 'diesel');
      expect(record.segments.first.duration(at(900)).inSeconds, 600);
      expect(record.segments.last.energySource, 'grid');
      expect(
        record.businessState,
        SessionBusinessState.running,
        reason: 'تغيير الطاقة لا يوقف السقي',
      );
      expect(record.totals.billableSeconds, 900);
    });

    test('تغيير الطاقة أثناء التوقف لا يستأنف السقي', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      final session = await startSession(repository, at: t0);
      await pause(repository, session: session, at: at(300));
      await changeEnergy(
        repository,
        session: session,
        at: at(400),
        newSource: 'grid',
      );

      final record = (await projectorFor(store).projectSession(
        sessionAccount,
        session.localId,
        now: at(900),
      ))!;

      expect(record.businessState, SessionBusinessState.paused);
      expect(record.currentEnergySource, 'grid');
      expect(
        record.totals.billableSeconds,
        300,
        reason: 'المقطع الجديد توقف أيضًا، فلا يزيد المحتسب',
      );
      expect(record.totals.totalPausedSeconds, 600);
    });
  });

  group('حالة المزامنة مستقلة عن حالة السقي', () {
    test('جارية + محفوظة على الجهاز قبل أي محاولة', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      final session = await startSession(repository, at: t0);

      final record = (await projectorFor(store).projectSession(
        sessionAccount,
        session.localId,
        now: at(60),
      ))!;

      expect(record.businessState, SessionBusinessState.running);
      expect(record.syncState, SessionSyncState.localOnly);
      expect(record.syncState.text, SyncStatusText.localDurable);
    });

    test('محاولة فاشلة واحدة لا ترفع الحالة إلى حرجة', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      final session = await startSession(repository, at: t0);
      final transport = FakeCommandTransport()
        ..scheduleNetworkFailure(CommandType.startIrrigationSession);

      await SyncEngine(
        store: store,
        transport: transport,
        clock: clock,
      ).run(sessionAccount);

      final record = (await projectorFor(store).projectSession(
        sessionAccount,
        session.localId,
        now: at(60),
      ))!;

      expect(
        record.businessState,
        SessionBusinessState.running,
        reason: 'انقطاع الشبكة لا يوقف السقي في الأرض',
      );
      expect(record.syncState, SessionSyncState.pending);
      expect(record.syncState.text, SyncStatusText.pending);
      expect(record.pendingCommandCount, 1);
    });

    test('رفض عملي يصير تعارضًا ويبقى السقي جاريًا', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      final session = await startSession(repository, at: t0);
      final transport = FakeCommandTransport()
        ..scheduleBusinessRejection(CommandType.startIrrigationSession);

      await SyncEngine(
        store: store,
        transport: transport,
        clock: clock,
      ).run(sessionAccount);

      final record = (await projectorFor(store).projectSession(
        sessionAccount,
        session.localId,
        now: at(60),
      ))!;

      expect(record.businessState, SessionBusinessState.running);
      expect(record.syncState, SessionSyncState.conflict);
      expect(record.syncState.text, SyncStatusText.needsReview);
    });

    test('بعد نجاح المزامنة يُحسم معرّف الجلسة الخادمي', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      final session = await startSession(repository, at: t0);
      final transport = FakeCommandTransport();

      await SyncEngine(
        store: store,
        transport: transport,
        clock: clock,
      ).run(sessionAccount);

      final record = (await projectorFor(store).projectSession(
        sessionAccount,
        session.localId,
        now: at(60),
      ))!;

      expect(record.syncState, SessionSyncState.synced);
      expect(record.serverSessionId, isNotNull);
      expect(record.pendingCommandCount, 0);
      expect(record.lastSuccessfulSyncAt, isNotNull);
    });
  });

  group('التسعير', () {
    test('بلا لقطة تسعير يُعرض نصّ الانتظار ولا رقم', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      final session = await startSession(repository, at: t0);

      final record = (await projectorFor(
        store,
        pricing: const PricingResolver.none(),
      ).projectSession(sessionAccount, session.localId, now: at(600)))!;

      expect(record.totals.pricingPending, isTrue);
      expect(record.totals.accruedMinor, isNull);
      expect(record.accruedTextOrPending, SessionStateText.pricingPending);
      expect(
        record.remainingMinor,
        isNull,
        reason: 'لا متبقي بلا مستحق محسوم',
      );
      expect(
        record.totals.billableSeconds,
        600,
        reason: 'غياب السعر لا يمنع عرض الزمن المقاس',
      );
    });

    test('السعر يُحسم بوقت بداية المقطع لا بالوقت الحالي', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      final session = await startSession(repository, at: t0);
      await pause(repository, session: session, at: at(100));
      await resume(repository, session: session, at: at(200));

      // سعر قديم للمقطع الأول، وسعر أحدث للمقطع الذي بدأ بعد at(150).
      final record = (await projectorFor(
        store,
        pricing: PricingResolver([
          PricingSnapshot(
            hourlyRateMinor: 7200,
            effectiveFrom: at(150),
          ),
          PricingSnapshot(hourlyRateMinor: 3600, effectiveFrom: t0),
        ]),
      ).projectSession(sessionAccount, session.localId, now: at(300)))!;

      // المقطع الأول 100 ثانية بسعر 3600 = 100.
      // المقطع الثاني 100 ثانية بسعر 7200 = 200.
      expect(record.totals.accruedMinor, 300);
    });
  });

  group('سلامة الزمن في الجلسة المستعادة', () {
    test('ترتيب أحداث مستحيل يُرفع علمه ولا يُنتج مدة سالبة', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      final session = await startSession(repository, at: at(600));
      // إيقاف بوقت أسبق من البدء: ساعة الهاتف عُدِّلت بين الحدثين.
      await pause(repository, session: session, at: at(100));

      final record = (await projectorFor(store).projectSession(
        sessionAccount,
        session.localId,
        now: at(1200),
      ))!;

      expect(
        record.timeIntegrityFlags,
        contains(TimeIntegrityFlag.impossibleEventOrdering),
      );
      expect(record.timeIsTrusted, isFalse);
      expect(record.totals.billableSeconds, 0);
      expect(
        record.totals.accruedMinor,
        0,
        reason: 'لا مبلغ سالب يُطرح من مستحق المزارع',
      );
    });

    test('تقديم ساعة الهاتف لا يضخّم المستحق', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      final session = await startSession(repository, at: t0);

      // مرساة الجلسة عند بدئها.
      final anchor = SessionTimeAnchor(
        wallClock: t0,
        monotonic: const Duration(hours: 2),
        bootId: 'boot-1',
        serverTime: t0,
      );

      // بعد 10 دقائق سقي فعلي قدّم المستخدم الساعة ثلاث ساعات: ساعة
      // الحائط تقول 3:10، والعدّاد التصاعدي يقول 10 دقائق فقط.
      final record = (await projectorFor(store).projectSession(
        sessionAccount,
        session.localId,
        now: t0.add(const Duration(hours: 3, minutes: 10)),
        timeContext: SessionTimeContext(
          anchor: anchor,
          reading: TimeReading(
            wallClock: t0.add(const Duration(hours: 3, minutes: 10)),
            monotonic: const Duration(hours: 2, minutes: 10),
            bootId: 'boot-1',
          ),
        ),
      ))!;

      expect(
        record.totals.billableSeconds,
        600,
        reason: 'العدّاد التصاعدي هو المرجع، فلا تُحتسب ثلاث ساعات وهمية',
      );
      expect(
        record.totals.accruedMinor,
        600,
        reason: 'ساعة معدَّلة لا تضيف 10800 ريال على المزارع',
      );
      expect(
        record.timeIntegrityFlags,
        contains(TimeIntegrityFlag.deviceClockChanged),
      );
      expect(record.timeIsTrusted, isFalse);
    });

    test('إعادة الإقلاع تُعلَن ولا تُخفى', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      final session = await startSession(repository, at: t0);

      final record = (await projectorFor(store).projectSession(
        sessionAccount,
        session.localId,
        now: at(1800),
        timeContext: SessionTimeContext(
          anchor: SessionTimeAnchor(
            wallClock: t0,
            monotonic: const Duration(hours: 2),
            bootId: 'boot-1',
            serverTime: t0,
          ),
          reading: TimeReading(
            wallClock: at(1800),
            // العدّاد صُفِّر بالإقلاع.
            monotonic: const Duration(minutes: 4),
            bootId: 'boot-2',
          ),
        ),
      ))!;

      expect(
        record.timeIntegrityFlags,
        contains(TimeIntegrityFlag.rebootTimelineUnverified),
      );
      expect(
        record.totals.billableSeconds,
        1800,
        reason: 'يُرجَع لساعة الحائط، والجلسة لا تُفقد بسبب إعادة الإقلاع',
      );
      expect(
        record.businessState,
        SessionBusinessState.running,
        reason: 'القسم 16: الجلسة تُستعاد جارية بعد إعادة إقلاع الهاتف',
      );
    });
  });

  group('عزل الحسابات وتعدد الجلسات', () {
    test('جلسة حساب لا تظهر لحساب آخر (ق-101)', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      await startSession(repository, at: t0);

      final projector = projectorFor(store);

      expect(
        await projector.activeSessions(sessionAccount, now: at(60)),
        hasLength(1),
      );
      expect(
        await projector.activeSessions('account-other', now: at(60)),
        isEmpty,
      );
    });

    test('جلستان لبئرين تُستعادان معًا ومرتَّبتين بوقت البدء', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      await startSession(repository, at: at(500), well: 'well-b');
      await startSession(repository, at: t0, well: 'well-a');

      final active = await projectorFor(store).activeSessions(
        sessionAccount,
        now: at(900),
      );

      expect(active, hasLength(2));
      expect(active.first.wellId, 'well-a');
      expect(active.last.wellId, 'well-b');
      expect(active.first.totals.billableSeconds, 900);
      expect(active.last.totals.billableSeconds, 400);
    });

    test('حدث بلا أمر بدء لا يخترع جلسة', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      await repository.enqueue(
        accountId: sessionAccount,
        type: CommandType.pauseIrrigationSession,
        aggregateLocalId: 'ghost-session',
        occurredAt: t0,
        payload: {'p_session_id': 'ghost-session', 'p_reason': 'صيانة'},
      );

      expect(
        await projectorFor(store).projectAll(sessionAccount, now: at(60)),
        isEmpty,
      );
    });
  });

  group('المرجع غير المحسوم', () {
    test('أرض أُنشئت بلا اتصال تُعرض بمعرّفها المحلي لا بمرجع خام', () async {
      final store = await openStore();
      final repository = repositoryFor(store);

      final farm = await repository.enqueue(
        accountId: sessionAccount,
        type: CommandType.createFarm,
        wellId: sessionWell,
        occurredAt: t0,
        payload: {
          'p_well_id': sessionWell,
          'p_name': 'الأرض الشرقية',
          'p_farmer_well_account_id': 'fwa-0000-0009',
        },
      );

      final session = await repository.enqueue(
        accountId: sessionAccount,
        type: CommandType.startIrrigationSession,
        wellId: sessionWell,
        occurredAt: t0,
        payload: {
          'p_well_id': sessionWell,
          'p_pump_id': 'pump-0000-0009',
          'p_farm_id': repository.referenceTo(farm).toJson(),
          'p_farmer_well_account_id': 'fwa-0000-0009',
          'p_energy_source': 'diesel',
        },
      );

      final record = (await projectorFor(store).projectSession(
        sessionAccount,
        session.localId,
        now: at(60),
      ))!;

      expect(record.farmReference, farm.localId);
      expect(record.businessState, SessionBusinessState.running);
    });
  });
}

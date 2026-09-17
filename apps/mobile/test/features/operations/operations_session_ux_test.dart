import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_reference.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/compact_energy_selector.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/payment_receipt_dialog.dart';

import '../../support/identity_fixture.dart';

class _FakeOperationsRepo extends OperationsRepository {
  _FakeOperationsRepo({
    this.farmers = const [],
    this.farms = const [],
    this.pumps = const [],
  });

  List<FarmerAccount> farmers;
  List<Farm> farms;
  List<Pump> pumps;

  @override
  Future<List<FarmerAccount>> fetchFarmers(
    String wellId, {
    String? query,
  }) async => farmers;

  @override
  Future<List<Farm>> fetchFarms(
    String wellId, {
    String? farmerAccountId,
  }) async => farms;

  @override
  Future<List<Pump>> fetchPumps(String wellId) async => pumps;
}

class _FakePriceRepo extends WellManagementRepository {
  _FakePriceRepo([this.schedule]);
  final PriceScheduleModel? schedule;

  @override
  Future<PriceScheduleModel?> fetchActivePriceSchedule(
    String wellId, {
    DateTime? at,
  }) async => schedule;
}

class _DelayedActionCoordinator extends OfflineSessionCoordinator {
  _DelayedActionCoordinator({required super.store});

  int pauseCalls = 0;
  int energyCalls = 0;
  int completeCalls = 0;
  Completer<void> pauseGate = Completer<void>();
  Completer<void> energyGate = Completer<void>();
  Completer<void> completeGate = Completer<void>();

  @override
  Future<CommandEnvelope> pauseSession({
    required String accountId,
    required String sessionLocalId,
    required String reason,
    DateTime? pausedAt,
  }) async {
    pauseCalls += 1;
    final result = await super.pauseSession(
      accountId: accountId,
      sessionLocalId: sessionLocalId,
      reason: reason,
      pausedAt: pausedAt,
    );
    await pauseGate.future;
    return result;
  }

  @override
  Future<CommandEnvelope> changeEnergySource({
    required String accountId,
    required String sessionLocalId,
    required String newEnergySource,
    DateTime? changedAt,
  }) async {
    energyCalls += 1;
    final result = await super.changeEnergySource(
      accountId: accountId,
      sessionLocalId: sessionLocalId,
      newEnergySource: newEnergySource,
      changedAt: changedAt,
    );
    await energyGate.future;
    return result;
  }

  @override
  Future<CommandEnvelope> completeSession({
    required String accountId,
    required String sessionLocalId,
    DateTime? completedAt,
  }) async {
    completeCalls += 1;
    final result = await super.completeSession(
      accountId: accountId,
      sessionLocalId: sessionLocalId,
      completedAt: completedAt,
    );
    await completeGate.future;
    return result;
  }
}

void main() {
  const accountId = 'owner-1';
  const well = WellSummary(
    id: 'well-1',
    tenantId: 'tenant-1',
    name: 'بئر الخير الرئيسي',
    status: 'active',
    roles: ['owner', 'operator'],
  );

  const solarRule = PriceRuleModel(
    id: 'rule-solar',
    energySource: 'solar',
    hourlyRateMinor: 5000,
  );
  const dieselRule = PriceRuleModel(
    id: 'rule-diesel',
    energySource: 'well_diesel',
    hourlyRateMinor: 10000,
  );

  late InMemoryOutboxStore store;
  late InMemoryOutboxStore delayedStore;
  late OfflineSessionCoordinator coordinator;
  late _DelayedActionCoordinator delayedCoordinator;

  setUp(() async {
    store = InMemoryOutboxStore();
    coordinator = OfflineSessionCoordinator(store: store);
    await coordinator.initialize();
    delayedStore = InMemoryOutboxStore();
    delayedCoordinator = _DelayedActionCoordinator(store: delayedStore);
    await delayedCoordinator.initialize();
  });

  tearDown(() {
    coordinator.dispose();
    if (!identical(coordinator, delayedCoordinator)) {
      delayedCoordinator.dispose();
    }
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    required OperationsRepository repo,
    WellManagementRepository? priceRepo,
    DateTime Function()? clock,
    Size? physicalSize,
  }) async {
    if (physicalSize != null) {
      tester.view.physicalSize = physicalSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: OperationsScreen(
            key: ValueKey(repo),
            identity: testIdentity(accountId: accountId, wells: const [well]),
            coordinator: coordinator,
            repository: repo,
            priceRepository: priceRepo ?? _FakePriceRepo(),
            clock: clock,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('Q-129 / Device Acceptance Session UX Contract', () {
    testWidgets(
      '1-3. المزارع: لا تركيز تلقائي، لا كود عام، ويظهر الهاتف إن وجد',
      (tester) async {
        final repo = _FakeOperationsRepo(
          farmers: const [
            FarmerAccount(
              id: 'farmer-1',
              fullName: 'سعيد الحظرمي',
              publicCode: 'FAR-SECRET-99',
              phone: '777123456',
            ),
          ],
          pumps: const [
            Pump(id: 'p1', wellId: 'well-1', name: 'مضخة 1', publicCode: 'P-1'),
          ],
        );

        await pumpScreen(tester, repo: repo);

        // فتح منتقي المزارع
        final farmerField = find.text('ابحث باسم المزارع أو رقم هاتفه...');
        expect(farmerField, findsOneWidget);
        await tester.tap(farmerField);
        await tester.pumpAndSettle();

        // 1. لوحة البحث لا تطلب التركيز التلقائي
        final searchField = tester.widget<TextField>(find.byType(TextField));
        expect(searchField.autofocus, isFalse);

        // 2. الكود السري الداخلي لا يظهر للمستخدم
        expect(find.textContaining('FAR-SECRET-99'), findsNothing);
        expect(find.textContaining('كود:'), findsNothing);

        // 3. رقم الهاتف يظهر
        expect(find.textContaining('777123456'), findsOneWidget);

        // اختيار المزارع
        await tester.tap(find.text('سعيد الحظرمي'));
        await tester.pumpAndSettle();

        // البطاقة المختارة مضغوطة وبلا كود داخلي
        expect(find.text('سعيد الحظرمي'), findsOneWidget);
        expect(find.textContaining('FAR-SECRET-99'), findsNothing);
      },
    );

    testWidgets(
      '4-5. الأرض: معطلة قبل المزارع، وتفرغ فور تغيير أو مسح المزارع',
      (tester) async {
        final repo = _FakeOperationsRepo(
          farmers: const [
            FarmerAccount(id: 'farmer-1', fullName: 'سعيد', publicCode: 'F-1'),
            FarmerAccount(id: 'farmer-2', fullName: 'علي', publicCode: 'F-2'),
          ],
          farms: const [
            Farm(
              id: 'farm-1',
              wellId: 'well-1',
              farmerAccountId: 'farmer-1',
              name: 'أرض الجربة',
            ),
          ],
          pumps: const [
            Pump(id: 'p1', wellId: 'well-1', name: 'مضخة 1', publicCode: 'P-1'),
          ],
        );

        await pumpScreen(tester, repo: repo);

        // 4. الأرض معطلة قبل المزارع
        expect(find.text('يرجى اختيار المزارع أولاً'), findsOneWidget);

        // اختيار مزارع
        await tester.tap(find.text('ابحث باسم المزارع أو رقم هاتفه...'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('سعيد'));
        await tester.pumpAndSettle();

        // أصبحت مفعلة
        expect(find.text('ابحث باسم الأرض...'), findsOneWidget);

        // اختيار الأرض
        await tester.tap(find.text('ابحث باسم الأرض...'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('أرض الجربة'));
        await tester.pumpAndSettle();
        expect(find.text('أرض الجربة'), findsOneWidget);

        // 5. تغيير المزارع يفرغ الأرض ويعطلها حتى يتم اختيار مزارع جديد
        await tester.tap(find.text('سعيد'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('علي'));
        await tester.pumpAndSettle();

        // تم تفريغ الأرض السابقة
        expect(find.text('أرض الجربة'), findsNothing);
      },
    );

    testWidgets(
      '6-8. المضخات: حجب الكود، واختيار التلقائي للمضخة الواحدة فقط',
      (tester) async {
        // حالة مضخة وحيدة
        final repoSingle = _FakeOperationsRepo(
          pumps: const [
            Pump(
              id: 'p1',
              wellId: 'well-1',
              name: 'المضخة الشرقية',
              publicCode: 'PUMP-SECRET-1',
            ),
          ],
        );
        await pumpScreen(tester, repo: repoSingle);

        // 6. كود المضخة لا يظهر
        expect(find.textContaining('PUMP-SECRET-1'), findsNothing);
        // 7. المضخة الوحيدة تم اختيارها تلقائياً
        expect(find.text('المضخة الشرقية'), findsOneWidget);

        // حالة مضخات متعددة
        final repoMulti = _FakeOperationsRepo(
          pumps: const [
            Pump(
              id: 'p1',
              wellId: 'well-1',
              name: 'المضخة 1',
              publicCode: 'P-1',
            ),
            Pump(
              id: 'p2',
              wellId: 'well-1',
              name: 'المضخة 2',
              publicCode: 'P-2',
            ),
          ],
        );
        await pumpScreen(tester, repo: repoMulti);

        // 8. لا اختيار ضمني عند تعدد المضخات
        expect(find.text('اختر المضخة...'), findsOneWidget);
      },
    );

    testWidgets(
      '9-13. الطاقة وزر البدء: لا افتراضي ضمني، تحكم مضغوط، وإرشاد الحقول الناقصة',
      (tester) async {
        final repo = _FakeOperationsRepo(
          farmers: const [
            FarmerAccount(id: 'farmer-1', fullName: 'صالح', publicCode: 'F-1'),
          ],
          farms: const [
            Farm(
              id: 'farm-1',
              wellId: 'well-1',
              farmerAccountId: 'farmer-1',
              name: 'أرض الوادي',
            ),
          ],
          pumps: const [
            Pump(id: 'p1', wellId: 'well-1', name: 'مضخة 1', publicCode: 'P-1'),
          ],
        );

        await pumpScreen(tester, repo: repo);

        // 9-10. مصدر الطاقة غير مختار مبدئياً وموجود في أداة مدمجة
        expect(find.byType(CompactEnergySelector), findsOneWidget);
        expect(find.text('اختر مصدر الطاقة...'), findsOneWidget);

        // 11-12. زر البدء معطل مع إرشاد واضح للحقل الناقص الفعلي
        final startBtn = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'بدء جلسة سقي جديدة'),
        );
        expect(startBtn.onPressed, isNull);
        expect(find.text('يرجى تحديد المزارع المستفيد'), findsOneWidget);

        // اختيار المزارع
        await tester.tap(find.text('ابحث باسم المزارع أو رقم هاتفه...'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('صالح'));
        await tester.pumpAndSettle();

        // الإرشاد يطلب الأرض
        expect(find.text('يرجى تحديد الأرض الزراعية'), findsOneWidget);

        // اختيار الأرض
        await tester.tap(find.text('ابحث باسم الأرض...'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('أرض الوادي'));
        await tester.pumpAndSettle();

        // الإرشاد يطلب مصدر الطاقة
        expect(find.text('يرجى تحديد مصدر الطاقة'), findsOneWidget);

        // اختيار الطاقة
        await tester.ensureVisible(find.byType(CompactEnergySelector));
        await tester.tap(find.byType(CompactEnergySelector));
        await tester.pumpAndSettle();
        await tester.tap(find.text('طاقة شمسية'));
        await tester.pumpAndSettle();

        // 13. اكتمال الحقول يفعل زر البدء
        final activeStartBtn = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'بدء جلسة سقي جديدة'),
        );
        expect(activeStartBtn.onPressed, isNotNull);
      },
    );

    testWidgets(
      '14-19. الجلسة النشطة: مصطلحات قصيرة، تفاصيل للعرض فقط، صدق المزامنة، وتفقيط المبلغ',
      (tester) async {
        final t0 = DateTime.utc(2026, 9, 15, 8);
        coordinator.updatePricing([
          PricingSnapshot(
            hourlyRateMinor: 5000,
            effectiveFrom: t0,
            energySource: 'solar',
          ),
        ]);
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'p1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
          startedAt: t0,
        );

        final repo = _FakeOperationsRepo(
          farmers: const [
            FarmerAccount(
              id: 'farmer-1',
              fullName: 'المزارع مسعود',
              publicCode: 'F-1',
            ),
          ],
          farms: const [
            Farm(
              id: 'farm-1',
              wellId: 'well-1',
              farmerAccountId: 'farmer-1',
              name: 'أرض النخيل',
            ),
          ],
          pumps: const [
            Pump(
              id: 'p1',
              wellId: 'well-1',
              name: 'مضخة الأمل',
              publicCode: 'P-1',
            ),
          ],
        );

        final priceRepo = _FakePriceRepo(
          PriceScheduleModel(
            id: 'sched-1',
            wellId: 'well-1',
            name: 'تعرفة',
            status: 'active',
            effectiveFrom: t0,
            rules: const [solarRule],
          ),
        );

        await pumpScreen(
          tester,
          repo: repo,
          priceRepo: priceRepo,
          clock: () => t0.add(const Duration(seconds: 3600)),
        );

        // 14. المصطلح القصير: جاري
        expect(find.text('جاري'), findsOneWidget);

        // 16. قسم قراءة فقط
        expect(find.text('تفاصيل الجلسة الحالية'), findsOneWidget);
        expect(find.text('المزارع مسعود'), findsOneWidget);
        expect(find.text('أرض النخيل'), findsOneWidget);

        // 17. صدق المزامنة: يقرأ من الحالة الفعلية ولا يدعي 'مزامن'
        expect(find.text(SyncStatusText.localDurable), findsOneWidget);
        expect(find.text('تمت المزامنة'), findsNothing);

        // 18-19. المبلغ والتفقيط
        expect(find.textContaining('المبلغ'), findsOneWidget);
        expect(find.text('5,000'), findsOneWidget);
        expect(find.text('ريال'), findsWidgets);
        expect(find.textContaining('خمسة آلاف ريال'), findsWidgets);
      },
    );

    testWidgets(
      '20-23. الإيقاف المؤقت والاستئناف: تأكيد قبل الإيقاف وزر استئناف صريح',
      (tester) async {
        final t0 = DateTime.utc(2026, 9, 15, 8);
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
          startedAt: t0,
        );

        await pumpScreen(tester, repo: _FakeOperationsRepo());

        // 20. النقر على إيقاف مؤقت يفتح حوار التأكيد
        final pauseBtn = find.text('إيقاف مؤقت');
        await tester.ensureVisible(pauseBtn);
        await tester.tap(pauseBtn);
        await tester.pumpAndSettle();

        expect(find.text('إيقاف السقي مؤقتًا؟'), findsOneWidget);
        expect(
          find.text('سيتوقف الوقت واحتساب المبلغ حتى الاستئناف.'),
          findsOneWidget,
        );

        // 21. الإلغاء لا يسجل أمراً
        await tester.tap(find.text('إلغاء'));
        await tester.pumpAndSettle();
        expect(find.text('جاري'), findsOneWidget);
        expect(
          (await store.allCommands(accountId)).where(
            (command) => command.type == CommandType.pauseIrrigationSession,
          ),
          isEmpty,
        );

        // 22. التأكيد يوقف الجلسة
        await tester.ensureVisible(pauseBtn);
        await tester.tap(pauseBtn);
        await tester.pumpAndSettle();
        await tester.tap(find.text('تأكيد'));
        await tester.pumpAndSettle();

        // 15 + 23. الحالة "توقف مؤقت" والزر "استئناف"
        expect(find.text('توقف مؤقت'), findsOneWidget);
        expect(find.text('استئناف'), findsOneWidget);
        expect(
          (await store.allCommands(accountId)).where(
            (command) => command.type == CommandType.pauseIrrigationSession,
          ),
          hasLength(1),
        );
        final pause = (await store.allCommands(accountId)).singleWhere(
          (command) => command.type == CommandType.pauseIrrigationSession,
        );
        expect(pause.payload['p_reason'], 'operator_pause');
      },
    );

    testWidgets(
      '24-29. تغيير المصدر: تأكيد أولاً، وأثناء التوقف يُسجَّل المصدر المعلّق دون فوترة ويُستأنف به',
      (tester) async {
        final t0 = DateTime.utc(2026, 9, 15, 8);
        coordinator.updatePricing([
          PricingSnapshot(
            hourlyRateMinor: 5000,
            effectiveFrom: t0,
            energySource: 'solar',
          ),
          PricingSnapshot(
            hourlyRateMinor: 10000,
            effectiveFrom: t0,
            energySource: 'well_diesel',
          ),
        ]);
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
          startedAt: t0,
        );

        final priceRepo = _FakePriceRepo(
          PriceScheduleModel(
            id: 'sched-1',
            wellId: 'well-1',
            name: 'تعرفة',
            status: 'active',
            effectiveFrom: t0,
            rules: const [solarRule, dieselRule],
          ),
        );

        await pumpScreen(
          tester,
          repo: _FakeOperationsRepo(),
          priceRepo: priceRepo,
          clock: () => t0.add(const Duration(minutes: 10)),
        );

        // 24. إيقاف مؤقت للجلسة
        final pauseBtn = find.text('إيقاف مؤقت');
        await tester.ensureVisible(pauseBtn);
        await tester.tap(pauseBtn);
        await tester.pumpAndSettle();
        await tester.tap(find.text('تأكيد'));
        await tester.pumpAndSettle();

        expect(find.text('توقف مؤقت'), findsOneWidget);
        expect(find.text('00:10:00'), findsOneWidget);

        // 25. النقر على تحويل المصدر أثناء التوقف يفتح حوار التأكيد
        final switchBtn = find.text('تحويل مصدر الطاقة');
        await tester.ensureVisible(switchBtn);
        await tester.tap(switchBtn);
        await tester.pumpAndSettle();

        await tester.tap(find.text('ديزل البئر'));
        await tester.pumpAndSettle();

        expect(find.text('تأكيد تغيير مصدر الطاقة'), findsOneWidget);
        expect(find.textContaining('10,000 ريال / ساعة'), findsOneWidget);
        expect(find.text('التعرفة المتاحة (تأشيرية):'), findsOneWidget);

        // 26. إلغاء التحويل يبقي التوقف بلا أمر جديد
        await tester.tap(find.text('إلغاء'));
        await tester.pumpAndSettle();
        expect(find.text('توقف مؤقت'), findsOneWidget);
        expect(
          (await store.allCommands(accountId)).where(
            (command) => command.type == CommandType.changeSessionEnergySource,
          ),
          isEmpty,
        );

        // 27. تأكيد التحويل أثناء التوقف: ينشئ أمراً واحداً وتبقى الجلسة متوقفة
        await tester.ensureVisible(switchBtn);
        await tester.tap(switchBtn);
        await tester.pumpAndSettle();
        await tester.tap(find.text('ديزل البئر'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('تأكيد التحويل'));
        await tester.pumpAndSettle();

        expect(find.text('توقف مؤقت'), findsOneWidget);
        expect(
          find.textContaining('عند الاستئناف: ديزل البئر'),
          findsOneWidget,
        );
        expect(find.text('00:10:00'), findsOneWidget); // العداد مجمد
        expect(
          (await store.allCommands(accountId)).where(
            (command) => command.type == CommandType.changeSessionEnergySource,
          ),
          hasLength(1),
        );
        expect(
          (await store.allCommands(accountId)).where(
            (command) => command.type == CommandType.resumeIrrigationSession,
          ),
          isEmpty, // لا استئناف تلقائي
        );

        // 28. الاستئناف يفتح الجلسة بالمصدر الجديد ويظهر "الآن"
        final resumeBtn = find.text('استئناف');
        await tester.ensureVisible(resumeBtn);
        await tester.tap(resumeBtn);
        await tester.pumpAndSettle();

        expect(find.text('جاري'), findsOneWidget);
        expect(find.textContaining('ديزل البئر — الآن'), findsOneWidget);
      },
    );

    testWidgets(
      '30-38. إنهاء الجلسة: تأكيد قبل الإرسال، ملخص منفصل، دفع اختياري، وتصفير النموذج',
      (tester) async {
        final t0 = DateTime.utc(2026, 9, 15, 8);
        coordinator.updatePricing([
          PricingSnapshot(
            hourlyRateMinor: 5000,
            effectiveFrom: t0,
            energySource: 'solar',
          ),
        ]);
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
          startedAt: t0,
        );

        final repo = _FakeOperationsRepo(
          farmers: const [
            FarmerAccount(id: 'farmer-1', fullName: 'غانم', publicCode: 'F-1'),
          ],
          farms: const [
            Farm(
              id: 'farm-1',
              wellId: 'well-1',
              farmerAccountId: 'farmer-1',
              name: 'مزرعة الخير',
            ),
          ],
          pumps: const [
            Pump(
              id: 'pump-1',
              wellId: 'well-1',
              name: 'المضخة 1',
              publicCode: 'P-1',
            ),
          ],
        );

        final priceRepo = _FakePriceRepo(
          PriceScheduleModel(
            id: 'sched-1',
            wellId: 'well-1',
            name: 'تعرفة',
            status: 'active',
            effectiveFrom: t0,
            rules: const [solarRule],
          ),
        );

        await pumpScreen(
          tester,
          repo: repo,
          priceRepo: priceRepo,
          clock: () => t0.add(const Duration(minutes: 30)),
        );

        // 30. زر الإنهاء يفتح حوار التأكيد أولاً
        final endBtn = find.text('إنهاء الجلسة');
        await tester.ensureVisible(endBtn);
        await tester.tap(endBtn);
        await tester.pumpAndSettle();

        expect(find.text('تأكيد إنهاء الجلسة'), findsOneWidget);
        // 32. يعرض تفاصيل المصادر والمبلغ والتفقيط
        expect(find.text('2,500'), findsWidgets);
        expect(find.textContaining('ألفان وخمسمائة ريال'), findsWidgets);

        // 31. الإلغاء لا يسجل إنهاء
        await tester.tap(find.text('إلغاء'));
        await tester.pumpAndSettle();
        expect(find.text('جاري'), findsOneWidget);
        expect(
          (await store.allCommands(accountId)).where(
            (command) => command.type == CommandType.completeIrrigationSession,
          ),
          isEmpty,
        );

        // 33. تأكيد الإنهاء يسجل الإنهاء
        await tester.ensureVisible(endBtn);
        await tester.tap(endBtn);
        await tester.pumpAndSettle();
        await tester.tap(find.text('تأكيد الإنهاء'));
        await tester.pumpAndSettle();

        // 34. ظهور ملخص ما بعد الإنهاء منفصلاً عن السداد
        expect(find.text('ملخص الجلسة'), findsOneWidget);
        expect(find.text('منتهي'), findsOneWidget);
        expect(find.text('تسجيل دفعة'), findsOneWidget);
        expect(find.text('إغلاق'), findsOneWidget);
        expect(
          (await store.allCommands(accountId)).where(
            (command) => command.type == CommandType.completeIrrigationSession,
          ),
          hasLength(1),
        );

        // 35-36. إغلاق الملخص لا يفتح دفعاً، والنقر على تسجيل دفعة يفتح سند القبض
        await tester.tap(find.text('تسجيل دفعة'));
        await tester.pumpAndSettle();
        expect(find.byType(PaymentReceiptDialog), findsOneWidget);

        // إغلاق نافذة السداد
        await tester.tap(find.byIcon(Icons.close));
        await tester.pumpAndSettle();
        expect(
          (await store.allCommands(accountId))
              .where((command) => command.type == CommandType.recordPayment),
          isEmpty,
        );

        // 37. تصفير النموذج بعد الانتهاء
        expect(find.text('ابحث باسم المزارع أو رقم هاتفه...'), findsOneWidget);
        expect(
          find.text('يرجى اختيار المزارع أولاً'),
          findsOneWidget,
        ); // الأرض معطلة
        expect(
          find.text('اختر مصدر الطاقة...'),
          findsOneWidget,
        ); // الطاقة مفرغة
        expect(find.text('المضخة 1'), findsOneWidget); // المضخة الوحيدة محفوظة
      },
    );

    testWidgets('التفاعل السريع لا ينشئ أكثر من أمر مؤثر واحد', (tester) async {
      coordinator.dispose();
      store = delayedStore;
      final delayed = delayedCoordinator;
      coordinator = delayed;
      final t0 = DateTime.utc(2026, 9, 15, 8);
      await coordinator.startSession(
        accountId: accountId,
        wellId: 'well-1',
        pumpId: 'pump-1',
        farmId: 'farm-1',
        farmerAccountId: 'farmer-1',
        energySource: 'solar',
        startedAt: t0,
      );
      Future<void> waitForCommand(CommandType type) async {
        await tester.runAsync(() async {
          for (var attempt = 0; attempt < 100; attempt += 1) {
            final commands = await store.allCommands(accountId);
            if (commands.any((command) => command.type == type)) return;
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          fail('لم يُحفظ الأمر $type');
        });
        await tester.pumpAndSettle();
      }

      await pumpScreen(
        tester,
        repo: _FakeOperationsRepo(),
        priceRepo: _FakePriceRepo(
          PriceScheduleModel(
            id: 'schedule-1',
            wellId: 'well-1',
            name: 'تسعير',
            status: 'active',
            effectiveFrom: t0,
            rules: const [solarRule, dieselRule],
          ),
        ),
        clock: () => t0.add(const Duration(minutes: 30)),
      );

      final pause = find.text('إيقاف مؤقت');
      await tester.ensureVisible(pause);
      await tester.tap(pause);
      await tester.tap(pause, warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('تأكيد'));
      await tester.pump();
      expect(delayed.pauseCalls, 1);
      delayed.pauseGate.complete();
      await waitForCommand(CommandType.pauseIrrigationSession);
      await tester.tap(find.text('استئناف'));
      await tester.pumpAndSettle();
      final change = find.text('تحويل مصدر الطاقة');
      await tester.ensureVisible(change);
      await tester.tap(change);
      await tester.tap(change, warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('ديزل البئر'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تأكيد التحويل'));
      await tester.pump();
      expect(delayed.energyCalls, 1);
      delayed.energyGate.complete();
      await waitForCommand(CommandType.changeSessionEnergySource);

      final end = find.text('إنهاء الجلسة');
      await tester.ensureVisible(end);
      await tester.tap(end);
      await tester.tap(end, warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('تأكيد الإنهاء'));
      await tester.pump();
      expect(delayed.completeCalls, 1);
      delayed.completeGate.complete();
      await waitForCommand(CommandType.completeIrrigationSession);

      final commands = await store.allCommands(accountId);
      expect(
        commands.where(
          (command) => command.type == CommandType.pauseIrrigationSession,
        ),
        hasLength(1),
      );
      expect(
        commands.where(
          (command) => command.type == CommandType.changeSessionEnergySource,
        ),
        hasLength(1),
      );
      expect(
        commands.where(
          (command) => command.type == CommandType.completeIrrigationSession,
        ),
        hasLength(1),
      );
    });

    testWidgets(
      '38. جلسة بلا تسعيرة تعرض النص المعتمد ولا تخترع مبلغاً في التأكيد أو الملخص',
      (tester) async {
        final t0 = DateTime.utc(2026, 9, 15, 8);
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
          startedAt: t0,
        );

        await pumpScreen(
          tester,
          repo: _FakeOperationsRepo(),
          clock: () => t0.add(const Duration(minutes: 10)),
        );

        // فتح حوار تأكيد الإنهاء
        final endBtn = find.text('إنهاء الجلسة');
        await tester.ensureVisible(endBtn);
        await tester.tap(endBtn);
        await tester.pumpAndSettle();

        // لا يوجد 0 ريال، بل بانتظار المزامنة
        expect(find.textContaining('0 ريال'), findsNothing);
        expect(find.text(SessionStateText.pricingPending), findsWidgets);

        // تأكيد الإنهاء
        await tester.tap(find.text('تأكيد الإنهاء'));
        await tester.pumpAndSettle();

        // في الملخص أيضاً
        expect(find.textContaining('0 ريال'), findsNothing);
        expect(find.text(SessionStateText.pricingPending), findsWidgets);
      },
    );

    testWidgets(
      'الدفع اللاحق يبقى مربوطاً ببئر الجلسة بعد تغيير السياق المرئي',
      (tester) async {
        final t0 = DateTime.utc(2026, 9, 15, 8);
        const secondWell = WellSummary(
          id: 'well-2',
          tenantId: 'tenant-1',
          name: 'بئر أخرى',
          status: 'active',
          roles: ['owner'],
        );
        coordinator.updatePricing([
          PricingSnapshot(
            hourlyRateMinor: 5000,
            effectiveFrom: t0,
            energySource: 'solar',
          ),
        ]);
        await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
          startedAt: t0,
        );
        final repo = _FakeOperationsRepo(
          farmers: const [
            FarmerAccount(
              id: 'farmer-1',
              fullName: 'مزارع 1',
              publicCode: 'F1',
            ),
          ],
          farms: const [
            Farm(
              id: 'farm-1',
              wellId: 'well-1',
              farmerAccountId: 'farmer-1',
              name: 'أرض 1',
            ),
          ],
          pumps: const [
            Pump(
              id: 'pump-1',
              wellId: 'well-1',
              name: 'مضخة 1',
              publicCode: 'P1',
            ),
          ],
        );
        final schedule = _FakePriceRepo(
          PriceScheduleModel(
            id: 'schedule-1',
            wellId: 'well-1',
            name: 'تسعير',
            status: 'active',
            effectiveFrom: t0,
            rules: const [solarRule],
          ),
        );
        var activeWell = well;
        late StateSetter rebuildHost;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                rebuildHost = setState;
                return OperationsScreen(
                  identity: testIdentity(
                    accountId: accountId,
                    wells: const [well, secondWell],
                    activeWell: activeWell,
                  ),
                  coordinator: coordinator,
                  repository: repo,
                  priceRepository: schedule,
                  clock: () => t0.add(const Duration(hours: 1)),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('إنهاء الجلسة'));
        await tester.tap(find.text('إنهاء الجلسة'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('تأكيد الإنهاء'));
        await tester.pumpAndSettle();

        rebuildHost(() => activeWell = secondWell);
        await tester.pump();
        await tester.tap(find.text('تسجيل دفعة'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('حفظ واعتماد'));
        await tester.tap(find.text('حفظ واعتماد'));
        await tester.pumpAndSettle();

        final payment = (await store.allCommands(
          accountId,
        )).singleWhere((command) => command.type == CommandType.recordPayment);
        expect(payment.wellId, 'well-1');
        expect(payment.aggregateLocalId, isNotNull);
        expect(payment.payload['p_well_id'], 'well-1');
        expect(payment.payload['p_farmer_well_account_id'], 'farmer-1');
        final completion = (await store.allCommands(accountId)).singleWhere(
          (command) => command.type == CommandType.completeIrrigationSession,
        );
        expect(
          payment.payload['p_session_charge_id'],
          CommandReference(
            localId: completion.localId,
            kind: EntityKind.sessionCharge,
          ).toJson(),
        );
      },
    );

    testWidgets('الجلسة الموقوفة تحدّث نص المزامنة من الحالة الحقيقية', (
      tester,
    ) async {
      final t0 = DateTime.utc(2026, 9, 15, 8);
      final session = await coordinator.startSession(
        accountId: accountId,
        wellId: 'well-1',
        pumpId: 'pump-1',
        farmId: 'farm-1',
        farmerAccountId: 'farmer-1',
        energySource: 'solar',
        startedAt: t0,
      );
      await coordinator.pauseSession(
        accountId: accountId,
        sessionLocalId: session.localId,
        reason: 'operator_pause',
        pausedAt: t0.add(const Duration(minutes: 1)),
      );

      await pumpScreen(tester, repo: _FakeOperationsRepo());
      expect(find.text(SyncStatusText.localDurable), findsOneWidget);
      expect(find.text(SyncStatusText.confirmed), findsNothing);

      for (final command in await store.allCommands(accountId)) {
        await store.markConfirmed(
          accountId,
          command.localId,
          serverResponse: const {'accepted': true},
          attemptedAt: t0.add(const Duration(minutes: 2)),
        );
      }
      await store.putMapping(
        accountId,
        IdMapping(
          localId: session.localId,
          kind: EntityKind.session,
          serverId: 'srv-session-1',
          resolvedAt: t0.add(const Duration(minutes: 2)),
        ),
      );
      await coordinator.projectActiveSession(
        accountId: accountId,
        wellId: 'well-1',
      );
      expect(
        coordinator.currentActiveSession!.syncState,
        SessionSyncState.synced,
      );
      await tester.pumpAndSettle();

      expect(find.text(SyncStatusText.confirmed), findsOneWidget);
      expect(find.text(SyncStatusText.localDurable), findsNothing);
      expect(find.text('توقف مؤقت'), findsOneWidget);
    });

    testWidgets(
      '39-40. ثبات FIN-001 وتصميم شاشة ضيقة (360px) دون أي تجاوز بصري',
      (tester) async {
        final t0 = DateTime.utc(2026, 9, 15, 6);
        final now = t0.add(const Duration(seconds: 2451));
        coordinator.updatePricing([
          PricingSnapshot(
            hourlyRateMinor: 5000,
            effectiveFrom: t0,
            energySource: 'solar',
          ),
          PricingSnapshot(
            hourlyRateMinor: 10000,
            effectiveFrom: t0,
            energySource: 'well_diesel',
          ),
        ]);
        final session = await coordinator.startSession(
          accountId: accountId,
          wellId: 'well-1',
          pumpId: 'pump-1',
          farmId: 'farm-1',
          farmerAccountId: 'farmer-1',
          energySource: 'solar',
          startedAt: t0,
        );
        await coordinator.changeEnergySource(
          accountId: accountId,
          sessionLocalId: session.localId,
          newEnergySource: 'well_diesel',
          changedAt: t0.add(const Duration(seconds: 2386)),
        );

        final priceRepo = _FakePriceRepo(
          PriceScheduleModel(
            id: 'sched-fin-001',
            wellId: 'well-1',
            name: 'تعرفة مختلطة',
            status: 'active',
            effectiveFrom: t0,
            rules: const [solarRule, dieselRule],
          ),
        );

        // عرض شاشة ضيقة 360px
        await pumpScreen(
          tester,
          repo: _FakeOperationsRepo(),
          priceRepo: priceRepo,
          clock: () => now,
          physicalSize: const Size(360, 800),
        );

        // 39. ثبات الحساب المالي 3,493 وليس 6,808
        expect(find.text('3,493'), findsOneWidget);
        expect(find.text('6,808'), findsNothing);

        // 40. فحص عدم وجود تجاوزات (Overflow) في حالة الجريان
        expect(tester.takeException(), isNull);

        // الإيقاف المؤقت
        final pauseBtn = find.text('إيقاف مؤقت');
        await tester.ensureVisible(pauseBtn);
        await tester.tap(pauseBtn);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('تأكيد'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // الإنهاء
        final endBtn = find.text('إنهاء الجلسة');
        await tester.ensureVisible(endBtn);
        await tester.tap(endBtn);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // الملخص
        await tester.tap(find.text('تأكيد الإنهاء'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('3,493'), findsWidgets);

        await tester.tap(find.text('تسجيل دفعة'));
        await tester.pumpAndSettle();
        expect(find.byType(PaymentReceiptDialog), findsOneWidget);
        expect(find.textContaining('ريال يمني'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('عرض 412 مع تكبير النص يعرض نموذج ما قبل الجلسة بلا تجاوز', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(412, 900),
              textScaler: TextScaler.linear(1.3),
            ),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: OperationsScreen(
                identity: testIdentity(
                  accountId: accountId,
                  wells: const [well],
                ),
                coordinator: coordinator,
                repository: _FakeOperationsRepo(
                  pumps: const [
                    Pump(
                      id: 'pump-1',
                      wellId: 'well-1',
                      name: 'مضخة رئيسية',
                      publicCode: 'HIDDEN',
                    ),
                  ],
                ),
                priceRepository: _FakePriceRepo(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بيانات ومحددات السقي'), findsOneWidget);
      expect(find.textContaining('HIDDEN'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

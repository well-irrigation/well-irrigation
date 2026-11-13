import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/api/session_financial_adjustment.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/session_financial_adjustment.dart';
import 'package:well_irrigation_mobile/features/farmers/farmer_detail_screen.dart';
import 'package:well_irrigation_mobile/features/history/session_detail_screen.dart';
import 'package:well_irrigation_mobile/features/history/session_financial_adjustment_form.dart';
import 'package:well_irrigation_mobile/features/history/session_financial_adjustment_screen.dart';

final now = DateTime.utc(2026, 11, 11);
Map<String, Object?> state({
  bool allowed = true,
  String status = 'ready',
  int? effective = 8500,
  int revision = 3,
  bool approved = false,
}) => {
  'contract': 'session_financial_state',
  'version': 1,
  'well_id': 'well',
  'session_id': 'session',
  'original_amount_minor': effective == null ? null : 10000,
  'system_amount_minor': effective == null ? null : 9000,
  'approved_amount_minor': approved ? effective : null,
  'effective_amount_minor': effective,
  'paid_amount_minor': effective == null ? null : 123,
  'outstanding_amount_minor': effective == null ? null : 456,
  'operational_revision': revision,
  'system_financial_revision': 2,
  'manual_approval_revision': approved ? 1 : 0,
  'can_adjust': allowed,
  'financial_status': status,
  'reason_code': null,
  'adjustment_history': [
    if (approved)
      {
        'manual_approval_revision': 1,
        'previous_effective_minor': 9000,
        'approved_amount_minor': effective,
        'delta_minor': -500,
        'status': 'accepted',
        'reason': 'مراجعة سابقة',
        'actor_name': 'أحمد',
        'accepted_at': '2026-11-11T12:00:00Z',
      },
  ],
};

class _Repo extends OperationsRepository {
  Map<String, Object?> raw = state();
  bool offline = false, denied = false, failDetail = false;
  String sessionStatus = 'closed';
  int reads = 0, detailReads = 0, detailAmount = 8500;
  final capabilityScopes = <(String, String)>[];
  Completer<SessionFinancialState>? nextRead;

  @override
  Future<SessionFinancialState> getSessionFinancialState({
    required String accountId,
    required String sessionId,
  }) async {
    reads++;
    if (offline) throw StateError('offline');
    final gate = nextRead;
    nextRead = null;
    if (gate != null) return gate.future;
    return SessionFinancialState.fromContract(raw, sessionId: sessionId);
  }

  @override
  Future<SessionFinancialAdjustmentCapability>
  getSessionFinancialAdjustmentCapability({
    required String accountId,
    required String sessionId,
  }) async {
    capabilityScopes.add((accountId, sessionId));
    if (offline) throw StateError('offline');
    return SessionFinancialAdjustmentCapability.fromContract(
      denied
          ? {
              'contract': 'session_financial_adjustment_capability',
              'version': 1,
              'session_id': sessionId,
              'can_adjust': false,
              'reason_code': 'permission_denied',
            }
          : {...raw, 'contract': 'session_financial_adjustment_capability'},
      sessionId: sessionId,
    );
  }

  @override
  Future<FarmerDetailData> fetchFarmerDetail({
    required String wellId,
    required String farmerAccountId,
  }) async => FarmerDetailData(
    account: FarmerAccount(
      id: farmerAccountId,
      fullName: 'أحمد',
      publicCode: 'F-01',
      phone: '771234567',
    ),
    farms: const [],
    totalSessionsCount: 1,
    totalBilledYER: 8500,
    totalPaidYER: 0,
    netBalanceYER: 8500,
    recentSessions: [(await fetchSessionDetail('session')).session],
  );

  @override
  Future<SessionDetailData> fetchSessionDetail(String sessionId) async {
    detailReads++;
    if (failDetail) throw StateError('offline');
    return SessionDetailData(
      session: SessionHistoryItem(
        id: sessionId,
        wellId: 'well',
        farmerName: 'أحمد',
        farmerCode: 'ف١',
        farmerAccountId: 'farmer',
        farmName: 'الوادي',
        pumpName: 'المضخة',
        operatorName: 'المشغل',
        startedAt: now,
        endedAt: sessionStatus == 'closed' ? now : null,
        status: sessionStatus,
        totalAmountYER: detailAmount,
        hasCharge: true,
      ),
      segments: const [],
      canReadSessionCorrections: false,
      canCorrectSession: false,
    );
  }
}

class _Coordinator extends OfflineSessionCoordinator {
  _Coordinator(InMemoryOutboxStore store) : super(store: store);
  SessionFinancialAdjustmentFollowUpLookup? blocker;
  Completer<SessionFinancialAdjustmentFollowUpLookup>? nextLookup;
  Completer<SessionFinancialAdjustmentFollowUpLookup>? nextObservation;
  int observationReads = 0;
  int submitCalls = 0;

  @override
  Future<CommandEnvelope> submitSessionFinancialAdjustment({
    required String accountId,
    required String wellId,
    required String sessionId,
    required int baseOperationalRevision,
    required int baseSystemFinancialRevision,
    required int baseManualApprovalRevision,
    required int approvedAmountYER,
    required String reason,
  }) {
    submitCalls++;
    return super.submitSessionFinancialAdjustment(
      accountId: accountId,
      wellId: wellId,
      sessionId: sessionId,
      baseOperationalRevision: baseOperationalRevision,
      baseSystemFinancialRevision: baseSystemFinancialRevision,
      baseManualApprovalRevision: baseManualApprovalRevision,
      approvedAmountYER: approvedAmountYER,
      reason: reason,
    );
  }

  @override
  Future<SessionFinancialAdjustmentFollowUpLookup>
  readSessionFinancialAdjustmentFollowUp({
    required String accountId,
    required String wellId,
    required String sessionId,
    required String localId,
  }) async {
    observationReads++;
    final gate = nextObservation;
    nextObservation = null;
    if (gate != null) return gate.future;
    return super.readSessionFinancialAdjustmentFollowUp(
      accountId: accountId,
      wellId: wellId,
      sessionId: sessionId,
      localId: localId,
    );
  }

  @override
  Future<SessionFinancialAdjustmentFollowUpLookup>
  findBlockingSessionFinancialAdjustmentFollowUp({
    required String accountId,
    required String wellId,
    required String sessionId,
  }) async {
    final gate = nextLookup;
    nextLookup = null;
    if (gate != null) return gate.future;
    return blocker ??
        await super.findBlockingSessionFinancialAdjustmentFollowUp(
          accountId: accountId,
          wellId: wellId,
          sessionId: sessionId,
        );
  }
}

const amount = ValueKey('financial_adjustment_amount');
const reason = ValueKey('financial_adjustment_reason');
const review = ValueKey('financial_adjustment_review');
const confirm = ValueKey('financial_adjustment_confirm');

void main() {
  late _Repo repo;
  late InMemoryOutboxStore store;
  late _Coordinator coordinator;
  setUp(() {
    repo = _Repo();
    store = InMemoryOutboxStore();
    coordinator = _Coordinator(store);
  });
  tearDown(() async => store.close());
  void widgetTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        coordinator.dispose();
      }
    });
  }

  Future<List<CommandEnvelope>> rows() => store.allCommands('account');
  Widget screen({String? localId}) => SessionFinancialAdjustmentScreen(
    accountId: 'account',
    wellId: 'well',
    sessionId: 'session',
    sessionLabel: 'جلسة الوادي',
    repository: repo,
    coordinator: coordinator,
    localId: localId,
  );
  Future<void> tap(WidgetTester t, Finder finder) async {
    await t.ensureVisible(finder);
    await t.tap(finder);
    await t.pumpAndSettle();
  }

  Future<void> open(WidgetTester t, {String? localId}) async {
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<bool>(
                  builder: (_) => screen(localId: localId),
                ),
              ),
              child: const Text('فتح'),
            ),
          ),
        ),
      ),
    );
    await tap(t, find.text('فتح'));
  }

  Future<void> detail(WidgetTester t) async {
    await t.pumpWidget(
      MaterialApp(
        home: SessionDetailScreen(
          sessionId: 'session',
          wellName: 'البئر',
          accountId: 'account',
          wellId: 'well',
          repository: repo,
          coordinator: coordinator,
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> form(
    WidgetTester t,
    String value, {
    String why = 'سبب التعديل',
  }) async {
    await t.enterText(find.byKey(amount), value);
    await t.enterText(find.byKey(reason), why);
    await tap(t, find.byKey(review));
  }

  Future<CommandEnvelope> seed() =>
      OutboxRepository(
        store: store,
        clock: () => now,
      ).enqueueSessionFinancialAdjustment(
        accountId: 'account',
        wellId: 'well',
        sessionId: 'session',
        baseOperationalRevision: 3,
        baseSystemFinancialRevision: 2,
        baseManualApprovalRevision: 0,
        approvedAmountYER: 0,
        reason: 'سبب التعديل',
      );
  Future<void> observe(
    CommandEnvelope command,
    SessionFinancialAdjustmentState outcome,
  ) async {
    await store.claim('account', command.localId, attemptedAt: now);
    await store.recordSessionFinancialAdjustmentObservation(
      accountId: 'account',
      localId: command.localId,
      state: outcome,
      observedAt: now,
      result: sessionFinancialStoredResult(
        SessionFinancialAdjustmentResponse(
          state: outcome,
          accepted: outcome == SessionFinancialAdjustmentState.accepted
              ? AcceptedSessionFinancialAdjustment(
                  adjustmentId: 'adjustment',
                  operationalRevision: 3,
                  systemFinancialRevision: 3,
                  manualApprovalRevision: 1,
                  previousEffectiveYER: 8500,
                  approvedAmountYER: 0,
                  effectiveAmountYER: 0,
                  deltaYER: -8500,
                  acceptedAt: now,
                )
              : null,
        ),
      ),
    );
  }

  test('strict whole YER parser', () {
    for (final value in ['8500', '٨٥٠٠', '۸۵۰۰', '8,500', '٨٬٥٠٠']) {
      expect(parseSessionFinancialAmount(value), 8500, reason: value);
    }
    expect(parseSessionFinancialAmount('0'), 0);
    expect(
      parseSessionFinancialAmount('9223372036854775807'),
      9223372036854775807,
    );
    for (final value in [
      '',
      ' ',
      '-1',
      '+1',
      '12.5',
      '12,5',
      '١٢٫٥',
      'abc123',
      '8,50',
      '8,,500',
      '8,500٬000',
      '9223372036854775808',
    ]) {
      expect(parseSessionFinancialAmount(value), isNull, reason: value);
    }
  });
  for (final mode in [
    'allowed',
    'denied',
    'locked',
    'review-denied',
    'review-allowed',
    'offline',
    'active',
  ]) {
    widgetTest('detail entry $mode', (t) async {
      repo.denied = mode == 'denied';
      repo.offline = mode == 'offline';
      if (mode == 'active') repo.sessionStatus = 'open';
      if (mode == 'locked') repo.raw = state(allowed: false, status: 'locked');
      if (mode.startsWith('review')) {
        repo.raw = state(
          allowed: mode == 'review-allowed',
          status: 'financial_review_required',
        );
      }
      await detail(t);
      expect(
        find.text('تعديل المبلغ'),
        ['allowed', 'review-allowed'].contains(mode)
            ? findsOneWidget
            : findsNothing,
      );
      if (mode == 'offline') {
        expect(find.byTooltip('إعادة تحميل البيانات المالية'), findsOneWidget);
      }
      if (mode == 'locked') {
        expect(find.textContaining('إجراء مالي محمي'), findsOneWidget);
      }
      if (mode == 'review-denied') {
        expect(find.textContaining('مراجعة مالية قبل'), findsOneWidget);
      }
    });
  }
  widgetTest('completed history session opens financial route', (t) async {
    await detail(t);
    await tap(t, find.text('تعديل المبلغ'));
    expect(find.text('تعديل مبلغ الجلسة'), findsOneWidget);
    expect(find.byKey(amount), findsOneWidget);
  });
  for (final mode in ['allowed', 'denied', 'offline']) {
    widgetTest('farmer profile completed session preserves scope: $mode', (
      t,
    ) async {
      repo.denied = mode == 'denied';
      repo.offline = mode == 'offline';
      await t.pumpWidget(
        MaterialApp(
          home: FarmerDetailScreen(
            wellId: 'well',
            farmerAccountId: 'farmer',
            wellName: 'اسم البئر للعرض',
            canCreateFarm: false,
            accountId: 'account',
            repository: repo,
            coordinator: coordinator,
          ),
        ),
      );
      await t.pumpAndSettle();
      await tap(t, find.text('الجلسات (1)'));
      await tap(t, find.text('الوادي'));
      final session = t.widget<SessionDetailScreen>(
        find.byType(SessionDetailScreen),
      );
      expect((session.accountId, session.wellId), ('account', 'well'));
      expect(repo.capabilityScopes, [('account', 'session')]);
      expect(
        find.text('تعديل المبلغ'),
        mode == 'allowed' ? findsOneWidget : findsNothing,
      );
      expect(
        find.byTooltip('إعادة تحميل البيانات المالية'),
        mode == 'offline' ? findsOneWidget : findsNothing,
      );
      if (mode == 'allowed') {
        await tap(t, find.text('تعديل المبلغ'));
        expect(find.byKey(review), findsOneWidget);
      }
    });
  }
  widgetTest('server amounts and safe history at large text scale', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(320, 640);
    addTearDown(t.view.reset);
    repo.raw = state(effective: 9223372036854775807, approved: true);
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2.5)),
          child: child!,
        ),
        home: screen(),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('9,223,372,036,854,775,807'), findsWidgets);
    final rendered = t.renderObject<RenderParagraph>(
      find.text('9,223,372,036,854,775,807 ريال يمني').first,
    );
    expect(rendered.didExceedMaxLines, isFalse);
    expect(
      rendered
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 25),
          )
          .every(
            (box) => box.left >= -1 && box.right <= rendered.size.width + 1,
          ),
      isTrue,
    );

    expect(find.textContaining('123 ريال'), findsOneWidget);
    expect(find.textContaining('456 ريال'), findsOneWidget);
    await tap(t, find.text('المزيد من التفاصيل'));
    expect(find.textContaining('10,000 ريال'), findsOneWidget);
    await tap(t, find.text('سجل تعديلات المبلغ'));
    expect(find.text('أحمد'), findsOneWidget);
    expect(find.text('مراجعة سابقة'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  widgetTest('null amounts remain unavailable', (t) async {
    repo.raw = state(allowed: false, effective: null);
    await open(t);
    expect(find.text('غير متاح'), findsNWidgets(4));
    expect(find.byKey(amount), findsNothing);
  });
  widgetTest('server zero is displayed and prefilled', (t) async {
    repo.raw = state(effective: 0, approved: true);
    await open(t);
    expect(find.text('0 ريال يمني'), findsOneWidget);
    expect(t.widget<TextFormField>(find.byKey(amount)).controller!.text, '0');
    expect(find.text('آخر مبلغ معتمد يدويًا'), findsNothing);
  });
  for (final value in [
    '',
    '-100',
    '12.5',
    '12,5',
    'abc123',
    '8,50',
    '9223372036854775808',
  ]) {
    widgetTest('invalid amount $value remains visible and invalid', (t) async {
      await open(t);
      await form(t, value);
      expect(find.text('أدخل مبلغًا صحيحًا بالريال اليمني.'), findsOneWidget);
      expect(
        t.widget<TextFormField>(find.byKey(amount)).controller!.text,
        value,
      );
      expect(await rows(), isEmpty);
    });
  }
  widgetTest('blank reason and normal no-op are rejected', (t) async {
    await open(t);
    await form(t, '8500', why: '  ');
    expect(find.text('سبب تعديل المبلغ مطلوب.'), findsOneWidget);
    await form(t, '8500');
    expect(find.text('أدخل مبلغًا مختلفًا عن المبلغ الحالي.'), findsOneWidget);
    expect(find.byKey(confirm), findsNothing);
  });
  widgetTest('review-required permits same-amount reapproval', (t) async {
    repo.raw = state(status: 'financial_review_required');
    await open(t);
    await form(t, '8500');
    expect(find.byKey(confirm), findsOneWidget);
    await tap(t, find.byKey(confirm));
    expect((await rows()).single.payload['p_approved_amount_minor'], 8500);
  });
  widgetTest('cancel then double confirm saves exact offline snapshot once', (
    t,
  ) async {
    await open(t);
    await form(t, '٠', why: '  سبب التعديل  ');
    expect(find.text('المبلغ الحالي'), findsOneWidget);
    expect(
      find.text('سيصبح المبلغ المعتمد لهذه الجلسة صفرًا.'),
      findsOneWidget,
    );
    expect(find.textContaining('هذا الإجراء لا يسجل دفعة'), findsOneWidget);
    final cancel = t
        .widget<TextButton>(find.widgetWithText(TextButton, 'رجوع'))
        .onPressed!;
    cancel();
    cancel();
    await t.pumpAndSettle();
    expect(await rows(), isEmpty);
    final reviewPress = t.widget<FilledButton>(find.byKey(review)).onPressed!;
    reviewPress();
    reviewPress();
    await t.pumpAndSettle();
    expect(find.byKey(confirm), findsOneWidget);
    repo.offline = true;
    final press = t.widget<FilledButton>(find.byKey(confirm)).onPressed!;
    press();
    press();
    await t.pumpAndSettle();
    final r = SessionFinancialAdjustmentRequest.fromCommand(
      (await rows()).single,
    )!;
    expect(repo.reads, 1);
    expect(
      (
        r.baseOperationalRevision,
        r.baseSystemFinancialRevision,
        r.baseManualApprovalRevision,
      ),
      (3, 2, 0),
    );
    expect(r.approvedAmountYER, 0);
    expect(r.reason, 'سبب التعديل');
    expect(
      find.textContaining('تم حفظ تعديل المبلغ على الجهاز'),
      findsOneWidget,
    );
  });
  widgetTest('offline without snapshot offers read only', (t) async {
    repo.offline = true;
    await open(t);
    expect(find.textContaining('اتصل بالإنترنت وأعد التحميل'), findsOneWidget);
    expect(find.byKey(review), findsNothing);
    expect(await rows(), isEmpty);
  });
  for (final outcome in [
    null,
    SessionFinancialAdjustmentState.processing,
    SessionFinancialAdjustmentState.unresolved,
    SessionFinancialAdjustmentState.notFound,
  ]) {
    widgetTest('durable blocker $outcome replaces edit form', (t) async {
      final c = await seed();
      if (outcome != null) await observe(c, outcome);
      await open(t);
      expect(find.byKey(review), findsNothing);
      expect(find.text('متابعة الحالة'), findsOneWidget);
      expect(find.textContaining('إعادة الإرسال'), findsNothing);
      expect(await rows(), hasLength(1));
    });
  }
  widgetTest('dispatching, unavailable and ambiguous block new intent', (
    t,
  ) async {
    final c = await seed();
    await store.claim('account', c.localId, attemptedAt: now);
    await open(t);
    expect(find.byKey(review), findsNothing);
    for (final result in [
      const SessionFinancialAdjustmentFollowUpLookup.unavailable(),
      const SessionFinancialAdjustmentFollowUpLookup.ambiguous(),
    ]) {
      coordinator.blocker = result;
      await t.pumpWidget(const SizedBox());
      await open(t);
      expect(
        find.textContaining('تعذر التحقق من حالة تعديل سابق'),
        findsOneWidget,
      );
      expect(find.byKey(review), findsNothing);
    }
  });
  for (final outcome in [
    SessionFinancialAdjustmentState.validationError,
    SessionFinancialAdjustmentState.conflictRequest,
    SessionFinancialAdjustmentState.conflictRevision,
    SessionFinancialAdjustmentState.financialReviewRequired,
    SessionFinancialAdjustmentState.locked,
    SessionFinancialAdjustmentState.permissionDenied,
  ]) {
    widgetTest('terminal $outcome requires explicit next action', (t) async {
      final c = await seed();
      await observe(c, outcome);
      await open(t, localId: c.localId);
      expect(find.byKey(review), findsNothing);
      expect(find.textContaining('إعادة الإرسال'), findsNothing);
      final message = switch (outcome) {
        SessionFinancialAdjustmentState.validationError => 'لم يُعتمد التعديل',
        SessionFinancialAdjustmentState.conflictRequest =>
          'تعذر التحقق من سلامة هذا الطلب',
        SessionFinancialAdjustmentState.conflictRevision =>
          'تغيرت بيانات الجلسة',
        SessionFinancialAdjustmentState.financialReviewRequired =>
          'مراجعة مالية قبل تعديل المبلغ',
        SessionFinancialAdjustmentState.locked => 'إجراء مالي محمي',
        SessionFinancialAdjustmentState.permissionDenied =>
          'لم تعد لديك صلاحية',
        _ => throw StateError('unexpected test outcome'),
      };
      expect(find.textContaining(message), findsOneWidget);
      expect(
        find.text(
          outcome == SessionFinancialAdjustmentState.conflictRequest
              ? 'متابعة الحالة'
              : 'راجع البيانات من جديد',
        ),
        findsOneWidget,
      );
      if (outcome == SessionFinancialAdjustmentState.conflictRevision) {
        expect(find.textContaining('تغيرت بيانات الجلسة'), findsOneWidget);
        repo.raw = state(revision: 4);
        await tap(t, find.text('راجع البيانات من جديد'));
        await form(t, '100');
        await tap(t, find.byKey(confirm));
        final saved = await rows();
        expect(saved, hasLength(2));
        expect(saved.last.commandId, isNot(c.commandId));
        expect(saved.last.payload['p_base_operational_revision'], 4);
      } else {
        expect(await rows(), hasLength(1));
      }
    });
  }
  for (final fail in [false, true]) {
    widgetTest(
      'automatic acceptance returns and refreshes detail, read fails=$fail',
      (t) async {
        await detail(t);
        await tap(t, find.text('تعديل المبلغ'));
        await form(t, '0');
        await tap(t, find.byKey(confirm));
        expect(coordinator.submitCalls, 1);
        final command = (await rows()).single;
        await observe(command, SessionFinancialAdjustmentState.processing);
        await t.pump(const Duration(seconds: 2));
        expect(
          find.textContaining('جارٍ التحقق من تعديل المبلغ'),
          findsOneWidget,
        );
        repo.detailAmount = 777;
        repo.failDetail = fail;
        await observe(command, SessionFinancialAdjustmentState.accepted);
        await t.pump(const Duration(seconds: 2));
        await t.pumpAndSettle();
        expect(find.byType(SessionFinancialAdjustmentScreen), findsNothing);
        expect(find.text('تم اعتماد تعديل المبلغ.'), findsOneWidget);
        expect(repo.detailReads, 2);
        expect(find.textContaining(fail ? '8,500' : '777'), findsWidgets);
        expect(coordinator.submitCalls, 1);
        expect(await rows(), hasLength(1));
      },
    );
  }
  widgetTest('automatic read in flight cannot navigate after system back', (
    t,
  ) async {
    final command = await seed();
    await observe(command, SessionFinancialAdjustmentState.processing);
    await detail(t);
    await tap(t, find.text('متابعة تعديل المبلغ'));
    final gate = Completer<SessionFinancialAdjustmentFollowUpLookup>();
    coordinator.nextObservation = gate;
    await t.pump(const Duration(seconds: 2));
    expect(coordinator.nextObservation, isNull);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await observe(command, SessionFinancialAdjustmentState.accepted);
    gate.complete(
      await coordinator.readSessionFinancialAdjustmentFollowUp(
        accountId: 'account',
        wellId: 'well',
        sessionId: 'session',
        localId: command.localId,
      ),
    );
    final reads = coordinator.observationReads;
    await t.pump(const Duration(seconds: 10));
    await t.pumpAndSettle();
    expect(coordinator.observationReads, reads);
    expect(find.byType(SessionDetailScreen), findsOneWidget);
    expect(find.text('تم اعتماد تعديل المبلغ.'), findsNothing);
    expect(repo.detailReads, 1);
  });
  widgetTest('manual read invalidates in-flight automatic acceptance', (
    t,
  ) async {
    final command = await seed();
    await observe(command, SessionFinancialAdjustmentState.processing);
    await detail(t);
    await tap(t, find.text('متابعة تعديل المبلغ'));
    final gate = Completer<SessionFinancialAdjustmentFollowUpLookup>();
    coordinator.nextObservation = gate;
    await t.pump(const Duration(seconds: 2));
    expect(coordinator.nextObservation, isNull);
    final reads = coordinator.observationReads;
    await t.pump(const Duration(seconds: 6));
    expect(coordinator.observationReads, reads);
    await observe(command, SessionFinancialAdjustmentState.accepted);
    final accepted = await coordinator.readSessionFinancialAdjustmentFollowUp(
      accountId: 'account',
      wellId: 'well',
      sessionId: 'session',
      localId: command.localId,
    );
    await tap(t, find.text('متابعة الحالة'));
    gate.complete(accepted);
    await t.pumpAndSettle();
    expect(find.byType(SessionDetailScreen), findsOneWidget);
    expect(find.text('تم اعتماد تعديل المبلغ.'), findsOneWidget);
    expect(repo.detailReads, 2);
    expect(coordinator.submitCalls, 0);
    expect(await rows(), hasLength(1));
  });
  widgetTest('automatic and manual status reads never submit again', (t) async {
    await open(t);
    await form(t, '0');
    await tap(t, find.byKey(confirm));
    expect(coordinator.submitCalls, 1);
    final command = (await rows()).single;
    await observe(command, SessionFinancialAdjustmentState.processing);
    final reads = coordinator.observationReads;
    for (var i = 1; i <= 3; i++) {
      await t.pump(const Duration(seconds: 2));
      expect(coordinator.observationReads, reads + i);
      expect(coordinator.submitCalls, 1);
    }
    await tap(t, find.text('متابعة الحالة'));
    expect(coordinator.observationReads, reads + 4);
    expect(coordinator.submitCalls, 1);
    expect((await rows()).single.localId, command.localId);
    expect(find.textContaining('جارٍ التحقق من تعديل المبلغ'), findsOneWidget);
  });
  widgetTest('reopened processing re-observes without another command', (
    t,
  ) async {
    final command = await seed();
    await observe(command, SessionFinancialAdjustmentState.processing);
    await open(t);
    final initialReads = coordinator.observationReads;
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(seconds: 2));
      expect(coordinator.observationReads, initialReads + i + 1);
      expect(
        find.textContaining('جارٍ التحقق من تعديل المبلغ'),
        findsOneWidget,
      );
      expect(await rows(), hasLength(1));
      expect((await rows()).single.localId, command.localId);
      expect(repo.reads, 0);
    }
  });
  widgetTest('automatic observation pauses while another route is current', (
    t,
  ) async {
    final command = await seed();
    await observe(command, SessionFinancialAdjustmentState.processing);
    await open(t);
    final reads = coordinator.observationReads;
    final navigator = Navigator.of(
      t.element(find.byType(SessionFinancialAdjustmentScreen)),
    );
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('صفحة أخرى')),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 10));
    expect(coordinator.observationReads, reads);
    navigator.pop();
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 2));
    expect(coordinator.observationReads, reads + 1);
    expect(await rows(), hasLength(1));
  });
  widgetTest('automatic observation resumes after a cancelled back gesture', (
    t,
  ) async {
    final command = await seed();
    await observe(command, SessionFinancialAdjustmentState.processing);
    await open(t);
    final reads = coordinator.observationReads;
    final navigator = Navigator.of(
      t.element(find.byType(SessionFinancialAdjustmentScreen)),
    );
    navigator.didStartUserGesture();
    await t.pump(const Duration(seconds: 4));
    expect(coordinator.observationReads, reads);
    navigator.didStopUserGesture();
    await t.pump(const Duration(seconds: 2));
    expect(coordinator.observationReads, reads + 1);
  });
  for (final interruption in [
    'gesture',
    'covered route',
    'automatic gesture',
    'completed gesture',
  ]) {
    widgetTest('acceptance observed before ownership returns: $interruption', (
      t,
    ) async {
      final command = await seed();
      await observe(command, SessionFinancialAdjustmentState.processing);
      await detail(t);
      await tap(t, find.text('متابعة تعديل المبلغ'));
      final navigator = Navigator.of(
        t.element(find.byType(SessionFinancialAdjustmentScreen)),
      );
      final gate = Completer<SessionFinancialAdjustmentFollowUpLookup>();
      coordinator.nextObservation = gate;
      if (interruption == 'automatic gesture') {
        await t.pump(const Duration(seconds: 2));
      } else {
        await tap(t, find.text('متابعة الحالة'));
      }
      expect(coordinator.nextObservation, isNull);
      if (interruption == 'covered route') {
        unawaited(
          navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('صفحة أخرى')),
            ),
          ),
        );
        await t.pumpAndSettle();
      } else {
        navigator.didStartUserGesture();
      }
      await observe(command, SessionFinancialAdjustmentState.accepted);
      gate.complete(
        await coordinator.readSessionFinancialAdjustmentFollowUp(
          accountId: 'account',
          wellId: 'well',
          sessionId: 'session',
          localId: command.localId,
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.byType(SessionFinancialAdjustmentScreen, skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text('تم اعتماد تعديل المبلغ.', skipOffstage: false),
        findsOneWidget,
      );
      expect(repo.detailReads, 1);
      final reads = coordinator.observationReads;
      if (interruption == 'covered route') {
        navigator.pop();
      } else {
        if (interruption == 'completed gesture') navigator.pop();
        navigator.didStopUserGesture();
      }
      await t.pumpAndSettle();
      await t.pump(const Duration(seconds: 10));
      expect(find.byType(SessionFinancialAdjustmentScreen), findsNothing);
      expect(find.byType(SessionDetailScreen), findsOneWidget);
      expect(coordinator.observationReads, reads);
      final departed = interruption == 'completed gesture';
      expect(repo.detailReads, departed ? 1 : 2);
      expect(
        find.text('تم اعتماد تعديل المبلغ.'),
        departed ? findsNothing : findsOneWidget,
      );
      expect(coordinator.submitCalls, 0);
    });
  }
  for (final outcome in [
    SessionFinancialAdjustmentState.unresolved,
    SessionFinancialAdjustmentState.notFound,
  ]) {
    widgetTest('automatic observation stops on $outcome', (t) async {
      await open(t);
      await form(t, '0');
      await tap(t, find.byKey(confirm));
      expect(coordinator.submitCalls, 1);
      final command = (await rows()).single;
      await observe(command, SessionFinancialAdjustmentState.processing);
      await t.pump(const Duration(seconds: 2));
      await observe(command, outcome);
      await t.pump(const Duration(seconds: 2));
      expect(
        find.textContaining('لم نتمكن من التأكد من نتيجة التعديل'),
        findsOneWidget,
      );
      final reads = coordinator.observationReads;
      await t.pump(const Duration(seconds: 10));
      expect(coordinator.observationReads, reads);
      expect(find.textContaining('إعادة الإرسال'), findsNothing);
      expect(find.byKey(review), findsNothing);
      expect(coordinator.submitCalls, 1);
      expect(await rows(), hasLength(1));
    });
  }
  widgetTest(
    'late accepted observation after system back leaves parent intact',
    (t) async {
      await open(t);
      await form(t, '0');
      await tap(t, find.byKey(confirm));
      final c = (await rows()).single;
      await observe(c, SessionFinancialAdjustmentState.accepted);
      final accepted = await coordinator.readSessionFinancialAdjustmentFollowUp(
        accountId: 'account',
        wellId: 'well',
        sessionId: 'session',
        localId: c.localId,
      );
      final gate = Completer<SessionFinancialAdjustmentFollowUpLookup>();
      coordinator.nextObservation = gate;
      await tap(t, find.text('متابعة الحالة'));
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      gate.complete(accepted);
      await t.pumpAndSettle();
      expect(find.text('فتح'), findsOneWidget);
      expect(find.text('تم اعتماد تعديل المبلغ.'), findsNothing);
    },
  );

  widgetTest('two accepted observations pop only once', (t) async {
    await open(t);
    await form(t, '0');
    await tap(t, find.byKey(confirm));
    final c = (await rows()).single;
    await observe(c, SessionFinancialAdjustmentState.accepted);
    final accepted = await coordinator.readSessionFinancialAdjustmentFollowUp(
      accountId: 'account',
      wellId: 'well',
      sessionId: 'session',
      localId: c.localId,
    );
    final gate = Completer<SessionFinancialAdjustmentFollowUpLookup>();
    coordinator.nextObservation = gate;
    final refresh = t
        .widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'متابعة الحالة'),
        )
        .onPressed!;
    refresh();
    refresh();
    await t.pumpAndSettle();
    gate.complete(accepted);
    await t.pumpAndSettle();
    expect(find.text('فتح'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  widgetTest('a new blocker while confirmation is open prevents submission', (
    t,
  ) async {
    await open(t);
    await form(t, '0');
    await seed();
    await tap(t, find.byKey(confirm));
    expect(await rows(), hasLength(1));
    expect(find.byKey(review), findsNothing);
    expect(find.text('متابعة الحالة'), findsOneWidget);
  });

  widgetTest(
    'the selected follow-up stays exact when it becomes accepted before opening',
    (t) async {
      final c = await seed();
      await detail(t);
      await observe(c, SessionFinancialAdjustmentState.accepted);
      await tap(t, find.text('متابعة تعديل المبلغ'));
      expect(find.byType(SessionFinancialAdjustmentScreen), findsNothing);
      expect(find.text('تم اعتماد تعديل المبلغ.'), findsOneWidget);
      expect(await rows(), hasLength(1));
    },
  );

  widgetTest('newer read wins and late error after back is harmless', (
    t,
  ) async {
    final old = Completer<SessionFinancialState>();
    repo.nextRead = old;
    await open(t);
    repo.raw = state(effective: 1234);
    await tap(t, find.byTooltip('إعادة تحميل البيانات المالية'));
    expect(
      t.widget<TextFormField>(find.byKey(amount)).controller!.text,
      '1234',
    );
    old.complete(
      SessionFinancialState.fromContract(
        state(effective: 999),
        sessionId: 'session',
      ),
    );
    await t.pumpAndSettle();
    expect(
      t.widget<TextFormField>(find.byKey(amount)).controller!.text,
      '1234',
    );
    final late = Completer<SessionFinancialState>();
    repo.nextRead = late;
    await tap(t, find.byTooltip('إعادة تحميل البيانات المالية'));
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    late.completeError(StateError('late error'));
    await t.pumpAndSettle();
    expect(find.text('فتح'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  widgetTest('back during local follow-up read invalidates late result', (
    t,
  ) async {
    final gate = Completer<SessionFinancialAdjustmentFollowUpLookup>();
    coordinator.nextLookup = gate;
    await open(t);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    gate.complete(const SessionFinancialAdjustmentFollowUpLookup.absent());
    await t.pumpAndSettle();
    expect(find.text('فتح'), findsOneWidget);
    expect(repo.reads, 0);
  });
}

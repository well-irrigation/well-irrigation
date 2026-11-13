import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/features/history/session_detail_screen.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';

import '../../core/session/session_test_support.dart' show acceptTestCompletion;

/// مستودع اختبار يحاكي عقد `api.get_session_detail` (م-41C2).
/// الشاشة لم تعد تملك تفصيلًا وهميًا: عقد حقيقي أو فشل صريح.
class _FakeOperationsRepository extends OperationsRepository {
  const _FakeOperationsRepository({
    this.shouldFail = false,
    this.billed = true,
    this.canRead = false,
    this.canCorrect = false,
  });

  final bool shouldFail;
  final bool billed;
  final bool canRead;
  final bool canCorrect;

  @override
  Future<SessionDetailData> fetchSessionDetail(String sessionId) async {
    if (shouldFail) {
      throw StateError('backend unavailable');
    }

    final started = DateTime(2026, 8, 31, 9);

    return SessionDetailData(
      canReadSessionCorrections: canRead,
      canCorrectSession: canCorrect,
      session: SessionHistoryItem(
        id: sessionId,
        wellId: 'well-1',
        farmerName: 'محمد علي الحبيشي',
        farmerCode: 'F-001',
        farmerAccountId: 'acc-1',
        farmName: 'مزرعة الوادي الشرقية',
        pumpName: 'المضخة الرئيسية 1',
        operatorName: 'خالد النجحي',
        startedAt: started,
        endedAt: started.add(const Duration(hours: 1, minutes: 30)),
        energySourceCode: 'solar',
        // الفعلي مجموع المقاطع 3000+600+1800 = 5400، والمفوتر 4800
        // (التوقف غير محسوب) — كميتان منفصلتان كما يعيدهما العقد (ق-131).
        actualSeconds: 5400,
        billableSeconds: billed ? 4800 : 0,
        totalAmountYER: billed ? 2917 : 0,
        paidAmountYER: billed ? 2917 : 0,
        paymentStatus: billed ? 'settled' : 'not_billed',
        hasCharge: billed,
        hasInvoice: billed,
      ),
      segments: [
        SessionSegmentItem(
          sequenceNumber: 1,
          segmentType: 'solar_run',
          isStop: false,
          isBillable: true,
          energySourceCode: 'solar',
          startedAt: started,
          endedAt: started.add(const Duration(minutes: 50)),
          actualSeconds: 3000,
          billableSeconds: 3000,
          appliedRateYER: 3500,
          timeChargeYER: 2917,
          totalChargeYER: 2917,
        ),
        SessionSegmentItem(
          sequenceNumber: 2,
          segmentType: 'operator_pause',
          isStop: true,
          isBillable: false,
          startedAt: started.add(const Duration(minutes: 50)),
          endedAt: started.add(const Duration(hours: 1)),
          actualSeconds: 600,
        ),
        SessionSegmentItem(
          sequenceNumber: 3,
          segmentType: 'well_diesel_run',
          isStop: false,
          isBillable: true,
          energySourceCode: 'well_diesel',
          startedAt: started.add(const Duration(hours: 1)),
          actualSeconds: 1800,
          billableSeconds: 1800,
          appliedRateYER: 3500,
          timeChargeYER: 1750,
          totalChargeYER: 1750,
        ),
      ],
      crops: const ['قات', 'قمح'],
      paymentMethod: billed ? 'cash' : null,
      paymentReference: billed ? 'PMT-090-A' : null,
      paidAt: billed ? started.add(const Duration(hours: 2)) : null,
    );
  }
}

Widget _wrap({bool shouldFail = false, bool billed = true}) {
  return MaterialApp(
    locale: const Locale('ar'),
    home: SessionDetailScreen(
      sessionId: 'ses-090-a',
      wellName: 'بئر الخير الرئيسي',
      repository: _FakeOperationsRepository(
        shouldFail: shouldFail,
        billed: billed,
      ),
    ),
  );
}

void main() {
  _correctionActionVisibilityTests();
  group('SessionDetailScreen Tests (UX-13 / 377)', () {
    testWidgets('1. عرض تفاصيل الجلسة والخط الزمني والمستحق المالي', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      expect(find.text('محمد علي الحبيشي'), findsOneWidget);
      expect(find.text('بئر الخير الرئيسي'), findsOneWidget);
      expect(find.text('المضخة الرئيسية 1'), findsOneWidget);
      expect(find.text('خالد النجحي'), findsOneWidget);
      expect(find.text('المحاصيل: قات، قمح'), findsOneWidget);
      expect(find.text('الخط الزمني وتغيرات الطاقة'), findsOneWidget);
      expect(find.text('تشغيل عبر طاقة شمسية'), findsOneWidget);
      expect(find.text('إيقاف من المشغل'), findsOneWidget);
      expect(find.text('تشغيل عبر ديزل البئر'), findsOneWidget);
      expect(find.text('تفاصيل السداد'), findsOneWidget);
      expect(find.text('عرض ملخص الجلسة'), findsOneWidget);
      expect(find.text('مشاركة الملخص'), findsOneWidget);
    });

    testWidgets(
      '2. المقطع يعرض المبلغ المخزّن والتسعيرة المثبتة بلا حساب محلي',
      (tester) async {
        await tester.pumpWidget(_wrap());
        await tester.pumpAndSettle();

        expect(find.textContaining('2,917 ريال'), findsWidgets);
        expect(find.textContaining('التسعيرة المثبتة'), findsWidgets);
        expect(find.textContaining('محسوب على المزارع: لا'), findsOneWidget);
      },
    );

    testWidgets('2b. خلية المدة تعرض الفعلي لا المفوتر (ق-131 البند 7)', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      // 5400 ثانية = 1 س و 30 د و 0 ث — الفعلي بمقاطعه كلها.
      expect(find.text('مدة التنفيذ الفعلية'), findsOneWidget);
      expect(find.text('1 س و 30 د و 0 ث'), findsOneWidget);
    });

    testWidgets('3. فتح نافذة معاينة الفاتورة الحرارية عند الضغط على طباعة', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('عرض ملخص الجلسة'));
      await tester.pumpAndSettle();

      expect(find.text('ملخص الجلسة'), findsOneWidget);
      expect(find.text('الطباعة غير متاحة حاليًا'), findsOneWidget);
      await tester.tap(find.text('الطباعة غير متاحة حاليًا'));
      await tester.pump();
      expect(find.textContaining('تم إرسال أمر الطباعة'), findsNothing);
    });

    testWidgets(
      '3b. الإيصال الحراري يعرض الفعلي أولًا والمفوتر مميزًا حين يختلفا (ق-131)',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        await tester.pumpWidget(_wrap());
        await tester.pumpAndSettle();

        await tester.tap(find.text('عرض ملخص الجلسة'));
        await tester.pumpAndSettle();

        // سطر الفعلي أساسي، وسطر المفوتر مستقل مميز — لا يظهر أحدهما
        // بوصفه الآخر. والتسعيرة والمبلغ يبقيان من المفوتر المخزَّن.
        // (الخلية خلف النافذة والإيصال داخلها يشتركان في بعض النصوص.)
        expect(find.textContaining('مدة التنفيذ الفعلية'), findsWidgets);
        expect(find.textContaining('1 س و 30 د و 0 ث'), findsWidgets);
        expect(find.textContaining('الوقت المفوتر'), findsWidgets);
        expect(find.textContaining('1 س و 20 د و 0 ث'), findsOneWidget);
        expect(find.textContaining('سعر الساعة'), findsNothing);
        expect(find.textContaining('ليس فاتورة أو سند قبض'), findsOneWidget);
        expect(find.textContaining('2,917 ريال'), findsWidgets);
      },
    );

    testWidgets('4. الجلسة غير المفوترة لا تُطبع ولا تُفقَّط (ق-99)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(_wrap(billed: false));
      await tester.pumpAndSettle();

      expect(find.text('الحالة المالية لم تُعتمد بعد'), findsOneWidget);
      expect(find.text('لم تُعتمد التكلفة بعد'), findsOneWidget);
      expect(find.textContaining('فقط '), findsNothing);
      expect(find.text('طريقة السداد: غير مسجلة'), findsOneWidget);

      await tester.tap(find.text('عرض ملخص الجلسة'));
      await tester.pumpAndSettle();

      expect(find.text('ملخص الجلسة'), findsNothing);
      expect(
        find.textContaining('التكلفة المالية لهذه الجلسة لم تُعتمد بعد'),
        findsOneWidget,
      );
    });

    testWidgets('5. فشل العقد يظهر خطأً صريحًا مع إعادة المحاولة', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(shouldFail: true));
      await tester.pumpAndSettle();

      expect(find.textContaining('تعذّر تحميل تفاصيل الجلسة'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsOneWidget);
    });
  });
}

// Gate the canonical read independently of the real persisted detail cache.
class _CorrectionReadRepository extends OperationsRepository {
  Completer<SessionDetailData> response = Completer<SessionDetailData>();
  int reads = 0;
  @override
  Future<SessionDetailData> fetchSessionDetail(String sessionId) {
    reads++;
    return response.future;
  }
}

class _CorrectionEventCoordinator extends OfflineSessionCoordinator {
  _CorrectionEventCoordinator(InMemoryOutboxStore store) : super(store: store);
  final events = StreamController<ActiveSessionRecord>.broadcast();
  @override
  Stream<ActiveSessionRecord> watchCompletionResult({
    required String accountId,
    required String wellId,
    required String serverSessionId,
  }) => events.stream;
}

void _correctionActionVisibilityTests() {
  const action = 'تصحيح السجل';
  Future<SessionDetailData> data({required bool read, required bool correct}) =>
      _FakeOperationsRepository(
        canRead: read,
        canCorrect: correct,
      ).fetchSessionDetail('server');

  void viewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<_CorrectionEventCoordinator> cachedCoordinator() async {
    final store = InMemoryOutboxStore();
    final c = _CorrectionEventCoordinator(store);
    addTearDown(() async {
      await c.events.close();
      c.dispose();
    });
    final startTime = DateTime.utc(2026, 8, 31, 9);
    final start = await c.startSession(
      accountId: 'a',
      wellId: 'well-1',
      pumpId: 'p',
      farmId: 'f',
      farmerAccountId: 'acc-1',
      energySource: 'solar',
      startedAt: startTime,
    );
    final end = await c.completeSession(
      accountId: 'a',
      sessionLocalId: start.localId,
      completedAt: startTime.add(const Duration(minutes: 90)),
    );
    await acceptTestCompletion(
      store,
      root: start,
      completion: end,
      serverId: 'server',
      chargeId: 'charge',
      amountMinor: 2917,
    );
    final state = (await c.restoreCompletedSession(
      accountId: 'a',
      wellId: 'well-1',
      serverSessionId: 'server',
    ))!;
    await c.rememberSessionPaymentRead(
      accountId: 'a',
      wellId: 'well-1',
      revision: state.revision,
      detail: await data(read: true, correct: true),
    );
    final cached = (await c.restoreCompletedSession(
      accountId: 'a',
      wellId: 'well-1',
      serverSessionId: 'server',
    ))!;
    expect(cached.cachedDetail!.canCorrectSession, isTrue);
    return c;
  }

  Widget screen(OperationsRepository repo, {_CorrectionEventCoordinator? c}) =>
      MaterialApp(
        home: SessionDetailScreen(
          sessionId: 'server',
          wellName: 'بئر',
          repository: repo,
          coordinator: c,
          accountId: c == null ? null : 'a',
          wellId: c == null ? null : 'well-1',
        ),
      );

  testWidgets(
    'live canonical true exposes secondary correction after summary before timeline',
    (tester) async {
      viewport(tester);
      await tester.pumpWidget(
        screen(
          const _FakeOperationsRepository(canRead: true, canCorrect: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(action),
        findsOneWidget,
        reason: 'live canonical detail with canCorrectSession=true must expose correction',
      );
      final secondary = find.ancestor(
        of: find.text(action),
        matching: find.byWidgetPredicate(
          (w) => w is OutlinedButton || w is TextButton,
        ),
      );
      expect(secondary, findsOneWidget);
      // Widget traversal order, not absolute pixel coordinates.
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .toList();
      expect(
        texts.indexOf('محمد علي الحبيشي'),
        lessThan(texts.indexOf(action)),
      );
      expect(
        texts.indexOf(action),
        lessThan(texts.indexOf('الخط الزمني وتغيرات الطاقة')),
      );
    },
  );

  testWidgets('live correction action is enabled for opening the form', (
    tester,
  ) async {
    viewport(tester);
    await tester.pumpWidget(
      screen(const _FakeOperationsRepository(canRead: true, canCorrect: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text(action), findsOneWidget);
    final button = find.ancestor(
      of: find.text(action),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    );
    expect(button, findsOneWidget);
    expect(
      tester.widget<ButtonStyleButton>(button).onPressed,
      isNotNull,
      reason: 'Expected correction action to be enabled',
    );
  });

  testWidgets(
    'tap opens full-screen correction shell with effective snapshot and empty reason',
    (tester) async {
      viewport(tester);
      final repo = _CorrectionReadRepository();
      final snapshot = SessionDetailData(
        canReadSessionCorrections: true,
        canCorrectSession: true,
        session: SessionHistoryItem(
          id: 'server',
          wellId: 'well-1',
          farmerName: 'مزارع',
          farmerCode: 'F1',
          farmerAccountId: 'acc-1',
          farmName: 'أرض',
          pumpName: 'مضخة',
          operatorName: 'مشغل',
          // Deliberately distinguish all three sources. The form must use only
          // explicit effective facts, never originals or legacy aliases.
          startedAt: DateTime(2026, 8, 31, 7),
          endedAt: DateTime(2026, 8, 31, 12),
          originalStartedAt: DateTime(2026, 8, 31, 8),
          originalEndedAt: DateTime(2026, 8, 31, 10),
          effectiveStartedAt: DateTime(2026, 8, 31, 9),
          effectiveEndedAt: DateTime(2026, 8, 31, 11),
          operationalRevision: 3,
          financialStatus: 'pending',
          financialAppliedRevision: 0,
        ),
        segments: const [],
      );
      repo.response.complete(snapshot);
      await tester.pumpWidget(screen(repo));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(action));
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      final title = find.descendant(
        of: find.byType(AppBar),
        matching: find.text(action),
      );
      expect(
        title,
        findsOneWidget,
        reason: 'Expected to find correction form screen after tap',
      );
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        Navigator.of(tester.element(title)).canPop(),
        isTrue,
        reason: 'correction must open a separate full-screen route',
      );

      final start = find.byKey(const ValueKey('session_correction_start'));
      final end = find.byKey(const ValueKey('session_correction_end'));
      final reason = find.byKey(const ValueKey('session_correction_reason'));
      for (final field in [start, end, reason]) {
        expect(field, findsOneWidget);
      }
      for (final label in [
        'البداية الفعلية',
        'النهاية الفعلية',
        'سبب التصحيح',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      // Time inputs may be read-only picker fields. Inspect their displayed
      // text without depending on pixel positions or the correction screen type.
      String inputText(Finder field) {
        final editable = find.descendant(
          of: field,
          matching: find.byType(EditableText),
        );
        expect(editable, findsOneWidget);
        return tester.widget<EditableText>(editable).controller.text;
      }

      final initialStart = inputText(start);
      final initialEnd = inputText(end);
      expect(initialStart, contains('09:00'));
      expect(initialEnd, contains('11:00'));
      expect(initialStart, isNot(contains('08:00')));
      expect(initialStart, isNot(contains('07:00')));
      expect(initialEnd, isNot(contains('10:00')));
      expect(initialEnd, isNot(contains('12:00')));
      expect(inputText(reason), isEmpty);

      // No read on navigation: the opened form retains the supplied snapshot.
      // BASE_REVISION_VALIDATION_DEFERRED_TO_DRAFT_CONTRACT_RED: revision is
      // deliberately not exposed through a technical UI or private route API.
      expect(repo.reads, 1);
      repo.response = Completer<SessionDetailData>();
      await tester.pump();
      expect(inputText(start), initialStart);
      expect(inputText(end), initialEnd);
      expect(inputText(reason), isEmpty);
      expect(repo.reads, 1);
    },
  );

  for (final read in [true, false]) {
    testWidgets('live read=$read correct=false hides correction', (
      tester,
    ) async {
      viewport(tester);
      await tester.pumpWidget(
        screen(_FakeOperationsRepository(canRead: read, canCorrect: false)),
      );
      await tester.pumpAndSettle();
      expect(find.text('محمد علي الحبيشي'), findsOneWidget);
      expect(find.text(action), findsNothing);
    });
  }

  for (final result in ['true', 'false', 'failure']) {
    testWidgets('cached true cannot authorize before canonical $result', (
      tester,
    ) async {
      viewport(tester);
      final c = await cachedCoordinator();
      final repo = _CorrectionReadRepository();
      await tester.pumpWidget(screen(repo, c: c));
      await tester.pump();
      await tester.pump();
      expect(repo.reads, greaterThan(0));
      expect(find.text('قراءة محفوظة على الجهاز'), findsOneWidget);
      expect(
        find.text(action),
        findsNothing,
        reason:
            'cached true is historical only while canonical read is pending',
      );
      if (result == 'failure') {
        repo.response.completeError(StateError('network unavailable'));
      } else {
        repo.response.complete(
          await data(read: true, correct: result == 'true'),
        );
      }
      await tester.pumpAndSettle();
      if (result != 'failure') {
        expect(find.text('قراءة محفوظة على الجهاز'), findsNothing);
        expect(find.text('محمد علي الحبيشي'), findsOneWidget);
      }
      c.dispose();
      expect(
        find.text(action),
        result == 'true' ? findsOneWidget : findsNothing,
        reason: 'only successful live canonical true authorizes correction',
      );
    });
  }

  testWidgets(
    'new canonical refresh revokes previously live correction capability',
    (tester) async {
      viewport(tester);
      final c = await cachedCoordinator();
      final repo = _CorrectionReadRepository();
      repo.response.complete(await data(read: true, correct: true));
      await tester.pumpWidget(screen(repo, c: c));
      await tester.pumpAndSettle();
      // Continue through revocation even in RED; assert the initial state last.
      final initiallyVisible = find.text(action).evaluate().length;
      final readsBefore = repo.reads;
      repo.response = Completer<SessionDetailData>();
      final state = (await c.restoreCompletedSession(
        accountId: 'a',
        wellId: 'well-1',
        serverSessionId: 'server',
      ))!;
      // Existing completion notification refreshes canonical detail in-place.
      c.events.add(state.record);
      await tester.pump();
      await tester.pump();
      expect(repo.reads, greaterThan(readsBefore));
      repo.response.complete(await data(read: true, correct: false));
      await tester.pumpAndSettle();
      expect(find.text(action), findsNothing);
      c.dispose();
      expect(
        initiallyVisible,
        1,
        reason: 'initial live true must expose correction before revocation',
      );
    },
  );
}

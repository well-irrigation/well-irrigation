import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/features/history/session_detail_screen.dart';

class _LayoutRepository extends OperationsRepository {
  const _LayoutRepository({
    this.multipleSegments = false,
    this.longNames = false,
    this.acceptedPartial = false,
  });
  final bool multipleSegments;
  final bool longNames;
  final bool acceptedPartial;

  @override
  Future<SessionDetailData> fetchSessionDetail(String sessionId) async {
    final start = DateTime(2026, 10, 14, 9);
    return SessionDetailData(
      session: SessionHistoryItem(
        id: sessionId,
        wellId: 'well-1',
        farmerName: longNames
            ? 'محمد علي أحمد الحبيشي صاحب المزرعة الشرقية'
            : 'محمد علي الحبيشي',
        farmerCode: 'F-001',
        farmerAccountId: 'acc-1',
        farmName: 'مزرعة الوادي الشرقية',
        pumpName: 'المضخة الرئيسية 1',
        operatorName: 'خالد النجحي',
        startedAt: start,
        endedAt: start.add(const Duration(minutes: 10)),
        energySourceCode: 'solar',
        actualSeconds: 600,
        billableSeconds: 600,
        totalAmountYER: 86,
        paidAmountYER: acceptedPartial ? 20 : 0,
        paymentStatus: acceptedPartial ? 'partial' : 'unpaid',
        hasCharge: true,
        hasInvoice: false,
      ),
      segments: [
        SessionSegmentItem(
          sequenceNumber: 1,
          segmentType: 'solar_run',
          isStop: false,
          isBillable: true,
          energySourceCode: 'solar',
          startedAt: start,
          actualSeconds: 600,
          billableSeconds: 600,
          appliedRateYER: 516,
          timeChargeYER: 86,
          totalChargeYER: 86,
        ),
        if (multipleSegments)
          SessionSegmentItem(
            sequenceNumber: 2,
            segmentType: 'operator_pause',
            isStop: true,
            isBillable: false,
            startedAt: start.add(const Duration(minutes: 10)),
            actualSeconds: 60,
          ),
      ],
      crops: const ['قات', 'قمح'],
      paymentMethod: acceptedPartial ? 'cash' : null,
      paidAt: acceptedPartial ? DateTime.utc(2026, 10, 14, 14, 0, 41) : null,
    );
  }
}

void main() {
  setUpAll(() async {
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      await (FontLoader('NotoSansArabic')..addFont(
            rootBundle.load('assets/fonts/NotoSansArabic-$weight.ttf'),
          ))
          .load();
    }
  });

  Future<void> showDetail(
    WidgetTester tester, {
    double scale = 1,
    Size size = const Size(360, 800),
    bool multiple = false,
    bool longNames = false,
    bool acceptedPartial = false,
  }) async {
    // المحاكي: 720×1600 عند 320dpi؛ شريطان 56 و48 بكسل.
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = size * 2;
    tester.view.padding = const FakeViewPadding(top: 56, bottom: 48);
    addTearDown(tester.view.reset);
    final store = InMemoryOutboxStore();
    final coordinator = OfflineSessionCoordinator(store: store);
    final at = DateTime.utc(2026, 10, 14);
    final start = await coordinator.startSession(
      accountId: 'account',
      wellId: 'well-1',
      pumpId: 'p',
      farmId: 'f',
      farmerAccountId: 'acc-1',
      energySource: 'solar',
      startedAt: at,
    );
    final end = await coordinator.completeSession(
      accountId: 'account',
      sessionLocalId: start.localId,
      completedAt: at.add(const Duration(minutes: 10)),
    );
    await store.putMapping(
      'account',
      IdMapping(
        localId: start.localId,
        kind: EntityKind.session,
        serverId: '4fbe90-session',
        resolvedAt: at,
      ),
    );
    await store.markConfirmed(
      'account',
      end.localId,
      serverResponse: {'session_charge_id': 'charge', 'amount_minor': 86},
      attemptedAt: at,
    );
    if (acceptedPartial) {
      final payment = await coordinator.recordPayment(
        accountId: 'account',
        wellId: 'well-1',
        farmerAccountId: 'acc-1',
        amountMinor: 20,
        paymentMethod: 'cash',
        sessionLocalId: start.localId,
        sessionCompletionLocalId: end.localId,
      );
      await store.putMapping(
        'account',
        IdMapping(
          localId: payment.localId,
          kind: EntityKind.payment,
          serverId: 'payment-server',
          resolvedAt: at,
        ),
      );
      await store.markConfirmed(
        'account',
        payment.localId,
        serverResponse: {
          'payment_id': 'payment-server',
          'settled_minor': 20,
          'receipt': {'public_code': 'PAY-26-FA378'},
        },
        attemptedAt: at,
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('ar')],
        theme: ThemeData(useMaterial3: true, fontFamily: 'NotoSansArabic'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: SessionDetailScreen(
          sessionId: '4fbe90-session',
          coordinator: coordinator,
          accountId: 'account',
          wellId: 'well-1',
          wellName: 'بئر الخير الرئيسي',
          repository: _LayoutRepository(
            multipleSegments: multiple,
            longNames: longNames,
            acceptedPartial: acceptedPartial,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    coordinator.dispose();
  }

  testWidgets(
    'default emulator shows all facts and actions without scrolling',
    (tester) async {
      await showDetail(tester);
      expect(tester.takeException(), isNull);
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scroll.position.maxScrollExtent, 0);
      expect(find.text('#4fbe90'), findsOneWidget);
      expect(
        tester
            .renderObject<RenderParagraph>(find.text('#4fbe90'))
            .textDirection,
        TextDirection.ltr,
      );
      expect(find.textContaining('(Timeline)'), findsNothing);
      expect(find.text('الخط الزمني وتغيرات الطاقة'), findsOneWidget);
      expect(find.byTooltip('مشاركة الملخص'), findsNothing);
      expect(find.byTooltip('عرض ملخص الجلسة'), findsNothing);
      expect(find.text('مشاركة الملخص'), findsOneWidget);
      expect(find.text('عرض ملخص الجلسة'), findsOneWidget);
      final summary = find.widgetWithText(ElevatedButton, 'عرض ملخص الجلسة');
      expect(
        tester
            .widget<Icon>(
              find.descendant(of: summary, matching: find.byType(Icon)),
            )
            .icon,
        Icons.article_outlined,
      );

      for (final text in [
        'محمد علي الحبيشي',
        'المضخة الرئيسية 1',
        'خالد النجحي',
        'تكلفة الجلسة',
        '86 ريال',
        'ستة وثمانون ريالًا فقط',
        'المستحق',
        'المدفوع',
        'المتبقي',
        'لا توجد فاتورة مسجلة',
        'آجل / غير مدفوع 🔴',
        'تشغيل عبر طاقة شمسية',
        '9:00:00 ص',
        'التسعيرة المثبتة: 516 ر/س',
        'مشاركة الملخص',
        'عرض ملخص الجلسة',
        'تسجيل دفعة',
      ]) {
        final finder = find.text(text);
        expect(finder, findsWidgets, reason: text);
        expect(
          tester.getRect(finder.first).top,
          greaterThanOrEqualTo(28),
          reason: text,
        );
        expect(
          tester.getRect(finder.first).bottom,
          lessThanOrEqualTo(776),
          reason: text,
        );
      }
      final words = find.text('ستة وثمانون ريالًا فقط');
      final amount = find.text('86 ريال').first;
      expect(
        tester.getRect(words).top,
        greaterThanOrEqualTo(tester.getRect(amount).bottom),
      );
      expect(
        tester.getRect(words).top - tester.getRect(amount).bottom,
        lessThan(8),
      );
      expect(
        tester
            .renderObject<RenderParagraph>(words)
            .getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 20),
            ),
        hasLength(1),
      );
      for (final button in [
        find.byType(OutlinedButton),
        find.byType(ElevatedButton),
        find.byType(FilledButton),
      ]) {
        expect(button.hitTestable(), findsOneWidget);
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      }
      await tester.tap(find.text('عرض ملخص الجلسة'));
      await tester.pumpAndSettle();
      expect(find.textContaining('ليس فاتورة أو سند قبض'), findsOneWidget);
      expect(find.textContaining('INV-'), findsNothing);
      expect(find.text('الطباعة غير متاحة حاليًا'), findsOneWidget);
      await tester.tap(find.text('الطباعة غير متاحة حاليًا'));
      await tester.pumpAndSettle();
      expect(find.textContaining('تم إرسال أمر الطباعة'), findsNothing);
    },
  );

  testWidgets(
    'accepted partial receipt stays readable with all default actions and no scroll',
    (tester) async {
      await showDetail(tester, acceptedPartial: true);
      expect(tester.takeException(), isNull);
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .maxScrollExtent,
        0,
      );
      expect(find.text('طريقة السداد: نقدًا'), findsOneWidget);
      expect(find.textContaining('2026-10-14T'), findsNothing);
      for (final text in [
        'تسجيل دفعة',
        'عرض ملخص الجلسة',
        'مشاركة الملخص',
        'ستة وثمانون ريالًا فقط',
        'لا توجد فاتورة مسجلة',
        'سند قبض: PAY-26-FA378',
      ]) {
        expect(find.text(text), findsOneWidget);
        expect(tester.getRect(find.text(text)).bottom, lessThanOrEqualTo(776));
      }
    },
  );

  for (final scale in [1.3, 2.0]) {
    testWidgets('text scale $scale preserves facts with safe fallback scroll', (
      tester,
    ) async {
      await showDetail(tester, scale: scale, multiple: true, longNames: true);
      expect(tester.takeException(), isNull);
      final header = tester.getRect(find.byType(AppBar));
      expect(
        tester.getRect(find.text('بئر الخير الرئيسي')).bottom,
        lessThanOrEqualTo(header.bottom),
      );
      for (final paragraph in tester.renderObjectList<RenderParagraph>(
        find.byType(RichText),
      )) {
        expect(paragraph.didExceedMaxLines, isFalse);
      }
      for (final text in [
        'ستة وثمانون ريالًا فقط',
        'إيقاف من المشغل',
        'لا توجد فاتورة مسجلة',
        'عرض ملخص الجلسة',
      ]) {
        await tester.ensureVisible(find.text(text));
        await tester.pumpAndSettle();
        expect(find.text(text).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('small viewport allows scrolling to bottom actions', (
    tester,
  ) async {
    await showDetail(tester, size: const Size(320, 568));
    await tester.ensureVisible(find.text('عرض ملخص الجلسة'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('عرض ملخص الجلسة').hitTestable(), findsOneWidget);
  });
}

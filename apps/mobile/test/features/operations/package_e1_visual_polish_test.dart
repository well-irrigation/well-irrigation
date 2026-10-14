import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/session/session_segment.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/payment_receipt_dialog.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/session_completion_result.dart';

ActiveSessionRecord _record({bool accepted = false}) {
  final start = DateTime.utc(2026, 10, 14, 14);
  final end = start.add(const Duration(minutes: 10));
  final segments = [
    SessionSegment(
      kind: SegmentKind.running,
      startedAt: start,
      endedAt: end,
      energySource: 'solar',
      hourlyRateMinor: 516,
    ),
  ];
  return ActiveSessionRecord(
    localId: 'a',
    accountId: 'account',
    wellId: 'well',
    farmerName: 'محمد علي الحبيشي',
    farmName: 'مزرعة الوادي الشرقية',
    pumpName: 'المضخة الرئيسية 1',
    startedAt: start,
    completedAt: end,
    businessState: SessionBusinessState.completed,
    syncState: SessionSyncState.pending,
    segments: segments,
    totals: summarize(segments, end),
    payments: [
      LocalPayment(
        localId: 'p',
        amountMinor: 86,
        paidAt: end,
        status: accepted ? CommandStatus.confirmed : CommandStatus.pending,
        serverId: accepted ? 'server-p' : null,
        acceptedReceipt: accepted
            ? {
                'public_code': 'PAY-26-FA378',
                'amount_minor': 86,
                'method': 'cash',
                'paid_at': '2026-10-14T14:00:41.300364+00:00',
              }
            : null,
      ),
    ],
    timeIntegrityFlags: const {},
    pendingCommandCount: 1,
    approvedAmountMinor: 86,
  );
}

void main() {
  setUpAll(() async {
    final loader = FontLoader('NotoSansArabic');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      loader.addFont(
        rootBundle.load('assets/fonts/NotoSansArabic-$weight.ttf'),
      );
    }
    await loader.load();
  });
  Future<void> show(WidgetTester t, Widget child, {double scale = 1}) async {
    t.view.devicePixelRatio = 2;
    t.view.physicalSize = const Size(720, 1600);
    t.view.padding = const FakeViewPadding(top: 56, bottom: 48);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        key: ObjectKey(child),
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'NotoSansArabic',
          colorSchemeSeed: const Color(0xFF0265BA),
        ),
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          appBar: child is PaymentReceiptDialog
              ? null
              : AppBar(title: const Text('التشغيل')),
          body: SafeArea(
            child: child is PaymentReceiptDialog
                ? Builder(
                    builder: (context) => TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => child,
                      ),
                      child: const Text('فتح طلب دفعة'),
                    ),
                  )
                : child,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    if (child is PaymentReceiptDialog) {
      await t.tap(find.text('فتح طلب دفعة'));
      await t.pumpAndSettle();
    }
  }

  void noClipping(WidgetTester t) {
    expect(t.takeException(), isNull);
    for (final text in t.renderObjectList<RenderParagraph>(
      find.byType(RichText),
    )) {
      expect(text.didExceedMaxLines, isFalse, reason: text.text.toPlainText());
    }
  }

  test('E1 presentation wording stays local to display', () {
    for (final entry in {
      0: 'صفر ريال',
      1: 'ريال واحد',
      2: 'ريالان',
      3: 'ثلاثة ريالات',
      10: 'عشرة ريالات',
      11: 'أحد عشر ريالًا',
      86: 'ستة وثمانون ريالًا',
      100: 'مائة ريال',
      125: 'مائة وخمسة وعشرون ريالًا',
    }.entries) {
      expect(SessionCompletionResult.amountWords(entry.key), entry.value);
    }
  });
  for (final rate in <int?>[null, 3500]) {
    testWidgets(
      'payment dialog fits default viewport rate=$rate and saves same integer amount',
      (t) async {
        int? paid;
        String? method;
        await show(
          t,
          PaymentReceiptDialog(
            wellName: 'بئر الخير',
            operatorName: 'خالد النجحي',
            farmerName: 'محمد علي الحبيشي',
            farmName: 'مزرعة الوادي الشرقية',
            energySource: 'طاقة شمسية',
            hourlyRateYER: rate,
            billableSeconds: 600,
            actualSeconds: 600,
            totalAmountYER: 86,
            amountApproved: true,
            onConfirmPayment:
                ({
                  required paidAmountYER,
                  required paymentMethod,
                  required isFullySettled,
                }) async {
                  paid = paidAmountYER;
                  method = paymentMethod;
                },
          ),
        );
        noClipping(t);
        expect(
          t
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .maxScrollExtent,
          0,
        );
        for (final text in [
          'مبلغ الدفعة',
          'ستة وثمانون ريالًا',
          'طريقة الدفع',
          'طلب دفعة مطابق للمبلغ المعروض — لم يُعتمد بعد',
          'طلب دفعة — لا يثبت السداد قبل قبول الخادم',
          'حفظ طلب الدفعة',
        ]) {
          final f = find.text(text);
          expect(f, findsWidgets, reason: text);
          expect(
            t.getRect(f.first).top,
            greaterThanOrEqualTo(28),
            reason: text,
          );
          expect(
            t.getRect(f.first).bottom,
            lessThanOrEqualTo(776),
            reason: text,
          );
        }
        expect(find.textContaining('المبلغ المدفوع الآن'), findsNothing);
        expect(find.textContaining('نقدًا'), findsWidgets);
        expect(
          t.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
          '86',
        );
        await t.tap(find.text('حفظ طلب الدفعة'));
        await t.pumpAndSettle();
        expect(paid, 86);
        expect(method, 'cash');
      },
    );
  }
  testWidgets(
    'edited payment preserves the submitted integer and formats the displayed difference only',
    (t) async {
      int? submitted;
      await show(
        t,
        PaymentReceiptDialog(
          wellName: 'بئر',
          operatorName: 'مشغل',
          farmerName: 'مزارع',
          farmName: 'أرض',
          energySource: 'طاقة شمسية',
          hourlyRateYER: null,
          billableSeconds: 600,
          totalAmountYER: 86,
          onConfirmPayment:
              ({
                required paidAmountYER,
                required paymentMethod,
                required isFullySettled,
              }) async {
                submitted = paidAmountYER;
              },
        ),
      );
      await t.enterText(find.byType(TextFormField), '20');
      await t.pumpAndSettle();
      expect(find.text('ستة وستون ريالًا'), findsOneWidget);
      expect(
        find.text('طلب دفعة — لا يثبت السداد قبل قبول الخادم'),
        findsOneWidget,
      );
      expect(
        t.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
        '20',
      );
      expect(
        t
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .maxScrollExtent,
        0,
      );
      await t.tap(find.text('حفظ طلب الدفعة'));
      await t.pumpAndSettle();
      expect(submitted, 20);
    },
  );
  for (final accepted in [false, true]) {
    testWidgets(
      'completion card fits all facts and keeps non-modal actions; accepted=$accepted',
      (t) async {
        var later = 0;
        var payment = 0;
        var details = 0;
        await show(
          t,
          SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: SessionCompletionResult(
              record: _record(accepted: accepted),
              onLater: () => later++,
              onPayment: () => payment++,
              onDetails: () => details++,
            ),
          ),
        );
        noClipping(t);
        expect(
          t
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .maxScrollExtent,
          0,
        );
        for (final text in [
          'انتهت الجلسة',
          'المبلغ المعتمد',
          'تسجيل دفعة',
          'عرض التفاصيل',
          'لاحقًا',
        ]) {
          expect(find.text(text).hitTestable(), findsOneWidget);
        }
        for (final fact in [
          'محمد علي الحبيشي',
          'مزرعة الوادي الشرقية',
          'المضخة الرئيسية 1',
          'طاقة شمسية',
          'البداية',
          'النهاية',
          'مدة التنفيذ الفعلية',
          'ستة وثمانون ريالًا فقط',
        ]) {
          expect(find.textContaining(fact), findsWidgets);
        }
        expect(find.byType(Dialog), findsNothing);
        expect(find.textContaining('INV-'), findsNothing);
        if (accepted) {
          expect(find.textContaining('PAY-26-FA378'), findsOneWidget);
          expect(find.text('طريقة الدفع: نقدًا'), findsOneWidget);
          expect(find.textContaining('2026-10-14T'), findsNothing);
          expect(find.textContaining('وقت الدفعة:'), findsOneWidget);
        } else {
          expect(find.text('دفعة معلقة — بانتظار المزامنة'), findsOneWidget);
          expect(find.textContaining('PAY-'), findsNothing);
        }
        await t.tap(find.text('تسجيل دفعة'));
        await t.tap(find.text('عرض التفاصيل'));
        await t.tap(find.text('لاحقًا'));
        expect(payment, 1);
        expect(details, 1);
        expect(later, 1);
      },
    );
  }
  for (final scale in [1.3, 2.0]) {
    testWidgets(
      'dialog and completion allow accessible scroll at scale=$scale',
      (t) async {
        await show(
          t,
          PaymentReceiptDialog(
            wellName: 'بئر',
            operatorName: 'مشغل',
            farmerName: 'محمد علي الحبيشي',
            farmName: 'مزرعة الوادي الشرقية',
            energySource: 'طاقة شمسية',
            hourlyRateYER: 3500,
            billableSeconds: 600,
            actualSeconds: 600,
            totalAmountYER: 86,
            onConfirmPayment: ({
              required paidAmountYER,
              required paymentMethod,
              required isFullySettled,
            }) async {},
          ),
          scale: scale,
        );
        await t.ensureVisible(find.text('حفظ طلب الدفعة'));
        await t.pumpAndSettle();
        noClipping(t);
        expect(find.text('حفظ طلب الدفعة').hitTestable(), findsOneWidget);
        await show(
          t,
          SingleChildScrollView(
            child: SessionCompletionResult(
              record: _record(accepted: true),
              onLater: () {},
              onDetails: () {},
            ),
          ),
          scale: scale,
        );
        await t.ensureVisible(find.text('لاحقًا'));
        await t.pumpAndSettle();
        noClipping(t);
        expect(find.text('لاحقًا').hitTestable(), findsOneWidget);
      },
    );
  }
}

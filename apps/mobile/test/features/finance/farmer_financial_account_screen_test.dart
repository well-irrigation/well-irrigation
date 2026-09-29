import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/finance_repository.dart';
import 'package:well_irrigation_mobile/features/finance/farmer_financial_account_screen.dart';

/// مستودع مزيَّف يعيد غلاف api.get_farmer_account كما هو: الهوية والدين
/// والرصيد المقدم داخل account، والفواتير والسندات مرتبة من الأحدث. الاسم
/// والرمز والهاتف كلها بيانات ثابتة داخل الفحص فقط — المستودع نفسه لم يبق
/// فيه اسم ولا رصيد مقدَّم مثبَّت.
class _FakeFinanceRepository extends FinanceRepository {
  @override
  Future<FarmerFinancialAccountData> fetchFarmerFinancialAccount(
    String wellId,
    String farmerAccountId, {
    int limit = 50,
  }) async {
    return FarmerFinancialAccountData.fromContract({
      'contract': 'get_farmer_account',
      'version': 1,
      'account': {
        'id': farmerAccountId,
        'well_id': wellId,
        'public_code': 'FRM-001',
        'full_name': 'ناصر سعيد الوصابي',
        'phone': '772334455',
        'status': 'active',
        'credit_limit_minor': 500000,
        'invoiced_minor': 260000,
        'allocated_minor': 110000,
        'total_debt_minor': 150000,
        'advance_balance_minor': 20000,
      },
      'invoices': [
        {
          'id': 'invoice-1',
          'invoice_number': 'INV-002',
          'issue_date': '2026-08-28',
          'due_date': '2026-09-11',
          'session_id': 'session-2',
          'farm_name': 'قطعة الشمال',
          'original_amount_minor': 180000,
          'paid_amount_minor': 30000,
          'outstanding_minor': 150000,
          'settlement_method': 'cash',
          'status': 'partial',
        },
        {
          'id': 'invoice-2',
          'invoice_number': 'INV-001',
          'issue_date': '2026-08-14',
          'due_date': '2026-08-28',
          'session_id': 'session-1',
          'farm_name': 'قطعة الجنوب',
          'original_amount_minor': 80000,
          'paid_amount_minor': 80000,
          'outstanding_minor': 0,
          'settlement_method': 'cash',
          'status': 'paid',
        },
        {
          'id': 'invoice-3',
          'invoice_number': 'INV-003',
          'issue_date': '2026-09-01',
          'due_date': '2026-09-15',
          'session_id': 'session-3',
          'farm_name': 'قطعة الشرق',
          'original_amount_minor': 60000,
          'paid_amount_minor': 0,
          'outstanding_minor': 60000,
          'settlement_method': 'cash',
          'status': 'unpaid',
        },
      ],
      'payments': [
        {
          'id': 'payment-1',
          'receipt_number': 'PAY-001',
          'paid_at': '2026-08-29T10:00:00Z',
          'amount_minor': 110000,
          'method': 'cash',
          'purpose': 'invoice',
          'status': 'posted',
          'note': null,
          'allocated_invoices': ['INV-001', 'INV-002'],
        },
      ],
    });
  }
}

void main() {
  /// اختيار فاتورة داخل نافذة التسديد مع تمريرها للمرئي. [bounded]
  /// يمنع pumpAndSettle حين يبقى نداء الاقتراح معلّقًا على بوابة.
  Future<void> selectInvoice(
    WidgetTester tester,
    String invoiceNumber, {
    bool bounded = false,
  }) async {
    final finder = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(invoiceNumber),
    );
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    if (bounded) {
      await tester.pump();
    } else {
      await tester.pumpAndSettle();
    }
  }

  group(
    'FarmerFinancialAccountScreen Tests (UX-14 / 408–424 / No Silent Netting)',
    () {
      testWidgets('1. عرض فصل الديون عن الرصيد المقدم وتطبيق مبدأ ق-99', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: FarmerFinancialAccountScreen(
              wellId: 'well-1',
              farmerAccountId: 'farmer-account-1',
              wellName: 'بئر الخير الرئيسي',
              repository: _FakeFinanceRepository(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('الحساب المالي: ناصر سعيد الوصابي'), findsOneWidget);
        expect(find.text('إجمالي الديون المستحقة'), findsOneWidget);
        expect(find.text('الرصيد المقدم بحسابه'), findsOneWidget);
        expect(find.textContaining('مبدأ ق-99'), findsOneWidget);
        expect(find.textContaining('الفواتير المستحقة'), findsOneWidget);
        expect(find.textContaining('سجل سندات القبض'), findsOneWidget);
        expect(find.text('تسجيل دفعة / سند قبض'), findsOneWidget);
        expect(find.text('استخدام الرصيد المقدم'), findsOneWidget);
      });

      testWidgets('2. فتح حوار تسجيل دفعة وسند قبض جديد', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: FarmerFinancialAccountScreen(
              wellId: 'well-1',
              farmerAccountId: 'farmer-account-1',
              wellName: 'بئر الخير الرئيسي',
              repository: _FakeFinanceRepository(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // الضغط على زر تسجيل دفعة
        await tester.tap(find.text('تسجيل دفعة / سند قبض'));
        await tester.pumpAndSettle();

        expect(find.text('تسجيل دفعة وسند قبض'), findsOneWidget);
        expect(find.text('المبلغ المدفوع (ريال يمني) *'), findsOneWidget);
        expect(find.text('طريقة الدفع *'), findsOneWidget);
        expect(find.text('إصدار سند القبض'), findsOneWidget);
      });

      testWidgets(
        '3. النافذة تعرض السندات ولا تطلب اقتراحًا قبل اكتمال الاختيار',
        (tester) async {
          final spy = _WriteSpyFinanceRepository();

          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('ar'),
              home: FarmerFinancialAccountScreen(
                wellId: 'well-1',
                farmerAccountId: 'farmer-account-1',
                wellName: 'بئر الخير الرئيسي',
                repository: spy,
              ),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.text('استخدام الرصيد المقدم'));
          await tester.pumpAndSettle();

          // السندات من العقد بمتبقّي كل واحد، والمستنفَد لا يُعرض للاختيار.
          expect(find.text('تسديد من الرصيد المقدم'), findsOneWidget);
          expect(find.text('PAY-ADV-1'), findsOneWidget);
          expect(
            find.textContaining('المتبقي في السند: 40,000 ريال'),
            findsOneWidget,
          );
          expect(find.text('PAY-ADV-SPENT'), findsNothing);

          // اختيار السند وحده لا يطلب اقتراحًا ولا يرسل أي تخصيص.
          await tester.tap(find.text('PAY-ADV-1'));
          await tester.pumpAndSettle();

          expect(spy.proposalCalls, 0);
          expect(spy.allocateCalls, 0);
          expect(find.textContaining('المقترح تطبيقه'), findsNothing);
        },
      );

      testWidgets(
        '4. بعد اكتمال الاختيارَين: اقتراح الخادم يُعرض والمبلغ يُعبَّأ منه لا من حساب محلي',
        (tester) async {
          final spy = _WriteSpyFinanceRepository();

          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('ar'),
              home: FarmerFinancialAccountScreen(
                wellId: 'well-1',
                farmerAccountId: 'farmer-account-1',
                wellName: 'بئر الخير الرئيسي',
                repository: spy,
              ),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.text('استخدام الرصيد المقدم'));
          await tester.pumpAndSettle();

          await tester.tap(find.text('PAY-ADV-1'));
          await tester.pumpAndSettle();
          await selectInvoice(tester, 'INV-002');

          // الاقتراح من الخادم يُعرض بسطوره الصريحة والمبلغ مُعبَّأ منه.
          // (السطر الأوسط يُقاس داخل صندوق الاقتراح وحده لأن بلاطة
          // الفاتورة تحمل الوصفة نفسها.)
          final summary = find.byKey(const ValueKey('advanceProposalSummary'));
          expect(spy.proposalCalls, 1);
          expect(spy.requestedPairs, ['pay-adv-1|invoice-1']);
          expect(
            find.descendant(
              of: summary,
              matching: find.textContaining(
                'المتاح من الرصيد المقدم: 40,000 ريال',
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: summary,
              matching: find.textContaining(
                'المتبقي على الفاتورة: 150,000 ريال',
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: summary,
              matching: find.textContaining('المقترح تطبيقه: 40,000 ريال'),
            ),
            findsOneWidget,
          );
          expect(find.text('40,000'), findsOneWidget);
          expect(spy.allocateCalls, 0);
        },
      );

      testWidgets(
        '5. لا تخصيص إلا بزر التأكيد الصريح، والمُرسَل المعرّفان الحقيقيان والمبلغ المؤكَّد المعدَّل',
        (tester) async {
          final spy = _WriteSpyFinanceRepository();

          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('ar'),
              home: FarmerFinancialAccountScreen(
                wellId: 'well-1',
                farmerAccountId: 'farmer-account-1',
                wellName: 'بئر الخير الرئيسي',
                repository: spy,
              ),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.text('استخدام الرصيد المقدم'));
          await tester.pumpAndSettle();

          // قبل اكتمال الاقتراح زر التأكيد معطَّل: لا تخصيص بلا اقتراح.
          await tester.tap(find.text('PAY-ADV-1'));
          await tester.pumpAndSettle();
          await selectInvoice(tester, 'INV-002');

          // المبلغ المقترح قابل للتعديل قبل التأكيد.
          await tester.enterText(find.byType(TextFormField).last, '15000');
          await tester.tap(find.text('تأكيد التسديد من المقدم'));
          await tester.pumpAndSettle();

          expect(spy.allocateCalls, 1);
          expect(spy.lastPaymentId, 'pay-adv-1');
          expect(spy.lastAllocations, [
            {'invoice_id': 'invoice-1', 'amount_minor': 15000},
          ]);
        },
      );

      testWidgets('6. الإلغاء يغلق النافذة بصفر نداء تخصيص', (tester) async {
        final spy = _WriteSpyFinanceRepository();

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: FarmerFinancialAccountScreen(
              wellId: 'well-1',
              farmerAccountId: 'farmer-account-1',
              wellName: 'بئر الخير الرئيسي',
              repository: spy,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('استخدام الرصيد المقدم'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('PAY-ADV-1'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('INV-002'),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('إلغاء'));
        await tester.pumpAndSettle();

        expect(spy.allocateCalls, 0);
        expect(find.text('تسديد من الرصيد المقدم'), findsNothing);
      });

      testWidgets(
        '7. فشل حساب الاقتراح: رسالة صادقة بلا مبلغ مُلفَّق وبلا أي تخصيص',
        (tester) async {
          final spy = _WriteSpyFinanceRepository()
            ..proposalFailure = StateError('تعذر الاتصال');

          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('ar'),
              home: FarmerFinancialAccountScreen(
                wellId: 'well-1',
                farmerAccountId: 'farmer-account-1',
                wellName: 'بئر الخير الرئيسي',
                repository: spy,
              ),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.text('استخدام الرصيد المقدم'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('PAY-ADV-1'));
          await tester.pumpAndSettle();
          await selectInvoice(tester, 'INV-002');

          expect(
            find.textContaining(
              'تعذر حساب التسوية المقترحة — لم يُرسل أي تسديد',
            ),
            findsOneWidget,
          );
          expect(find.textContaining('المقترح تطبيقه'), findsNothing);
          expect(find.text('40,000'), findsNothing);

          // زر التأكيد معطَّل فعلًا: لا كتابة بلا اقتراح.
          final confirm = tester.widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'تأكيد التسديد من المقدم'),
          );
          expect(confirm.onPressed, isNull);
          expect(spy.allocateCalls, 0);
        },
      );

      testWidgets('8. مقترح صفر من الخادم: لا تأكيد ممكن بلا أي استهلاك صامت', (
        tester,
      ) async {
        final spy = _WriteSpyFinanceRepository()..defaultZeroProposal = true;

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: FarmerFinancialAccountScreen(
              wellId: 'well-1',
              farmerAccountId: 'farmer-account-1',
              wellName: 'بئر الخير الرئيسي',
              repository: spy,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('استخدام الرصيد المقدم'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('PAY-ADV-1'));
        await tester.pumpAndSettle();
        await selectInvoice(tester, 'INV-002');

        expect(find.textContaining('المقترح تطبيقه: 0 ريال'), findsOneWidget);
        final confirm = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'تأكيد التسديد من المقدم'),
        );
        expect(confirm.onPressed, isNull);
        expect(spy.allocateCalls, 0);
      });

      testWidgets(
        '9. تغيير الفاتورة يصفّر الاقتراح فورًا ويعرض اقتراح المزاوجة الجديدة',
        (tester) async {
          final spy = _WriteSpyFinanceRepository()
            ..proposals['pay-adv-1|invoice-3'] = _proposal(
              proposedMinor: 30000,
              outstandingMinor: 60000,
              invoiceId: 'invoice-3',
            );

          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('ar'),
              home: FarmerFinancialAccountScreen(
                wellId: 'well-1',
                farmerAccountId: 'farmer-account-1',
                wellName: 'بئر الخير الرئيسي',
                repository: spy,
              ),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.text('استخدام الرصيد المقدم'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('PAY-ADV-1'));
          await tester.pumpAndSettle();
          await selectInvoice(tester, 'INV-002');
          expect(
            find.textContaining('المقترح تطبيقه: 40,000 ريال'),
            findsOneWidget,
          );

          // التبديل: القديم يزول فورًا والجديد يُعرض من الرد الجديد.
          await selectInvoice(tester, 'INV-003');

          expect(
            find.textContaining('المقترح تطبيقه: 40,000 ريال'),
            findsNothing,
          );
          expect(
            find.textContaining('المقترح تطبيقه: 30,000 ريال'),
            findsOneWidget,
          );
          expect(spy.requestedPairs, [
            'pay-adv-1|invoice-1',
            'pay-adv-1|invoice-3',
          ]);
        },
      );

      testWidgets(
        '10. ردّ المزاوجة القديمة البطيء لا يُعرض فوق المزاوجة الأحدث',
        (tester) async {
          final gate = Completer<void>();
          final spy = _WriteSpyFinanceRepository()
            ..proposalGate = gate
            ..proposals['pay-adv-1|invoice-3'] = _proposal(
              proposedMinor: 30000,
              outstandingMinor: 60000,
              invoiceId: 'invoice-3',
            );

          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('ar'),
              home: FarmerFinancialAccountScreen(
                wellId: 'well-1',
                farmerAccountId: 'farmer-account-1',
                wellName: 'بئر الخير الرئيسي',
                repository: spy,
              ),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.text('استخدام الرصيد المقدم'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('PAY-ADV-1'));
          await tester.pumpAndSettle();
          await selectInvoice(tester, 'INV-002', bounded: true);
          expect(find.text('جارٍ حساب التسوية المقترحة...'), findsOneWidget);

          // التبديل أثناء تعليق الردّ الأول: الاقتراح القديم لا يُعرض.
          await selectInvoice(tester, 'INV-003', bounded: true);
          await tester.pump();

          gate.complete();
          await tester.pumpAndSettle();

          expect(
            find.textContaining('المقترح تطبيقه: 40,000 ريال'),
            findsNothing,
          );
          expect(
            find.textContaining('المقترح تطبيقه: 30,000 ريال'),
            findsOneWidget,
          );
          expect(spy.allocateCalls, 0);
        },
      );

      testWidgets('11. فشل عقد الحساب لا يُظهر هوية ولا رصيدًا مُلفَّقًا', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: FarmerFinancialAccountScreen(
              wellId: 'well-1',
              farmerAccountId: 'farmer-account-lost',
              wellName: 'بئر الخير الرئيسي',
              repository: _FailingFinanceRepository(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.text('لم يتم العثور على بيانات الحساب المالي'),
          findsOneWidget,
        );
        expect(
          find.textContaining('تعذر تحميل الحساب المالي للمزارع'),
          findsOneWidget,
        );

        // تصريف مؤقّت إخفاء التنبيه حتى لا يبقى Timer معلقًا بعد الفحص
        await tester.pumpAndSettle(const Duration(seconds: 5));
      });
    },
  );
}

/// مستودع يفشل كما يفشل العقد على حساب غير مرئي (42501).
class _FailingFinanceRepository extends FinanceRepository {
  @override
  Future<FarmerFinancialAccountData> fetchFarmerFinancialAccount(
    String wellId,
    String farmerAccountId, {
    int limit = 50,
  }) async {
    throw StateError('لا توجد صلاحية على حساب هذا المزارع');
  }
}

/// جاسوس كتابة واقتراح: يرصد نداء التخصيص ونداء الاقتراح معًا. الشاشة
/// لا يجوز أن تنادي العقد بمعرّف لم يعده عقد قراءة، ولا أن تُرسل تخصيصًا
/// بلا تأكيد صريح — والنداء نفسه لا نتيجته هو ما يُقاس (ق-99 / ق-131).
class _WriteSpyFinanceRepository extends _FakeFinanceRepository {
  int allocateCalls = 0;
  String? lastPaymentId;
  List<Map<String, dynamic>>? lastAllocations;

  int proposalCalls = 0;
  final List<String> requestedPairs = [];

  /// بوابة تُبطئ كل نداء اقتراح لإثبات الردّ القديم وحالة التحميل.
  Completer<void>? proposalGate;
  Object? proposalFailure;
  bool defaultZeroProposal = false;
  final Map<String, AdvanceAllocationProposal> proposals = {};

  @override
  Future<List<AdvanceReceipt>> fetchAdvanceReceipts(
    String farmerAccountId, {
    int limit = 50,
  }) async {
    return [
      AdvanceReceipt.fromJson(const {
        'payment_id': 'pay-adv-1',
        'public_code': 'PAY-ADV-1',
        'amount_minor': 50000,
        'allocated_minor': 10000,
        'remaining_minor': 40000,
        'is_exhausted': false,
      }),
      AdvanceReceipt.fromJson(const {
        'payment_id': 'pay-adv-spent',
        'public_code': 'PAY-ADV-SPENT',
        'amount_minor': 20000,
        'allocated_minor': 20000,
        'remaining_minor': 0,
        'is_exhausted': true,
      }),
    ];
  }

  @override
  Future<AdvanceAllocationProposal> fetchAdvanceAllocationProposal({
    required String paymentId,
    required String invoiceId,
  }) async {
    proposalCalls += 1;
    requestedPairs.add('$paymentId|$invoiceId');
    final gate = proposalGate;
    if (gate != null) await gate.future;
    final error = proposalFailure;
    if (error != null) throw error;
    final proposal = proposals['$paymentId|$invoiceId'];
    if (proposal != null) return proposal;
    return AdvanceAllocationProposal(
      paymentId: paymentId,
      invoiceId: invoiceId,
      farmerWellAccountId: 'farmer-account-1',
      wellId: 'well-1',
      advanceRemainingMinor: 40000,
      invoiceOutstandingMinor: 150000,
      proposedMinor: defaultZeroProposal ? 0 : 40000,
      canApply: !defaultZeroProposal,
    );
  }

  @override
  Future<void> allocateAdvance({
    required String paymentId,
    required List<Map<String, dynamic>> allocations,
  }) async {
    allocateCalls += 1;
    lastPaymentId = paymentId;
    lastAllocations = allocations;
  }
}

AdvanceAllocationProposal _proposal({
  required int proposedMinor,
  required int outstandingMinor,
  required String invoiceId,
}) => AdvanceAllocationProposal(
  paymentId: 'pay-adv-1',
  invoiceId: invoiceId,
  farmerWellAccountId: 'farmer-account-1',
  wellId: 'well-1',
  advanceRemainingMinor: 40000,
  invoiceOutstandingMinor: outstandingMinor,
  proposedMinor: proposedMinor,
  canApply: proposedMinor > 0,
);

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
  group('FarmerFinancialAccountScreen Tests (UX-14 / 408–424 / No Silent Netting)', () {
    testWidgets('1. عرض فصل الديون عن الرصيد المقدم وتطبيق مبدأ ق-99', (tester) async {
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

    testWidgets('3. نافذة الرصيد المقدم تعرض السندات ومتبقّي كل سند', (
      tester,
    ) async {
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
      expect(find.textContaining('المتبقي في السند: 40,000 ريال'), findsOneWidget);
      expect(find.text('PAY-ADV-SPENT'), findsNothing);
      expect(
        find.textContaining('المبلغ تكتبه بنفسك'),
        findsOneWidget,
      );
      expect(spy.allocateCalls, 0);
    });

    testWidgets('4. لا تسديد بلا اختيار، والمُرسَل معرّفٌ من العقد ومبلغ مكتوب', (
      tester,
    ) async {
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

      // ضغط التسديد بلا اختيار: لا نداء، ورسالة تقول ما ينقص.
      await tester.tap(find.text('تسديد'));
      await tester.pumpAndSettle();
      expect(spy.allocateCalls, 0);
      expect(find.textContaining('اختر سند الرصيد المقدم'), findsOneWidget);

      await tester.tap(find.text('PAY-ADV-1'));
      await tester.pumpAndSettle();
      // النصّ نفسه موجود في الشاشة تحت النافذة، فالنقر على نسخة النافذة.
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('INV-002'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).last, '15000');
      await tester.tap(find.text('تسديد'));
      await tester.pumpAndSettle();

      // معرّف السند جاء من العقد، والمبلغ هو ما كُتب — لا رقم مُشتقّ.
      expect(spy.allocateCalls, 1);
      expect(spy.lastPaymentId, 'pay-adv-1');
      expect(spy.lastAllocations, [
        {'invoice_id': 'invoice-1', 'amount_minor': 15000},
      ]);
    });

    testWidgets('5. فشل عقد الحساب لا يُظهر هوية ولا رصيدًا مُلفَّقًا', (tester) async {
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
      expect(find.text('لم يتم العثور على بيانات الحساب المالي'), findsOneWidget);
      expect(find.textContaining('تعذر تحميل الحساب المالي للمزارع'), findsOneWidget);

      // تصريف مؤقّت إخفاء التنبيه حتى لا يبقى Timer معلقًا بعد الفحص
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });
  });
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

/// جاسوس كتابة: يرصد أي نداء تخصيص. الشاشة لا يجوز أن تنادي العقد بمعرّف
/// لم يُعده عقد قراءة، فالنداء نفسه — لا نتيجته — هو العيب (ق-99 / م-41D5).
/// جاسوس يرصد **ما أُرسل** لا مجرّد أنه أُرسل: المعرّف والمبلغ كما وصلا.
class _WriteSpyFinanceRepository extends _FakeFinanceRepository {
  int allocateCalls = 0;
  String? lastPaymentId;
  List<Map<String, dynamic>>? lastAllocations;

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
  Future<void> allocateAdvance({
    required String paymentId,
    required List<Map<String, dynamic>> allocations,
  }) async {
    allocateCalls += 1;
    lastPaymentId = paymentId;
    lastAllocations = allocations;
  }
}

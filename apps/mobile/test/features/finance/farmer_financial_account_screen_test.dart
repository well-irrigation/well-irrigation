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

    testWidgets('3. فتح حوار استخدام الرصيد المقدم لتسديد أقدم الفواتير', (tester) async {
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

      // الضغط على زر استخدام الرصيد المقدم
      await tester.tap(find.text('استخدام الرصيد المقدم'));
      await tester.pumpAndSettle();

      expect(find.text('استخدام الرصيد المقدم'), findsWidgets);
      expect(find.text('الرصيد المقدم المتاح:'), findsOneWidget);
      expect(find.text('تأكيد التسديد من المقدم'), findsOneWidget);
    });

    testWidgets('4. فشل عقد الحساب لا يُظهر هوية ولا رصيدًا مُلفَّقًا', (tester) async {
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

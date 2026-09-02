import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/finance_repository.dart';
import 'package:well_irrigation_mobile/features/finance/profit_distribution_screen.dart';
import '../../support/identity_fixture.dart';

/// مستودع مزيَّف يعيد ما يعيده عقد api.list_well_profit_cycles: دورة واحدة
/// وأسطر شركائها داخل الغلاف نفسه بأسماء مفاتيح القاعدة. المتبقي في كل سطر
/// هو ما تعرّفه القاعدة في هجرة 068 — صافي المستحق ناقص المصروف فعلًا.
class _FakeFinanceRepository extends FinanceRepository {
  @override
  Future<List<ProfitDistributionCycleItem>> fetchProfitDistributionCycles(
    String wellId, {
    int limit = 24,
  }) async {
    return [
      ProfitDistributionCycleItem.fromJson({
        'id': 'cycle-1',
        'well_id': wellId,
        'public_code': 'PDC-001',
        'period_start': '2026-08-01T00:00:00Z',
        'period_end': '2026-09-01T00:00:00Z',
        'status': 'calculated',
        'eligible_revenue_minor': 900000,
        'eligible_expenses_minor': 300000,
        'retained_liabilities_minor': 50000,
        'maintenance_reserve_minor': 100000,
        'distributable_profit_minor': 450000,
        'calculated_at': '2026-09-01T08:00:00Z',
        'approved_at': null,
        'partner_lines': [
          {
            'line_id': 'line-1',
            'partner_id': 'partner-1',
            'partner_name': 'عبدالرحمن باجعفر',
            'profit_percent': 40,
            'gross_share_minor': 180000,
            'out_of_pocket_minor': 25000,
            'irrigation_deduction_minor': 35000,
            'other_deductions_minor': 0,
            'net_share_minor': 170000,
            'paid_amount_minor': 100000,
            'remaining_minor': 70000,
            'payout_status': 'partial',
          },
          {
            'line_id': 'line-2',
            'partner_id': 'partner-2',
            'partner_name': 'صالح مهدي العامري',
            'profit_percent': 35,
            'gross_share_minor': 157500,
            'out_of_pocket_minor': 0,
            'irrigation_deduction_minor': 12000,
            'other_deductions_minor': 0,
            'net_share_minor': 145500,
            'paid_amount_minor': 0,
            'remaining_minor': 145500,
            'payout_status': 'pending',
          },
        ],
      }),
    ];
  }
}

void main() {
  group('ProfitDistributionScreen Tests (UX-14 / 439–447)', () {
    testWidgets('1. عرض دورات توزيع الأرباح وتفكيك المعادلة المحاسبية المعتمدة', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: ProfitDistributionScreen(
            identity: testIdentity(),
            repository: _FakeFinanceRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('دورات وتوزيع الأرباح'), findsOneWidget);
      expect(find.text('صافي الأرباح القابلة للتوزيع:'), findsOneWidget);
      expect(find.text('تفكيك المعادلة المحاسبية المعتمدة:'), findsOneWidget);
      expect(find.text('المقبوضات المؤهلة (+):'), findsOneWidget);
      expect(find.text('المصروفات المؤهلة (-):'), findsOneWidget);
      expect(find.text('احتياطي الصيانة (-):'), findsOneWidget);
      expect(find.text('أنصبة الشركاء في هذه الدورة:'), findsOneWidget);
      expect(find.text('احتساب دورة أرباح جديدة'), findsOneWidget);
    });

    testWidgets('2. فتح نافذة احتساب دورة أرباح جديدة واختيار الفترة والاحتياطي', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: ProfitDistributionScreen(
            identity: testIdentity(),
            repository: _FakeFinanceRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // الضغط على زر احتساب دورة أرباح جديدة
      await tester.tap(find.text('احتساب دورة أرباح جديدة'));
      await tester.pumpAndSettle();

      expect(find.text('احتساب دورة توزيع الأرباح'), findsOneWidget);
      expect(find.text('الفترة المحاسبية المراد احتساب أرباحها:'), findsOneWidget);
      expect(find.text('احتياطي الصيانة المحتجز (ريال يمني)'), findsOneWidget);
      expect(find.text('احتساب وتجهيز الدورة'), findsOneWidget);
    });

    testWidgets('3. فشل العقد يوقف الدوران ويُظهر رسالة بلا دورات مُلفَّقة', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: ProfitDistributionScreen(
            identity: testIdentity(),
            repository: _FailingFinanceRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('لا توجد دورات توزيع أرباح سابقة'), findsOneWidget);
      expect(find.textContaining('تعذر تحميل دورات الأرباح'), findsOneWidget);

      // تصريف مؤقّت إخفاء التنبيه حتى لا يبقى Timer معلقًا بعد الفحص
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });
  });
}

/// مستودع يفشل كما يفشل العقد حين لا صلاحية (42501): الشاشة تُظهر الخطأ
/// ولا تعرض أرقامًا بديلة.
class _FailingFinanceRepository extends FinanceRepository {
  @override
  Future<List<ProfitDistributionCycleItem>> fetchProfitDistributionCycles(
    String wellId, {
    int limit = 24,
  }) async {
    throw StateError('لا توجد صلاحية على هذا البئر');
  }
}

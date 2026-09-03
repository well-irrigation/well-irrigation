import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/finance_repository.dart';
import 'package:well_irrigation_mobile/core/api/partner_repository.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';
import 'package:well_irrigation_mobile/features/finance/partner_overview_screen.dart';

import '../../support/identity_fixture.dart';

/// مستودعات مُتحكَّم بها: تفصل «ما أعاده العقد» عن «ما عُرض على الشاشة».
class _FakePartnerRepository extends PartnerRepository {
  _FakePartnerRepository({this.overview, this.farmers, this.failRead = false});

  final PartnerOverview? overview;
  final List<FarmerBalance>? farmers;
  final bool failRead;

  int reads = 0;

  @override
  Future<PartnerOverview> fetchOverview(String wellId) async {
    reads++;
    if (failRead) {
      throw StateError('partner contract unavailable');
    }
    return overview ??
        const PartnerOverview(
          wellId: 'well-095',
          isPartner: false,
          presence: ActiveSessionPresence(count: 0, hasActive: false),
          openPeriod: null,
        );
  }

  @override
  Future<List<FarmerBalance>> fetchFarmerBalances(String wellId) async {
    return farmers ?? const [];
  }
}

class _FakeFinanceRepository extends FinanceRepository {
  _FakeFinanceRepository({this.cycles, this.partners, this.expenses});

  final List<ProfitDistributionCycleItem>? cycles;
  final List<PartnerFinancialItem>? partners;
  final List<ExpenseItem>? expenses;

  @override
  Future<List<ProfitDistributionCycleItem>> fetchProfitDistributionCycles(
    String wellId, {
    int limit = 24,
  }) async => cycles ?? const [];

  @override
  Future<List<PartnerFinancialItem>> fetchPartners(
    String wellId, {
    int limit = 100,
  }) async => partners ?? const [];

  @override
  Future<List<ExpenseItem>> fetchExpenses(
    String wellId, {
    String? status,
    int limit = 100,
  }) async => expenses ?? const [];
}

class _FakeWellRepository extends WellManagementRepository {
  _FakeWellRepository({this.tanks});

  final List<FuelTankModel>? tanks;

  @override
  Future<List<FuelTankModel>> fetchFuelTanks(
    String wellId, {
    bool includeInactive = false,
  }) async => tanks ?? const [];
}

/// حمولة العقد كما يعيدها الخادم في هجرة 095، فيقيس الاختبار التفكيك
/// والعرض معًا: مفتاح ينقص أو يتغيّر يسقط هنا لا في يد المستخدم.
PartnerOverview _overviewPayload({
  bool hasActive = true,
  int activeCount = 1,
  bool withShare = true,
}) {
  return PartnerOverview.fromJson({
    'contract': 'read_partner_overview',
    'version': 1,
    'well_id': 'well-095',
    'is_partner': withShare,
    'partner': withShare
        ? {
            'partner_id': 'partner-a',
            'person_id': 'person-a',
            'full_name': 'سالم الشريك',
            'phone': '771000095',
            'period_start': '2026-08-01T00:00:00Z',
            'ownership_percent': 50,
            'profit_percent': 60,
            'gross_earned_minor': 240000,
            'irrigation_deducted_minor': 15000,
            'expenses_paid_minor': 20000,
            'net_payable_minor': 245000,
            'unpaid_minor': 145000,
            'total_paid_minor': 100000,
          }
        : null,
    'active_sessions': {'count': activeCount, 'has_active': hasActive},
    'open_window': {
      'starts_at': '2026-08-28T00:00:00Z',
      'is_final': false,
      'days_counted': 4,
      'sessions_count': 7,
      'charges_minor': 310000,
      'collected_minor': 180000,
      'expenses_minor': 45000,
    },
    'server_time': '2026-09-03T09:41:00Z',
  });
}

ProfitDistributionCycleItem _cyclePayload() {
  return ProfitDistributionCycleItem.fromJson({
    'id': 'cycle-1',
    'well_id': 'well-095',
    'period_start': '2026-07-01T00:00:00Z',
    'period_end': '2026-08-01T00:00:00Z',
    'status': 'approved',
    'eligible_revenue_minor': 500000,
    'eligible_expenses_minor': 100000,
    'retained_liabilities_minor': 0,
    'maintenance_reserve_minor': 0,
    'distributable_profit_minor': 400000,
    'approved_at': '2026-08-02T00:00:00Z',
    'partner_lines': [
      {
        'line_id': 'line-1',
        'partner_id': 'partner-a',
        'partner_name': 'سالم الشريك',
        'profit_percent': 45,
        'gross_share_minor': 180000,
        'out_of_pocket_minor': 0,
        'irrigation_deduction_minor': 0,
        'other_deductions_minor': 0,
        'net_share_minor': 180000,
        'paid_amount_minor': 100000,
        'remaining_minor': 80000,
        'payout_status': 'partially_paid',
      },
    ],
  });
}

Widget _host({
  required _FakePartnerRepository partnerRepo,
  _FakeFinanceRepository? financeRepo,
  _FakeWellRepository? wellRepo,
}) {
  final identity = testIdentity(
    activeWell: testWell(
      id: 'well-095',
      name: 'بئر الشريك',
      roles: const ['partner'],
    ),
    wells: [
      testWell(id: 'well-095', name: 'بئر الشريك', roles: const ['partner']),
    ],
  );

  return MaterialApp(
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: PartnerOverviewScreen(
        identity: identity,
        onWellChanged: (_) {},
        onLogout: () {},
        partnerRepository: partnerRepo,
        financeRepository: financeRepo ?? _FakeFinanceRepository(),
        wellRepository: wellRepo ?? _FakeWellRepository(),
      ),
    ),
  );
}

void main() {
  testWidgets('نصيب الشريك يُعرض من العقد لا من حساب في العميل', (
    tester,
  ) async {
    final repo = _FakePartnerRepository(overview: _overviewPayload());

    await tester.pumpWidget(_host(partnerRepo: repo));
    await tester.pumpAndSettle();

    expect(repo.reads, 1);
    expect(find.text('سالم الشريك'), findsWidgets);
    expect(find.text('نسبتك من الأرباح الآن'), findsOneWidget);
    expect(find.text('60%'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('100,000 ريال'), findsOneWidget);
    expect(find.text('145,000 ريال'), findsOneWidget);
  });

  testWidgets('حضور الجلسة الجارية يُعلن وعددها، وأرقامها لا', (tester) async {
    await tester.pumpWidget(
      _host(
        partnerRepo: _FakePartnerRepository(
          overview: _overviewPayload(hasActive: true, activeCount: 2),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('يوجد سقي جارٍ الآن — عدد الجلسات: 2'), findsOneWidget);
    expect(
      find.textContaining('أرقام الجلسة الجارية — المستحق والمدة والمضخة'),
      findsOneWidget,
    );
  });

  testWidgets('لا جلسة جارية = حالة تُقال لا فراغ', (tester) async {
    await tester.pumpWidget(
      _host(
        partnerRepo: _FakePartnerRepository(
          overview: _overviewPayload(hasActive: false, activeCount: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('لا يوجد سقي جارٍ الآن'), findsOneWidget);
  });

  testWidgets('الفترة غير المُقفلة موسومة بأرقام غير نهائية', (tester) async {
    await tester.pumpWidget(
      _host(partnerRepo: _FakePartnerRepository(overview: _overviewPayload())),
    );
    await tester.pumpAndSettle();

    expect(find.text('غير مُقفلة — أرقام غير نهائية'), findsOneWidget);
    expect(find.text('إيراد مفوتَر'), findsOneWidget);
    expect(find.text('180,000 ريال'), findsOneWidget);
    expect(find.text('45,000 ريال'), findsOneWidget);
    expect(
      find.textContaining('الصافي وحصتك من هذه الفترة يُعلنان عند إقفالها'),
      findsOneWidget,
    );
  });

  testWidgets('كل فترة بنسبتها التاريخية لا بنسبة اليوم', (tester) async {
    await tester.pumpWidget(
      _host(
        partnerRepo: _FakePartnerRepository(overview: _overviewPayload()),
        financeRepo: _FakeFinanceRepository(cycles: [_cyclePayload()]),
      ),
    );
    await tester.pumpAndSettle();

    // نسبته اليوم 60% ونسبته في الفترة المُقفلة 45%: الاثنتان معروضتان
    // كلٌّ في موضعها، فلا تُعاد كتابة تاريخ الفترة بنسبة الحاضر (ق-23).
    expect(find.text('نسبتك في هذه الفترة'), findsOneWidget);
    expect(find.text('45%'), findsOneWidget);
    expect(find.text('60%'), findsOneWidget);
    expect(find.text('معتمدة'), findsOneWidget);
  });

  testWidgets('المزارعون وديونهم والوقود يُعرضان كما أعادهما العقد', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        partnerRepo: _FakePartnerRepository(
          overview: _overviewPayload(),
          farmers: [
            FarmerBalance.fromJson(const {
              'farmer_well_account_id': 'fwa-1',
              'public_code': 'FWA-095',
              'full_name': 'مزارع البئر',
              'status': 'active',
              'invoiced_minor': 200000,
              'allocated_minor': 0,
              'advance_minor': 0,
              'debt_minor': 200000,
            }),
          ],
        ),
        wellRepo: _FakeWellRepository(
          tanks: [
            FuelTankModel.fromJson(const {
              'id': 'tank-1',
              'well_id': 'well-095',
              'public_code': 'TNK-1',
              'name': 'خزان البئر',
              'capacity_ml': 2000000,
              'current_balance_ml': 750000,
              'measurement_method': 'dipstick',
              'status': 'active',
            }),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('مزارع البئر (FWA-095)'), findsOneWidget);
    expect(find.text('200,000 ريال'), findsOneWidget);
    expect(find.text('خزان البئر'), findsOneWidget);
    expect(find.text('750 من 2000 لتر'), findsOneWidget);
  });

  testWidgets('الشركاء ونِسبهم يُعرضون، والمصروف بلا اسم من سجّله', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        partnerRepo: _FakePartnerRepository(overview: _overviewPayload()),
        financeRepo: _FakeFinanceRepository(
          partners: [
            PartnerFinancialItem.fromJson(const {
              'id': 'partner-a',
              'partner_person_id': 'person-a',
              'full_name': 'سالم الشريك',
              'phone': '771000095',
              'ownership_percent': 50,
              'profit_percent': 60,
              'net_payable_minor': 245000,
              'total_paid_minor': 100000,
              'status': 'active',
            }),
            PartnerFinancialItem.fromJson(const {
              'id': 'partner-b',
              'partner_person_id': 'person-b',
              'full_name': 'فهد الشريك',
              'phone': '772000095',
              'ownership_percent': 50,
              'profit_percent': 40,
              'net_payable_minor': 0,
              'total_paid_minor': 0,
              'status': 'active',
            }),
          ],
          expenses: [
            ExpenseItem.fromJson(const {
              'id': 'exp-1',
              'well_id': 'well-095',
              'category_code': 'maintenance',
              'category_name': 'صيانة',
              'amount_minor': 40000,
              'description': 'تغيير زيت المضخة',
              'status': 'posted',
              'spent_at': '2026-08-30T08:00:00Z',
              'recorded_by_name': null,
            }),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // اسمه موسوم «أنت» فلا يخلط سطره بسطر شريكه.
    expect(find.text('سالم الشريك (أنت)'), findsOneWidget);
    expect(find.text('فهد الشريك'), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);

    expect(find.text('تغيير زيت المضخة'), findsOneWidget);
    expect(find.text('40,000 ريال'), findsOneWidget);
    expect(
      find.textContaining('من سجّل المصروف وملاحظاته الداخلية خارج نطاق'),
      findsOneWidget,
    );
  });

  testWidgets('غياب سطر الشراكة يُقال ولا يُملأ بصفر', (tester) async {
    await tester.pumpWidget(
      _host(
        partnerRepo: _FakePartnerRepository(
          overview: _overviewPayload(withShare: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('لا يوجد سطر شراكة سارٍ لحسابك على هذا البئر.'),
      findsOneWidget,
    );
    expect(find.textContaining('عرض صفر هنا يُقرأ'), findsOneWidget);
  });

  testWidgets('فشل القراءة يُعلَن بسببه ولا يُعرض رقم مكانه', (tester) async {
    await tester.pumpWidget(
      _host(partnerRepo: _FakePartnerRepository(failRead: true)),
    );
    await tester.pumpAndSettle();

    expect(find.text('تعذر تحميل بيانات شراكتك'), findsOneWidget);
    expect(
      find.textContaining('partner contract unavailable'),
      findsOneWidget,
    );
    expect(find.text('نسبتك من الأرباح الآن'), findsNothing);
  });

  testWidgets('لا زرّ كتابة ولا حقل إدخال في شاشة الشريك', (tester) async {
    await tester.pumpWidget(
      _host(
        partnerRepo: _FakePartnerRepository(overview: _overviewPayload()),
        financeRepo: _FakeFinanceRepository(cycles: [_cyclePayload()]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(
      find.textContaining('هذه الشاشة اطلاع فقط'),
      findsOneWidget,
    );
  });
}

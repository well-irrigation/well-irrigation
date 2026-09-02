import 'package:flutter/material.dart';
import '../../core/api/app_bootstrap_repository.dart';
import '../../core/identity/app_identity.dart';
import '../../core/api/well_management_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/currency_display.dart';
import '../../core/widgets/top_well_selector.dart';

/// شاشة التقارير والمؤشرات والرسوم البيانية البسيطة V1 (UX-15 / القرارات 498–521)
class ReportsAnalyticsScreen extends StatefulWidget {
  final AppIdentity identity;
  final ValueChanged<WellSummary>? onWellChanged;
  final VoidCallback? onNavigateToHistory;
  final VoidCallback? onNavigateToExpenses;
  final WellManagementRepository? repository;

  const ReportsAnalyticsScreen({
    super.key,
    required this.identity,
    this.onWellChanged,
    this.onNavigateToHistory,
    this.onNavigateToExpenses,
    this.repository,
  });

  @override
  State<ReportsAnalyticsScreen> createState() => _ReportsAnalyticsScreenState();
}

class _ReportsAnalyticsScreenState extends State<ReportsAnalyticsScreen> {
  late WellManagementRepository _repo;
  late WellSummary _activeWell;

  String get _activeWellId => _activeWell.id;
  bool _isLoading = true;
  String _selectedPeriod = 'this_month'; // today, this_week, this_month

  ReportSummaryModel? _summary;

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? WellManagementRepository();
    _activeWell = widget.identity.activeWell;
    _loadReport();
  }

  Future<void> _loadReport() async {
    setState(() => _isLoading = true);
    try {
      final data = await _repo.fetchReportsSummary(
        wellId: _activeWellId,
        periodCode: _selectedPeriod,
      );
      if (!mounted) return;
      setState(() {
        _summary = data;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _summary = null;
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحميل التقارير: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: TopWellSelector(
          wells: widget.identity.wells,
          activeWell: _activeWell,
          subtitle: 'التقارير والمؤشرات العامة',
          onWellChanged: (newWell) {
            setState(() {
              _activeWell = newWell;
            });
            _loadReport();
            if (widget.onWellChanged != null) {
              widget.onWellChanged!(newWell);
            }
          },
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadReport,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // محدد الفترات الزمنية (القرار 498)
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        children: [
                          _buildPeriodTab('اليوم', 'today'),
                          _buildPeriodTab('هذا الأسبوع', 'this_week'),
                          _buildPeriodTab('هذا الشهر', 'this_month'),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // شبكة المؤشرات الرئيسية (القرار 499)
                    if (_summary != null) ...[
                      Row(
                        children: [
                          Expanded(
                            child: _buildMetricCard(
                              title: 'جلسات السقي',
                              value: '${_summary!.totalSessions} جلسة',
                              subtitle: '${(_summary!.totalDurationSeconds ~/ 3600)} ساعة تشغيل',
                              icon: Icons.water_drop_outlined,
                              color: AppColors.waterBlue,
                              onTap: widget.onNavigateToHistory,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildMetricCard(
                              title: 'استهلاك الديزل',
                              value: '${_summary!.totalFuelConsumedLiters} لتر',
                              subtitle: 'مخزون البئر',
                              icon: Icons.local_gas_station_outlined,
                              color: Colors.deepOrange,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildFinancialMetricCard(
                              title: 'المقبوضات المحصلة',
                              amount: _summary!.totalCollectedYER,
                              color: AppColors.agriculturalGreen,
                              icon: Icons.payments_outlined,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildFinancialMetricCard(
                              title: 'المصروفات المعتمدة',
                              amount: _summary!.totalExpensesYER,
                              color: Colors.purple,
                              icon: Icons.receipt_long_outlined,
                              onTap: widget.onNavigateToExpenses,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 20),

                      // 1. رسم ساعات السقي اليومية (Bar Chart V1 - Decisions 514 & 515)
                      _buildDailyIrrigationChartCard(_summary!.dailyIrrigation),

                      const SizedBox(height: 16),

                      // 2. رسم توزيع ساعات الطاقة (Energy Distribution - Decision 517)
                      _buildEnergyDistributionCard(_summary!.energyDistribution),

                      const SizedBox(height: 16),

                      // 3. اتجاه التحصيل مقابل المصروفات (Financial Trend - Decision 516)
                      _buildFinancialTrendCard(_summary!.financialTrends),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildPeriodTab(String title, String code) {
    final isSelected = _selectedPeriod == code;
    return Expanded(
      child: InkWell(
        onTap: () {
          setState(() => _selectedPeriod = code);
          _loadReport();
        },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? AppColors.deepBlue : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              color: isSelected ? Colors.white : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(title, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  Icon(icon, size: 18, color: color),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                value,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color),
              ),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFinancialMetricCard({
    required String title,
    required int amount,
    required Color color,
    required IconData icon,
    VoidCallback? onTap,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(title, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  Icon(icon, size: 18, color: color),
                ],
              ),
              const SizedBox(height: 8),
              CurrencyDisplay(
                amount: amount,
                showTafqeet: false,
                amountStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color),
              ),
              const SizedBox(height: 2),
              const Text('إجمالي الفترة', style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDailyIrrigationChartCard(List<DailyIrrigationMetric> metrics) {
    final maxHours = metrics.fold<int>(1, (max, m) => m.hours > max ? m.hours : max);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'ساعات السقي اليومية (Bar Chart V1)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.waterBlue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('ساعة / يوم', style: TextStyle(fontSize: 10, color: AppColors.deepBlue, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 140,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: metrics.map((m) {
                  final ratio = m.hours / maxHours;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            '${m.hours}س',
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            height: 80 * ratio + 10,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [AppColors.deepBlue, AppColors.waterBlue],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            m.dayName,
                            style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEnergyDistributionCard(List<EnergyDistributionMetric> distribution) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'توزيع ساعات السقي حسب مصدر الطاقة (Decision 517)',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 14),
            // شريط النسبة المئوية الملون
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 14,
                child: Row(
                  children: distribution.map((d) {
                    Color color = d.energySource == 'solar'
                        ? Colors.amber.shade700
                        : (d.energySource == 'well_diesel' ? Colors.deepOrange : AppColors.agriculturalGreen);
                    return Expanded(
                      flex: d.percentage,
                      child: Container(color: color),
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // مفاتيح الخريطة
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: distribution.map((d) {
                Color color = d.energySource == 'solar'
                    ? Colors.amber.shade700
                    : (d.energySource == 'well_diesel' ? Colors.deepOrange : AppColors.agriculturalGreen);
                return Row(
                  children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Text('${d.label} (${d.percentage}%)', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  ],
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFinancialTrendCard(List<FinancialTrendMetric> trends) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'التحصيل مقابل المصروفات خلال الفترة (Line/Trend V1)',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 12),
            ...trends.map((t) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(t.periodLabel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    Row(
                      children: [
                        Text(
                          'تحصيل: ${t.collectedYER} ريال',
                          style: const TextStyle(fontSize: 11, color: AppColors.agriculturalGreen, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'مصروف: ${t.expensesYER} ريال',
                          style: const TextStyle(fontSize: 11, color: Colors.purple),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

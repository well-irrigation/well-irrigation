import 'package:flutter/material.dart';
import '../../core/api/app_bootstrap_repository.dart';
import '../../core/identity/app_identity.dart';
import '../../core/api/finance_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/currency_display.dart';
import '../../core/widgets/top_well_selector.dart';
import 'partner_detail_financial_screen.dart';
import 'profit_distribution_screen.dart';

class PartnersScreen extends StatefulWidget {
  final AppIdentity identity;
  final ValueChanged<WellSummary>? onWellChanged;
  final FinanceRepository? repository;

  const PartnersScreen({
    super.key,
    required this.identity,
    this.onWellChanged,
    this.repository,
  });

  @override
  State<PartnersScreen> createState() => _PartnersScreenState();
}

class _PartnersScreenState extends State<PartnersScreen> {
  late FinanceRepository _repo;
  late WellSummary _activeWell;

  String get _activeWellId => _activeWell.id;
  String get _activeWellName => _activeWell.name;
  bool _isLoading = true;
  List<PartnerFinancialItem> _partners = [];

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? FinanceRepository();
    _activeWell = widget.identity.activeWell;
    _loadPartners();
  }

  Future<void> _loadPartners() async {
    setState(() => _isLoading = true);
    try {
      final list = await _repo.fetchPartners(_activeWellId);
      if (!mounted) return;
      setState(() {
        _partners = list;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _partners = const [];
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحميل بيانات الشركاء: $e')),
      );
    }
  }

  void _navigateToPartnerDetail(PartnerFinancialItem partner) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PartnerDetailFinancialScreen(
          wellId: _activeWellId,
          partnerId: partner.id,
          wellName: _activeWellName,
          repository: _repo,
        ),
      ),
    ).then((_) => _loadPartners());
  }

  void _navigateToDistributions() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfitDistributionScreen(
          identity: widget.identity.withActiveWell(_activeWell),
          repository: _repo,
        ),
      ),
    ).then((_) => _loadPartners());
  }

  @override
  Widget build(BuildContext context) {
    final totalProfitPercent = _partners.fold<int>(0, (sum, p) => sum + p.profitPercent);
    final totalRemainingBalance = _partners.fold<int>(0, (sum, p) => sum + p.remainingBalanceYER);

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: TopWellSelector(
          wells: widget.identity.wells,
          activeWell: _activeWell,
          subtitle: 'حسابات الشركاء والنسب',
          onWellChanged: (newWell) {
            setState(() {
              _activeWell = newWell;
            });
            _loadPartners();
            if (widget.onWellChanged != null) {
              widget.onWellChanged!(newWell);
            }
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.pie_chart_outline, color: AppColors.deepBlue),
            tooltip: 'دورات توزيع الأرباح',
            onPressed: _navigateToDistributions,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToDistributions,
        backgroundColor: AppColors.deepBlue,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.calculate_outlined),
        label: const Text('دورات وتوزيع الأرباح'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadPartners,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // بطاقة ملخص الشراكة ونسب الأرباح
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.deepBlue, Color(0xFF0D47A1)],
                          begin: Alignment.topRight,
                          end: Alignment.bottomLeft,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.deepBlue.withValues(alpha: 0.3),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: const [
                                  Icon(Icons.handshake_outlined, color: Colors.white, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'هيكل الشركاء والأرباح',
                                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: totalProfitPercent == 100
                                      ? AppColors.agriculturalGreen
                                      : Colors.orange,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  'مجموع النسب: $totalProfitPercent%',
                                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'إجمالي المستحقات المتبقية للشركاء:',
                            style: TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                          const SizedBox(height: 4),
                          CurrencyDisplay(
                            amount: totalRemainingBalance,
                            showTafqeet: false,
                            amountStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                            unitStyle: const TextStyle(color: Colors.white70, fontSize: 13),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // عنوان القائمة
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'قائمة الشركاء (${_partners.length})',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.history, size: 16),
                          label: const Text('سجل التوزيعات'),
                          onPressed: _navigateToDistributions,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // بطاقات الشركاء
                    if (_partners.isEmpty)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text('لا يوجد شركاء مسجلين في هذا البئر', style: TextStyle(color: AppColors.textSecondary)),
                        ),
                      )
                    else
                      ..._partners.map((partner) => _buildPartnerCard(partner)),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildPartnerCard(PartnerFinancialItem partner) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _navigateToPartnerDetail(partner),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ترويسة الشريك
              Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: AppColors.waterBlue.withValues(alpha: 0.12),
                    child: Text(
                      partner.fullName.isNotEmpty ? partner.fullName.substring(0, 1) : 'ش',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          partner.fullName,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          partner.phone.isNotEmpty ? '+967 ${partner.phone}' : 'بدون هاتف',
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.agriculturalGreen.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'شريك نشط ✅',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.agriculturalGreen),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),
              const Divider(height: 1, color: AppColors.surfaceSubtle),
              const SizedBox(height: 10),

              // نسب الشراكة والمستحق
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('نسبة الأرباح:', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      Text(
                        '${partner.profitPercent}%',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'الملكية: ${partner.ownershipPercent}%',
                        style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text('المتبقي له:', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      CurrencyDisplay(
                        amount: partner.remainingBalanceYER,
                        showTafqeet: false,
                        amountStyle: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: partner.remainingBalanceYER > 0 ? AppColors.deepBlue : AppColors.agriculturalGreen,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'إجمالي صافي الأرباح: ${partner.netPayableYER} ريال',
                        style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

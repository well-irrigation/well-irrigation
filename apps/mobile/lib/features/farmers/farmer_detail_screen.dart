import 'package:flutter/material.dart';

import '../../core/api/operations_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/tafqeet_utils.dart';
import '../../core/widgets/currency_display.dart';
import '../finance/farmer_financial_account_screen.dart';
import '../history/session_detail_screen.dart';

/// شاشة الملف الشخصي للمزارع وأراضيه وسجلاته وكشف الحساب (UX-13 / 380)
class FarmerDetailScreen extends StatefulWidget {
  const FarmerDetailScreen({
    required this.wellId,
    required this.farmerAccountId,
    required this.wellName,
    this.repository,
    super.key,
  });

  final String wellId;
  final String farmerAccountId;
  final String wellName;
  final OperationsRepository? repository;

  @override
  State<FarmerDetailScreen> createState() => _FarmerDetailScreenState();
}

class _FarmerDetailScreenState extends State<FarmerDetailScreen> with SingleTickerProviderStateMixin {
  late OperationsRepository _repo;
  late TabController _tabController;

  bool _isLoading = true;
  FarmerDetailData? _detailData;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    _repo = widget.repository ?? const OperationsRepository();
    _loadDetail();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadDetail() async {
    setState(() => _isLoading = true);
    try {
      final data = await _repo.fetchFarmerDetail(
        wellId: widget.wellId,
        farmerAccountId: widget.farmerAccountId,
      );
      if (mounted) {
        setState(() {
          _detailData = data;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showAddFarmDialog() {
    final nameController = TextEditingController();
    bool isSubmitting = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: const [
              Icon(Icons.landscape_outlined, color: AppColors.agriculturalGreen),
              SizedBox(width: 8),
              Text('إضافة أرض زراعية جديدة', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'سيتم ربط الأرض بالمزارع: ${_detailData?.account.fullName ?? ""}',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'اسم الأرض أو القطعة الزراعية *',
                  hintText: 'مثال: مزرعة الوادي الشرقي',
                  prefixIcon: Icon(Icons.terrain, size: 20),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: isSubmitting ? null : () => Navigator.of(dialogCtx).pop(),
              child: const Text('إلغاء', style: TextStyle(color: AppColors.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.agriculturalGreen,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: isSubmitting
                  ? null
                  : () async {
                      final name = nameController.text.trim();
                      if (name.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('يرجى إدخال اسم الأرض')),
                        );
                        return;
                      }

                      setDialogState(() => isSubmitting = true);
                      try {
                        await _repo.createFarm(
                          wellId: widget.wellId,
                          name: name,
                          farmerAccountId: widget.farmerAccountId,
                        );

                        if (dialogCtx.mounted) {
                          Navigator.of(dialogCtx).pop();
                        }
                        _loadDetail();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('تمت إضافة الأرض بنجاح ✅')),
                          );
                        }
                      } catch (e) {
                        setDialogState(() => isSubmitting = false);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('حدث خطأ أثناء الإضافة: $e')),
                          );
                        }
                      }
                    },
              child: isSubmitting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text('حفظ الأرض'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0) {
      return '$hours س و $minutes د';
    } else {
      return '$minutes دقيقة';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('ملف المزارع')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_detailData == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('ملف المزارع')),
        body: const Center(child: Text('لم يتم العثور على بيانات المزارع')),
      );
    }

    final data = _detailData!;
    final account = data.account;

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(
          account.fullName,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
        ),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.deepBlue,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.deepBlue,
          indicatorWeight: 3,
          tabs: [
            Tab(text: 'الأراضي (${data.farms.length})'),
            Tab(text: 'الجلسات (${data.totalSessionsCount})'),
            const Tab(text: 'كشف الحساب'),
          ],
        ),
      ),
      body: Column(
        children: [
          // كرت الترويسة الثابت للمزارع
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: AppColors.waterBlue.withValues(alpha: 0.12),
                  child: Text(
                    account.fullName.isNotEmpty ? account.fullName.substring(0, 1) : 'م',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            account.fullName,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: AppColors.border, width: 0.5),
                            ),
                            child: Text(
                              account.publicCode,
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.textSecondary),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        account.phone != null && account.phone!.isNotEmpty ? '+967 ${account.phone}' : 'بدون رقم هاتف مسجل',
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
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
                    'نشط ✅',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.agriculturalGreen),
                  ),
                ),
              ],
            ),
          ),

          // المحتوى المقسم لتبويبات
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                // 1. تبويب الأراضي الزراعية
                _buildFarmsTab(data.farms),

                // 2. تبويب سجل الجلسات
                _buildSessionsTab(data.recentSessions),

                // 3. تبويب كشف الحساب المالي
                _buildStatementTab(data),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFarmsTab(List<Farm> farms) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.agriculturalGreen,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_location_alt_outlined),
        label: const Text('إضافة أرض', style: TextStyle(fontWeight: FontWeight.bold)),
        onPressed: _showAddFarmDialog,
      ),
      body: farms.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.landscape_outlined, size: 48, color: AppColors.textMuted),
                  SizedBox(height: 12),
                  Text('لا توجد أراضٍ زراعية مسجلة لهذا المزارع بعد', style: TextStyle(color: AppColors.textSecondary)),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: farms.length,
              itemBuilder: (context, index) {
                final farm = farms[index];
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: AppColors.border),
                  ),
                  child: ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.agriculturalGreen.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.landscape, color: AppColors.agriculturalGreen, size: 20),
                    ),
                    title: Text(
                      farm.name,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.textPrimary),
                    ),
                    subtitle: const Text('أرض زراعية نشطة', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    trailing: const Icon(Icons.check_circle, color: AppColors.agriculturalGreen, size: 18),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildSessionsTab(List<SessionHistoryItem> sessions) {
    if (sessions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.history_toggle_off, size: 48, color: AppColors.textMuted),
            SizedBox(height: 12),
            Text('لا توجد جلسات سقي سابقة لهذا المزارع', style: TextStyle(color: AppColors.textSecondary)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: sessions.length,
      itemBuilder: (context, index) {
        final s = sessions[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.border),
          ),
          child: ListTile(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SessionDetailScreen(
                    sessionId: s.id,
                    wellName: widget.wellName,
                    repository: _repo,
                  ),
                ),
              );
            },
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.waterBlue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.water_drop, color: AppColors.waterBlue, size: 20),
            ),
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(s.farmName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                CurrencyDisplay(
                  amount: s.totalAmountYER,
                  amountStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                ),
              ],
            ),
            subtitle: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${s.startedAt.year}/${s.startedAt.month}/${s.startedAt.day} • ${_formatDuration(s.billableSeconds)}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
                Text(
                  s.isFullySettled ? 'خالص ✅' : 'متبقي ${s.remainingAmountYER} ر',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: s.isFullySettled ? AppColors.agriculturalGreen : AppColors.error,
                  ),
                ),
              ],
            ),
            trailing: const Icon(Icons.chevron_left, color: AppColors.textMuted, size: 18),
          ),
        );
      },
    );
  }

  Widget _buildStatementTab(FarmerDetailData data) {
    final isDebt = data.netBalanceYER > 0;
    final balanceColor = isDebt ? AppColors.error : AppColors.agriculturalGreen;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // كرت الرصيد الصافي الكبير
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isDebt
                    ? [const Color(0xFFC0392B), const Color(0xFFE74C3C)]
                    : [AppColors.deepBlue, AppColors.waterBlue],
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: (isDebt ? Colors.red : AppColors.deepBlue).withValues(alpha: 0.3),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              children: [
                Text(
                  isDebt ? 'المستحقات المتبقية على المزارع' : 'الحساب خالص / لا توجد ديون',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 8),
                CurrencyDisplay(
                  amount: data.netBalanceYER.abs(),
                  amountStyle: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  unitStyle: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 8),
                Text(
                  'فقط ${Tafqeet.format(data.netBalanceYER.abs())} لا غير.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // تفاصيل الفواتير والمدفوعات
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: AppColors.border),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildStatementRow('إجمالي فواتير السقي:', data.totalBilledYER, AppColors.deepBlue),
                  const SizedBox(height: 12),
                  _buildStatementRow('إجمالي المدفوعات المسددة:', data.totalPaidYER, AppColors.agriculturalGreen),
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: AppColors.surfaceSubtle),
                  const SizedBox(height: 12),
                  _buildStatementRow('صافي الرصيد المتبقي:', data.netBalanceYER, balanceColor, isBold: true),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ملاحظة إرشادية
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: const [
                Icon(Icons.info_outline, size: 18, color: AppColors.waterBlue),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'يتم احتساب الرصيد تلقائياً من واقع جلسات السقي المعتمدة وسندات القبض المسجلة.',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // زر فتح الحساب المالي الموسع (UX-14)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.deepBlue,
                side: const BorderSide(color: AppColors.deepBlue),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
              label: const Text('فتح الحساب المالي وسندات القبض (UX-14)', style: TextStyle(fontWeight: FontWeight.bold)),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => FarmerFinancialAccountScreen(
                      wellId: widget.wellId,
                      farmerAccountId: widget.farmerAccountId,
                      wellName: widget.wellName,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatementRow(String title, int amount, Color color, {bool isBold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            color: isBold ? AppColors.textPrimary : AppColors.textSecondary,
          ),
        ),
        CurrencyDisplay(
          amount: amount,
          showTafqeet: false,
          amountStyle: TextStyle(
            fontSize: isBold ? 15 : 13,
            fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}

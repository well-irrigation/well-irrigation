import 'package:flutter/material.dart';
import '../../core/api/app_bootstrap_repository.dart';
import '../../core/identity/app_identity.dart';
import '../../core/api/finance_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/currency_display.dart';
import '../../core/widgets/currency_text_form_field.dart';
import '../../core/widgets/top_well_selector.dart';

class ProfitDistributionScreen extends StatefulWidget {
  final AppIdentity identity;
  final ValueChanged<WellSummary>? onWellChanged;
  final FinanceRepository? repository;

  const ProfitDistributionScreen({
    super.key,
    required this.identity,
    this.onWellChanged,
    this.repository,
  });

  @override
  State<ProfitDistributionScreen> createState() => _ProfitDistributionScreenState();
}

class _ProfitDistributionScreenState extends State<ProfitDistributionScreen> {
  late FinanceRepository _repo;
  late WellSummary _activeWell;

  String get _activeWellId => _activeWell.id;
  bool _isLoading = true;
  List<ProfitDistributionCycleItem> _cycles = [];

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? FinanceRepository();
    _activeWell = widget.identity.activeWell;
    _loadCycles();
  }

  Future<void> _loadCycles() async {
    setState(() => _isLoading = true);
    try {
      final list = await _repo.fetchProfitDistributionCycles(
        _activeWellId,
      );
      if (!mounted) return;
      setState(() {
        _cycles = list;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cycles = const [];
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحميل دورات الأرباح: $e')),
      );
    }
  }

  void _showCalculateCycleDialog() {
    showDialog(
      context: context,
      builder: (dialogCtx) => _CalculateCycleDialog(
        wellId: _activeWellId,
        repository: _repo,
        onCycleCalculated: () {
          _loadCycles();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم احتساب دورة الأرباح بنجاح ✅')),
          );
        },
      ),
    );
  }

  void _showApproveConfirmation(ProfitDistributionCycleItem cycle) {
    showDialog(
      context: context,
      builder: (dialogCtx) {
        bool isApproving = false;
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: Row(
                children: const [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 24),
                  SizedBox(width: 8),
                  Text('تأكيد اعتماد دورة الأرباح', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'تنبيه هام (إجراء نهائي):',
                    style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'عند اعتماد دورة الأرباح سيتم قفل الحسابات لهذه الفترة بشكل نهائي، وتثبيت أنصبة الشركاء المالية كالتزامات رسمية للصرف، ولا يمكن تعديلها لاحقاً إلا بقيود تصحيحية مدققة.',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('إجمالي الأرباح المعتمدة:', style: TextStyle(fontSize: 12)),
                        CurrencyDisplay(
                          amount: cycle.distributableProfitYER,
                          showTafqeet: false,
                          amountStyle: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isApproving ? null : () => Navigator.of(ctx).pop(),
                  child: const Text('إلغاء', style: TextStyle(color: AppColors.textSecondary)),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.agriculturalGreen,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: isApproving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.check, size: 18),
                  label: const Text('إقرار واعتماد التوزيع'),
                  onPressed: isApproving
                      ? null
                      : () async {
                          setModalState(() => isApproving = true);
                          final nav = Navigator.of(ctx);
                          final scaffold = ScaffoldMessenger.of(context);
                          try {
                            await _repo.approveProfitDistribution(cycle.id);
                            if (ctx.mounted) nav.pop();
                            _loadCycles();
                            if (mounted) {
                              scaffold.showSnackBar(
                                const SnackBar(content: Text('تم اعتماد دورة الأرباح وقفل الفترة بنجاح ✅')),
                              );
                            }
                          } catch (e) {
                            setModalState(() => isApproving = false);
                            if (mounted) {
                              scaffold.showSnackBar(
                                SnackBar(content: Text('حدث خطأ: $e')),
                              );
                            }
                          }
                        },
                ),
              ],
            );
          },
        );
      },
    );
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
          subtitle: 'دورات وتوزيع الأرباح',
          onWellChanged: (newWell) {
            setState(() {
              _activeWell = newWell;
            });
            _loadCycles();
            if (widget.onWellChanged != null) {
              widget.onWellChanged!(newWell);
            }
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCalculateCycleDialog,
        backgroundColor: AppColors.deepBlue,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('احتساب دورة أرباح جديدة'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadCycles,
              child: _cycles.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.pie_chart_outline, size: 48, color: AppColors.border),
                          SizedBox(height: 12),
                          Text('لا توجد دورات توزيع أرباح سابقة', style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _cycles.length,
                      itemBuilder: (context, index) {
                        final cycle = _cycles[index];
                        return _buildCycleCard(cycle);
                      },
                    ),
            ),
    );
  }

  Widget _buildCycleCard(ProfitDistributionCycleItem cycle) {
    final isApproved = cycle.status == 'approved' || cycle.status == 'completed';
    final statusColor = isApproved ? AppColors.agriculturalGreen : Colors.orange;
    final statusText = isApproved ? 'معتمدة ومقفلة ✅' : 'محسوبة (بانتظار الاعتماد) ⏳';

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
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
            // ترويسة الدورة والحالة
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      const Icon(Icons.date_range, size: 18, color: AppColors.deepBlue),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'دورة الفترة: ${_formatDate(cycle.periodStart)} إلى ${_formatDate(cycle.periodEnd)}',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: statusColor),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),
            const Divider(height: 1, color: AppColors.surfaceSubtle),
            const SizedBox(height: 12),

            // كرت إجمالي الأرباح الموزعة
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.deepBlue.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.deepBlue.withValues(alpha: 0.1)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('صافي الأرباح القابلة للتوزيع:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  CurrencyDisplay(
                    amount: cycle.distributableProfitYER,
                    showTafqeet: false,
                    amountStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // تفكيك المعادلة الشفافة (Decisions 440)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('تفكيك المعادلة المحاسبية المعتمدة:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.textSecondary)),
                  const SizedBox(height: 8),
                  _buildFormulaRow('المقبوضات المؤهلة (+):', cycle.eligibleRevenueYER, AppColors.deepBlue),
                  const SizedBox(height: 4),
                  _buildFormulaRow('المصروفات المؤهلة (-):', cycle.eligibleExpensesYER, Colors.red),
                  const SizedBox(height: 4),
                  _buildFormulaRow('الالتزامات المحتجزة (-):', cycle.retainedLiabilitiesYER, Colors.orange),
                  const SizedBox(height: 4),
                  _buildFormulaRow('احتياطي الصيانة (-):', cycle.maintenanceReserveYER, Colors.purple),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // توزيع الحصص على الشركاء (Decisions 441)
            const Text('أنصبة الشركاء في هذه الدورة:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
            const SizedBox(height: 8),
            ...cycle.partnerLines.map((line) => _buildPartnerLineItem(line)),

            // زر اعتماد الدورة للمالك إذا كانت بانتظار الاعتماد
            if (!isApproved) ...[
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.agriculturalGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('إقرار واعتماد دورة الأرباح (قفل الفترة)', style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: () => _showApproveConfirmation(cycle),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFormulaRow(String title, int amount, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
        CurrencyDisplay(
          amount: amount,
          showTafqeet: false,
          amountStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
        ),
      ],
    );
  }

  Widget _buildPartnerLineItem(DistributionPartnerLine line) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Text(line.partnerName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.waterBlue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('${line.profitPercent}%', style: const TextStyle(fontSize: 10, color: AppColors.deepBlue)),
              ),
            ],
          ),
          CurrencyDisplay(
            amount: line.netShareYER,
            showTafqeet: false,
            amountStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
  }
}

/// نافذة احتساب دورة أرباح جديدة
class _CalculateCycleDialog extends StatefulWidget {
  final String wellId;
  final FinanceRepository repository;
  final VoidCallback onCycleCalculated;

  const _CalculateCycleDialog({
    required this.wellId,
    required this.repository,
    required this.onCycleCalculated,
  });

  @override
  State<_CalculateCycleDialog> createState() => _CalculateCycleDialogState();
}

class _CalculateCycleDialogState extends State<_CalculateCycleDialog> {
  final _reserveController = TextEditingController(text: '0');

  DateTime _startDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _endDate = DateTime.now();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _reserveController.dispose();
    super.dispose();
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: const [
          Icon(Icons.calculate, color: AppColors.deepBlue),
          SizedBox(width: 8),
          Text('احتساب دورة توزيع الأرباح', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'الفترة المحاسبية المراد احتساب أرباحها:',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: _pickDateRange,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${_formatDate(_startDate)} إلى ${_formatDate(_endDate)}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const Icon(Icons.calendar_month, color: AppColors.deepBlue, size: 20),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            // احتياطي الصيانة
            CurrencyTextFormField(
              controller: _reserveController,
              labelText: 'احتياطي الصيانة المحتجز (ريال يمني)',
              hintText: '0',
            ),
            const SizedBox(height: 8),
            const Text(
              'ملاحظة: الاحتساب المبدئي يسمح للمالك بمراجعة الأرقام والمعادلة قبل الإقرار النهائي.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('إلغاء', style: TextStyle(color: AppColors.textSecondary)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.deepBlue,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: _isSubmitting
              ? null
              : () async {
                  final rawReserve = _reserveController.text.replaceAll(',', '').trim();
                  final reserve = int.tryParse(rawReserve) ?? 0;

                  setState(() => _isSubmitting = true);
                  final nav = Navigator.of(context);
                  final scaffold = ScaffoldMessenger.of(context);
                  try {
                    await widget.repository.calculateProfitDistribution(
                      wellId: widget.wellId,
                      periodStart: _startDate,
                      periodEnd: _endDate,
                      manualReserveYER: reserve,
                    );
                    if (mounted) {
                      nav.pop();
                      widget.onCycleCalculated();
                    }
                  } catch (e) {
                    setState(() => _isSubmitting = false);
                    if (mounted) {
                      scaffold.showSnackBar(
                        SnackBar(content: Text('حدث خطأ: $e')),
                      );
                    }
                  }
                },
          child: _isSubmitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text('احتساب وتجهيز الدورة'),
        ),
      ],
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
  }
}

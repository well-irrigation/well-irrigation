import 'package:flutter/material.dart';
import '../../core/api/app_bootstrap_repository.dart';
import '../../core/api/well_management_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/currency_display.dart';
import '../../core/widgets/currency_text_form_field.dart';
import '../../core/widgets/top_well_selector.dart';

/// شاشة تعرفة الطاقة وإدارة الأسعار التاريخية (UX-15 / القرارات 491–497)
class PricingTariffScreen extends StatefulWidget {
  final String wellName;
  final String? wellId;
  final List<WellSummary> wells;
  final ValueChanged<WellSummary>? onWellChanged;
  final WellManagementRepository? repository;

  const PricingTariffScreen({
    super.key,
    required this.wellName,
    this.wellId,
    this.wells = const [],
    this.onWellChanged,
    this.repository,
  });

  @override
  State<PricingTariffScreen> createState() => _PricingTariffScreenState();
}

class _PricingTariffScreenState extends State<PricingTariffScreen> {
  late WellManagementRepository _repo;
  String? _activeWellId;
  String _activeWellName = '';
  bool _isLoading = true;
  PriceScheduleModel? _schedule;

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? WellManagementRepository();
    _activeWellName = widget.wellName;
    _activeWellId = widget.wellId ?? (widget.wells.isNotEmpty ? widget.wells.first.id : 'well-1');
    _loadSchedule();
  }

  Future<void> _loadSchedule() async {
    setState(() => _isLoading = true);
    final item = await _repo.fetchActivePriceSchedule(_activeWellId ?? 'well-1');
    if (mounted) {
      setState(() {
        _schedule = item;
        _isLoading = false;
      });
    }
  }

  void _showUpdateTariffDialog() {
    if (_schedule == null) return;
    showDialog(
      context: context,
      builder: (dialogCtx) => _UpdateTariffDialog(
        wellId: _activeWellId ?? 'well-1',
        currentSchedule: _schedule!,
        repository: _repo,
        onScheduleUpdated: () {
          _loadSchedule();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم اعتماد جدول التعرفة الجديد بنجاح ✅')),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeWellSummary = widget.wells.firstWhere(
      (w) => w.id == _activeWellId,
      orElse: () => WellSummary(
        id: _activeWellId ?? 'well-1',
        tenantId: 'tenant-1',
        name: _activeWellName,
        status: 'active',
        roles: const ['owner', 'operator'],
      ),
    );

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: TopWellSelector(
          wells: widget.wells.isNotEmpty ? widget.wells : [activeWellSummary],
          activeWell: activeWellSummary,
          subtitle: 'تعرفة الطاقة والأسعار',
          onWellChanged: (newWell) {
            setState(() {
              _activeWellId = newWell.id;
              _activeWellName = newWell.name;
            });
            _loadSchedule();
            if (widget.onWellChanged != null) {
              widget.onWellChanged!(newWell);
            }
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showUpdateTariffDialog,
        backgroundColor: AppColors.deepBlue,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.rate_review_outlined),
        label: const Text('تحديث جدول الأسعار'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadSchedule,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // بطاقة التعرفة النشطة الحالية
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.deepBlue, Color(0xFF1565C0)],
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
                                  Icon(Icons.price_change, color: Colors.white, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'التعرفة النشطة حالياً',
                                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: AppColors.agriculturalGreen,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Text(
                                  'معتمدة وسارية ✅',
                                  style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _schedule?.scheduleName ?? 'تعرفة الموسم الزراعي',
                            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'تاريخ السريان: ${_formatDate(_schedule?.effectiveFrom ?? DateTime.now())}',
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                          if (_schedule?.changeReason.isNotEmpty == true) ...[
                            const SizedBox(height: 4),
                            Text(
                              'السبب: ${_schedule!.changeReason}',
                              style: const TextStyle(color: Colors.white70, fontSize: 11),
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    const Text(
                      'أسعار ساعة السقي حسب مصدر الطاقة:',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 12),

                    // بطاقات أسعار مصادر الطاقة
                    if (_schedule != null) ..._schedule!.rules.map((rule) => _buildRateCard(rule)),

                    const SizedBox(height: 16),

                    // تنبيه التسعير التاريخي (Decisions 492 & 496)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Icon(Icons.history_toggle_off, color: AppColors.waterBlue, size: 20),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'مبدأ الأسعار التاريخية (ق-100 / 492–496): عند تحديث الأسعار، يتم حفظ جدول زمني جديد ولا تتأثر أسعار جلسات السقي والفواتير التاريخية السابقة نهائياً.',
                              style: TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildRateCard(PriceRuleModel rule) {
    IconData icon;
    Color color;

    switch (rule.energySource) {
      case 'solar':
        icon = Icons.wb_sunny_outlined;
        color = Colors.amber.shade800;
        break;
      case 'well_diesel':
        icon = Icons.local_gas_station_outlined;
        color = Colors.deepOrange;
        break;
      default:
        icon = Icons.agriculture_outlined;
        color = AppColors.agriculturalGreen;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rule.label,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  const Text('سعر الساعة الواحدة', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                ],
              ),
            ),
            CurrencyDisplay(
              amount: rule.hourlyRateYER,
              showTafqeet: false,
              amountStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color),
              unitStyle: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
  }
}

/// نافذة تحديث التعرفة والأسعار
class _UpdateTariffDialog extends StatefulWidget {
  final String wellId;
  final PriceScheduleModel currentSchedule;
  final WellManagementRepository repository;
  final VoidCallback onScheduleUpdated;

  const _UpdateTariffDialog({
    required this.wellId,
    required this.currentSchedule,
    required this.repository,
    required this.onScheduleUpdated,
  });

  @override
  State<_UpdateTariffDialog> createState() => _UpdateTariffDialogState();
}

class _UpdateTariffDialogState extends State<_UpdateTariffDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _reasonController = TextEditingController();
  final _solarController = TextEditingController();
  final _wellDieselController = TextEditingController();
  final _farmerDieselController = TextEditingController();

  final DateTime _effectiveFrom = DateTime.now();
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _nameController.text = 'تعرفة ${DateTime.now().year} المحدثة';
    _reasonController.text = 'تعديل أسعار الوقود ومعدلات التشغيل';

    for (final r in widget.currentSchedule.rules) {
      if (r.energySource == 'solar') _solarController.text = '${r.hourlyRateYER}';
      if (r.energySource == 'well_diesel') _wellDieselController.text = '${r.hourlyRateYER}';
      if (r.energySource == 'farmer_diesel') _farmerDieselController.text = '${r.hourlyRateYER}';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _reasonController.dispose();
    _solarController.dispose();
    _wellDieselController.dispose();
    _farmerDieselController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: const [
          Icon(Icons.rate_review_outlined, color: AppColors.deepBlue),
          SizedBox(width: 8),
          Text('تحديث تعرفة الأسعار', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'اسم جدول التعرفة *',
                  border: OutlineInputBorder(),
                ),
                validator: (val) => val == null || val.trim().isEmpty ? 'مطلوب' : null,
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _reasonController,
                decoration: const InputDecoration(
                  labelText: 'سبب تعديل الأسعار *',
                  border: OutlineInputBorder(),
                ),
                validator: (val) => val == null || val.trim().isEmpty ? 'مطلوب' : null,
              ),
              const SizedBox(height: 12),

              CurrencyTextFormField(
                controller: _solarController,
                labelText: 'سعر ساعة الطاقة الشمسية (ريال/ساعة) *',
                hintText: '0',
                validator: (val) => val == null || val.trim().isEmpty ? 'مطلوب' : null,
              ),
              const SizedBox(height: 12),

              CurrencyTextFormField(
                controller: _wellDieselController,
                labelText: 'سعر ساعة ديزل البئر الشامل (ريال/ساعة) *',
                hintText: '0',
                validator: (val) => val == null || val.trim().isEmpty ? 'مطلوب' : null,
              ),
              const SizedBox(height: 12),

              CurrencyTextFormField(
                controller: _farmerDieselController,
                labelText: 'سعر ساعة ديزل المزارع (ريال/ساعة) *',
                hintText: '0',
                validator: (val) => val == null || val.trim().isEmpty ? 'مطلوب' : null,
              ),
            ],
          ),
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
                  if (!_formKey.currentState!.validate()) return;
                  final solar = int.parse(_solarController.text.replaceAll(',', '').trim());
                  final wellDiesel = int.parse(_wellDieselController.text.replaceAll(',', '').trim());
                  final farmerDiesel = int.parse(_farmerDieselController.text.replaceAll(',', '').trim());

                  setState(() => _isSubmitting = true);
                  final nav = Navigator.of(context);
                  final scaffold = ScaffoldMessenger.of(context);
                  try {
                    await widget.repository.updatePriceSchedule(
                      wellId: widget.wellId,
                      scheduleName: _nameController.text.trim(),
                      changeReason: _reasonController.text.trim(),
                      effectiveFrom: _effectiveFrom,
                      solarHourlyRateYER: solar,
                      wellDieselHourlyRateYER: wellDiesel,
                      farmerDieselHourlyRateYER: farmerDiesel,
                    );
                    if (mounted) {
                      nav.pop();
                      widget.onScheduleUpdated();
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
              : const Text('اعتماد وسريان التعرفة'),
        ),
      ],
    );
  }
}

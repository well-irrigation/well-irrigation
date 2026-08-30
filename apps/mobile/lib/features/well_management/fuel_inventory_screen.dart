import 'package:flutter/material.dart';
import '../../core/api/app_bootstrap_repository.dart';
import '../../core/api/well_management_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/digit_utils.dart';
import '../../core/widgets/currency_text_form_field.dart';
import '../../core/widgets/top_well_selector.dart';

/// شاشة إدارة الوقود والخزانات والجرد والتسويات (UX-15 / القرارات 478–490)
class FuelInventoryScreen extends StatefulWidget {
  final String wellName;
  final String? wellId;
  final List<WellSummary> wells;
  final ValueChanged<WellSummary>? onWellChanged;
  final WellManagementRepository? repository;

  const FuelInventoryScreen({
    super.key,
    required this.wellName,
    this.wellId,
    this.wells = const [],
    this.onWellChanged,
    this.repository,
  });

  @override
  State<FuelInventoryScreen> createState() => _FuelInventoryScreenState();
}

class _FuelInventoryScreenState extends State<FuelInventoryScreen> {
  late WellManagementRepository _repo;
  String? _activeWellId;
  String _activeWellName = '';
  bool _isLoading = true;
  List<FuelTankModel> _tanks = [];

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? WellManagementRepository();
    _activeWellName = widget.wellName;
    _activeWellId = widget.wellId ?? (widget.wells.isNotEmpty ? widget.wells.first.id : 'well-1');
    _loadTanks();
  }

  Future<void> _loadTanks() async {
    setState(() => _isLoading = true);
    final list = await _repo.fetchFuelTanks(_activeWellId ?? 'well-1');
    if (mounted) {
      setState(() {
        _tanks = list;
        _isLoading = false;
      });
    }
  }

  void _showRecordPurchaseDialog() {
    if (_tanks.isEmpty) return;
    showDialog(
      context: context,
      builder: (dialogCtx) => _RecordFuelPurchaseDialog(
        tanks: _tanks,
        repository: _repo,
        onPurchaseRecorded: () {
          _loadTanks();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم تسجيل شراء الديزل وإضافته للمخزون بنجاح ✅')),
          );
        },
      ),
    );
  }

  void _showPhysicalCountDialog(FuelTankModel tank) {
    showDialog(
      context: context,
      builder: (dialogCtx) => _PhysicalCountAdjustmentDialog(
        tank: tank,
        repository: _repo,
        onCountRecorded: () {
          _loadTanks();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم تسجيل الجرد الفعلي واعتماد تسوية الفروقات ✅')),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalFuelBalance = _tanks.fold<int>(0, (sum, t) => sum + t.currentBalanceLiters);
    final totalCapacity = _tanks.fold<int>(0, (sum, t) => sum + t.capacityLiters);

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
          subtitle: 'إدارة الوقود والخزانات',
          onWellChanged: (newWell) {
            setState(() {
              _activeWellId = newWell.id;
              _activeWellName = newWell.name;
            });
            _loadTanks();
            if (widget.onWellChanged != null) {
              widget.onWellChanged!(newWell);
            }
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showRecordPurchaseDialog,
        backgroundColor: Colors.deepOrange,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.local_gas_station),
        label: const Text('تسجيل شراء ديزل'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadTanks,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // كرت رصيد ديزل البئر الإجمالي (القرار 478)
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFD35400), Color(0xFFE67E22)],
                          begin: Alignment.topRight,
                          end: Alignment.bottomLeft,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.deepOrange.withValues(alpha: 0.3),
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
                                  Icon(Icons.opacity, color: Colors.white, size: 22),
                                  SizedBox(width: 8),
                                  Text(
                                    'رصيد ديزل البئر المتاح',
                                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  'السعة: $totalCapacity لتر',
                                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                '$totalFuelBalance',
                                style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
                              ),
                              const SizedBox(width: 8),
                              const Text('لتر ديزل', style: TextStyle(color: Colors.white70, fontSize: 15)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value: totalCapacity > 0 ? (totalFuelBalance / totalCapacity) : 0,
                              backgroundColor: Colors.white24,
                              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                              minHeight: 8,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // قائمة الخزانات (القرار 479)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'خزانات الوقود (${_tanks.length})',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('شراء ديزل'),
                          onPressed: _showRecordPurchaseDialog,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    if (_tanks.isEmpty)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text('لا توجد خزانات وقود مسجلة لهذا البئر', style: TextStyle(color: AppColors.textSecondary)),
                        ),
                      )
                    else
                      ..._tanks.map((tank) => _buildTankCard(tank)),

                    const SizedBox(height: 16),

                    // إرشاد فصل ديزل البئر عن ديزل المزارع (Decisions 480 & 489)
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
                          Icon(Icons.info_outline, color: AppColors.waterBlue, size: 20),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'فصل ملكية الوقود (ق-100 / 480): كميات وتكلفة ديزل البئر تتبع إدارة المخزون التشغيلي. عندما يستخدم المزارع وقوده الخاص (ديزل المزارع) يظل رصيده منفصلاً ولا يفرض عليه أي رسم وقود إضافي.',
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

  Widget _buildTankCard(FuelTankModel tank) {
    final percent = tank.capacityLiters > 0 ? (tank.currentBalanceLiters / tank.capacityLiters) : 0.0;
    final isActual = tank.measurementMethod == 'actual';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.deepOrange.withValues(alpha: 0.1),
                  child: const Icon(Icons.storage, color: Colors.deepOrange, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tank.name,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'السعة الكلية: ${tank.capacityLiters} لتر',
                        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (isActual ? AppColors.agriculturalGreen : Colors.orange).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isActual ? 'قياس فعلي محقق ✅' : 'قياس تقديري ⚠️',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isActual ? AppColors.agriculturalGreen : Colors.orange),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'الرصيد الحالي: ${tank.currentBalanceLiters} لتر (${(percent * 100).toStringAsFixed(0)}%)',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.deepBlue),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    side: const BorderSide(color: AppColors.deepBlue),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  icon: const Icon(Icons.tune, size: 14),
                  label: const Text('جرد وقياس فعلي', style: TextStyle(fontSize: 11)),
                  onPressed: () => _showPhysicalCountDialog(tank),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// نافذة تسجيل شراء وقود جديد
class _RecordFuelPurchaseDialog extends StatefulWidget {
  final List<FuelTankModel> tanks;
  final WellManagementRepository repository;
  final VoidCallback onPurchaseRecorded;

  const _RecordFuelPurchaseDialog({
    required this.tanks,
    required this.repository,
    required this.onPurchaseRecorded,
  });

  @override
  State<_RecordFuelPurchaseDialog> createState() => _RecordFuelPurchaseDialogState();
}

class _RecordFuelPurchaseDialogState extends State<_RecordFuelPurchaseDialog> {
  final _formKey = GlobalKey<FormState>();
  final _quantityController = TextEditingController();
  final _costController = TextEditingController();
  final _supplierController = TextEditingController();
  final _noteController = TextEditingController();

  late String _selectedTankId;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _selectedTankId = widget.tanks.first.id;
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _costController.dispose();
    _supplierController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: const [
          Icon(Icons.local_gas_station, color: Colors.deepOrange),
          SizedBox(width: 8),
          Text('تسجيل شراء ديزل جديد', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _selectedTankId,
                decoration: const InputDecoration(
                  labelText: 'الخزان المستهدف *',
                  border: OutlineInputBorder(),
                ),
                items: widget.tanks.map((t) {
                  return DropdownMenuItem(
                    value: t.id,
                    child: Text(
                      '${t.name} (${t.currentBalanceLiters} لتر متاح)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged: (val) => setState(() => _selectedTankId = val ?? widget.tanks.first.id),
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _quantityController,
                keyboardType: TextInputType.number,
                inputFormatters: [ArabicToEnglishDigitsFormatter()],
                decoration: const InputDecoration(
                  labelText: 'الكمية المشتراة (باللتر) *',
                  hintText: 'مثال: 1000',
                  border: OutlineInputBorder(),
                ),
                validator: (val) => val == null || val.trim().isEmpty ? 'مطلوب' : null,
              ),
              const SizedBox(height: 12),

              CurrencyTextFormField(
                controller: _costController,
                labelText: 'التكلفة الإجمالية (ريال يمني) *',
                hintText: '0',
                validator: (val) => val == null || val.trim().isEmpty ? 'مطلوب' : null,
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _supplierController,
                decoration: const InputDecoration(
                  labelText: 'اسم المورد / المحطة (اختياري)',
                  border: OutlineInputBorder(),
                ),
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
            backgroundColor: Colors.deepOrange,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: _isSubmitting
              ? null
              : () async {
                  if (!_formKey.currentState!.validate()) return;
                  final qty = int.parse(_quantityController.text.trim());
                  final cost = int.parse(_costController.text.replaceAll(',', '').trim());

                  setState(() => _isSubmitting = true);
                  final nav = Navigator.of(context);
                  final scaffold = ScaffoldMessenger.of(context);
                  try {
                    await widget.repository.recordFuelPurchase(
                      tankId: _selectedTankId,
                      quantityLiters: qty,
                      totalCostYER: cost,
                      supplierName: _supplierController.text.trim(),
                      note: _noteController.text.trim(),
                    );
                    if (mounted) {
                      nav.pop();
                      widget.onPurchaseRecorded();
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
              : const Text('تأكيد وإضافة للمخزون'),
        ),
      ],
    );
  }
}

/// نافذة الجرد والقياس الفعلي وتسوية الفروقات
class _PhysicalCountAdjustmentDialog extends StatefulWidget {
  final FuelTankModel tank;
  final WellManagementRepository repository;
  final VoidCallback onCountRecorded;

  const _PhysicalCountAdjustmentDialog({
    required this.tank,
    required this.repository,
    required this.onCountRecorded,
  });

  @override
  State<_PhysicalCountAdjustmentDialog> createState() => _PhysicalCountAdjustmentDialogState();
}

class _PhysicalCountAdjustmentDialogState extends State<_PhysicalCountAdjustmentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _measuredController = TextEditingController();
  final _reasonController = TextEditingController();

  int _difference = 0;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _measuredController.text = '${widget.tank.currentBalanceLiters}';
    _reasonController.text = 'مطابقة الجرد الفعلي بالمسطرة';
  }

  @override
  void dispose() {
    _measuredController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _calculateDiff() {
    final measured = int.tryParse(_measuredController.text.trim()) ?? widget.tank.currentBalanceLiters;
    setState(() {
      _difference = measured - widget.tank.currentBalanceLiters;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: const [
          Icon(Icons.tune, color: AppColors.deepBlue),
          SizedBox(width: 8),
          Text('تسجيل جرد وقياس فعلي', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('الخزان: ${widget.tank.name}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('الرصيد المسجل بالنظام: ${widget.tank.currentBalanceLiters} لتر', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 14),

              TextFormField(
                controller: _measuredController,
                keyboardType: TextInputType.number,
                inputFormatters: [ArabicToEnglishDigitsFormatter()],
                onChanged: (_) => _calculateDiff(),
                decoration: const InputDecoration(
                  labelText: 'القياس الفعلي بالخزان (لتر) *',
                  border: OutlineInputBorder(),
                ),
                validator: (val) => val == null || val.trim().isEmpty ? 'مطلوب' : null,
              ),
              const SizedBox(height: 10),

              // كرت إظهار الفرق (القرار 486)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _difference == 0
                      ? AppColors.agriculturalGreen.withValues(alpha: 0.1)
                      : (_difference > 0 ? Colors.purple.withValues(alpha: 0.1) : Colors.red.withValues(alpha: 0.1)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('فرق التسوية المحتسب:', style: TextStyle(fontSize: 12)),
                    Text(
                      '$_difference لتر',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: _difference == 0
                            ? AppColors.agriculturalGreen
                            : (_difference > 0 ? Colors.purple : Colors.red),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _reasonController,
                decoration: const InputDecoration(
                  labelText: 'سبب تسوية الفرق *',
                  border: OutlineInputBorder(),
                ),
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
                  final measured = int.parse(_measuredController.text.trim());

                  setState(() => _isSubmitting = true);
                  final nav = Navigator.of(context);
                  final scaffold = ScaffoldMessenger.of(context);
                  try {
                    await widget.repository.recordPhysicalFuelCount(
                      wellId: widget.tank.wellId,
                      tankId: widget.tank.id,
                      measuredBalanceLiters: measured,
                      adjustmentReason: _reasonController.text.trim(),
                    );
                    if (mounted) {
                      nav.pop();
                      widget.onCountRecorded();
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
              : const Text('اعتماد الجرد والتسوية'),
        ),
      ],
    );
  }
}

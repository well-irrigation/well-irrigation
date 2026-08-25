import 'package:flutter/material.dart';
import '../../core/api/app_bootstrap_repository.dart';
import '../../core/api/well_management_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/digit_utils.dart';
import '../../core/widgets/top_well_selector.dart';

/// شاشة إدارة المضخات والمعدات التشغيلية (UX-15 / القرارات 466–472)
class PumpsManagementScreen extends StatefulWidget {
  final String wellName;
  final String? wellId;
  final List<WellSummary> wells;
  final ValueChanged<WellSummary>? onWellChanged;
  final WellManagementRepository? repository;

  const PumpsManagementScreen({
    super.key,
    required this.wellName,
    this.wellId,
    this.wells = const [],
    this.onWellChanged,
    this.repository,
  });

  @override
  State<PumpsManagementScreen> createState() => _PumpsManagementScreenState();
}

class _PumpsManagementScreenState extends State<PumpsManagementScreen> {
  late WellManagementRepository _repo;
  String? _activeWellId;
  String _activeWellName = '';
  bool _isLoading = true;
  List<PumpModel> _pumps = [];

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? WellManagementRepository();
    _activeWellName = widget.wellName;
    _activeWellId = widget.wellId ?? (widget.wells.isNotEmpty ? widget.wells.first.id : 'well-1');
    _loadPumps();
  }

  Future<void> _loadPumps() async {
    setState(() => _isLoading = true);
    final list = await _repo.fetchPumps(_activeWellId ?? 'well-1');
    if (mounted) {
      setState(() {
        _pumps = list;
        _isLoading = false;
      });
    }
  }

  void _showAddEditPumpDialog([PumpModel? existingPump]) {
    showDialog(
      context: context,
      builder: (dialogCtx) => _AddEditPumpDialog(
        wellId: _activeWellId ?? 'well-1',
        existingPump: existingPump,
        repository: _repo,
        onPumpSaved: () {
          _loadPumps();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(existingPump == null ? 'تمت إضافة المضخة بنجاح ✅' : 'تم تحديث بيانات المضخة بنجاح ✅'),
            ),
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
          subtitle: 'إدارة المضخات والمعدات',
          onWellChanged: (newWell) {
            setState(() {
              _activeWellId = newWell.id;
              _activeWellName = newWell.name;
            });
            _loadPumps();
            if (widget.onWellChanged != null) {
              widget.onWellChanged!(newWell);
            }
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddEditPumpDialog(),
        backgroundColor: AppColors.deepBlue,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('إضافة مضخة جديدة'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadPumps,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // بطاقة تعريفية بالمضخات
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.waterBlue.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.water, color: AppColors.waterBlue, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'المضخات المسجلة (${_pumps.length})',
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  'المضخة معدة ميكانيكية، ومصدر الطاقة الفعلي يتحدد بكل جلسة سقي.',
                                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    if (_pumps.isEmpty)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text('لا توجد مضخات مسجلة لهذا البئر', style: TextStyle(color: AppColors.textSecondary)),
                        ),
                      )
                    else
                      ..._pumps.map((pump) => _buildPumpCard(pump)),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildPumpCard(PumpModel pump) {
    Color statusColor;
    String statusText;

    switch (pump.status) {
      case 'running':
        statusColor = AppColors.agriculturalGreen;
        statusText = 'تعمل وجاهزة ✅';
        break;
      case 'maintenance':
        statusColor = Colors.orange;
        statusText = 'تحت الصيانة 🛠️';
        break;
      case 'retired':
        statusColor = Colors.grey;
        statusText = 'خارج الخدمة 🚫';
        break;
      default:
        statusColor = AppColors.deepBlue;
        statusText = 'متوقفة / احتياط ⏸️';
    }

    String typeLabel = pump.pumpType == 'submersible'
        ? 'مضخة غاطسة'
        : (pump.pumpType == 'surface' ? 'مضخة سطحية' : 'مضخة توربين');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _showAddEditPumpDialog(pump),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ترويسة المضخة
              Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: AppColors.deepBlue.withValues(alpha: 0.08),
                    child: const Icon(Icons.speed, color: AppColors.deepBlue, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          pump.name,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$typeLabel • ${pump.horsepower} حصان',
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
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

              const SizedBox(height: 10),
              const Divider(height: 1, color: AppColors.surfaceSubtle),
              const SizedBox(height: 8),

              // المواصفات التقديرية
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (pump.flowRateLitersPerSecond != null)
                    Text(
                      'التدفق: ${pump.flowRateLitersPerSecond} لتر/ث',
                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),
                  if (pump.fuelConsumptionLitersPerHour != null && pump.fuelConsumptionLitersPerHour! > 0)
                    Text(
                      'الاستهلاك: ${pump.fuelConsumptionLitersPerHour} لتر/ساعة',
                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),
                  TextButton.icon(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    icon: const Icon(Icons.edit, size: 14),
                    label: const Text('تعديل', style: TextStyle(fontSize: 12)),
                    onPressed: () => _showAddEditPumpDialog(pump),
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

/// نافذة إضافة أو تعديل بيانات المضخة
class _AddEditPumpDialog extends StatefulWidget {
  final String wellId;
  final PumpModel? existingPump;
  final WellManagementRepository repository;
  final VoidCallback onPumpSaved;

  const _AddEditPumpDialog({
    required this.wellId,
    this.existingPump,
    required this.repository,
    required this.onPumpSaved,
  });

  @override
  State<_AddEditPumpDialog> createState() => _AddEditPumpDialogState();
}

class _AddEditPumpDialogState extends State<_AddEditPumpDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _hpController = TextEditingController();
  final _flowController = TextEditingController();
  final _fuelController = TextEditingController();
  final _notesController = TextEditingController();

  String _pumpType = 'submersible';
  String _status = 'standby';
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    if (widget.existingPump != null) {
      final p = widget.existingPump!;
      _nameController.text = p.name;
      _hpController.text = p.horsepower.toString();
      _flowController.text = p.flowRateLitersPerSecond?.toString() ?? '';
      _fuelController.text = p.fuelConsumptionLitersPerHour?.toString() ?? '';
      _notesController.text = p.notes ?? '';
      _pumpType = p.pumpType;
      _status = p.status;
    } else {
      _hpController.text = '50';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hpController.dispose();
    _flowController.dispose();
    _fuelController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existingPump != null;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(isEdit ? Icons.edit : Icons.add_circle_outline, color: AppColors.deepBlue),
          const SizedBox(width: 8),
          Text(isEdit ? 'تعديل بيانات المضخة' : 'إضافة مضخة جديدة', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // اسم المضخة
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'اسم / نوع المضخة *',
                  hintText: 'مثال: Frankline 75HP الغاطسة',
                  border: OutlineInputBorder(),
                ),
                validator: (val) => val == null || val.trim().isEmpty ? 'يرجى إدخال اسم المضخة' : null,
              ),
              const SizedBox(height: 12),

              // نوع المضخة والحالة
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _pumpType,
                      decoration: const InputDecoration(
                        labelText: 'نوع المضخة',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'submersible', child: Text('غاطسة')),
                        DropdownMenuItem(value: 'surface', child: Text('سطحية')),
                        DropdownMenuItem(value: 'turbine', child: Text('توربين')),
                      ],
                      onChanged: (val) => setState(() => _pumpType = val ?? 'submersible'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _status,
                      decoration: const InputDecoration(
                        labelText: 'الحالة',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'running', child: Text('تعمل ✅')),
                        DropdownMenuItem(value: 'standby', child: Text('احتياط ⏸️')),
                        DropdownMenuItem(value: 'maintenance', child: Text('صيانة 🛠️')),
                        DropdownMenuItem(value: 'retired', child: Text('خارج الخدمة')),
                      ],
                      onChanged: (val) => setState(() => _status = val ?? 'standby'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // القدرة بالحصان والتدفق
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _hpController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [ArabicToEnglishDigitsFormatter()],
                      decoration: const InputDecoration(
                        labelText: 'القدرة (حصان) *',
                        border: OutlineInputBorder(),
                      ),
                      validator: (val) => val == null || val.trim().isEmpty ? 'مطلوب' : null,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _flowController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [ArabicToEnglishDigitsFormatter()],
                      decoration: const InputDecoration(
                        labelText: 'التدفق (لتر/ث)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // معدل استهلاك الوقود
              TextFormField(
                controller: _fuelController,
                keyboardType: TextInputType.number,
                inputFormatters: [ArabicToEnglishDigitsFormatter()],
                decoration: const InputDecoration(
                  labelText: 'معدل استهلاك الديزل التقديري (لتر/ساعة)',
                  hintText: 'مثال: 14',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),

              // ملاحظات
              TextFormField(
                controller: _notesController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'ملاحظات الصيانة والتشغيل',
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
            backgroundColor: AppColors.deepBlue,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: _isSubmitting
              ? null
              : () async {
                  if (!_formKey.currentState!.validate()) return;
                  final hp = int.tryParse(_hpController.text.trim()) ?? 50;
                  final flow = int.tryParse(_flowController.text.trim());
                  final fuel = int.tryParse(_fuelController.text.trim());

                  setState(() => _isSubmitting = true);
                  final nav = Navigator.of(context);
                  final scaffold = ScaffoldMessenger.of(context);
                  try {
                    await widget.repository.savePump(
                      wellId: widget.wellId,
                      pumpId: widget.existingPump?.id,
                      name: _nameController.text.trim(),
                      pumpType: _pumpType,
                      horsepower: hp,
                      flowRateLps: flow,
                      fuelRateLph: fuel,
                      status: _status,
                      notes: _notesController.text.trim(),
                    );
                    if (mounted) {
                      nav.pop();
                      widget.onPumpSaved();
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
              : Text(isEdit ? 'حفظ التعديلات' : 'إضافة المضخة'),
        ),
      ],
    );
  }
}

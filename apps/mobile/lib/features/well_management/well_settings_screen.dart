import 'package:flutter/material.dart';
import '../../core/api/app_bootstrap_repository.dart';
import '../../core/api/well_management_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/digit_utils.dart';
import '../../core/widgets/top_well_selector.dart';

/// شاشة بيانات وإعدادات البئر الأساسية (UX-15 / القرارات 460–465)
class WellSettingsScreen extends StatefulWidget {
  final String wellName;
  final String? wellId;
  final List<WellSummary> wells;
  final ValueChanged<WellSummary>? onWellChanged;
  final WellManagementRepository? repository;

  const WellSettingsScreen({
    super.key,
    required this.wellName,
    this.wellId,
    this.wells = const [],
    this.onWellChanged,
    this.repository,
  });

  @override
  State<WellSettingsScreen> createState() => _WellSettingsScreenState();
}

class _WellSettingsScreenState extends State<WellSettingsScreen> {
  late WellManagementRepository _repo;
  String? _activeWellId;
  String _activeWellName = '';
  bool _isLoading = true;
  bool _isSaving = false;

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _locationController = TextEditingController();
  final _depthController = TextEditingController();
  final _staticWaterController = TextEditingController();
  final _notesController = TextEditingController();

  WellDetailsModel? _details;

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? WellManagementRepository();
    _activeWellName = widget.wellName;
    _activeWellId = widget.wellId ?? (widget.wells.isNotEmpty ? widget.wells.first.id : 'well-1');
    _loadDetails();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    _depthController.dispose();
    _staticWaterController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadDetails() async {
    setState(() => _isLoading = true);
    final data = await _repo.fetchWellDetails(_activeWellId ?? 'well-1');
    if (mounted) {
      setState(() {
        _details = data;
        _nameController.text = data.name;
        _locationController.text = data.locationDescription ?? '';
        _depthController.text = data.depthMeters?.toString() ?? '';
        _staticWaterController.text = data.staticWaterLevelMeters?.toString() ?? '';
        _notesController.text = data.notes ?? '';
        _isLoading = false;
      });
    }
  }

  Future<void> _saveChanges() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);
    final scaffold = ScaffoldMessenger.of(context);

    final depth = int.tryParse(_depthController.text.trim());
    final staticWater = int.tryParse(_staticWaterController.text.trim());

    try {
      await _repo.updateWellDetails(
        wellId: _activeWellId ?? 'well-1',
        name: _nameController.text.trim(),
        locationDescription: _locationController.text.trim(),
        depthMeters: depth,
        staticWaterLevelMeters: staticWater,
        notes: _notesController.text.trim(),
      );

      if (mounted) {
        setState(() {
          _isSaving = false;
          _activeWellName = _nameController.text.trim();
        });
        scaffold.showSnackBar(
          const SnackBar(content: Text('تم حفظ بيانات البئر بنجاح ✅')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        scaffold.showSnackBar(
          SnackBar(content: Text('حدث خطأ أثناء الحفظ: $e')),
        );
      }
    }
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
          subtitle: 'بيانات وإعدادات البئر',
          onWellChanged: (newWell) {
            setState(() {
              _activeWellId = newWell.id;
              _activeWellName = newWell.name;
            });
            _loadDetails();
            if (widget.onWellChanged != null) {
              widget.onWellChanged!(newWell);
            }
          },
        ),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.deepBlue,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: _isSaving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.save_outlined),
            label: const Text('حفظ التغييرات صراحة', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            onPressed: _isSaving ? null : _saveChanges,
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // كرت الحالة التشغيلية للبئر
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
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.water_drop, color: Colors.white, size: 28),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _details?.name ?? _activeWellName,
                                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppColors.agriculturalGreen,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: const Text('حالة البئر: نشط وتشغيلي', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    const Text(
                      'البيانات التشغيلية والموقع:',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 12),

                    // اسم البئر
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'اسم البئر المعتمد *',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.badge_outlined, size: 20),
                      ),
                      validator: (val) => val == null || val.trim().isEmpty ? 'يرجى إدخال اسم البئر' : null,
                    ),
                    const SizedBox(height: 14),

                    // موقع البئر والوصف
                    TextFormField(
                      controller: _locationController,
                      decoration: const InputDecoration(
                        labelText: 'الموقع الجغرافي / الحوض / المنطقة',
                        hintText: 'مثال: وادي حضرموت - منطقة الغرفة',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.location_on_outlined, size: 20),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // العمق ومنسوب المياه
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _depthController,
                            keyboardType: TextInputType.number,
                            inputFormatters: [ArabicToEnglishDigitsFormatter()],
                            decoration: const InputDecoration(
                              labelText: 'العمق الكلي (متر)',
                              hintText: '180',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.straighten, size: 20),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: _staticWaterController,
                            keyboardType: TextInputType.number,
                            inputFormatters: [ArabicToEnglishDigitsFormatter()],
                            decoration: const InputDecoration(
                              labelText: 'منسوب المياه الساكن (متر)',
                              hintText: '45',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.waves, size: 20),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // ملاحظات البئر
                    TextFormField(
                      controller: _notesController,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'ملاحظات وتشغيل البئر',
                        hintText: 'أي تفاصيل تشغيلية تخص البئر أو الشراكات...',
                        border: OutlineInputBorder(),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // تنبيه حماية البيانات التاريخية (القرار 464 & 465)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Icon(Icons.shield_outlined, color: Colors.amber, size: 20),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'ضوابط السلامة (ق-100 / 464–465): لحماية سجلات السقي والتحصيل المالي السابقة، لا يمكن حذف البئر نهائياً في حال وجود معاملات تاريخية. كما يُمنع تعطيل البئر أثناء وجود جلسة سقي جارية.',
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
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/app_bootstrap_repository.dart';
import '../../core/api/operations_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/digit_utils.dart';
import '../../core/widgets/top_well_selector.dart';
import 'farmer_detail_screen.dart';

/// شاشة دليل المزارعين والأراضي (UX-13 / 380 / ق-80 / ق-84 / ق-98)
class FarmersDirectoryScreen extends StatefulWidget {
  const FarmersDirectoryScreen({
    required this.wellName,
    this.wellId,
    this.wells = const [],
    this.repository,
    this.onWellChanged,
    this.onLogout,
    super.key,
  });

  final String wellName;
  final String? wellId;
  final List<WellSummary> wells;
  final OperationsRepository? repository;
  final ValueChanged<WellSummary>? onWellChanged;
  final VoidCallback? onLogout;

  @override
  State<FarmersDirectoryScreen> createState() => _FarmersDirectoryScreenState();
}

class _FarmersDirectoryScreenState extends State<FarmersDirectoryScreen> {
  late OperationsRepository _repo;

  String? _activeWellId;
  String _activeWellName = '';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  List<FarmerAccount> _farmers = [];
  Map<String, int> _farmCounts = {};

  @override
  void initState() {
    super.initState();
    _activeWellName = widget.wellName;
    _activeWellId = widget.wellId ?? (widget.wells.isNotEmpty ? widget.wells.first.id : 'well-1');

    _repo = widget.repository ?? const OperationsRepository();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (_activeWellId == null) return;
    setState(() => _isLoading = true);

    try {
      final farmers = await _repo.fetchFarmers(_activeWellId!);
      final farms = await _repo.fetchFarms(_activeWellId!);

      final counts = <String, int>{};
      for (final f in farms) {
        if (f.farmerAccountId != null) {
          counts[f.farmerAccountId!] = (counts[f.farmerAccountId!] ?? 0) + 1;
        }
      }

      if (mounted) {
        setState(() {
          _farmers = farmers;
          _farmCounts = counts;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<FarmerAccount> get _filteredFarmers {
    if (_searchQuery.trim().isEmpty) {
      return _farmers;
    }
    final q = normalizeArabicDigits(_searchQuery.trim().toLowerCase());
    return _farmers.where((f) {
      final matchName = f.fullName.toLowerCase().contains(q);
      final matchCode = f.publicCode.toLowerCase().contains(q);
      final matchPhone = f.phone != null && f.phone!.contains(q);
      return matchName || matchCode || matchPhone;
    }).toList();
  }

  void _showAddFarmerDialog() {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final notesController = TextEditingController();
    bool isSubmitting = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: const [
              Icon(Icons.person_add_outlined, color: AppColors.deepBlue),
              SizedBox(width: 8),
              Text('إضافة مزارع جديد', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'الاسم الكامل للمزارع *',
                    hintText: 'مثال: محمد عبدالله الشامي',
                    prefixIcon: Icon(Icons.person_outline, size: 20),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    ArabicToEnglishDigitsFormatter(),
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(9),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'رقم الهاتف (9 أرقام)',
                    hintText: '7XXXXXXXX',
                    prefixText: '+967 ',
                    prefixIcon: Icon(Icons.phone_outlined, size: 20),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: notesController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'ملاحظات إضافية (اختياري)',
                    hintText: 'موقع الأرض أو تفاصيل إضافية...',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSubmitting ? null : () => Navigator.of(dialogCtx).pop(),
              child: const Text('إلغاء', style: TextStyle(color: AppColors.textSecondary)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.deepBlue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: isSubmitting
                  ? null
                  : () async {
                      final name = nameController.text.trim();
                      if (name.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('يرجى إدخال اسم المزارع')),
                        );
                        return;
                      }

                      setDialogState(() => isSubmitting = true);
                      try {
                        await _repo.createFarmer(
                          wellId: _activeWellId!,
                          fullName: name,
                          phone: phoneController.text.trim().isNotEmpty ? phoneController.text.trim() : null,
                          notes: notesController.text.trim().isNotEmpty ? notesController.text.trim() : null,
                        );

                        if (dialogCtx.mounted) {
                          Navigator.of(dialogCtx).pop();
                        }
                        _loadData();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('تمت إضافة المزارع بنجاح ✅')),
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
                  : const Text('حفظ المزارع'),
            ),
          ],
        ),
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

    final displayedFarmers = _filteredFarmers;

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: TopWellSelector(
          wells: widget.wells.isNotEmpty ? widget.wells : [activeWellSummary],
          activeWell: activeWellSummary,
          subtitle: 'دليل المزارعين والأراضي',
          onWellChanged: (newWell) {
            setState(() {
              _activeWellId = newWell.id;
              _activeWellName = newWell.name;
            });
            _loadData();
            if (widget.onWellChanged != null) {
              widget.onWellChanged!(newWell);
            }
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.textSecondary),
            tooltip: 'تحديث',
            onPressed: _loadData,
          ),
          if (widget.onLogout != null)
            IconButton(
              icon: const Icon(Icons.logout, color: AppColors.textSecondary),
              tooltip: 'تسجيل الخروج',
              onPressed: widget.onLogout,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.deepBlue,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add),
        label: const Text('مزارع جديد', style: TextStyle(fontWeight: FontWeight.bold)),
        onPressed: _showAddFarmerDialog,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 1. حقل البحث الفوري
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'ابحث باسم المزارع، رقم الهاتف، أو الكود...',
                  hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                  prefixIcon: const Icon(Icons.search, color: AppColors.waterBlue, size: 20),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: AppColors.surface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (val) => setState(() => _searchQuery = val),
              ),
            ),

            // 2. شريط الإحصائيات
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.people_outline, size: 16, color: AppColors.deepBlue),
                      const SizedBox(width: 6),
                      Text(
                        '${displayedFarmers.length} مزارع مسجل',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.deepBlue),
                      ),
                    ],
                  ),
                  Text(
                    '${_farmCounts.values.fold<int>(0, (sum, c) => sum + c)} أرض زراعية',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),

            // 3. قائمة المزارعين
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : displayedFarmers.isEmpty
                      ? _buildEmptyState()
                      : RefreshIndicator(
                          onRefresh: _loadData,
                          child: ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: displayedFarmers.length,
                            itemBuilder: (context, index) {
                              final farmer = displayedFarmers[index];
                              final count = _farmCounts[farmer.id] ?? 0;
                              return _buildFarmerCard(farmer, count);
                            },
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.person_off_outlined, size: 36, color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            const Text(
              'لا يوجد مزارعون',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
            ),
            const SizedBox(height: 6),
            const Text(
              'لم يتم العثور على مزارعين يطابقون شروط البحث، أو لم يتم تسجيل مزارعين في هذا البئر بعد.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFarmerCard(FarmerAccount farmer, int farmsCount) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => FarmerDetailScreen(
                wellId: _activeWellId!,
                farmerAccountId: farmer.id,
                wellName: _activeWellName,
                repository: _repo,
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // أيقونة المزارع
              CircleAvatar(
                radius: 24,
                backgroundColor: AppColors.waterBlue.withValues(alpha: 0.12),
                child: Text(
                  farmer.fullName.isNotEmpty ? farmer.fullName.substring(0, 1) : 'م',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.deepBlue,
                  ),
                ),
              ),
              const SizedBox(width: 14),

              // الاسم والكود والهاتف
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            farmer.fullName,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
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
                            farmer.publicCode,
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.textSecondary),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.phone_outlined, size: 13, color: AppColors.textMuted),
                        const SizedBox(width: 4),
                        Text(
                          farmer.phone != null && farmer.phone!.isNotEmpty ? '+967 ${farmer.phone}' : 'بدون هاتف',
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                        ),
                        const SizedBox(width: 12),
                        const Icon(Icons.landscape_outlined, size: 13, color: AppColors.agriculturalGreen),
                        const SizedBox(width: 4),
                        Text(
                          '$farmsCount ${farmsCount == 1 ? "أرض" : "أراضي"}',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.agriculturalGreen),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const Icon(Icons.chevron_left, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

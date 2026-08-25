import 'package:flutter/material.dart';
import '../../core/api/app_bootstrap_repository.dart';
import '../../core/api/well_management_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/top_well_selector.dart';
import 'fuel_inventory_screen.dart';
import 'pricing_tariff_screen.dart';
import 'pumps_management_screen.dart';
import 'well_settings_screen.dart';

/// المدخل المركزي لإدارة البئر والمعدات والوقود والتسعير (UX-15 / القرار 460)
class WellManagementHubScreen extends StatefulWidget {
  final String wellName;
  final String? wellId;
  final List<WellSummary> wells;
  final ValueChanged<WellSummary>? onWellChanged;
  final WellManagementRepository? repository;

  const WellManagementHubScreen({
    super.key,
    required this.wellName,
    this.wellId,
    this.wells = const [],
    this.onWellChanged,
    this.repository,
  });

  @override
  State<WellManagementHubScreen> createState() => _WellManagementHubScreenState();
}

class _WellManagementHubScreenState extends State<WellManagementHubScreen> {
  late WellManagementRepository _repo;
  String? _activeWellId;
  String _activeWellName = '';

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? WellManagementRepository();
    _activeWellName = widget.wellName;
    _activeWellId = widget.wellId ?? (widget.wells.isNotEmpty ? widget.wells.first.id : 'well-1');
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
          subtitle: 'إدارة البئر والمعدات والتشغيل',
          onWellChanged: (newWell) {
            setState(() {
              _activeWellId = newWell.id;
              _activeWellName = newWell.name;
            });
            if (widget.onWellChanged != null) {
              widget.onWellChanged!(newWell);
            }
          },
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // كرت البئر الحالي
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
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.settings_suggest, color: Colors.white, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _activeWellName,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'لوحة التحكم الإدارية والفنية للبئر',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            const Text(
              'أقسام الإدارة والتشغيل:',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 12),

            // 1. بيانات البئر الأساسية
            _buildSectionCard(
              title: 'بيانات وإعدادات البئر',
              subtitle: 'الاسم، الموقع، العمق، الحالة التشغيلية',
              icon: Icons.edit_note_outlined,
              color: AppColors.deepBlue,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => WellSettingsScreen(
                      wellName: _activeWellName,
                      wellId: _activeWellId,
                      wells: widget.wells,
                      repository: _repo,
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 12),

            // 2. إدارة المضخات
            _buildSectionCard(
              title: 'المضخات والمعدات',
              subtitle: 'المواصفات الفنية، القدرة، الحالات والصيانة',
              icon: Icons.speed_outlined,
              color: AppColors.waterBlue,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PumpsManagementScreen(
                      wellName: _activeWellName,
                      wellId: _activeWellId,
                      wells: widget.wells,
                      repository: _repo,
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 12),

            // 3. تعرفة الطاقة والأسعار
            _buildSectionCard(
              title: 'تعرفة الطاقة والأسعار التاريخية',
              subtitle: 'سعر الساعة للطاقة الشمسية وديزل البئر وديزل المزارع',
              icon: Icons.price_change_outlined,
              color: AppColors.agriculturalGreen,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PricingTariffScreen(
                      wellName: _activeWellName,
                      wellId: _activeWellId,
                      wells: widget.wells,
                      repository: _repo,
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 12),

            // 4. إدارة الوقود والخزانات
            _buildSectionCard(
              title: 'الوقود والخزانات والجرد',
              subtitle: 'رصيد الديزل، تسجيل الشراء، الجرد والتسويات',
              icon: Icons.local_gas_station_outlined,
              color: Colors.deepOrange,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => FuelInventoryScreen(
                      wellName: _activeWellName,
                      wellId: _activeWellId,
                      wells: widget.wells,
                      repository: _repo,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
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
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 16, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

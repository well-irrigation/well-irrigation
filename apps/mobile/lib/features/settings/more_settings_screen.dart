import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/account_repository.dart';
import '../../core/api/app_bootstrap_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/top_well_selector.dart';
import 'app_settings_screen.dart';
import 'device_sync_screen.dart';
import 'help_support_screen.dart';
import 'profile_security_screen.dart';
import 'team_permissions_screen.dart';

/// صفحة المزيد والقائمة الشاملة للحساب والإعدادات (UX-16A / القرار 527 / ق-101)
class MoreSettingsScreen extends StatefulWidget {
  const MoreSettingsScreen({
    required this.wellName,
    this.wellId,
    this.wells = const [],
    this.onWellChanged,
    this.onLogout,
    this.repository,
    super.key,
  });

  final String wellName;
  final String? wellId;
  final List<WellSummary> wells;
  final ValueChanged<WellSummary>? onWellChanged;
  final VoidCallback? onLogout;
  final AccountRepository? repository;

  @override
  State<MoreSettingsScreen> createState() => _MoreSettingsScreenState();
}

class _MoreSettingsScreenState extends State<MoreSettingsScreen> {
  late AccountRepository _repo;
  UserProfileData? _profile;
  bool _isLoading = true;
  String? _activeWellId;
  String _activeWellName = '';

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? AccountRepository();
    _activeWellName = widget.wellName;
    _activeWellId = widget.wellId ?? (widget.wells.isNotEmpty ? widget.wells.first.id : 'well-1');
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() => _isLoading = true);
    final data = await _repo.fetchUserProfile();
    if (mounted) {
      setState(() {
        _profile = data;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleSafeLogout() async {
    HapticFeedback.mediumImpact();
    final pendingCount = await _repo.checkPendingOperationsBeforeLogout();

    if (!mounted) return;

    if (pendingCount > 0) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppColors.warning, size: 28),
              SizedBox(width: 8),
              Text('تنبيه أمان البيانات', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'يوجد $pendingCount عملية غير متزامنة مع السحابة محفوظة محلياً على هذا الهاتف (القرار 578).',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'تسجيل الخروج سيحافظ على هذه العمليات مشفرة على الجهاز، لكن يُفضل الاتصال بالإنترنت ومزامنتها أولاً.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('إلغاء والمزامنة أولاً'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.of(ctx).pop();
                if (widget.onLogout != null) {
                  widget.onLogout!();
                }
              },
              child: const Text('تأكيد الخروج الآمن'),
            ),
          ],
        ),
      );
    } else {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('تسجيل الخروج', style: TextStyle(fontWeight: FontWeight.bold)),
          content: const Text('هل أنت متأكد من رغبتك في تسجيل الخروج من التطبيق؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.of(ctx).pop();
                if (widget.onLogout != null) {
                  widget.onLogout!();
                }
              },
              child: const Text('تسجيل الخروج'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveWell = widget.wells.isNotEmpty
        ? widget.wells.firstWhere((w) => w.id == _activeWellId, orElse: () => widget.wells.first)
        : WellSummary(
            id: _activeWellId ?? 'well-1',
            tenantId: 'tenant-1',
            name: _activeWellName,
            status: 'active',
            roles: const ['owner'],
          );

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: TopWellSelector(
          wells: widget.wells.isNotEmpty ? widget.wells : [effectiveWell],
          activeWell: effectiveWell,
          subtitle: 'المزيد • الحساب والإعدادات',
          onWellChanged: (w) {
            setState(() {
              _activeWellId = w.id;
              _activeWellName = w.name;
            });
            if (widget.onWellChanged != null) widget.onWellChanged!(w);
          },
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 1. رأس الحساب (القرار 528)
                _buildAccountHeader(),
                const SizedBox(height: 16),

                // 2. بطاقات الأقسام (القرار 527)
                _buildSectionHeader('إدارة الحساب والأمان'),
                _buildMenuItem(
                  icon: Icons.person_outline,
                  iconColor: AppColors.waterBlue,
                  title: 'حسابي والملف الشخصي',
                  subtitle: 'تعديل الاسم، إدارة الهاتف المعتمد، والأمان',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ProfileSecurityScreen(
                          profile: _profile!,
                          repository: _repo,
                          onProfileUpdated: _loadProfile,
                        ),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 12),
                _buildSectionHeader('إدارة الفريق والبئر'),
                _buildMenuItem(
                  icon: Icons.people_outline,
                  iconColor: AppColors.agriculturalGreen,
                  title: 'الفريق والصلاحيات',
                  subtitle: 'إدارة المشغلين والمحاسبين وتعيينات البئر',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => TeamPermissionsScreen(
                          wellId: _activeWellId ?? 'well-1',
                          wellName: _activeWellName,
                          repository: _repo,
                        ),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 12),
                _buildSectionHeader('الجهاز والتشغيل الميداني'),
                _buildMenuItem(
                  icon: Icons.sync_rounded,
                  iconColor: const Color(0xFF0284C7),
                  title: 'الجهاز والمزامنة',
                  subtitle: 'صحة التخزين المحلي، العمليات المعلقة، وتحديث البيانات',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DeviceSyncScreen(repository: _repo),
                      ),
                    );
                  },
                ),
                _buildMenuItem(
                  icon: Icons.tune,
                  iconColor: const Color(0xFF6366F1),
                  title: 'تفضيلات التطبيق والطباعة',
                  subtitle: 'المظهر الميداني، إعدادات الطابعة الحرارية والإشعارات',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => AppSettingsScreen(repository: _repo),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 12),
                _buildSectionHeader('المساعدة والمعلومات القانونية'),
                _buildMenuItem(
                  icon: Icons.help_outline,
                  iconColor: AppColors.warning,
                  title: 'المساعدة والدعم وعن التطبيق',
                  subtitle: 'أرقام الدعم الفني، سياق التشخيص، الشروط والخصوصية',
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const HelpSupportScreen(),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 24),
                // 3. زر تسجيل الخروج الآمن (القرار 578)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.error.withValues(alpha: 0.1),
                    foregroundColor: AppColors.error,
                    elevation: 0,
                    side: const BorderSide(color: AppColors.error),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.logout),
                  label: const Text('تسجيل الخروج من الحساب', style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: _handleSafeLogout,
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }

  Widget _buildAccountHeader() {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: AppColors.waterBlue.withValues(alpha: 0.15),
              child: const Icon(Icons.person, color: AppColors.waterBlue, size: 32),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _profile?.fullName ?? 'محمد عبدالله الشامي',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.phone_android, size: 14, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Text(
                        _profile?.phone.isNotEmpty == true ? _profile!.phone : '777123456',
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: (_profile?.rolesSummary ?? ['مالك بئر الخير الرئيسي']).map((role) {
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.agriculturalGreen.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppColors.agriculturalGreen.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          role,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.agriculturalGreen,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, right: 4),
      child: Text(
        title,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _buildMenuItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: iconColor.withValues(alpha: 0.1),
          child: Icon(icon, color: iconColor),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: AppColors.textSecondary),
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
      ),
    );
  }
}

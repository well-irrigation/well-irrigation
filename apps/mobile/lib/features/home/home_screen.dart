import 'package:flutter/material.dart';
import '../../core/api/app_bootstrap_repository.dart';
import '../../core/identity/app_identity.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/top_well_selector.dart';

/// الشاشة الرئيسية الموحدة للمالك وحسابات الأدوار المتعددة (UX-05 / UX-06 / UX-15 / ق-87)
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    required this.identity,
    this.onWellChanged,
    this.onNavigateToOperations,
    this.onNavigateToHistory,
    this.onNavigateToFarmers,
    this.onNavigateToExpenses,
    this.onNavigateToPartners,
    this.onNavigateToWellManagement,
    this.onNavigateToReports,
    this.onNavigateToMoreSettings,
    this.onLogout,
    super.key,
  });

  final AppIdentity identity;
  final ValueChanged<WellSummary>? onWellChanged;
  final VoidCallback? onNavigateToOperations;
  final VoidCallback? onNavigateToHistory;
  final VoidCallback? onNavigateToFarmers;
  final VoidCallback? onNavigateToExpenses;
  final VoidCallback? onNavigateToPartners;
  final VoidCallback? onNavigateToWellManagement;
  final VoidCallback? onNavigateToReports;
  final VoidCallback? onNavigateToMoreSettings;
  final VoidCallback? onLogout;

  @override
  Widget build(BuildContext context) {
    final activeWell = identity.activeWell;

    // الاسم كما سجّله الخادم. غيابه يُترك فراغًا ولا يُملأ بلقب عام يُقرأ
    // كأنه اسم المستخدم (ق-113).
    final subtitle = identity.displayName.isEmpty
        ? 'الرئيسية'
        : 'الرئيسية • ${identity.displayName}';

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        centerTitle: false,
        title: TopWellSelector(
          wells: identity.wells,
          activeWell: activeWell,
          subtitle: subtitle,
          onWellChanged: (newWell) {
            if (onWellChanged != null) {
              onWellChanged!(newWell);
            }
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: AppColors.textSecondary),
            tooltip: 'الإعدادات والمزيد',
            onPressed: onNavigateToMoreSettings,
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: AppColors.textSecondary),
            tooltip: 'تسجيل الخروج',
            onPressed: onLogout,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // كرت البئر الحالي المعتمد
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.deepBlue, AppColors.waterBlue],
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.deepBlue.withValues(alpha: 0.2),
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
                        const Text(
                          'البئر النشط الحالي',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.agriculturalGreen,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'جاهز للتشغيل',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      activeWell.name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'الحالة: ${activeWell.status == "active" ? "نشط ومتاح للعمليات" : "غير نشط"}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              const Text(
                'الخدمات والأقسام الرئيسية',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepBlue,
                ),
              ),
              const SizedBox(height: 14),

              // شبكة كروت الوصول السريع للخدمات (UX-07 / UX-13 / UX-14 / UX-15 / UX-16A)
              Row(
                children: [
                  Expanded(
                    child: _ServiceCard(
                      icon: Icons.play_circle_filled,
                      title: 'لوحة التشغيل',
                      subtitle: 'بدء وإيقاف العداد المباشر',
                      color: AppColors.waterBlue,
                      onTap: onNavigateToOperations,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _ServiceCard(
                      icon: Icons.history,
                      title: 'سجل الجلسات',
                      subtitle: 'تاريخ السقي والتفاصيل',
                      color: AppColors.deepBlue,
                      onTap: onNavigateToHistory,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _ServiceCard(
                      icon: Icons.people_alt,
                      title: 'المزارعون والأراضي',
                      subtitle: 'دليل المزارعين والأراضي',
                      color: AppColors.agriculturalGreen,
                      onTap: onNavigateToFarmers,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _ServiceCard(
                      icon: Icons.receipt_long,
                      title: 'المصروفات والمالية',
                      subtitle: 'تسجيل واعتماد المصروفات',
                      color: Colors.deepOrange,
                      onTap: onNavigateToExpenses,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _ServiceCard(
                      icon: Icons.handshake,
                      title: 'الشركاء والأرباح',
                      subtitle: 'النسب ودورات التوزيع',
                      color: AppColors.warning,
                      onTap: onNavigateToPartners,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _ServiceCard(
                      icon: Icons.settings_suggest,
                      title: 'إدارة البئر والمعدات',
                      subtitle: 'المضخات والوقود والأسعار',
                      color: Colors.indigo,
                      onTap: onNavigateToWellManagement,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _ServiceCard(
                      icon: Icons.analytics_outlined,
                      title: 'التقارير والمؤشرات',
                      subtitle: 'التحصيل والمصروفات والوقود',
                      color: Colors.teal,
                      onTap: onNavigateToReports,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _ServiceCard(
                      icon: Icons.more_horiz_rounded,
                      title: 'المزيد والإعدادات',
                      subtitle: 'الحساب، الفريق والمزامنة',
                      color: AppColors.waterBlue,
                      onTap: onNavigateToMoreSettings,
                    ),
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

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: AppColors.deepBlue,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

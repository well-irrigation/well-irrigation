import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';

/// شريط التنقل السفلي المفرغ بزر إجراء عائم وسطي (UX-15 / ق-127)
///
/// يوفّر 4 وجهات رئيسية متوازنة تفصل بينها فجوة مقوسة (Notch)
/// للزر العائم الخاص ببدء التشغيل السريع، مع مساحات لمس معيارية
/// وتغذية حسية، وتوزيع متجاوب متكافئ يمنع الفيض على أي شاشة.
class HomeBottomNavBar extends StatelessWidget {
  const HomeBottomNavBar({
    this.selectedIndex = 0,
    this.isOperatorMode = false,
    this.onNavigateToHome,
    this.onNavigateToOperations,
    this.onNavigateToHistory,
    this.onNavigateToReports,
    this.onNavigateToMoreSettings,
    super.key,
  });

  final int selectedIndex;
  final bool isOperatorMode;
  final VoidCallback? onNavigateToHome;
  final VoidCallback? onNavigateToOperations;
  final VoidCallback? onNavigateToHistory;
  final VoidCallback? onNavigateToReports;
  final VoidCallback? onNavigateToMoreSettings;

  @override
  Widget build(BuildContext context) {
    return BottomAppBar(
      shape: const CircularNotchedRectangle(),
      notchMargin: 6.0,
      color: Colors.white,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      padding: EdgeInsets.zero,
      height: 62,
      child: Row(
        children: [
          // الجهة اليمنى (في RTL): الرئيسية والعمليات
          Expanded(
            child: _NavBarItem(
              icon: Icons.home_rounded,
              label: 'الرئيسية',
              isSelected: selectedIndex == 0,
              onTap: onNavigateToHome,
            ),
          ),
          Expanded(
            child: _NavBarItem(
              icon: Icons.water_drop_outlined,
              label: 'العمليات',
              isSelected: selectedIndex == 1,
              onTap: onNavigateToOperations,
            ),
          ),
          // فجوة الزر العائم الوسطي (Notch spacing)
          const SizedBox(width: 48),
          // الجهة اليسرى (في RTL): التقارير والمزيد
          Expanded(
            child: _NavBarItem(
              icon: isOperatorMode
                  ? Icons.history_rounded
                  : Icons.analytics_outlined,
              label: isOperatorMode ? 'سجل الجلسات' : 'التقارير',
              isSelected: selectedIndex == 2,
              onTap: isOperatorMode ? onNavigateToHistory : onNavigateToReports,
            ),
          ),
          Expanded(
            child: _NavBarItem(
              icon: Icons.menu_rounded,
              label: 'المزيد',
              isSelected: selectedIndex == 3,
              onTap: onNavigateToMoreSettings,
            ),
          ),
        ],
      ),
    );
  }
}

class _NavBarItem extends StatelessWidget {
  const _NavBarItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? AppColors.waterBlue : AppColors.textSecondary;

    return InkWell(
      onTap: () {
        if (onTap != null) {
          HapticFeedback.lightImpact();
          onTap!();
        }
      },
      borderRadius: BorderRadius.circular(16),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: color,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

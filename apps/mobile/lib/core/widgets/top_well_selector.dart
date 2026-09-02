import 'package:flutter/material.dart';
import '../api/app_bootstrap_repository.dart';
import '../theme/app_colors.dart';

/// مكوّن مبدل الآبار في الشريط العلوي (Top Well Selector - UX-05 / ق-87)
///
/// يدعم:
/// - إظهار اسم البئر الحالي النشط في الشريط العلوي.
/// - إظهار سهم التبديل عند امتلاك المستخدم لأكثر من بئر.
/// - فتح قائمة سفلية سريعة للتبديل بين الآبار المتاحة وتحديث السياق لحظياً.
///
/// [activeWell] بئر حقيقي إلزامي من `AppIdentity`: كان يُقبل `null` فيُطبع
/// «لا بئر مختار»، وذلك النصّ لم يكن يظهر إلا حين لفّق أحدهم بئرًا خارج آبار
/// المستخدم. البئر النشط الآن من العقد وحده، فلا حالة «بلا بئر» تُعرض هنا.
class TopWellSelector extends StatelessWidget {
  const TopWellSelector({
    required this.wells,
    required this.activeWell,
    required this.onWellChanged,
    this.subtitle,
    super.key,
  });

  final List<WellSummary> wells;
  final WellSummary activeWell;
  final ValueChanged<WellSummary> onWellChanged;
  final String? subtitle;

  void _openWellPickerSheet(BuildContext context) {
    if (wells.length <= 1) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Material(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [

              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text(
                'التبديل بين الآبار المتاحة',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepBlue,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'اختر البئر الذي تريد إدارته وتشغيله الآن',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: wells.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, index) {

                    final well = wells[index];
                    final isSelected = activeWell.id == well.id;

                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      leading: CircleAvatar(
                        radius: 18,
                        backgroundColor: isSelected
                            ? AppColors.waterBlue
                            : AppColors.surface,
                        child: Icon(
                          Icons.water_drop,
                          size: 20,
                          color: isSelected ? Colors.white : AppColors.deepBlue,
                        ),
                      ),
                      title: Text(
                        well.name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected
                              ? AppColors.waterBlue
                              : AppColors.deepBlue,
                        ),
                      ),
                      subtitle: Text(
                        well.roles.map((r) {
                          switch (r) {
                            case 'owner':
                              return 'مالك';
                            case 'operator':
                              return 'مشغل';
                            case 'partner':
                              return 'شريك';
                            default:
                              return r;
                          }
                        }).join(' • '),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted,
                        ),
                      ),
                      trailing: isSelected
                          ? const Icon(
                              Icons.check_circle,
                              color: AppColors.waterBlue,
                              size: 20,
                            )
                          : null,
                      onTap: () {
                        onWellChanged(well);
                        Navigator.of(sheetContext).pop();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}


  @override
  Widget build(BuildContext context) {
    final hasMultipleWells = wells.length > 1;
    final displayName = activeWell.name;

    return InkWell(
      onTap: hasMultipleWells ? () => _openWellPickerSheet(context) : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.deepBlue,
                      ),
                    ),
                    if (hasMultipleWells) ...[
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.keyboard_arrow_down,
                        size: 18,
                        color: AppColors.waterBlue,
                      ),
                    ],
                  ],
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

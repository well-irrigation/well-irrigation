import 'package:flutter/material.dart';

import '../../../core/api/operations_repository.dart';
import '../../../core/api/well_management_repository.dart';
import '../../../core/session/session_business_state.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/currency_utils.dart';
import '../../../core/utils/tafqeet_utils.dart';

/// مكوّن اختيار مصدر الطاقة المدمج (Q-129 / UX-08)
///
/// يستبدل البطاقات الثلاث الكبيرة بمحدد مدمج واحد،
/// وعند النقر عليه تظهر قائمة المصادر مع أسعارها وتفقيطها.
class CompactEnergySelector extends StatelessWidget {
  const CompactEnergySelector({
    required this.selectedSource,
    required this.priceRules,
    required this.onSourceSelected,
    this.enabled = true,
    super.key,
  });

  final String? selectedSource;
  final List<PriceRuleModel> priceRules;
  final ValueChanged<String> onSourceSelected;
  final bool enabled;

  PriceRuleModel? _ruleFor(String code) {
    for (final rule in priceRules) {
      if (rule.energySource == code) return rule;
    }
    return null;
  }

  void _openSourcePicker(BuildContext context) {
    if (!enabled) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Material(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Text(
                  'اختيار مصدر الطاقة والتسعيرة',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.deepBlue,
                  ),
                ),
                const SizedBox(height: 16),
                ...kSessionEnergySources.map((code) {
                  final isSelected = selectedSource == code;
                  final rate = _ruleFor(code)?.hourlyRateMinor;
                  final glyph = energySourceGlyph(code);
                  final label = energySourceLabel(code);

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: isSelected
                          ? AppColors.waterBlue.withValues(alpha: 0.08)
                          : AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          Navigator.of(sheetContext).pop();
                          onSourceSelected(code);
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.waterBlue
                                  : AppColors.border,
                              width: isSelected ? 1.5 : 1,
                            ),
                          ),
                          child: ListTile(
                            leading: Text(
                              glyph,
                              style: const TextStyle(fontSize: 22),
                            ),
                            title: Text(
                              label,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: AppColors.deepBlue,
                              ),
                            ),
                            subtitle: rate == null
                                ? const Text(
                                    'التسعيرة غير متوفرة',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.warning,
                                    ),
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${CurrencyUtils.formatAmount(rate)} ريال / ساعة',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.textSecondary,
                                        ),
                                      ),
                                      Text(
                                        Tafqeet.format(rate),
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: AppColors.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                            trailing: isSelected
                                ? const Icon(
                                    Icons.check_circle,
                                    color: AppColors.waterBlue,
                                    size: 20,
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final code = selectedSource;
    final rate = code != null ? _ruleFor(code)?.hourlyRateMinor : null;
    final glyph = code != null ? energySourceGlyph(code) : '';
    final label = code != null ? energySourceLabel(code) : '';

    final String displayText;
    final Color textColor;
    if (code == null) {
      displayText = 'اختر مصدر الطاقة...';
      textColor = AppColors.textMuted;
    } else {
      final rateText = rate == null
          ? 'التسعيرة غير متوفرة'
          : '${CurrencyUtils.formatAmount(rate)} ريال / ساعة';
      displayText = '$glyph $label — $rateText';
      textColor = AppColors.deepBlue;
    }

    return InkWell(
      key: const Key('compact_energy_selector'),
      onTap: enabled ? () => _openSourcePicker(context) : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: enabled ? Colors.white : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: code != null ? AppColors.waterBlue : AppColors.border,
            width: code != null ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    displayText,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (rate != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      Tafqeet.format(rate),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Icons.arrow_drop_down,
              color: enabled ? AppColors.deepBlue : AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

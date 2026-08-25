import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../utils/currency_utils.dart';
import '../utils/tafqeet_utils.dart';

/// مكون عرض المبالغ المالية بالأرقام المنسقة مع التفقيط النصي الأنيق
class CurrencyDisplay extends StatelessWidget {
  const CurrencyDisplay({
    required this.amount,
    this.unit = 'ريال يمني',
    this.showTafqeet = true,
    this.amountStyle,
    this.unitStyle,
    this.tafqeetStyle,
    this.alignment = CrossAxisAlignment.start,
    super.key,
  });

  final int amount;
  final String unit;
  final bool showTafqeet;
  final TextStyle? amountStyle;
  final TextStyle? unitStyle;
  final TextStyle? tafqeetStyle;
  final CrossAxisAlignment alignment;

  @override
  Widget build(BuildContext context) {
    final formattedAmount = CurrencyUtils.formatAmount(amount);
    final tafqeetText = Tafqeet.format(amount);

    return Column(
      crossAxisAlignment: alignment,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(
                formattedAmount,
                style: amountStyle ??
                    const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: AppColors.deepBlue,
                    ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              unit,
              style: unitStyle ??
                  const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.waterBlue,
                  ),
            ),
          ],

        ),
        if (showTafqeet && amount > 0) ...[
          const SizedBox(height: 2),
          Text(
            '($tafqeetText)',
            style: tafqeetStyle ??
                const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
          ),
        ],
      ],
    );
  }
}

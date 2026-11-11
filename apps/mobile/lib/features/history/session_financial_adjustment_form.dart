import 'package:flutter/material.dart';

import '../../core/utils/currency_utils.dart';
import '../../core/utils/digit_utils.dart';

final _plainAmount = RegExp(r'^[0-9]+$');
final _westernGrouping = RegExp(r'^[0-9]{1,3}(,[0-9]{3})+$');
final _arabicGrouping = RegExp(r'^[0-9]{1,3}(٬[0-9]{3})+$');

/// Whole YER. Validate the entire input before removing grouping separators.
int? parseSessionFinancialAmount(String text) {
  final normalized = normalizeArabicDigits(text);
  if (_plainAmount.hasMatch(normalized)) return int.tryParse(normalized);
  if (_westernGrouping.hasMatch(normalized)) {
    return int.tryParse(normalized.replaceAll(',', ''));
  }
  if (_arabicGrouping.hasMatch(normalized)) {
    return int.tryParse(normalized.replaceAll('٬', ''));
  }
  return null;
}

class SessionFinancialAmountText extends StatelessWidget {
  const SessionFinancialAmountText(this.amount, {super.key});

  final int? amount;

  @override
  Widget build(BuildContext context) => Text(
    amount == null
        ? 'غير متاح'
        : '${CurrencyUtils.formatAmount(amount!)} ريال يمني',
    softWrap: true,
  );
}

class SessionFinancialAdjustmentForm extends StatelessWidget {
  const SessionFinancialAdjustmentForm({
    required this.formKey,
    required this.amount,
    required this.reason,
    required this.enabled,
    required this.currentAmount,
    required this.allowSameAmount,
    required this.onReview,
    super.key,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController amount;
  final TextEditingController reason;
  final bool enabled;
  final int currentAmount;
  final bool allowSameAmount;
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) => Form(
    key: formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: const ValueKey('financial_adjustment_amount'),
          controller: amount,
          enabled: enabled,
          keyboardType: TextInputType.number,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(
            labelText: 'المبلغ الجديد',
            suffixText: 'ريال يمني',
          ),
          validator: (text) {
            final parsed = parseSessionFinancialAmount(text ?? '');
            if (parsed == null) return 'أدخل مبلغًا صحيحًا بالريال اليمني.';
            if (!allowSameAmount && parsed == currentAmount) {
              return 'أدخل مبلغًا مختلفًا عن المبلغ الحالي.';
            }
            return null;
          },
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const ValueKey('financial_adjustment_reason'),
          controller: reason,
          enabled: enabled,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'سبب تعديل المبلغ'),
          validator: (text) =>
              (text ?? '').trim().isEmpty ? 'سبب تعديل المبلغ مطلوب.' : null,
        ),
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('financial_adjustment_review'),
          onPressed: enabled ? onReview : null,
          child: const Text('مراجعة التعديل'),
        ),
      ],
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../utils/currency_utils.dart';
import '../utils/digit_utils.dart';
import '../utils/tafqeet_utils.dart';

/// حقل إدخال المبالغ والأسعار المالية المتطور
///
/// الميزات:
/// 1. فواصل الآلاف اللحظية أثناء الكتابة (3,500).
/// 2. توحيد الأرقام العربية إلى الإنجليزية لحظياً.
/// 3. شريط تفقيط عربي مالي لحظي يظهر تحت الحقل مباشرة (ثلاثة آلاف وخمسمائة ريال).
class CurrencyTextFormField extends StatefulWidget {
  const CurrencyTextFormField({
    required this.controller,
    this.hintText = 'أدخل المبلغ بالريال',
    this.labelText,
    this.unitSuffix = 'ريال',
    this.onChanged,
    this.validator,
    this.autofocus = false,
    this.enabled = true,
    super.key,
  });

  final TextEditingController controller;
  final String hintText;
  final String? labelText;
  final String unitSuffix;
  final ValueChanged<int>? onChanged;
  final FormFieldValidator<String>? validator;
  final bool autofocus;
  final bool enabled;

  @override
  State<CurrencyTextFormField> createState() => _CurrencyTextFormFieldState();
}

class _CurrencyTextFormFieldState extends State<CurrencyTextFormField> {
  int _currentAmount = 0;

  @override
  void initState() {
    super.initState();
    _currentAmount = CurrencyUtils.parseRawInt(widget.controller.text);
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final newAmount = CurrencyUtils.parseRawInt(widget.controller.text);
    if (newAmount != _currentAmount) {
      setState(() {
        _currentAmount = newAmount;
      });
      widget.onChanged?.call(newAmount);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasAmount = _currentAmount > 0;
    final tafqeetText = hasAmount ? Tafqeet.format(_currentAmount) : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.labelText != null) ...[
          Text(
            widget.labelText!,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
        ],
        TextFormField(
          controller: widget.controller,
          enabled: widget.enabled,
          autofocus: widget.autofocus,
          keyboardType: TextInputType.number,
          inputFormatters: [
            const ArabicToEnglishDigitsFormatter(),
            const ThousandsSeparatorInputFormatter(),
            LengthLimitingTextInputFormatter(14),
          ],
          validator: widget.validator,
          decoration: InputDecoration(
            hintText: widget.hintText,
            hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 14),
            suffixText: widget.unitSuffix,
            suffixStyle: const TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.deepBlue,
              fontSize: 13,
            ),
            filled: true,
            fillColor: AppColors.surface,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppColors.borderFocused, width: 1.5),
            ),
          ),
        ),
        if (hasAmount) ...[
          const SizedBox(height: 6),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.waterBlue.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppColors.waterBlue.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.edit_note,
                  size: 16,
                  color: AppColors.waterBlue,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    tafqeetText,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: AppColors.deepBlue,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

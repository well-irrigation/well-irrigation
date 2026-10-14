import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/currency_utils.dart';
import '../../../core/widgets/currency_display.dart';
import '../../../core/widgets/currency_text_form_field.dart';
import 'session_completion_result.dart';

/// طلب دفعة مستقل؛ قبول الخادم وحده يثبت السداد والسند.
class PaymentReceiptDialog extends StatefulWidget {
  const PaymentReceiptDialog({
    required this.wellName,
    required this.operatorName,
    required this.farmerName,
    required this.farmName,
    required this.energySource,
    required this.hourlyRateYER,
    required this.billableSeconds,
    this.actualSeconds,
    this.amountApproved = false,
    required this.totalAmountYER,
    required this.onConfirmPayment,
    super.key,
  });

  final String wellName;
  final String operatorName;
  final String farmerName;
  final String farmName;
  final String energySource;
  final int? hourlyRateYER;
  final int billableSeconds;

  /// مدة التنفيذ الفعلية إن وفرها المستدعي من حصيلة المقاطع نفسها
  /// (`wallClockSeconds` — كامل الخط الزمني المسجَّل قبل الإنهاء).
  /// غيابها يعني أنها غير متوفرة فلا تُعرض ولا تُخترع محليًا
  /// (ق-131 البند 7). لا يدخل في أي حساب مالي.
  final int? actualSeconds;
  final bool amountApproved;
  final int totalAmountYER;
  final Future<void> Function({
    required int paidAmountYER,
    required String paymentMethod,
    required bool isFullySettled,
  })
  onConfirmPayment;

  @override
  State<PaymentReceiptDialog> createState() => _PaymentReceiptDialogState();
}

class _PaymentReceiptDialogState extends State<PaymentReceiptDialog> {
  final _paidController = TextEditingController();
  String _paymentMethod = 'cash';
  bool _isSaving = false;
  bool _showThermalPreview = false;

  @override
  void initState() {
    super.initState();
    // الدفعة الافتراضية كامل المبلغ
    _paidController.text = CurrencyUtils.formatAmount(widget.totalAmountYER);
  }

  @override
  void dispose() {
    _paidController.dispose();
    super.dispose();
  }

  int get _paidAmount {
    return CurrencyUtils.parseRawInt(_paidController.text);
  }

  int get _remainingAmount => widget.totalAmountYER - _paidAmount;

  String _buildReceiptText(int hourlyRate) =>
      'ملخص طلب دفعة — ليس سند قبض\n'
      'المزارع: ${widget.farmerName}\n'
      'الأرض: ${widget.farmName}\n'
      'المبلغ المطلوب تسجيله: ${CurrencyUtils.formatAmount(_paidAmount)} ريال\n'
      'طريقة الدفع: ${SessionCompletionResult.methodLabel(_paymentMethod)}\n'
      'لا يثبت السداد أو التخصيص قبل قبول الخادم';

  void _handlePrint() {
    // لا طباعة مُدَّعاة: لا تكامل بلوتوث في هذا الإصدار، وكان التأخير
    // 600ms يُعرض كنجاح إرسال إلى طابعة غير موجودة (ق-113 / م-41D4).
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'الطباعة الحرارية غير متاحة في هذا الإصدار — لم يُرسل أمر طباعة',
        ),
        backgroundColor: AppColors.warning,
      ),
    );
  }

  Future<void> _handleConfirm() async {
    if (_isSaving || _paidAmount <= 0) return;
    setState(() => _isSaving = true);
    try {
      await widget.onConfirmPayment(
        paidAmountYER: _paidAmount,
        paymentMethod: _paymentMethod,
        isFullySettled: _remainingAmount <= 0,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطأ أثناء الحفظ: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  /// سطر مدة بعنوان صريح: تسمية الفعلي والمفوتر لا تُشتبه (ق-131 البند 7)
  /// — ولا يُسمى المفوتر أبدًا «مدة السقي الفعلية».
  Widget _durationRow(String label, int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        Text(
          '$hours س : $minutes د : $secs ث',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hourlyRate = widget.hourlyRateYER;
    final receiptText = hourlyRate == null
        ? null
        : _buildReceiptText(hourlyRate);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // الرأس
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.agriculturalGreen.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.receipt_long,
                      color: AppColors.agriculturalGreen,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'تسجيل دفعة',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'المزارع: ${widget.farmerName}',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'إغلاق طلب الدفعة',
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ],
              ),
              const Divider(height: 12),

              // الحقائق نفسها في شبكة مرنة؛ لا طي ولا حذف للمبالغ أو المدد.
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final stacked =
                        MediaQuery.textScalerOf(context).scale(14) > 20;
                    final width = stacked
                        ? constraints.maxWidth
                        : (constraints.maxWidth - 12) / 2;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        if (widget.actualSeconds != null)
                          SizedBox(
                            width: width,
                            child: _durationRow(
                              'مدة التنفيذ الفعلية:',
                              widget.actualSeconds!,
                            ),
                          ),
                        SizedBox(
                          width: width,
                          child: _durationRow(
                            'الوقت المفوتر:',
                            widget.billableSeconds,
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (hourlyRate == null) ...[
                                const Text(
                                  'طريقة التسعير:',
                                  style: TextStyle(fontSize: 12),
                                ),
                                const Text(
                                  'حسب مقاطع الجلسة',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ] else ...[
                                Text(
                                  'سعر الساعة (${widget.energySource}):',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                CurrencyDisplay(
                                  amount: hourlyRate,
                                  unit: 'ريال / ساعة',
                                  showTafqeet: false,
                                  amountStyle: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  unitStyle: const TextStyle(fontSize: 12),
                                ),
                                Text(
                                  SessionCompletionResult.amountWords(
                                    hourlyRate,
                                  ),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.amountApproved
                                    ? 'المبلغ المعتمد للجلسة:'
                                    : 'المبلغ التقديري للجلسة:',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              CurrencyDisplay(
                                amount: widget.totalAmountYER,
                                unit: 'ريال',
                                showTafqeet: false,
                                amountStyle: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.agriculturalGreen,
                                ),
                              ),
                              Text(
                                SessionCompletionResult.amountWords(
                                  widget.totalAmountYER,
                                ),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),

              // حقل المبلغ المدفوع نقداً
              CurrencyTextFormField(
                controller: _paidController,
                labelText: 'مبلغ الدفعة',
                tafqeetFormatter: SessionCompletionResult.amountWords,
                hintText: 'أدخل المبلغ',
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),

              // طريقة الدفع
              DropdownButtonFormField<String>(
                initialValue: _paymentMethod,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'طريقة الدفع',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                items: const [
                  DropdownMenuItem(value: 'cash', child: Text('نقدًا')),
                  DropdownMenuItem(
                    value: 'bank_transfer',
                    child: Text('حوالة مصرفية'),
                  ),
                  DropdownMenuItem(
                    value: 'mobile_wallet',
                    child: Text('محفظة إلكترونية'),
                  ),
                ],
                onChanged: (val) {
                  if (val != null) {
                    setState(() => _paymentMethod = val);
                  }
                },
              ),
              const SizedBox(height: 8),

              const Text(
                'طلب دفعة — لا يثبت السداد قبل قبول الخادم',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 8),

              // المتبقي
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _remainingAmount > 0
                      ? Colors.amber.shade50
                      : Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _remainingAmount > 0
                        ? Colors.amber.shade300
                        : Colors.green.shade300,
                  ),
                ),
                child: _remainingAmount == 0
                    ? Text(
                        'طلب دفعة مطابق للمبلغ المعروض — لم يُعتمد بعد',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade900,
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            _remainingAmount > 0
                                ? 'الفرق عن المبلغ المعروض (تقديري):'
                                : 'زيادة مقترحة — يحددها الخادم:',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _remainingAmount > 0
                                  ? Colors.amber.shade900
                                  : Colors.green.shade900,
                            ),
                          ),
                          const SizedBox(height: 6),
                          CurrencyDisplay(
                            amount: _remainingAmount.abs(),
                            showTafqeet: false,
                            unit: 'ريال',
                            amountStyle: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _remainingAmount > 0
                                  ? Colors.amber.shade900
                                  : Colors.green.shade900,
                            ),
                          ),
                          Text(
                            SessionCompletionResult.amountWords(
                              _remainingAmount.abs(),
                            ),
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 8),

              // خيار معاينة الفاتورة الحرارية
              if (receiptText != null)
                InkWell(
                  onTap: () => setState(
                    () => _showThermalPreview = !_showThermalPreview,
                  ),
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _showThermalPreview
                                ? Icons.keyboard_arrow_up
                                : Icons.receipt,
                            size: 18,
                            color: AppColors.textSecondary,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _showThermalPreview
                                  ? 'إخفاء ملخص طلب الدفعة'
                                  : 'معاينة ملخص طلب الدفعة',
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

              if (_showThermalPreview && receiptText != null)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Text(
                    receiptText,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.3,
                    ),
                  ),
                ),

              const SizedBox(height: 8),

              // الحفظ والطباعة في صف واحد مع أهداف لمس كاملة.
              LayoutBuilder(
                builder: (context, constraints) {
                  final stacked =
                      MediaQuery.textScalerOf(context).scale(14) > 20;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: stacked
                            ? constraints.maxWidth
                            : constraints.maxWidth - 56,
                        child: ElevatedButton.icon(
                          onPressed: _isSaving || _paidAmount <= 0
                              ? null
                              : _handleConfirm,
                          icon: _isSaving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.check_circle),
                          label: const Text(
                            'حفظ طلب الدفعة',
                            textAlign: TextAlign.center,
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.agriculturalGreen,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(48, 48),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _handlePrint,
                        icon: const Icon(Icons.print_disabled),
                        tooltip: 'طباعة حرارية (غير متاحة)',
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

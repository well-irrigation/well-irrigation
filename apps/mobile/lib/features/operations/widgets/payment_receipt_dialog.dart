import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/printer/receipt_formatter.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/currency_utils.dart';
import '../../../core/utils/tafqeet_utils.dart';
import '../../../core/widgets/currency_display.dart';
import '../../../core/widgets/currency_text_form_field.dart';

/// نافذة سداد الفاتورة وسند القبض والطباعة الحرارية الميدانية (UX-10 / ق-91 / ق-92)
class PaymentReceiptDialog extends StatefulWidget {
  const PaymentReceiptDialog({
    required this.wellName,
    required this.operatorName,
    required this.farmerName,
    required this.farmName,
    required this.energySource,
    required this.hourlyRateYER,
    required this.billableSeconds,
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

  String _buildReceiptText(int hourlyRate) {
    final paidAmount = _paidAmount;
    final remainingAmount = widget.totalAmountYER - paidAmount;
    var text = ReceiptFormatter.formatSessionInvoice(
      wellName: widget.wellName,
      invoiceNumber:
          'INV-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}',
      date: DateTime.now(),
      operatorName: widget.operatorName,
      farmerName: widget.farmerName,
      farmName: widget.farmName,
      energySource: widget.energySource,
      hourlyRateYER: hourlyRate,
      billableSeconds: widget.billableSeconds,
      totalAmountYER: widget.totalAmountYER,
      paidAmountYER: paidAmount,
    );
    text = text.replaceAll(' ريال يمني', ' ريال');
    text = text.replaceFirst(
      '- سعر الساعة: ${CurrencyUtils.formatAmount(hourlyRate)} ريال',
      '- سعر الساعة: ${CurrencyUtils.formatAmount(hourlyRate)} ريال / ساعة\n'
          '- سعر الساعة كتابة: ${Tafqeet.format(hourlyRate)}',
    );
    text = text.replaceFirst(
      'المدفوع نقداً: ${CurrencyUtils.formatAmount(paidAmount)} ريال',
      'المدفوع نقداً: ${CurrencyUtils.formatAmount(paidAmount)} ريال\n'
          'المدفوع كتابة: ${Tafqeet.format(paidAmount)}',
    );
    final originalRemaining =
        'المتبقي: ${CurrencyUtils.formatAmount(remainingAmount)} ريال';
    final truthfulBalance = switch (remainingAmount) {
      > 0 =>
        'المتبقي: ${CurrencyUtils.formatAmount(remainingAmount)} ريال\n'
            'المتبقي كتابة: ${Tafqeet.format(remainingAmount)}',
      0 => 'الحساب: خالص بالكامل',
      _ =>
        'رصيد مقدم: ${CurrencyUtils.formatAmount(remainingAmount.abs())} ريال\n'
            'الرصيد المقدم كتابة: ${Tafqeet.format(remainingAmount.abs())}',
    };
    return text.replaceFirst(originalRemaining, truthfulBalance);
  }

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

  @override
  Widget build(BuildContext context) {
    final hours = widget.billableSeconds ~/ 3600;
    final minutes = (widget.billableSeconds % 3600) ~/ 60;
    final seconds = widget.billableSeconds % 60;

    final hourlyRate = widget.hourlyRateYER;
    final receiptText = hourlyRate == null
        ? null
        : _buildReceiptText(hourlyRate);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        padding: const EdgeInsets.all(20),
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
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.agriculturalGreen.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.receipt_long,
                      color: AppColors.agriculturalGreen,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 12),
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
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ],
              ),
              const Divider(height: 24),

              // تفاصيل المدة والمستحق
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  children: [
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        const Text('مدة السقي الفعلية:'),
                        const SizedBox(width: 8),
                        Text(
                          '$hours س : $minutes د : $seconds ث',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 6),
                    if (hourlyRate == null)
                      const Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          Text('طريقة التسعير:'),
                          Text(
                            'حسب مقاطع الجلسة',
                            textAlign: TextAlign.end,
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      )
                    else
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.start,
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          Text('سعر الساعة (${widget.energySource}):'),
                          CurrencyDisplay(
                            amount: hourlyRate,
                            unit: 'ريال / ساعة',
                            alignment: CrossAxisAlignment.end,
                            amountStyle: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                            tafqeetStyle: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    const Divider(height: 16),
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.start,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        const Text(
                          'المبلغ الإجمالي:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        CurrencyDisplay(
                          amount: widget.totalAmountYER,
                          unit: 'ريال',
                          alignment: CrossAxisAlignment.end,
                          amountStyle: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.agriculturalGreen,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // حقل المبلغ المدفوع نقداً
              CurrencyTextFormField(
                controller: _paidController,
                labelText: 'المبلغ المدفوع الآن (ريال)',
                hintText: 'أدخل المبلغ المحصل',
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),

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
                  DropdownMenuItem(value: 'cash', child: Text('نقداً (كاش)')),
                  DropdownMenuItem(
                    value: 'bank_transfer',
                    child: Text('حوالة / مصرفية'),
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
              const SizedBox(height: 12),

              // المتبقي
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
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
                        'خالص بالكامل ✅',
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
                                ? 'المتبقي (دين على المزارع):'
                                : 'رصيد مقدم:',
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
                            unit: 'ريال',
                            amountStyle: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _remainingAmount > 0
                                  ? Colors.amber.shade900
                                  : Colors.green.shade900,
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 16),

              // خيار معاينة الفاتورة الحرارية
              if (receiptText != null)
                InkWell(
                  onTap: () => setState(
                    () => _showThermalPreview = !_showThermalPreview,
                  ),
                  borderRadius: BorderRadius.circular(8),
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
                                ? 'إخفاء معاينة الإيصال'
                                : 'معاينة قالب الإيصال الحراري (58mm)',
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
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

              const SizedBox(height: 20),

              // أزرار العمليات
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: _handlePrint,
                    icon: const Icon(Icons.print_disabled),
                    label: const Text('طباعة حرارية (غير متاحة)'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
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
                    label: const Text('حفظ واعتماد'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.agriculturalGreen,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
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

import 'package:flutter/material.dart';
import '../../core/api/finance_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/tafqeet_utils.dart';
import '../../core/widgets/currency_display.dart';
import '../../core/widgets/currency_text_form_field.dart';

class PartnerDetailFinancialScreen extends StatefulWidget {
  final String wellId;
  final String partnerId;
  final String wellName;
  final FinanceRepository? repository;

  const PartnerDetailFinancialScreen({
    super.key,
    required this.wellId,
    required this.partnerId,
    this.wellName = 'بئر الخير الرئيسي',
    this.repository,
  });

  @override
  State<PartnerDetailFinancialScreen> createState() => _PartnerDetailFinancialScreenState();
}

class _PartnerDetailFinancialScreenState extends State<PartnerDetailFinancialScreen> {
  late FinanceRepository _repo;
  bool _isLoading = true;
  PartnerFinancialItem? _partner;

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? FinanceRepository();
    _loadPartnerDetail();
  }

  Future<void> _loadPartnerDetail() async {
    setState(() => _isLoading = true);
    try {
      final item = await _repo.fetchPartnerDetailFinancial(
        widget.wellId,
        widget.partnerId,
      );
      if (!mounted) return;
      setState(() {
        _partner = item;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _partner = null;
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحميل حساب الشريك: $e')),
      );
    }
  }

  void _showPayoutDialog() {
    if (_partner == null) return;
    showDialog(
      context: context,
      builder: (dialogCtx) => _PartnerPayoutDialog(
        partner: _partner!,
        repository: _repo,
        onPayoutRecorded: () {
          _loadPartnerDetail();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم تسجيل صرف أرباح الشريك بنجاح ✅')),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('الحساب المالي للشريك')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_partner == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('الحساب المالي للشريك')),
        body: const Center(child: Text('لم يتم العثور على بيانات الشريك')),
      );
    }

    final p = _partner!;

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(
          p.fullName,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
        ),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.agriculturalGreen,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.payments_outlined),
            label: const Text('صرف أرباح للشريك', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            onPressed: p.remainingBalanceYER > 0 ? _showPayoutDialog : null,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ترويسة الشريك ونسبه
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: AppColors.waterBlue.withValues(alpha: 0.12),
                    child: Text(
                      p.fullName.isNotEmpty ? p.fullName.substring(0, 1) : 'ش',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.fullName,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          p.phone.isNotEmpty ? '+967 ${p.phone}' : 'بدون رقم مسجل',
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.deepBlue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        const Text('نسبة الأرباح', style: TextStyle(fontSize: 10, color: AppColors.deepBlue)),
                        Text('${p.profitPercent}%', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.deepBlue)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // كرت الرصيد المتبقي مع التفقيط
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.deepBlue, Color(0xFF1565C0)],
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.deepBlue.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  const Text('المتبقي المستحق للشريك حالياً', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 8),
                  CurrencyDisplay(
                    amount: p.remainingBalanceYER,
                    amountStyle: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
                    unitStyle: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'فقط ${Tafqeet.format(p.remainingBalanceYER)} لا غير.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // تفكيك معادلة المستحق للشريك (Decisions 440-441)
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: AppColors.border),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'تفكيك المستحقات المالية (المعادلة المعتمدة):',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 14),
                    _buildCalcRow('الحصة الإجمالية من الأرباح المعتمدة (+):', p.totalEarningsYER, AppColors.deepBlue),
                    const SizedBox(height: 10),
                    _buildCalcRow('تعويض مصروفات دفعها من جيبه (+):', p.outOfPocketExpensesYER, Colors.purple),
                    const SizedBox(height: 10),
                    _buildCalcRow('استقطاع سقي أرضه الزراعية (-):', p.irrigationDeductionYER, Colors.red),
                    const SizedBox(height: 10),
                    const Divider(height: 1, color: AppColors.surfaceSubtle),
                    const SizedBox(height: 10),
                    _buildCalcRow('صافي المستحق الإجمالي (=):', p.netPayableYER, AppColors.deepBlue, isBold: true),
                    const SizedBox(height: 10),
                    _buildCalcRow('المبالغ المصروفة له مسبقاً (-):', p.totalPaidYER, AppColors.agriculturalGreen),
                    const SizedBox(height: 10),
                    const Divider(height: 1, color: AppColors.surfaceSubtle),
                    const SizedBox(height: 10),
                    _buildCalcRow('المتبقي الصافي للشريك (=):', p.remainingBalanceYER, AppColors.deepBlue, isBold: true),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // بطاقة توجيهية
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: const [
                  Icon(Icons.info_outline, size: 18, color: AppColors.waterBlue),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'تعتمد أرباح الشريك فقط بعد إقرار واعتماد دورات التوزيع من قبل المالك. المصروفات التي يدفعها الشريك تعوض له تلقائياً وتخصم تكاليف سقيه وفق السياسة المعتمدة.',
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCalcRow(String title, int amount, Color color, {bool isBold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            color: isBold ? AppColors.textPrimary : AppColors.textSecondary,
          ),
        ),
        CurrencyDisplay(
          amount: amount,
          showTafqeet: false,
          amountStyle: TextStyle(
            fontSize: isBold ? 14 : 13,
            fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// نافذة صرف أرباح للشريك
class _PartnerPayoutDialog extends StatefulWidget {
  final PartnerFinancialItem partner;
  final FinanceRepository repository;
  final VoidCallback onPayoutRecorded;

  const _PartnerPayoutDialog({
    required this.partner,
    required this.repository,
    required this.onPayoutRecorded,
  });

  @override
  State<_PartnerPayoutDialog> createState() => _PartnerPayoutDialogState();
}

class _PartnerPayoutDialogState extends State<_PartnerPayoutDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _amountController.text = '${widget.partner.remainingBalanceYER}';
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: const [
          Icon(Icons.monetization_on_outlined, color: AppColors.agriculturalGreen),
          SizedBox(width: 8),
          Text('صرف مستحقات الشريك', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'الشريك: ${widget.partner.fullName}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'المستحق المتبقي: ${widget.partner.remainingBalanceYER} ريال',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 14),
            CurrencyTextFormField(
              controller: _amountController,
              labelText: 'مبلغ الصرف (ريال يمني) *',
              hintText: '0',
              validator: (val) {
                if (val == null || val.trim().isEmpty) return 'يرجى إدخال المبلغ';
                final numVal = int.tryParse(val.replaceAll(',', '').trim()) ?? 0;
                if (numVal <= 0) return 'المبلغ يجب أن يكون أكبر من الصفر';
                if (numVal > widget.partner.remainingBalanceYER) {
                  return 'المبلغ يتجاوز المتبقي للشريك';
                }
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('إلغاء', style: TextStyle(color: AppColors.textSecondary)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.agriculturalGreen,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: _isSubmitting
              ? null
              : () async {
                  if (!_formKey.currentState!.validate()) return;
                  final rawAmount = _amountController.text.replaceAll(',', '').trim();
                  final amount = int.parse(rawAmount);

                  setState(() => _isSubmitting = true);
                  final nav = Navigator.of(context);
                  final scaffold = ScaffoldMessenger.of(context);
                  try {
                    await widget.repository.payPartnerDistribution(
                      distributionLineId: widget.partner.id,
                      amountYER: amount,
                    );
                    if (mounted) {
                      nav.pop();
                      widget.onPayoutRecorded();
                    }
                  } catch (e) {
                    setState(() => _isSubmitting = false);
                    if (mounted) {
                      scaffold.showSnackBar(
                        SnackBar(content: Text('حدث خطأ: $e')),
                      );
                    }
                  }
                },
          child: _isSubmitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text('تأكيد الصرف'),
        ),
      ],
    );
  }
}

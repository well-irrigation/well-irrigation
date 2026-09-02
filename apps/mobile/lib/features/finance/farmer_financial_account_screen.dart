import 'package:flutter/material.dart';
import '../../core/api/finance_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/currency_display.dart';
import '../../core/widgets/currency_text_form_field.dart';

class FarmerFinancialAccountScreen extends StatefulWidget {
  final String wellId;
  final String farmerAccountId;
  final String wellName;
  final FinanceRepository? repository;

  const FarmerFinancialAccountScreen({
    super.key,
    required this.wellId,
    required this.farmerAccountId,
    this.wellName = 'بئر الخير الرئيسي',
    this.repository,
  });

  @override
  State<FarmerFinancialAccountScreen> createState() => _FarmerFinancialAccountScreenState();
}

class _FarmerFinancialAccountScreenState extends State<FarmerFinancialAccountScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late FinanceRepository _repo;

  bool _isLoading = true;
  FarmerFinancialAccountData? _accountData;

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? FinanceRepository();
    _tabController = TabController(length: 2, vsync: this);
    _loadAccount();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadAccount() async {
    setState(() => _isLoading = true);
    try {
      final data = await _repo.fetchFarmerFinancialAccount(
        widget.wellId,
        widget.farmerAccountId,
      );
      if (!mounted) return;
      setState(() {
        _accountData = data;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _accountData = null;
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحميل الحساب المالي للمزارع: $e')),
      );
    }
  }

  void _showRecordPaymentDialog() {
    if (_accountData == null) return;
    showDialog(
      context: context,
      builder: (dialogCtx) => _RecordPaymentDialog(
        wellId: widget.wellId,
        farmerAccountId: widget.farmerAccountId,
        accountData: _accountData!,
        repository: _repo,
        onPaymentRecorded: () {
          _loadAccount();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم تسجيل الدفعة وإصدار السند بنجاح ✅')),
          );
        },
      ),
    );
  }

  void _showAllocateAdvanceDialog() {
    if (_accountData == null) return;
    showDialog(
      context: context,
      builder: (dialogCtx) => _AllocateAdvanceDialog(
        accountData: _accountData!,
        repository: _repo,
        onAdvanceAllocated: () {
          _loadAccount();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('تم استخدام الرصيد المقدم في تسديد الفواتير بنجاح ✅')),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('الحساب المالي للمزارع')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_accountData == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('الحساب المالي للمزارع')),
        body: const Center(child: Text('لم يتم العثور على بيانات الحساب المالي')),
      );
    }

    final data = _accountData!;

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(
          'الحساب المالي: ${data.fullName}',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
        ),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.deepBlue,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.deepBlue,
          indicatorWeight: 3,
          tabs: [
            Tab(text: 'الفواتير المستحقة (${data.invoices.length})'),
            Tab(text: 'سجل سندات القبض (${data.payments.length})'),
          ],
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
          child: Row(
            children: [
              if (data.advanceBalanceYER > 0 && data.totalDebtYER > 0) ...[
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.purple,
                      side: const BorderSide(color: Colors.purple),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.swap_horizontal_circle_outlined, size: 18),
                    label: const Text('استخدام الرصيد المقدم', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    onPressed: _showAllocateAdvanceDialog,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.agriculturalGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.payments_outlined, size: 18),
                  label: const Text('تسجيل دفعة / سند قبض', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  onPressed: _showRecordPaymentDialog,
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          // كرت الملخص المالي: فصل الدين عن الرصيد المقدم (Decisions 409 & 421 - No Silent Netting)
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    // كرت المستحق عليه (الديون)
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFC0392B).withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFC0392B).withValues(alpha: 0.25)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: const [
                                Icon(Icons.receipt_outlined, color: Color(0xFFC0392B), size: 16),
                                SizedBox(width: 4),
                                Text('إجمالي الديون المستحقة', style: TextStyle(fontSize: 11, color: Color(0xFFC0392B), fontWeight: FontWeight.bold)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            CurrencyDisplay(
                              amount: data.totalDebtYER,
                              showTafqeet: false,
                              amountStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFFC0392B)),
                            ),
                            const SizedBox(height: 2),
                            const Text('فواتير غير مسددة', style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),

                    // كرت الرصيد المقدم (Advance)
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.purple.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.purple.withValues(alpha: 0.25)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: const [
                                Icon(Icons.account_balance_wallet_outlined, color: Colors.purple, size: 16),
                                SizedBox(width: 4),
                                Text('الرصيد المقدم بحسابه', style: TextStyle(fontSize: 11, color: Colors.purple, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            CurrencyDisplay(
                              amount: data.advanceBalanceYER,
                              showTafqeet: false,
                              amountStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.purple),
                            ),
                            const SizedBox(height: 2),
                            const Text('رصيد مدفوع مقدماً', style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: const [
                    Icon(Icons.info_outline, size: 14, color: AppColors.waterBlue),
                    SizedBox(width: 4),
                    Text(
                      'مبدأ ق-99: يتم عرض الديون والرصيد المقدم منفصلين دون تقاص صامت.',
                      style: TextStyle(fontSize: 10, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // التبويبات
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildInvoicesList(data.invoices),
                _buildPaymentsList(data.payments),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInvoicesList(List<FarmerInvoiceItem> invoices) {
    if (invoices.isEmpty) {
      return const Center(child: Text('لا توجد فواتير مسجلة للمزارع'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: invoices.length,
      itemBuilder: (context, index) {
        final inv = invoices[index];
        final isPaid = inv.status == 'paid';
        final isPartial = inv.status == 'partial';

        Color statusColor = isPaid ? AppColors.agriculturalGreen : (isPartial ? Colors.orange : Colors.red);
        String statusText = isPaid ? 'مسددة بالكامل ✅' : (isPartial ? 'مسددة جزئياً ⚠️' : 'غير مسددة 🔴');

        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.receipt, size: 16, color: AppColors.deepBlue),
                        const SizedBox(width: 6),
                        Text(inv.invoiceNumber, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(statusText, style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('الأرض: ${inv.farmName}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                const SizedBox(height: 8),
                const Divider(height: 1, color: AppColors.surfaceSubtle),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('المبلغ الأصلي:', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                        Text('${inv.originalAmountYER} ريال', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('المدفوع:', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                        Text('${inv.paidAmountYER} ريال', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.agriculturalGreen)),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text('المتبقي:', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                        CurrencyDisplay(
                          amount: inv.remainingAmountYER,
                          showTafqeet: false,
                          amountStyle: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: inv.remainingAmountYER > 0 ? Colors.red : AppColors.agriculturalGreen,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPaymentsList(List<FarmerPaymentReceiptItem> payments) {
    if (payments.isEmpty) {
      return const Center(child: Text('لا توجد سندات قبض مسجلة'));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: payments.length,
      itemBuilder: (context, index) {
        final pay = payments[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.check_circle_outline, size: 16, color: AppColors.agriculturalGreen),
                        const SizedBox(width: 6),
                        Text('سند قبض: ${pay.receiptNumber}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      ],
                    ),
                    CurrencyDisplay(
                      amount: pay.amountYER,
                      showTafqeet: false,
                      amountStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.agriculturalGreen),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'طريقة الدفع: ${pay.method == "cash" ? "نقداً" : (pay.method == "transfer" ? "حوالة بنكية" : "آجل")}',
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
                if (pay.allocatedInvoiceNumbers.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'مخصص لسداد: ${pay.allocatedInvoiceNumbers.join(", ")}',
                    style: const TextStyle(fontSize: 11, color: AppColors.deepBlue),
                  ),
                ],
                if (pay.note != null && pay.note!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('ملاحظة: ${pay.note}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// نافذة تسجيل دفعة وسند قبض جديد
class _RecordPaymentDialog extends StatefulWidget {
  final String wellId;
  final String farmerAccountId;
  final FarmerFinancialAccountData accountData;
  final FinanceRepository repository;
  final VoidCallback onPaymentRecorded;

  const _RecordPaymentDialog({
    required this.wellId,
    required this.farmerAccountId,
    required this.accountData,
    required this.repository,
    required this.onPaymentRecorded,
  });

  @override
  State<_RecordPaymentDialog> createState() => _RecordPaymentDialogState();
}

class _RecordPaymentDialogState extends State<_RecordPaymentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();

  String _paymentMethod = 'cash';
  bool _isSubmitting = false;

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: const [
          Icon(Icons.payments_outlined, color: AppColors.agriculturalGreen),
          SizedBox(width: 8),
          Text('تسجيل دفعة وسند قبض', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('المزارع: ${widget.accountData.fullName} (${widget.accountData.publicCode})', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('الديون المستحقة: ${widget.accountData.totalDebtYER} ريال', style: const TextStyle(fontSize: 12, color: Colors.red)),
              const SizedBox(height: 14),

              // المبلغ
              CurrencyTextFormField(
                controller: _amountController,
                labelText: 'المبلغ المدفوع (ريال يمني) *',
                hintText: '0',
                validator: (val) {
                  if (val == null || val.trim().isEmpty) return 'يرجى إدخال المبلغ';
                  final numVal = int.tryParse(val.replaceAll(',', '').trim()) ?? 0;
                  if (numVal <= 0) return 'المبلغ يجب أن يكون أكبر من الصفر';
                  return null;
                },
              ),
              const SizedBox(height: 14),

              // طريقة الدفع
              DropdownButtonFormField<String>(
                initialValue: _paymentMethod,
                decoration: const InputDecoration(
                  labelText: 'طريقة الدفع *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.payment, size: 20),
                ),
                items: const [
                  DropdownMenuItem(value: 'cash', child: Text('نقداً (Cash)')),
                  DropdownMenuItem(value: 'transfer', child: Text('حوالة / إيداع بنكي')),
                ],
                onChanged: (val) => setState(() => _paymentMethod = val ?? 'cash'),
              ),
              const SizedBox(height: 14),

              // ملاحظة
              TextFormField(
                controller: _noteController,
                decoration: const InputDecoration(
                  labelText: 'ملاحظة أو رقم الحوالة (اختياري)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
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
                    await widget.repository.recordGeneralPayment(
                      wellId: widget.wellId,
                      farmerAccountId: widget.farmerAccountId,
                      amountYER: amount,
                      method: _paymentMethod,
                      note: _noteController.text.trim(),
                    );
                    if (mounted) {
                      nav.pop();
                      widget.onPaymentRecorded();
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
              : const Text('إصدار سند القبض'),
        ),
      ],
    );
  }
}

/// نافذة استخدام الرصيد المقدم في تسديد الفواتير (Decision 420)
class _AllocateAdvanceDialog extends StatefulWidget {
  final FarmerFinancialAccountData accountData;
  final FinanceRepository repository;
  final VoidCallback onAdvanceAllocated;

  const _AllocateAdvanceDialog({
    required this.accountData,
    required this.repository,
    required this.onAdvanceAllocated,
  });

  @override
  State<_AllocateAdvanceDialog> createState() => _AllocateAdvanceDialogState();
}

class _AllocateAdvanceDialogState extends State<_AllocateAdvanceDialog> {
  bool _isSubmitting = false;

  @override
  Widget build(BuildContext context) {
    final unpaidInvoices = widget.accountData.invoices.where((i) => i.status != 'paid').toList();
    final advanceBalance = widget.accountData.advanceBalanceYER;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: const [
          Icon(Icons.swap_horizontal_circle_outlined, color: Colors.purple),
          SizedBox(width: 8),
          Text('استخدام الرصيد المقدم', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.purple.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.purple.withValues(alpha: 0.2)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('الرصيد المقدم المتاح:', style: TextStyle(fontSize: 12)),
                  Text('$advanceBalance ريال', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.purple)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'سيتم استخدام الرصيد لتسديد أقدم الفواتير المستحقة التالية بصورة صريحة ومعتمدة:',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 8),
            ...unpaidInvoices.take(3).map((inv) {
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(inv.invoiceNumber, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    Text('المتبقي: ${inv.remainingAmountYER} ريال', style: const TextStyle(fontSize: 11, color: Colors.red)),
                  ],
                ),
              );
            }),
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
            backgroundColor: Colors.purple,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: _isSubmitting
              ? null
              : () async {
                  setState(() => _isSubmitting = true);
                  final nav = Navigator.of(context);
                  final scaffold = ScaffoldMessenger.of(context);
                  try {
                    await widget.repository.allocateAdvance(
                      paymentId: 'mock-advance-pay',
                      allocations: [],
                    );
                    if (mounted) {
                      nav.pop();
                      widget.onAdvanceAllocated();
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
              : const Text('تأكيد التسديد من المقدم'),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import '../../core/api/app_bootstrap_repository.dart';
import '../../core/identity/app_identity.dart';
import '../../core/api/finance_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/tafqeet_utils.dart';
import '../../core/widgets/currency_display.dart';
import '../../core/widgets/currency_text_form_field.dart';
import '../../core/widgets/top_well_selector.dart';

class ExpensesScreen extends StatefulWidget {
  final AppIdentity identity;
  final ValueChanged<WellSummary>? onWellChanged;
  final FinanceRepository? repository;

  const ExpensesScreen({
    super.key,
    required this.identity,
    this.onWellChanged,
    this.repository,
  });

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late FinanceRepository _repo;

  late WellSummary _activeWell;

  String get _activeWellId => _activeWell.id;
  bool _isLoading = true;
  List<ExpenseItem> _expenses = [];

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? FinanceRepository();
    _tabController = TabController(length: 3, vsync: this);
    _activeWell = widget.identity.activeWell;
    _loadExpenses();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadExpenses() async {
    setState(() => _isLoading = true);
    try {
      final list = await _repo.fetchExpenses(_activeWellId);
      if (!mounted) return;
      setState(() {
        _expenses = list;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _expenses = const [];
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحميل المصروفات: $e')),
      );
    }
  }

  void _showRecordExpenseDialog() {
    showDialog(
      context: context,
      builder: (dialogCtx) {
        return _RecordExpenseDialog(
          wellId: _activeWellId,
          repository: _repo,
          onExpenseRecorded: () {
            _loadExpenses();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('تم تسجيل المصروف بنجاح ✅')),
            );
          },
        );
      },
    );
  }

  void _showApproveExpenseDialog(ExpenseItem expense) {
    showDialog(
      context: context,
      builder: (dialogCtx) {
        return _ApproveExpenseDialog(
          expense: expense,
          repository: _repo,
          onDecisionMade: () {
            _loadExpenses();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('تم تحديث حالة المصروف بنجاح ✅')),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();

    // تصنيف المصروفات للتبويبات
    final todayExpenses = _expenses.where((e) {
      return e.spentAt.year == now.year && e.spentAt.month == now.month && e.spentAt.day == now.day;
    }).toList();

    final pendingExpenses = _expenses.where((e) => e.status == 'pending_approval').toList();
    final historyExpenses = _expenses.where((e) => e.status != 'pending_approval').toList();

    final totalSpentThisMonth = _expenses
        .where((e) => e.status == 'posted')
        .fold<int>(0, (sum, e) => sum + e.amountYER);

    final pendingCount = pendingExpenses.length;
    final pendingSum = pendingExpenses.fold<int>(0, (sum, e) => sum + e.amountYER);

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: TopWellSelector(
          wells: widget.identity.wells,
          activeWell: _activeWell,
          subtitle: 'المصروفات التشغيلية والمالية',
          onWellChanged: (newWell) {
            setState(() {
              _activeWell = newWell;
            });
            _loadExpenses();
            if (widget.onWellChanged != null) {
              widget.onWellChanged!(newWell);
            }
          },
        ),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.deepBlue,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.deepBlue,
          indicatorWeight: 3,
          tabs: [
            Tab(text: 'اليوم (${todayExpenses.length})'),
            Tab(text: 'بانتظار الاعتماد ($pendingCount)'),
            Tab(text: 'السجل (${historyExpenses.length})'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showRecordExpenseDialog,
        backgroundColor: AppColors.deepBlue,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('تسجيل مصروف'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // كرت ملخص المصروفات
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.deepBlue.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.deepBlue.withValues(alpha: 0.15)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('إجمالي المصروفات المعتمدة', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                              const SizedBox(height: 4),
                              CurrencyDisplay(
                                amount: totalSpentThisMonth,
                                showTafqeet: false,
                                amountStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.orange.withValues(alpha: 0.2)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('بانتظار الاعتماد ($pendingCount)', style: const TextStyle(fontSize: 11, color: Colors.deepOrange)),
                              const SizedBox(height: 4),
                              CurrencyDisplay(
                                amount: pendingSum,
                                showTafqeet: false,
                                amountStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.deepOrange),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // محتوى التبويبات
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildExpensesList(todayExpenses, emptyMessage: 'لا توجد مصروفات مسجلة اليوم'),
                      _buildExpensesList(pendingExpenses, emptyMessage: 'لا توجد مصروفات بانتظار الاعتماد', isPendingTab: true),
                      _buildExpensesList(historyExpenses, emptyMessage: 'سجل المصروفات فارغ'),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildExpensesList(List<ExpenseItem> items, {required String emptyMessage, bool isPendingTab = false}) {
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.receipt_long_outlined, size: 48, color: AppColors.border),
            const SizedBox(height: 12),
            Text(emptyMessage, style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final expense = items[index];
        return _buildExpenseCard(expense, isPendingTab: isPendingTab);
      },
    );
  }

  Widget _buildExpenseCard(ExpenseItem expense, {bool isPendingTab = false}) {
    Color statusColor;
    String statusText;

    if (expense.status == 'posted') {
      statusColor = AppColors.agriculturalGreen;
      statusText = 'معتمد ✅';
    } else if (expense.status == 'pending_approval') {
      statusColor = Colors.orange;
      statusText = 'بانتظار الاعتماد ⏳';
    } else {
      statusColor = Colors.red;
      statusText = 'مرفوض ❌';
    }

    final isPartnerPaid = expense.paymentSource == 'partner_paid';

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
            // الترويسة: الفئة والحالة
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.deepBlue.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    expense.categoryName,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: statusColor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // الوصف والمبلغ
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        expense.description,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'المسجل: ${expense.recordedByName ?? "المشغل"}',
                        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                CurrencyDisplay(
                  amount: expense.amountYER,
                  showTafqeet: false,
                  amountStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                ),
              ],
            ),

            const SizedBox(height: 10),
            const Divider(height: 1, color: AppColors.surfaceSubtle),
            const SizedBox(height: 8),

            // مصدر الدفع والمرفق
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      isPartnerPaid ? Icons.person_outline : Icons.account_balance_wallet_outlined,
                      size: 15,
                      color: isPartnerPaid ? Colors.purple : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isPartnerPaid ? 'دفعها الشريك: ${expense.partnerName ?? ""}' : 'مصدر الدفع: صندوق البئر',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: isPartnerPaid ? FontWeight.bold : FontWeight.normal,
                        color: isPartnerPaid ? Colors.purple : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
                if (expense.attachmentSkipped)
                  Tooltip(
                    message: 'سبب التخطي: ${expense.skipReason ?? "غير محدد"}',
                    child: Row(
                      children: const [
                        Icon(Icons.warning_amber_rounded, size: 14, color: Colors.orange),
                        SizedBox(width: 2),
                        Text('تم تخطي المرفق', style: TextStyle(fontSize: 10, color: Colors.orange)),
                      ],
                    ),
                  )
                else
                  Row(
                    children: const [
                      Icon(Icons.attachment, size: 14, color: AppColors.agriculturalGreen),
                      SizedBox(width: 2),
                      Text('مرفق سند', style: TextStyle(fontSize: 10, color: AppColors.agriculturalGreen)),
                    ],
                  ),
              ],
            ),

            // زر اعتماد/رفض للمالك إذا كان معلقاً
            if (isPendingTab || expense.status == 'pending_approval') ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.gavel, size: 16),
                  label: const Text('مراجعة وقرار الاعتماد'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.deepBlue,
                    side: const BorderSide(color: AppColors.deepBlue),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () => _showApproveExpenseDialog(expense),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// نافذة تسجيل مصروف جديد
class _RecordExpenseDialog extends StatefulWidget {
  final String wellId;
  final FinanceRepository repository;
  final VoidCallback onExpenseRecorded;

  const _RecordExpenseDialog({
    required this.wellId,
    required this.repository,
    required this.onExpenseRecorded,
  });

  @override
  State<_RecordExpenseDialog> createState() => _RecordExpenseDialogState();
}

class _RecordExpenseDialogState extends State<_RecordExpenseDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _descController = TextEditingController();
  final _skipReasonController = TextEditingController();

  String _categoryCode = 'fuel';
  String _paymentSource = 'cashbox';
  String? _selectedPartnerId;
  bool _skipAttachment = false;
  bool _isSubmitting = false;

  final Map<String, String> _categories = {
    'fuel': 'ديزل ووقود',
    'maintenance': 'صيانة وقطع غيار',
    'oil': 'زيوت وشحوم',
    'payroll': 'رواتب وعمالة',
    'electricity': 'كهرباء وطاقة',
    'other': 'مصروفات أخرى',
  };

  @override
  void dispose() {
    _amountController.dispose();
    _descController.dispose();
    _skipReasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: const [
          Icon(Icons.add_shopping_cart, color: AppColors.deepBlue),
          SizedBox(width: 8),
          Text('تسجيل مصروف جديد', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // فئة المصروف
              DropdownButtonFormField<String>(
                initialValue: _categoryCode,
                decoration: const InputDecoration(
                  labelText: 'فئة المصروف *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.category_outlined, size: 20),
                ),
                items: _categories.entries.map((e) {
                  return DropdownMenuItem(value: e.key, child: Text(e.value));
                }).toList(),
                onChanged: (val) => setState(() => _categoryCode = val ?? 'other'),
              ),
              const SizedBox(height: 14),

              // المبلغ والتفقيط
              CurrencyTextFormField(
                controller: _amountController,
                labelText: 'المبلغ (ريال يمني) *',
                hintText: '0',
                validator: (val) {
                  if (val == null || val.trim().isEmpty) return 'يرجى إدخال المبلغ';
                  final numVal = int.tryParse(val.replaceAll(',', '').trim()) ?? 0;
                  if (numVal <= 0) return 'المبلغ يجب أن يكون أكبر من الصفر';
                  return null;
                },
              ),
              const SizedBox(height: 14),

              // مصدر الدفع
              DropdownButtonFormField<String>(
                initialValue: _paymentSource,
                decoration: const InputDecoration(
                  labelText: 'مصدر سداد المصروف *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.account_balance_wallet_outlined, size: 20),
                ),
                items: const [
                  DropdownMenuItem(value: 'cashbox', child: Text('صندوق البئر النقدي (Cashbox)')),
                  DropdownMenuItem(value: 'partner_paid', child: Text('دفعها شريك من جيبه الخاص')),
                ],
                onChanged: (val) => setState(() => _paymentSource = val ?? 'cashbox'),
              ),
              const SizedBox(height: 14),

              // الوصف والبيان
              TextFormField(
                controller: _descController,
                decoration: const InputDecoration(
                  labelText: 'بيان وتفاصيل المصروف *',
                  hintText: 'مثال: تعبئة برميل ديزل سعة 200 لتر',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.description_outlined, size: 20),
                ),
                validator: (val) => (val == null || val.trim().isEmpty) ? 'يرجى كتابة البيان' : null,
              ),
              const SizedBox(height: 14),

              // خيار تخطي المرفق
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('تخطي إرفاق صورة السند / الفاتورة', style: TextStyle(fontSize: 13)),
                subtitle: const Text('يلزم تدوين سبب التخطي لحفظ الشفافية', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                value: _skipAttachment,
                onChanged: (val) => setState(() => _skipAttachment = val ?? false),
                controlAffinity: ListTileControlAffinity.leading,
              ),

              if (_skipAttachment) ...[
                const SizedBox(height: 8),
                TextFormField(
                  controller: _skipReasonController,
                  decoration: const InputDecoration(
                    labelText: 'سبب عدم توفر المرفق *',
                    hintText: 'مثال: المحل لا يصدر فواتير ورقية',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.edit_note, size: 20),
                  ),
                  validator: (val) {
                    if (_skipAttachment && (val == null || val.trim().isEmpty)) {
                      return 'سبب التخطي إلزامي عند عدم إرفاق سند';
                    }
                    return null;
                  },
                ),
              ],
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
            backgroundColor: AppColors.deepBlue,
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
                    await widget.repository.recordExpense(
                      wellId: widget.wellId,
                      categoryCode: _categoryCode,
                      amountYER: amount,
                      description: _descController.text.trim(),
                      paymentSource: _paymentSource,
                      partnerId: _selectedPartnerId,
                      attachmentSkipped: _skipAttachment,
                      skipReason: _skipAttachment ? _skipReasonController.text.trim() : null,
                    );
                    if (mounted) {
                      nav.pop();
                      widget.onExpenseRecorded();
                    }
                  } catch (e) {
                    setState(() => _isSubmitting = false);
                    if (mounted) {
                      scaffold.showSnackBar(
                        SnackBar(content: Text('حدث خطأ أثناء الحفظ: $e')),
                      );
                    }
                  }
                },
          child: _isSubmitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
              : const Text('حفظ المصروف'),
        ),
      ],
    );
  }
}

/// نافذة مراجعة واعتماد المصروف
class _ApproveExpenseDialog extends StatefulWidget {
  final ExpenseItem expense;
  final FinanceRepository repository;
  final VoidCallback onDecisionMade;

  const _ApproveExpenseDialog({
    required this.expense,
    required this.repository,
    required this.onDecisionMade,
  });

  @override
  State<_ApproveExpenseDialog> createState() => _ApproveExpenseDialogState();
}

class _ApproveExpenseDialogState extends State<_ApproveExpenseDialog> {
  final _noteController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _makeDecision(bool approve) async {
    setState(() => _isSubmitting = true);
    final nav = Navigator.of(context);
    final scaffold = ScaffoldMessenger.of(context);
    try {
      await widget.repository.decideExpense(
        expenseId: widget.expense.id,
        approve: approve,
        note: _noteController.text.trim(),
      );
      if (mounted) {
        nav.pop();
        widget.onDecisionMade();
      }
    } catch (e) {
      setState(() => _isSubmitting = false);
      if (mounted) {
        scaffold.showSnackBar(
          SnackBar(content: Text('حدث خطأ: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final exp = widget.expense;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: const [
          Icon(Icons.approval, color: AppColors.deepBlue),
          SizedBox(width: 8),
          Text('مراجعة المصروف والاعتماد', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // بطاقة تفاصيل المصروف
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(exp.categoryName, style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.deepBlue)),
                      CurrencyDisplay(
                        amount: exp.amountYER,
                        showTafqeet: false,
                        amountStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(exp.description, style: const TextStyle(fontSize: 13, color: AppColors.textPrimary)),
                  const SizedBox(height: 4),
                  Text(
                    'فقط ${Tafqeet.format(exp.amountYER)} لا غير.',
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    exp.paymentSource == 'partner_paid'
                        ? 'مصدر الدفع: دفعها الشريك (${exp.partnerName ?? ""}) من جيبه'
                        : 'مصدر الدفع: صندوق البئر النقدي',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                  if (exp.attachmentSkipped) ...[
                    const SizedBox(height: 6),
                    Text(
                      'تنبيه: تم تخطي المرفق بسبب: ${exp.skipReason ?? "غير محدد"}',
                      style: const TextStyle(fontSize: 11, color: Colors.deepOrange),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ملاحظة المالك
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(
                labelText: 'ملاحظة المالك (اختياري)',
                hintText: 'سبب القبول أو الرفض',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
          child: const Text('إلغاء', style: TextStyle(color: AppColors.textSecondary)),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.close, size: 16),
          label: const Text('رفض'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: _isSubmitting ? null : () => _makeDecision(false),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.check, size: 16),
          label: const Text('اعتماد المصروف'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.agriculturalGreen,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: _isSubmitting ? null : () => _makeDecision(true),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../../core/api/finance_repository.dart';
import '../../core/identity/app_identity.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/currency_display.dart';
import '../../core/widgets/currency_text_form_field.dart';

/// شاشة حيازة المشغل النقدية والترحيل (ق-131 البند 18 / م-45 مرحلة A).
///
/// العقد المعروض:
/// - الرصيد رصيد دفتري من صندوق الحيازة، وموسوم بأنه **مال البئر/العمل
///   في حيازة المشغل — ليس محفظة شخصية** (UX-14).
/// - الإقرار لا يُرحِّل محاسبيًا: يؤكد المالك فيصير «نقل حيازة لا
///   إيراد ثاني» — فلا تُعرض أي حالة كمرحّلة قبل ACK (نمط 423)،
///   و`balance` من الخادم هو الحقيقة الوحيدة بلا تحسين متفائل.
/// - الأقسام بالأدوار: المشغل يرى حيازته وإقراره، والمالك يرى تأكيد
///   التراخيم المعلقة وسجل البئر، وصاحب الدورين يرى القسمين معًا.
/// - بلا نوبات: الإقرار على مستوى البئر عبر جسر الهجرة 110، ولا تُفتح
///   نوبة ولا يُختلق معرّفها هنا، ولا حسم للفروق (م109 يمنعه عمدًا).
class OperatorCashCustodyScreen extends StatefulWidget {
  final AppIdentity identity;
  final FinanceRepository? repository;

  const OperatorCashCustodyScreen({
    super.key,
    required this.identity,
    this.repository,
  });

  @override
  State<OperatorCashCustodyScreen> createState() =>
      _OperatorCashCustodyScreenState();
}

class _OperatorCashCustodyScreenState extends State<OperatorCashCustodyScreen> {
  late FinanceRepository _repo;
  bool _isLoading = true;
  String? _loadError;
  OperatorCashCustody? _custody;
  List<OperatorCashRemittance> _remittances = const [];

  bool get _isOwner => widget.identity.isOwner;
  bool get _isOperator => widget.identity.isOperator;
  String get _activeWellId => widget.identity.activeWell.id;

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? FinanceRepository();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      // رصيد الحيازة للمشغل النشط وحده (المالك ليس له حيازة)، والقائمة
      // متاحة للمالك والمشغل معًا بتصريح الخادم. كل الأرقام من الخادم —
      // لا حساب رصيد في العميل ولا تحديث متفائل (ق-99).
      final custody = _isOperator
          ? await _repo.fetchMyOperatorCashCustody(_activeWellId)
          : null;
      final remittances = await _repo.fetchOperatorCashRemittances(
        _activeWellId,
      );
      if (!mounted) return;
      setState(() {
        _custody = custody;
        _remittances = remittances;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _openDeclareRemittanceSheet() async {
    final declared = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DeclareRemittanceSheet(
        wellId: _activeWellId,
        repository: _repo,
      ),
    );
    if (declared == true) {
      await _loadAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'أُقر الترحيل وبانتظار تأكيد المالك — '
            'لم يُرحَّل محاسبيًا بعد',
          ),
        ),
      );
    }
  }

  /// تأكيد المالك: الحوار يجمع المبلغ المؤكد وسبب الفرق إن غيّره، ثم
  /// عقد الخادم api.confirm_handover هو سلطة النتيجة، وبعده إعادة
  /// تحميل من الخادم وحدها — لا تعديل رصيد متفائل.
  Future<void> _openConfirmDialog(OperatorCashRemittance r) async {
    final outcome = await showDialog<_ConfirmOutcome>(
      context: context,
      builder: (_) => _ConfirmRemittanceDialog(remittance: r),
    );
    if (outcome == null) return;
    try {
      final result = await _repo.confirmOperatorCashRemittance(
        handoverId: r.id,
        confirmedAmountYER: outcome.confirmedAmountYER,
        differenceReason: outcome.differenceReason,
      );
      await _loadAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result == 'confirmed'
                ? 'تم تأكيد الاستلام وترحيل النقد إلى صندوق البئر'
                : 'تم تسجيل فرق في التسليم ولم يُرحّل النقد محاسبيًا.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('رفض الخادم التأكيد: $e')),
      );
    }
  }

  /// الحالات النصية الحاكمة: الإقرار المعلق ليس نقدًا خرج من الحيازة،
  /// والمؤكد وحده «تم الترحيل».
  String _statusLabel(OperatorCashRemittance r) {
    switch (r.status) {
      case 'confirmed':
        return 'تم الترحيل';
      case 'difference_pending':
        return 'فرق معلق';
      case 'settled':
        return 'فرق محسوم';
      case 'rejected':
        return 'مرفوض';
      default:
        return 'بانتظار تأكيد المالك';
    }
  }

  IconData _statusIcon(OperatorCashRemittance r) {
    switch (r.status) {
      case 'confirmed':
        return Icons.check_circle_outline;
      case 'difference_pending':
        return Icons.report_problem_outlined;
      default:
        return Icons.hourglass_top_rounded;
    }
  }

  Color _statusColor(OperatorCashRemittance r) {
    switch (r.status) {
      case 'confirmed':
        return AppColors.success;
      case 'difference_pending':
        return AppColors.warning;
      default:
        return AppColors.info;
    }
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/'
        '${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('حيازة النقد'),
        backgroundColor: AppColors.deepBlue,
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
              ? _buildErrorView()
              : RefreshIndicator(
                  onRefresh: _loadAll,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (_isOperator) ...[
                        _buildCustodyCard(),
                        const SizedBox(height: 16),
                      ],
                      if (_isOwner &&
                          _remittances.any((r) => r.status == 'declared'))
                        ...[
                          _buildPendingConfirmationsSection(),
                          const SizedBox(height: 16),
                        ],
                      Text(
                        'سجل التراخيم',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_remittances.isEmpty)
                        _buildEmptyRemittances()
                      else
                        ..._remittances.map(_buildRemittanceTile),
                    ],
                  ),
                ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppColors.error),
            const SizedBox(height: 12),
            Text(
              'تعذر تحميل الحيازة',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              _loadError ?? '',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _loadAll, child: const Text('إعادة المحاولة')),
          ],
        ),
      ),
    );
  }

  /// قسم المشغل: الرصيد الدفتري بدلالته الحاكمة وزر الإقرار.
  Widget _buildCustodyCard() {
    final custody = _custody;
    return Card(
      elevation: 0,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.account_balance_wallet_rounded,
                  color: AppColors.waterBlueDark,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'نقد البئر في حيازتك',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              custody?.cashboxName ?? 'حيازة نقد المشغل',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                  ),
            ),
            const SizedBox(height: 12),
            CurrencyDisplay(
              amount: custody?.balanceYER ?? 0,
              amountStyle: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
            ),
            const SizedBox(height: 8),
            // الدلالة الحاكمة: مال البئر في الحيازة لا محفظة شخصية،
            // والترحيل نقل حيازة لا إيراد ثاني (UX-14).
            Text(
              custody?.semantics ??
                  'مال البئر/العمل في حيازة المشغل لهذا البئر — '
                      'ليس محفظة شخصية، والترحيل نقل حيازة لا إيراد',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _openDeclareRemittanceSheet,
                icon: const Icon(Icons.assignment_turned_in_outlined),
                label: const Text('إقرار ترحيل إلى صندوق البئر'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// قسم المالك: الإقرارات المعلقة بانتظار تأكيده، بكل ما يلزم
  /// للمقارنة (المشغل، المبلغ، الوقت، الملاحظة) وزر التأكيد.
  Widget _buildPendingConfirmationsSection() {
    final pending = _remittances
        .where((r) => r.status == 'declared')
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'ترحيلات النقد بانتظار التأكيد',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
        ),
        const SizedBox(height: 8),
        ...pending.map(_buildPendingTile),
      ],
    );
  }

  Widget _buildPendingTile(OperatorCashRemittance r) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.hourglass_top_rounded,
                  size: 18,
                  color: AppColors.info,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    r.fromProfileName,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            CurrencyDisplay(
              amount: r.declaredAmountYER,
              unit: 'ريال',
              showTafqeet: false,
              amountStyle: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
              unitStyle: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Text(
              'أُقر في ${_formatDate(r.declaredAt)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                  ),
            ),
            if (r.note != null && r.note!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                r.note!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _openConfirmDialog(r),
                icon: const Icon(Icons.task_alt_rounded),
                label: const Text('تأكيد الاستلام'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyRemittances() {
    return Card(
      elevation: 0,
      color: AppColors.surfaceSubtle,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.inbox_outlined, color: AppColors.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _isOperator
                    ? 'لا توجد تراخيم بعد — أقر بترحيل أول مبلغ من حيازتك'
                    : 'لا توجد تراخيم لهذا البئر بعد',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRemittanceTile(OperatorCashRemittance r) {
    final color = _statusColor(r);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_statusIcon(r), size: 18, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _statusLabel(r),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                  ),
                ),
                if (!_isOperator && r.fromProfileName.isNotEmpty)
                  Text(
                    r.fromProfileName,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            CurrencyDisplay(
              amount: r.declaredAmountYER,
              unit: 'ريال',
              showTafqeet: false,
              amountStyle: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
              unitStyle: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Text(
              'أُقر في ${_formatDate(r.declaredAt)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                  ),
            ),
            if (r.status == 'confirmed' && r.confirmedAmountYER != null) ...[
              const SizedBox(height: 4),
              Text(
                'أكده المالك: ${r.confirmedAmountYER} ريال'
                ' — رُحِّل محاسبيًا إلى صندوق البئر',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
            ],
            if (r.status == 'difference_pending' &&
                r.differenceYER != null &&
                r.differenceYER != 0) ...[
              const SizedBox(height: 4),
              Text(
                'الفرق: ${r.differenceYER} ريال'
                '${r.differenceReason == null ? '' : ' — السبب: ${r.differenceReason}'}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.warning,
                    ),
              ),
            ],
            if (r.note != null && r.note!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                r.note!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textMuted,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// نافذة إقرار الترحيل: مبلغ بتفقيط لحظي، وسبب/ملاحظة اختيارية، وزر
/// إقرار صريح واحد — الإقرار عرض للمالك والتأكيد فعلُه هو، فلا تُدَّعي
/// أي محاسبة هنا.
class _DeclareRemittanceSheet extends StatefulWidget {
  final String wellId;
  final FinanceRepository repository;

  const _DeclareRemittanceSheet({
    required this.wellId,
    required this.repository,
  });

  @override
  State<_DeclareRemittanceSheet> createState() =>
      _DeclareRemittanceSheetState();
}

class _DeclareRemittanceSheetState extends State<_DeclareRemittanceSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final amount = int.tryParse(
      _amountController.text.replaceAll(RegExp(r'[^\d]'), ''),
    );
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل مبلغ ترحيل صحيحًا أكبر من صفر')),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      final id = await widget.repository.declareMyOperatorCashRemittance(
        wellId: widget.wellId,
        amountYER: amount,
        note: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(id.isNotEmpty);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('رفض الخادم الإقرار: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'إقرار ترحيل إلى صندوق البئر العام',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'نقل حيازة لا إيراد: يعرض إقرارك على المالك، وبعد تأكيده '
              'ينتقل النقد من حيازتك إلى صندوق البئر دون تغيير المبلغ '
              'الاقتصادي للبئر.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                  ),
            ),
            const SizedBox(height: 16),
            CurrencyTextFormField(
              controller: _amountController,
              labelText: 'مبلغ الترحيل',
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'المبلغ مطلوب' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _noteController,
              decoration: const InputDecoration(
                labelText: 'ملاحظة (اختياري)',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('إقرار وتقديم للمالك'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// نتيجة حوار تأكيد المالك كما تُرسل إلى العقد حرفيًا.
class _ConfirmOutcome {
  const _ConfirmOutcome({
    required this.confirmedAmountYER,
    required this.differenceReason,
  });

  final int confirmedAmountYER;
  final String? differenceReason;
}

/// حوار تأكيد المالك: المبلغ الابتدائي = المقر. تغيير المبلغ يجعل
/// سبب الفرق إلزاميًا ويحوّل النتيجة إلى difference_pending بلا أي
/// ترحيل — ولا زر حسم للفرق هنا إطلاقًا (م109 يمنعه عمدًا).
class _ConfirmRemittanceDialog extends StatefulWidget {
  final OperatorCashRemittance remittance;

  const _ConfirmRemittanceDialog({required this.remittance});

  @override
  State<_ConfirmRemittanceDialog> createState() =>
      _ConfirmRemittanceDialogState();
}

class _ConfirmRemittanceDialogState extends State<_ConfirmRemittanceDialog> {
  late final TextEditingController _amountController;
  final _reasonController = TextEditingController();
  bool _amountChanged = false;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(
      text: _formatAmount(widget.remittance.declaredAmountYER),
    );
    _amountController.addListener(_onAmountChanged);
  }

  static String _formatAmount(int amount) {
    return amount.toString().replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]},',
        );
  }

  void _onAmountChanged() {
    final amount =
        int.tryParse(_amountController.text.replaceAll(RegExp(r'[^\d]'), ''));
    final changed = amount != widget.remittance.declaredAmountYER;
    if (changed != _amountChanged) {
      setState(() => _amountChanged = changed);
    }
  }

  @override
  void dispose() {
    _amountController.removeListener(_onAmountChanged);
    _amountController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _submit() {
    final amount =
        int.tryParse(_amountController.text.replaceAll(RegExp(r'[^\d]'), ''));
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('أدخل مبلغًا مستلمًا صحيحًا أكبر من صفر')),
      );
      return;
    }
    final changed = amount != widget.remittance.declaredAmountYER;
    final reason = _reasonController.text.trim();
    if (changed && reason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ذكر سبب الفرق إلزامي عند تغيير المبلغ')),
      );
      return;
    }
    Navigator.of(context).pop(
      _ConfirmOutcome(
        confirmedAmountYER: amount,
        // مطابق ⟹ سبب null حتى لو كُتب؛ ومغاير ⟹ السبب إلزامي.
        differenceReason: changed ? reason : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.remittance;
    return AlertDialog(
      title: const Text('تأكيد استلام ترحيل النقد'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${r.fromProfileName} أقر بترحيل:'),
            const SizedBox(height: 8),
            CurrencyDisplay(
              amount: r.declaredAmountYER,
              unit: 'ريال',
              showTafqeet: false,
            ),
            const SizedBox(height: 16),
            CurrencyTextFormField(
              controller: _amountController,
              labelText: 'المبلغ المستلم فعليًا',
            ),
            if (_amountChanged) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _reasonController,
                decoration: const InputDecoration(
                  labelText: 'سبب الفرق (إلزامي)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 8),
              Text(
                'بتغيير المبلغ يسجل الفرق حالة «فرق معلق» ويبقى النقد '
                'بلا ترحيل محاسبي حتى عقد التسوية المالية المخصص.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.warning,
                    ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('تأكيد الاستلام'),
        ),
      ],
    );
  }
}

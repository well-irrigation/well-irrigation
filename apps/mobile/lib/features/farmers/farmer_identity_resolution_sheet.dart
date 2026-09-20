import 'package:flutter/material.dart';

import '../../core/session/offline_session_coordinator.dart';
import '../../core/sync/farmer_identity_review.dart';
import '../../core/theme/app_colors.dart';

/// واجهة حسم تعارض وهوية المزارع المحتاجة مراجعة بشرية (ق-88 / ق-114).
///
/// تعرض البيانات الأصلية المدخلة، والمرشحين ببياناتهم الآمنة فقط (بلا تخمين هاتف)،
/// وتتيح إما اختيار مرشح قائم ("استخدام هذا المزارع") أو تأكيد شخص مختلف ببيانات
/// مميزة صريحة ("هذا شخص مختلف").
class FarmerIdentityResolutionSheet extends StatefulWidget {
  const FarmerIdentityResolutionSheet({
    super.key,
    required this.review,
    required this.accountId,
    this.coordinator,
    this.onResolved,
  });

  final FarmerIdentityReview review;
  final String accountId;
  final OfflineSessionCoordinator? coordinator;
  final VoidCallback? onResolved;

  static Future<bool?> show(
    BuildContext context, {
    required FarmerIdentityReview review,
    required String accountId,
    OfflineSessionCoordinator? coordinator,
    VoidCallback? onResolved,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: FarmerIdentityResolutionSheet(
          review: review,
          accountId: accountId,
          coordinator: coordinator,
          onResolved: onResolved,
        ),
      ),
    );
  }

  @override
  State<FarmerIdentityResolutionSheet> createState() =>
      _FarmerIdentityResolutionSheetState();
}

class _FarmerIdentityResolutionSheetState
    extends State<FarmerIdentityResolutionSheet> {
  bool _isSubmitting = false;
  bool _showDifferentPersonForm = false;
  String? _errorMessage;

  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _preferredNameController;
  late final TextEditingController _notesController;

  OfflineSessionCoordinator get _coordinator =>
      widget.coordinator ?? OfflineSessionCoordinator.instance;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.review.fullName);
    _phoneController = TextEditingController(text: widget.review.phone ?? '');
    _preferredNameController =
        TextEditingController(text: widget.review.preferredName ?? '');
    _notesController = TextEditingController(text: widget.review.notes ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _preferredNameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _handleUseExisting(FarmerDuplicateCandidate candidate) async {
    if (_isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      await _coordinator.resolveFarmerWithExisting(
        accountId: widget.accountId,
        review: widget.review,
        selectedPersonId: candidate.personId,
      );

      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('تم حفظ قرار الحسم وسيتم مزامنته'),
          backgroundColor: AppColors.deepBlue,
        ),
      );
      widget.onResolved?.call();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _handleDifferentPerson() async {
    if (_isSubmitting) return;

    final fullName = _nameController.text.trim();
    final phone = _phoneController.text.trim();

    final cleanDigits = phone.replaceAll(RegExp(r'\D'), '');
    if (phone.isNotEmpty && cleanDigits.length < 7) {
      setState(() {
        _errorMessage = 'يرجى إدخال رقم هاتف صحيح لا يقل عن 7 أرقام';
      });
      return;
    }

    // فحص سلامة الهاتف: مقارنة بالهاتف المُدخل أصلاً للعملية عند وجود تطابق هاتف
    final matchedOnPhone = widget.review.candidates.any(
      (c) => c.matchedOn == 'phone' || c.matchedOn == 'name+phone',
    );
    final originalPhone = widget.review.phone?.trim() ?? '';

    if (matchedOnPhone && phone.isNotEmpty && phone == originalPhone) {
      setState(() {
        _errorMessage =
            'لا يمكن تأكيد شخص مختلف بنفس رقم الهاتف المُدخل سابقًا الذي طابق مرشحًا موجودًا؛ يرجى إدخال رقم هاتف مختلف ومميز. يتحقق الخادم بشكل قطعي من عدم تكراره مع أي مرشح.';
      });
      return;
    }

    if (phone.isEmpty) {
      setState(() {
        _errorMessage =
            'يلزم إدخال رقم هاتف مميز لإثبات أن هذا المزارع شخص مختلف ومنع تشابه الأسماء.';
      });
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      await _coordinator.resolveFarmerAsDifferentPerson(
        accountId: widget.accountId,
        review: widget.review,
        fullName: fullName,
        phone: phone,
        preferredName: _preferredNameController.text.trim(),
        notes: _notesController.text.trim(),
        creditLimitMinor: widget.review.creditLimitMinor,
      );

      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop(true);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('تم حفظ قرار الحسم وسيتم مزامنته'),
          backgroundColor: AppColors.deepBlue,
        ),
      );
      widget.onResolved?.call();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: AppColors.warning,
                    size: 24,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'مراجعة هوية المزارع (اشتباه تكرار)',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.deepBlue,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'العملية قيد المراجعة ولم تُنشأ بعد. يوجد تشابه مع مزارعين مسجلين في النظام، يرجى اختيار المزارع المطابق أو تأكيد شخص مختلف.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),

              // بطاقة البيانات المدخلة الأصلية
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
                    const Text(
                      'البيانات المدخلة في الطلب:',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      widget.review.fullName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (widget.review.phone != null &&
                        widget.review.phone!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        'الهاتف: ${widget.review.phone}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),

              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppColors.error.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: AppColors.error,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.error,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // قائمة المرشحين المطابقين
              const Text(
                'المرشحون المطابقون في النظام:',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepBlue,
                ),
              ),
              const SizedBox(height: 8),

              ...widget.review.candidates.map((candidate) {
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              candidate.fullName,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceSubtle,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              candidate.publicCode,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: candidate.matchLevel == 'match'
                                  ? AppColors.error.withValues(alpha: 0.1)
                                  : AppColors.warning.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              candidate.matchLevelDescription,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: candidate.matchLevel == 'match'
                                    ? AppColors.error
                                    : AppColors.warning,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            candidate.matchedOnDescription,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _isSubmitting
                              ? null
                              : () => _handleUseExisting(candidate),
                          icon: const Icon(Icons.check, size: 16),
                          label: const Text('استخدام هذا المزارع'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.waterBlue,
                            side: const BorderSide(color: AppColors.waterBlue),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),

              const SizedBox(height: 8),
              const Divider(),
              const SizedBox(height: 8),

              // خيار شخص مختلف
              if (!_showDifferentPersonForm) ...[
                OutlinedButton.icon(
                  onPressed: _isSubmitting
                      ? null
                      : () => setState(() => _showDifferentPersonForm = true),
                  icon: const Icon(Icons.person_add_outlined),
                  label: const Text('هذا شخص مختلف'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.deepBlue,
                    side: const BorderSide(color: AppColors.deepBlue),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.borderFocused),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'تأكيد شخص مختلف ببيانات مميزة:',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.deepBlue,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'لا يُكشف هاتف المرشح حمايةً للخصوصية. يتحقق الخادم بشكل قطعي من عدم تكرار الهاتف مع أي مزارع قائم.',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'الاسم الكامل *',
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'رقم الهاتف المميز *',
                          hintText: 'مثال: 771234567',
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _preferredNameController,
                        decoration: const InputDecoration(
                          labelText: 'اللقب / الشهرة (اختياري)',
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _notesController,
                        decoration: const InputDecoration(
                          labelText: 'ملاحظات تمييزية (اختياري)',
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _isSubmitting
                                  ? null
                                  : _handleDifferentPerson,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.deepBlue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                              ),
                              child: _isSubmitting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('تأكيد وحفظ القرار'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: _isSubmitting
                                ? null
                                : () => setState(
                                    () => _showDifferentPersonForm = false),
                            child: const Text('إلغاء'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

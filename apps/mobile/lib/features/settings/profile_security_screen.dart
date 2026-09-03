import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/account_repository.dart';
import '../../core/theme/app_colors.dart';

/// شاشة الملف الشخصي وأمان الحساب (UX-16A / القرارات 528–545 / ق-84 / ق-101)
class ProfileSecurityScreen extends StatefulWidget {
  const ProfileSecurityScreen({
    required this.profile,
    this.repository,
    this.onProfileUpdated,
    super.key,
  });

  final UserProfileData profile;
  final AccountRepository? repository;
  final VoidCallback? onProfileUpdated;

  @override
  State<ProfileSecurityScreen> createState() => _ProfileSecurityScreenState();
}

class _ProfileSecurityScreenState extends State<ProfileSecurityScreen> {
  late AccountRepository _repo;
  late TextEditingController _nameController;
  bool _isSavingName = false;

  /// هاتف الحساب كما قرأه العقد. كان الغياب يُعرض برقم جاهز مكتوب في الشاشة،
  /// فيرى المستخدم رقمًا ليس رقمه ويظنه معتمدًا. الغياب الآن يُعلن (ق-113).
  bool get _hasPhone => widget.profile.phone.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? AccountRepository();
    _nameController = TextEditingController(text: widget.profile.fullName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _handleSaveName() async {
    final newName = _nameController.text.trim();
    if (newName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يرجى إدخال اسم المستخدم الثلاثي أو الرباعي')),
      );
      return;
    }

    setState(() => _isSavingName = true);
    HapticFeedback.lightImpact();

    try {
      await _repo.updateUserName(newName);

      if (mounted) {
        setState(() => _isSavingName = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم تحديث الاسم المعتمد بنجاح ✅'),
            backgroundColor: AppColors.agriculturalGreen,
          ),
        );
        if (widget.onProfileUpdated != null) {
          widget.onProfileUpdated!();
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isSavingName = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'تعذر تحديث الاسم. تحقق من الاتصال وأعد المحاولة.',
            ),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  /// تغيير رقم الهاتف **غير متاح** في هذا الإصدار، ويُقال ذلك صريحًا.
  ///
  /// كان المسار تمثيلًا كاملًا: يُعلن «تم إرسال رمز التحقق في رسالة نصية»
  /// ولا رسالة تُرسل، **ولا يُقرأ الرمز الذي يكتبه المستخدم أصلًا**، ثم
  /// يُعلن «تم تأكيد وتحديث رقم الهاتف بنجاح» ولا شيء يتغيّر في أي مكان.
  /// والرقم هو هوية الحساب ومفتاح الدخول (ق-84)، فقد يظن صاحبه أنه صار
  /// يدخل برقمه الجديد فيجد نفسه محجوبًا (ق-113 / ق-123 / ق-124).
  void _showChangePhoneDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => const _PhoneChangeUnavailableDialog(),
    );
  }

  void _showChangePasswordDialog() {
    final oldPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    bool isSubmitting = false;

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('تغيير كلمة المرور', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: oldPasswordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'كلمة المرور الحالية *',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: newPasswordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'كلمة المرور الجديدة *',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: confirmPasswordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'تأكيد كلمة المرور الجديدة *',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                oldPasswordController.clear();
                newPasswordController.clear();
                confirmPasswordController.clear();
                Navigator.of(dialogCtx).pop();
              },
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.waterBlue,
                foregroundColor: Colors.white,
              ),
              onPressed: isSubmitting
                  ? null
                  : () async {
                      final currentPass = oldPasswordController.text;
                      final newPass = newPasswordController.text;
                      final confirmPass = confirmPasswordController.text;

                      // الخانة كانت تُعرض ولا تُقرأ: من يمسك الهاتف مفتوحًا
                      // كان يغيّر كلمة المرور بلا معرفة القديمة (ق-105).
                      if (currentPass.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('أدخل كلمة المرور الحالية أولًا')),
                        );
                        return;
                      }

                      if (newPass.length < 6) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('يجب أن لا تقل كلمة المرور عن 6 خانات')),
                        );
                        return;
                      }

                      if (newPass != confirmPass) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('كلمات المرور الجديدة غير متطابقة')),
                        );
                        return;
                      }

                      setDialogState(() => isSubmitting = true);
                      final messenger = ScaffoldMessenger.of(context);
                      final navigator = Navigator.of(dialogCtx);

                      Object? failure;
                      try {
                        await _repo.updatePassword(
                          currentPassword: currentPass,
                          newPassword: newPass,
                        );
                      } catch (error) {
                        // لا رسالة نجاح لتغيير لم يحدث (ق-118 / م-41B3B).
                        failure = error;
                      }

                      // تفريغ فوري لكلمات المرور من الذاكرة (ق-118 / القرار 541)
                      oldPasswordController.clear();
                      newPasswordController.clear();
                      confirmPasswordController.clear();

                      if (!mounted) return;

                      if (failure != null) {
                        setDialogState(() => isSubmitting = false);
                        // «كلمتك الحالية خطأ» ليست «تعذر الاتصال»: الرسالتان
                        // تُفرَّقان وإلا بحث المستخدم عن العطب في غير موضعه.
                        final message = failure is WrongCurrentPasswordException
                            ? 'كلمة المرور الحالية غير صحيحة — لم يتغيّر شيء'
                            : 'تعذر تغيير كلمة المرور — لم يتغيّر شيء، وكلمتك الحالية ما زالت صالحة';
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(message),
                            backgroundColor: AppColors.error,
                          ),
                        );
                        return;
                      }

                      navigator.pop();
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text('تم تغيير كلمة المرور بنجاح ✅'),
                          backgroundColor: AppColors.agriculturalGreen,
                        ),
                      );
                    },
              child: isSubmitting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('حفظ كلمة المرور'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text('الملف الشخصي والأمان', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // بطاقة تعديل الاسم (القرار 538)
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: AppColors.border),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'الاسم الشخصي المعتمد',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'يظهر هذا الاسم في سجلات التشغيل، الفواتير، وسندات القبض الميدانية.',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'الاسم الكامل *',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.waterBlue,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.check, size: 18),
                      label: _isSavingName
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('حفظ الاسم'),
                      onPressed: _isSavingName ? null : _handleSaveName,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // بطاقة رقم الهاتف (القرارات 533–537)
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: AppColors.border),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'رقم الهاتف وهوية الحساب',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: _hasPhone
                              ? AppColors.waterBlue.withValues(alpha: 0.1)
                              : AppColors.warning.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          // كانت الشارة تقول «معتمد وموثق ✅» وهي تدّعي تحقّقًا
                          // لا وجود له في المنظومة كلها: لا رمز ولا رسالة ولا
                          // تحقّق من الرقم في أي مكان (ق-113 / ق-124).
                          _hasPhone ? 'رقم الدخول' : 'غير مقروء من العقد',
                          style: TextStyle(
                            color: _hasPhone
                                ? AppColors.waterBlue
                                : AppColors.warning,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'رقم الهاتف هو المعرّف الوحيد لحسابك في جميع الآبار المشترك بها (ق-84). '
                    'ولا يوجد تحقّق برسالة نصية في هذا الإصدار.',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.phone_android,
                          color: _hasPhone
                              ? AppColors.waterBlue
                              : AppColors.textMuted,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _hasPhone
                              ? widget.profile.phone
                              : 'لا رقم هاتف في بيانات الحساب',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: _hasPhone ? 16 : 13,
                            color: _hasPhone
                                ? AppColors.deepBlue
                                : AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                      side: const BorderSide(color: AppColors.border),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.phone_forwarded, size: 18),
                    label: const Text('تغيير رقم الهاتف (غير متاح)'),
                    onPressed: _showChangePhoneDialog,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // بطاقة أمان كلمة المرور (القرارات 539–541)
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: AppColors.border),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'أمان وكلمة المرور',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'حافظ على سرية كلمة المرور؛ لا يستطيع أي مالك أو مشغل آخر الاطلاع عليها.',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.waterBlue.withValues(alpha: 0.1),
                      foregroundColor: AppColors.waterBlue,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.lock_reset, size: 18),
                    label: const Text('تغيير كلمة المرور'),
                    onPressed: _showChangePasswordDialog,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// حالة صريحة بدل تمثيل تغيير رقم لم يحدث (ق-113 / ق-123 / ق-124).
///
/// بلا مستودع وبلا `await`: لا مسار كتابة من هذه النافذة أصلًا، فلا يمكن
/// أن تُعلن نجاحًا ولا فشلًا. نفس نمط `_AdvanceUnavailableDialog` في م-41D5.
class _PhoneChangeUnavailableDialog extends StatelessWidget {
  const _PhoneChangeUnavailableDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'تغيير رقم الهاتف غير متاح في هذا الإصدار',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
      ),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'رقم هاتفك هو هوية حسابك ومفتاح دخولك (ق-84)، فتغييره يحتاج '
            'إثبات ملكيتك للرقم الجديد برمز يُرسل إليه.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          SizedBox(height: 10),
          Text(
            'ولا يوجد إرسال رسائل نصية في هذا الإصدار — ولن نُظهر لك تأكيدًا '
            'لتغيير لم يحدث. رقمك الحالي هو ما تدخل به، ولم يُرسل أي طلب.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          SizedBox(height: 10),
          Text(
            'لتغييره الآن راجع مسؤول التطبيق.',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('حسنًا'),
        ),
      ],
    );
  }
}

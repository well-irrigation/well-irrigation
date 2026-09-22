import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api/auth_repository.dart';
import '../../core/api/team_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/digit_utils.dart';

enum _ActivationStage {
  validation,
  waitingOwner,
  choosePassword,
  existingPassword,
  existingInvitations,
  existingWaiting,
}

/// تنشيط عضو وفق ق-130: الدعوة والقبول لا يمنحان وصولًا، ولا يُنشأ حساب
/// جديد إلا بعد تأكيد المالك عبر طرف M104 الموثوق.
class MemberActivationScreen extends StatefulWidget {
  const MemberActivationScreen({
    this.authRepository,
    this.teamRepository,
    this.onActivated,
    super.key,
  });

  final AuthRepository? authRepository;
  final TeamRepository? teamRepository;
  final VoidCallback? onActivated;

  @override
  State<MemberActivationScreen> createState() => _MemberActivationScreenState();
}

class _MemberActivationScreenState extends State<MemberActivationScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _existingPasswordController = TextEditingController();

  late final TeamRepository _team;
  _ActivationStage _stage = _ActivationStage.validation;
  List<MyWellInvitation> _invitations = const [];
  String? _continuationToken;
  String? _status;
  String? _error;
  bool _busy = false;
  bool _obscure = true;
  bool _activationReported = false;

  AuthRepository get _auth =>
      widget.authRepository ?? AuthRepository(Supabase.instance.client);

  @override
  void initState() {
    super.initState();
    _team = widget.teamRepository ?? TeamRepository();
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _existingPasswordController.dispose();
    super.dispose();
  }

  String get _phone => normalizeArabicDigits(_phoneController.text).trim();
  String get _code => normalizeArabicDigits(_codeController.text).trim();

  void _reportActivation() {
    if (_activationReported) return;
    _activationReported = true;
    widget.onActivated?.call();
  }

  Future<void> _validateInvitation() async {
    if (_phone.length < 9) {
      setState(() => _error = 'أدخل رقم هاتف صحيحًا.');
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(_code)) {
      setState(() => _error = 'رمز الدعوة ستة أرقام.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    MemberValidationOutcome result;
    try {
      result = await _auth.validateMemberFinalization(
        phone: _phone,
        code: _code,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'تعذر التحقق من الدعوة — لم يُنشأ حساب ولم يُمنح وصول.';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _applyValidation(result);
    });
  }

  void _applyValidation(MemberValidationOutcome result) {
    switch (result.outcome) {
      case 'accepted_pending_owner':
        if (!_storeToken(result)) return;
        _stage = _ActivationStage.waitingOwner;
        _status = 'بانتظار تأكيد مالك البئر';
        _error = null;
      case 'owner_confirmed_pending_account':
        if (!_storeToken(result)) return;
        _stage = _ActivationStage.choosePassword;
        _status = 'تم تأكيد الهوية';
        _error = null;
      case 'wrong_code':
        final left = result.attemptsLeft;
        _error = left == null
            ? 'رمز الدعوة غير صحيح.'
            : 'رمز الدعوة غير صحيح — بقيت $left محاولات.';
      case 'expired':
        _error = 'انتهت الدعوة.';
      case 'revoked':
        _error = 'أُلغيت الدعوة.';
      case 'no_invitation':
        _error = 'لا توجد دعوة مطابقة.';
      case 'existing_account':
        _continuationToken = null;
        _stage = _ActivationStage.existingPassword;
        _status = 'لديك حساب قائم — سجّل الدخول لعرض دعواتك';
        _error = null;
      default:
        _error = 'تعذر تحديد حالة الدعوة — لم يتغيّر أي وصول.';
    }
  }

  bool _storeToken(MemberValidationOutcome result) {
    final token = result.continuationToken;
    if (token == null || token.isEmpty) {
      _error = 'لم يعُد الخادم رمز الاستمرار — لم يُنشأ حساب.';
      return false;
    }
    _continuationToken = token;
    return true;
  }

  Future<void> _finalizeNewMember() async {
    final password = _passwordController.text;
    if (password.length < 6) {
      setState(() => _error = 'كلمة المرور لا تقل عن 6 خانات.');
      return;
    }
    if (password != _confirmController.text) {
      setState(() => _error = 'كلمتا المرور غير متطابقتين.');
      return;
    }
    final token = _continuationToken;
    if (token == null) {
      setState(() {
        _stage = _ActivationStage.waitingOwner;
        _error = 'تحقق من موافقة المالك مرة أخرى.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    MemberFinalizationOutcome result;
    try {
      result = await _auth.finalizeMember(
        continuationToken: token,
        password: password,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'تعذر إكمال الحساب — لم نعلن تنشيطه.';
      });
      return;
    }

    if (!mounted) return;
    if (result.outcome == 'confirmed') {
      try {
        await _auth.signIn(phoneOrEmail: _phone, password: password);
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = 'اكتمل الحساب لكن تعذر تسجيل الدخول. سجّل الدخول يدويًا.';
        });
        return;
      }
      if (!mounted) return;
      setState(() => _busy = false);
      if (_auth.isAuthenticated) {
        _reportActivation();
      } else {
        setState(() => _error = 'لم تبدأ جلسة دخول — لم نعلن التنشيط.');
      }
      return;
    }

    setState(() {
      _busy = false;
      switch (result.outcome) {
        case 'not_ready':
          _stage = _ActivationStage.waitingOwner;
          _status = 'بانتظار تأكيد مالك البئر';
          _error = 'لم يكتمل تأكيد المالك بعد.';
        case 'finalization_failed':
          _error = 'فشل إكمال الحساب — لم يُفعّل الوصول.';
        case 'auth_creation_failed':
          _error = 'تعذر إنشاء الحساب. لا تحاول إنشاءه من مسار آخر.';
        case 'compensation_failed':
          _error = 'تحتاج الحالة إلى معالجة من الخادم. لا تعِد إنشاء الحساب.';
        case 'completion_ambiguous':
          _error =
              'نحمي حالة الإكمال الآن — لا تنشئ حسابًا آخر. تواصل مع الدعم.';
        default:
          _error = 'تعذر إكمال الحساب — لم نعلن تنشيطه.';
      }
    });
  }

  Future<void> _signInExisting() async {
    final password = _existingPasswordController.text;
    if (password.isEmpty) {
      setState(() => _error = 'أدخل كلمة مرور حسابك.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _auth.signIn(phoneOrEmail: _phone, password: password);
      if (!_auth.isAuthenticated) {
        throw const AuthException('No authenticated session');
      }
      final invitations = await _team.listMyInvitations();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _invitations = invitations;
        _stage = _ActivationStage.existingInvitations;
        _status = invitations.isEmpty
            ? 'لا توجد دعوات معلّقة لهذا الحساب'
            : null;
      });
    } on AuthException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'كلمة مرور الحساب غير صحيحة.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'تعذر قراءة دعوات الحساب — لم يُقبل أي شيء.';
      });
    }
  }

  Future<void> _acceptInvitation(MyWellInvitation invitation) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    InvitationActionResult result;
    try {
      result = await _team.acceptInvitation(invitation.invitationId);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'تعذر قبول الدعوة — لم يُمنح وصول.';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);

    if (result.outcome == 'already_confirmed') {
      _reportActivation();
      return;
    }
    if (result.outcome == 'accepted_pending_owner' ||
        result.outcome == 'already_accepted') {
      setState(() {
        _stage = _ActivationStage.existingWaiting;
        _status = 'تم قبول الدعوة — بانتظار تأكيد المالك';
      });
      return;
    }
    setState(() {
      _error = result.outcome == 'expired'
          ? 'انتهت الدعوة.'
          : 'تعذر قبول الدعوة في حالتها الحالية.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          'تنشيط حساب عضو',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'أدخل رقمك ورمز الدعوة أولًا. لن يُنشأ حساب ولن يُمنح وصول '
                'قبل موافقة مالك البئر.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 18),
              if (_stage == _ActivationStage.validation) _validationFields(),
              if (_status != null) ...[
                _stateMessage(_status!, isError: false),
                const SizedBox(height: 12),
              ],
              if (_stage == _ActivationStage.waitingOwner)
                _fullButton('تحقق من موافقة المالك', _validateInvitation),
              if (_stage == _ActivationStage.choosePassword)
                _newPasswordFields(),
              if (_stage == _ActivationStage.existingPassword)
                _existingPasswordField(),
              if (_stage == _ActivationStage.existingInvitations)
                _existingInvitationList(),
              if (_error != null) ...[
                const SizedBox(height: 12),
                _stateMessage(_error!, isError: true),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _validationFields() {
    return Column(
      children: [
        TextFormField(
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          inputFormatters: [
            ArabicToEnglishDigitsFormatter(),
            LengthLimitingTextInputFormatter(16),
          ],
          decoration: const InputDecoration(
            labelText: 'رقم هاتفك *',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.phone_android),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          inputFormatters: [
            ArabicToEnglishDigitsFormatter(),
            LengthLimitingTextInputFormatter(6),
          ],
          decoration: const InputDecoration(
            labelText: 'رمز الدعوة *',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 18),
        _fullButton('التحقق من الدعوة', _validateInvitation),
      ],
    );
  }

  Widget _newPasswordFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'بانتظار اختيار كلمة المرور',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        _passwordField(_passwordController, 'كلمة المرور *'),
        const SizedBox(height: 12),
        _passwordField(_confirmController, 'تأكيد كلمة المرور *'),
        const SizedBox(height: 18),
        _fullButton('إكمال إنشاء الحساب', _finalizeNewMember),
      ],
    );
  }

  Widget _existingPasswordField() {
    return Column(
      children: [
        _passwordField(_existingPasswordController, 'كلمة مرور الحساب *'),
        const SizedBox(height: 18),
        _fullButton('تسجيل الدخول وعرض الدعوات', _signInExisting),
      ],
    );
  }

  Widget _passwordField(TextEditingController controller, String label) {
    return TextFormField(
      controller: controller,
      obscureText: _obscure,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          tooltip: _obscure ? 'إظهار كلمة المرور' : 'إخفاء كلمة المرور',
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
        ),
      ),
    );
  }

  Widget _existingInvitationList() {
    if (_invitations.isEmpty) return const SizedBox.shrink();
    return Column(
      children: _invitations
          .map((invitation) {
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      invitation.wellName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(_roleLabel(invitation.role)),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _acceptInvitation(invitation),
                      child: const Text('قبول الدعوة'),
                    ),
                  ],
                ),
              ),
            );
          })
          .toList(growable: false),
    );
  }

  Widget _stateMessage(String message, {required bool isError}) {
    final color = isError ? AppColors.error : AppColors.deepBlue;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          message,
          style: TextStyle(color: color, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _fullButton(String label, Future<void> Function() action) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton(
        onPressed: _busy ? null : action,
        child: Text(label),
      ),
    );
  }

  static String _roleLabel(String role) {
    return switch (role) {
      'owner' => 'مالك',
      'operator' => 'مشغّل',
      'partner' => 'شريك',
      'manager' => 'مدير',
      _ => role,
    };
  }
}

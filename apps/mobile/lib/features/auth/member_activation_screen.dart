import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api/auth_repository.dart';
import '../../core/api/team_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/digit_utils.dart';

/// شاشة تنشيط عضو مدعو (ق-123 / هجرة 094 / م-41E المرحلة 3).
///
/// **لماذا يُدخل العضو رمزه هنا لا في شاشة الدخول:** معرفة أن لرقمٍ دعوةً
/// **قبل** المصادقة تحتاج عقدًا ينفّذه المستخدم المجهول، وحدّ
/// «صفر تنفيذ لـ`anon`» ثابت مقيس بحرس دائم. فالمسار: يُنشئ العضو حسابه
/// بكلمة مروره التي يختارها هو، ثم يُثبت الدعوة برمزها. وهذا **يفشي أقل**
/// من سؤال الخادم قبل المصادقة لا أكثر.
///
/// ولا كلمة مرور يكتبها المالك لأحد (الثابت 706).
class MemberActivationScreen extends StatefulWidget {
  const MemberActivationScreen({
    this.authRepository,
    this.teamRepository,
    this.onActivated,
    super.key,
  });

  final AuthRepository? authRepository;
  final TeamRepository? teamRepository;

  /// يُنادى بعد **تعيين نافذ حقيقي** على بئر، لا بعد إنشاء الحساب.
  final VoidCallback? onActivated;

  @override
  State<MemberActivationScreen> createState() => _MemberActivationScreenState();
}

class _MemberActivationScreenState extends State<MemberActivationScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  late TeamRepository _team;
  bool _isSubmitting = false;
  bool _obscure = true;
  String? _error;
  String? _notice;

  /// يصير `true` بعد نجاح المصادقة، فتبقى المطالبة وحدها مطلوبة عند
  /// إعادة المحاولة — فلا يُعاد إنشاء حساب موجود.
  bool _authenticated = false;

  @override
  void initState() {
    super.initState();
    _team = widget.teamRepository ?? TeamRepository();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  AuthRepository get _auth {
    final injected = widget.authRepository;
    if (injected != null) return injected;
    return AuthRepository(Supabase.instance.client);
  }

  /// سلّم مصادقة حتمي: دخول بحساب قائم أولًا، وإلا إنشاء حساب جديد.
  /// وإخفاق الإنشاء لوجود الحساب يُقال صريحًا بدل «تعذر» عامة.
  Future<bool> _ensureAuthenticated({
    required String phone,
    required String password,
    required String name,
  }) async {
    if (_authenticated) return true;

    try {
      await _auth.signIn(phoneOrEmail: phone, password: password);
      if (_auth.isAuthenticated) {
        _authenticated = true;
        return true;
      }
    } on AuthException {
      // ليس حسابًا قائمًا بهذه الكلمة — نُجرّب الإنشاء.
    } catch (_) {
      setState(() => _error = 'تعذر الاتصال بالخادم — لم يُنشأ شيء.');
      return false;
    }

    try {
      await _auth.signUpMember(
        phone: phone,
        password: password,
        fullName: name,
      );
    } on AuthException {
      setState(() {
        _error = 'يوجد حساب بهذا الرقم وكلمة المرور غير مطابقة. '
            'سجّل الدخول بحسابك ثم أدخل رمز التنشيط.';
      });
      return false;
    } catch (_) {
      setState(() => _error = 'تعذر الاتصال بالخادم — لم يُنشأ شيء.');
      return false;
    }

    if (!_auth.isAuthenticated) {
      setState(() {
        _error = 'لم تُنشأ جلسة دخول — أعد المحاولة.';
      });
      return false;
    }

    _authenticated = true;
    return true;
  }

  Future<void> _activate() async {
    final name = _nameController.text.trim();
    final phone = normalizeArabicDigits(_phoneController.text).trim();
    final code = normalizeArabicDigits(_codeController.text).trim();
    final password = _passwordController.text;
    final confirm = _confirmController.text;

    if (name.isEmpty) {
      setState(() => _error = 'أدخل اسمك كما تريد ظهوره على السندات.');
      return;
    }
    if (phone.length < 9) {
      setState(() => _error = 'أدخل رقم هاتفك من 9 أرقام.');
      return;
    }
    if (code.length != 6) {
      setState(() => _error = 'رمز التنشيط ستة أرقام.');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'كلمة المرور لا تقل عن 6 خانات.');
      return;
    }
    if (password != confirm) {
      setState(() => _error = 'كلمتا المرور غير متطابقتين.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
      _notice = null;
    });

    final ready = await _ensureAuthenticated(
      phone: phone,
      password: password,
      name: name,
    );

    if (!mounted) return;
    if (!ready) {
      setState(() => _isSubmitting = false);
      return;
    }

    ClaimResult? result;
    try {
      result = await _team.claimInvitation(code);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _error = 'تعذر التحقق من الرمز — لم يُمنح أي وصول. أعد المحاولة.';
      });
      return;
    }

    if (!mounted) return;
    setState(() => _isSubmitting = false);

    if (result.isSuccess) {
      widget.onActivated?.call();
      return;
    }

    if (result.isWrongCode) {
      final left = result.attemptsLeft;
      setState(() {
        _error = left == null
            ? 'رمز التنشيط غير صحيح.'
            : 'رمز التنشيط غير صحيح — بقيت $left محاولات.';
        _notice = 'حسابك جاهز؛ يكفي إدخال الرمز الصحيح.';
      });
      return;
    }

    setState(() {
      _error = 'لا توجد دعوة سارية لرقمك.';
      _notice = 'اطلب من مالك البئر أن يدعوك، أو أن يعيد إصدار الرمز.';
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
                'أضافك مالك البئر وأعطاك رمزًا من ستة أرقام. أدخله مع رقمك '
                'واختر كلمة مرورك — لا يعرفها أحد غيرك.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'اسمك كما يظهر على السندات *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  ArabicToEnglishDigitsFormatter(),
                  LengthLimitingTextInputFormatter(9),
                ],
                decoration: const InputDecoration(
                  labelText: 'رقم هاتفك (7xxxxxxxx) *',
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
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 8,
                ),
                decoration: const InputDecoration(
                  labelText: 'رمز التنشيط *',
                  hintText: '------',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passwordController,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'كلمة المرور الجديدة *',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirmController,
                obscureText: _obscure,
                decoration: const InputDecoration(
                  labelText: 'تأكيد كلمة المرور *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.error),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _error!,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.error,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_notice != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          _notice!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.agriculturalGreen,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _isSubmitting ? null : _activate,
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'تنشيط الحساب',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'لا يوجد إرسال رسائل نصية في هذا الإصدار: الرمز يأخذه العضو '
                'من مالك البئر مباشرة.',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

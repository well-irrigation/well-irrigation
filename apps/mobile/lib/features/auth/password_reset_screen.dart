import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api/auth_repository.dart';
import '../../core/theme/app_colors.dart';

/// شاشة إعادة تعيين كلمة المرور برمز سلّمه المالك باليد (م-41F / هجرة 096).
///
/// لماذا بهذا الشكل: من ينسى كلمة مروره لا جلسة له، فلا يستطيع أي عقد في
/// القاعدة أن يخدمه؛ والمالك **لا يكتب** له كلمة مرور (الثابت 706). فالمسار:
/// المالك يتحقق من هويته أمامه ويُصدر رمزًا يقرأه عليه، ثم **صاحب الحساب
/// وحده** يكتب كلمة مروره هنا.
///
/// ولا رسائل نصية في هذا الإصدار، والشاشة تقول ذلك صريحًا بدل أن تُظهر زرّ
/// «أرسل رمزًا» لا يرسل شيئًا.
class PasswordResetScreen extends StatefulWidget {
  const PasswordResetScreen({
    this.authRepository,
    this.onDone,
    super.key,
  });

  final AuthRepository? authRepository;

  /// يُنادى بعد نجاح إعادة التعيين وحده، لا بعد أي نداء ناجح.
  final VoidCallback? onDone;

  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _isSubmitting = false;
  bool _obscure = true;
  bool _done = false;
  String? _error;

  @override
  void dispose() {
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

  /// النجاح يُعلن **بعد نتيجة الخادم وحدها**، ولكل حالة معلنة رسالتها: من
  /// يبحث عن العطب في غير موضعه يفقد وقته ومحاولاته.
  Future<void> _submit() async {
    final phone = _phoneController.text.trim();
    final code = _codeController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmController.text;

    if (phone.length < 9) {
      setState(() => _error = 'أدخل رقم هاتفك كما سجّله مالك البئر');
      return;
    }
    if (code.length != 6) {
      setState(() => _error = 'الرمز ستة أرقام كما أعطاك المالك');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'كلمة المرور ستة أحرف على الأقل');
      return;
    }
    if (password != confirm) {
      setState(() => _error = 'كلمتا المرور غير متطابقتين');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    PasswordResetOutcome result;
    try {
      result = await _auth.resetPasswordWithCode(
        phone: phone,
        code: code,
        newPassword: password,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _error = 'تعذر الاتصال بالخادم — لم تتغيّر كلمة المرور.\n\n$error';
      });
      return;
    }

    if (!mounted) return;

    if (result.isSuccess) {
      setState(() {
        _isSubmitting = false;
        _done = true;
      });
      return;
    }

    setState(() {
      _isSubmitting = false;
      _error = _messageFor(result);
    });
  }

  static String _messageFor(PasswordResetOutcome result) {
    if (result.isWrongCode) {
      final left = result.attemptsLeft;
      return left == null
          ? 'الرمز غير صحيح — لم تتغيّر كلمة المرور'
          : 'الرمز غير صحيح — بقيت $left محاولات';
    }
    if (result.hasNoTicket) {
      return 'لا يوجد رمز سارٍ لرقمك. اطلب من مالك البئر إصدار رمز جديد '
          'بعد أن يتحقق من هويتك.';
    }
    if (result.isWeakPassword) {
      return 'كلمة المرور قصيرة — لم يُرسل أي طلب';
    }
    if (result.isTicketSpent) {
      return 'استُهلك الرمز ولم تُطبَّق كلمة المرور. اطلب رمزًا جديدًا من '
          'المالك — كلمة مرورك القديمة لم تتغيّر.';
    }
    return 'خدمة إعادة التعيين غير متاحة الآن — لم يتغيّر شيء';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.deepBlue,
        foregroundColor: Colors.white,
        title: const Text('إعادة تعيين كلمة المرور'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: _done ? _successView() : _formView(),
        ),
      ),
    );
  }

  Widget _successView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        const Icon(
          Icons.lock_reset,
          size: 48,
          color: AppColors.agriculturalGreen,
        ),
        const SizedBox(height: 16),
        const Text(
          'تغيّرت كلمة مرورك',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.deepBlue,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'ادخل الآن برقمك وكلمة المرور الجديدة. والرمز الذي استعملته انتهى '
          'ولا يعمل مرة أخرى.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: widget.onDone,
          child: const Text('العودة إلى الدخول'),
        ),
      ],
    );
  }

  Widget _formView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'الرمز يعطيك إياه مالك البئر بعد أن يتحقق من هويتك أمامه. لا تُرسل '
          'رسائل نصية في هذا الإصدار، ولا يكتب أحد كلمة مرورك: تكتبها أنت '
          'هنا وحدك.',
          style: TextStyle(
            fontSize: 13,
            color: AppColors.textSecondary,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 20),
        TextFormField(
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'رقم هاتفك',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.phone_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            letterSpacing: 8,
          ),
          decoration: const InputDecoration(
            labelText: 'رمز إعادة التعيين',
            hintText: '------',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _passwordController,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: 'كلمة المرور الجديدة',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _confirmController,
          obscureText: _obscure,
          decoration: const InputDecoration(
            labelText: 'تأكيد كلمة المرور',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.lock_outline),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.error),
            ),
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: AppColors.error),
            ),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: Text(
            _isSubmitting ? 'جارٍ التحقق…' : 'تعيين كلمة المرور',
          ),
        ),
      ],
    );
  }
}

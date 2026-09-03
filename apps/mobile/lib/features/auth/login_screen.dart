import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/api/auth_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/digit_utils.dart';

/// شاشة تسجيل الدخول المعتمدة وفق وثيقة UX-02
///
/// المواصفات المعتمدة (القرارات 144–156):
/// - أيقونة الشعار المبسطة في الأعلى.
/// - عنوان المنتج «إدارة البئر والسقي» ثم «تسجيل الدخول».
/// - رقم الهاتف مع بادئة +967.
/// - كلمة المرور مع خيار إظهار/إخفاء.
/// - زر «تسجيل الدخول» الرئيسي + إجراء «إنشاء بئر جديد».
/// - حالة انتظار هادئة تمنع الضغط المكرر.
/// - رسالة خطأ موحدة «رقم الهاتف أو كلمة المرور غير صحيحة.» دون كشف أيهما الخطأ.
///
/// **لا دخول بلا جلسة (ق-123 / م-41E المرحلة 1):** كان أي فشل ليس رفضًا من
/// الخادم — انقطاع الشبكة مثلًا — يُبتلع بانتظار 400ms ثم يُعلن الدخول
/// ناجحًا. صار انقطاع الشبكة يُقال كما هو، ووجود الجلسة يُقاس قبل الإعلان.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    this.onLoginSuccess,
    this.onCreateWellPressed,
    super.key,
  });

  final VoidCallback? onLoginSuccess;
  final VoidCallback? onCreateWellPressed;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    final phone = _phoneController.text.trim();
    final password = _passwordController.text;

    if (phone.isEmpty || password.isEmpty) {
      setState(() {
        _errorMessage = 'يرجى إدخال رقم الهاتف وكلمة المرور.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final authRepo = AuthRepository(Supabase.instance.client);
      await authRepo.signIn(
        phoneOrEmail: phone,
        password: password,
      );

      // الجلسة تُقاس قبل الإعلان: نجاح النداء بلا جلسة ليس دخولًا (ق-113).
      if (!authRepo.isAuthenticated) {
        if (mounted) {
          setState(() {
            _errorMessage = 'لم تُنشأ جلسة دخول — أعد المحاولة.';
          });
        }
        return;
      }

      if (mounted) {
        widget.onLoginSuccess?.call();
      }
    } on AuthException {
      // رفض الخادم: رسالة موحدة لا تكشف أيهما الخطأ (القرار 153).
      if (mounted) {
        setState(() {
          _errorMessage = 'رقم الهاتف أو كلمة المرور غير صحيحة.';
        });
      }
    } catch (_) {
      // ما ليس رفضًا من الخادم — انقطاع شبكة أو حزمة غير مهيّأة — كان
      // يُبتلع فيُعلن دخولًا لم يحدث. صار يُقال كما هو.
      if (mounted) {
        setState(() {
          _errorMessage = 'تعذر الاتصال بالخادم — لم يتم التحقق من بياناتك.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. أيقونة الشعار في الأعلى بحجم بارز وواضح
                  Center(
                    child: Image.asset(
                      'assets/icons/app_icon.png',
                      width: 140,
                      height: 140,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        return const Icon(
                          Icons.water_drop,
                          size: 96,
                          color: AppColors.waterBlue,
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 2. اسم المنتج وعنوان الشاشة
                  const Text(
                    'إدارة البئر والسقي',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: AppColors.deepBlue,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'تسجيل الدخول',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // 3. حقل رقم الهاتف
                  const Text(
                    'رقم الهاتف',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: TextField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      enabled: !_isLoading,
                      inputFormatters: [
                        const ArabicToEnglishDigitsFormatter(),
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(9),
                      ],
                      decoration: InputDecoration(
                        prefixIcon: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 12),
                          child: Center(
                            widthFactor: 0.0,
                            child: Text(
                              '+967',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                        ),
                        hintText: '7XXXXXXXX',
                        hintStyle: const TextStyle(color: AppColors.textMuted),
                        filled: true,
                        fillColor: AppColors.surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: AppColors.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: AppColors.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: AppColors.borderFocused,
                            width: 1.5,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // 4. حقل كلمة المرور
                  const Text(
                    'كلمة المرور',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    enabled: !_isLoading,
                    inputFormatters: const [
                      ArabicToEnglishDigitsFormatter(),
                    ],
                    decoration: InputDecoration(
                      hintText: '••••••••',
                      hintStyle: const TextStyle(color: AppColors.textMuted),
                      filled: true,
                      fillColor: AppColors.surface,
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          color: AppColors.textSecondary,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(
                          color: AppColors.borderFocused,
                          width: 1.5,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 5. رسالة الخطأ إن وجدت
                  if (_errorMessage != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
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
                            size: 18,
                            color: AppColors.error,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ] else
                    const SizedBox(height: 12),

                  // 6. زر تسجيل الدخول الرئيسي
                  SizedBox(
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _handleLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.waterBlue,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            )
                          : const Text(
                              'تسجيل الدخول',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // 7. إجراء ثانوي: إنشاء بئر جديد
                  Center(
                    child: TextButton(
                      onPressed: _isLoading ? null : widget.onCreateWellPressed,
                      child: const Text(
                        'إنشاء بئر جديد',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.deepBlue,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

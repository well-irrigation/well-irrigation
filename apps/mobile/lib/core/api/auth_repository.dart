import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/digit_utils.dart';

/// مستودع إدارة المصادقة والجلسات عبر Supabase Auth (ق-84 / ق-110)
class AuthRepository {
  const AuthRepository(this._client);

  final SupabaseClient _client;

  bool get isAuthenticated => _client.auth.currentSession != null;
  User? get currentUser => _client.auth.currentUser;
  String? get currentUserId => _client.auth.currentUser?.id;

  /// تحويل رقم الهاتف إلى بريد هوية داخلي موثوق لنظام المصادقة
  static String phoneToInternalEmail(String phone) {
    final digits = normalizeArabicDigits(phone).replaceAll(RegExp(r'\D'), '');
    return '$digits@phone.well-irrigation.local';
  }

  /// تسجيل الدخول برقم الهاتف وكلمة المرور
  ///
  /// يدعم أرقام الهواتف اليمنية مع التنسيق الدولي (+967) أو البريد الإلكتروني.
  /// يتم توحيد الأرقام العربية إلى الإنجليزية تلقائياً لضمان تطابق كلمات المرور وأرقام الهواتف.
  Future<AuthResponse> signIn({
    required String phoneOrEmail,
    required String password,
  }) async {
    final cleanInput = normalizeArabicDigits(phoneOrEmail.trim());
    final cleanPassword = normalizeArabicDigits(password);

    if (cleanInput.contains('@')) {
      return _client.auth.signInWithPassword(
        email: cleanInput,
        password: cleanPassword,
      );
    }

    final internalEmail = phoneToInternalEmail(cleanInput);

    return _client.auth.signInWithPassword(
      email: internalEmail,
      password: cleanPassword,
    );
  }

  /// تسجيل حساب مالك جديد
  Future<AuthResponse> signUpOwner({
    required String phone,
    required String password,
    required String fullName,
  }) async {
    final cleanPhone = normalizeArabicDigits(phone.trim());
    final cleanPassword = normalizeArabicDigits(password);
    final formattedPhone = cleanPhone.startsWith('+')
        ? cleanPhone
        : '+967$cleanPhone';
    final internalEmail = phoneToInternalEmail(cleanPhone);

    return _client.auth.signUp(
      email: internalEmail,
      password: cleanPassword,
      data: {
        'phone': formattedPhone,
        'full_name': fullName.trim(),
      },
    );
  }

  /// تسجيل الخروج الآمن
  Future<void> signOut() async {
    await _client.auth.signOut();
  }
}

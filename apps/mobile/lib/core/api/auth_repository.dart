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

  /// تسجيل حساب عضو فريق مدعو (ق-123 / م-41E المرحلة 3).
  ///
  /// نفس هوية الدخول في [signUpOwner] — بريد صُوري مُشتق من الرقم — والفرق
  /// أن هذا الحساب **لا يُنشئ بئرًا**: صلاحيته تأتي من المطالبة بدعوة
  /// (`api.claim_well_invitation`) وحدها. والاسم يكتبه صاحبه لأنه ما
  /// يُطبع على سند القبض (الثابت 705)، ولا يُقرأ قبل المصادقة.
  Future<AuthResponse> signUpMember({
    required String phone,
    required String password,
    required String fullName,
  }) async {
    final cleanPhone = normalizeArabicDigits(phone.trim());
    final cleanPassword = normalizeArabicDigits(password);
    final formattedPhone = cleanPhone.startsWith('+')
        ? cleanPhone
        : '+967$cleanPhone';

    return _client.auth.signUp(
      email: phoneToInternalEmail(cleanPhone),
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

  /// إعادة تعيين كلمة المرور برمز سلّمه المالك باليد (م-41F / هجرة 096).
  ///
  /// تُنفَّذ عند **طرف خادمي** لا في القاعدة ولا هنا: الاستعادة تحدث قبل
  /// الدخول، وحدّ «لا تنفيذ لغير المسجَّل» في القاعدة يمنع أي عقد يناديه من
  /// لا جلسة له. وكلمة المرور يختارها صاحبها ولا يكتبها أحد له (الثابت 706).
  ///
  /// ما يعيده الطرف الخادمي يُعرض كما هو: لا اشتقاق ولا تفسير محلي، وفشل
  /// الاتصال يبقى استثناءً يظهر للمستخدم لا نجاحًا صامتًا (ق-113).
  Future<PasswordResetOutcome> resetPasswordWithCode({
    required String phone,
    required String code,
    required String newPassword,
  }) async {
    try {
      final response = await _client.functions.invoke(
        'reset-password',
        body: {
          'phone': normalizeArabicDigits(phone.trim()),
          'code': normalizeArabicDigits(code.trim()),
          'new_password': normalizeArabicDigits(newPassword),
        },
      );

      final data = response.data;
      if (data is Map<String, dynamic>) {
        return PasswordResetOutcome.fromJson(data);
      }
      throw const FormatException(
        'استجابة غير متوقعة من طرف إعادة التعيين',
      );
    } on FunctionException catch (error) {
      // الطرف الخادمي يعيد حالته في جسم الرد مع رمز حالة غير 2xx،
      // فالحالة المعلنة تُقرأ ولا تُبدَّل بخطأ عام.
      final details = error.details;
      if (details is Map<String, dynamic> && details['outcome'] is String) {
        return PasswordResetOutcome.fromJson(details);
      }
      rethrow;
    }
  }
}

/// نتيجة إعادة التعيين كما أعلنها الطرف الخادمي حرفيًّا.
class PasswordResetOutcome {
  const PasswordResetOutcome({required this.outcome, this.attemptsLeft});

  factory PasswordResetOutcome.fromJson(Map<String, dynamic> json) {
    return PasswordResetOutcome(
      outcome: json['outcome'] as String? ?? '',
      attemptsLeft: (json['attempts_left'] as num?)?.toInt(),
    );
  }

  final String outcome;
  final int? attemptsLeft;

  bool get isSuccess => outcome == 'ok';
  bool get isWrongCode => outcome == 'wrong_code';
  bool get hasNoTicket => outcome == 'no_ticket';
  bool get isWeakPassword => outcome == 'weak_password';

  /// استُهلكت التذكرة ولم تُطبَّق كلمة المرور: حالة تُقال صريحة، فصاحبها
  /// يحتاج رمزًا جديدًا ولا يظن أن كلمة مروره تغيّرت.
  bool get isTicketSpent => outcome == 'ticket_spent_not_applied';
}

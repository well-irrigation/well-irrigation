import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/digit_utils.dart';

/// مستودع إدارة المصادقة والجلسات عبر Supabase Auth (ق-84 / ق-110)
class AuthRepository {
  const AuthRepository(this._client);

  final SupabaseClient _client;

  bool get isAuthenticated => _client.auth.currentSession != null;
  User? get currentUser => _client.auth.currentUser;
  String? get currentUserId => _client.auth.currentUser?.id;

  /// نطاق البريد الداخلي الذي يُبنى من رقم الهاتف.
  ///
  /// **قرار هوية دائم.** كل حساب يُنشأ بهذا النطاق، وتغييره بعد وجود
  /// حسابات يفصل أصحابها عن حساباتهم — فيصير رقم الهاتف نفسه بريدًا آخر
  /// لا يعرفه نظام المصادقة. تغييره ممكن بلا كلفة **فقط** بينما القاعدة
  /// بلا حسابات.
  ///
  /// وكان `phone.well-irrigation.local` فرفضه الإنتاج في أول تسجيل حقيقي
  /// (`email_address_invalid`): الامتداد `.local` ليس نطاقًا عامًّا صالحًا،
  /// والقاعدة المحلية كانت تقبله — فنجحت 354 اختبارًا و603 تحققات ولم
  /// يكشفه شيء. هذا ما لا يقيسه إلا التشغيل الحقيقي.
  static const String _identityEmailDomain = 'phone.wellirrigation.app';

  /// تحويل رقم الهاتف إلى بريد هوية داخلي موثوق لنظام المصادقة
  static String phoneToInternalEmail(String phone) {
    final digits = normalizeArabicDigits(phone).replaceAll(RegExp(r'\D'), '');
    return '$digits@$_identityEmailDomain';
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
      data: {'phone': formattedPhone, 'full_name': fullName.trim()},
    );
  }

  /// عقد تاريخي متروك لتوافق الاستدعاءات القديمة فقط.
  ///
  /// مسار ق-130 الحالي لا يستعمله؛ إنشاء العضو الجديد يتم حصريًا عبر
  /// [finalizeMember] بعد قبول الدعوة وتأكيد المالك.
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
      data: {'phone': formattedPhone, 'full_name': fullName.trim()},
    );
  }

  /// يتحقق من دعوة العضو قبل المصادقة عبر طرف M104 الموثوق.
  Future<MemberValidationOutcome> validateMemberFinalization({
    required String phone,
    required String code,
  }) async {
    final data = await _invokeMemberFinalization({
      'operation': 'validate',
      'phone': normalizeArabicDigits(phone.trim()),
      'code': normalizeArabicDigits(code.trim()),
    });
    return MemberValidationOutcome.fromJson(data);
  }

  /// ينشئ الحساب ويربطه بالدعوة بعد تأكيد المالك فقط.
  Future<MemberFinalizationOutcome> finalizeMember({
    required String continuationToken,
    required String password,
  }) async {
    final data = await _invokeMemberFinalization({
      'operation': 'finalize',
      'continuation_token': continuationToken,
      'password': normalizeArabicDigits(password),
    });
    return MemberFinalizationOutcome.fromJson(data);
  }

  Future<Map<String, dynamic>> _invokeMemberFinalization(
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await _client.functions.invoke(
        'member-finalization',
        body: body,
      );
      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      throw const FormatException('استجابة غير متوقعة من طرف تنشيط العضو');
    } on FunctionException catch (error) {
      final details = error.details;
      if (details is Map<String, dynamic> && details['outcome'] is String) {
        return details;
      }
      rethrow;
    }
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
      throw const FormatException('استجابة غير متوقعة من طرف إعادة التعيين');
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

class MemberValidationOutcome {
  const MemberValidationOutcome({
    required this.outcome,
    this.continuationToken,
    this.continuationExpiresAt,
    this.attemptsLeft,
  });

  factory MemberValidationOutcome.fromJson(Map<String, dynamic> json) {
    final rawExpiry = json['continuation_expires_at'] as String?;
    return MemberValidationOutcome(
      outcome: json['outcome'] as String? ?? '',
      continuationToken: json['continuation_token'] as String?,
      continuationExpiresAt: rawExpiry == null
          ? null
          : DateTime.tryParse(rawExpiry),
      attemptsLeft: (json['attempts_left'] as num?)?.toInt(),
    );
  }

  final String outcome;
  final String? continuationToken;
  final DateTime? continuationExpiresAt;
  final int? attemptsLeft;
}

class MemberFinalizationOutcome {
  const MemberFinalizationOutcome({required this.outcome});

  factory MemberFinalizationOutcome.fromJson(Map<String, dynamic> json) {
    return MemberFinalizationOutcome(outcome: json['outcome'] as String? ?? '');
  }

  final String outcome;
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

import 'package:supabase_flutter/supabase_flutter.dart';
import 'app_bootstrap_repository.dart';
import '../session/offline_session_coordinator.dart';

/// نماذج بيانات الحساب والإعدادات والفريق والمزامنة (UX-16A / القرارات 527–600 / ق-101)

class UserProfileData {
  const UserProfileData({
    required this.id,
    required this.fullName,
    required this.phone,
    this.isPlatformAdmin = false,
    this.rolesSummary = const [],
    this.farmerAccountLink,
  });

  final String id;
  final String fullName;
  final String phone;
  final bool isPlatformAdmin;

  /// أدوار المستخدم على آباره كما بُنيت من العقد. فارغة = لا دور معروف، ولا
  /// يُفترض هنا دور مالك على بئر باسم ثابت (ق-113).
  final List<String> rolesSummary;
  final String? farmerAccountLink;

  factory UserProfileData.fromJson(Map<String, dynamic> json) {
    return UserProfileData(
      id: json['id'] as String? ?? '',
      fullName: json['full_name'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      isPlatformAdmin: json['is_platform_admin'] as bool? ?? false,
      rolesSummary: (json['roles_summary'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      farmerAccountLink: json['farmer_account_link'] as String?,
    );
  }

  UserProfileData copyWith({
    String? fullName,
    String? phone,
    bool? isPlatformAdmin,
    List<String>? rolesSummary,
    String? farmerAccountLink,
  }) {
    return UserProfileData(
      id: id,
      fullName: fullName ?? this.fullName,
      phone: phone ?? this.phone,
      isPlatformAdmin: isPlatformAdmin ?? this.isPlatformAdmin,
      rolesSummary: rolesSummary ?? this.rolesSummary,
      farmerAccountLink: farmerAccountLink ?? this.farmerAccountLink,
    );
  }
}

/// حالة الجهاز والمزامنة كما هي **مقيسة فعلًا** لا كما نتمناها.
///
/// أي حقل غير مقيس يبقى `null` ولا يُخمَّن: قياس الاتصال بالخادم وحالة
/// الإرسال الخلفي يأتيان مع شاشات الجاهزية (W2-02d / ق-90)، وقبل ذلك
/// إعلانهما «يعمل» ادعاء بلا دليل.
class DeviceSyncStatusModel {
  const DeviceSyncStatusModel({
    required this.localStorageReady,
    required this.pendingOperationsCount,
    this.lastSyncTime,
    this.isOnline,
    this.backgroundSyncActive,
  });

  /// مقيس: الطابور المستعمل مخزَّن على قرص الهاتف لا في الذاكرة وحدها.
  final bool localStorageReady;

  /// مقيس: عدد العمليات المعلَّقة في الطابور نفسه.
  final int pendingOperationsCount;

  /// مسجَّل في الطابور؛ `null` تعني «لم تنجح مزامنة بعد».
  final DateTime? lastSyncTime;

  /// `null` تعني «غير مقيس بعد».
  final bool? isOnline;

  /// `null` تعني «غير مقيس بعد».
  final bool? backgroundSyncActive;
}

/// يُرفع عند طلب مزامنة يدوية ولا ناقل مزامنة موصول بعد (W2-02d / ق-90).
/// وجوده يمنع تحويل «لم يُرسل شيء» إلى رسالة نجاح.
class ManualSyncUnavailableException implements Exception {
  const ManualSyncUnavailableException();

  @override
  String toString() => 'المزامنة اليدوية غير موصولة بعد';
}

/// يُرفع عند تغيير كلمة المرور بكلمة حالية غير صحيحة (ق-105 / ق-123).
///
/// كانت خانة «كلمة المرور الحالية» تُعرض وتُفرَّغ ولا تُقرأ، فيغيّر كلمةَ
/// المرور من يمسك الهاتف مفتوحًا دون معرفة القديمة. وجود هذا النوع يفصل
/// «كلمتك الحالية خطأ» عن «تعذر الاتصال»، فلا يُقال أحدهما مكان الآخر.
class WrongCurrentPasswordException implements Exception {
  const WrongCurrentPasswordException();

  @override
  String toString() => 'كلمة المرور الحالية غير صحيحة';
}

class AppSettingsModel {
  const AppSettingsModel({
    this.themeMode = 'light', // light, dark, system
    this.printerPaperSize = '58mm', // 58mm, 80mm
    this.bluetoothPrinterName,
    this.bluetoothPrinterMac,
    this.autoPrintReceipt = false,
    this.operationsAlerts = true,
    this.financialAlerts = true,
    this.syncAlerts = true,
  });

  final String themeMode;
  final String printerPaperSize;
  final String? bluetoothPrinterName;
  final String? bluetoothPrinterMac;
  final bool autoPrintReceipt;
  final bool operationsAlerts;
  final bool financialAlerts;
  final bool syncAlerts;

  AppSettingsModel copyWith({
    String? themeMode,
    String? printerPaperSize,
    String? bluetoothPrinterName,
    String? bluetoothPrinterMac,
    bool? autoPrintReceipt,
    bool? operationsAlerts,
    bool? financialAlerts,
    bool? syncAlerts,
  }) {
    return AppSettingsModel(
      themeMode: themeMode ?? this.themeMode,
      printerPaperSize: printerPaperSize ?? this.printerPaperSize,
      bluetoothPrinterName: bluetoothPrinterName ?? this.bluetoothPrinterName,
      bluetoothPrinterMac: bluetoothPrinterMac ?? this.bluetoothPrinterMac,
      autoPrintReceipt: autoPrintReceipt ?? this.autoPrintReceipt,
      operationsAlerts: operationsAlerts ?? this.operationsAlerts,
      financialAlerts: financialAlerts ?? this.financialAlerts,
      syncAlerts: syncAlerts ?? this.syncAlerts,
    );
  }
}

/// مستودع إدارة الحساب والإعدادات والفريق والمزامنة
class AccountRepository {
  final SupabaseClient? _client;
  final OfflineSessionCoordinator? _coordinatorOverride;

  AccountRepository([this._client, this._coordinatorOverride]);

  OfflineSessionCoordinator get _coordinator =>
      _coordinatorOverride ?? OfflineSessionCoordinator.instance;

  SupabaseClient? get _effectiveClient {
    try {
      return _client ?? Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  /// 1. جلب الملف الشخصي للمستخدم
  Future<UserProfileData> fetchUserProfile() async {
    final client = _effectiveClient;
    if (client == null || client.auth.currentSession == null) {
      throw StateError('Authenticated session is required');
    }

    final bootstrap =
        await AppBootstrapRepository(client).fetchBootstrap();

    String roleLabel(String role) {
      switch (role) {
        case 'owner':
          return 'مالك';
        case 'operator':
          return 'مشغل ميداني';
        case 'accountant':
          return 'محاسب';
        case 'partner':
          return 'شريك';
        case 'viewer':
          return 'مستعرض';
        default:
          return role;
      }
    }

    return UserProfileData(
      id: bootstrap.profile.id,
      fullName: bootstrap.profile.fullName,
      phone: bootstrap.profile.phone,
      isPlatformAdmin: bootstrap.profile.isPlatformAdmin,
      rolesSummary: [
        for (final well in bootstrap.wells)
          for (final role in well.roles)
            '${well.name} — ${roleLabel(role)}',
      ],
    );
  }

  /// 2. تحديث الاسم الشخصي
  Future<void> updateUserName(String newName) async {
    final cleanName = newName.trim();
    if (cleanName.isEmpty) {
      throw ArgumentError.value(
        newName,
        'newName',
        'Profile name is required',
      );
    }

    final client = _effectiveClient;
    if (client == null || client.auth.currentSession == null) {
      throw StateError('Authenticated session is required');
    }

    await client.schema('api').rpc(
      'update_profile_name',
      params: {'p_full_name': cleanName},
    );
  }

  /// 3. تغيير كلمة المرور بأمان
  ///
  /// [currentPassword] تُتحقَّق فعلًا بإعادة مصادقة على حساب الجلسة نفسه
  /// قبل أي تغيير (ق-105: إعادة مصادقة مناسبة). الخانة كانت تُعرض ولا
  /// تُقرأ، فكان من يمسك الهاتف مفتوحًا يغيّرها بلا معرفة القديمة.
  ///
  /// لا يُبتلع أي فشل: بلا جلسة مصدَّقة أو عند رفض الخادم يُرفع الخطأ
  /// كما هو، فلا تصل الشاشة إلى رسالة نجاح وكلمة المرور لم تتغير. ورفض
  /// إعادة المصادقة يُرفع نوعًا مسمّى لا رسالة عامة.
  Future<void> updatePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (newPassword.isEmpty) {
      throw ArgumentError.value(
        newPassword,
        'newPassword',
        'Password is required',
      );
    }

    if (currentPassword.isEmpty) {
      throw ArgumentError.value(
        currentPassword,
        'currentPassword',
        'Current password is required',
      );
    }

    final client = _effectiveClient;
    final email = client?.auth.currentUser?.email;
    if (client == null || email == null || email.isEmpty) {
      throw StateError('Authenticated session is required');
    }

    // إعادة المصادقة على بريد الجلسة نفسه — لا على رقم مأخوذ من الشاشة.
    try {
      await client.auth.signInWithPassword(
        email: email,
        password: currentPassword,
      );
    } on AuthException {
      throw const WrongCurrentPasswordException();
    }

    await client.auth.updateUser(
      UserAttributes(password: newPassword),
    );
  }

  /// 7. جلب حالة الجهاز والمزامنة — المقيس فقط
  ///
  /// العدد وتاريخ آخر مزامنة يُقرآن من الطابور نفسه، وجاهزية التخزين
  /// المحلي من نوع الطابور المستعمل فعلًا. الاتصال والإرسال الخلفي
  /// يبقيان `null` = غير مقيسين (W2-02d). الفشل يُرفع ولا يُبتلع.
  ///
  /// [accountId] هوية صاحب الطابور من العقد: القراءة بمفتاح غير مفتاح الكتابة
  /// تُظهر طابورًا فارغًا لحساب عليه عمليات لم تُرسل (ق-113).
  Future<DeviceSyncStatusModel> fetchDeviceSyncStatus(String accountId) async {
    final coordinator = _coordinator;
    final pendingCount =
        await coordinator.getPendingOperationsCount(accountId);
    final lastSync = await coordinator.lastSuccessfulSyncAt(accountId);

    return DeviceSyncStatusModel(
      localStorageReady: coordinator.usesDurableStore,
      pendingOperationsCount: pendingCount,
      lastSyncTime: lastSync,
    );
  }

  /// 8. إجراء المزامنة اليدوية
  ///
  /// تمر بالمنسق القائم لا بتأخير صناعي: إن لم يكن هناك ناقل موصول
  /// يُعلن ذلك صريحًا بدل الانتظار لحظة ثم إعلان النجاح.
  Future<void> triggerManualSync(String accountId) async {
    final coordinator = _coordinator;
    if (!coordinator.canSyncNow) {
      throw const ManualSyncUnavailableException();
    }

    await coordinator.syncNow(accountId);
  }

  /// 9. فحص الأمان قبل تسجيل الخروج (القرار 578)
  ///
  /// يفشل مغلقًا: تعذُّر القراءة يُرفع ولا يُترجم إلى «لا يوجد معلَّق»،
  /// لأن الخروج على عمليات لم تُرسل ضياع مال ميداني.
  Future<int> checkPendingOperationsBeforeLogout(String accountId) async {
    return _coordinator.getPendingOperationsCount(accountId);
  }
}

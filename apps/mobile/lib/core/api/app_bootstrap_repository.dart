import 'package:supabase_flutter/supabase_flutter.dart';

/// سياق المستخدم والآبار المتاحة المجلوبة من عقد القراءة api.app_bootstrap (ق-82 / 077)
class UserProfile {
  const UserProfile({
    required this.id,
    required this.fullName,
    required this.phone,
    required this.isPlatformAdmin,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'] as String? ?? '',
      fullName: json['full_name'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      isPlatformAdmin: json['is_platform_admin'] as bool? ?? false,
    );
  }

  final String id;
  final String fullName;
  final String phone;
  final bool isPlatformAdmin;
}

class WellSummary {
  const WellSummary({
    required this.id,
    required this.tenantId,
    required this.name,
    this.location,
    required this.status,
    required this.roles,
  });

  factory WellSummary.fromJson(Map<String, dynamic> json) {
    final rawRoles = json['roles'];
    final List<String> rolesList;
    if (rawRoles is List) {
      rolesList = rawRoles.map((e) => e.toString()).toList();
    } else {
      rolesList = [];
    }

    return WellSummary(
      id: json['id'] as String? ?? '',
      tenantId: json['tenant_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      location: json['location'] as String?,
      status: json['status'] as String? ?? 'active',
      roles: rolesList,
    );
  }

  final String id;
  final String tenantId;
  final String name;
  final String? location;
  final String status;
  final List<String> roles;

  bool get isOwner => roles.contains('owner');
  bool get isOperator => roles.contains('operator');
  bool get isPartner => roles.contains('partner');
  bool get isManager => roles.contains('manager');

  /// سلطته على هذا البئر شراكةٌ وحدها: لا مالك ولا مدير ولا مشغّل.
  ///
  /// يقابل `iam.is_partner_only` في هجرة 095 حرفًا بحرف، فما تحجبه الواجهة
  /// هو ما يحجبه الخادم — والعكس: من له دور تشغيلي لا يُقيَّد لأنه شريك.
  bool get isPartnerOnly =>
      isPartner && !isOwner && !isManager && !isOperator;
}

class BootstrapData {
  const BootstrapData({
    required this.profile,
    required this.wells,
  });

  factory BootstrapData.fromJson(Map<String, dynamic> json) {
    final profileJson = json['profile'];
    final wellsJson = json['wells'];
    if (profileJson is! Map<String, dynamic> ||
        profileJson['id'] is! String ||
        (profileJson['id'] as String).isEmpty ||
        profileJson['is_platform_admin'] is! bool ||
        wellsJson is! List ||
        wellsJson.any(
          (w) =>
              w is! Map<String, dynamic> ||
              w['id'] is! String ||
              w['tenant_id'] is! String ||
              w['name'] is! String ||
              w['status'] is! String ||
              w['roles'] is! List ||
              (w['roles'] as List).any((r) => r is! String || r.isEmpty),
        )) {
      throw const FormatException('bootstrap_payload_invalid');
    }

    return BootstrapData(
      profile: UserProfile.fromJson(profileJson),
      wells: wellsJson
          .map((w) => WellSummary.fromJson(w as Map<String, dynamic>))
          .toList(),
    );
  }

  final UserProfile profile;
  final List<WellSummary> wells;

  WellSummary? get primaryWell => wells.isNotEmpty ? wells.first : null;
}

class AppBootstrapRepository {
  const AppBootstrapRepository(this._client);

  final SupabaseClient _client;

  Future<BootstrapData> fetchBootstrap() async {
    final raw = await _client.schema('api').rpc('app_bootstrap');
    if (raw is Map<String, dynamic>) {
      return BootstrapData.fromJson(raw);
    }
    throw const FormatException('استجابة غير متوقعة من عقد app_bootstrap');
  }

  Future<String> createTenantWithWell({
    required String tenantName,
    required String wellName,
  }) async {
    final raw = await _client.schema('api').rpc(
      'create_tenant_with_well',
      params: {
        'p_tenant_name': tenantName,
        'p_well_name': wellName,
      },
    );
    return raw.toString();
  }

  Future<Map<String, dynamic>> setupWellFull({
    required Map<String, dynamic> setupData,
  }) async {
    final raw = await _client.schema('api').rpc(
      'setup_well_full',
      params: {
        'p_setup_data': setupData,
      },
    );
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    return {'status': 'success'};
  }
}

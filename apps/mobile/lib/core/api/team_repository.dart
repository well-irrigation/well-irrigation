import 'package:supabase_flutter/supabase_flutter.dart';

/// عقود فريق البئر ودورة قبول/تأكيد الدعوات وفق ق-130.
///
/// كل نداء يمر عبر مخطط `api` وحده (ق-78)، ولا حساب ولا اشتقاق هنا: ما
/// يعرضه العميل هو ما أعاده العقد حرفيًّا (ق-99 / ق-113).
class TeamMember {
  const TeamMember({
    required this.profileId,
    required this.fullName,
    required this.phone,
    required this.role,
    required this.status,
    this.since,
  });

  factory TeamMember.fromJson(Map<String, dynamic> json) {
    final rawSince = json['since'] as String?;
    return TeamMember(
      profileId: json['profile_id'] as String? ?? '',
      fullName: json['full_name'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      role: json['role'] as String? ?? '',
      status: json['status'] as String? ?? '',
      since: rawSince == null ? null : DateTime.tryParse(rawSince),
    );
  }

  final String profileId;
  final String fullName;
  final String phone;
  final String role;
  final String status;
  final DateTime? since;

  bool get isActive => status == 'active';
}

/// دعوة معلَّقة أو منتهية كما يعيدها العقد. لا يعيد العقد الرمز ولا
/// تلبيدته أبدًا: الرمز يُعرض مرة واحدة لحظة الدعوة.
class TeamInvitation {
  const TeamInvitation({
    required this.invitationId,
    required this.fullName,
    required this.phone,
    required this.role,
    required this.status,
    required this.attemptsLeft,
    this.expiresAt,
    this.invitedAt,
    this.claimedAt,
  });

  factory TeamInvitation.fromJson(Map<String, dynamic> json) {
    DateTime? parse(String key) {
      final raw = json[key] as String?;
      return raw == null ? null : DateTime.tryParse(raw);
    }

    return TeamInvitation(
      invitationId: json['invitation_id'] as String? ?? '',
      fullName: json['full_name'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      role: json['role'] as String? ?? '',
      status: json['status'] as String? ?? '',
      attemptsLeft: (json['attempts_left'] as num?)?.toInt() ?? 0,
      expiresAt: parse('expires_at'),
      invitedAt: parse('invited_at'),
      claimedAt: parse('claimed_at'),
    );
  }

  final String invitationId;
  final String fullName;
  final String phone;
  final String role;
  final String status;
  final int attemptsLeft;
  final DateTime? expiresAt;
  final DateTime? invitedAt;
  final DateTime? claimedAt;

  bool get isPending =>
      status == 'invited' || status == 'accepted_pending_owner';
  bool get isAwaitingOwner => status == 'accepted_pending_owner';
}

class WellTeam {
  const WellTeam({required this.members, required this.invitations});

  factory WellTeam.fromJson(Map<String, dynamic> json) {
    final rawMembers = json['members'];
    final rawInvitations = json['invitations'];

    return WellTeam(
      members: rawMembers is List
          ? rawMembers
                .whereType<Map<String, dynamic>>()
                .map(TeamMember.fromJson)
                .toList(growable: false)
          : const [],
      invitations: rawInvitations is List
          ? rawInvitations
                .whereType<Map<String, dynamic>>()
                .map(TeamInvitation.fromJson)
                .toList(growable: false)
          : const [],
    );
  }

  final List<TeamMember> members;
  final List<TeamInvitation> invitations;
}

/// نتيجة دعوة ق-130: الدعوة لا تربط حسابًا ولا تمنح وصولًا تلقائيًا.
class InviteResult {
  const InviteResult({required this.outcome, this.code, this.expiresAt});

  factory InviteResult.fromJson(Map<String, dynamic> json) {
    final rawExpires = json['expires_at'] as String?;
    return InviteResult(
      outcome: json['outcome'] as String? ?? '',
      code: json['code'] as String?,
      expiresAt: rawExpires == null ? null : DateTime.tryParse(rawExpires),
    );
  }

  final String outcome;
  final String? code;
  final DateTime? expiresAt;

  bool get isInvited => outcome == 'invited';
  bool get isAwaitingOwner => outcome == 'accepted_pending_owner';
  bool get isAlreadyConfirmed => outcome == 'already_confirmed';
}

class MyWellInvitation {
  const MyWellInvitation({
    required this.invitationId,
    required this.wellId,
    required this.wellName,
    required this.role,
    required this.status,
    this.fullName = '',
    this.phone = '',
    this.expiresAt,
    this.invitedAt,
    this.acceptedAt,
  });

  factory MyWellInvitation.fromJson(Map<String, dynamic> json) {
    DateTime? parse(String key) {
      final raw = json[key] as String?;
      return raw == null ? null : DateTime.tryParse(raw);
    }

    return MyWellInvitation(
      invitationId: json['invitation_id'] as String? ?? '',
      wellId: json['well_id'] as String? ?? '',
      wellName: json['well_name'] as String? ?? '',
      fullName: json['full_name'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      role: json['role'] as String? ?? '',
      status: json['status'] as String? ?? '',
      expiresAt: parse('expires_at'),
      invitedAt: parse('invited_at'),
      acceptedAt: parse('accepted_at'),
    );
  }

  final String invitationId;
  final String wellId;
  final String wellName;
  final String fullName;
  final String phone;
  final String role;
  final String status;
  final DateTime? expiresAt;
  final DateTime? invitedAt;
  final DateTime? acceptedAt;
}

class InvitationActionResult {
  const InvitationActionResult({
    required this.outcome,
    this.invitationId,
    this.wellId,
    this.role,
  });

  factory InvitationActionResult.fromJson(Map<String, dynamic> json) {
    return InvitationActionResult(
      outcome: json['outcome'] as String? ?? '',
      invitationId: json['invitation_id'] as String?,
      wellId: json['well_id'] as String?,
      role: json['role'] as String?,
    );
  }

  final String outcome;
  final String? invitationId;
  final String? wellId;
  final String? role;
}

/// نتيجة المطالبة بالدعوة. أربع حالات لا خامسة، والرمز الخاطئ يعيد عدد
/// المحاولات المتبقية لأن الخصم يجري على الخادم فعلًا.
class ClaimResult {
  const ClaimResult({
    required this.outcome,
    this.wellId,
    this.wellName,
    this.role,
    this.attemptsLeft,
  });

  factory ClaimResult.fromJson(Map<String, dynamic> json) {
    return ClaimResult(
      outcome: json['outcome'] as String? ?? '',
      wellId: json['well_id'] as String?,
      wellName: json['well_name'] as String?,
      role: json['role'] as String?,
      attemptsLeft: (json['attempts_left'] as num?)?.toInt(),
    );
  }

  final String outcome;
  final String? wellId;
  final String? wellName;
  final String? role;
  final int? attemptsLeft;

  bool get isSuccess => outcome == 'claimed' || outcome == 'already_claimed';
  bool get isWrongCode => outcome == 'wrong_code';
  bool get hasNoInvitation => outcome == 'no_invitation';
}

class TeamRepository {
  TeamRepository([SupabaseClient? client]) : _injected = client;

  final SupabaseClient? _injected;

  /// العميل الفعلي. غيابه حالة صريحة تُرفع، لا نجاح صامت (ق-113).
  SupabaseClient get _client {
    final injected = _injected;
    if (injected != null) return injected;

    try {
      return Supabase.instance.client;
    } catch (_) {
      throw StateError('Supabase client is unavailable');
    }
  }

  Future<WellTeam> fetchWellTeam(String wellId) async {
    final raw = await _client
        .schema('api')
        .rpc('list_well_team', params: {'p_well_id': wellId});

    if (raw is Map<String, dynamic>) {
      return WellTeam.fromJson(raw);
    }
    throw const FormatException('استجابة غير متوقعة من عقد list_well_team');
  }

  Future<InviteResult> inviteMember({
    required String wellId,
    required String role,
    required String fullName,
    required String phone,
  }) async {
    final raw = await _client
        .schema('api')
        .rpc(
          'invite_well_member',
          params: {
            'p_well_id': wellId,
            'p_role': role,
            'p_full_name': fullName,
            'p_phone': phone,
          },
        );

    if (raw is Map<String, dynamic>) {
      return InviteResult.fromJson(raw);
    }
    throw const FormatException('استجابة غير متوقعة من عقد invite_well_member');
  }

  Future<void> revokeMember({
    required String wellId,
    required String role,
    required String phone,
  }) async {
    await _client
        .schema('api')
        .rpc(
          'revoke_well_member',
          params: {'p_well_id': wellId, 'p_role': role, 'p_phone': phone},
        );
  }

  Future<List<MyWellInvitation>> listMyInvitations() async {
    final raw = await _client.schema('api').rpc('list_my_well_invitations');
    if (raw is Map<String, dynamic>) {
      final invitations = raw['invitations'];
      if (invitations is List) {
        return invitations
            .whereType<Map<String, dynamic>>()
            .map(MyWellInvitation.fromJson)
            .toList(growable: false);
      }
    }
    throw const FormatException(
      'استجابة غير متوقعة من عقد list_my_well_invitations',
    );
  }

  Future<InvitationActionResult> acceptInvitation(String invitationId) {
    return _invitationAction('accept_well_invitation', invitationId);
  }

  Future<InvitationActionResult> confirmInvitation(String invitationId) {
    return _invitationAction('confirm_well_invitation', invitationId);
  }

  Future<InvitationActionResult> rejectInvitation(String invitationId) {
    return _invitationAction('reject_well_invitation', invitationId);
  }

  Future<InvitationActionResult> _invitationAction(
    String contract,
    String invitationId,
  ) async {
    final raw = await _client
        .schema('api')
        .rpc(contract, params: {'p_invitation_id': invitationId});
    if (raw is Map<String, dynamic>) {
      return InvitationActionResult.fromJson(raw);
    }
    throw FormatException('استجابة غير متوقعة من عقد $contract');
  }

  Future<ClaimResult> claimInvitation(String code) async {
    final raw = await _client
        .schema('api')
        .rpc('claim_well_invitation', params: {'p_code': code});

    if (raw is Map<String, dynamic>) {
      return ClaimResult.fromJson(raw);
    }
    throw const FormatException(
      'استجابة غير متوقعة من عقد claim_well_invitation',
    );
  }

  /// إصدار رمز إعادة تعيين لعضو (م-41F / هجرة 096). الرمز يُعاد **مرة
  /// واحدة** لمن سيسلّمه باليد، ولا يُخزَّن نصًّا في القاعدة.
  Future<ResetIssueResult> requestMemberPasswordReset({
    required String wellId,
    required String phone,
  }) async {
    final raw = await _client
        .schema('api')
        .rpc(
          'request_member_password_reset',
          params: {'p_well_id': wellId, 'p_phone': phone},
        );

    if (raw is Map<String, dynamic>) {
      return ResetIssueResult.fromJson(raw);
    }
    throw const FormatException(
      'استجابة غير متوقعة من عقد request_member_password_reset',
    );
  }

  Future<List<ResetTicket>> fetchResetRequests(String wellId) async {
    final raw = await _client
        .schema('api')
        .rpc('list_member_reset_requests', params: {'p_well_id': wellId});

    if (raw is Map<String, dynamic>) {
      final items = raw['requests'];
      if (items is List) {
        return items
            .whereType<Map<String, dynamic>>()
            .map(ResetTicket.fromJson)
            .toList(growable: false);
      }
    }
    throw const FormatException(
      'استجابة غير متوقعة من عقد list_member_reset_requests',
    );
  }
}

/// نتيجة إصدار تذكرة إعادة التعيين. `code` يأتي مرة واحدة ولا يُقرأ بعدها.
class ResetIssueResult {
  const ResetIssueResult({
    required this.outcome,
    this.ticketId,
    this.fullName,
    this.phone,
    this.code,
    this.expiresAt,
  });

  factory ResetIssueResult.fromJson(Map<String, dynamic> json) {
    final rawExpires = json['expires_at'] as String?;
    return ResetIssueResult(
      outcome: json['outcome'] as String? ?? '',
      ticketId: json['ticket_id'] as String?,
      fullName: json['full_name'] as String?,
      phone: json['phone'] as String?,
      code: json['code'] as String?,
      expiresAt: rawExpires == null ? null : DateTime.tryParse(rawExpires),
    );
  }

  final String outcome;
  final String? ticketId;
  final String? fullName;
  final String? phone;
  final String? code;
  final DateTime? expiresAt;

  bool get isIssued => outcome == 'issued';
  bool get hasNoMember => outcome == 'no_member';
}

/// تذكرة إعادة تعيين كما يعيدها العقد: حالتها ومحاولاتها ومدتها، بلا رمز.
class ResetTicket {
  const ResetTicket({
    required this.ticketId,
    required this.fullName,
    required this.phone,
    required this.status,
    required this.attemptsLeft,
    this.expiresAt,
    this.requestedAt,
    this.consumedAt,
  });

  factory ResetTicket.fromJson(Map<String, dynamic> json) {
    DateTime? parse(String key) {
      final raw = json[key] as String?;
      return raw == null ? null : DateTime.tryParse(raw);
    }

    return ResetTicket(
      ticketId: json['ticket_id'] as String? ?? '',
      fullName: json['full_name'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      status: json['status'] as String? ?? '',
      attemptsLeft: (json['attempts_left'] as num?)?.toInt() ?? 0,
      expiresAt: parse('expires_at'),
      requestedAt: parse('requested_at'),
      consumedAt: parse('consumed_at'),
    );
  }

  final String ticketId;
  final String fullName;
  final String phone;
  final String status;
  final int attemptsLeft;
  final DateTime? expiresAt;
  final DateTime? requestedAt;
  final DateTime? consumedAt;

  bool get isPending => status == 'pending';
}

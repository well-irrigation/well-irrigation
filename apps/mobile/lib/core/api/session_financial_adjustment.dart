enum SessionFinancialAdjustmentReadFailure {
  unavailable,
  authentication,
  forbidden,
  network,
  malformed,
  unsupportedVersion,
  scopeMismatch,
  identityChanged,
}

class SessionFinancialAdjustmentReadUnavailable implements Exception {
  const SessionFinancialAdjustmentReadUnavailable(this.kind);
  final SessionFinancialAdjustmentReadFailure kind;
}

enum SessionFinancialStatus { ready, locked, reviewRequired, permissionDenied }

SessionFinancialStatus _financialStatus(Object? raw) {
  return switch (raw) {
    'ready' => SessionFinancialStatus.ready,
    'locked' => SessionFinancialStatus.locked,
    'financial_review_required' => SessionFinancialStatus.reviewRequired,
    _ => throw const SessionFinancialAdjustmentReadUnavailable(
      SessionFinancialAdjustmentReadFailure.malformed,
    ),
  };
}

class SessionFinancialAdjustmentHistoryEntry {
  const SessionFinancialAdjustmentHistoryEntry._({
    required this.manualApprovalRevision,
    required this.previousEffectiveYER,
    required this.approvedAmountYER,
    required this.deltaYER,
    required this.reason,
    required this.actorName,
    required this.acceptedAt,
  });

  factory SessionFinancialAdjustmentHistoryEntry.fromContract(Object? raw) {
    if (raw is! Map) throw _malformed;
    final revision = _unsigned(raw['manual_approval_revision']);
    final previous = _unsigned(raw['previous_effective_minor']);
    final approved = _unsigned(raw['approved_amount_minor']);
    final delta = _signed(raw['delta_minor']);
    final reason = _text(raw['reason']);
    final actor = _text(raw['actor_name']);
    final accepted = _time(raw['accepted_at']);
    if (revision == null ||
        revision < 1 ||
        previous == null ||
        approved == null ||
        delta == null ||
        reason == null ||
        actor == null ||
        accepted == null ||
        raw['status'] != 'accepted') {
      throw _malformed;
    }
    return SessionFinancialAdjustmentHistoryEntry._(
      manualApprovalRevision: revision,
      previousEffectiveYER: previous,
      approvedAmountYER: approved,
      deltaYER: delta,
      reason: reason,
      actorName: actor,
      acceptedAt: accepted,
    );
  }

  final int manualApprovalRevision;
  final int previousEffectiveYER;
  final int approvedAmountYER;
  final int deltaYER;
  final String reason;
  final String actorName;
  final DateTime acceptedAt;
}

class SessionFinancialState {
  SessionFinancialState._({
    required this.sessionId,
    required this.wellId,
    required this.originalAmountYER,
    required this.systemAmountYER,
    required this.approvedAmountYER,
    required this.effectiveAmountYER,
    required this.paidAmountYER,
    required this.outstandingAmountYER,
    required this.operationalRevision,
    required this.systemFinancialRevision,
    required this.manualApprovalRevision,
    required this.canAdjust,
    required this.status,
    required this.reasonCode,
    required List<SessionFinancialAdjustmentHistoryEntry> adjustmentHistory,
  }) : adjustmentHistory = List.unmodifiable(adjustmentHistory);

  factory SessionFinancialState.fromContract(
    Object? raw, {
    required String sessionId,
  }) {
    final data = _baseContract(
      raw,
      contract: 'session_financial_state',
      sessionId: sessionId,
    );
    final history = data['adjustment_history'];
    if (history is! List) throw _malformed;
    final original = _nullableUnsigned(data, 'original_amount_minor');
    final system = _nullableUnsigned(data, 'system_amount_minor');
    final approved = _nullableUnsigned(data, 'approved_amount_minor');
    final effective = _nullableUnsigned(data, 'effective_amount_minor');
    final paid = _nullableUnsigned(data, 'paid_amount_minor');
    final outstanding = _nullableUnsigned(data, 'outstanding_amount_minor');
    final operational = _unsigned(data['operational_revision']);
    final systemRevision = _unsigned(data['system_financial_revision']);
    final manualRevision = _unsigned(data['manual_approval_revision']);
    final allowed = data['can_adjust'];
    if (!data.containsKey('reason_code')) throw _malformed;
    final reasonCode = data['reason_code'];
    if (reasonCode != null && reasonCode is! String) throw _malformed;
    if (operational == null ||
        systemRevision == null ||
        manualRevision == null ||
        systemRevision > operational ||
        manualRevision == _maxInt64 ||
        allowed is! bool) {
      throw _malformed;
    }
    final amounts = [original, system, effective, paid, outstanding];
    final hasCharge = amounts.every((value) => value != null);
    if (!hasCharge && amounts.any((value) => value != null) ||
        (!hasCharge && approved != null) ||
        (manualRevision == 0 && approved != null) ||
        (manualRevision > 0 && approved == null)) {
      throw _malformed;
    }
    final parsedHistory = history
        .map(SessionFinancialAdjustmentHistoryEntry.fromContract)
        .toList(growable: false);
    if (parsedHistory.length != manualRevision) throw _malformed;
    for (var index = 0; index < parsedHistory.length; index++) {
      if (parsedHistory[index].manualApprovalRevision != index + 1) {
        throw _malformed;
      }
    }
    return SessionFinancialState._(
      sessionId: sessionId,
      wellId: _text(data['well_id'])!,
      originalAmountYER: original,
      systemAmountYER: system,
      approvedAmountYER: approved,
      effectiveAmountYER: effective,
      paidAmountYER: paid,
      outstandingAmountYER: outstanding,
      operationalRevision: operational,
      systemFinancialRevision: systemRevision,
      manualApprovalRevision: manualRevision,
      canAdjust: allowed,
      status: _financialStatus(data['financial_status']),
      reasonCode: reasonCode as String?,
      adjustmentHistory: parsedHistory,
    );
  }

  final String sessionId;
  final String wellId;
  final int? originalAmountYER;
  final int? systemAmountYER;
  final int? approvedAmountYER;
  final int? effectiveAmountYER;
  final int? paidAmountYER;
  final int? outstandingAmountYER;
  final int operationalRevision;
  final int systemFinancialRevision;
  final int manualApprovalRevision;
  final bool canAdjust;
  final SessionFinancialStatus status;
  final String? reasonCode;
  final List<SessionFinancialAdjustmentHistoryEntry> adjustmentHistory;
}

class SessionFinancialAdjustmentCapability {
  const SessionFinancialAdjustmentCapability._({
    required this.sessionId,
    required this.wellId,
    required this.canAdjust,
    required this.status,
    required this.reasonCode,
  });

  factory SessionFinancialAdjustmentCapability.fromContract(
    Object? raw, {
    required String sessionId,
  }) {
    if (raw is! Map ||
        raw['contract'] != 'session_financial_adjustment_capability' ||
        raw['version'] is! int ||
        raw['session_id'] != sessionId ||
        raw['can_adjust'] is! bool) {
      throw _malformed;
    }
    if (raw['version'] != 1) {
      throw const SessionFinancialAdjustmentReadUnavailable(
        SessionFinancialAdjustmentReadFailure.unsupportedVersion,
      );
    }
    if (!raw.containsKey('reason_code')) throw _malformed;
    final reason = raw['reason_code'];
    if (reason != null && reason is! String) throw _malformed;
    if (reason == 'permission_denied') {
      if (raw['well_id'] != null || raw['can_adjust'] != false) {
        throw _malformed;
      }
      return SessionFinancialAdjustmentCapability._(
        sessionId: sessionId,
        wellId: null,
        canAdjust: false,
        status: SessionFinancialStatus.permissionDenied,
        reasonCode: reason as String,
      );
    }
    final well = _text(raw['well_id']);
    if (well == null || raw['financial_status'] is! String) throw _malformed;
    final stateRaw = Map<Object?, Object?>.from(raw)
      ..['contract'] = 'session_financial_state';
    SessionFinancialState.fromContract(stateRaw, sessionId: sessionId);
    return SessionFinancialAdjustmentCapability._(
      sessionId: sessionId,
      wellId: well,
      canAdjust: raw['can_adjust'] as bool,
      status: _financialStatus(raw['financial_status']),
      reasonCode: reason as String?,
    );
  }

  final String sessionId;
  final String? wellId;
  final bool canAdjust;
  final SessionFinancialStatus status;
  final String? reasonCode;
}

const _malformed = SessionFinancialAdjustmentReadUnavailable(
  SessionFinancialAdjustmentReadFailure.malformed,
);
const _maxInt64 = 9223372036854775807;

Map _baseContract(
  Object? raw, {
  required String contract,
  required String sessionId,
}) {
  if (raw is! Map ||
      raw['contract'] != contract ||
      raw['version'] is! int ||
      raw['session_id'] is! String ||
      _text(raw['well_id']) == null) {
    throw _malformed;
  }
  if (raw['version'] != 1) {
    throw const SessionFinancialAdjustmentReadUnavailable(
      SessionFinancialAdjustmentReadFailure.unsupportedVersion,
    );
  }
  if (raw['session_id'] != sessionId) {
    throw const SessionFinancialAdjustmentReadUnavailable(
      SessionFinancialAdjustmentReadFailure.scopeMismatch,
    );
  }
  return raw;
}

int? _unsigned(Object? value) =>
    value is int && value >= 0 && value <= _maxInt64 ? value : null;

int? _signed(Object? value) =>
    value is int && value >= -9223372036854775808 && value <= _maxInt64
    ? value
    : null;

int? _nullableUnsigned(Map data, String key) {
  if (!data.containsKey(key)) throw _malformed;
  final value = data[key];
  if (value == null) return null;
  final parsed = _unsigned(value);
  if (parsed == null) throw _malformed;
  return parsed;
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty && value.trim() == value
    ? value
    : null;

DateTime? _time(Object? value) {
  if (value is! String) return null;
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (match == null) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  if (year < 1 ||
      month < 1 ||
      month > 12 ||
      day < 1 ||
      day > DateTime.utc(year, month + 1, 0).day ||
      int.parse(match[4]!) > 23 ||
      int.parse(match[5]!) > 59 ||
      int.parse(match[6]!) > 59) {
    return null;
  }
  final zone = match[7]!;
  if (zone != 'Z' &&
      (int.parse(zone.substring(1, 3)) > 23 ||
          int.parse(zone.substring(4, 6)) > 59)) {
    return null;
  }
  return DateTime.tryParse(value)?.toUtc();
}

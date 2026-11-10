import 'command_envelope.dart';
import 'command_type.dart';
import 'sync_status.dart';

const _maxInt64 = 9223372036854775807;

class SessionFinancialAdjustmentRequest {
  const SessionFinancialAdjustmentRequest._({
    required this.command,
    required this.sessionId,
    required this.baseOperationalRevision,
    required this.baseSystemFinancialRevision,
    required this.baseManualApprovalRevision,
    required this.approvedAmountYER,
    required this.reason,
  });

  static SessionFinancialAdjustmentRequest? fromCommand(
    CommandEnvelope command,
  ) {
    final payload = command.payload;
    const keys = {
      'p_session_id',
      'p_base_operational_revision',
      'p_base_system_financial_revision',
      'p_base_manual_approval_revision',
      'p_approved_amount_minor',
      'p_reason',
    };
    final session = payload['p_session_id'];
    final operational = _unsigned(payload['p_base_operational_revision']);
    final system = _unsigned(payload['p_base_system_financial_revision']);
    final manual = _unsigned(payload['p_base_manual_approval_revision']);
    final amount = _unsigned(payload['p_approved_amount_minor']);
    final reason = payload['p_reason'];
    if (command.type != CommandType.adjustSessionFinancialAmount ||
        command.accountId.trim().isEmpty ||
        command.commandId.trim().isEmpty ||
        command.wellId?.trim().isEmpty != false ||
        command.aggregateLocalId != null ||
        command.prerequisites.isNotEmpty ||
        command.localContext.isNotEmpty ||
        payload.length != keys.length ||
        !payload.keys.every(keys.contains) ||
        session is! String ||
        session.trim().isEmpty ||
        session.trim() != session ||
        operational == null ||
        system == null ||
        manual == null ||
        manual == _maxInt64 ||
        amount == null ||
        reason is! String ||
        reason.trim().isEmpty ||
        reason.trim() != reason) {
      return null;
    }
    return SessionFinancialAdjustmentRequest._(
      command: command,
      sessionId: session,
      baseOperationalRevision: operational,
      baseSystemFinancialRevision: system,
      baseManualApprovalRevision: manual,
      approvedAmountYER: amount,
      reason: reason,
    );
  }

  final CommandEnvelope command;
  final String sessionId;
  String get commandId => command.commandId;
  final int baseOperationalRevision;
  final int baseSystemFinancialRevision;
  final int baseManualApprovalRevision;
  final int approvedAmountYER;
  final String reason;
  DateTime get requestedAt => command.occurredAt.toUtc();

  Map<String, Object?> get arguments => {
    ...command.payload,
    commandIdArgument: commandId,
    'p_requested_at': requestedAt.toIso8601String(),
  };
}

class SessionFinancialAdjustmentReceiptRequest {
  const SessionFinancialAdjustmentReceiptRequest._(this.command);

  static SessionFinancialAdjustmentReceiptRequest? fromCommand(
    CommandEnvelope command,
  ) => SessionFinancialAdjustmentRequest.fromCommand(command) == null
      ? null
      : SessionFinancialAdjustmentReceiptRequest._(command);

  final CommandEnvelope command;
  String get accountId => command.accountId;
  String get sessionId => command.payload['p_session_id'] as String;
  String get commandId => command.commandId;
  Map<String, Object?> get arguments => {
    'p_session_id': sessionId,
    'p_command_id': commandId,
  };
}

enum SessionFinancialAdjustmentState {
  accepted('accepted'),
  processing('processing'),
  validationError('validation_error'),
  financialReviewRequired('financial_review_required'),
  locked('locked'),
  conflictRequest('conflict_request'),
  conflictRevision('conflict_revision'),
  permissionDenied('permission_denied'),
  unresolved('unresolved'),
  notFound('not_found');

  const SessionFinancialAdjustmentState(this.wireValue);
  final String wireValue;

  static SessionFinancialAdjustmentState? fromWire(Object? value) {
    for (final state in values) {
      if (state.wireValue == value) return state;
    }
    return null;
  }

  bool get isReview => switch (this) {
    accepted || processing => false,
    _ => true,
  };
}

class AcceptedSessionFinancialAdjustment {
  const AcceptedSessionFinancialAdjustment({
    required this.adjustmentId,
    required this.operationalRevision,
    required this.systemFinancialRevision,
    required this.manualApprovalRevision,
    required this.previousEffectiveYER,
    required this.approvedAmountYER,
    required this.effectiveAmountYER,
    required this.deltaYER,
    required this.acceptedAt,
  });

  final String adjustmentId;
  final int operationalRevision;
  final int systemFinancialRevision;
  final int manualApprovalRevision;
  final int previousEffectiveYER;
  final int approvedAmountYER;
  final int effectiveAmountYER;
  final int deltaYER;
  final DateTime acceptedAt;
}

sealed class SessionFinancialAdjustmentRead {
  const SessionFinancialAdjustmentRead();
}

class SessionFinancialAdjustmentResponse
    extends SessionFinancialAdjustmentRead {
  const SessionFinancialAdjustmentResponse({
    required this.state,
    this.accepted,
  });

  final SessionFinancialAdjustmentState state;
  final AcceptedSessionFinancialAdjustment? accepted;
}

enum SessionFinancialAdjustmentReadFailureKind {
  authentication,
  forbidden,
  network,
  malformed,
  unavailable,
}

class SessionFinancialAdjustmentReadFailure
    extends SessionFinancialAdjustmentRead {
  const SessionFinancialAdjustmentReadFailure(
    this.kind, {
    this.executionNotStarted = false,
  });

  final SessionFinancialAdjustmentReadFailureKind kind;
  final bool executionNotStarted;
}

abstract interface class SessionFinancialAdjustmentTransport {
  Future<SessionFinancialAdjustmentRead> adjustSessionFinancialAmount(
    SessionFinancialAdjustmentRequest request,
  );

  Future<SessionFinancialAdjustmentRead> readSessionFinancialAdjustmentReceipt(
    SessionFinancialAdjustmentReceiptRequest request,
  );
}

SessionFinancialAdjustmentResponse parseSessionFinancialAdjustmentResult(
  SessionFinancialAdjustmentRequest request,
  Object? raw,
) {
  if (raw is! Map || !raw.keys.every((key) => key is String)) {
    throw const FormatException('invalid_financial_adjustment_result');
  }
  final map = Map<String, Object?>.from(raw);
  if (map['contract'] != 'session_financial_adjustment' ||
      map['version'] is! int ||
      map['version'] != 1 ||
      map['session_id'] != request.sessionId ||
      map['command_id'] != request.commandId ||
      map['retry_authorized'] != false ||
      map.containsKey('financial_status')) {
    throw const FormatException('invalid_financial_adjustment_result');
  }
  final state = SessionFinancialAdjustmentState.fromWire(map['status']);
  if (state == null || state == SessionFinancialAdjustmentState.notFound) {
    throw const FormatException('invalid_financial_adjustment_status');
  }
  if (state != SessionFinancialAdjustmentState.accepted) {
    final allowed = {
      'contract',
      'version',
      'session_id',
      'command_id',
      'status',
      'reason_code',
      'retry_authorized',
    };
    if (!map.keys.every(allowed.contains) ||
        (map['reason_code'] != null && map['reason_code'] is! String)) {
      throw const FormatException('invalid_financial_adjustment_rejection');
    }
    return SessionFinancialAdjustmentResponse(state: state);
  }
  const acceptedKeys = {
    'contract',
    'version',
    'status',
    'session_id',
    'command_id',
    'adjustment_id',
    'operational_revision',
    'system_financial_revision',
    'manual_approval_revision',
    'previous_effective_minor',
    'approved_amount_minor',
    'effective_amount_minor',
    'delta_minor',
    'accepted_at',
    'retry_authorized',
  };
  if (map.length != acceptedKeys.length ||
      !map.keys.every(acceptedKeys.contains)) {
    throw const FormatException('invalid_financial_adjustment_acceptance');
  }
  final adjustment = _text(map['adjustment_id']);
  final operational = _unsigned(map['operational_revision']);
  final system = _unsigned(map['system_financial_revision']);
  final manual = _unsigned(map['manual_approval_revision']);
  final previous = _unsigned(map['previous_effective_minor']);
  final approved = _unsigned(map['approved_amount_minor']);
  final effective = _unsigned(map['effective_amount_minor']);
  final delta = _signed(map['delta_minor']);
  final acceptedAt = _time(map['accepted_at']);
  if (adjustment == null ||
      operational == null ||
      system == null ||
      manual == null ||
      previous == null ||
      approved == null ||
      effective == null ||
      delta == null ||
      acceptedAt == null ||
      operational != request.baseOperationalRevision ||
      system != request.baseOperationalRevision ||
      manual != request.baseManualApprovalRevision + 1 ||
      approved != request.approvedAmountYER ||
      approved != effective) {
    throw const FormatException('invalid_financial_adjustment_acceptance');
  }
  return SessionFinancialAdjustmentResponse(
    state: state,
    accepted: AcceptedSessionFinancialAdjustment(
      adjustmentId: adjustment,
      operationalRevision: operational,
      systemFinancialRevision: system,
      manualApprovalRevision: manual,
      previousEffectiveYER: previous,
      approvedAmountYER: approved,
      effectiveAmountYER: effective,
      deltaYER: delta,
      acceptedAt: acceptedAt,
    ),
  );
}

SessionFinancialAdjustmentResponse parseSessionFinancialAdjustmentReceipt(
  SessionFinancialAdjustmentReceiptRequest receipt,
  Object? raw,
) {
  if (raw is! Map ||
      raw['contract'] != 'session_financial_adjustment_receipt' ||
      raw['version'] is! int ||
      raw['version'] != 1 ||
      raw['session_id'] != receipt.sessionId ||
      raw['command_id'] != receipt.commandId ||
      raw['retry_authorized'] != false ||
      !raw.containsKey('result')) {
    throw const FormatException('invalid_financial_adjustment_receipt');
  }
  final state = SessionFinancialAdjustmentState.fromWire(raw['status']);
  if (state == null) {
    throw const FormatException('invalid_financial_adjustment_receipt_status');
  }
  final result = raw['result'];
  if (result == null &&
      const {
        SessionFinancialAdjustmentState.processing,
        SessionFinancialAdjustmentState.unresolved,
        SessionFinancialAdjustmentState.notFound,
        SessionFinancialAdjustmentState.permissionDenied,
      }.contains(state)) {
    return SessionFinancialAdjustmentResponse(state: state);
  }
  final request = SessionFinancialAdjustmentRequest.fromCommand(
    receipt.command,
  )!;
  final parsed = parseSessionFinancialAdjustmentResult(request, result);
  if (parsed.state != state) {
    throw const FormatException('financial_adjustment_receipt_mismatch');
  }
  return parsed;
}

Map<String, Object?> sessionFinancialStoredResult(
  SessionFinancialAdjustmentResponse response,
) {
  final accepted = response.accepted;
  return Map.unmodifiable({
    'contract': 'session_financial_adjustment_observation',
    'version': 1,
    'status': response.state.wireValue,
    'retry_authorized': false,
    if (accepted != null) ...{
      'adjustment_id': accepted.adjustmentId,
      'operational_revision': accepted.operationalRevision,
      'system_financial_revision': accepted.systemFinancialRevision,
      'manual_approval_revision': accepted.manualApprovalRevision,
      'previous_effective_minor': accepted.previousEffectiveYER,
      'approved_amount_minor': accepted.approvedAmountYER,
      'effective_amount_minor': accepted.effectiveAmountYER,
      'delta_minor': accepted.deltaYER,
      'accepted_at': accepted.acceptedAt.toIso8601String(),
    },
  });
}

Map<String, Object?> sessionFinancialObservation(
  SessionFinancialAdjustmentState state,
) => Map.unmodifiable({
  'contract': 'session_financial_adjustment_observation',
  'version': 1,
  'status': state.wireValue,
  'retry_authorized': false,
});

int? _unsigned(Object? value) =>
    value is int && value >= 0 && value <= _maxInt64 ? value : null;

int? _signed(Object? value) =>
    value is int && value >= -9223372036854775808 && value <= _maxInt64
    ? value
    : null;

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

/// Local durable evidence only; never grants permission or write retry authority.
enum SessionFinancialAdjustmentFollowUpPhase {
  pendingFirstSend,
  inFlight,
  processing,
  accepted,
  needsReview,
  uncertain,
}

enum SessionFinancialAdjustmentLookupStatus {
  absent,
  found,
  unavailable,
  ambiguous,
}

class SessionFinancialAdjustmentFollowUpLookup {
  const SessionFinancialAdjustmentFollowUpLookup.absent()
    : status = SessionFinancialAdjustmentLookupStatus.absent,
      followUp = null;
  const SessionFinancialAdjustmentFollowUpLookup.unavailable()
    : status = SessionFinancialAdjustmentLookupStatus.unavailable,
      followUp = null;
  const SessionFinancialAdjustmentFollowUpLookup.ambiguous()
    : status = SessionFinancialAdjustmentLookupStatus.ambiguous,
      followUp = null;
  const SessionFinancialAdjustmentFollowUpLookup.found(this.followUp)
    : status = SessionFinancialAdjustmentLookupStatus.found;

  final SessionFinancialAdjustmentLookupStatus status;
  final SessionFinancialAdjustmentFollowUp? followUp;
  bool get blocksNewIntent => switch (status) {
    SessionFinancialAdjustmentLookupStatus.absent => false,
    SessionFinancialAdjustmentLookupStatus.found =>
      followUp?.blocksNewIntent ?? true,
    _ => true,
  };
}

/// A non-blocking historical result still requires fresh canonical state and
/// explicit confirmation before any future intent. This model cannot send.
class SessionFinancialAdjustmentFollowUp {
  SessionFinancialAdjustmentFollowUp._(
    SessionFinancialAdjustmentRequest request,
    this.commandStatus,
    this.outcome,
    this.phase,
  ) : localId = request.command.localId,
      sessionId = request.sessionId,
      commandId = request.commandId,
      requestedAt = request.requestedAt,
      baseOperationalRevision = request.baseOperationalRevision,
      baseSystemFinancialRevision = request.baseSystemFinancialRevision,
      baseManualApprovalRevision = request.baseManualApprovalRevision,
      approvedAmountYER = request.approvedAmountYER,
      reason = request.reason;

  final String localId;
  final String sessionId;
  final String commandId;
  final DateTime requestedAt;
  final int baseOperationalRevision;
  final int baseSystemFinancialRevision;
  final int baseManualApprovalRevision;
  final int approvedAmountYER;
  final String reason;
  final CommandStatus commandStatus;
  final SessionFinancialAdjustmentResponse? outcome;
  final SessionFinancialAdjustmentFollowUpPhase phase;

  bool get blocksNewIntent =>
      phase != SessionFinancialAdjustmentFollowUpPhase.accepted &&
      phase != SessionFinancialAdjustmentFollowUpPhase.needsReview;

  static SessionFinancialAdjustmentFollowUp? fromCommand(
    CommandEnvelope command,
  ) {
    final request = SessionFinancialAdjustmentRequest.fromCommand(command);
    if (request == null) return null;
    SessionFinancialAdjustmentResponse? outcome;
    var malformed = false;
    if (command.serverResponse != null) {
      try {
        outcome = _parseStoredFinancialObservation(
          request,
          command.serverResponse!,
        );
      } on FormatException {
        malformed = true;
      }
    }
    var phase = SessionFinancialAdjustmentFollowUpPhase.uncertain;
    if (!malformed) {
      final state = outcome?.state;
      if (command.status == CommandStatus.pending &&
          outcome == null &&
          ((command.lastAttemptAt == null && command.retryCount == 0) ||
              command.lastError == 'financial_adjustment_preflight_not_sent')) {
        phase = SessionFinancialAdjustmentFollowUpPhase.pendingFirstSend;
      } else if (command.status == CommandStatus.dispatching &&
          outcome == null) {
        phase = SessionFinancialAdjustmentFollowUpPhase.inFlight;
      } else if (command.status == CommandStatus.dispatching &&
          state == SessionFinancialAdjustmentState.processing) {
        phase = SessionFinancialAdjustmentFollowUpPhase.processing;
      } else if (command.status == CommandStatus.confirmed &&
          state == SessionFinancialAdjustmentState.accepted) {
        phase = SessionFinancialAdjustmentFollowUpPhase.accepted;
      } else if (command.status == CommandStatus.review &&
          const {
            SessionFinancialAdjustmentState.validationError,
            SessionFinancialAdjustmentState.conflictRequest,
            SessionFinancialAdjustmentState.conflictRevision,
            SessionFinancialAdjustmentState.financialReviewRequired,
            SessionFinancialAdjustmentState.locked,
            SessionFinancialAdjustmentState.permissionDenied,
          }.contains(state)) {
        phase = SessionFinancialAdjustmentFollowUpPhase.needsReview;
      }
    }
    return SessionFinancialAdjustmentFollowUp._(
      request,
      command.status,
      outcome,
      phase,
    );
  }
}

SessionFinancialAdjustmentResponse _parseStoredFinancialObservation(
  SessionFinancialAdjustmentRequest request,
  Map<String, Object?> stored,
) {
  if (stored['contract'] != 'session_financial_adjustment_observation' ||
      stored['version'] is! int ||
      stored['version'] != 1 ||
      stored['retry_authorized'] != false) {
    throw const FormatException('invalid_stored_financial_observation');
  }
  final state = SessionFinancialAdjustmentState.fromWire(stored['status']);
  if (state == null ||
      (state != SessionFinancialAdjustmentState.accepted &&
          (stored.length != 4 ||
              !stored.keys.every(
                const {
                  'contract',
                  'version',
                  'status',
                  'retry_authorized',
                }.contains,
              )))) {
    throw const FormatException('invalid_stored_financial_observation');
  }
  // Storage omits envelope-owned identity. Bind it from the same durable row,
  // then reuse the wire parsers for every amount, revision and timestamp.
  return parseSessionFinancialAdjustmentReceipt(
    SessionFinancialAdjustmentReceiptRequest.fromCommand(request.command)!,
    {
      'contract': 'session_financial_adjustment_receipt',
      'version': 1,
      'session_id': request.sessionId,
      'command_id': request.commandId,
      'status': state.wireValue,
      'retry_authorized': false,
      'result': state == SessionFinancialAdjustmentState.notFound
          ? null
          : {
              ...stored,
              'contract': 'session_financial_adjustment',
              'session_id': request.sessionId,
              'command_id': request.commandId,
            },
    },
  );
}

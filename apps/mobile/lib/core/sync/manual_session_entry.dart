import 'command_envelope.dart';
import 'command_type.dart';
import 'sync_status.dart';

bool isManualSessionEntry(CommandType type) =>
    type == CommandType.recordHistoricalSession ||
    type == CommandType.adoptExternalSession;

/// حقائق بشرية فقط؛ الهوية التنفيذية والمال والإسناد يقررها الخادم.
class ManualSessionEntryFacts {
  ManualSessionEntryFacts({
    required this.wellId,
    required this.farmerWellAccountId,
    required this.farmId,
    required this.pumpId,
    required DateTime startedAt,
    DateTime? endedAt,
    required this.energySource,
    required String reason,
    this.notes,
  }) : startedAt = startedAt.toUtc(),
       endedAt = endedAt?.toUtc(),
       reason = reason.trim() {
    if (![wellId, farmerWellAccountId, farmId, pumpId].every(_uuid) ||
        this.reason.isEmpty ||
        !const {'solar', 'well_diesel', 'farmer_diesel'}.contains(energySource) ||
        (this.endedAt != null && !this.startedAt.isBefore(this.endedAt!))) {
      throw ArgumentError('invalid_manual_session_entry');
    }
  }

  final String wellId, farmerWellAccountId, farmId, pumpId, energySource, reason;
  final String? notes;
  final DateTime startedAt;
  final DateTime? endedAt;
  CommandType get type => endedAt == null
      ? CommandType.adoptExternalSession
      : CommandType.recordHistoricalSession;

  Map<String, Object?> get payload => Map.unmodifiable({
    'p_well_id': wellId,
    'p_request': Map<String, Object?>.unmodifiable({
      'version': 1,
      'farmer_well_account_id': farmerWellAccountId,
      'farm_id': farmId,
      'pump_id': pumpId,
      'started_at': startedAt.toIso8601String(),
      if (endedAt != null) 'ended_at': endedAt!.toIso8601String(),
      'energy_source': energySource,
      'reason': reason,
      if (notes != null) 'notes': notes,
    }),
  });
}

class ManualSessionEntryReceiptRequest {
  const ManualSessionEntryReceiptRequest._(this.command, this.startedAt, this.endedAt);
  final CommandEnvelope command;
  final DateTime startedAt;
  final DateTime? endedAt;
  String get entryType => command.type == CommandType.recordHistoricalSession
      ? 'manual_historical_completed' : 'manual_external_active';
  Map<String, Object?> get arguments => {
    'p_well_id': command.wellId, 'p_command_id': command.commandId,
  };

  static ManualSessionEntryReceiptRequest? fromCommand(CommandEnvelope c) {
    if (!isManualSessionEntry(c.type) || !_uuid(c.accountId) ||
        !_uuid(c.wellId) || !_uuid(c.commandId) ||
        c.payload.length != 2 || c.payload['p_well_id'] != c.wellId ||
        c.aggregateLocalId != null || c.prerequisites.isNotEmpty ||
        c.localContext.isNotEmpty) {
      return null;
    }
    final r = c.payload['p_request'];
    if (r is! Map || r['version'] is! int || r['version'] != 1 ||
        !r.keys.every(const {'version','pump_id','farm_id',
          'farmer_well_account_id','started_at','ended_at',
          'energy_source','reason','notes'}.contains) ||
        ![r['pump_id'],r['farm_id'],r['farmer_well_account_id']].every(_uuid) ||
        !_text(r['reason']) ||
        (r.containsKey('notes') && r['notes'] != null && r['notes'] is! String) ||
        !const {'solar','well_diesel','farmer_diesel'}.contains(r['energy_source'])) {
      return null;
    }
    final start = _time(r['started_at']);
    final end = _time(r['ended_at']);
    if (start == null || start != c.occurredAt.toUtc() ||
        (c.type == CommandType.recordHistoricalSession
          ? end == null || !start.isBefore(end) || end.isAfter(c.createdLocalAt)
          : r.containsKey('ended_at')) || start.isAfter(c.createdLocalAt)) {
      return null;
    }
    return ManualSessionEntryReceiptRequest._(c, start, end);
  }
}

enum ManualSessionEntryState {
  accepted, processing, conflictOverlap, conflictActiveResource,
  validationError, needsReview, unresolved, notFound;

  static ManualSessionEntryState? fromWire(Object? value) => switch (value) {
    'accepted' => accepted,
    'processing' => processing,
    'conflict_overlap' => conflictOverlap,
    'conflict_active_resource' => conflictActiveResource,
    'validation_error' => validationError,
    'needs_review' => needsReview,
    'unresolved' => unresolved,
    'not_found' => notFound,
    _ => null,
  };
  bool get requiresAction => const {
    conflictOverlap, conflictActiveResource, validationError, needsReview,
  }.contains(this);
}

enum ManualSessionEntryReadFailureKind { authentication, forbidden, network, malformed }
sealed class ManualSessionEntryRead { const ManualSessionEntryRead(); }
class ManualSessionEntryReadFailure extends ManualSessionEntryRead {
  const ManualSessionEntryReadFailure(this.kind);
  final ManualSessionEntryReadFailureKind kind;
}

/// القبول دليل إنشاء تاريخي؛ المبلغ الحالي والحالة الحالية لهما قراءاتهما.
class ManualSessionEntryOutcome extends ManualSessionEntryRead {
  const ManualSessionEntryOutcome._(this.state, this.result, this.sessionId,
    this.startedAt, this.endedAt, this.amountMinor, this.isOpen);
  final ManualSessionEntryState state;
  final Map<String, Object?>? result;
  final String? sessionId;
  final DateTime? startedAt, endedAt;
  final int? amountMinor;
  final bool? isOpen;
}

/// لا يُفسر غياب نتيجة خادمية على أنه غياب نية المستخدم المحفوظة.
class ManualSessionEntryObservation {
  const ManualSessionEntryObservation(this.command,this.outcome);
  final CommandEnvelope command;
  final ManualSessionEntryRead? outcome;
  bool get isQueued => command.status == CommandStatus.pending;
  bool get isRecovering => command.status == CommandStatus.dispatching;
}

abstract interface class ManualSessionEntryReceiptTransport {
  Future<ManualSessionEntryRead> readManualSessionEntryReceipt(
    ManualSessionEntryReceiptRequest request,
  );
}

ManualSessionEntryRead parseManualSessionEntryResult(
  ManualSessionEntryReceiptRequest request, Object? raw,
) {
  const invalid = ManualSessionEntryReadFailure(ManualSessionEntryReadFailureKind.malformed);
  if (raw is! Map || !raw.keys.every((k) => k is String) ||
      raw['contract'] != 'manual_session_entry' ||
      raw['version'] is! int || raw['version'] != 1 ||
      raw['well_id'] != request.command.wellId ||
      raw['command_id'] != request.command.commandId ||
      raw['entry_type'] != request.entryType) {
    return invalid;
  }
  final state = ManualSessionEntryState.fromWire(raw['status']);
  if (state == null || state == ManualSessionEntryState.notFound) return invalid;
  final result = Map<String,Object?>.unmodifiable(raw.cast<String,Object?>());
  if (state != ManualSessionEntryState.accepted) {
    return ManualSessionEntryOutcome._(state,result,null,null,null,null,null);
  }
  final start = _time(raw['started_at']);
  final end = _time(raw['ended_at']);
  final completed = request.endedAt != null;
  if (!_uuid(raw['tenant_id']) || !_uuid(raw['session_id']) ||
      start != request.startedAt || !raw.containsKey('ended_at') ||
      !raw.containsKey('session_charge_id') || !raw.containsKey('amount_minor') ||
      (completed
        ? end != request.endedAt || !_uuid(raw['session_charge_id']) ||
          raw['amount_minor'] is! int || (raw['amount_minor'] as int) < 0 ||
          (raw['amount_minor'] as int) > 9223372036854775807
        : raw['ended_at'] != null || raw['session_charge_id'] != null || raw['amount_minor'] != null)) {
    return invalid;
  }
  return ManualSessionEntryOutcome._(state,result,raw['session_id'] as String,
    start,end,raw['amount_minor'] as int?,!completed);
}

ManualSessionEntryRead parseManualSessionEntryReceipt(
  ManualSessionEntryReceiptRequest request, Object? raw,
) {
  const invalid = ManualSessionEntryReadFailure(ManualSessionEntryReadFailureKind.malformed);
  if (raw is! Map || raw['contract'] != 'get_manual_session_entry_receipt' ||
      raw['version'] is! int || raw['version'] != 1 ||
      raw['well_id'] != request.command.wellId ||
      raw['command_id'] != request.command.commandId ||
      raw['retry_authorized'] != false || !raw.containsKey('result')) {
    return invalid;
  }
  final state = ManualSessionEntryState.fromWire(raw['status']);
  if (state == null) return invalid;
  if (raw['result'] == null) {
    return const {ManualSessionEntryState.processing,ManualSessionEntryState.notFound,
      ManualSessionEntryState.unresolved}.contains(state)
        ? ManualSessionEntryOutcome._(state,null,null,null,null,null,null) : invalid;
  }
  final parsed = parseManualSessionEntryResult(request,raw['result']);
  return parsed is ManualSessionEntryOutcome && parsed.state == state ? parsed : invalid;
}

bool _text(Object? v) => v is String && v.trim().isNotEmpty;
bool _uuid(Object? v) => v is String && RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
).hasMatch(v);
DateTime? _time(Object? v) {
  if (v is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3}(\d{3})?)?Z$').hasMatch(v)) return null;
  final t = DateTime.tryParse(v);
  if (t == null) return null;
  final canonical = t.toUtc().toIso8601String();
  return canonical == v || '${canonical.substring(0,canonical.length-1)}000Z' == v
      ? t.toUtc() : null;
}

/// أهلية إنشاء نية جديدة بتأكيد المستخدم؛ ليست تفويضًا لإعادة إرسال الأصل.
enum ManualEntryCorrectionEligibility {
  eligibleTerminalNoSession,
  ineligiblePendingOrAmbiguous,
  ineligibleSessionExists,
  ineligibleContradictoryEvidence,
  ineligibleUnsupportedOrUnknown,
}

/// وجود جلسة مثبت برابط المخزن أو بنتيجة قبول محفوظة ومتحقق منها.
/// الإدخال المنتهي لا يحتاج رابط إسقاط جلسة جارية، لكن قبوله يثبت جلسته.
enum ManualEntrySessionBinding { absent, present, contradictory }

/// لقطة محلية متسقة؛ لا تعرض صفوف المخزن أو حمولة نتيجة خادمية خامًا.
class ManualSessionEntryFollowUp {
  const ManualSessionEntryFollowUp._({
    required this.accountId,
    required this.wellId,
    required this.localId,
    required this.commandId,
    required this.facts,
    required this.outcome,
    required this.binding,
    required this.canonicalSessionId,
    required this.eligibility,
  });
  final String accountId, wellId, localId, commandId;
  final ManualSessionEntryFacts facts;
  final ManualSessionEntryState? outcome;
  final ManualEntrySessionBinding binding;
  final String? canonicalSessionId;
  final ManualEntryCorrectionEligibility eligibility;
}

/// الدليل المشترك فقط؛ سياسة حارس البدء وسياسة التصحيح تظلان مستقلتين.
bool manualEntryTerminalResultProvesNoSession(CommandEnvelope command) {
  if (command.status != CommandStatus.review || command.lastAttemptAt == null) {
    return false;
  }
  final request = ManualSessionEntryReceiptRequest.fromCommand(command);
  final outcome = request == null
      ? null
      : parseManualSessionEntryResult(request, command.serverResponse);
  if (outcome is! ManualSessionEntryOutcome || outcome.result == null) {
    return false;
  }
  final result = outcome.result!;
  if (!result.keys.every(
    const {
      'contract',
      'version',
      'well_id',
      'command_id',
      'entry_type',
      'status',
      'reason',
    }.contains,
  )) {
    return false;
  }
  return switch (outcome.state) {
    ManualSessionEntryState.validationError =>
      result['reason'] == null || result['reason'] == 'context_invalid',
    ManualSessionEntryState.conflictOverlap ||
    ManualSessionEntryState.conflictActiveResource => result['reason'] == null,
    _ => false,
  };
}

/// تُستدعى داخل لقطة المخزن، بعد قراءة الربط نفسه الذي يحمي بدء التشغيل.
ManualSessionEntryFollowUp? manualSessionEntryFollowUpFromSnapshot(
  CommandEnvelope command, {
  required String? boundSessionId,
  bool unsafeBinding = false,
}) {
  final request = ManualSessionEntryReceiptRequest.fromCommand(command);
  if (request == null) return null;
  final payload = command.payload['p_request'] as Map;
  final facts = ManualSessionEntryFacts(
    wellId: command.wellId!,
    farmerWellAccountId: payload['farmer_well_account_id'] as String,
    farmId: payload['farm_id'] as String,
    pumpId: payload['pump_id'] as String,
    startedAt: request.startedAt,
    endedAt: request.endedAt,
    energySource: payload['energy_source'] as String,
    reason: payload['reason'] as String,
    notes: payload['notes'] as String?,
  );
  final parsed = command.serverResponse == null
      ? null
      : parseManualSessionEntryResult(request, command.serverResponse);
  final outcome = parsed is ManualSessionEntryOutcome ? parsed : null;
  final accepted = outcome?.state == ManualSessionEntryState.accepted;
  final rejected = const {
    ManualSessionEntryState.validationError,
    ManualSessionEntryState.conflictOverlap,
    ManualSessionEntryState.conflictActiveResource,
  }.contains(outcome?.state);
  final resultHasSessionEvidence =
      !accepted &&
      command.serverResponse != null &&
      const {
        'session_id',
        'started_at',
        'ended_at',
        'tenant_id',
        'session_charge_id',
        'amount_minor',
      }.any(command.serverResponse!.containsKey);
  final contradictory =
      unsafeBinding ||
      (boundSessionId != null && !_uuid(boundSessionId)) ||
      resultHasSessionEvidence ||
      (boundSessionId != null && rejected) ||
      (accepted &&
          ((boundSessionId != null && boundSessionId != outcome!.sessionId) ||
              command.status != CommandStatus.confirmed ||
              (command.type == CommandType.adoptExternalSession &&
                  boundSessionId == null)));
  final binding = contradictory
      ? ManualEntrySessionBinding.contradictory
      : boundSessionId != null || accepted
      ? ManualEntrySessionBinding.present
      : ManualEntrySessionBinding.absent;
  final ManualEntryCorrectionEligibility eligibility;
  if (contradictory) {
    eligibility =
        ManualEntryCorrectionEligibility.ineligibleContradictoryEvidence;
  } else if (boundSessionId != null || accepted) {
    eligibility = ManualEntryCorrectionEligibility.ineligibleSessionExists;
  } else if (manualEntryTerminalResultProvesNoSession(command)) {
    eligibility = ManualEntryCorrectionEligibility.eligibleTerminalNoSession;
  } else if (command.serverResponse == null ||
      const {
        ManualSessionEntryState.processing,
        ManualSessionEntryState.needsReview,
        ManualSessionEntryState.unresolved,
        ManualSessionEntryState.notFound,
      }.contains(outcome?.state)) {
    eligibility = ManualEntryCorrectionEligibility.ineligiblePendingOrAmbiguous;
  } else {
    eligibility =
        ManualEntryCorrectionEligibility.ineligibleUnsupportedOrUnknown;
  }
  return ManualSessionEntryFollowUp._(
    accountId: command.accountId,
    wellId: command.wellId!,
    localId: command.localId,
    commandId: command.commandId,
    facts: facts,
    outcome: outcome?.state,
    binding: binding,
    canonicalSessionId: boundSessionId ?? outcome?.sessionId,
    eligibility: eligibility,
  );
}

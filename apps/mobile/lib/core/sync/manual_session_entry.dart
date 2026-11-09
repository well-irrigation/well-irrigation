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

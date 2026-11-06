import 'command_envelope.dart';
import 'command_type.dart';

abstract interface class SessionCorrectionReceiptTransport {
  Future<SessionCorrectionReceiptRead> readSessionCorrectionReceipt(
    SessionCorrectionReceiptRequest request,
  );
}

const _serverBigintMax = 9223372036854775807;
const _maxCorrectableBaseRevision = 9223372036854775806;

/// هوية قراءة فقط، مرتبطة بطلب التصحيح الأصلي؛ لا تمنح إذن إرسال.
class SessionCorrectionReceiptRequest {
  const SessionCorrectionReceiptRequest._({
    required this.accountId,
    required this.wellId,
    required this.sessionId,
    required this.commandId,
    required this.baseRevision,
    required this.desiredStartedAt,
    required this.desiredEndedAt,
  });

  final String accountId, wellId, sessionId, commandId;
  final int baseRevision;
  final DateTime desiredStartedAt, desiredEndedAt;

  static SessionCorrectionReceiptRequest? fromCommand(CommandEnvelope command) {
    final payload = command.payload;
    final session = payload['p_session_id'];
    final revision = payload['p_base_revision'];
    final start = _strictTime(payload['p_desired_started_at']);
    final end = _strictTime(payload['p_desired_ended_at']);
    const keys = {
      'p_session_id',
      'p_base_revision',
      'p_reason',
      'p_desired_started_at',
      'p_desired_ended_at',
    };
    if (command.type != CommandType.correctIrrigationSession ||
        !_nonEmpty(command.accountId) ||
        !_nonEmpty(command.wellId) ||
        !_nonEmpty(command.commandId) ||
        !_nonEmpty(session) ||
        revision is! int ||
        revision < 0 ||
        revision > _maxCorrectableBaseRevision ||
        !_nonEmpty(payload['p_reason']) ||
        payload.length != keys.length ||
        !payload.keys.every(keys.contains) ||
        start == null ||
        end == null ||
        !start.isBefore(end)) {
      return null;
    }
    return SessionCorrectionReceiptRequest._(
      accountId: command.accountId,
      wellId: command.wellId!,
      sessionId: session as String,
      commandId: command.commandId,
      baseRevision: revision,
      desiredStartedAt: start,
      desiredEndedAt: end,
    );
  }

  Map<String, Object?> get arguments => {
    'p_session_id': sessionId,
    'p_command_id': commandId,
  };
}

enum SessionCorrectionReceiptState {
  accepted,
  processing,
  notFound,
  unresolved,
}

enum SessionCorrectionReceiptFailureKind {
  authentication,
  forbidden,
  network,
  malformed,
}

sealed class SessionCorrectionReceiptRead {
  const SessionCorrectionReceiptRead();
}

class SessionCorrectionReceiptResponse extends SessionCorrectionReceiptRead {
  const SessionCorrectionReceiptResponse(this.state, this.receipt);
  final SessionCorrectionReceiptState state;
  final Map<String, Object?>? receipt;
}

class SessionCorrectionReceiptFailure extends SessionCorrectionReceiptRead {
  const SessionCorrectionReceiptFailure(this.kind);
  final SessionCorrectionReceiptFailureKind kind;
}

/// يحفظ نتيجة القبول التاريخية؛ الحالة المالية الحالية لها عقد قراءة آخر.
SessionCorrectionReceiptRead parseSessionCorrectionReceipt(
  SessionCorrectionReceiptRequest request,
  Object? raw,
) {
  const malformed = SessionCorrectionReceiptFailure(
    SessionCorrectionReceiptFailureKind.malformed,
  );
  if (raw is! Map ||
      raw['contract'] != 'get_session_correction_receipt' ||
      raw['version'] is! int ||
      raw['version'] != 1 ||
      raw['session_id'] != request.sessionId ||
      raw['command_id'] != request.commandId ||
      raw['command_type'] != 'correct_irrigation_session' ||
      raw['retry_authorized'] is! bool ||
      raw['retry_authorized'] != false ||
      !raw.containsKey('receipt')) {
    return malformed;
  }
  final state = switch (raw['status']) {
    'accepted' => SessionCorrectionReceiptState.accepted,
    'processing' => SessionCorrectionReceiptState.processing,
    'not_found' => SessionCorrectionReceiptState.notFound,
    'unresolved' => SessionCorrectionReceiptState.unresolved,
    _ => null,
  };
  if (state == null) return malformed;
  final receipt = raw['receipt'];
  if (state != SessionCorrectionReceiptState.accepted) {
    return receipt == null
        ? SessionCorrectionReceiptResponse(state, null)
        : malformed;
  }
  if (receipt is! Map ||
      !receipt.keys.every((key) => key is String) ||
      receipt['contract'] != 'session_correction' ||
      receipt['version'] is! int ||
      receipt['version'] != 1 ||
      receipt['status'] != 'accepted' ||
      !_nonEmpty(receipt['tenant_id']) ||
      receipt['well_id'] != request.wellId ||
      receipt['session_id'] != request.sessionId ||
      receipt['command_id'] != request.commandId ||
      !_nonEmpty(receipt['correction_id']) ||
      receipt['previous_revision'] is! int ||
      (receipt['previous_revision'] as int) < 0 ||
      receipt['previous_revision'] != request.baseRevision ||
      receipt['operational_revision'] is! int ||
      (receipt['operational_revision'] as int) < 1 ||
      (receipt['operational_revision'] as int) > _serverBigintMax ||
      receipt['operational_revision'] != request.baseRevision + 1 ||
      receipt['financial_status'] != 'pending') {
    return malformed;
  }
  final start = _strictTime(receipt['actual_started_at']);
  final end = _strictTime(receipt['actual_ended_at']);
  final acceptedAt = _strictTime(receipt['accepted_at']);
  if (start == null ||
      end == null ||
      acceptedAt == null ||
      !start.isAtSameMomentAs(request.desiredStartedAt) ||
      !end.isAtSameMomentAs(request.desiredEndedAt)) {
    return malformed;
  }
  return SessionCorrectionReceiptResponse(
    state,
    Map<String, Object?>.unmodifiable(Map<String, Object?>.from(receipt)),
  );
}

bool _nonEmpty(Object? value) => value is String && value.trim().isNotEmpty;

// نفس نطاق ISO الصريح في حقائق التصحيح: فحص التقويم قبل تحويل الإزاحة.
final _timestamp = RegExp(
  r'^([+-]?\d{4,6})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2}):(\d{2})'
  r'(?:[.,](\d+))?([Zz]|([+-])(\d{2})(?::?(\d{2}))?)$',
);

DateTime? _strictTime(Object? value) {
  if (value is! String) return null;
  final match = _timestamp.firstMatch(value);
  if (match == null || match.end != value.length) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final hour = int.parse(match[4]!);
  final minute = int.parse(match[5]!);
  final second = int.parse(match[6]!);
  final offsetHour = match[10] == null ? 0 : int.parse(match[10]!);
  final offsetMinute = match[11] == null ? 0 : int.parse(match[11]!);
  if (offsetHour > 23 || offsetMinute > 59) return null;
  try {
    final wall = DateTime.utc(year, month, day, hour, minute, second);
    if (wall.year != year ||
        wall.month != month ||
        wall.day != day ||
        wall.hour != hour ||
        wall.minute != minute ||
        wall.second != second) {
      return null;
    }
    return DateTime.tryParse(value)?.toUtc();
  } on ArgumentError {
    return null;
  } on FormatException {
    return null;
  }
}

/// تصنيف مصدر النية فقط؛ لا يمنح إذن إرسال ولا يحسم نتيجة التنفيذ.
library;

import 'dart:convert';

import 'command_envelope.dart';
import 'command_type.dart';

enum CommandIntentOrigin { provenHuman, provenAutomatic, unresolved }

bool sessionFinancialHistoryMutation(CommandType type) =>
    type == CommandType.adjustSessionFinancialAmount;

bool q137OperationalCommand(CommandType type) => const {
  CommandType.startOperationalSession,
  CommandType.startIrrigationSession,
  CommandType.startAdhocSession,
  CommandType.startBookingSession,
  CommandType.completeIrrigationSession,
  CommandType.pauseIrrigationSession,
  CommandType.resumeIrrigationSession,
  CommandType.changeSessionEnergySource,
  CommandType.recordBookingTransitionDecision,
  CommandType.executePendingBookingStart,
  CommandType.endBookingTransitionChain,
}.contains(type);

String humanCommandIntentBundleKey(String localId) =>
    'command.human_intent.v1.$localId';

String humanCommandIntentRecord(CommandEnvelope command) {
  final starting =
      command.type == CommandType.startOperationalSession ||
      command.type == CommandType.startIrrigationSession ||
      command.type == CommandType.startAdhocSession;
  return jsonEncode({
    'version': 1,
    'provenance': 'human_command_intent',
    'account_id': command.accountId,
    'well_id': command.wellId,
    'session_local_id': starting
        ? command.localId
        : (command.aggregateLocalId ?? command.localId),
    'command_local_id': command.localId,
    'command_id': command.commandId,
    'command_type': command.type.storageValue,
    'action': starting
        ? 'start_session'
        : command.type == CommandType.completeIrrigationSession
        ? 'complete_session'
        : command.type.storageValue,
    'occurred_at': command.occurredAt.toUtc().toIso8601String(),
  });
}

class CommandIntentClassification {
  CommandIntentClassification(
    this.origin,
    this.reason,
    Iterable<String> evidence,
  ) : evidence = List.unmodifiable(evidence);

  final CommandIntentOrigin origin;

  /// رمز تشخيصي ثابت، وليس رسالة رفض أعمال أو نص واجهة.
  final String reason;

  /// مسارات الأدلة المرتبطة بالهوية، دون نسخ السجلات أو بيانات المزارع.
  final List<String> evidence;
}

/// دالة نقية تستقبل صف الأمر ولقطات سجلات محلية موجودة بالفعل.
///
/// [records] مفاتيح حزمها الأصلية وقيمها JSON أو خرائط مفكوكة. على المستدعي
/// قراءة المفاتيح المحددة من تخزين الحساب نفسه، لا قبول أدلة مرسلة من UI.
/// هذه قرائن مصدر محلي، وليست إثبات صلاحية أو توقيعًا أمنيًا.
///
/// لا تكفي manual_start وحدها: يلزم سجل booking.manual_start.v1 الأصلي
/// الذي يحفظ start_local_id وstart_command_id للأمر نفسه ضمن حسابه وبئره وحجزه.
/// يدعم كذلك أثر الإكمال والخليفة المرتبطين. لا يستنتج
/// بشرية الإكمال من بداية بشرية، ولا مصدر النية من حالة الإرسال أو رد الخادم.
/// غياب دليل أو عدم دعمه يعني unresolved، لا إذن إعادة تنفيذ.
CommandIntentClassification classifyCommandIntent(
  CommandEnvelope command, {
  Map<String, Object?> records = const {},
}) {
  final evidence = <String>[];
  final usedKeys = <String>{};
  var human = false;
  var automatic = false;
  var invalid = false;

  CommandIntentClassification unresolved(String reason) =>
      CommandIntentClassification(
        CommandIntentOrigin.unresolved,
        reason,
        evidence,
      );

  if (!_id(command.localId) ||
      !_id(command.commandId) ||
      !_id(command.accountId) ||
      !_id(command.wellId)) {
    return unresolved('invalid_command_identity');
  }

  final freeStart =
      command.type == CommandType.startOperationalSession ||
      command.type == CommandType.startIrrigationSession ||
      command.type == CommandType.startAdhocSession;
  final humanKey = humanCommandIntentBundleKey(command.localId);
  if (records.containsKey(humanKey)) {
    usedKeys.add(humanKey);
    final original = _record(records[humanKey]);
    final root = freeStart
        ? command.localId
        : (command.aggregateLocalId ?? command.localId);
    if (!q137OperationalCommand(command.type) ||
        !_id(root) ||
        !_scoped(original, 'human_command_intent', command, root) ||
        original?['command_local_id'] != command.localId ||
        original?['command_id'] != command.commandId ||
        original?['command_type'] != command.type.storageValue ||
        original?['action'] !=
            (freeStart
                ? 'start_session'
                : command.type == CommandType.completeIrrigationSession
                ? 'complete_session'
                : command.type.storageValue) ||
        _at(original?['occurred_at']) != command.occurredAt.toUtc()) {
      invalid = true;
    } else {
      human = true;
      evidence.add(humanKey);
    }
  }

  if (command.type == CommandType.startBookingSession) {
    final booking = command.payload['p_booking_id'];
    if (!_id(booking)) return unresolved('invalid_booking_identity');
    final marker = command.localContext['manual_start'];
    if (command.localContext.containsKey('manual_start')) {
      if (marker is! bool) {
        invalid = true;
      } else if (marker) {
        if (command.localContext['booking_id'] != booking) {
          invalid = true;
        } else {
          final key = 'booking.manual_start.v1.${command.wellId}.$booking';
          usedKeys.add(key);
          final original = _record(records[key]);
          if (original == null ||
              original.length != 2 ||
              original['start_local_id'] != command.localId ||
              original['start_command_id'] != command.commandId) {
            invalid = true;
          } else {
            human = true;
            evidence.add('local_context.manual_start');
            evidence.add('$key:start_local_id+start_command_id');
          }
        }
      }
    }
    final root = command.localContext['previous_session_local_id'];
    if (_id(root)) {
      final key = 'session.successor.v1.${command.wellId}.$root';
      if (records.containsKey(key)) {
        usedKeys.add(key);
        final successor = _record(records[key]);
        final completionKey = 'session.completion.v1.${command.wellId}.$root';
        usedKeys.add(completionKey);
        final completion = _record(records[completionKey]);
        final candidate = successor?['candidate'];
        if (!_scoped(successor, 'session_successor_effect', command, root) ||
            !_scoped(completion, 'session_completion_effect', command, root) ||
            successor?['state'] != 'starting' ||
            successor?['start_local_id'] != command.localId ||
            successor?['start_command_id'] != command.commandId ||
            !_id(successor?['effect_id']) ||
            !_id(completion?['completion_local_id']) ||
            !_id(completion?['completion_command_id']) ||
            successor?['completion_command_id'] !=
                completion?['completion_command_id'] ||
            !command.prerequisites.contains(
              completion?['completion_local_id'],
            ) ||
            candidate is! Map ||
            candidate['booking_id'] != booking ||
            command.localContext['booking_id'] != booking) {
          invalid = true;
        } else {
          automatic = true;
          evidence.add('$key:${command.localId}:${command.commandId}');
          evidence.add(
            '$completionKey:${completion!['completion_command_id']}',
          );
        }
      }
    }
  } else if (command.type == CommandType.completeIrrigationSession) {
    final root = command.aggregateLocalId;
    final session = command.payload['p_session_id'];
    if (!_id(root) ||
        session is! Map ||
        session.length != 2 ||
        session[r'$ref'] != root ||
        session[r'$kind'] != 'session') {
      return unresolved('unproven_session_link');
    }
    final key = 'session.completion.v1.${command.wellId}.$root';
    if (records.containsKey(key)) {
      usedKeys.add(key);
      final completion = _record(records[key]);
      if (!_scoped(completion, 'session_completion_effect', command, root) ||
          completion?['completion_local_id'] != command.localId ||
          completion?['completion_command_id'] != command.commandId ||
          _at(completion?['completed_at']) != command.occurredAt.toUtc()) {
        invalid = true;
      } else {
        final trigger = completion!['trigger'];
        if (trigger == 'manual_stop') {
          human = true;
        } else if (trigger == 'auto_due' || trigger == 'late_recovery') {
          automatic = true;
        }
        if (human || automatic) {
          evidence.add('$key:$trigger:${command.commandId}');
        }
      }
    }
  } else if (freeStart) {
    if (command.payload['p_well_id'] != command.wellId) {
      return unresolved('unproven_well_link');
    }
  } else if (!human) {
    return unresolved('unsupported_legacy_intent');
  }

  if (records.keys.any((key) => !usedKeys.contains(key))) {
    return unresolved('unbound_record');
  }
  if (human && automatic) return unresolved('conflicting_evidence');
  if (invalid) return unresolved('invalid_or_unbound_evidence');
  if (human) {
    return CommandIntentClassification(
      CommandIntentOrigin.provenHuman,
      'linked_human_evidence',
      evidence,
    );
  }
  if (automatic) {
    return CommandIntentClassification(
      CommandIntentOrigin.provenAutomatic,
      'linked_automatic_evidence',
      evidence,
    );
  }
  return unresolved('insufficient_evidence');
}

bool _id(Object? value) => value is String && value.trim().isNotEmpty;

Map<Object?, Object?>? _record(Object? value) {
  if (value is String) {
    try {
      value = jsonDecode(value);
    } on FormatException {
      return null;
    }
  }
  return value is Map ? value.cast<Object?, Object?>() : null;
}

DateTime? _at(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

bool _scoped(
  Map<Object?, Object?>? record,
  String provenance,
  CommandEnvelope command,
  Object? root,
) =>
    record != null &&
    record['version'] is int &&
    record['version'] == 1 &&
    record['provenance'] == provenance &&
    record['account_id'] == command.accountId &&
    record['well_id'] == command.wellId &&
    record['session_local_id'] == root;

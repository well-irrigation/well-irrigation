/// قراءة محددة للأمر وأدلته؛ لا قرار إرسال ولا تغيير حالة.
library;

import 'command_intent_policy.dart';
import 'command_envelope.dart';
import 'command_type.dart';
import 'outbox_store.dart';

class CommandIntentEvidenceReader {
  CommandIntentEvidenceReader(OutboxStore store)
    : this.fromReads(store.commandByLocalId, store.readBundle);

  /// يسمح بتمرير قراءات المعاملة نفسها، دون الرجوع لاتصال خارجها.
  CommandIntentEvidenceReader.fromReads(
    this._commandByLocalId,
    this._readBundle,
  );

  /// يجب أن يكون المخزن مهيأً. لا يهيئ القارئ قاعدة أو يكتب سجلًا.
  final Future<CommandEnvelope?> Function(String, String) _commandByLocalId;
  final Future<String?> Function(String, String) _readBundle;

  Future<CommandIntentClassification> read({
    required String accountId,
    required String wellId,
    required String localId,
  }) async {
    CommandIntentClassification unresolved(String reason) =>
        CommandIntentClassification(
          CommandIntentOrigin.unresolved,
          reason,
          const [],
        );
    if ([accountId, wellId, localId].any((id) => id.trim().isEmpty)) {
      return unresolved('invalid_requested_scope');
    }
    try {
      final command = await _commandByLocalId(accountId, localId);
      if (command == null) return unresolved('command_not_found');
      if (command.accountId != accountId ||
          command.wellId != wellId ||
          command.localId != localId) {
        return unresolved('stored_command_scope_mismatch');
      }
      final records = <String, Object?>{};
      Future<bool> load(String key) async {
        final value = await _readBundle(accountId, key);
        if (value == null) return false;
        records[key] = value;
        return true;
      }

      switch (command.type) {
        case CommandType.startBookingSession:
          final booking = command.payload['p_booking_id'];
          if (command.localContext['manual_start'] == true &&
              booking is String &&
              booking.isNotEmpty) {
            await load('booking.manual_start.v1.$wellId.$booking');
          }
          final previous = command.localContext['previous_session_local_id'];
          if (previous is String &&
              previous.isNotEmpty &&
              await load('session.successor.v1.$wellId.$previous')) {
            await load('session.completion.v1.$wellId.$previous');
          }
        case CommandType.startIrrigationSession:
        case CommandType.startAdhocSession:
          await load(humanCommandIntentBundleKey(localId));
        case CommandType.completeIrrigationSession:
          await load(humanCommandIntentBundleKey(localId));
          final root = command.aggregateLocalId;
          if (root != null && root.isNotEmpty) {
            await load('session.completion.v1.$wellId.$root');
          }
        default:
          await load(humanCommandIntentBundleKey(localId));
          break;
      }
      return classifyCommandIntent(command, records: records);
    } on Object {
      // غياب اليقين لا يحول محاولة قديمة إلى فشل أو إذن إعادة تنفيذ.
      return unresolved('intent_evidence_unavailable');
    }
  }
}

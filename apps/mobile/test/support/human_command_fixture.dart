import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';

/// Explicit fixture action for tests which enqueue human commands directly.
/// Legacy/provenance-negative fixtures must not call this helper.
Future<void> recordTestHumanAction(OutboxStore store, CommandEnvelope command) {
  if (!const {
    CommandType.startIrrigationSession,
    CommandType.startAdhocSession,
    CommandType.pauseIrrigationSession,
    CommandType.resumeIrrigationSession,
    CommandType.changeSessionEnergySource,
    CommandType.completeIrrigationSession,
  }.contains(command.type)) {
    throw ArgumentError('not_current_manual_command');
  }
  return store
      .insertBundle(
        accountId: command.accountId,
        key: humanCommandIntentBundleKey(command.localId),
        value: humanCommandIntentRecord(command),
        commands: const [],
      )
      .then((_) {});
}

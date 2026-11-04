import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';

/// Explicit server receipt for tests exercising post-acceptance UI.
/// Calling completeSession alone records human intent, not accepted completion.
Future<void> acceptTestCompletion({
  required OutboxStore store,
  required OfflineSessionCoordinator coordinator,
  required String accountId,
  required String wellId,
  int amountMinor = 0,
  int rateMinor = 0,
}) async {
  final commands = await store.allCommands(accountId);
  final end = commands.lastWhere(
    (c) =>
        c.wellId == wellId && c.type == CommandType.completeIrrigationSession,
  );
  final root = commands.singleWhere((c) => c.localId == end.aggregateLocalId);
  final serverId =
      (await store.mapping(
        accountId,
        root.localId,
        EntityKind.session,
      ))?.serverId ??
      'accepted-${root.localId}';
  await store.putMapping(
    accountId,
    IdMapping(
      localId: root.localId,
      kind: EntityKind.session,
      serverId: serverId,
      resolvedAt: end.occurredAt,
    ),
  );
  final seconds = end.occurredAt.difference(root.occurredAt).inSeconds;
  expect(
    await (store as AtomicCommandDispatchStore).reconcileCompletionReceipt(
      end,
      serverId,
      {
        'session_id': serverId,
        'session_charge_id': 'charge-${end.localId}',
        'status': 'closed',
        'ended_at': end.occurredAt.toIso8601String(),
        'actual_seconds': seconds,
        'billable_seconds': seconds,
        'weighted_price_per_hour_minor': rateMinor,
        'amount_minor': amountMinor,
        'segments': <Object?>[],
      },
    ),
    isTrue,
  );
  await coordinator.freshProjectActiveSession(
    accountId: accountId,
    wellId: wellId,
  );
}

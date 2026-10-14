import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_reference.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';

import 'package_a_outbox_test.dart' as f;

class EndChainTransport extends f.PackageTransport {
  bool rejectEnd = false;
  @override
  Future<DispatchResult> dispatch(DispatchRequest request) async {
    if (request.type != CommandType.endBookingTransitionChain) {
      return super.dispatch(request);
    }
    requests.add(request);
    return normalizeAcceptedResponse(
      request.type,
      rejectEnd
          ? {
              'contract': 'end_booking_transition_chain',
              'version': 1,
              'status': 'rejected',
              'reason_code': 'next_booking_exists',
            }
          : {
              'contract': 'end_booking_transition_chain',
              'version': 1,
              'status': 'ended',
              'session_id': 'server-B',
              'chain_id': 'chain',
              'well_id': 'well',
              'ended_reason': 'final_booking_completed',
              'ended_at': f.instant.toIso8601String(),
            },
    );
  }
}

void main() {
  test('end-chain contract has only session and stable command id, no entity or event time', () {
    const type = CommandType.endBookingTransitionChain;
    expect(type.rpcName, 'end_booking_transition_chain');
    expect(type.scope, CommandScope.session);
    expect(type.produces, isNull);
    expect(type.eventTimeArgument, isNull);
    expect(
      buildRpcArguments(
        type: type,
        commandId: 'stable',
        occurredAt: f.instant,
        resolvedPayload: {'p_session_id': 'server'},
      ),
      {'p_session_id': 'server', 'p_command_id': 'stable'},
    );
  });
  for (final mode in ['pending', 'retry', 'review', 'accepted']) {
    test(
      'completion $mode gates end-chain without blocking another well',
      () async {
        final store = InMemoryOutboxStore();
        await store.insert(
          f.command('complete', CommandType.completeIrrigationSession, 1),
        );
        await store.insert(
          f.command(
            'end',
            CommandType.endBookingTransitionChain,
            2,
            prerequisites: ['complete'],
          ),
        );
        await store.insert(
          f.command(
            'unrelated',
            CommandType.startBookingSession,
            3,
            well: 'other',
          ),
        );
        if (mode == 'pending') {
          await store.claim('account', 'complete', attemptedAt: DateTime.now());
        }
        final transport = EndChainTransport();
        if (mode == 'retry') {
          transport.completionResult = const DispatchFailed(
            disposition: FailureDisposition.retry,
            message: 'offline',
          );
        }
        if (mode == 'review') {
          transport.completionResult = const DispatchFailed(
            disposition: FailureDisposition.review,
            message: 'conflict',
          );
        }
        await SyncEngine(store: store, transport: transport).run('account');
        expect(
          transport.requests.any((r) => r.commandId == 'uuid-end'),
          mode == 'accepted',
        );
        expect(
          transport.requests.any((r) => r.commandId == 'uuid-unrelated'),
          isTrue,
        );
        expect(
          (await store.commandByLocalId('account', 'end'))?.status,
          mode == 'review'
              ? CommandStatus.review
              : mode == 'accepted'
              ? CommandStatus.confirmed
              : CommandStatus.pending,
        );
      },
    );
  }
  test('local session reference resolves and replay does not dispatch a second end', () async {
    final store = InMemoryOutboxStore();
    await store.putMapping(
      'account',
      IdMapping(
        localId: 'local-session',
        kind: EntityKind.session,
        serverId: 'server-B',
        resolvedAt: f.instant,
      ),
    );
    await store.insert(
      f.command('complete', CommandType.completeIrrigationSession, 1),
    );
    final end = CommandEnvelope(
      localId: 'end',
      commandId: 'uuid-end',
      type: CommandType.endBookingTransitionChain,
      accountId: 'account',
      sequence: 2,
      occurredAt: f.instant,
      createdLocalAt: f.instant,
      wellId: 'well',
      prerequisites: ['complete'],
      payload: {
        'p_session_id': const CommandReference(
          localId: 'local-session',
          kind: EntityKind.session,
        ).toJson(),
      },
    );
    await store.insert(end);
    final transport = EndChainTransport();
    final engine = SyncEngine(store: store, transport: transport);
    await engine.run('account');
    await engine.run('account');
    final requests = transport.requests
        .where((r) => r.type == CommandType.endBookingTransitionChain)
        .toList();
    expect(requests, hasLength(1));
    expect(requests.single.arguments, {
      'p_session_id': 'server-B',
      'p_command_id': 'uuid-end',
    });
    expect(await store.mapping('account', 'end', EntityKind.session), isNull);
    expect(await store.mappings('account'), hasLength(2));
  });
  test(
    'next booking rejection is durable review and never blindly retried',
    () async {
      final store = InMemoryOutboxStore();
      await store.insert(
        f.command('complete', CommandType.completeIrrigationSession, 1),
      );
      await store.insert(
        f.command(
          'end',
          CommandType.endBookingTransitionChain,
          2,
          prerequisites: ['complete'],
        ),
      );
      final transport = EndChainTransport()..rejectEnd = true;
      final engine = SyncEngine(store: store, transport: transport);
      await engine.run('account');
      await engine.run('account');
      final row = (await store.commandByLocalId('account', 'end'))!;
      expect(row.status, CommandStatus.review);
      expect(row.serverResponse?['reason_code'], 'next_booking_exists');
      expect(
        transport.requests.where(
          (r) => r.type == CommandType.endBookingTransitionChain,
        ),
        hasLength(1),
      );
    },
  );
}

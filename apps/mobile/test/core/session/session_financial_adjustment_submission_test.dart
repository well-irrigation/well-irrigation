import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/session_financial_adjustment.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

class _ProbeTransport
    implements CommandTransport, SessionFinancialAdjustmentTransport {
  _ProbeTransport(this.store);
  final InMemoryOutboxStore store;
  final requests = <SessionFinancialAdjustmentRequest>[];
  final entered = Completer<void>();
  final response = Completer<SessionFinancialAdjustmentRead>();

  @override
  Future<DispatchResult> dispatch(DispatchRequest request) =>
      throw StateError('financial command must use typed transport');

  @override
  Future<SessionFinancialAdjustmentRead> adjustSessionFinancialAmount(
    SessionFinancialAdjustmentRequest request,
  ) async {
    requests.add(request);
    final saved = (await store.allCommands('account-a')).single;
    expect(saved.status, CommandStatus.dispatching);
    expect(saved.commandId, request.commandId);
    expect(saved.payload, request.command.payload);
    if (!entered.isCompleted) entered.complete();
    return response.future;
  }

  @override
  Future<SessionFinancialAdjustmentRead> readSessionFinancialAdjustmentReceipt(
    SessionFinancialAdjustmentReceiptRequest request,
  ) => throw StateError('not used in first dispatch');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('durable financial intent exists before first network call', () async {
    final store = InMemoryOutboxStore();
    final transport = _ProbeTransport(store);
    final coordinator = OfflineSessionCoordinator(
      store: store,
      commandTransport: transport,
    );
    try {
      final saved = await coordinator.submitSessionFinancialAdjustment(
        accountId: 'account-a',
        wellId: 'well-a',
        sessionId: 'session-a',
        baseOperationalRevision: 3,
        baseSystemFinancialRevision: 2,
        baseManualApprovalRevision: 1,
        approvedAmountYER: 0,
        reason: '  اعتماد صفر  ',
      );
      await transport.entered.future.timeout(const Duration(seconds: 2));
      expect(saved.payload['p_reason'], 'اعتماد صفر');
      expect(saved.payload['p_approved_amount_minor'], 0);
      expect(saved.aggregateLocalId, isNull);
      expect(transport.requests, hasLength(1));
    } finally {
      if (!transport.response.isCompleted) {
        transport.response.complete(
          const SessionFinancialAdjustmentReadFailure(
            SessionFinancialAdjustmentReadFailureKind.network,
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);
      coordinator.dispose();
      await store.close();
    }
  });
}

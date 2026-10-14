import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';

import 'session_test_support.dart';

void main() {
  test(
    'تفاصيل A تستقبل إقرارها بعد إغلاق B دون أحداث للسجل غير المركب',
    () async {
      final store = InMemoryOutboxStore();
      final coordinator = OfflineSessionCoordinator(store: store);
      final at = DateTime.utc(2026, 10, 14);
      Future<String> close(String farmer, DateTime startAt) async {
        final start = await coordinator.startSession(
          accountId: 'a',
          wellId: 'w',
          pumpId: 'p',
          farmId: 'f',
          farmerAccountId: farmer,
          energySource: 'solar',
          startedAt: startAt,
        );
        await coordinator.completeSession(
          accountId: 'a',
          sessionLocalId: start.localId,
          completedAt: startAt.add(const Duration(minutes: 2)),
        );
        return start.localId;
      }

      final a = await close('farmer-a', at);
      await close('farmer-b', at.add(const Duration(minutes: 3)));
      await store.putMapping(
        'a',
        IdMapping(
          localId: a,
          kind: EntityKind.session,
          serverId: 'server-A',
          resolvedAt: at,
        ),
      );
      final observed = <ActiveSessionRecord>[];
      final unrelated = <ActiveSessionRecord>[];
      final sub = coordinator
          .watchCompletionResult(
            accountId: 'a',
            wellId: 'w',
            serverSessionId: 'server-A',
          )
          .listen(observed.add);
      final other = coordinator
          .watchCompletionResult(
            accountId: 'a',
            wellId: 'other',
            serverSessionId: 'server-A',
          )
          .listen(unrelated.add);
      await Future<void>.delayed(Duration.zero);
      final completion = (await store.commandsForWell('a', 'w')).singleWhere(
        (c) =>
            c.aggregateLocalId == a &&
            c.type == CommandType.completeIrrigationSession,
      );
      await store.markConfirmed(
        'a',
        completion.localId,
        serverResponse: {'session_charge_id': 'charge-A', 'amount_minor': 50},
        attemptedAt: at,
      );
      await coordinator.freshProjectActiveSession(accountId: 'a', wellId: 'w');
      await Future<void>.delayed(Duration.zero);
      expect(observed.single.approvedAmountMinor, 50);
      expect(unrelated, isEmpty);
      await sub.cancel();
      await other.cancel();
      coordinator.dispose();
    },
  );
  test(
    'نتيجة الإكمال والدفعة المقبولة تستعاد من SQLite دون مؤقت مالي',
    () async {
      sqfliteFfiInit();
      final dir = await Directory.systemTemp.createTemp('e1-result-');
      final path = '${dir.path}/outbox.db';
      var store = SqliteOutboxStore(
        databasePath: path,
        sqfliteFactory: databaseFactoryFfi,
      );
      var coordinator = OfflineSessionCoordinator(store: store);
      final at = DateTime.utc(2026, 10, 14);
      final start = await coordinator.startSession(
        accountId: 'a',
        wellId: 'w',
        pumpId: 'p',
        farmId: 'f',
        farmerAccountId: 'farmer',
        energySource: 'solar',
        farmerName: 'غانم',
        farmName: 'الوادي',
        pumpName: 'الشرقية',
        startedAt: at,
      );
      final end = await coordinator.completeSession(
        accountId: 'a',
        sessionLocalId: start.localId,
        completedAt: at.add(const Duration(minutes: 2)),
      );
      final payment = await coordinator.recordPayment(
        accountId: 'a',
        wellId: 'w',
        farmerAccountId: 'farmer',
        amountMinor: 200,
        paymentMethod: 'cash',
        sessionLocalId: start.localId,
        sessionCompletionLocalId: end.localId,
      );
      await store.markConfirmed(
        'a',
        end.localId,
        serverResponse: {'session_charge_id': 'charge', 'amount_minor': 125},
        attemptedAt: at,
      );
      await store.markConfirmed(
        'a',
        payment.localId,
        serverResponse: {
          'payment_id': 'payment-server',
          'settled_minor': 125,
          'advance_minor': 75,
          'receipt': {
            'payment_id': 'payment-server',
            'public_code': 'PMT-1',
            'amount_minor': 200,
          },
        },
        attemptedAt: at,
      );
      await store.putMapping(
        'a',
        IdMapping(
          localId: payment.localId,
          serverId: 'payment-server',
          kind: EntityKind.payment,
          resolvedAt: at,
        ),
      );
      coordinator.dispose();
      await store.close();
      store = SqliteOutboxStore(
        databasePath: path,
        sqfliteFactory: databaseFactoryFfi,
      );
      coordinator = OfflineSessionCoordinator(store: store);
      final records = <ActiveSessionRecord>[];
      final subscription = coordinator.completionResultStream.listen(
        records.add,
      );
      await coordinator.freshProjectActiveSession(accountId: 'a', wellId: 'w');
      await Future<void>.delayed(Duration.zero);
      final restored = records.single;
      expect(restored.approvedAmountMinor, 125);
      expect(restored.farmerName, 'غانم');
      expect(restored.farmName, 'الوادي');
      expect(restored.pumpName, 'الشرقية');
      expect(restored.completedAt, at.add(const Duration(minutes: 2)));
      expect(restored.payments.single.acceptedReceipt?['public_code'], 'PMT-1');
      expect(restored.payments.single.acceptedReceipt?['amount_minor'], 200);
      final count = records.length;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(
        records.length,
        count,
        reason: 'نبض العداد لا يصدر حدث نتيجة مالية',
      );
      await subscription.cancel();
      coordinator.dispose();
      await store.close();
      await dir.delete(recursive: true);
    },
  );
  test(
    'الإقرار وحده يحول المبلغ التقديري إلى مبلغ معتمد قابل للاستعادة',
    () async {
      final store = InMemoryOutboxStore();
      final repo = OutboxRepository(store: store);
      final at = DateTime.utc(2026, 10, 14);
      final start = await startSession(repo, at: at);
      final end = await complete(
        repo,
        session: start,
        at: at.add(const Duration(minutes: 2)),
      );
      var record =
          (await ActiveSessionProjector(
            store: store,
            pricing: pricingAt(at),
          ).projectSession(
            sessionAccount,
            start.localId,
            now: at.add(const Duration(minutes: 3)),
          ))!;
      expect(record.approvedAmountMinor, isNull);
      await store.markConfirmed(
        sessionAccount,
        end.localId,
        serverResponse: {'session_charge_id': 'charge-1', 'amount_minor': 125},
        attemptedAt: at,
      );
      record = (await ActiveSessionProjector(store: store).projectSession(
        sessionAccount,
        start.localId,
        now: at.add(const Duration(minutes: 3)),
      ))!;
      expect(record.approvedAmountMinor, 125);
      expect(record.completionCommandLocalId, end.localId);
    },
  );
}

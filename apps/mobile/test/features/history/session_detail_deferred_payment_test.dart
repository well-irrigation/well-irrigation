import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/features/history/session_detail_screen.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/payment_receipt_dialog.dart';

class _Repo extends OperationsRepository {
  String status = 'unpaid';
  bool offline = false;
  int reads = 0;
  Completer<SessionDetailData>? waiting;
  @override
  Future<SessionDetailData> fetchSessionDetail(String id) async {
    reads++;
    if (waiting != null) return waiting!.future;
    if (offline) throw StateError('offline');
    final at = DateTime(2026, 10, 14, 9);
    return SessionDetailData(
      session: SessionHistoryItem(
        id: id,
        wellId: 'w',
        farmerName: 'مزارع',
        farmerCode: 'F1',
        farmerAccountId: 'farmer',
        farmName: 'أرض',
        pumpName: 'مضخة',
        operatorName: 'مشغل',
        startedAt: at,
        endedAt: at.add(const Duration(minutes: 2)),
        actualSeconds: 120,
        billableSeconds: 120,
        hasCharge: true,
        hasInvoice: false,
        totalAmountYER: 86,
        paidAmountYER: status == 'settled'
            ? 86
            : status == 'partial'
            ? 20
            : 0,
        paymentStatus: status,
      ),
      segments: const [],
    );
  }
}

class _Ack implements CommandTransport {
  final gate = Completer<DispatchResult>();
  @override
  Future<DispatchResult> dispatch(DispatchRequest request) => gate.future;
}

Future<void> _seed(
  OfflineSessionCoordinator c,
  InMemoryOutboxStore store,
) async {
  final at = DateTime.utc(2026, 10, 14);
  final start = await c.startSession(
    accountId: 'a',
    wellId: 'w',
    pumpId: 'p',
    farmId: 'f',
    farmerAccountId: 'farmer',
    energySource: 'solar',
    farmerName: 'مزارع',
    farmName: 'أرض',
    startedAt: at,
  );
  final end = await c.completeSession(
    accountId: 'a',
    sessionLocalId: start.localId,
    completedAt: at.add(const Duration(minutes: 2)),
  );
  await store.putMapping(
    'a',
    IdMapping(
      localId: start.localId,
      kind: EntityKind.session,
      serverId: 'server',
      resolvedAt: at,
    ),
  );
  await store.putMapping(
    'a',
    IdMapping(
      localId: end.localId,
      kind: EntityKind.sessionCharge,
      serverId: 'charge',
      resolvedAt: at,
    ),
  );
  await store.markConfirmed(
    'a',
    start.localId,
    serverResponse: {'session_id': 'server'},
    attemptedAt: at,
  );
  await store.markConfirmed(
    'a',
    end.localId,
    serverResponse: {'session_charge_id': 'charge', 'amount_minor': 86},
    attemptedAt: at,
  );
}

Widget _screen(OfflineSessionCoordinator c, _Repo repo, {Key? key}) =>
    MaterialApp(
      home: SessionDetailScreen(
        key: key,
        sessionId: 'server',
        wellName: 'بئر',
        accountId: 'a',
        wellId: 'w',
        coordinator: c,
        repository: repo,
      ),
    );
Future<void> _save(WidgetTester t) async {
  await t.tap(find.text('تسجيل دفعة'));
  await t.pumpAndSettle();
  expect(find.byType(PaymentReceiptDialog), findsOneWidget);
  expect(
    t
        .widget<PaymentReceiptDialog>(find.byType(PaymentReceiptDialog))
        .totalAmountYER,
    86,
  );
  await t.ensureVisible(find.text('حفظ طلب الدفعة'));
  await t.tap(find.text('حفظ طلب الدفعة'));
  await t.pumpAndSettle();
}

void main() {
  void viewport(WidgetTester t) {
    t.view.physicalSize = const Size(720, 1600);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
  }

  for (final status in ['unpaid', 'partial', 'settled']) {
    testWidgets('$status payment eligibility and cancellation', (t) async {
      viewport(t);
      final store = InMemoryOutboxStore();
      final c = OfflineSessionCoordinator(store: store);
      addTearDown(c.dispose);
      await _seed(c, store);
      final repo = _Repo()..status = status;
      await t.pumpWidget(_screen(c, repo));
      await t.pumpAndSettle();
      expect(
        find.text('تسجيل دفعة'),
        status == 'settled' ? findsNothing : findsOneWidget,
      );
      expect(find.text('لا توجد فاتورة مسجلة'), findsOneWidget);
      if (status != 'settled') {
        await t.tap(find.text('تسجيل دفعة'));
        await t.pumpAndSettle();
        expect(find.byType(PaymentReceiptDialog), findsOneWidget);
        await t.tapAt(const Offset(5, 5));
        await t.pumpAndSettle();
      }
      expect(
        (await store.allCommands('a'))
            .where((c) => c.type == CommandType.recordPayment),
        isEmpty,
      );
      c.dispose();
    });
  }
  testWidgets(
    'offline pending survives rebuild and coordinator recreation without another event',
    (t) async {
      viewport(t);
      final store = InMemoryOutboxStore();
      var c = OfflineSessionCoordinator(store: store);
      await _seed(c, store);
      final repo = _Repo();
      await t.pumpWidget(_screen(c, repo));
      await t.pumpAndSettle();
      repo.offline = true;
      await _save(t);
      expect(find.text('دفعة معلقة — بانتظار المزامنة'), findsOneWidget);
      expect(find.text('تسجيل دفعة'), findsNothing);
      expect(find.text('وفق قراءة الخادم'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);

      for (final text in ['خالص', 'تم السداد', 'تم إصدار سند', 'INV-']) {
        expect(find.textContaining(text), findsNothing);
      }
      await t.pumpWidget(_screen(c, repo));
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
      c.dispose();
      c = OfflineSessionCoordinator(store: store);
      addTearDown(c.dispose);
      repo.waiting = Completer<SessionDetailData>();
      await t.pumpWidget(_screen(c, repo, key: const ValueKey('recreated')));
      await t.pump();
      await t.pump();
      expect(find.text('دفعة معلقة — بانتظار المزامنة'), findsOneWidget);
      expect(find.text('تسجيل دفعة'), findsNothing);
      expect(
        (await store.allCommands('a'))
            .where((c) => c.type == CommandType.recordPayment),
        hasLength(1),
      );
      c.dispose();
    },
  );
  testWidgets('review is restored before any network response', (t) async {
    viewport(t);
    final store = InMemoryOutboxStore();
    final c = OfflineSessionCoordinator(store: store);
    addTearDown(c.dispose);
    await _seed(c, store);
    final state = (await c.restoreCompletedSession(
      accountId: 'a',
      wellId: 'w',
      serverSessionId: 'server',
    ))!;
    final p = await c.recordPayment(
      accountId: 'a',
      wellId: 'w',
      farmerAccountId: 'farmer',
      amountMinor: 86,
      paymentMethod: 'cash',
      sessionLocalId: state.record.localId,
      sessionCompletionLocalId: state.record.completionCommandLocalId,
    );
    await store.markNeedsReview(
      'a',
      p.localId,
      error: 'conflict',
      attemptedAt: DateTime.utc(2026, 10, 14),
    );
    final repo = _Repo()..waiting = Completer<SessionDetailData>();
    await t.pumpWidget(_screen(c, repo));
    await t.pump();
    await t.pump();
    expect(find.text('دفعة تحتاج مراجعة'), findsOneWidget);
    expect(find.text('تسجيل دفعة'), findsNothing);
    c.dispose();
  });
  testWidgets(
    'ACK alone exposes canonical receipt and triggers one canonical read, without polling',
    (t) async {
      viewport(t);
      final store = InMemoryOutboxStore();
      final seed = OfflineSessionCoordinator(store: store);
      await _seed(seed, store);
      seed.dispose();
      final ack = _Ack();
      final c = OfflineSessionCoordinator(store: store, commandTransport: ack);
      addTearDown(c.dispose);
      final repo = _Repo();
      await t.pumpWidget(_screen(c, repo));
      await t.pumpAndSettle();
      await _save(t);
      expect(find.textContaining('PMT-REAL'), findsNothing);
      expect(find.text('دفعة معلقة — بانتظار المزامنة'), findsOneWidget);
      repo.status = 'settled';
      ack.gate.complete(
        const DispatchAccepted(
          entityId: 'p-server',
          response: {
            'payment_id': 'p-server',
            'settled_minor': 86,
            'receipt': {'public_code': 'PMT-REAL'},
          },
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('خالص بالكامل ✅'), findsOneWidget);
      expect(find.textContaining('PMT-REAL'), findsOneWidget);
      expect(find.text('تسجيل دفعة'), findsNothing);
      expect(find.text('لا توجد فاتورة مسجلة'), findsOneWidget);
      final reads = repo.reads;
      await t.pump(const Duration(seconds: 3));
      expect(repo.reads, reads);
      c.dispose();
    },
  );
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/operational_start_recovery.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/start_recovery_policy.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import '../../core/session/legacy_start_retirement_test.dart'
    show CurrentRepository;
import '../../core/session/operational_start_guided_recovery_test.dart'
    show GuidedReceiptTransport, startTime;
import 'operational_start_guided_recovery_test.dart' show openGuided;

void main() {
  late InMemoryOutboxStore store;
  late CurrentRepository repo;
  late GuidedReceiptTransport transport;
  late OperationalStartRecovery recovery;
  int refresh = 0;
  setUp(() async {
    store = InMemoryOutboxStore();
    await store.initialize();
    await store.insert(
      CommandEnvelope(
        localId: 'old',
        commandId: 'original',
        type: CommandType.startIrrigationSession,
        accountId: 'account',
        wellId: 'well',
        sequence: 1,
        occurredAt: startTime,
        createdLocalAt: startTime,
        payload: {'p_well_id': 'well'},
        status: CommandStatus.review,
      ),
    );
    repo = CurrentRepository();
    transport = GuidedReceiptTransport();
    refresh = 0;
    recovery = OperationalStartRecovery(
      store: store,
      transport: transport,
      repository: repo,
      currentAccountId: () => 'account',
    );
  });
  tearDown(() async => store.close());
  Future<void> open(WidgetTester t) => openGuided(
    t,
    recovery,
    'old',
    onResolved: () async {
      refresh++;
    },
  );
  testWidgets(
    'single repair action; opening never reads server or sends command',
    (t) async {
      await open(t);
      expect(find.text('إصلاح الحالة'), findsNWidgets(2));
      expect(find.text('التحقق من حالة الجلسة'), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(repo.currentReads, 0);
      expect(transport.requests, isEmpty);
      expect(transport.reads, 0);
    },
  );
  testWidgets('repair no-active succeeds once despite double tap', (t) async {
    await open(t);
    final button = find.widgetWithText(TextButton, 'إصلاح الحالة');
    await t.tap(button);
    await t.tap(button);
    await t.pumpAndSettle();
    expect(find.text('تم إصلاح الحالة. يمكنك بدء جلسة جديدة.'), findsOneWidget);
    expect(repo.currentReads, 1);
    expect(refresh, 1);
    expect(transport.requests, isEmpty);
    expect(
      (await store.readStartRecovery('account')).policy.root('old'),
      StartRecoveryDisposition.legacyRetired,
    );
  });
  testWidgets(
    'current session success describes independent current restoration',
    (t) async {
      repo.hasActive = true;
      await open(t);
      await t.tap(find.widgetWithText(TextButton, 'إصلاح الحالة'));
      await t.pumpAndSettle();
      expect(
        find.text('تم استعادة الجلسة الحالية ويمكنك متابعة التشغيل.'),
        findsOneWidget,
      );
      expect(refresh, 1);
      expect(transport.reads, 0);
    },
  );
  testWidgets('offline keeps evidence and retry is a fresh current read', (
    t,
  ) async {
    repo.fail = true;
    await open(t);
    await t.tap(find.widgetWithText(TextButton, 'إصلاح الحالة'));
    await t.pumpAndSettle();
    expect(find.text('تعذر الاتصال بالخادم.'), findsOneWidget);
    expect(find.text('إعادة المحاولة'), findsOneWidget);
    expect(
      (await store.readStartRecovery('account'))
          .records[startRecoveryKey('old')],
      isNull,
    );
    repo.fail = false;
    await t.tap(find.text('إعادة المحاولة'));
    await t.pumpAndSettle();
    expect(refresh, 1);
    expect(repo.currentReads, 2);
    expect(transport.requests, isEmpty);
  });
  testWidgets(
    'back while checking prevents implicit retirement and late refresh',
    (t) async {
      repo.barrier = Completer<void>();
      await open(t);
      await t.tap(find.widgetWithText(TextButton, 'إصلاح الحالة'));
      await t.pump();
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      repo.barrier!.complete();
      await t.pumpAndSettle();
      expect(refresh, 0);
      expect(
        (await store.readStartRecovery('account'))
            .records[startRecoveryKey('old')],
        isNull,
      );
      expect(transport.requests, isEmpty);
    },
  );
}

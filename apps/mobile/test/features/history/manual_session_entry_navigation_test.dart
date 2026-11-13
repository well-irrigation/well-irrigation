import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/manual_session_entry.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/features/history/manual_session_entry_screen.dart';

import '../../core/sync/manual_session_entry_test.dart' as f;
import '../../support/identity_fixture.dart';
import 'manual_session_entry_ui_test.dart' as ui;

class ReadGateCoordinator extends OfflineSessionCoordinator {
  ReadGateCoordinator(InMemoryOutboxStore store) : super(store: store);
  final reads = <Completer<ManualSessionEntryObservation?>>[];
  ManualSessionEntryFollowUp? snapshot;
  @override
  bool get canSyncNow => false;
  @override
  Future<ManualSessionEntryObservation?> observeManualSessionEntry({
    required String accountId,
    required String wellId,
    required String localId,
  }) {
    final gate = Completer<ManualSessionEntryObservation?>();
    reads.add(gate);
    return gate.future;
  }

  @override
  Future<ManualSessionEntryFollowUp?> readManualSessionEntryFollowUp({
    required String accountId,
    required String wellId,
    required String localId,
  }) async => snapshot;
  void release(
    int index,
    ManualSessionEntryObservation observation,
    ManualSessionEntryFollowUp follow,
  ) {
    snapshot = follow;
    reads[index].complete(observation);
  }
}

class StackObserver extends NavigatorObserver {
  final popped = <String?>[];
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route.settings.name);
    super.didPop(route, previousRoute);
  }
}

void main() {
  late InMemoryOutboxStore store;
  late ReadGateCoordinator coordinator;
  late StackObserver observer;
  late CommandEnvelope command;
  late ManualSessionEntryObservation pending, accepted;
  late ManualSessionEntryFollowUp pendingSnapshot, acceptedSnapshot;
  late GlobalKey<NavigatorState> navigator;
  final outcomes = <ManualSessionEntryOutcome>[];
  Future<void> setup(bool completed) async {
    store = InMemoryOutboxStore();
    coordinator = ReadGateCoordinator(store);
    observer = StackObserver();
    navigator = GlobalKey<NavigatorState>();
    outcomes.clear();
    command = await f.enqueue(store, completed);
    final repo = OutboxRepository(store: store);
    pending = (await repo.observeManualSessionEntry(
      accountId: f.account,
      wellId: f.well,
      localId: command.localId,
    ))!;
    pendingSnapshot = (await repo.readManualSessionEntryFollowUp(
      accountId: f.account,
      wellId: f.well,
      localId: command.localId,
    ))!;
    await SyncEngine(
      store: store,
      transport: f.Transport()..response = f.accepted(command),
      clock: () => f.now,
    ).run(f.account);
    accepted = (await repo.observeManualSessionEntry(
      accountId: f.account,
      wellId: f.well,
      localId: command.localId,
    ))!;
    acceptedSnapshot = (await repo.readManualSessionEntryFollowUp(
      accountId: f.account,
      wellId: f.well,
      localId: command.localId,
    ))!;
  }

  Future<void> open(WidgetTester t) async {
    final repo = ui.EntryRepository();
    final cap = await repo.fetchManualSessionEntryCapability(
      accountId: f.account,
      wellId: f.well,
    );
    Widget historyPage(BuildContext context) => Scaffold(
      body: Column(
        children: [
          const Text('سجل الجلسات'),
          TextButton(
            child: const Text('افتح الطلب'),
            onPressed: () async {
              final result = await Navigator.of(context)
                  .push<ManualSessionEntryOutcome>(
                    MaterialPageRoute(
                      settings: const RouteSettings(name: 'follow-up'),
                      builder: (_) => ManualSessionEntryScreen(
                        identity: testIdentity(
                          accountId: f.account,
                          wells: [testWell(id: f.well)],
                        ),
                        repository: repo,
                        capability: cap,
                        coordinator: coordinator,
                        existingCommand: command,
                      ),
                    ),
                  );
              if (result != null) outcomes.add(result);
            },
          ),
        ],
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [observer],
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const Text('الشاشة قبل السجل'),
                TextButton(
                  child: const Text('افتح السجل'),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        settings: const RouteSettings(name: 'history'),
                        builder: historyPage,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('افتح السجل'));
    await t.pumpAndSettle();
    await t.tap(find.text('افتح الطلب'));
    await t.pumpAndSettle();
    expect(coordinator.reads, hasLength(1));
  }

  void check(
    String name,
    bool completed,
    Future<void> Function(WidgetTester) body,
  ) => testWidgets(name, (t) async {
    await setup(completed);
    try {
      await open(t);
      await body(t);
    } finally {
      coordinator.dispose();
      await t.pumpWidget(const SizedBox.shrink());
      await store.close();
    }
  });
  void historyRemains(WidgetTester t) {
    expect(observer.popped.where((x) => x == 'follow-up'), hasLength(1));
    expect(observer.popped.where((x) => x == 'history'), isEmpty);
    expect(find.text('سجل الجلسات'), findsOneWidget);
    expect(find.text('الشاشة قبل السجل'), findsNothing);
    expect(t.takeException(), isNull);
  }

  for (final completed in [true, false]) {
    check(
      '$completed late accepted during user back must not pop history',
      completed,
      (t) async {
        await t.tap(find.text('العودة للسجل'));
        await t.pump();
        expect(
          find.byType(ManualSessionEntryScreen, skipOffstage: false),
          findsOneWidget,
        ); // departure, not disposal
        coordinator.release(0, accepted, acceptedSnapshot);
        await t.pumpAndSettle();
        historyRemains(t);
        expect(outcomes, isEmpty);
      },
    );
    check(
      '$completed system back revokes late accepted navigation',
      completed,
      (t) async {
        await t.binding.handlePopRoute();
        await t.pump();
        coordinator.release(0, accepted, acceptedSnapshot);
        await t.pumpAndSettle();
        historyRemains(t);
        expect(outcomes, isEmpty);
      },
    );
    check('$completed newest refresh wins over old accepted read', completed, (
      t,
    ) async {
      await t.tap(find.text('تحديث الحالة'));
      await t.pump();
      expect(coordinator.reads, hasLength(2));
      coordinator.release(1, pending, pendingSnapshot);
      await t.pumpAndSettle();
      coordinator.release(0, accepted, acceptedSnapshot);
      await t.pumpAndSettle();
      expect(observer.popped, isEmpty);
      expect(find.byType(ManualSessionEntryScreen), findsOneWidget);
      expect(
        find.text(
          'تم حفظ الجلسة على الجهاز، وسيتم إكمال إضافتها عند توفر الاتصال.',
        ),
        findsOneWidget,
      );
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'تحديث الحالة'),
            )
            .onPressed,
        isNotNull,
      );
    });
    check('$completed two accepted reads navigate once', completed, (t) async {
      await t.tap(find.text('تحديث الحالة'));
      await t.pump();
      coordinator.release(1, accepted, acceptedSnapshot);
      await t.pump();
      coordinator.release(0, accepted, acceptedSnapshot);
      await t.pumpAndSettle();
      historyRemains(t);
      expect(outcomes, hasLength(1));
      expect(outcomes.single.isOpen, !completed);
    });
    check(
      '$completed in-flight refresh cannot navigate after departure',
      completed,
      (t) async {
        coordinator.release(0, pending, pendingSnapshot);
        await t.pumpAndSettle();
        await t.tap(find.text('تحديث الحالة'));
        await t.pump();
        await t.tap(find.text('العودة للسجل'));
        await t.pump();
        coordinator.release(1, accepted, acceptedSnapshot);
        await t.pumpAndSettle();
        historyRemains(t);
        expect(outcomes, isEmpty);
      },
    );
  }
  check('late stale error does not replace newer result', true, (t) async {
    await t.tap(find.text('تحديث الحالة'));
    await t.pump();
    coordinator.release(1, pending, pendingSnapshot);
    await t.pumpAndSettle();
    coordinator.reads[0].completeError(StateError('private RPC failure'));
    await t.pumpAndSettle();
    expect(
      find.text(
        'تم حفظ الجلسة على الجهاز، وسيتم إكمال إضافتها عند توفر الاتصال.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('تعذر إكمال'), findsNothing);
    expect(observer.popped, isEmpty);
  });
  check('departed read error has no visible effect on history', true, (
    t,
  ) async {
    await t.tap(find.text('العودة للسجل'));
    await t.pump();
    coordinator.reads[0].completeError(
      StateError('private error after departure'),
    );
    await t.pumpAndSettle();
    historyRemains(t);
    expect(find.textContaining('تعذر إكمال'), findsNothing);
  });
  check(
    'covered in-flight refresh releases loading for the owning page',
    false,
    (t) async {
      coordinator.release(0, pending, pendingSnapshot);
      await t.pumpAndSettle();
      await t.tap(find.text('تحديث الحالة'));
      await t.pump();
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'cover'),
          builder: (_) => const Scaffold(body: Text('شاشة أخرى')),
        ),
      );
      await t.pumpAndSettle();
      coordinator.release(1, accepted, acceptedSnapshot);
      await t.pumpAndSettle();
      expect(find.text('شاشة أخرى'), findsOneWidget);
      expect(observer.popped, isEmpty);
      navigator.currentState!.pop();
      await t.pumpAndSettle();
      expect(
        t
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'تحديث الحالة'),
            )
            .onPressed,
        isNotNull,
      );
      await t.tap(find.text('تحديث الحالة'));
      await t.pump();
      coordinator.release(2, accepted, acceptedSnapshot);
      await t.pumpAndSettle();
      expect(find.text('سجل الجلسات'), findsOneWidget);
      expect(observer.popped.where((r) => r == 'history'), isEmpty);
      expect(observer.popped.where((r) => r == 'follow-up'), hasLength(1));
    },
  );
  check('covered route cannot pop a different current route', false, (t) async {
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'cover'),
        builder: (_) => const Scaffold(body: Text('شاشة أخرى')),
      ),
    );
    await t.pumpAndSettle();
    coordinator.release(0, accepted, acceptedSnapshot);
    await t.pumpAndSettle();
    expect(find.text('شاشة أخرى'), findsOneWidget);
    expect(observer.popped, isEmpty);
    navigator.currentState!.pop();
    await t.pumpAndSettle();
    await t.tap(find.text('تحديث الحالة'));
    await t.pump();
    coordinator.release(1, accepted, acceptedSnapshot);
    await t.pumpAndSettle();
    expect(observer.popped.where((x) => x == 'follow-up'), hasLength(1));
    expect(observer.popped.where((x) => x == 'history'), isEmpty);
    expect(find.text('سجل الجلسات'), findsOneWidget);
  });
}

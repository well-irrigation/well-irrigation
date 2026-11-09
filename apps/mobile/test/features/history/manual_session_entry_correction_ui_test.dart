import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/manual_session_entry.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/features/history/manual_session_entry_screen.dart';
import 'package:well_irrigation_mobile/features/history/session_history_screen.dart';

import '../../core/sync/manual_session_entry_test.dart' as f;
import '../../support/identity_fixture.dart';
import 'manual_session_entry_ui_test.dart' as ui;

String stamp(DateTime time) {
  final v = time.toLocal();
  return '${v.year}/${v.month}/${v.day}  ${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}';
}

void main() {
  late InMemoryOutboxStore store;
  late OutboxRepository outbox;
  late OfflineSessionCoordinator coordinator;
  late ui.EntryRepository repo;
  setUp(() {
    store = InMemoryOutboxStore();
    outbox = OutboxRepository(store: store);
    coordinator = OfflineSessionCoordinator(store: store);
    repo = ui.EntryRepository();
  });
  void check(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (t) async {
        try {
          await body(t);
        } finally {
          coordinator.dispose();
          await t.pumpWidget(const SizedBox.shrink());
        }
      });
  Future<CommandEnvelope> seed(
    bool completed,
    String state, {
    int hours = 0,
  }) async {
    final facts = ManualSessionEntryFacts(
      wellId: f.well,
      farmerWellAccountId: f.farmer,
      farmId: f.farm,
      pumpId: f.pump,
      startedAt: f.start.add(Duration(hours: hours)),
      endedAt: completed ? f.end.add(Duration(hours: hours)) : null,
      energySource: 'solar',
      reason: 'سبب محفوظ $hours',
      notes: 'ملاحظات أصلية',
    );
    final c = await outbox.prepareManualSessionEntry(
      accountId: f.account,
      facts: facts,
    );
    await outbox.saveManualSessionEntry(c);
    if (state == 'pending') return c;
    final transport = ui.UiTransport()..outcome = state;
    await SyncEngine(store: store, transport: transport).run(f.account);
    return c;
  }

  Future<void> open(WidgetTester t, CommandEnvelope c) async {
    final cap = await repo.fetchManualSessionEntryCapability(
      accountId: f.account,
      wellId: f.well,
    );
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ManualSessionEntryScreen(
                    identity: testIdentity(
                      accountId: f.account,
                      wells: [testWell(id: f.well)],
                    ),
                    capability: cap,
                    repository: repo,
                    coordinator: coordinator,
                    existingCommand: c,
                  ),
                ),
              ),
              child: const Text('فتح'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('فتح'));
    await t.pumpAndSettle();
  }

  Future<void> history(WidgetTester t, {double scale = 1}) async {
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: SessionHistoryScreen(
          identity: testIdentity(
            accountId: f.account,
            wells: [testWell(id: f.well)],
          ),
          repository: repo,
          coordinator: coordinator,
          manualOutbox: outbox,
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> save(WidgetTester t) async {
    final button = find.widgetWithText(FilledButton, 'حفظ الجلسة');
    await ui.reveal(t, button);
    await t.pumpAndSettle();
    await t.tap(button);
    await t.pumpAndSettle();
  }

  check('two completed requests keep explicit selection and original summary', (
    t,
  ) async {
    final a = await seed(true, 'pending'),
        b = await seed(true, 'pending', hours: 3);
    await history(t);
    expect(find.textContaining(stamp(f.start)), findsOneWidget);
    expect(
      find.textContaining(stamp(f.start.add(const Duration(hours: 3)))),
      findsOneWidget,
    );
    for (final c in [a, b]) {
      final card = find.byKey(ValueKey('manual-request-${c.localId}'));
      await ui.reveal(t, card);
      await t.tap(
        find.descendant(of: card, matching: find.text('متابعة الطلب')),
      );
      await t.pumpAndSettle();
      final summary = find.byKey(const ValueKey('manual-follow-up-summary'));
      expect(
        find.descendant(
          of: summary,
          matching: find.textContaining(stamp(c.occurredAt)),
        ),
        findsOneWidget,
      );
      expect(find.textContaining(c.commandId), findsNothing);
      await t.tap(find.text('العودة للسجل'));
      await t.pumpAndSettle();
    }
  });
  check('multiple request chooser fits a small screen with scaled Arabic', (
    t,
  ) async {
    t.view.physicalSize = const Size(320, 568);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await seed(true, 'pending');
    await seed(false, 'pending', hours: 3);
    await history(t, scale: 1.5);
    await t.tap(find.text('إضافة جلسة سقي سابقة'));
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  check('dialog follows chosen older request instead of newest', (t) async {
    final a = await seed(true, 'pending');
    await seed(true, 'pending', hours: 3);
    await history(t);
    await t.tap(find.text('إضافة جلسة سقي سابقة'));
    await t.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    final summary = find.descendant(
      of: dialog,
      matching: find.textContaining(stamp(f.start)),
    );
    expect(summary, findsOneWidget);
    final item = find.byKey(ValueKey('manual-dialog-request-${a.localId}'));
    await t.ensureVisible(item);
    await t.pumpAndSettle();
    await t.tap(
      find.descendant(of: item, matching: find.text('متابعة الطلب المحفوظ')),
    );
    await t.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('manual-follow-up-summary')),
        matching: find.textContaining(stamp(a.occurredAt)),
      ),
      findsOneWidget,
    );
  });
  check('original and corrected offline requests remain separate in history', (
    t,
  ) async {
    final c = await seed(true, 'validation_error');
    await history(t);
    await t.ensureVisible(find.widgetWithText(TextButton, 'متابعة الطلب'));
    await t.pumpAndSettle();
    await t.tap(find.text('متابعة الطلب'));
    await t.pumpAndSettle();
    await t.tap(find.text('تصحيح البيانات'));
    await t.pumpAndSettle();
    await ui.reveal(t, find.byKey(const ValueKey('reason')));
    await t.enterText(find.byKey(const ValueKey('reason')), 'تصحيح السبب');
    await save(t);
    await t.tap(find.text('حفظ الطلب المصحح'));
    await t.pumpAndSettle();
    await t.tap(find.text('العودة للسجل'));
    await t.pumpAndSettle();
    expect(find.byType(ManualSessionEntryScreen), findsNothing);
    expect(find.text('السبب: سبب محفوظ 0'), findsOneWidget);
    expect(find.text('السبب: تصحيح السبب'), findsOneWidget);
    expect(find.text('لم تتم الإضافة'), findsOneWidget);
    final all = await store.allCommands(f.account);
    expect(all, hasLength(2));
    expect(
      all.singleWhere((x) => x.localId == c.localId).status,
      CommandStatus.review,
    );
  });
  check('capability revoked during confirmation creates no intent', (t) async {
    final c = await seed(false, 'validation_error');
    await open(t, c);
    await t.tap(find.text('تصحيح البيانات'));
    await t.pumpAndSettle();
    await save(t);
    repo.active = false;
    await t.tap(find.text('حفظ الطلب المصحح'));
    await t.pumpAndSettle();
    expect(await store.allCommands(f.account), hasLength(1));
    expect(find.textContaining('لا تتوفر').hitTestable(), findsOneWidget);
  });
  check('completed and active summaries are different without IDs', (t) async {
    final a = await seed(true, 'pending'),
        b = await seed(false, 'pending', hours: 3);
    await history(t);
    expect(find.text('جلسة منتهية'), findsOneWidget);
    expect(find.text('جلسة ما زالت جارية'), findsOneWidget);
    expect(find.textContaining(a.localId), findsNothing);
    expect(find.textContaining(b.commandId), findsNothing);
  });
  for (final completed in [true, false]) {
    for (final state in [
      'validation_error',
      'conflict_overlap',
      'conflict_active_resource',
    ]) {
      check('$completed $state eligible correction visible', (t) async {
        final c = await seed(completed, state);
        await open(t, c);
        expect(find.text('تصحيح البيانات'), findsOneWidget);
      });
    }
    check(
      '$completed prefill corrected offline intent preserves original and double confirmation',
      (t) async {
        final c = await seed(completed, 'validation_error');
        final original = (await store.commandByLocalId(f.account, c.localId))!;
        await open(t, c);
        await t.tap(find.text('تصحيح البيانات'));
        await t.pumpAndSettle();
        expect(
          find.text(completed ? 'جلسة ما زالت جارية' : 'جلسة منتهية'),
          findsNothing,
        );
        expect(
          t
              .widget<DropdownButtonFormField>(
                find.byKey(const ValueKey('farmer')),
              )
              .initialValue,
          isNotNull,
        );
        expect(
          t
              .widget<DropdownButtonFormField>(
                find.byKey(const ValueKey('pump')),
              )
              .initialValue,
          isNotNull,
        );
        expect(find.text(stamp(f.start)), findsOneWidget);
        if (completed) expect(find.text(stamp(f.end)), findsOneWidget);
        await ui.reveal(t, find.byKey(const ValueKey('reason')));
        expect(find.text('سبب محفوظ 0'), findsOneWidget);
        await t.enterText(find.byKey(const ValueKey('reason')), 'سبب مصحح');
        await ui.reveal(t, find.byKey(const ValueKey('notes')));
        expect(find.text('ملاحظات أصلية'), findsOneWidget);
        await save(t);
        expect(await store.allCommands(f.account), hasLength(1));
        expect(find.text('حفظ الطلب المصحح'), findsOneWidget);
        final confirmationPoint = t.getCenter(find.text('حفظ الطلب المصحح'));
        await t.tapAt(confirmationPoint);
        await t.tapAt(confirmationPoint);
        await t.pumpAndSettle();
        final all = await store.allCommands(f.account);
        expect(all, hasLength(2));
        final next = all.singleWhere((x) => x.localId != c.localId);
        expect(next.commandId, isNot(c.commandId));
        expect(next.type, c.type);
        final payload = next.payload['p_request'] as Map;
        expect(payload['reason'], 'سبب مصحح');
        expect(payload['notes'], 'ملاحظات أصلية');
        expect(
          payload['started_at'],
          (c.payload['p_request'] as Map)['started_at'],
        );
        expect(
          payload.keys,
          unorderedEquals(((c.payload['p_request'] as Map).keys)),
        );
        final old = (await store.commandByLocalId(f.account, c.localId))!;
        expect(old.payload, original.payload);
        expect(old.serverResponse, original.serverResponse);
        expect(old.status, original.status);
        expect(
          find.text(
            'تم حفظ الجلسة على الجهاز، وسيتم إكمال إضافتها عند توفر الاتصال.',
          ),
          findsOneWidget,
        );
      },
    );
  }
  for (final state in [
    'pending',
    'ambiguous',
    'processing',
    'needs_review',
    'unresolved',
    'not_found',
    'accepted',
  ]) {
    check('$state cannot offer correction', (t) async {
      final c = await seed(false, state);
      await open(t, c);
      expect(find.text('تصحيح البيانات'), findsNothing);
    });
  }
  for (final state in [
    'request_changed',
    'unknown',
    'accepted_closed',
    'accepted_completed',
  ]) {
    check('$state stays follow-up only', (t) async {
      final completed = state == 'accepted_closed';
      final c = await seed(
        completed,
        state.startsWith('accepted') ? 'accepted' : 'validation_error',
      );
      if (state == 'request_changed' || state == 'unknown') {
        final old = (await store.commandByLocalId(f.account, c.localId))!;
        await store.markNeedsReview(
          f.account,
          c.localId,
          error: 'test-domain-evidence',
          attemptedAt: f.now,
          serverResponse: {
            ...old.serverResponse!,
            if (state == 'request_changed') 'reason': 'request_changed',
            if (state == 'unknown') 'status': 'future_state',
          },
        );
      }
      if (state == 'accepted_completed') {
        final done = await outbox.enqueue(
          accountId: f.account,
          wellId: f.well,
          type: CommandType.completeIrrigationSession,
          aggregateLocalId: c.localId,
          occurredAt: f.now,
          payload: {'p_session_id': f.session},
        );
        await store.markConfirmed(
          f.account,
          done.localId,
          serverResponse: {'status': 'closed'},
          attemptedAt: f.now,
        );
      }
      await open(t, c);
      expect(find.text('تصحيح البيانات'), findsNothing);
    });
  }
  for (final unavailable in [false, true]) {
    check('permission changes while corrected form is open $unavailable', (
      t,
    ) async {
      final c = await seed(true, 'validation_error');
      await open(t, c);
      await t.tap(find.text('تصحيح البيانات'));
      await t.pumpAndSettle();
      if (unavailable) {
        repo.failCapability = true;
      } else {
        repo.completed = false;
      }
      await save(t);
      expect(find.text('حفظ الطلب المصحح'), findsNothing);
      expect(await store.allCommands(f.account), hasLength(1));
      expect(
        find
            .textContaining(unavailable ? 'تعذر التحقق' : 'لا تتوفر')
            .hitTestable(),
        findsOneWidget,
      );
      await t.drag(find.byType(ListView).last, const Offset(0, 1800));
      await t.pumpAndSettle();
      expect(
        find.textContaining(unavailable ? 'تعذر التحقق' : 'لا تتوفر'),
        findsOneWidget,
      );
    });
  }
  check('cancel correction confirmation creates no new intent', (t) async {
    final c = await seed(true, 'validation_error');
    await open(t, c);
    await t.tap(find.text('تصحيح البيانات'));
    await t.pumpAndSettle();
    await save(t);
    await t.tap(find.text('إلغاء'));
    await t.pumpAndSettle();
    expect(await store.allCommands(f.account), hasLength(1));
    expect(find.text('حفظ الجلسة'), findsOneWidget);
  });
  check('binding contradiction cannot offer correction', (t) async {
    final c = await seed(false, 'validation_error');
    await store.putMapping(
      f.account,
      IdMapping(
        localId: c.localId,
        kind: EntityKind.session,
        serverId: f.session,
        resolvedAt: f.now,
      ),
    );
    await open(t, c);
    expect(find.text('تصحيح البيانات'), findsNothing);
  });
  for (final unavailable in [false, true]) {
    check(
      'current capability ${unavailable ? 'unavailable' : 'denied'} blocks corrected intent',
      (t) async {
        final c = await seed(true, 'validation_error');
        await open(t, c);
        if (unavailable) {
          repo.failCapability = true;
        } else {
          repo.completed = false;
        }
        await t.tap(find.text('تصحيح البيانات'));
        await t.pumpAndSettle();
        expect(find.text('حفظ الجلسة'), findsNothing);
        expect(await store.allCommands(f.account), hasLength(1));
        expect(
          find.textContaining(unavailable ? 'تعذر التحقق' : 'لا تتوفر'),
          findsOneWidget,
        );
      },
    );
  }
}

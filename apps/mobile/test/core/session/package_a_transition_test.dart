@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/session/time_integrity.dart';
import 'package:well_irrigation_mobile/core/sync/command_reference.dart';

import 'local_booking_transition_regression_test.dart' as f;
import '../sync/package_a_outbox_test.dart' as sync_fixture;

import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqliteOutboxStore store;
  late BookingLocalLedger ledger;
  late OfflineSessionCoordinator coordinator;
  late f.FieldClock clock;
  var scheduled = 0;
  Future<void> open() async {
    store = SqliteOutboxStore(
      databasePath: '${dir.path}/outbox.db',
      sqfliteFactory: databaseFactoryFfi,
    );
    await store.initialize();
    ledger = BookingLocalLedger(store);
    coordinator = OfflineSessionCoordinator(
      store: store,
      bookingLedger: ledger,
      timeIntegritySource: clock,
      commandQueuedScheduler: (_) async {
        scheduled++;
        return true;
      },
    );
    await ledger.importServerSession(
      accountId: 'account',
      wellId: 'well',
      sessionId: 'server-A',
      bookingId: 'A',
      startedAt: f.at(43),
    );
  }

  Future<LocalBookingTransitionResult> run({
    bool due = true,
    bool callback = true,
    BookingAutomationState? state,
    bool Function()? isCurrent,
    WellDaySchedule? schedule,
  }) async {
    if (due) clock.now = f.at(47);
    return coordinator.runPhoneOwnedDueBookingTransition(
      accountId: 'account',
      wellId: 'well',
      cachedSchedule: f.cached(schedule ?? f.fieldSchedule()),
      automation: state ?? f.automation(),
      commandId: 'caller-command',
      localSessionId: 'caller-local',
      scheduledCallback: callback,
      isCurrent: isCurrent,
    );
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('package-a-');
    clock = f.FieldClock();
    scheduled = 0;
    await open();
  });
  tearDown(() async {
    coordinator.dispose();
    await store.close();
    await dir.delete(recursive: true);
  });
  test('offline atomic transition makes B live with stable IDs across ticks and restart', () async {
    final result = await run();
    expect(result.reason, 'phone_owned_live_transition');
    final rows = await store.allCommands('account');
    expect(rows.map((c) => c.type), [
      CommandType.completeIrrigationSession,
      CommandType.startBookingSession,
    ]);
    expect(rows[0].occurredAt, f.at(47));
    expect(rows[1].occurredAt, f.at(47));
    expect(rows[1].prerequisites, [rows[0].localId]);
    expect(rows.every((c) => c.status == CommandStatus.pending), isTrue);
    expect(coordinator.currentActiveSession?.localId, rows[1].localId);
    expect(coordinator.currentActiveSession?.serverSessionId, isNull);
    expect(coordinator.currentActiveSession?.farmReference, 'farm');
    expect(await ledger.loadProvisionalSessions('account', 'well'), isEmpty);
    await run();
    expect(await store.allCommands('account'), hasLength(2));
    expect(scheduled, 1);
    final ids = rows.map((c) => c.commandId).toList();
    coordinator.dispose();
    await store.close();
    await open();
    expect(
      (await run()).outcome,
      LocalBookingTransitionOutcome.alreadyRecorded,
    );
    expect((await store.allCommands('account')).map((c) => c.commandId), ids);
    expect(coordinator.currentActiveSession?.startedAt, f.at(47));
  });
  test(
    'B has all normal offline controls and remains the only active session',
    () async {
      await run();
      final id = coordinator.currentActiveSession!.localId;
      await coordinator.pauseSession(
        accountId: 'account',
        sessionLocalId: id,
        reason: 'operator_pause',
        pausedAt: f.at(48),
      );
      await coordinator.resumeSession(
        accountId: 'account',
        sessionLocalId: id,
        resumedAt: f.at(49),
      );
      await coordinator.changeEnergySource(
        accountId: 'account',
        sessionLocalId: id,
        newEnergySource: 'farmer_diesel',
        changedAt: f.at(50),
      );
      expect(
        coordinator.currentActiveSession?.currentEnergySource,
        'farmer_diesel',
      );
      await coordinator.completeSession(
        accountId: 'account',
        sessionLocalId: id,
        completedAt: f.at(51),
      );
      expect(coordinator.currentActiveSession, isNull);
      expect(await store.allCommands('account'), hasLength(6));
    },
  );
  test('missed callback creates no outbox commands and no B', () async {
    expect(
      (await run(callback: false)).outcome,
      LocalBookingTransitionOutcome.missedRequiresReview,
    );
    expect(await store.allCommands('account'), isEmpty);
    expect(coordinator.currentActiveSession, isNull);
  });
  test('auto off creates no bundle', () async {
    final off = BookingAutomationState(
      wellId: 'well',
      enabled: false,
      revision: 1,
      settingsRowExists: true,
      firstSession: 'manual',
    );
    expect((await run(state: off)).transitioned, isFalse);
    expect(await store.allCommands('account'), isEmpty);
  });
  test(
    'invalidation inside durable commit rolls back both commands and ledger',
    () async {
      var checks = 0;
      final result = await run(isCurrent: () => ++checks < 3);
      expect(result.transitioned, isFalse);
      expect(await store.allCommands('account'), isEmpty);
      expect(coordinator.currentActiveSession, isNull);
      expect((await run()).transitioned, isTrue);
    },
  );
  test('legacy provisional evidence stays legacy and is never reinterpreted as real B', () async {
    final intent = BookingTransitionIntent(
      wellId: 'well',
      transitionKey: resultKey(),
      commandId: 'legacy-command',
      chainId: 'chain',
      currentSessionId: 'server-A',
      nextBookingId: 'B',
      decisionRevision: 0,
      automationRevision: 1,
      state: BookingIntentState.awaitingReconciliation,
    );
    await ledger.recordOperationalTransition(
      accountId: 'account',
      intent: intent,
      localSessionId: 'legacy-local',
      occurredAt: f.at(47),
    );
    final result = await run();
    expect(result.transitioned, isFalse);
    expect(result.reason, 'legacy_provisional_requires_review');
    final legacy = (await ledger.loadProvisionalSessions(
      'account',
      'well',
    )).single;
    expect(legacy.provenance, 'local_offline_provisional');
    expect(legacy.commandId, 'legacy-command');
    expect(await store.allCommands('account'), isEmpty);
  });
  test('local outbox A completion references its real start root and only B remains active', () async {
    final a = await coordinator.startSession(
      accountId: 'account',
      wellId: 'well',
      pumpId: 'pump',
      farmId: 'farm',
      farmerAccountId: 'farmer',
      energySource: 'well_diesel',
      startedAt: f.at(43),
    );
    final base = f.fieldSchedule();
    final schedule = copySchedule(
      base,
      CurrentBookingSession(
        sessionId: a.localId,
        status: 'open',
        startedAt: f.at(43),
        wellId: 'well',
        bookingId: 'A',
      ),
    );
    expect((await run(schedule: schedule)).transitioned, isTrue);
    final rows = await store.allCommands('account');
    expect(
      rows[1].payload['p_session_id'],
      CommandReference(localId: a.localId, kind: EntityKind.session).toJson(),
    );
    expect(rows[1].aggregateLocalId, a.localId);
    expect(coordinator.currentActiveSession?.bookingId, 'B');
    expect(
      (await coordinator.unresolvedSessions('account'))
          .where((s) => s.businessState.isActive),
      hasLength(1),
    );
  });
  test('idle well cannot automatically start first booking', () async {
    expect(
      (await run(schedule: copySchedule(f.fieldSchedule(), null))).transitioned,
      isFalse,
    );
    expect(await store.allCommands('account'), isEmpty);
  });
  for (final mode in [
    'no_anchor',
    'reboot',
    'wall_jump',
    'monotonic_backwards',
  ]) {
    test('invalid time $mode cannot authorize transition', () async {
      coordinator.dispose();
      coordinator = OfflineSessionCoordinator(
        store: store,
        bookingLedger: ledger,
        timeIntegritySource: FixedTimeSource(mode),
      );
      final base = f.cached(f.fieldSchedule());
      final result = await coordinator.runPhoneOwnedDueBookingTransition(
        accountId: 'account',
        wellId: 'well',
        cachedSchedule: mode == 'no_anchor'
            ? CachedBookingSchedule(base.schedule, base.fetchedAt)
            : base,
        automation: f.automation(),
        commandId: 'unused',
        localSessionId: 'unused',
        scheduledCallback: true,
      );
      expect(result.transitioned, isFalse);
      if (mode == 'wall_jump') {
        expect(result.reason, 'not_due');
      } else {
        expect(
          result.outcome,
          LocalBookingTransitionOutcome.timeIntegrityRequiresReview,
        );
      }
      expect(await store.allCommands('account'), isEmpty);
    });
  }
  test(
    'second offline boundary completes local B by reference and starts C once',
    () async {
      final base = f.fieldSchedule(
        bookings: [f.booking('A', 40), f.booking('B', 44), f.booking('C', 49)],
      );
      await run(schedule: base);
      final b = coordinator.currentActiveSession!;
      final derived = coordinator.phoneOwnedBookingSchedule(
        base,
        automation: f.automation(),
      )!;
      expect(derived.currentSession?.sessionId, b.localId);
      clock.now = f.at(51);
      expect((await run(due: false, schedule: derived)).transitioned, isTrue);
      final rows = await store.allCommands('account');
      expect(rows, hasLength(4));
      expect(
        rows[2].payload['p_session_id'],
        CommandReference(localId: b.localId, kind: EntityKind.session).toJson(),
      );
      expect(rows[3].payload['p_booking_id'], 'C');
      expect(rows[3].prerequisites, [rows[2].localId]);
      expect(coordinator.currentActiveSession?.bookingId, 'C');
      expect(
        (await run(due: false, schedule: derived)).outcome,
        LocalBookingTransitionOutcome.alreadyRecorded,
      );
      expect(await store.allCommands('account'), hasLength(4));
    },
  );
  test(
    'revised stale intent cannot duplicate an already committed boundary',
    () async {
      await run();
      final first = (await store.allCommands('account'))
          .map((r) => r.commandId)
          .toList();
      expect(
        (await run(state: f.automation(decisionRevision: 1))).outcome,
        LocalBookingTransitionOutcome.alreadyRecorded,
      );
      expect(
        (await store.allCommands('account')).map((r) => r.commandId),
        first,
      );
    },
  );
  test('simultaneous due callbacks persist exactly one pair', () async {
    final results = await Future.wait(List.generate(8, (_) => run()));
    expect(results.every((r) => r.transitioned), isTrue);
    expect(await store.allCommands('account'), hasLength(2));
    expect(scheduled, 1);
  });
  test('server conflict is dispatched once, retains local B and observes durable review', () async {
    await run();
    final transport = sync_fixture.PackageTransport()
      ..startResponse = {'status': 'conflict', 'session_id': 'another-session'};
    final engine = SyncEngine(store: store, transport: transport);
    await engine.run('account');
    await engine.run('account');
    expect(
      transport.requests.where(
        (r) => r.type == CommandType.startBookingSession,
      ),
      hasLength(1),
    );
    final record = await coordinator.restorePhoneOwnedTransition(
      accountId: 'account',
      wellId: 'well',
      transitionKey: resultKey(),
    );
    expect(record?.reconciliationState, 'requires_review');
    final active = await coordinator.projectActiveSession(
      accountId: 'account',
      wellId: 'well',
    );
    expect(active?.bookingId, 'B');
    expect(active?.syncState, SessionSyncState.conflict);
    expect(active?.startedAt, f.at(47));
    expect(active?.serverSessionId, isNull);
    expect(await store.allCommands('account'), hasLength(2));
  });
  test(
    'wall clock jump never replaces trusted actual transition instant',
    () async {
      coordinator.dispose();
      coordinator = OfflineSessionCoordinator(
        store: store,
        bookingLedger: ledger,
        timeIntegritySource: FixedTimeSource('wall_jump_due'),
      );
      expect((await run()).transitioned, isTrue);
      expect((await store.allCommands('account')).map((c) => c.occurredAt), [
        f.at(47),
        f.at(47),
      ]);
    },
  );
  test(
    'server rejection preserves B and records review when observed',
    () async {
      await run();
      final rows = await store.allCommands('account');
      await store.markNeedsReview(
        'account',
        rows[1].localId,
        error: 'conflict',
        attemptedAt: f.at(48),
      );
      final record = await coordinator.restorePhoneOwnedTransition(
        accountId: 'account',
        wellId: 'well',
        transitionKey: resultKey(),
      );
      expect(record?.reconciliationState, 'requires_review');
      expect(
        (await coordinator.projectActiveSession(
          accountId: 'account',
          wellId: 'well',
        ))?.localId,
        rows[1].localId,
      );
      expect(await store.allCommands('account'), hasLength(2));
    },
  );
}

String resultKey() => 'chain:server-A:B:0:1';

WellDaySchedule copySchedule(
  WellDaySchedule base,
  CurrentBookingSession? current,
) => WellDaySchedule(
  wellId: base.wellId,
  requestedDay: base.requestedDay,
  serverTime: base.serverTime,
  timezone: base.timezone,
  dayStart: base.dayStart,
  dayEnd: base.dayEnd,
  wellTimezone: base.wellTimezone,
  bookings: base.bookings,
  currentSession: current,
);

class FixedTimeSource implements TimeIntegritySource {
  FixedTimeSource(this.mode);
  final String mode;
  @override
  Future<TimeReading> read() async => TimeReading(
    wallClock: mode.startsWith('wall_jump') ? f.at(57) : f.at(47),
    monotonic: mode == 'monotonic_backwards'
        ? const Duration(seconds: 1)
        : mode == 'wall_jump'
        ? const Duration(seconds: 100)
        : const Duration(seconds: 340),
    bootId: mode == 'reboot' ? '43' : '42',
  );
}

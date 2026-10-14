@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/today_bookings_panel.dart';

import '../../support/identity_fixture.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/time_integrity.dart';
import 'package:well_irrigation_mobile/core/session/local_booking_transition_resolver.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';

DateTime at(int minute) => DateTime.utc(2026, 10, 8, 20, minute);

class FieldClock implements TimeIntegritySource {
  DateTime now = at(43);
  void Function()? onRead;
  @override
  Future<TimeReading> read() async {
    onRead?.call();
    return TimeReading(
      wallClock: now,
      monotonic: const Duration(seconds: 100) + now.difference(at(43)),
      bootId: '42',
    );
  }
}

BookingDayItem booking(
  String id,
  int start, {
  int priority = 0,
  String? code,
  bool consumed = false,
  String status = 'confirmed',
  int duration = 4,
}) => BookingDayItem(
  id: id,
  publicCode: code ?? id,
  wellId: 'well',
  farmerWellAccountId: 'farmer',
  farmId: 'farm',
  expectedEnergySource: 'well_diesel',
  scheduledStart: at(start),
  scheduledEnd: at(start + 4),
  scheduledDay: '2026-10-08',
  expectedDurationMinutes: duration,
  status: status,
  priority: priority,
  statusGroup: 'active',
  session: consumed
      ? BookingSessionSummary(
          sessionId: 'used-$id',
          status: 'closed',
          startedAt: at(start),
          endedAt: at(start + 4),
        )
      : null,
);
WellDaySchedule fieldSchedule({
  List<BookingDayItem>? bookings,
  int actualStart = 43,
}) => WellDaySchedule(
  wellId: 'well',
  requestedDay: DateTime.utc(2026, 10, 8),
  serverTime: at(43),
  timezone: 'Asia/Aden',
  wellTimezone: 'Asia/Aden',
  dayStart: DateTime.utc(2026, 10, 7, 21),
  dayEnd: DateTime.utc(2026, 10, 8, 21),
  currentSession: CurrentBookingSession(
    sessionId: 'server-A',
    status: 'open',
    startedAt: at(actualStart),
    wellId: 'well',
    bookingId: 'A',
  ),
  bookings:
      bookings ??
      [
        booking('A', 40, code: 'BKG-26-A97C3'),
        booking('B', 44, code: 'BKG-26-43D2E'),
      ],
);
BookingAutomationState automation({String? next, int decisionRevision = 0}) =>
    BookingAutomationState(
      wellId: 'well',
      enabled: true,
      revision: 1,
      settingsRowExists: true,
      firstSession: 'manual',
      activeChainId: 'chain',
      activeChainStatus: 'active',
      activeChainNextBookingId: next,
      activeChainDecisionRevision: decisionRevision,
    );
CachedBookingSchedule cached(WellDaySchedule schedule) => CachedBookingSchedule(
  schedule,
  at(43),
  timeAnchor: SessionTimeAnchor(
    serverTime: at(43),
    wallClock: at(43),
    monotonic: const Duration(seconds: 100),
    bootId: '42',
  ),
);

class FieldBookingRepository extends BookingRepository {
  FieldBookingRepository(
    BookingLocalLedger ledger,
    FieldClock clock,
    this.snapshot,
  ) : super(null, null, ledger, clock);
  WellDaySchedule snapshot;
  BookingAutomationState automationSnapshot = automation();
  @override
  Future<List<BookingTransitionIntent>> reconcilePendingLocalIntents({
    required String accountId,
    required String wellId,
  }) async => [];
  @override
  Future<BookingScheduleView> fetchScheduleView({
    required String accountId,
    required String wellId,
  }) async => BookingScheduleView(
    schedule: snapshot,
    isCached: true,
    fetchedAt: at(43),
    timeAnchor: cached(snapshot).timeAnchor,
  );
  @override
  Future<(BookingAutomationState, bool)> fetchAutomationView({
    required String accountId,
    required String wellId,
  }) async => (automationSnapshot, true);
}

class TimerProbeCoordinator extends OfflineSessionCoordinator {
  TimerProbeCoordinator(FieldClock clock)
    : super(store: InMemoryOutboxStore(), timeIntegritySource: clock);
  bool complete = false;
  LocalProvisionalBookingSession? evidence;
  @override
  Future<LocalProvisionalBookingSession?> restoreProvisionalBookingSession({
    required String accountId,
    required String wellId,
  }) async => evidence;
  int calls = 0;
  ResolvedLocalBookingTransitionCandidate? observed;
  bool? scheduled;
  @override
  Future<LocalBookingTransitionResult> runPhoneOwnedDueBookingTransition({
    required String accountId,
    required String wellId,
    required CachedBookingSchedule? cachedSchedule,
    required BookingAutomationState? automation,
    required String commandId,
    required String localSessionId,
    required bool scheduledCallback,
    bool Function()? isCurrent,
  }) async {
    calls++;
    observed = resolveLocalBookingTransition(
      schedule: cachedSchedule!.schedule,
      automation: automation!,
    );
    scheduled = scheduledCallback;
    if (complete) {
      if (!scheduledCallback) {
        return const LocalBookingTransitionResult(
          outcome: LocalBookingTransitionOutcome.missedRequiresReview,
          reason: 'missed',
        );
      }
      evidence = LocalProvisionalBookingSession(
        localSessionId: localSessionId,
        wellId: wellId,
        chainId: observed!.chainId,
        serverSessionId: observed!.currentSessionId,
        nextBookingId: observed!.nextBooking.id,
        commandId: commandId,
        transitionKey: 'probe',
        closedLocallyAt: at(47),
        startedLocallyAt: at(47),
        decisionRevision: observed!.decisionRevision,
        automationRevision: observed!.automationRevision,
      );
      return LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.transitioned,
        reason: 'probe',
        session: evidence,
      );
    }
    return const LocalBookingTransitionResult(
      outcome: LocalBookingTransitionOutcome.blocked,
      reason: 'timer_probe',
    );
  }
}

class EmptyFieldOperations extends OperationsRepository {
  @override
  Future<List<Pump>> fetchPumps(String wellId) async => [];
}

class EmptyFieldPrices extends WellManagementRepository {
  @override
  Future<PriceScheduleModel?> fetchActivePriceSchedule(
    String wellId, {
    DateTime? at,
  }) async => null;
}

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late SqliteOutboxStore store;
  late BookingLocalLedger ledger;
  late FieldClock clock;
  late OfflineSessionCoordinator coordinator;
  Future<void> reopen() async {
    await store.close();
    store = SqliteOutboxStore(
      sqfliteFactory: databaseFactoryFfiNoIsolate,
      databasePath: '${dir.path}/outbox.db',
    );
    ledger = BookingLocalLedger(store);
    coordinator = OfflineSessionCoordinator(
      store: store,
      bookingLedger: ledger,
      timeIntegritySource: clock,
    );
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('field_transition_regression');
    clock = FieldClock();
    store = SqliteOutboxStore(
      sqfliteFactory: databaseFactoryFfiNoIsolate,
      databasePath: '${dir.path}/outbox.db',
    );
    ledger = BookingLocalLedger(store);
    coordinator = OfflineSessionCoordinator(
      store: store,
      bookingLedger: ledger,
      timeIntegritySource: clock,
    );
    await ledger.importServerSession(
      accountId: 'account',
      wellId: 'well',
      sessionId: 'server-A',
      bookingId: 'A',
      startedAt: at(43),
    );
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });
  Future<LocalBookingTransitionResult> run({
    WellDaySchedule? schedule,
    String? hint,
    bool scheduled = true,
  }) => coordinator.runPhoneOwnedDueBookingTransition(
    accountId: 'account',
    wellId: 'well',
    cachedSchedule: cached(schedule ?? fieldSchedule()),
    automation: automation(next: hint),
    commandId: 'phone-command',
    localSessionId: 'local-B',
    scheduledCallback: scheduled,
  );

  test(
    'field active null-next transitions at actual operational end once',
    () async {
      clock.now = at(47);
      final first = await run();
      expect(first.outcome, LocalBookingTransitionOutcome.transitioned);
      expect(first.intent?.nextBookingId, 'B');
      expect(first.liveTransition?.occurredAt, at(47));
      final duplicate = await run();
      expect(duplicate.intent?.commandId, 'phone-command');
      expect(await ledger.loadProvisionalSessions('account', 'well'), isEmpty);
      expect(await store.pendingCommands('account'), hasLength(2));
    },
  );
  test('scheduled end passed but actual start plus duration not reached: no transition', () async {
    clock.now = at(45);
    final result = await run(hint: 'B');
    expect(result.reason, 'not_due');
    expect(await ledger.loadAwaitingIntents('account', 'well'), isEmpty);
    expect(await ledger.loadProvisionalSessions('account', 'well'), isEmpty);
  });
  test(
    'shared resolver derives active null-next and ignores JSON position',
    () {
      final result = resolveLocalBookingTransition(
        schedule: fieldSchedule(bookings: [booking('B', 44), booking('A', 40)]),
        automation: automation(),
      );
      expect(result?.nextBooking.id, 'B');
      expect(result?.operationalEnd, at(47));
      expect(result?.dueAt, at(47));
    },
  );
  test(
    'later next scheduled start governs due; later operational end governs due',
    () {
      final laterNext = resolveLocalBookingTransition(
        schedule: fieldSchedule(bookings: [booking('A', 40), booking('B', 48)]),
        automation: automation(),
      );
      expect(laterNext?.dueAt, at(48));
      final laterEnd = resolveLocalBookingTransition(
        schedule: fieldSchedule(),
        automation: automation(),
      );
      expect(laterEnd?.dueAt, at(47));
    },
  );
  test('candidate ordering is start ASC priority DESC public code ASC', () {
    final list = [
      booking('A', 40),
      booking('late', 49, priority: 100),
      booking('low', 44, priority: 0),
      booking('high-Z', 44, priority: 10, code: 'ZZ'),
      booking('high-A', 44, priority: 10, code: 'AA'),
    ];
    final next = resolveLocalBookingTransition(
      schedule: fieldSchedule(bookings: list),
      automation: automation(),
    );
    expect(next?.nextBooking.id, 'high-A');
    list.removeWhere((b) => b.id == 'high-A');
    expect(
      resolveLocalBookingTransition(
        schedule: fieldSchedule(bookings: list),
        automation: automation(),
      )?.nextBooking.id,
      'high-Z',
    );
    list.removeWhere((b) => b.id == 'high-Z');
    expect(
      resolveLocalBookingTransition(
        schedule: fieldSchedule(bookings: list),
        automation: automation(),
      )?.nextBooking.id,
      'low',
    );
  });
  test(
    'consumed confirmed booking is excluded; no unconsumed candidate blocks',
    () async {
      final list = [
        booking('A', 40),
        booking('consumed', 44, consumed: true),
        booking('B', 45),
      ];
      expect(
        resolveLocalBookingTransition(
          schedule: fieldSchedule(bookings: list),
          automation: automation(),
        )?.nextBooking.id,
        'B',
      );
      clock.now = at(47);
      final result = await run(
        schedule: fieldSchedule(
          bookings: [
            booking('A', 40),
            booking('B', 44, consumed: true),
            booking('draft', 44, status: 'draft'),
          ],
        ),
      );
      expect(result.outcome, LocalBookingTransitionOutcome.blocked);
      expect(await ledger.loadAwaitingIntents('account', 'well'), isEmpty);
    },
  );
  test('current duration missing/invalid, current booking missing, and decision hint mismatch fail closed', () {
    expect(
      resolveLocalBookingTransition(
        schedule: fieldSchedule(
          bookings: [booking('A', 40, duration: 0), booking('B', 44)],
        ),
        automation: automation(),
      ),
      isNull,
    );
    expect(
      resolveLocalBookingTransition(
        schedule: fieldSchedule(bookings: [booking('B', 44)]),
        automation: automation(),
      ),
      isNull,
    );
    expect(
      resolveLocalBookingTransition(
        schedule: fieldSchedule(),
        automation: automation(next: 'different'),
      ),
      isNull,
    );
    expect(
      resolveLocalBookingTransition(
        schedule: fieldSchedule(),
        automation: automation(next: 'A'),
      ),
      isNull,
    );
  });
  test('restart same boot before due restores snapshot and rederives candidate for arming', () async {
    final schedule = fieldSchedule();
    final response = {
      'status': 'ok',
      'well_id': 'well',
      'requested_day': '2026-10-08',
      'server_time': at(43).toIso8601String(),
      'timezone': 'Asia/Aden',
      'well_timezone': 'Asia/Aden',
      'day_start': schedule.dayStart.toIso8601String(),
      'day_end': schedule.dayEnd.toIso8601String(),
      'current_session': {
        'session_id': 'server-A',
        'well_id': 'well',
        'booking_id': 'A',
        'status': 'open',
        'started_at': at(43).toIso8601String(),
      },
      'bookings': schedule.bookings
          .map(
            (b) => {
              'id': b.id,
              'well_id': b.wellId,
              'public_code': b.publicCode,
              'farmer_well_account_id': b.farmerWellAccountId,
              'farm_id': b.farmId,
              'expected_energy_source': b.expectedEnergySource,
              'scheduled_start': b.scheduledStart.toIso8601String(),
              'scheduled_end': b.scheduledEnd.toIso8601String(),
              'scheduled_day': b.scheduledDay,
              'expected_duration_minutes': b.expectedDurationMinutes,
              'status': b.status,
              'priority': b.priority,
              'status_group': b.statusGroup,
            },
          )
          .toList(),
    };
    await ledger.saveSchedule(
      accountId: 'account',
      wellId: 'well',
      response: response,
      fetchedAt: at(43),
      timeAnchor: cached(schedule).timeAnchor,
    );
    await reopen();
    final restored = (await ledger.loadLatestSchedule('account', 'well'))!;
    clock.now = at(45);
    final decision = resolveLocalBookingTransition(
      schedule: restored.schedule,
      automation: automation(),
    )!;
    final now = resolveServerAlignedNow(
      anchor: restored.timeAnchor!,
      reading: await clock.read(),
    );
    expect(now.trustedForAutomaticTransition, isTrue);
    expect(decision.dueAt.difference(now.at), const Duration(minutes: 2));
    expect((await run(schedule: restored.schedule)).reason, 'not_due');
    expect(await ledger.loadAwaitingIntents('account', 'well'), isEmpty);
    clock.now = at(47);
    expect((await run(schedule: restored.schedule)).intent?.nextBookingId, 'B');
  });
  test('callback rederives candidate before write instead of using old RAM decision', () async {
    clock.now = at(47);
    final list = [booking('A', 40), booking('B', 44)];
    final snapshot = fieldSchedule(bookings: list);
    var reads = 0;
    clock.onRead = () {
      if (++reads == 2) list[1] = booking('C', 44);
    };
    final changed = await run(schedule: snapshot);
    expect(changed.reason, 'candidate_changed');
    expect(await ledger.loadAwaitingIntents('account', 'well'), isEmpty);
    expect(await ledger.loadProvisionalSessions('account', 'well'), isEmpty);
    clock.onRead = null;
    final refreshed = await run(schedule: snapshot);
    expect(refreshed.intent?.nextBookingId, 'C');
  });
  test(
    'restart after operational due remains missed review with no backdating',
    () async {
      await reopen();
      clock.now = at(48);
      final missed = await run(scheduled: false);
      expect(
        missed.outcome,
        LocalBookingTransitionOutcome.missedRequiresReview,
      );
      expect(await ledger.loadProvisionalSessions('account', 'well'), isEmpty);
    },
  );
  testWidgets(
    'foreground timer arms active null-next and invokes callback only at operational due',
    (tester) async {
      final probe = TimerProbeCoordinator(clock);
      clock.now = at(43);
      await tester.pumpWidget(
        MaterialApp(
          home: OperationsScreen(
            identity: testIdentity(
              accountId: 'account',
              wells: [
                testWell(id: 'well', roles: ['operator']),
              ],
            ),
            coordinator: probe,
            bookingRepository: FieldBookingRepository(
              ledger,
              clock,
              fieldSchedule(),
            ),
            repository: EmptyFieldOperations(),
            priceRepository: EmptyFieldPrices(),
            timeIntegritySource: clock,
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      clock.now = at(44);
      await tester.pump(const Duration(minutes: 1));
      expect(probe.calls, 0);
      clock.now = at(47);
      await tester.pump(const Duration(minutes: 3));
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      expect(probe.calls, 1);
      expect(probe.observed?.nextBooking.id, 'B');
      expect(probe.observed?.dueAt, at(47));
      expect(probe.scheduled, isTrue);
      await tester.pump(const Duration(minutes: 1));
      expect(probe.calls, 1);
      await tester.pumpWidget(const SizedBox());
      probe.dispose();
    },
  );
  for (final scenario in [
    'before',
    'at_due',
    'after_due',
    'changed',
    'revision',
    'pause',
    'restart',
  ]) {
    testWidgets('foreground arm refresh provenance: $scenario', (tester) async {
      final probe = TimerProbeCoordinator(clock)..complete = true;
      final repo = FieldBookingRepository(ledger, clock, fieldSchedule());
      Widget screen() => MaterialApp(
        home: OperationsScreen(
          identity: testIdentity(
            accountId: 'account',
            wells: [
              testWell(id: 'well', roles: ['operator']),
            ],
          ),
          coordinator: probe,
          bookingRepository: repo,
          repository: EmptyFieldOperations(),
          priceRepository: EmptyFieldPrices(),
          timeIntegritySource: clock,
        ),
      );
      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await tester.pump();
        }
      }

      void refresh() => tester
          .widget<TodayBookingsPanel>(find.byType(TodayBookingsPanel))
          .onRefresh();
      clock.now = at(43);
      await tester.pumpWidget(screen());
      await settle();
      if (scenario == 'pause') {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        clock.now = at(48);
        await tester.pump(const Duration(minutes: 5));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      } else if (scenario == 'restart') {
        await tester.pumpWidget(const SizedBox());
        clock.now = at(48);
        await tester.pumpWidget(screen());
      } else {
        clock.now = scenario == 'before'
            ? at(45)
            : scenario == 'after_due'
            ? at(48)
            : at(47);
        if (scenario == 'changed') {
          repo.snapshot = fieldSchedule(
            bookings: [booking('A', 40), booking('C', 44)],
          );
        }
        if (scenario == 'revision') {
          repo.automationSnapshot = automation(decisionRevision: 1);
        }
        // Start refresh before pumping expired timers: reproduces cancellation race.
        refresh();
      }
      await settle();
      if (scenario == 'before') {
        expect(probe.calls, 0);
        for (var i = 0; i < 3; i++) {
          refresh();
          await settle();
        }
        clock.now = at(47);
        await tester.pump(const Duration(minutes: 2));
        await settle();
      }
      if (['pause', 'restart', 'changed', 'revision'].contains(scenario)) {
        expect(probe.scheduled, isFalse);
        expect(probe.evidence, isNull);
      } else {
        expect(probe.calls, 1);
        expect(probe.scheduled, isTrue);
        expect(probe.evidence, isNotNull);
        final command = probe.evidence!.commandId;
        for (var i = 0; i < 3; i++) {
          refresh();
          await settle();
        }
        expect(probe.calls, 1);
        expect(probe.evidence!.commandId, command);
      }
      await tester.pumpWidget(const SizedBox());
      probe.dispose();
    });
  }
}

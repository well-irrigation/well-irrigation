import 'dart:convert';

import '../../support/accepted_completion_fixture.dart';
import '../../support/historical_session_fixture.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/booking/booking_reactivity.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/time_integrity.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/features/bookings/bookings_screen.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/today_bookings_panel.dart';

import '../../core/session/local_booking_transition_regression_test.dart' as f;
import '../../support/identity_fixture.dart';

final base = DateTime.utc(2026, 10, 14, 0, 13, 4);

class Clock implements TimeIntegritySource {
  DateTime now = base;
  @override
  Future<TimeReading> read() async => TimeReading(
    wallClock: now,
    monotonic: const Duration(seconds: 100) + now.difference(base),
    bootId: '42',
  );
}

const pump = Pump(
  id: 'pump',
  wellId: 'well',
  name: 'المضخة الشرقية',
  publicCode: 'P-1',
);

class Pumps extends f.EmptyFieldOperations {
  @override
  Future<List<Pump>> fetchPumps(String wellId) async => [pump];
}

BookingDayItem item(String id, int minute) => BookingDayItem(
  id: id,
  publicCode: id,
  wellId: 'well',
  farmerWellAccountId: 'farmer',
  farmerName: 'مزارع $id',
  farmId: 'farm',
  farmName: 'أرض $id',
  scheduledStart: DateTime.utc(2026, 10, 14, 0, minute),
  scheduledEnd: DateTime.utc(2026, 10, 14, 0, minute + 2),
  scheduledDay: '2026-10-14',
  expectedDurationMinutes: 2,
  expectedEnergySource: 'well_diesel',
  status: 'confirmed',
  priority: 0,
  statusGroup: 'active',
);
WellDaySchedule schedule({bool stale = false}) => WellDaySchedule(
  wellId: 'well',
  requestedDay: DateTime(2026, 10, 14),
  serverTime: base,
  timezone: 'Asia/Aden',
  wellTimezone: 'Asia/Aden',
  dayStart: DateTime.utc(2026, 10, 13, 21),
  dayEnd: DateTime.utc(2026, 10, 14, 21),
  bookings: [item('A', 13), item('B', 16)],
  currentSession: stale
      ? CurrentBookingSession(
          sessionId: 'server-A',
          status: 'open',
          startedAt: base,
          wellId: 'well',
          bookingId: 'A',
          bookingPublicCode: 'A',
        )
      : null,
);
final automation = BookingAutomationState(
  wellId: 'well',
  enabled: true,
  revision: 1,
  settingsRowExists: true,
  firstSession: 'manual',
  activeChainId: 'chain',
  activeChainStatus: 'active',
  activeChainNextBookingId: 'B',
  activeChainDecisionRevision: 1,
);
CachedBookingSchedule snapshot() => CachedBookingSchedule(
  schedule(),
  base,
  timeAnchor: SessionTimeAnchor(
    serverTime: base,
    wallClock: base,
    monotonic: const Duration(seconds: 100),
    bootId: '42',
  ),
);

class Repo extends BookingRepository {
  int scheduleCalls = 0;
  int listCalls = 0;
  @override
  Future<BookingScheduleView> fetchScheduleView({
    required String accountId,
    required String wellId,
  }) async {
    scheduleCalls++;
    return BookingScheduleView(
      schedule: schedule(stale: true),
      isCached: true,
      fetchedAt: base,
      timeAnchor: snapshot().timeAnchor,
    );
  }

  @override
  Future<(BookingAutomationState, bool)> fetchAutomationView({
    required String accountId,
    required String wellId,
  }) async => (automation, true);
  @override
  Future<WellBookingList> listWellBookings({
    required String wellId,
    DateTime? from,
    DateTime? to,
    int limit = 200,
  }) async {
    listCalls++;
    return WellBookingList(
      wellTimezone: 'Asia/Aden',
      count: 2,
      bookings: [
        for (final b in schedule().bookings)
          WellBookingListItem(
            id: b.id,
            publicCode: b.publicCode,
            farmerWellAccountId: b.farmerWellAccountId,
            farmerName: b.farmerName!,
            farmId: b.farmId!,
            farmName: b.farmName!,
            scheduledStart: b.scheduledStart,
            scheduledEnd: b.scheduledEnd,
            scheduledDay: b.scheduledDay,
            expectedDurationMinutes: b.expectedDurationMinutes,
            status: b.status,
            priority: b.priority,
          ),
      ],
    );
  }
}

void main() {
  testWidgets(
    'historical booked sessions retain reactive completion and late ACK safety on both screens',
    (tester) async {
      tester.view.physicalSize = const Size(1800, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = InMemoryOutboxStore();
      final clock = Clock();
      final repo = Repo();
      final coordinator = OfflineSessionCoordinator(
        store: store,
        timeIntegritySource: clock,
      );
      addTearDown(coordinator.dispose);
      addTearDown(store.close);
      final identity = testIdentity(
        accountId: 'cross-screen',
        wells: [
          testWell(id: 'well', roles: ['operator']),
        ],
      );
      Future<void> restoreHistoricalBooking(String id) async {
        final booking = schedule().bookings.singleWhere((b) => b.id == id);
        final anchor = snapshot().timeAnchor!;
        final start = await persistHistoricalStart(
          store: store,
          type: CommandType.startBookingSession,
          accountId: identity.accountId,
          wellId: 'well',
          localId: 'historical-$id',
          commandId: 'historical-command-$id',
          startedAt: clock.now,
          payload: {'p_booking_id': id, 'p_crops': <String>[]},
          localContext: {
            'booking_id': id,
            'manual_start': true,
            'p_pump_id': pump.id,
            'pump_name': pump.name,
            'p_farm_id': booking.farmId,
            'p_farmer_well_account_id': booking.farmerWellAccountId,
            'p_energy_source': booking.expectedEnergySource,
            'alternative_energy_source': booking.alternativeEnergySource,
            'farmer_name': booking.farmerName,
            'farm_name': booking.farmName,
            'expected_duration_minutes': booking.expectedDurationMinutes,
            'scheduled_start': booking.scheduledStart.toIso8601String(),
            'scheduled_end': booking.scheduledEnd.toIso8601String(),
            'automation_revision': automation.revision,
            'chain_id': automation.activeChainId,
            'decision_revision': automation.activeChainDecisionRevision,
            'trusted_time_anchor': {
              'server_time': anchor.serverTime!.toIso8601String(),
              'wall_clock': anchor.wallClock.toIso8601String(),
              'monotonic_us': anchor.monotonic.inMicroseconds,
              'boot_id': anchor.bootId,
            },
          },
        );
        await store.insertBundle(
          accountId: identity.accountId,
          key: 'booking.manual_start.v1.well.$id',
          value: jsonEncode({
            'start_local_id': start.localId,
            'start_command_id': start.commandId,
          }),
          commands: const [],
        );
        await coordinator.freshProjectActiveSession(
          accountId: identity.accountId,
          wellId: 'well',
        );
      }

      await restoreHistoricalBooking('A');
      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              Expanded(
                child: BookingsScreen(
                  identity: identity,
                  bookingRepository: repo,
                ),
              ),
              Expanded(
                child: OperationsScreen(
                  identity: identity,
                  coordinator: coordinator,
                  bookingRepository: repo,
                  repository: Pumps(),
                  priceRepository: f.EmptyFieldPrices(),
                  timeIntegritySource: clock,
                  clock: () => clock.now,
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final bookings = find.byType(BookingsScreen);
      final panel = find.byType(TodayBookingsPanel);
      Finder inBookings(String text) =>
          find.descendant(of: bookings, matching: find.text(text));
      Finder inPanel(String text) =>
          find.descendant(of: panel, matching: find.text(text));
      expect(inBookings('جاري'), findsOneWidget);
      expect(inPanel('جاري'), findsOneWidget);
      expect(find.text('المضخة الشرقية'), findsWidgets);
      expect(repo.scheduleCalls, 1);
      final initialPanel = tester.widget<TodayBookingsPanel>(panel);
      await tester.pump(const Duration(seconds: 1));
      expect(
        identical(tester.widget<TodayBookingsPanel>(panel), initialPanel),
        true,
      );
      Future<void> finishAt(DateTime now) async {
        clock.now = now;
        final root = coordinator.currentActiveSession!;
        await coordinator.completeSession(
          accountId: identity.accountId,
          sessionLocalId: root.localId,
          completedAt: now,
        );
        expect(coordinator.currentActiveSession?.completedAt, isNull);
        await acceptTestCompletion(
          store: store,
          coordinator: coordinator,
          accountId: identity.accountId,
          wellId: 'well',
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }

      await finishAt(DateTime.utc(2026, 10, 14, 0, 15, 4));
      expect(coordinator.currentActiveSession, isNull);
      expect(inBookings('جاري'), findsNothing);
      expect(inPanel('جاري'), findsNothing);
      expect(inPanel('التالي'), findsOneWidget);
      expect(inBookings('السجل المنتهي لليوم (1)'), findsOneWidget);
      expect(inPanel('السجل المنتهي لليوم (1)'), findsOneWidget);
      expect(find.textContaining('الجلسة الجارية من الحجز A'), findsNothing);
      expect(find.byKey(const Key('start-booking-A')), findsNothing);
      clock.now = DateTime.utc(2026, 10, 14, 0, 16);
      await restoreHistoricalBooking('B');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(inBookings('جاري'), findsOneWidget);
      expect(inPanel('جاري'), findsOneWidget);
      expect(coordinator.currentActiveSession?.pumpId, 'pump');
      expect(coordinator.currentActiveSession?.pumpName, pump.name);
      expect(find.text('المضخة الشرقية'), findsWidgets);
      // A late ACK for A must not clear B's live controls or identity.
      final currentB = coordinator.currentActiveSession!;
      final startA = (await store.allCommands(identity.accountId)).singleWhere(
        (row) =>
            row.type == CommandType.startBookingSession &&
            row.payload['p_booking_id'] == 'A',
      );
      await store.markConfirmed(
        identity.accountId,
        startA.localId,
        serverResponse: {'session_id': 'accepted-${startA.localId}'},
        attemptedAt: clock.now,
      );
      await coordinator.freshProjectActiveSession(
        accountId: identity.accountId,
        wellId: 'well',
      );
      await tester.pump();
      expect(coordinator.currentActiveSession?.localId, currentB.localId);
      expect(inPanel('جاري'), findsOneWidget);
      expect(find.text('إيقاف مؤقت'), findsOneWidget);
      await finishAt(DateTime.utc(2026, 10, 14, 0, 18));
      expect(inBookings('جاري'), findsNothing);
      expect(inPanel('جاري'), findsNothing);
      expect(inBookings('السجل المنتهي لليوم (2)'), findsOneWidget);
      expect(inPanel('السجل المنتهي لليوم (2)'), findsOneWidget);
      expect(repo.scheduleCalls, 1); // local boundaries did not fetch
      final scope = BookingReactivity.instance.scope(
        identity.accountId,
        'well',
      );
      scope.mutation(days: {'2026-10-14'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(repo.scheduleCalls, 2); // two mounted screens shared one refresh
      expect(inBookings('جاري'), findsNothing);
      expect(inPanel('جاري'), findsNothing);
      for (final row in await store.allCommands(identity.accountId)) {
        if (row.type == CommandType.completeIrrigationSession) continue;
        await store.markConfirmed(
          identity.accountId,
          row.localId,
          serverResponse: row.type == CommandType.endBookingTransitionChain
              ? {
                  'contract': 'end_booking_transition_chain',
                  'version': 1,
                  'status': 'ended',
                }
              : {
                  'session_id': 'accepted-${row.localId}',
                  'booking_id': row.payload['p_booking_id'],
                  'well_id': row.wellId,
                  'session_status': 'open',
                  'booking_status': 'confirmed',
                  'started_at': row.occurredAt.toIso8601String(),
                  'booked_duration_minutes': 2,
                  'operational_end_at': row.occurredAt
                      .add(const Duration(minutes: 2))
                      .toIso8601String(),
                },
          attemptedAt: clock.now,
        );
        if (row.type == CommandType.startBookingSession) {
          await store.putMapping(
            identity.accountId,
            IdMapping(
              localId: row.localId,
              kind: EntityKind.session,
              serverId: 'accepted-${row.localId}',
              resolvedAt: clock.now,
            ),
          );
        }
      }
      await coordinator.freshProjectActiveSession(
        accountId: identity.accountId,
        wellId: 'well',
      );
      await tester.pump();
      await tester.ensureVisible(inBookings('السجل المنتهي لليوم (2)'));
      await tester.tap(inBookings('السجل المنتهي لليوم (2)'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(inBookings('منفذ'), findsNWidgets(2));
      expect(inBookings('بانتظار المزامنة'), findsNothing);
      expect(inBookings('اكتملت الجلسة 03:18'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      coordinator.dispose();
    },
  );
  for (final enabled in [true, false]) {
    testWidgets(
      'offline automation retains saved value=$enabled with explicit subtitle',
      (tester) async {
        var changes = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: TodayBookingsPanel(
                  schedule: schedule(),
                  automation: BookingAutomationState(
                    wellId: 'well',
                    enabled: enabled,
                    settingsRowExists: true,
                    firstSession: 'manual',
                  ),
                  isLoadingSchedule: false,
                  isLoadingAutomation: false,
                  isUpdatingAutomation: false,
                  canManageAutomation: false,
                  hasLocalActiveSession: false,
                  isCachedSchedule: true,
                  onRefresh: () {},
                  onToggleAutomation: (_) => changes++,
                  onStartBooking: (_) async {},
                ),
              ),
            ),
          ),
        );
        final tile = tester.widget<SwitchListTile>(
          find.byKey(const Key('booking-automation-switch')),
        );
        expect(tile.value, enabled);
        expect(tile.onChanged, isNull);
        expect(
          find.text(
            '${enabled ? 'مفعّل' : 'غير مفعّل'} — محفوظ على الجهاز. يتطلب اتصالًا لتغيير الإعداد.',
          ),
          findsOneWidget,
        );
        expect(changes, 0);
      },
    );
  }
}

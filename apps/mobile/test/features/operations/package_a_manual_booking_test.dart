@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';

import '../../core/session/local_booking_transition_regression_test.dart' as f;
import '../../support/identity_fixture.dart';

import 'package:well_irrigation_mobile/features/operations/widgets/today_bookings_panel.dart';

import 'package_a_live_session_test.dart' as ui;

class ManualRepo extends ui.FreshRepo {
  ManualRepo(super.ledger, super.clock, super.snapshot);
  int directStarts = 0;
  @override
  Future<BookingStartResult> startBooking({
    required String bookingId,
    required DateTime startedAt,
    required String commandId,
    List<String> crops = const [],
  }) async {
    directStarts++;
    throw StateError('direct server path must not be called');
  }
}

void main() {
  sqfliteFfiInit();
  testWidgets(
    'operator tap starts locally, fast ACK and refresh retain controls and identity',
    (tester) async {
      late Directory dir;
      late SqliteOutboxStore store;
      late BookingLocalLedger ledger;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('manual-booking-ui-');
        store = SqliteOutboxStore(
          databasePath: '${dir.path}/outbox.db',
          sqfliteFactory: databaseFactoryFfi,
        );
        await store.initialize();
        ledger = BookingLocalLedger(store);
      });
      final clock = f.FieldClock();
      final base = f.fieldSchedule();
      final snapshot = WellDaySchedule(
        wellId: 'well',
        requestedDay: base.requestedDay,
        serverTime: base.serverTime,
        timezone: base.timezone,
        wellTimezone: base.wellTimezone,
        dayStart: base.dayStart,
        dayEnd: base.dayEnd,
        bookings: [f.booking('A', 43), f.booking('B', 48, duration: 3)],
      );
      final repo = ManualRepo(ledger, clock, snapshot);
      final coordinator = OfflineSessionCoordinator(
        store: store,
        bookingLedger: ledger,
        timeIntegritySource: clock,
      );
      Future<void> flush() async {
        for (var i = 0; i < 45; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
      }

      await tester.pumpWidget(
        MaterialApp(
          home: OperationsScreen(
            identity: testIdentity(
              accountId: 'account',
              wells: [
                testWell(id: 'well', roles: ['operator']),
              ],
            ),
            coordinator: coordinator,
            bookingRepository: repo,
            repository: f.EmptyFieldOperations(),
            priceRepository: f.EmptyFieldPrices(),
            timeIntegritySource: clock,
          ),
        ),
      );
      await flush();
      expect(coordinator.currentActiveSession, isNull);
      final startButton = find.byKey(const Key('start-booking-A'));
      clock.now = f.at(43).add(const Duration(seconds: 23));
      await tester.ensureVisible(startButton);
      await tester.tap(startButton);
      await flush();
      expect(repo.directStarts, 0);
      final active = coordinator.currentActiveSession!;
      expect(active.phoneOwned, isTrue);
      expect(active.bookingId, 'A');
      expect(find.text('إيقاف مؤقت'), findsOneWidget);
      expect(
        find.byKey(const Key('server-booking-session-notice')),
        findsNothing,
      );
      await tester.runAsync(() async {
        final start = (await store.allCommands('account')).single;
        expect(start.type, CommandType.startBookingSession);
        await store.markConfirmed(
          'account',
          start.localId,
          serverResponse: {'session_id': 'server-A'},
          attemptedAt: f.at(43),
        );
        await store.putMapping(
          'account',
          IdMapping(
            localId: start.localId,
            kind: EntityKind.session,
            serverId: 'server-A',
            resolvedAt: f.at(43),
          ),
        );
      });
      repo.snapshot = WellDaySchedule(
        wellId: 'well',
        requestedDay: base.requestedDay,
        serverTime: base.serverTime,
        timezone: base.timezone,
        wellTimezone: base.wellTimezone,
        dayStart: base.dayStart,
        dayEnd: base.dayEnd,
        bookings: snapshot.bookings,
        currentSession: CurrentBookingSession(
          sessionId: 'server-A',
          status: 'open',
          startedAt: active.startedAt,
          wellId: 'well',
          bookingId: 'A',
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await flush();
      expect(coordinator.currentActiveSession?.localId, active.localId);
      expect(coordinator.currentActiveSession?.startedAt, active.startedAt);
      expect(coordinator.currentActiveSession?.serverSessionId, 'server-A');
      expect(find.text('إيقاف مؤقت'), findsOneWidget);
      expect(
        find.byKey(const Key('server-booking-session-notice')),
        findsNothing,
      );
      clock.now = f.at(47).add(const Duration(seconds: 23));
      await tester.pump(const Duration(minutes: 4));
      await flush();
      expect(coordinator.currentActiveSession, isNull);
      expect(find.text('إيقاف مؤقت'), findsNothing);
      expect(
        find.byKey(const Key('server-booking-session-notice')),
        findsNothing,
      );
      clock.now = f.at(48);
      await tester.pump(const Duration(seconds: 37));
      await flush();
      expect(coordinator.currentActiveSession?.bookingId, 'B');
      expect(find.text('إيقاف مؤقت'), findsOneWidget);
      final panel = tester.widget<TodayBookingsPanel>(
        find.byType(TodayBookingsPanel),
      );
      expect(panel.requiresReview, isFalse);
      expect(panel.timeIntegrityRequiresReview, isFalse);
      clock.now = f.at(51);
      await tester.pump(const Duration(minutes: 3));
      await flush();
      expect(coordinator.currentActiveSession, isNull);
      expect(find.text('إيقاف مؤقت'), findsNothing);
      await tester.runAsync(() async {
        final commands = await store.allCommands('account');
        expect(commands, hasLength(5));
        expect(
          commands[1].occurredAt,
          f.at(47).add(const Duration(seconds: 23)),
        );
        expect(commands[2].occurredAt, f.at(48));
        expect(commands[3].occurredAt, f.at(51));
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      coordinator.dispose();
      await tester.runAsync(() async {
        await store.close();
        await dir.delete(recursive: true);
      });
    },
  );
}

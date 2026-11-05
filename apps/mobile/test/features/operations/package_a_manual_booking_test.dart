@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';

import '../../core/session/local_booking_transition_regression_test.dart' as f;
import '../../support/identity_fixture.dart';

import 'package_a_live_session_test.dart' as ui;

class TrustedPumpOperations extends f.EmptyFieldOperations {
  @override
  Future<List<Pump>> fetchPumps(String wellId) async => [
    Pump(id: 'pump', wellId: wellId, name: 'مضخة', publicCode: 'P'),
  ];
}

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
            repository: TrustedPumpOperations(),
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
      expect(active.phoneOwned, isFalse);
      expect(active.bookingId, isNull);
      expect(find.text('جارٍ تأكيد بدء الجلسة'), findsOneWidget);
      expect(find.text('لا تبدأ جلسة أخرى حتى يكتمل التحقق.'), findsOneWidget);
      expect(find.textContaining('لم يُسجَّل شيء'), findsNothing);
      expect(find.textContaining('PostgrestException'), findsNothing);
      expect(find.text('إيقاف مؤقت'), findsOneWidget);
      expect(
        find.byKey(const Key('server-booking-session-notice')),
        findsNothing,
      );
      await tester.runAsync(() async {
        final start = (await store.allCommands('account')).single;
        await store.markNeedsReview('account',start.localId,error:'not_found',attemptedAt:active.startedAt);
        await coordinator.freshProjectActiveSession(accountId:'account',wellId:'well');
      });
      await flush();
      expect(find.text('تحتاج عملية بدء الجلسة إلى مراجعة'),findsOneWidget);
      for (final technical in ['not_found','unresolved','retry_authorized','PostgrestException']) {
        expect(find.textContaining(technical),findsNothing);
      }
      await tester.runAsync(() async {
        final start = (await store.allCommands('account')).single;
        expect(start.type, CommandType.startOperationalSession);
        expect(start.payload['p_source_booking_id'], 'A');
        await store.markConfirmed(
          'account',
          start.localId,
          serverResponse: {'id': 'server-A'},
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
        bookings: [f.booking('A', 50, status:'cancelled')],
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
      expect(find.text('جارٍ تأكيد بدء الجلسة'), findsNothing);
      expect(find.text('إيقاف مؤقت'), findsOneWidget);
      expect(
        find.byKey(const Key('server-booking-session-notice')),
        findsNothing,
      );
      clock.now = f.at(47).add(const Duration(seconds: 23));
      await tester.pump(const Duration(minutes: 4));
      await flush();
      expect(coordinator.currentActiveSession?.localId, active.localId);
      expect(coordinator.currentActiveSession?.completedAt, isNull);
      expect(find.text('إيقاف مؤقت'), findsOneWidget);
      clock.now = f.at(51);
      await tester.pump(const Duration(minutes: 4));
      await flush();
      expect(coordinator.currentActiveSession?.bookingId, isNull);
      await tester.runAsync(() async {
        expect(await store.allCommands('account'), hasLength(1));
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

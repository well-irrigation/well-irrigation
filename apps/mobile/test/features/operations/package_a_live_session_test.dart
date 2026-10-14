import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';

import '../../core/session/local_booking_transition_regression_test.dart' as f;
import '../../support/identity_fixture.dart';

class FreshRepo extends f.FieldBookingRepository {
  FreshRepo(super.ledger, super.clock, super.snapshot);
  @override
  Future<(BookingAutomationState, bool)> fetchAutomationView({
    required String accountId,
    required String wellId,
  }) async => (f.automation(), false);
  @override
  Future<BookingScheduleView> fetchScheduleView({
    required String accountId,
    required String wellId,
  }) async => BookingScheduleView(
    schedule: snapshot,
    isCached: false,
    fetchedAt: f.at(43),
    timeAnchor: f.cached(snapshot).timeAnchor,
  );
}

void main() {
  sqfliteFfiInit();
  testWidgets(
    'fresh online snapshot arms phone transition, switches to B and never duplicates on timer',
    (tester) async {
      late Directory dir;
      late SqliteOutboxStore store;
      late BookingLocalLedger ledger;
      final clock = f.FieldClock();
      var scheduled = 0;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('package-a-ui-');
        store = SqliteOutboxStore(
          databasePath: '${dir.path}/outbox.db',
          sqfliteFactory: databaseFactoryFfi,
        );
        await store.initialize();
        ledger = BookingLocalLedger(store);
        await ledger.importServerSession(
          accountId: 'account',
          wellId: 'well',
          sessionId: 'server-A',
          bookingId: 'A',
          startedAt: f.at(43),
        );
      });
      final coordinator = OfflineSessionCoordinator(
        store: store,
        bookingLedger: ledger,
        timeIntegritySource: clock,
        commandQueuedScheduler: (_) async {
          scheduled++;
          return true;
        },
      );
      Future<void> flush() async {
        for (var i = 0; i < 18; i++) {
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
            bookingRepository: FreshRepo(ledger, clock, f.fieldSchedule()),
            repository: f.EmptyFieldOperations(),
            priceRepository: f.EmptyFieldPrices(),
            timeIntegritySource: clock,
          ),
        ),
      );
      await flush();
      clock.now = f.at(47);
      await tester.pump(const Duration(minutes: 4));
      await flush();
      expect(coordinator.currentActiveSession?.bookingId, 'B');
      expect(find.text('إيقاف مؤقت'), findsOneWidget);
      expect(
        find.byKey(const Key('server-booking-session-notice')),
        findsNothing,
      );
      clock.now = f.at(48);
      await tester.pump(const Duration(minutes: 1));
      await flush();
      await tester.runAsync(() async {
        expect(await store.allCommands('account'), hasLength(2));
      });
      expect(scheduled, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      coordinator.dispose();
      await tester.runAsync(() async {
        await store.close();
        await dir.delete(recursive: true);
      });
    },
  );
  for (final mode in ['pending', 'confirmed', 'completed']) {
    final confirmed = mode != 'pending';
    final completed = mode == 'completed';
    testWidgets('phone owned B controls win over stale server A, state=$mode', (
      tester,
    ) async {
      final store = InMemoryOutboxStore();
      await store.insert(
        CommandEnvelope(
          localId: 'local-B',
          commandId: 'command-B',
          type: CommandType.startBookingSession,
          accountId: 'account',
          wellId: 'well',
          sequence: 1,
          occurredAt: f.at(47),
          createdLocalAt: f.at(47),
          payload: {'p_booking_id': 'B', 'p_crops': <String>[]},
          localContext: {
            'previous_server_session_id': 'server-A',
            'p_farm_id': 'farm',
            'p_farmer_well_account_id': 'farmer',
            'p_energy_source': 'well_diesel',
            'farmer_name': 'مزارع الحجز التالي',
            'farm_name': 'أرض الحجز التالي',
          },
          status: confirmed ? CommandStatus.confirmed : CommandStatus.pending,
        ),
      );
      if (confirmed) {
        await store.putMapping(
          'account',
          IdMapping(
            localId: 'local-B',
            kind: EntityKind.session,
            serverId: 'server-B',
            resolvedAt: f.at(48),
          ),
        );
      }
      final clock = f.FieldClock()..now = f.at(48);
      final coordinator = OfflineSessionCoordinator(
        store: store,
        timeIntegritySource: clock,
      );
      if (completed) {
        await coordinator.completeSession(
          accountId: 'account',
          sessionLocalId: 'local-B',
          completedAt: f.at(49),
        );
      }
      final ledger = BookingLocalLedger(SqliteOutboxStore());
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
            bookingRepository: FreshRepo(ledger, clock, f.fieldSchedule()),
            repository: f.EmptyFieldOperations(),
            priceRepository: f.EmptyFieldPrices(),
            timeIntegritySource: clock,
          ),
        ),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump();
      }
      expect(
        find.byKey(const Key('server-booking-session-notice')),
        findsNothing,
      );
      expect(
        find.text('إيقاف مؤقت'),
        completed ? findsNothing : findsOneWidget,
      );
      expect(
        find.text('إنهاء الجلسة'),
        completed ? findsNothing : findsOneWidget,
      );
      if (!completed) {
        final pauseButton = find.ancestor(
          of: find.text('إيقاف مؤقت'),
          matching: find.byWidgetPredicate((w) => w is ElevatedButton),
        );
        expect(pauseButton, findsOneWidget);
        expect(tester.widget<ElevatedButton>(pauseButton).onPressed, isNotNull);
        expect(coordinator.currentActiveSession?.localId, 'local-B');
        expect(find.text('مزارع الحجز التالي'), findsOneWidget);
        expect(find.text('أرض الحجز التالي'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      coordinator.dispose();
    });
  }
}

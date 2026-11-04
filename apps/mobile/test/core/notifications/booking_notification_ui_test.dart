import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/booking/booking_reactivity.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_services.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_router.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_permission_coordinator.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_delivery_coordinator.dart';
import 'package:well_irrigation_mobile/features/bookings/bookings_screen.dart';

import '../../support/identity_fixture.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import '../sync/booking_dispatch_c2a_test.dart' show Transport, accepted;
import 'notification_delivery_test.dart' show RecordingPresenter;
import 'notification_routing_permission_test.dart' show Permission;
import 'notification_host_test.dart' show EmptyStore;

late SqliteOutboxStore bookingTestStore;

class BookingUiRepo extends BookingRepository {
  BookingUiRepo() : super(null, null, BookingLocalLedger(bookingTestStore));
  final List<WellBookingListItem> items = [];
  int listCalls = 0;
  int scheduleCalls = 0;
  WellBookingListItem item(
    String id,
    DateTime start, {
    String status = 'confirmed',
    int priority = 0,
  }) => WellBookingListItem(
    id: id,
    publicCode: id,
    farmerWellAccountId: 'farmer',
    farmerName: 'مزارع $id',
    farmId: 'farm',
    farmName: 'الأرض',
    scheduledStart: start,
    scheduledEnd: start.add(const Duration(minutes: 60)),
    scheduledDay: '2027-01-15',
    expectedDurationMinutes: 60,
    status: status,
    priority: priority,
    expectedEnergySource: 'well_diesel',
  );
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
      count: items.length,
      bookings: [...items],
    );
  }

  @override
  Future<BookingScheduleView> fetchScheduleView({
    required String accountId,
    required String wellId,
  }) async {
    scheduleCalls++;
    return BookingScheduleView(
      schedule: WellDaySchedule(
        wellId: wellId,
        requestedDay: DateTime(2027, 1, 15),
        timezone: 'Asia/Aden',
        wellTimezone: 'Asia/Aden',
        dayStart: DateTime.utc(2027, 1, 14, 21),
        dayEnd: DateTime.utc(2027, 1, 15, 21),
        bookings: const [],
      ),
      isCached: false,
      fetchedAt: DateTime.utc(2027, 1, 15),
    );
  }

  @override
  Future<(BookingAutomationState, bool)> fetchAutomationView({
    required String accountId,
    required String wellId,
  }) async => (
    BookingAutomationState(
      wellId: wellId,
      enabled: false,
      settingsRowExists: true,
      firstSession: 'manual',
    ),
    false,
  );
  @override
  Future<WellBookingDetail> getBookingDetail(String bookingId) async =>
      WellBookingDetail(
        booking: items.singleWhere((b) => b.id == bookingId),
        wellTimezone: 'Asia/Aden',
      );
  @override
  Future<BookingMutationResult> createBooking({
    required String wellId,
    required String farmerWellAccountId,
    required String farmId,
    required DateTime scheduledStart,
    required DateTime scheduledEnd,
    required String commandId,
    String? expectedEnergySource,
    String? alternativeEnergySource,
    int priority = 0,
    String? notes,
  }) async {
    items.add(item('NEW', scheduledStart));
    return const BookingMutationResult(status: 'confirmed', bookingId: 'NEW');
  }

  @override
  Future<BookingMutationResult> cancelBooking({
    required String bookingId,
    required String reason,
    required String commandId,
  }) async {
    final index = items.indexWhere((b) => b.id == bookingId);
    items[index] = item(
      bookingId,
      items[index].scheduledStart,
      status: 'cancelled',
    );
    return BookingMutationResult(status: 'ok', bookingId: bookingId);
  }

  @override
  Future<BookingMutationResult> rescheduleBooking({
    required String bookingId,
    required DateTime scheduledStart,
    required DateTime scheduledEnd,
    required String reason,
    required String commandId,
  }) async {
    final index = items.indexWhere((b) => b.id == bookingId);
    items[index] = item(bookingId, scheduledStart);
    return BookingMutationResult(status: 'ok', bookingId: bookingId);
  }
}


void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('c3_ui');
    bookingTestStore = SqliteOutboxStore(
      databasePath: '${dir.path}/db',
      sqfliteFactory: databaseFactoryFfiNoIsolate,
      singleInstance: false,
    );
    await bookingTestStore.initialize();
  });
  tearDown(() async {
    NotificationServices.current = null;
    await bookingTestStore.close();
    await dir.delete(recursive: true);
  });
  for (final confirmed in [false, true]) {
    testWidgets(
      'notification destination preserves day and target, confirmed=$confirmed; refresh emits no additional event',
      (tester) async {
        final repo = BookingUiRepo();
        final r = (await tester.runAsync(
          () => repo.saveLocalBooking(
            accountId: 'a',
            wellId: 'w',
            requestId: 'target',
            farmer: const FarmerAccount(
              id: 'f',
              fullName: 'أحمد',
              publicCode: 'F',
            ),
            farm: const Farm(
              id: 'farm',
              wellId: 'w',
              name: 'الأرض',
              farmerAccountId: 'f',
            ),
            scheduledStart: DateTime.utc(2027, 1, 15, 7),
            scheduledEnd: DateTime.utc(2027, 1, 15, 8),
            expectedEnergySource: 'well_diesel',
          ),
        ))!;
        await tester.runAsync(
          () => SyncEngine(
            store: bookingTestStore,
            transport: Transport(
              (request) async => confirmed
                  ? accepted(request)
                  : const DispatchFailed(
                      disposition: FailureDisposition.review,
                      message: 'RAW_PRIVATE_ERROR',
                    ),
            ),
            clock: () => DateTime.now(),
          ).runBookingCreates('a'),
        );
        if (confirmed) {
          repo.items.add(
            repo.item('booking-${r.commandId}', DateTime.utc(2027, 1, 15, 7)),
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            supportedLocales: const [Locale('ar')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: BookingsScreen(
              identity: testIdentity(
                accountId: 'a',
                wells: [testWell(id: 'w')],
              ),
              bookingRepository: repo,
              initialDay: DateTime(2027, 1, 15),
              initialRequestId: r.requestId,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('notification-target-booking')),
          findsOneWidget,
        );
        expect(find.text('الحجز المطلوب'), findsOneWidget);
        if (!confirmed) {
          expect(find.text('راجع الحجز'), findsOneWidget);
          expect(find.text('تعديل الحجز'), findsNothing);
          expect(find.text('بدء السقي'), findsNothing);
        }
        expect(find.textContaining('RAW_PRIVATE_ERROR'), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        BookingReactivity.instance
            .scope('a', 'w')
            .mutation(days: {r.scheduledDay});
        await tester.pumpAndSettle();
        final db = await tester.runAsync(
          () => databaseFactoryFfiNoIsolate.openDatabase(
            '${dir.path}/db',
            options: OpenDatabaseOptions(singleInstance: false),
          ),
        );
        expect(
          await tester.runAsync(() => db!.query('notification_events')),
          hasLength(1),
        );
        await tester.runAsync(() => db!.close());
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  test('permission rationale observes durable booking already saved, denial cannot undo it', () async {
    final repo = BookingUiRepo();
    final gateway = Permission();
    final explained = NotificationPermissionCoordinator(
      gateway: gateway,
      wasExplained: (_) async => false,
      markExplained: (_) async {},
    );
    var count = 0;
    explained.explain = (r) async {
      expect(
        await repo.localBooking(accountId: 'a', wellId: 'w', requestId: 'r'),
        isNotNull,
      );
      count++;
      return true;
    };
    NotificationServices.current = NotificationServices(
      delivery: NotificationDeliveryCoordinator(
        store: EmptyStore(),
        presenter: RecordingPresenter(),
      ),
      permission: explained,
      router: NotificationRouter(load: (a, id) async => null),
    );
    await repo.saveLocalBooking(
      accountId: 'a',
      wellId: 'w',
      requestId: 'r',
      farmer: const FarmerAccount(id: 'f', fullName: 'أحمد', publicCode: 'F'),
      farm: const Farm(
        id: 'farm',
        wellId: 'w',
        name: 'الأرض',
        farmerAccountId: 'f',
      ),
      scheduledStart: DateTime.utc(2027, 1, 15, 7),
      scheduledEnd: DateTime.utc(2027, 1, 15, 8),
      expectedEnergySource: 'well_diesel',
    );
    for (var i = 0; i < 100 && gateway.requests == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(count, 1);
    expect(gateway.requests, 1);
    expect(
      await repo.localBooking(accountId: 'a', wellId: 'w', requestId: 'r'),
      isNotNull,
    );
  });
}

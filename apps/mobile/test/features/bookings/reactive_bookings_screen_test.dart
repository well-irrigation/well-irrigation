import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/booking/booking_reactivity.dart';
import 'package:well_irrigation_mobile/features/bookings/bookings_screen.dart';

import '../../support/identity_fixture.dart';

class ReactiveRepo extends BookingRepository {
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

class FormOps extends OperationsRepository {
  @override
  Future<List<FarmerAccount>> fetchFarmers(
    String wellId, {
    String? query,
  }) async => [
    const FarmerAccount(id: 'farmer', fullName: 'أحمد', publicCode: 'F'),
  ];
  @override
  Future<List<Farm>> fetchFarms(
    String wellId, {
    String? farmerAccountId,
  }) async => [Farm(id: 'farm', wellId: wellId, name: 'الأرض')];
}

void main() {
  testWidgets(
    'Save creates immediately in sorted position; cancel moves to history without recreating list',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = ReactiveRepo()
        ..items.addAll([
          ReactiveRepo().item('late', DateTime(2027, 1, 15, 10)),
          ReactiveRepo().item('early', DateTime(2027, 1, 15, 7)),
        ]);
      final identity = testIdentity(
        accountId: 'mutation-ui',
        wells: [testWell(id: 'mutation-well')],
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('ar')],
          locale: const Locale('ar'),
          home: BookingsScreen(
            identity: identity,
            bookingRepository: repo,
            operationsRepository: FormOps(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(BookingsScreen));
      await tester.tap(find.text('إضافة حجز'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ابحث بالاسم أو الرمز'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('أحمد').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('ابحث عن الأرض'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('الأرض').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('ديزل البئر'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('حفظ الحجز'));
      await tester.pumpAndSettle();
      expect(identical(tester.state(find.byType(BookingsScreen)), state), true);
      expect(find.text('مزارع NEW'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('مزارع early')).dy,
        lessThan(tester.getTopLeft(find.text('مزارع NEW')).dy),
      );
      expect(
        tester.getTopLeft(find.text('مزارع NEW')).dy,
        lessThan(tester.getTopLeft(find.text('مزارع late')).dy),
      );
      final calls = repo.listCalls;
      await tester.tap(find.text('مزارع NEW'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إلغاء الحجز').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('تأكيد الإلغاء'));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('تفاصيل الحجز'))).pop();
      await tester.pumpAndSettle();
      expect(repo.listCalls, calls + 1);
      expect(find.text('مزارع NEW'), findsNothing);
      expect(find.text('السجل المنتهي لليوم (1)'), findsOneWidget);
      await tester.tap(find.text('السجل المنتهي لليوم (1)'));
      await tester.pumpAndSettle();
      expect(find.text('ملغى'), findsOneWidget);
      expect(find.text('مزارع NEW'), findsOneWidget);
    },
  );
  testWidgets(
    'mounted list reschedules immediately and unaffected well does not fetch',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = ReactiveRepo();
      repo.items.addAll([
        repo.item('A', DateTime(2027, 1, 15, 7)),
        repo.item('B', DateTime(2027, 1, 15, 8)),
      ]);
      final scope = BookingReactivity.instance.scope('reschedule-ui', 'well');
      await tester.pumpWidget(
        MaterialApp(
          home: BookingsScreen(
            identity: testIdentity(
              accountId: 'reschedule-ui',
              wells: [testWell(id: 'well')],
            ),
            bookingRepository: repo,
          ),
        ),
      );
      await tester.pumpAndSettle();
      repo.items[0] = repo.item('A', DateTime(2027, 1, 15, 9));
      scope.mutation(days: {'2027-01-15'});
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('مزارع B')).dy,
        lessThan(tester.getTopLeft(find.text('مزارع A')).dy),
      );
      final before = repo.listCalls;
      BookingReactivity.instance
          .scope('reschedule-ui', 'other')
          .mutation(days: {'2027-01-15'});
      await tester.pumpAndSettle();
      expect(repo.listCalls, before);
    },
  );
}

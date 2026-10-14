import 'package:flutter/material.dart';
import 'package:well_irrigation_mobile/core/booking/booking_reactivity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/features/bookings/bookings_screen.dart';
import 'package:well_irrigation_mobile/features/bookings/booking_detail_screen.dart';
import 'package:well_irrigation_mobile/features/bookings/booking_form_screen.dart';

import '../../support/identity_fixture.dart';

WellBookingListItem _item({String id = 'b1', String status = 'confirmed'}) =>
    WellBookingListItem(
      id: id,
      publicCode: 'B-$id',
      farmerWellAccountId: 'fa1',
      farmerName: 'مزارع $id',
      farmId: 'farm1',
      farmName: 'الأرض الأولى',
      scheduledStart: DateTime.utc(2026, 10, 10, 5),
      scheduledEnd: DateTime.utc(2026, 10, 10, 6),
      scheduledDay: '2026-10-10',
      expectedDurationMinutes: 60,
      status: status,
      priority: 0,
      expectedEnergySource: 'solar',
      notes: null,
    );

class _FakeBookingRepo extends BookingRepository {
  _FakeBookingRepo({this.items = const [], this.runningBookingId})
    : super(null);
  final List<WellBookingListItem> items;
  final String? runningBookingId;
  int detailCalls = 0;
  final List<int> listLimits = [];

  @override
  Future<WellBookingList> listWellBookings({
    required String wellId,
    DateTime? from,
    DateTime? to,
    int limit = 200,
  }) async {
    listLimits.add(limit);
    return WellBookingList(
      wellTimezone: 'Asia/Aden',
      count: items.length,
      bookings: items,
    );
  }

  @override
  Future<WellBookingDetail> getBookingDetail(String bookingId) async {
    detailCalls++;
    return WellBookingDetail(
      booking: _item(id: bookingId),
      wellTimezone: '',
    );
  }

  @override
  Future<BookingScheduleView> fetchScheduleView({
    required String accountId,
    required String wellId,
  }) async => BookingScheduleView(
    schedule: WellDaySchedule(
      wellId: wellId,
      requestedDay: DateTime.utc(2026, 10, 10),
      timezone: 'Asia/Aden',
      dayStart: DateTime.utc(2026, 10, 10),
      dayEnd: DateTime.utc(2026, 10, 11),
      wellTimezone: 'Asia/Aden',
      bookings: const [],
      currentSession: runningBookingId == null
          ? null
          : CurrentBookingSession(
              sessionId: 'sess-x',
              status: 'open',
              startedAt: DateTime.utc(2026, 10, 10, 8),
              wellId: wellId,
              bookingId: runningBookingId,
            ),
    ),
    isCached: false,
    fetchedAt: DateTime.utc(2026, 10, 10),
  );
}

const _well = WellSummary(
  id: 'well-1',
  tenantId: 't1',
  name: 'بئر',
  status: 'active',
  roles: ['owner', 'operator'],
);

class _FakeOps extends OperationsRepository {
  _FakeOps() : super(null);
  @override
  Future<List<FarmerAccount>> fetchFarmers(
    String wellId, {
    String? query,
  }) async => const [];
  @override
  Future<List<Farm>> fetchFarms(
    String wellId, {
    String? farmerAccountId,
  }) async => const [];
}

void main() {
  setUp(
    () => BookingReactivity.instance.scope('user-test-1', 'well-1').mutation(),
  );
  Widget wrap(Widget child) => MaterialApp(
    locale: const Locale('ar'),
    home: Directionality(textDirection: TextDirection.rtl, child: child),
  );

  void sizeLarge(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('لا تبويبات فئات قديمة؛ تنقّل يومي + إضافة + قراءة محدودة', (
    tester,
  ) async {
    sizeLarge(tester);
    final repo = _FakeBookingRepo(
      items: [
        _item(id: 'b1'),
        _item(id: 'b2'),
      ],
    );
    await tester.pumpWidget(
      wrap(
        BookingsScreen(
          identity: testIdentity(wells: const [_well]),
          bookingRepository: repo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // التنقّل اليومي هو النموذج الوحيد — لا تبويبات «القادمة/السابقة».
    expect(find.text('القادمة'), findsNothing);
    expect(find.text('السابقة'), findsNothing);
    expect(find.text('السابق'), findsOneWidget);
    expect(find.text('التالي'), findsOneWidget);
    expect(find.text('اليوم'), findsWidgets);
    expect(find.text('إضافة حجز'), findsOneWidget);
    // بطاقات من نتيجة القائمة فقط، بلا طلب تفاصيل لكل بطاقة.
    expect(repo.detailCalls, 0);
    expect(repo.listLimits, isNotEmpty);
    expect(repo.listLimits.every((l) => l <= 200), isTrue);
  });

  testWidgets('الحجز الجاري يفتح العمليات لا التفاصيل', (tester) async {
    sizeLarge(tester);
    var openedOps = false;
    final repo = _FakeBookingRepo(
      items: [_item(id: 'b1')],
      runningBookingId: 'b1',
    );
    await tester.pumpWidget(
      wrap(
        BookingsScreen(
          identity: testIdentity(wells: const [_well]),
          bookingRepository: repo,
          onOpenOperations: () => openedOps = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('جاري'), findsWidgets);
    await tester.tap(find.text('مزارع b1'));
    await tester.pumpAndSettle();
    expect(openedOps, isTrue);
    expect(find.byType(BookingDetailScreen), findsNothing);
    expect(repo.detailCalls, 0);
  });

  testWidgets('حجز غير جارٍ يفتح التفاصيل بطلب واحد عند الفتح', (tester) async {
    sizeLarge(tester);
    final repo = _FakeBookingRepo(items: [_item(id: 'b1')]);
    await tester.pumpWidget(
      wrap(
        BookingsScreen(
          identity: testIdentity(wells: const [_well]),
          bookingRepository: repo,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(repo.detailCalls, 0);

    await tester.tap(find.text('مزارع b1'));
    await tester.pumpAndSettle();
    expect(find.byType(BookingDetailScreen), findsOneWidget);
    expect(repo.detailCalls, 1);
    expect(find.textContaining('المحاصيل'), findsNothing);
  });

  testWidgets('السابق/التالي/اليوم ينقل تاريخ العرض ويعود لليوم الكنوني', (
    tester,
  ) async {
    sizeLarge(tester);
    final repo = _FakeBookingRepo(items: [_item(id: 'b1')]);
    await tester.pumpWidget(
      wrap(
        BookingsScreen(
          identity: testIdentity(wells: const [_well]),
          bookingRepository: repo,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // اليوم الكنوني يأتي من requestedDay = 2026-10-10.
    expect(
      find.text(bookingFullArabicDate(DateTime(2026, 10, 10))),
      findsOneWidget,
    );

    await tester.tap(find.text('التالي'));
    await tester.pumpAndSettle();
    expect(
      find.text(bookingFullArabicDate(DateTime(2026, 10, 11))),
      findsOneWidget,
    );
    expect(
      find.text(bookingFullArabicDate(DateTime(2026, 10, 10))),
      findsNothing,
    );

    await tester.tap(find.text('السابق'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('السابق'));
    await tester.pumpAndSettle();
    expect(
      find.text(bookingFullArabicDate(DateTime(2026, 10, 9))),
      findsOneWidget,
    );

    await tester.tap(find.byIcon(Icons.today_rounded));
    await tester.pumpAndSettle();
    expect(
      find.text(bookingFullArabicDate(DateTime(2026, 10, 10))),
      findsOneWidget,
    );
  });

  testWidgets('زر الإضافة يرث اليوم المعروض كتاريخ افتراضي', (tester) async {
    sizeLarge(tester);
    final repo = _FakeBookingRepo(items: [_item(id: 'b1')]);
    await tester.pumpWidget(
      wrap(
        BookingsScreen(
          identity: testIdentity(wells: const [_well]),
          bookingRepository: repo,
          operationsRepository: _FakeOps(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('التالي'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('إضافة حجز'));
    await tester.pumpAndSettle();

    final form = tester.widget<BookingFormScreen>(
      find.byType(BookingFormScreen),
    );
    expect(form.initialDate, DateTime(2026, 10, 11));
  });
}

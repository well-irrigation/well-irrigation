import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/today_bookings_panel.dart';

void main() {
  WellDaySchedule schedule({CurrentBookingSession? currentSession}) {
    return WellDaySchedule(
      wellId: 'well-1',
      requestedDay: DateTime(2026, 10, 8),
      timezone: 'Asia/Aden',
      dayStart: DateTime.utc(2026, 10, 7, 21),
      dayEnd: DateTime.utc(2026, 10, 8, 21),
      wellTimezone: 'Asia/Aden',
      currentSession: currentSession,
      bookings: [
        BookingDayItem(
          id: 'booking-1',
          publicCode: 'B-001',
          wellId: 'well-1',
          farmerWellAccountId: 'farmer-1',
          farmerName: 'أحمد',
          farmId: 'farm-1',
          farmName: 'المزرعة الشمالية',
          scheduledStart: DateTime.utc(2026, 10, 8, 5),
          scheduledEnd: DateTime.utc(2026, 10, 8, 6),
          scheduledDay: '2026-10-08',
          expectedDurationMinutes: 60,
          expectedEnergySource: 'solar',
          status: 'confirmed',
          priority: 0,
          statusGroup: 'active',
        ),
        BookingDayItem(
          id: 'booking-2',
          publicCode: 'B-002',
          wellId: 'well-1',
          farmerWellAccountId: 'farmer-2',
          farmerName: 'محمد',
          farmId: 'farm-2',
          farmName: 'المزرعة الجنوبية',
          scheduledStart: DateTime.utc(2026, 10, 8, 6),
          scheduledEnd: DateTime.utc(2026, 10, 8, 7),
          scheduledDay: '2026-10-08',
          expectedDurationMinutes: 60,
          expectedEnergySource: 'well_diesel',
          status: 'confirmed',
          priority: 0,
          statusGroup: 'active',
        ),
      ],
    );
  }

  const automation = BookingAutomationState(
    wellId: 'well-1',
    enabled: false,
    revision: 2,
    settingsRowExists: true,
    firstSession: 'manual',
    activeChainId: 'chain-1',
    activeChainStatus: 'waiting',
    activeChainNextBookingId: 'booking-2',
  );

  Widget subject({
    required bool canManage,
    CurrentBookingSession? currentSession,
    ValueChanged<bool>? onToggle,
    Future<void> Function(BookingDayItem booking)? onStart,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: TodayBookingsPanel(
            schedule: schedule(currentSession: currentSession),
            automation: automation,
            isLoadingSchedule: false,
            isLoadingAutomation: false,
            isUpdatingAutomation: false,
            canManageAutomation: canManage,
            hasLocalActiveSession: false,
            onRefresh: () {},
            onToggleAutomation: onToggle ?? (_) {},
            onStartBooking: onStart ?? (_) async {},
          ),
        ),
      ),
    );
  }

  testWidgets('shows server schedule, authoritative next booking, and manual start', (
    tester,
  ) async {
    String? startedBooking;
    await tester.pumpWidget(
      subject(
        canManage: true,
        onStart: (booking) async {
          startedBooking = booking.id;
        },
      ),
    );

    expect(find.text('حجوزات اليوم'), findsOneWidget);
    expect(find.text('أحمد'), findsOneWidget);
    expect(find.text('محمد'), findsOneWidget);
    expect(find.text('التالي'), findsOneWidget);
    expect(find.text('أول حجز يبدأ يدويًا. هذا المفتاح يحفظ إعداد البئر، ولا يعني تفعيل التشغيل الإنتاجي الدائم.'), findsOneWidget);
    expect(find.byKey(const Key('start-booking-booking-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('start-booking-booking-1')));
    await tester.pump();
    expect(startedBooking, 'booking-1');
  });

  testWidgets('operator can toggle automation but owner/read-only view cannot', (
    tester,
  ) async {
    bool? requested;
    await tester.pumpWidget(
      subject(
        canManage: true,
        onToggle: (value) => requested = value,
      ),
    );

    await tester.tap(find.byKey(const Key('booking-automation-switch')));
    await tester.pump();
    expect(requested, isTrue);

    requested = null;
    await tester.pumpWidget(
      subject(
        canManage: false,
        onToggle: (value) => requested = value,
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('booking-automation-switch')));
    await tester.pump();
    expect(requested, isNull);
    expect(
      find.text(
        'يمكنك مشاهدة الإعداد. تغييره متاح للمشغّل المخوّل على هاتف التشغيل فقط.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('open server session removes manual start actions', (tester) async {
    await tester.pumpWidget(
      subject(
        canManage: true,
        currentSession: CurrentBookingSession(
          sessionId: 'session-1',
          status: 'open',
          startedAt: DateTime.utc(2026, 10, 8, 5),
          wellId: 'well-1',
          bookingId: 'booking-1',
          bookingPublicCode: 'B-001',
        ),
      ),
    );

    expect(find.textContaining('الجلسة الجارية من الحجز B-001'), findsOneWidget);
    expect(find.text('الجاري'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('loading and error states are explicit', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayBookingsPanel(
            schedule: null,
            automation: null,
            isLoadingSchedule: false,
            isLoadingAutomation: false,
            isUpdatingAutomation: false,
            canManageAutomation: true,
            hasLocalActiveSession: false,
            scheduleError: 'تعذر تحميل حجوزات اليوم.',
            automationError: 'تعذر قراءة الإعداد.',
            onRefresh: () {},
            onToggleAutomation: (_) {},
            onStartBooking: (_) async {},
          ),
        ),
      ),
    );

    expect(find.text('تعذر تحميل حجوزات اليوم.'), findsOneWidget);
    expect(find.text('تعذر قراءة الإعداد.'), findsOneWidget);
    expect(find.text('إعادة تحميل الحجوزات'), findsOneWidget);
  });
}

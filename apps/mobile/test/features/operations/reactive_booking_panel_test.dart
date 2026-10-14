import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/today_bookings_panel.dart';

void main() {
  testWidgets(
    'closed actual session leaves primary list and appears in collapsed history',
    (tester) async {
      final start = DateTime.utc(2026, 10, 14, 0, 13);
      final booking = BookingDayItem(
        id: 'A',
        publicCode: 'B-A',
        wellId: 'well',
        farmerWellAccountId: 'farmer',
        farmerName: 'أحمد',
        farmId: 'farm',
        scheduledStart: start,
        scheduledEnd: start.add(const Duration(minutes: 2)),
        scheduledDay: '2026-10-14',
        expectedDurationMinutes: 2,
        expectedEnergySource: 'solar',
        status: 'confirmed',
        priority: 0,
        statusGroup: 'active',
        session: BookingSessionSummary(
          sessionId: 'session',
          status: 'closed',
          startedAt: start,
          endedAt: start.add(const Duration(minutes: 2, seconds: 4)),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TodayBookingsPanel(
                schedule: WellDaySchedule(
                  wellId: 'well',
                  requestedDay: start,
                  timezone: 'Asia/Aden',
                  dayStart: start,
                  dayEnd: start.add(const Duration(days: 1)),
                  wellTimezone: 'Asia/Aden',
                  bookings: [booking],
                ),
                automation: null,
                isLoadingSchedule: false,
                isLoadingAutomation: false,
                isUpdatingAutomation: false,
                canManageAutomation: false,
                hasLocalActiveSession: false,
                onRefresh: () => fail('manual refresh'),
                onToggleAutomation: (_) {},
                onStartBooking: (_) async => fail('executed start'),
              ),
            ),
          ),
        ),
      );
      expect(find.text('السجل المنتهي لليوم (1)'), findsOneWidget);
      expect(find.byKey(const Key('booking-card-A')), findsNothing);
      await tester.tap(find.text('السجل المنتهي لليوم (1)'));
      await tester.pumpAndSettle();
      expect(find.text('منفذ'), findsOneWidget);
      expect(find.text('اكتملت الجلسة 03:15'), findsOneWidget);
      expect(find.text('بدء هذا الحجز يدويًا'), findsNothing);
    },
  );
}

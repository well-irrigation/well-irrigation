import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';

void main() {
  group('BookingRepository contracts', () {
    test('parses canonical well day schedule without inventing values', () {
      final schedule = WellDaySchedule.fromContract({
        'status': 'ok',
        'well_id': 'well-1',
        'requested_day': '2026-10-08',
        'timezone': 'Asia/Aden',
        'day_start': '2026-10-07T21:00:00Z',
        'day_end': '2026-10-08T21:00:00Z',
        'well_timezone': 'Asia/Aden',
        'current_session': null,
        'count': 1,
        'bookings': [
          {
            'id': 'booking-1',
            'public_code': 'B-001',
            'well_id': 'well-1',
            'farmer_well_account_id': 'farmer-1',
            'farmer_name': 'مزارع الاختبار',
            'farm_id': 'farm-1',
            'farm_name': 'الأرض الأولى',
            'scheduled_start': '2026-10-08T05:00:00Z',
            'scheduled_end': '2026-10-08T06:00:00Z',
            'scheduled_day': '2026-10-08',
            'expected_duration_minutes': 60,
            'expected_energy_source': 'solar',
            'alternative_energy_source': null,
            'status': 'confirmed',
            'priority': 0,
            'status_group': 'active',
            'notes': null,
            'session': null,
          },
        ],
      });

      expect(schedule.wellId, 'well-1');
      expect(schedule.timezone, 'Asia/Aden');
      expect(schedule.bookings, hasLength(1));
      expect(schedule.bookings.single.publicCode, 'B-001');
      expect(schedule.bookings.single.canStartManually, isTrue);
      expect(schedule.currentSession, isNull);
    });

    test('fails closed when schedule payload is incomplete', () {
      expect(
        () => WellDaySchedule.fromContract({
          'status': 'ok',
          'well_id': 'well-1',
          'requested_day': '2026-10-08',
          'timezone': 'Asia/Aden',
          'day_start': '2026-10-07T21:00:00Z',
          'day_end': '2026-10-08T21:00:00Z',
          'well_timezone': 'Asia/Aden',
          'bookings': [
            {
              'id': 'booking-1',
              // public_code deliberately missing.
            },
          ],
        }),
        throwsStateError,
      );
    });

    test('parses automation state and keeps first session manual', () {
      final state = BookingAutomationState.fromContract({
        'contract': 'get_well_booking_automation',
        'version': 1,
        'well_id': 'well-1',
        'booking_auto_transition_enabled': true,
        'booking_auto_transition_revision': 4,
        'settings_row_exists': true,
        'settings_updated_at': '2026-10-08T00:00:00Z',
        'active_chain': {
          'chain_id': 'chain-1',
          'status': 'active',
          'next_booking_id': 'booking-2',
          'decision_revision': 7,
        },
        'automation_executor_ready': false,
        'auto_transition_executed': false,
        'first_session': 'manual',
      });

      expect(state.enabled, isTrue);
      expect(state.revision, 4);
      expect(state.firstSession, 'manual');
      expect(state.activeChainNextBookingId, 'booking-2');

      final updated = state.applyUpdate(
        const BookingAutomationUpdate(
          wellId: 'well-1',
          enabled: false,
          revision: 5,
        ),
      );
      expect(updated.enabled, isFalse);
      expect(updated.revision, 5);
      expect(updated.activeChainNextBookingId, 'booking-2');
    });

    test('rejects automation contract that changes first session semantics', () {
      expect(
        () => BookingAutomationState.fromContract({
          'contract': 'get_well_booking_automation',
          'version': 1,
          'well_id': 'well-1',
          'booking_auto_transition_enabled': false,
          'booking_auto_transition_revision': 0,
          'settings_row_exists': true,
          'active_chain': null,
          'first_session': 'automatic',
        }),
        throwsStateError,
      );
    });

    test('parses explicit booking start receipt', () {
      final result = BookingStartResult.fromContract({
        'booking_id': 'booking-1',
        'booking_status': 'confirmed',
        'session_id': 'session-1',
        'session_status': 'open',
        'well_id': 'well-1',
        'farmer_well_account_id': 'farmer-1',
        'farm_id': 'farm-1',
        'pump_id': 'pump-1',
        'energy_source': 'solar',
        'alternative_energy_source': null,
        'started_at': '2026-10-08T05:00:00Z',
        'booked_duration_minutes': 60,
        'operational_end_at': '2026-10-08T06:00:00Z',
      });

      expect(result.bookingId, 'booking-1');
      expect(result.sessionId, 'session-1');
      expect(result.sessionStatus, 'open');
      expect(result.wellId, 'well-1');
    });
  });
}

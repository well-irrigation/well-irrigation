import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';

Map<String, dynamic> _item({
  String id = 'booking-1',
  String status = 'confirmed',
}) => {
  'id': id,
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
  'status': status,
  'priority': 0,
  'notes': 'ملاحظة',
};

void main() {
  group('WellBookingList.fromContract', () {
    test('maps bounded list items without inventing values', () {
      final list = WellBookingList.fromContract({
        'status': 'ok',
        'well_id': 'well-1',
        'well_timezone': 'Asia/Aden',
        'count': 1,
        'bookings': [_item()],
      });
      expect(list.count, 1);
      expect(list.wellTimezone, 'Asia/Aden');
      expect(list.bookings, hasLength(1));
      final b = list.bookings.single;
      expect(b.id, 'booking-1');
      expect(b.publicCode, 'B-001');
      expect(b.farmerName, 'مزارع الاختبار');
      expect(b.farmName, 'الأرض الأولى');
      expect(b.expectedDurationMinutes, 60);
      expect(b.expectedEnergySource, 'solar');
      expect(b.status, 'confirmed');
      expect(b.notes, 'ملاحظة');
    });

    test('throws when contract status is not ok', () {
      expect(
        () => WellBookingList.fromContract({'status': 'error'}),
        throwsStateError,
      );
    });
  });

  group('WellBookingDetail.fromContract', () {
    test('maps canonical booking detail', () {
      final detail = WellBookingDetail.fromContract({
        'status': 'ok',
        'well_timezone': 'Asia/Aden',
        'booking': _item(id: 'booking-9'),
      });
      expect(detail.booking.id, 'booking-9');
      expect(detail.booking.farmName, 'الأرض الأولى');
      expect(detail.wellTimezone, 'Asia/Aden');
    });
  });

  group('BookingMutationResult.fromContract', () {
    test('parses success with booking id', () {
      final r = BookingMutationResult.fromContract({
        'status': 'created',
        'booking': {'id': 'booking-created'},
      });
      expect(r.isOk, isTrue);
      expect(r.isConflict, isFalse);
      expect(r.bookingId, 'booking-created');
    });

    test('parses conflict as a business conflict, not transport failure', () {
      final r = BookingMutationResult.fromContract({
        'status': 'conflict',
        'conflict_code': 'time_overlap',
        'message': 'يتعارض مع حجز آخر',
      });
      expect(r.isConflict, isTrue);
      expect(r.isOk, isFalse);
      expect(r.conflictCode, 'time_overlap');
      expect(r.message, 'يتعارض مع حجز آخر');
    });

    test('canonical server success status confirmed is treated as ok', () {
      final r = BookingMutationResult.fromContract({
        'status': 'confirmed',
        'booking_id': 'booking-x',
      });
      expect(r.isOk, isTrue);
      expect(r.isRejected, isFalse);
      expect(r.bookingId, 'booking-x');
    });

    test('structured rejection preserves reason_code, not swallowed', () {
      final r = BookingMutationResult.fromContract({
        'status': 'rejected',
        'reason_code': 'solar_start_outside_window',
      });
      expect(r.isRejected, isTrue);
      expect(r.isOk, isFalse);
      expect(r.isConflict, isFalse);
      expect(r.reasonCode, 'solar_start_outside_window');
    });
  });
}

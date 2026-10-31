import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/booking/local_booking_request.dart';
import 'package:well_irrigation_mobile/core/booking/booking_request_projection.dart';

LocalBookingRequest request({Map<String, Object?>? response, String id = 'request'}) => LocalBookingRequest(
  accountId: 'a', wellId: 'w', requestId: id, commandId: 'command-$id',
  createdLocalAt: DateTime.utc(2027), scheduledDay: '2027-01-01',
  payloadJson: jsonEncode({'p_well_id': 'w', 'p_farmer_well_account_id': 'f', 'p_farm_id': 'farm',
    'p_scheduled_start': '2027-01-01T07:00:00.000Z', 'p_scheduled_end': '2027-01-01T08:00:00.000Z',
    'p_expected_energy_source': 'well_diesel', 'p_notes': 'الأصل'}),
  contextJson: jsonEncode({'farmer_name': 'أحمد', 'farm_name': 'الأرض', 'duration_minutes': 60}),
  responseJson: response == null ? null : jsonEncode(response),
);
Map<String, Object?> receipt() => {'status': 'confirmed', 'booking_id': 'real', 'public_code': 'B-1',
  'well_id': 'w', 'scheduled_start': '2027-01-01T07:00:00.000Z', 'scheduled_end': '2027-01-01T08:00:00.000Z'};
void main() {
  for (final status in [null, 'conflict', 'rejected', 'unknown']) {
    test('local projection preserves request identity and remains non-startable: $status', () {
      final local = request(response: status == null ? null : {'status': status, 'reason_code': 'RAW_CODE'});
      final item = mergeBookingRequests([], [local]).single;
      expect(item.publicCode, isEmpty);
      expect(item.localRequest!.canStart, isFalse);
      expect(item.localRequest!.requestId, local.requestId);
      expect(item.localRequest!.commandId, local.commandId);
    });
  }
  test('accepted placeholder persists until canonical identity arrives, never startable', () {
    final local = request(response: receipt());
    final projected = mergeBookingRequests([], [local]).single;
    expect(projected.publicCode, 'B-1');
    expect(projected.localRequest!.canStart, isFalse);
    final canonical = WellBookingListItem(id: 'real', publicCode: 'B-1', farmerWellAccountId: 'f', farmerName: 'أحمد',
      farmId: 'farm', farmName: 'الأرض', scheduledStart: projected.scheduledStart, scheduledEnd: projected.scheduledEnd,
      scheduledDay: local.scheduledDay, expectedDurationMinutes: 60, status: 'confirmed', priority: 0);
    expect(mergeBookingRequests([canonical], [local]), [canonical]);
    final similar = WellBookingListItem(id: 'different', publicCode: 'B-2', farmerWellAccountId: 'f', farmerName: 'أحمد',
      farmId: 'farm', farmName: 'الأرض', scheduledStart: projected.scheduledStart, scheduledEnd: projected.scheduledEnd,
      scheduledDay: local.scheduledDay, expectedDurationMinutes: 60, status: 'confirmed', priority: 0);
    expect(mergeBookingRequests([similar], [local]), hasLength(2));
  });
  test('superseded local request stays hidden', () {
    final old = LocalBookingRequest.fromRow({...request().toRow(), 'superseded_by_request_id': 'replacement'});
    expect(mergeBookingRequests([], [old]), isEmpty);
  });
  test('malformed acceptance cannot show confirmation or code', () {
    final local = request(response: {'status': 'confirmed', 'booking_id': 'fake', 'public_code': 'fake'});
    expect(local.isConfirmed, isFalse);
    expect(mergeBookingRequests([], [local]).single.publicCode, isEmpty);
  });
}

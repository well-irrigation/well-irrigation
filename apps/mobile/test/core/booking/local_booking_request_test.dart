import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/booking/local_booking_request.dart';

const payload = '{"p_well_id":"well","p_farmer_well_account_id":"farmer",'
    '"p_farm_id":"farm","p_scheduled_start":"2026-10-31T07:00:00Z",'
    '"p_scheduled_end":"2026-10-31T08:00:00Z","p_notes":"الأصل"}';
const context = '{"farmer_name":"أحمد","duration_minutes":60}';

Map<String, Object?> accepted() => {
  'status': 'confirmed',
  'booking_id': 'canonical-booking',
  'public_code': 'B-1',
  'well_id': 'well',
  'scheduled_start': '2026-10-31T07:00:00Z',
  'scheduled_end': '2026-10-31T08:00:00Z',
};

LocalBookingRequest request({
  Map<String, Object?>? response,
  String? replaces,
  String? supersededBy,
}) => LocalBookingRequest(
  accountId: 'account',
  wellId: 'well',
  requestId: 'request-original',
  commandId: 'command-original',
  createdLocalAt: DateTime.parse('2026-10-31T09:12:13.456+03:00'),
  scheduledDay: '2026-10-31',
  payloadJson: payload,
  contextJson: context,
  responseJson: response == null ? null : jsonEncode(response),
  replacesRequestId: replaces,
  supersededByRequestId: supersededBy,
);

void main() {
  test('row round trip preserves original identities, times and literal payload', () {
    final original = request(response: accepted(), replaces: 'older-request');
    final row = original.toRow();
    expect(row['created_local_at'], '2026-10-31T06:12:13.456Z');
    expect(row['payload'], payload);
    expect(row['display_context'], context);
    final restored = LocalBookingRequest.fromRow(row);
    expect(restored.accountId, 'account');
    expect(restored.wellId, 'well');
    expect(restored.requestId, 'request-original');
    expect(restored.commandId, 'command-original');
    expect(restored.createdLocalAt, DateTime.utc(2026, 10, 31, 6, 12, 13, 456));
    expect(restored.scheduledDay, '2026-10-31');
    expect(restored.payloadJson, payload);
    expect(restored.contextJson, context);
    expect(restored.responseJson, original.responseJson);
    expect(restored.payload['p_scheduled_start'], '2026-10-31T07:00:00Z');
    expect(restored.payload['p_scheduled_end'], '2026-10-31T08:00:00Z');
    expect(restored.replacesRequestId, 'older-request');
    expect(restored.toRow(), row);
  });

  test('RPC arguments add the original command without rewriting source data', () {
    final original = request();
    final arguments = original.rpcArguments;
    expect(arguments['p_command_id'], 'command-original');
    expect(arguments['p_notes'], 'الأصل');
    arguments['p_notes'] = 'changed';
    expect(original.payloadJson, payload);
    expect(original.payload['p_notes'], 'الأصل');
    expect(() => original.payload['p_notes'] = 'changed', throwsUnsupportedError);
  });

  test('unacknowledged request has no canonical identity and cannot start', () {
    final original = request();
    expect(original.response, isNull);
    expect(original.isConfirmed, isFalse);
    expect(original.bookingId, isNull);
    expect(original.publicCode, isNull);
    expect(original.canStart, isFalse);
  });

  test('matched acceptance exposes canonical identity but never permits local start', () {
    final original = request(response: accepted());
    expect(original.isConfirmed, isTrue);
    expect(original.bookingId, 'canonical-booking');
    expect(original.publicCode, 'B-1');
    expect(original.canStart, isFalse);
    expect(() => original.response!['status'] = 'rejected', throwsUnsupportedError);
  });

  test('acceptance matches equivalent absolute requested times', () {
    final response = accepted()
      ..['scheduled_start'] = '2026-10-31T10:00:00+03:00'
      ..['scheduled_end'] = '2026-10-31T11:00:00+03:00';
    expect(request(response: response).isConfirmed, isTrue);
  });

  for (final key in ['status', 'booking_id', 'public_code', 'well_id',
    'scheduled_start', 'scheduled_end']) {
    test('missing acceptance $key cannot expose a confirmed booking', () {
      final response = accepted()..remove(key);
      final original = request(response: response);
      expect(original.isConfirmed, isFalse);
      expect(original.bookingId, isNull);
      expect(original.publicCode, isNull);
    });
  }
  for (final (key, value) in <(String, Object?)>[
    ('status', 'accepted'), ('booking_id', ''), ('booking_id', 5),
    ('public_code', ''), ('public_code', false), ('well_id', 'other-well'),
    ('scheduled_start', 'invalid'),
    ('scheduled_start', '2026-10-31T07:01:00Z'),
    ('scheduled_end', '2026-10-31T08:01:00Z'),
  ]) {
    test('inconsistent acceptance $key=$value remains unconfirmed', () {
      final original = request(response: accepted()..[key] = value);
      expect(original.isConfirmed, isFalse);
      expect(original.bookingId, isNull);
      expect(original.publicCode, isNull);
    });
  }

  test('replacement links round trip as data and suppress superseded correction', () {
    final original = request(response: {'status': 'conflict'},
      replaces: 'older-request', supersededBy: 'newer-request');
    final restored = LocalBookingRequest.fromRow(original.toRow());
    expect(restored.replacesRequestId, 'older-request');
    expect(restored.supersededByRequestId, 'newer-request');
    expect(restored.requestId, 'request-original');
    expect(restored.commandId, 'command-original');
    expect(restored.needsCorrection, isFalse);
    expect(restored.correctionAction, isNull);
    expect(restored.canStart, isFalse);
  });

  for (final status in ['conflict', 'rejected']) {
    test('unsuperseded $status offers correction without changing the request', () {
      final original = request(response: {'status': status});
      final before = original.toRow();
      expect(original.needsCorrection, isTrue);
      expect(original.correctionAction, isNotEmpty);
      expect(original.toRow(), before);
      expect(original.canStart, isFalse);
    });
  }
  test('row review marker is read without manufacturing an accepted result', () {
    final restored = LocalBookingRequest.fromRow({
      ...request().toRow(), 'review_required': 1,
    });
    expect(restored.reviewRequired, isTrue);
    expect(restored.isConfirmed, isFalse);
    expect(restored.bookingId, isNull);
  });
}

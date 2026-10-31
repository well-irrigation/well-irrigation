import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/booking_start_receipt.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';

final startedAt = DateTime.parse('2026-10-31T10:00:00+03:00');
CommandEnvelope startCommand({
  String account = 'account',
  String? well = 'well',
  String id = 'original-command',
  Map<String, Object?>? payload,
  Map<String, Object?>? context,
  CommandType type = CommandType.startBookingSession,
}) => CommandEnvelope(
  localId: 'original-local', commandId: id, accountId: account, wellId: well,
  type: type, sequence: 1, occurredAt: startedAt,
  createdLocalAt: DateTime.utc(2026, 10, 31, 6),
  payload: payload ?? {'p_booking_id': 'booking', 'p_crops': ['crop-a', 'crop-b']},
  localContext: context ?? {'manual_start': true, 'booking_id': 'booking'},
);

BookingStartReceiptRequest originalRequest() =>
    BookingStartReceiptRequest.fromCommand(startCommand())!;
Map<String, Object?> receipt() => {
  'session_id': 'session', 'booking_id': 'booking', 'well_id': 'well',
  'session_status': 'open', 'booking_status': 'confirmed',
  'started_at': '2026-10-31T07:00:00Z',
  'operational_end_at': '2026-10-31T07:10:00Z',
  'booked_duration_minutes': 10,
};
Map<String, Object?> wrapper(String state) => {
  'contract': 'get_booking_start_receipt', 'version': 1,
  'retry_authorized': false, 'well_id': 'well', 'booking_id': 'booking',
  'command_id': 'original-command',
  'command_type': 'start_irrigation_session_from_booking',
  'started_at': '2026-10-31T07:00:00Z', 'crops': ['crop-a', 'crop-b'],
  'status': state, 'receipt': state == 'accepted' ? receipt() : null,
};

void main() {
  test('receipt request preserves original identity, instant and crop payload', () {
    final crops = ['crop-a', 'crop-b'];
    final command = startCommand(payload: {'p_booking_id': 'booking', 'p_crops': crops});
    final request = BookingStartReceiptRequest.fromCommand(command)!;
    crops.add('later-change');
    expect(request.accountId, 'account');
    expect(request.startedAt, DateTime.utc(2026, 10, 31, 7));
    expect(request.arguments, {
      'p_well_id': 'well', 'p_booking_id': 'booking',
      'p_command_id': 'original-command',
      'p_started_at': '2026-10-31T07:00:00.000Z',
      'p_crops': ['crop-a', 'crop-b'],
    });
    expect(() => request.crops!.add('mutation'), throwsUnsupportedError);
  });

  test('absent crops remain null rather than an invented crop list', () {
    final request = BookingStartReceiptRequest.fromCommand(
      startCommand(payload: {'p_booking_id': 'booking'}))!;
    expect(request.crops, isNull);
    final response = wrapper('processing')..['crops'] = null;
    expect(parseBookingStartReceipt(request, response),
      isA<BookingStartReceiptResponse>());
  });

  for (final (label, command) in <(String, CommandEnvelope)>[
    ('account', startCommand(account: '')),
    ('well', startCommand(well: null)),
    ('command', startCommand(id: '')),
    ('manual marker', startCommand(context: {})),
    ('false manual marker', startCommand(context: {'manual_start': false, 'booking_id': 'booking'})),
    ('context booking', startCommand(context: {'manual_start': true, 'booking_id': 'other'})),
    ('empty booking', startCommand(payload: {'p_booking_id': ''})),
    ('unknown payload', startCommand(payload: {'p_booking_id': 'booking', 'extra': true})),
    ('crop type', startCommand(payload: {'p_booking_id': 'booking', 'p_crops': 'crop-a'})),
    ('crop member', startCommand(payload: {'p_booking_id': 'booking', 'p_crops': [5]})),
    ('command type', startCommand(type: CommandType.startIrrigationSession,
      payload: {'p_well_id': 'well'})),
  ]) {
    test('unbound $label cannot construct a receipt request', () {
      expect(BookingStartReceiptRequest.fromCommand(command), isNull);
    });
  }

  for (final (state, expected) in [
    ('accepted', BookingStartReceiptState.accepted),
    ('processing', BookingStartReceiptState.processing),
    ('not_found', BookingStartReceiptState.notFound),
    ('unresolved', BookingStartReceiptState.unresolved),
  ]) {
    test('$state remains a distinct read outcome without authorizing retry', () {
      final raw = wrapper(state);
      final result = parseBookingStartReceipt(originalRequest(), raw);
      expect(result, isA<BookingStartReceiptResponse>());
      final response = result as BookingStartReceiptResponse;
      expect(response.state, expected);
      if (state == 'accepted') {
        expect(response.receipt!['session_id'], 'session');
        expect(() => response.receipt!['session_id'] = 'other', throwsUnsupportedError);
      } else {
        expect(response.receipt, isNull);
        expect(response.state, isNot(BookingStartReceiptState.accepted));
      }
      expect(raw['retry_authorized'], isFalse);
    });
  }

  for (final kind in BookingStartReceiptFailureKind.values) {
    test('failure $kind cannot be mistaken for an accepted response', () {
      final BookingStartReceiptRead result = BookingStartReceiptFailure(kind);
      expect(result, isNot(isA<BookingStartReceiptResponse>()));
      expect((result as BookingStartReceiptFailure).kind, kind);
    });
  }

  test('valid receipt verifies equivalent instants and optional command identity', () {
    final value = receipt()
      ..['started_at'] = '2026-10-31T10:00:00+03:00'
      ..['command_id'] = 'original-command'
      ..['command_type'] = 'start_irrigation_session_from_booking';
    expect(validBookingStartReceipt(originalRequest(), value), isTrue);
    expect(parseBookingStartReceipt(originalRequest(), wrapper('accepted')),
      isA<BookingStartReceiptResponse>());
  });

  for (final key in ['contract', 'version', 'retry_authorized', 'well_id',
    'booking_id', 'command_id', 'command_type', 'started_at', 'crops', 'status']) {
    test('missing wrapper $key cannot acknowledge a start', () {
      final raw = wrapper('accepted')..remove(key);
      final result = parseBookingStartReceipt(originalRequest(), raw);
      expect(result, isA<BookingStartReceiptFailure>());
      expect((result as BookingStartReceiptFailure).kind, BookingStartReceiptFailureKind.malformed);
    });
  }

  for (final (key, value) in <(String, Object?)>[
    ('contract', 'other'), ('version', 2), ('version', '1'),
    ('retry_authorized', true), ('well_id', 'other'), ('booking_id', 'other'),
    ('command_id', 'other'), ('command_type', 'execute_pending_booking_start'),
    ('started_at', '2026-10-31T07:00:01Z'),
    ('crops', null), ('crops', ['crop-b', 'crop-a']), ('status', 'unknown'),
  ]) {
    test('mismatched wrapper $key=$value cannot authorize acceptance', () {
      expect(parseBookingStartReceipt(originalRequest(), wrapper('accepted')..[key] = value),
        isA<BookingStartReceiptFailure>());
    });
  }

  for (final key in ['session_id', 'booking_id', 'well_id', 'session_status',
    'booking_status', 'started_at', 'operational_end_at', 'booked_duration_minutes']) {
    test('missing receipt $key is not a valid accepted result', () {
      final value = receipt()..remove(key);
      expect(validBookingStartReceipt(originalRequest(), value), isFalse);
      expect(parseBookingStartReceipt(originalRequest(), wrapper('accepted')..['receipt'] = value),
        isA<BookingStartReceiptFailure>());
    });
  }

  for (final (key, value) in <(String, Object?)>[
    ('session_id', ''), ('booking_id', 'other'), ('well_id', 'other'),
    ('session_status', 'closed'), ('booking_status', 'cancelled'),
    ('started_at', '2026-10-31T07:00:01Z'),
    ('operational_end_at', '2026-10-31T07:11:00Z'),
    ('operational_end_at', 'invalid'), ('booked_duration_minutes', 0),
    ('booked_duration_minutes', -1), ('booked_duration_minutes', 1.5),
    ('booked_duration_minutes', 2147483648), ('command_id', 'other'),
    ('command_type', 'other'),
  ]) {
    test('inconsistent receipt $key=$value cannot establish acceptance', () {
      final valueMap = receipt()..[key] = value;
      expect(validBookingStartReceipt(originalRequest(), valueMap), isFalse);
      expect(parseBookingStartReceipt(originalRequest(), wrapper('accepted')..['receipt'] = valueMap),
        isA<BookingStartReceiptFailure>());
    });
  }

  for (final state in ['processing', 'not_found', 'unresolved']) {
    test('$state cannot smuggle an accepted receipt', () {
      expect(parseBookingStartReceipt(originalRequest(), wrapper(state)..['receipt'] = receipt()),
        isA<BookingStartReceiptFailure>());
    });
  }
  for (final raw in <Object?>[null, 'unavailable', [], 1]) {
    test('unavailable or malformed wrapper $raw remains a failure', () {
      expect(parseBookingStartReceipt(originalRequest(), raw), isA<BookingStartReceiptFailure>());
    });
  }
  test('accepted status without a receipt is malformed rather than success', () {
    expect(parseBookingStartReceipt(originalRequest(), wrapper('accepted')..['receipt'] = null),
      isA<BookingStartReceiptFailure>());
  });
}

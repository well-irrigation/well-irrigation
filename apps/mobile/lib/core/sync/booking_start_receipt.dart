/// قراءة نتيجة بدء الحجز الأصلي؛ لا تمنح إذن إرسال أو تنشئ طلبًا.
library;

import 'dart:convert';

import 'command_envelope.dart';
import 'command_type.dart';

abstract interface class BookingStartReceiptTransport {
  Future<BookingStartReceiptRead> readBookingStartReceipt(
    BookingStartReceiptRequest request,
  );
}

class BookingStartReceiptRequest {
  BookingStartReceiptRequest._(
    this.accountId,
    this.wellId,
    this.bookingId,
    this.commandId,
    this.startedAt,
    List<String>? crops,
  ) : crops = crops == null ? null : List.unmodifiable(crops);
  final String accountId, wellId, bookingId, commandId;
  final DateTime startedAt;
  final List<String>? crops;
  static BookingStartReceiptRequest? fromCommand(CommandEnvelope command) {
    final booking = command.payload['p_booking_id'];
    final crops = command.payload['p_crops'];
    if (command.type != CommandType.startBookingSession ||
        command.localContext['manual_start'] != true ||
        command.localContext['booking_id'] != booking ||
        command.accountId.isEmpty ||
        (command.wellId?.isEmpty ?? true) ||
        command.commandId.isEmpty ||
        booking is! String ||
        booking.isEmpty ||
        command.payload.keys.any(
          (k) => !{'p_booking_id', 'p_crops'}.contains(k),
        ) ||
        (crops != null && (crops is! List || crops.any((v) => v is! String)))) {
      return null;
    }
    return BookingStartReceiptRequest._(
      command.accountId,
      command.wellId!,
      booking,
      command.commandId,
      command.occurredAt.toUtc(),
      crops == null ? null : (crops as List).cast<String>(),
    );
  }

  Map<String, Object?> get arguments => {
    'p_well_id': wellId,
    'p_booking_id': bookingId,
    'p_command_id': commandId,
    'p_started_at': startedAt.toIso8601String(),
    'p_crops': crops,
  };
}

enum BookingStartReceiptState { accepted, processing, notFound, unresolved }

enum BookingStartReceiptFailureKind {
  authentication,
  forbidden,
  network,
  malformed,
}

sealed class BookingStartReceiptRead {
  const BookingStartReceiptRead();
}

class BookingStartReceiptResponse extends BookingStartReceiptRead {
  const BookingStartReceiptResponse(this.state, this.receipt);
  final BookingStartReceiptState state;
  final Map<String, Object?>? receipt;
}

class BookingStartReceiptFailure extends BookingStartReceiptRead {
  const BookingStartReceiptFailure(this.kind);
  final BookingStartReceiptFailureKind kind;
}

bool validBookingStartReceipt(
  BookingStartReceiptRequest request,
  Map<String, Object?> receipt,
) {
  final start = receipt['started_at'];
  final end = receipt['operational_end_at'];
  final duration = receipt['booked_duration_minutes'];
  if (receipt['session_id'] is! String ||
      (receipt['session_id'] as String).isEmpty ||
      receipt['booking_id'] != request.bookingId ||
      receipt['well_id'] != request.wellId ||
      receipt['session_status'] != 'open' ||
      receipt['booking_status'] != 'confirmed' ||
      start is! String ||
      DateTime.tryParse(start)?.toUtc() != request.startedAt ||
      end is! String ||
      duration is! int ||
      duration <= 0 ||
      duration > 2147483647 ||
      (receipt.containsKey('command_id') &&
          receipt['command_id'] != request.commandId) ||
      (receipt.containsKey('command_type') &&
          receipt['command_type'] != CommandType.startBookingSession.rpcName)) {
    return false;
  }
  // Validate the stored time relation only. No money or present-day status is inferred.
  final until = DateTime.tryParse(end);
  return until != null &&
      until.toUtc().difference(request.startedAt) ==
          Duration(minutes: duration);
}

BookingStartReceiptRead parseBookingStartReceipt(
  BookingStartReceiptRequest request,
  Object? raw,
) {
  const invalid = BookingStartReceiptFailure(
    BookingStartReceiptFailureKind.malformed,
  );
  if (raw is! Map ||
      raw['contract'] != 'get_booking_start_receipt' ||
      raw['version'] is! int ||
      raw['version'] != 1 ||
      raw['retry_authorized'] != false ||
      raw['well_id'] != request.wellId ||
      raw['booking_id'] != request.bookingId ||
      raw['command_id'] != request.commandId ||
      raw['command_type'] != CommandType.startBookingSession.rpcName ||
      raw['started_at'] is! String ||
      DateTime.tryParse(raw['started_at'] as String)?.toUtc() !=
          request.startedAt ||
      !raw.containsKey('crops') ||
      jsonEncode(raw['crops']) != jsonEncode(request.crops)) {
    return invalid;
  }
  final state = switch (raw['status']) {
    'accepted' => BookingStartReceiptState.accepted,
    'processing' => BookingStartReceiptState.processing,
    'not_found' => BookingStartReceiptState.notFound,
    'unresolved' => BookingStartReceiptState.unresolved,
    _ => null,
  };
  if (state == null) return invalid;
  final receipt = raw['receipt'];
  if (state != BookingStartReceiptState.accepted) {
    return receipt == null ? BookingStartReceiptResponse(state, null) : invalid;
  }
  if (receipt is! Map<String, dynamic> ||
      !validBookingStartReceipt(request, receipt)) {
    return invalid;
  }
  return BookingStartReceiptResponse(
    state,
    Map<String, Object?>.unmodifiable(receipt),
  );
}

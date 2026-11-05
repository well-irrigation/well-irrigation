import 'command_envelope.dart';
import 'command_type.dart';

abstract interface class OperationalStartReceiptTransport {
  Future<OperationalStartReceiptRead> readOperationalStartReceipt(
    OperationalStartReceiptRequest request,
  );
}

class OperationalStartReceiptRequest {
  OperationalStartReceiptRequest._(this.accountId, this.wellId, this.commandId);
  final String accountId, wellId, commandId;
  static OperationalStartReceiptRequest? fromCommand(CommandEnvelope c) {
    if (c.type != CommandType.startOperationalSession ||
        c.accountId.trim().isEmpty ||
        (c.wellId?.trim().isEmpty ?? true) ||
        c.commandId.trim().isEmpty) {
      return null;
    }
    return OperationalStartReceiptRequest._(
      c.accountId,
      c.wellId!,
      c.commandId,
    );
  }

  Map<String, Object?> get arguments => {
    'p_well_id': wellId,
    'p_command_id': commandId,
    'p_expected_command_type': 'start_operational_session',
  };
}

enum OperationalStartReceiptState {
  accepted,
  processing,
  notFound,
  unresolved,
  rejected,
}

enum OperationalStartReceiptFailureKind {
  authentication,
  forbidden,
  network,
  malformed,
  unavailable,
}

sealed class OperationalStartReceiptRead {
  const OperationalStartReceiptRead();
}

class OperationalStartReceiptResponse extends OperationalStartReceiptRead {
  const OperationalStartReceiptResponse(this.state, this.receipt);
  final OperationalStartReceiptState state;
  final Map<String, Object?>? receipt;
}

class OperationalStartReceiptFailure extends OperationalStartReceiptRead {
  const OperationalStartReceiptFailure(this.kind);
  final OperationalStartReceiptFailureKind kind;
}

bool validOperationalStartReceipt(
  OperationalStartReceiptRequest request,
  Map<String, Object?> receipt,
) =>
    receipt['id'] is String &&
    (receipt['id'] as String).trim().isNotEmpty &&
    receipt['occurrence_command_id'] == request.commandId;
OperationalStartReceiptRead parseOperationalStartReceipt(
  OperationalStartReceiptRequest request,
  Object? raw,
) {
  const invalid = OperationalStartReceiptFailure(
    OperationalStartReceiptFailureKind.malformed,
  );
  if (raw is! Map ||
      raw['contract'] != 'get_operational_start_receipt' ||
      raw['version'] is! int ||
      raw['version'] != 1 ||
      raw['well_id'] != request.wellId ||
      raw['command_id'] != request.commandId ||
      raw['command_type'] != 'start_operational_session' ||
      raw['retry_authorized'] != false ||
      !raw.containsKey('receipt')) {
    return invalid;
  }
  final state = switch (raw['status']) {
    'accepted' => OperationalStartReceiptState.accepted,
    'processing' => OperationalStartReceiptState.processing,
    'not_found' => OperationalStartReceiptState.notFound,
    'unresolved' => OperationalStartReceiptState.unresolved,
    'rejected' => OperationalStartReceiptState.rejected,
    _ => null,
  };
  if (state == null) return invalid;
  final receipt = raw['receipt'];
  if (state == OperationalStartReceiptState.rejected) {
    if (receipt is! Map<String, dynamic> ||
        receipt['status'] != 'rejected' ||
        receipt['reason'] is! String ||
        (receipt['reason'] as String).trim().isEmpty ||
        receipt.containsKey('id') ||
        receipt.containsKey('session_id') ||
        (receipt.containsKey('well_id') &&
            receipt['well_id'] != request.wellId) ||
        (receipt.containsKey('command_id') &&
            receipt['command_id'] != request.commandId) ||
        (receipt.containsKey('command_type') &&
            receipt['command_type'] != 'start_operational_session') ||
        (receipt.containsKey('occurrence_command_id') &&
            receipt['occurrence_command_id'] != request.commandId)) {
      return invalid;
    }
    return OperationalStartReceiptResponse(
      state,
      Map<String, Object?>.unmodifiable(receipt),
    );
  }
  if (state != OperationalStartReceiptState.accepted) {
    return receipt == null
        ? OperationalStartReceiptResponse(state, null)
        : invalid;
  }
  if (receipt is! Map<String, dynamic> ||
      !validOperationalStartReceipt(request, receipt)) {
    return invalid;
  }
  return OperationalStartReceiptResponse(
    state,
    Map<String, Object?>.unmodifiable(receipt),
  );
}

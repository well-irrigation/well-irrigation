import 'dart:convert';

import 'command_envelope.dart';
import 'command_type.dart';

/// Recovery support means a matching public receipt contract exists.
/// Adhoc and booking starts have different proof requirements and stay excluded.
bool isRecoverySupportedStartType(CommandType type) =>
    type == CommandType.startOperationalSession ||
    type == CommandType.startIrrigationSession;

abstract interface class OperationalStartReceiptTransport {
  Future<OperationalStartReceiptRead> readOperationalStartReceipt(
    OperationalStartReceiptRequest request,
  );
}

class OperationalStartReceiptRequest {
  OperationalStartReceiptRequest._(
    this.accountId,
    this.wellId,
    this.commandId,
    this.commandType,
  );
  final String accountId, wellId, commandId;
  final CommandType commandType;
  bool get isHistorical => commandType == CommandType.startIrrigationSession;
  static OperationalStartReceiptRequest? fromCommand(CommandEnvelope c) {
    if (!isRecoverySupportedStartType(c.type) ||
        c.accountId.trim().isEmpty ||
        (c.wellId?.trim().isEmpty ?? true) ||
        c.commandId.trim().isEmpty) {
      return null;
    }
    return OperationalStartReceiptRequest._(
      c.accountId,
      c.wellId!,
      c.commandId,
      c.type,
    );
  }

  Map<String, Object?> get arguments => {
    'p_well_id': wellId,
    'p_command_id': commandId,
    'p_expected_command_type': commandType.rpcName,
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
  const OperationalStartReceiptResponse(
    this.state,
    this.receipt, {
    this.envelope,
  });
  final OperationalStartReceiptState state;
  final Map<String, Object?>? receipt;

  /// Validated wire association. Bare legacy {id} is not a command binding.
  /// The parser copies only validated contract fields, never a fabricated occurrence.
  final Map<String, Object?>? envelope;
}

class OperationalStartReceiptFailure extends OperationalStartReceiptRead {
  const OperationalStartReceiptFailure(this.kind);
  final OperationalStartReceiptFailureKind kind;
}

bool validOperationalStartReceipt(
  OperationalStartReceiptRequest request,
  Map<String, Object?> receipt,
) {
  if (receipt['id'] is! String || (receipt['id'] as String).trim().isEmpty) {
    return false;
  }
  if (request.isHistorical) {
    return receipt.length == 1 &&
        receipt['id'] == (receipt['id'] as String).trim();
  }
  return receipt['occurrence_command_id'] == request.commandId;
}

/// Historical acceptance must retain the actual validated receipt envelope.
/// A mapping or a stored bare UUID alone never substitutes for this read.
bool validOperationalStartEvidence(
  OperationalStartReceiptRequest request,
  Map<String, Object?> receipt,
  Map<String, Object?>? envelope,
) {
  if (!validOperationalStartReceipt(request, receipt)) return false;
  if (!request.isHistorical) return true;
  if (envelope == null) return false;
  final parsed = parseOperationalStartReceipt(request, envelope);
  return parsed is OperationalStartReceiptResponse &&
      parsed.state == OperationalStartReceiptState.accepted &&
      jsonEncode(parsed.receipt) == jsonEncode(receipt);
}

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
      raw['command_type'] != request.commandType.rpcName ||
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
  OperationalStartReceiptResponse response(
    OperationalStartReceiptState state,
    Map<String, Object?>? receipt,
  ) {
    final frozen = receipt == null
        ? null
        : Map<String, Object?>.unmodifiable(receipt);
    return OperationalStartReceiptResponse(
      state,
      frozen,
      envelope: Map<String, Object?>.unmodifiable({
        'contract': raw['contract'],
        'version': raw['version'],
        'well_id': raw['well_id'],
        'command_id': raw['command_id'],
        'command_type': raw['command_type'],
        'retry_authorized': raw['retry_authorized'],
        'status': raw['status'],
        'receipt': frozen,
      }),
    );
  }

  final receipt = raw['receipt'];
  if (state == OperationalStartReceiptState.rejected) {
    // The sealed legacy writer persisted SQL NULL request facts. The public
    // reader explicitly cannot prove terminal non-execution for this type.
    if (request.isHistorical) return invalid;
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
            receipt['command_type'] != request.commandType.rpcName) ||
        (receipt.containsKey('occurrence_command_id') &&
            receipt['occurrence_command_id'] != request.commandId)) {
      return invalid;
    }
    return response(state, Map<String, Object?>.from(receipt));
  }
  if (state != OperationalStartReceiptState.accepted) {
    return receipt == null ? response(state, null) : invalid;
  }
  if (receipt is! Map<String, dynamic> ||
      !validOperationalStartReceipt(request, receipt)) {
    return invalid;
  }
  return response(state, Map<String, Object?>.from(receipt));
}

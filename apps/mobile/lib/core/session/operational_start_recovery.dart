import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/operations_repository.dart';
import '../sync/command_envelope.dart';
import '../sync/command_intent_policy.dart';
import '../sync/command_type.dart';
import '../sync/operational_start_receipt.dart';
import '../sync/outbox_store.dart';
import '../sync/sync_status.dart';
import '../sync/start_recovery_policy.dart';
import 'server_control_snapshot.dart';

enum OperationalStartRecoveryState {
  serverSessionFound,
  stillProcessing,
  offline,
  unresolvedManualReview,
  resolved,
}

enum OperationalStartRecoveryIssue {
  uncertain,
  scope,
  terminalRejected,
  canonicalDisagreement,
  unavailable,
  dependentUnresolved,
}

/// دليل قراءة؛ لا يعطي إذن إعادة إرسال ولا يغيّر الأمر أو نية الإيقاف.
/// رمز الاعتماد الخاص لا تنشئه الواجهة من معرّف جلسة أو JSON.
class OperationalStartRecoveryObservation {
  const OperationalStartRecoveryObservation._(
    this.state, {
    this.issue = OperationalStartRecoveryIssue.uncertain,
    this.session,
    this._command,
    this._receipt,
    this._receiptEnvelope,
    this._evidence,
    this._canonical,
  });

  final OperationalStartRecoveryState state;
  final OperationalStartRecoveryIssue issue;
  final SessionHistoryItem? session;
  final CommandEnvelope? _command;
  final Map<String, Object?>? _receipt;
  final Map<String, Object?>? _receiptEnvelope;
  final String? _evidence;
  final ServerControlSnapshot? _canonical;
  bool get restoredCurrentSession => session != null || _canonical != null;
  bool get canResolveRejected =>
      issue == OperationalStartRecoveryIssue.terminalRejected &&
      _command != null &&
      _receipt != null &&
      _evidence != null;
  bool get canAdopt =>
      state == OperationalStartRecoveryState.serverSessionFound;
}

/// يقرأ إيصال الأمر الأصلي والحالة الحالية، ثم يستخدم التسوية الذرية القائمة.
/// لا يملك dispatch أو enqueue أو حذف/إغلاق المحاولة أو تبنّي جلسة مختلفة.
class OperationalStartRecovery {
  OperationalStartRecovery({
    required this._store,
    required this._transport,
    required this._repository,
    required this._currentAccountId,
  });

  final OutboxStore _store;
  final OperationalStartReceiptTransport? _transport;
  final OperationsRepository _repository;
  final String? Function() _currentAccountId;
  final _adoptions =
      <(String, String, String), Future<OperationalStartRecoveryObservation>>{};

  OperationalStartRecoveryObservation _unresolved([
    OperationalStartRecoveryIssue issue =
        OperationalStartRecoveryIssue.uncertain,
  ]) => OperationalStartRecoveryObservation._(
    OperationalStartRecoveryState.unresolvedManualReview,
    issue: issue,
  );

  bool _owns(String account) =>
      account.isNotEmpty && _currentAccountId() == account;

  Future<String?> _farmerId(CommandEnvelope c) async {
    final raw = c.payload['p_farmer_well_account_id'];
    if (raw is String && raw.trim().isNotEmpty) return raw;
    if (raw is! Map ||
        raw.length != 2 ||
        raw[r'$kind'] != EntityKind.farmerWellAccount.storageValue ||
        raw[r'$ref'] is! String) {
      return null;
    }
    return (await _store.mapping(
      c.accountId,
      raw[r'$ref'] as String,
      EntityKind.farmerWellAccount,
    ))?.serverId;
  }

  Future<bool> isLegacyRoot({
    required String accountId,
    required String sessionLocalId,
  }) async =>
      _owns(accountId) &&
      (await _store.commandByLocalId(accountId, sessionLocalId))?.type ==
          CommandType.startIrrigationSession;

  final _repairs =
      <(String, String, String), Future<OperationalStartRecoveryObservation>>{};
  Future<OperationalStartRecoveryObservation> repairLegacyStart({
    required String accountId,
    required String wellId,
    required String sessionLocalId,
    bool Function()? isContextCurrent,
  }) {
    final key = (accountId, wellId, sessionLocalId);
    final running = _repairs[key];
    if (running != null) return running;
    final task = _repairLegacyStart(
      accountId,
      wellId,
      sessionLocalId,
      isContextCurrent ?? () => true,
    );
    _repairs[key] = task;
    return task.whenComplete(() => _repairs.remove(key));
  }

  Future<OperationalStartRecoveryObservation> _repairLegacyStart(
    String account,
    String well,
    String local,
    bool Function() contextCurrent,
  ) async {
    bool owns() => _owns(account) && contextCurrent();
    try {
      if (!owns() ||
          well.trim().isEmpty ||
          local.trim().isEmpty ||
          _store is! StartRecoveryLocalStore) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      final storage = _store as StartRecoveryLocalStore;
      final before = await storage.readStartRecovery(account);
      final root = before.commands.where((c) => c.localId == local).firstOrNull;
      if (root == null ||
          root.accountId != account ||
          root.wellId != well ||
          root.payload['p_well_id'] != well ||
          root.type != CommandType.startIrrigationSession) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      if (before.policy.root(local) == StartRecoveryDisposition.legacyRetired) {
        final saved =
            jsonDecode(before.records[startRecoveryKey(local)]!) as Map;
        return OperationalStartRecoveryObservation._(
          OperationalStartRecoveryState.resolved,
          canonical: saved['server_snapshot'] == null
              ? null
              : ServerControlSnapshot.fromJson(
                  (saved['server_snapshot'] as Map).cast<String, dynamic>(),
                ),
        );
      }
      if (root.status == CommandStatus.confirmed) return _unresolved();
      final current = await _repository.fetchCurrentOperationalSession(well);
      if (!owns()) return _unresolved(OperationalStartRecoveryIssue.scope);
      await storage.startRecoveryTransaction(
        account,
        (snapshot) => retireLegacyStartWrite(
          snapshot: snapshot,
          observed: root,
          evidence: before.evidence(local),
          wellId: well,
          current: current,
          at: DateTime.now(),
          isCurrent: owns,
        ),
      );
      if (!owns()) return _unresolved(OperationalStartRecoveryIssue.scope);
      return OperationalStartRecoveryObservation._(
        OperationalStartRecoveryState.resolved,
        session: current?.session,
      );
    } on SocketException {
      return const OperationalStartRecoveryObservation._(
        OperationalStartRecoveryState.offline,
      );
    } on TimeoutException {
      return const OperationalStartRecoveryObservation._(
        OperationalStartRecoveryState.offline,
      );
    } on PostgrestException {
      return const OperationalStartRecoveryObservation._(
        OperationalStartRecoveryState.offline,
      );
    } on Object {
      return _unresolved(OperationalStartRecoveryIssue.unavailable);
    }
  }

  Future<OperationalStartRecoveryObservation> check({
    required String accountId,
    required String wellId,
    required String sessionLocalId,
  }) async {
    if (!_owns(accountId)) {
      return _unresolved(OperationalStartRecoveryIssue.scope);
    }
    if (wellId.trim().isEmpty) {
      return _unresolved(OperationalStartRecoveryIssue.scope);
    }
    if (sessionLocalId.trim().isEmpty) {
      return _unresolved(OperationalStartRecoveryIssue.scope);
    }
    try {
      await _store.initialize();
      final saved = await _store.commandByLocalId(accountId, sessionLocalId);
      if (saved == null) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      if (saved.accountId != accountId) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      if (saved.wellId != wellId) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      final payloadWell = saved.payload['p_well_id'];
      if (payloadWell != wellId) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      if (!isRecoverySupportedStartType(saved.type)) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      final command = freezeDispatchCommand(saved);
      final record = await _store.readBundle(
        accountId,
        humanCommandIntentBundleKey(command.localId),
      );
      final human =
          classifyCommandIntent(
            command,
            records: {humanCommandIntentBundleKey(command.localId): ?record},
          ).origin ==
          CommandIntentOrigin.provenHuman;
      if (!human) {
        return _unresolved();
      }
      final snapshot = _store is StartRecoveryLocalStore
          ? await (_store as StartRecoveryLocalStore).readStartRecovery(
              accountId,
            )
          : null;
      final evidence = snapshot?.evidence(command.localId);
      if (snapshot?.policy.root(command.localId) ==
          StartRecoveryDisposition.resolvedNonExecution) {
        return const OperationalStartRecoveryObservation._(
          OperationalStartRecoveryState.resolved,
        );
      }
      if (snapshot?.policy.root(command.localId) ==
          StartRecoveryDisposition.conflict) {
        return _unresolved();
      }
      final request = OperationalStartReceiptRequest.fromCommand(command);
      final reader = _transport;
      if (request == null) {
        return _unresolved(OperationalStartRecoveryIssue.unavailable);
      }
      if (reader == null) {
        return _unresolved(OperationalStartRecoveryIssue.unavailable);
      }
      if (!_owns(accountId)) {
        return _unresolved(OperationalStartRecoveryIssue.unavailable);
      }
      final result = await reader
          .readOperationalStartReceipt(request)
          .timeout(const Duration(seconds: 20));
      if (!_owns(accountId)) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      if (result is OperationalStartReceiptFailure) {
        return result.kind == OperationalStartReceiptFailureKind.network
            ? const OperationalStartRecoveryObservation._(
                OperationalStartRecoveryState.offline,
              )
            : _unresolved();
      }
      if (result is! OperationalStartReceiptResponse) {
        return _unresolved();
      }
      if (result.state == OperationalStartReceiptState.processing) {
        return const OperationalStartRecoveryObservation._(
          OperationalStartRecoveryState.stillProcessing,
        );
      }
      if (result.state == OperationalStartReceiptState.rejected) {
        if (result.receipt == null || evidence == null) {
          return _unresolved();
        }
        final envelope = <String, Object?>{
          'contract': 'get_operational_start_receipt',
          'version': 1,
          'well_id': wellId,
          'command_id': command.commandId,
          'command_type': request.commandType.rpcName,
          'retry_authorized': false,
          'status': 'rejected',
          'receipt': result.receipt,
        };
        final valid = parseOperationalStartReceipt(request, envelope);
        if (valid is! OperationalStartReceiptResponse ||
            valid.state != OperationalStartReceiptState.rejected) {
          return _unresolved();
        }
        try {
          if (snapshot == null) {
            return _unresolved(OperationalStartRecoveryIssue.unavailable);
          }
          resolveRejectedStartWrite(
            snapshot: snapshot,
            observed: command,
            observedEvidence: evidence,
            receiptEnvelope: envelope,
            reason: 'review_preview',
            resolvedAt: DateTime.now().toUtc(),
            confirmed: true,
            isCurrent: () => _owns(accountId),
          );
        } on Object {
          return _unresolved(OperationalStartRecoveryIssue.dependentUnresolved);
        }
        return OperationalStartRecoveryObservation._(
          OperationalStartRecoveryState.unresolvedManualReview,
          issue: OperationalStartRecoveryIssue.terminalRejected,
          command: command,
          receipt: freezeDispatchReceipt(envelope),
          evidence: evidence,
        );
      }
      final receipt = result.receipt;
      if (result.state != OperationalStartReceiptState.accepted ||
          receipt == null ||
          !validOperationalStartEvidence(request, receipt, result.envelope)) {
        return _unresolved();
      }
      final binding = await _store.mapping(
        accountId,
        command.localId,
        EntityKind.session,
      );
      if ((binding != null &&
              (binding.localId != command.localId ||
                  binding.kind != EntityKind.session ||
                  binding.serverId != receipt['id'])) ||
          (command.serverResponse != null &&
              command.serverResponse!['id'] != receipt['id'])) {
        return _unresolved(OperationalStartRecoveryIssue.canonicalDisagreement);
      }
      if (!_owns(accountId)) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      final canonical = await _repository
          .fetchSessionDetail(receipt['id'] as String)
          .timeout(const Duration(seconds: 20));
      if (!_owns(accountId)) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      final session = canonical.session;
      final farmer = await _farmerId(command);
      if (!_owns(accountId)) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      if (session.id != receipt['id']) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      if (session.wellId != wellId) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      if (farmer == null) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      if (session.farmerAccountId != farmer) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      final control = ServerControlSnapshot.fromDetail(canonical);
      if (snapshot == null || evidence == null) {
        return _unresolved(OperationalStartRecoveryIssue.unavailable);
      }
      try {
        adoptStartPerspectiveWrite(
          snapshot: snapshot,
          observed: command,
          observedEvidence: evidence,
          receipt: receipt,
          validatedEnvelope: result.envelope,
          canonical: control,
          reason: 'explicit_same_identity_adoption',
          at: DateTime.now().toUtc(),
          isCurrent: () => _owns(accountId),
        );
      } on Object {
        return _unresolved(OperationalStartRecoveryIssue.canonicalDisagreement);
      }
      if (!_owns(accountId)) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      return OperationalStartRecoveryObservation._(
        OperationalStartRecoveryState.serverSessionFound,
        session: session,
        command: command,
        receipt: freezeDispatchReceipt(receipt),
        receiptEnvelope: freezeDispatchReceipt(result.envelope),
        evidence: evidence,
        canonical: control,
      );
    } on FormatException {
      return _unresolved();
    } on TimeoutException {
      return const OperationalStartRecoveryObservation._(
        OperationalStartRecoveryState.offline,
      );
    } on SocketException {
      return const OperationalStartRecoveryObservation._(
        OperationalStartRecoveryState.offline,
      );
    } on AuthException {
      return _unresolved(OperationalStartRecoveryIssue.scope);
    } on PostgrestException catch (error) {
      if (const {
        '42501',
        '28000',
        'PGRST301',
        'PGRST302',
      }.contains(error.code)) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      return const OperationalStartRecoveryObservation._(
        OperationalStartRecoveryState.offline,
      );
    } on Object {
      return _unresolved(OperationalStartRecoveryIssue.unavailable);
    }
  }

  Future<OperationalStartRecoveryObservation> resolveRejectedStart(
    OperationalStartRecoveryObservation observed, {
    required String reason,
    required bool confirmed,
  }) async {
    final command = observed._command;
    final storage = _store;
    if (!observed.canResolveRejected ||
        command == null ||
        storage is! StartRecoveryLocalStore ||
        !_owns(command.accountId)) {
      return _unresolved();
    }
    try {
      final applied = await (storage as StartRecoveryLocalStore)
          .startRecoveryTransaction(
            command.accountId,
            (snapshot) => resolveRejectedStartWrite(
              snapshot: snapshot,
              observed: command,
              observedEvidence: observed._evidence!,
              receiptEnvelope: observed._receipt!,
              reason: reason.trim(),
              resolvedAt: DateTime.now().toUtc(),
              confirmed: confirmed,
              isCurrent: () => _owns(command.accountId),
            ),
          );
      if (!_owns(command.accountId)) {
        return _unresolved(OperationalStartRecoveryIssue.scope);
      }
      return applied
          ? const OperationalStartRecoveryObservation._(
              OperationalStartRecoveryState.resolved,
            )
          : _unresolved();
    } on Object {
      return _unresolved();
    }
  }

  Future<OperationalStartRecoveryObservation> adopt(
    OperationalStartRecoveryObservation observed,
  ) {
    final command = observed._command;
    if (!observed.canAdopt || command == null || observed._receipt == null) {
      return Future.value(_unresolved());
    }
    final key = (command.accountId, command.wellId!, command.localId);
    return _adoptions.putIfAbsent(key, () async {
      try {
        final storage = _store;
        if (storage is! StartRecoveryLocalStore ||
            observed._canonical == null ||
            observed._evidence == null ||
            !_owns(command.accountId)) {
          return _unresolved();
        }
        final applied = await (storage as StartRecoveryLocalStore)
            .startRecoveryTransaction(
              command.accountId,
              (snapshot) => adoptStartPerspectiveWrite(
                snapshot: snapshot,
                observed: command,
                observedEvidence: observed._evidence,
                receipt: observed._receipt,
                validatedEnvelope: observed._receiptEnvelope,
                canonical: observed._canonical,
                reason: 'explicit_same_identity_adoption',
                at: DateTime.now().toUtc(),
                isCurrent: () => _owns(command.accountId),
              ),
            );
        if (applied && _owns(command.accountId)) {
          return OperationalStartRecoveryObservation._(
            OperationalStartRecoveryState.resolved,
            session: observed.session,
          );
        }
        return _unresolved();
      } on Object {
        return _unresolved();
      } finally {
        _adoptions.remove(key);
      }
    });
  }
}

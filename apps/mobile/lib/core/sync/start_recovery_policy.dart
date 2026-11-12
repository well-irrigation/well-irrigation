/// الدليل المحلي للحل لا يثبت تنفيذًا ولا يسمح بإعادة الإرسال.
library;

import 'dart:convert';

import '../session/server_control_snapshot.dart';
import '../api/operations_repository.dart';

import 'command_envelope.dart';
import 'command_intent_policy.dart';
import 'command_type.dart';
import 'command_transport.dart';
import 'operational_start_receipt.dart';
import 'outbox_store.dart';
import 'sync_status.dart';

String startRecoveryCommandFingerprint(CommandEnvelope? c) => jsonEncode([
  dispatchCommandFingerprint(c),
  c?.createdLocalAt.toUtc().toIso8601String(),
]);

const startRecoveryPrefix = 'session.start_recovery.v1/';
String startRecoveryKey(String root) =>
    '$startRecoveryPrefix${Uri.encodeComponent(root)}';
String startRecoveryConflictKey(String root) =>
    '${startRecoveryKey(root)}/conflict';

String startRecoveryLateKey(String root, String local, Object evidence) =>
    '${startRecoveryKey(root)}/evidence/${base64Url.encode(utf8.encode(jsonEncode([local, evidence])))}';

/// ينفذ القرار والمقارنة والكتابة في معاملة واحدة داخل مخزن الحساب.
abstract interface class StartRecoveryLocalStore {
  Future<StartRecoverySnapshot> readStartRecovery(String accountId);
  Future<StartRecoveryPolicy?> currentStartRecoveryPolicy(String accountId);
  Future<T> startRecoveryTransaction<T>(
    String accountId,
    StartRecoveryWrite<T> Function(StartRecoverySnapshot snapshot) decide,
  );
}

class StartRecoveryWrite<T> {
  const StartRecoveryWrite(
    this.result,
    this.values, {
    this.confirmStart,
    this.acceptedReceipt,
    this.isCurrent,
  });
  final CommandEnvelope? confirmStart;
  final Map<String, Object?>? acceptedReceipt;
  final bool Function()? isCurrent;
  final T result;

  /// مفاتيح جديدة فقط؛ لا overwrite حتى للقيم المتطابقة.
  final Map<String, String> values;
}

class StartRecoverySnapshot {
  StartRecoverySnapshot(
    this.accountId,
    this.commands,
    this.records,
    this.mappings,
  );
  final String accountId;
  final List<CommandEnvelope> commands;
  final Map<String, String> records;
  final List<IdMapping> mappings;

  int get sequenceFence {
    final stored = records['sequence_counter'];
    var maximum = stored == null ? 0 : int.parse(stored);
    for (final c in commands) {
      if (c.sequence > maximum) maximum = c.sequence;
    }
    return maximum;
  }

  List<CommandEnvelope> family(String root) {
    final ids = <String>{root};
    var changed = true;
    while (changed) {
      changed = false;
      for (final row in commands) {
        if (ids.contains(row.localId)) continue;
        if (ids.contains(row.aggregateLocalId) ||
            row.prerequisites.any(ids.contains) ||
            row.references.any((r) => ids.contains(r.localId))) {
          changed = ids.add(row.localId) || changed;
        }
      }
    }
    return commands.where((c) => ids.contains(c.localId)).toList()
      ..sort((a, b) => a.localId.compareTo(b.localId));
  }

  String evidence(String root) {
    final rows = family(root);
    final ids = {
      ...rows.map((c) => c.localId),
      ...rows.expand((c) => c.references.map((r) => r.localId)),
    };
    final keys =
        records.keys
            .where(
              (k) =>
                  !k.startsWith(startRecoveryPrefix) &&
                  (ids.any((id) => k.contains(id))),
            )
            .toList()
          ..sort();
    final binds =
        mappings
            .where((m) => ids.contains(m.localId))
            .map(
              (m) => jsonEncode([m.localId, m.kind.storageValue, m.serverId]),
            )
            .toList()
          ..sort();
    return jsonEncode([
      for (final row in rows) startRecoveryCommandFingerprint(row),
      {for (final key in keys) key: records[key]},
      binds,
    ]);
  }

  StartRecoveryPolicy get policy => StartRecoveryPolicy(this);
}

enum StartRecoveryDisposition {
  untouched,
  resolvedNonExecution,
  adoptedServerPerspective,
  legacyRetired,
  conflict,
}

/// السياسة الوحيدة للأصل المحلول وعائلته؛ الفساد يعيد الحجب ولا يفتح أصلًا.
class StartRecoveryPolicy {
  StartRecoveryPolicy(this.snapshot);
  final StartRecoverySnapshot snapshot;

  bool get _unattributableCorruption {
    try {
      for (final e in snapshot.records.entries.where(
        (e) => e.key.startsWith(startRecoveryPrefix),
      )) {
        final tail = e.key.substring(startRecoveryPrefix.length);
        final pieces = tail.split('/');
        if (!(pieces.length == 1 ||
            pieces.length == 2 && pieces.last == 'conflict' ||
            pieces.length == 3 &&
                pieces[1] == 'evidence' &&
                pieces.last.isNotEmpty)) {
          return true;
        }
        final id = Uri.decodeComponent(pieces.first);
        if (id.isEmpty || pieces.first != Uri.encodeComponent(id)) return true;
        final body = jsonDecode(e.value);
        if (body is! Map ||
            body['root_local_id'] != id ||
            body['account_id'] != snapshot.accountId ||
            !snapshot.commands.any(
              (c) => c.localId == id && isRecoverySupportedStartType(c.type),
            )) {
          return true;
        }
      }
      return false;
    } on Object {
      return true;
    }
  }

  Map<String, dynamic>? _event(String root) {
    final raw = snapshot.records[startRecoveryKey(root)];
    return raw == null
        ? null
        : (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  ServerControlSnapshot? control(String rootId) {
    final independent = legacyControlEvent(rootId);
    if (independent != null) {
      return ServerControlSnapshot.fromJson(
        (independent['server_snapshot'] as Map).cast<String, dynamic>(),
      );
    }
    if (root(rootId) != StartRecoveryDisposition.adoptedServerPerspective) {
      return null;
    }
    return ServerControlSnapshot.fromJson(
      (_event(rootId)!['server_snapshot'] as Map).cast<String, dynamic>(),
    );
  }

  String? controlAnchor(String rootId) => control(rootId) == null
      ? null
      : (legacyControlEvent(rootId) ?? _event(rootId))!['resolution_id']
            as String;

  bool mayControl(String rootId) =>
      protectedRoot(rootId) == null ||
      control(rootId)?.endedAt == null && control(rootId) != null;

  String scopedControlKey(String base, String rootId) {
    final anchor = controlAnchor(rootId);
    return anchor == null
        ? base
        : '$base/anchor/${Uri.encodeComponent(anchor)}';
  }

  bool _old(String rootId, String localId) =>
      (_event(rootId)!['isolated_child_ids'] as List).contains(localId);

  StartRecoveryDisposition root(String localId) {
    if (_unattributableCorruption) return StartRecoveryDisposition.conflict;
    final value = snapshot.records[startRecoveryKey(localId)];
    if (value == null) return StartRecoveryDisposition.untouched;
    try {
      final event = jsonDecode(value);
      final command = snapshot.commands
          .where((c) => c.localId == localId)
          .single;
      if (event is Map && event['kind'] == 'legacy_retired') {
        if (event['version'] != 1 ||
            command.type != CommandType.startIrrigationSession ||
            event['account_id'] != snapshot.accountId ||
            event['actor_account_id'] != snapshot.accountId ||
            event['root_local_id'] != localId ||
            event['command_id'] != command.commandId ||
            event['well_id'] != command.wellId ||
            event['original_type'] != command.type.storageValue ||
            event['original_root_fingerprint'] !=
                startRecoveryCommandFingerprint(command) ||
            event['resolution_id'] != 'legacy_retired:${command.commandId}' ||
            event['retired_family_fingerprints'] is! Map ||
            event['retired_family_ids'] is! List ||
            !(event['retired_family_ids'] as List).contains(localId) ||
            event['sequence_fence'] is! int ||
            event['original_evidence'] is! String ||
            DateTime.tryParse(event['resolved_at'] as String? ?? '') == null) {
          return StartRecoveryDisposition.conflict;
        }
        if (event['server_snapshot'] != null) {
          final canonical = ServerControlSnapshot.fromJson(
            (event['server_snapshot'] as Map).cast<String, dynamic>(),
          );
          if (canonical.wellId != command.wellId ||
              canonical.endedAt != null ||
              event['control_payload'] is! Map ||
              event['control_context'] is! Map ||
              event['control_payload']['p_well_id'] != canonical.wellId ||
              event['control_payload']['p_farmer_well_account_id'] !=
                  canonical.farmerId) {
            return StartRecoveryDisposition.conflict;
          }
        }
        final family = (event['retired_family_fingerprints'] as Map)
            .cast<String, String>();
        if (jsonEncode(family.keys.toList()) !=
            jsonEncode(event['retired_family_ids'])) {
          return StartRecoveryDisposition.conflict;
        }
        for (final e in family.entries) {
          final child = snapshot.commands
              .where((c) => c.localId == e.key)
              .single;
          if (child.accountId != snapshot.accountId ||
              child.wellId != command.wellId ||
              startRecoveryCommandFingerprint(child) != e.value) {
            return StartRecoveryDisposition.conflict;
          }
        }
        // Late historical evidence cannot restore operational authority.
        return StartRecoveryDisposition.legacyRetired;
      }
      if (event is Map && event['kind'] == 'adopted_server_perspective') {
        if (event['version'] != 1 ||
            event['account_id'] != snapshot.accountId ||
            event['actor_account_id'] != snapshot.accountId ||
            event['root_local_id'] != localId ||
            event['well_id'] != command.wellId ||
            event['command_id'] != command.commandId ||
            event['confirmed_root'] !=
                startRecoveryCommandFingerprint(command) ||
            event['sequence_fence'] is! int ||
            (event['sequence_fence'] as int) < command.sequence ||
            snapshot.records.containsKey(startRecoveryConflictKey(localId)) ||
            event['reason'] is! String ||
            (event['reason'] as String).trim().isEmpty ||
            DateTime.tryParse(event['resolved_at'] as String? ?? '') == null) {
          return StartRecoveryDisposition.conflict;
        }
        final receipt = (event['validated_receipt'] as Map)
            .cast<String, Object?>();
        final request = OperationalStartReceiptRequest.fromCommand(command);
        final control = ServerControlSnapshot.fromJson(
          (event['server_snapshot'] as Map).cast<String, dynamic>(),
        );
        if (request == null ||
            !validOperationalStartEvidence(
              request,
              receipt,
              event['validated_envelope'] == null
                  ? null
                  : (event['validated_envelope'] as Map)
                        .cast<String, Object?>(),
            ) ||
            receipt['id'] != control.sessionId ||
            control.wellId != command.wellId ||
            !snapshot.mappings.any(
              (m) =>
                  m.localId == localId &&
                  m.kind == EntityKind.session &&
                  m.serverId == control.sessionId,
            )) {
          return StartRecoveryDisposition.conflict;
        }
        final old = (event['child_fingerprints'] as Map).cast<String, String>();
        for (final e in old.entries) {
          if (startRecoveryCommandFingerprint(
                snapshot.commands.where((c) => c.localId == e.key).single,
              ) !=
              e.value) {
            return StartRecoveryDisposition.conflict;
          }
        }
        for (final e in (event['human_and_stop_evidence'] as Map).entries) {
          if (snapshot.records[e.key] != e.value) {
            return StartRecoveryDisposition.conflict;
          }
        }
        if (jsonEncode(event['isolated_child_ids']) !=
            jsonEncode(old.keys.toList())) {
          return StartRecoveryDisposition.conflict;
        }
        return StartRecoveryDisposition.adoptedServerPerspective;
      }
      if (event is! Map ||
          event['version'] != 1 ||
          event['kind'] != 'resolved_non_execution' ||
          event['account_id'] != snapshot.accountId ||
          event['actor_account_id'] != snapshot.accountId ||
          event['root_local_id'] != localId ||
          event['well_id'] != command.wellId ||
          event['command_id'] != command.commandId ||
          event['evidence'] != snapshot.evidence(localId) ||
          event['reason'] is! String ||
          (event['reason'] as String).trim().isEmpty ||
          DateTime.tryParse(event['resolved_at'] as String? ?? '') == null ||
          snapshot.records.containsKey(startRecoveryConflictKey(localId))) {
        return StartRecoveryDisposition.conflict;
      }
      final request = OperationalStartReceiptRequest.fromCommand(command);
      if (request == null) return StartRecoveryDisposition.conflict;
      final parsed = parseOperationalStartReceipt(
        request,
        event['validated_receipt'],
      );
      if (parsed is! OperationalStartReceiptResponse ||
          parsed.state != OperationalStartReceiptState.rejected) {
        return StartRecoveryDisposition.conflict;
      }
      return StartRecoveryDisposition.resolvedNonExecution;
    } on Object {
      return StartRecoveryDisposition.conflict;
    }
  }

  String? protectedRoot(String localId) {
    if (_unattributableCorruption) return localId;
    for (final key in snapshot.records.keys.where(
      (k) =>
          k.startsWith(startRecoveryPrefix) &&
          !k.substring(startRecoveryPrefix.length).contains('/'),
    )) {
      final root = Uri.decodeComponent(
        key.substring(startRecoveryPrefix.length),
      );
      if (snapshot.family(root).any((row) => row.localId == localId) ||
          (_event(root)?['retired_family_ids'] is List &&
              (_event(root)!['retired_family_ids'] as List).contains(
                localId,
              ))) {
        return root;
      }
    }
    return null;
  }

  bool contradicts(String rootId, String localId, Object evidence) {
    if (root(rootId) == StartRecoveryDisposition.adoptedServerPerspective &&
        localId == rootId) {
      final receipt = _event(rootId)!['validated_receipt'];
      if (jsonEncode(evidence) == jsonEncode(receipt)) return false;
      if (evidence is Map &&
          evidence.length == 1 &&
          evidence['session_id'] == control(rootId)?.sessionId) {
        return false;
      }
    }
    if (root(rootId) == StartRecoveryDisposition.adoptedServerPerspective &&
        localId != rootId) {
      final old = snapshot.commands
          .where((c) => c.localId == localId)
          .firstOrNull;
      if (old?.status == CommandStatus.confirmed &&
          old?.serverResponse != null) {
        if (jsonEncode(evidence) == jsonEncode(old!.serverResponse)) {
          return false;
        }
        if (evidence is Map &&
            evidence.length == 1 &&
            evidence['session_id'] ==
                old.serverResponse!['session_charge_id']) {
          return false;
        }
      }
    }
    return true;
  }

  bool mayDispatch(CommandEnvelope command) {
    final parent = protectedRoot(command.localId);
    if (isLegacyControl(localId: command.localId)) return false;
    if (parent == null) return true;
    return root(parent) == StartRecoveryDisposition.adoptedServerPerspective &&
        command.localId != parent &&
        !_old(parent, command.localId) &&
        control(parent)?.endedAt == null;
  }

  bool blocksOperationalStart(CommandEnvelope command) =>
      actionable(command) &&
      !(root(command.localId) ==
              StartRecoveryDisposition.adoptedServerPerspective &&
          control(command.localId)?.endedAt != null);

  bool actionable(CommandEnvelope command) {
    final parent = protectedRoot(command.localId);
    if (parent == null) return true;
    final disposition = root(parent);
    if (disposition == StartRecoveryDisposition.resolvedNonExecution ||
        disposition == StartRecoveryDisposition.legacyRetired) {
      return false;
    }
    if (disposition == StartRecoveryDisposition.adoptedServerPerspective) {
      return !_old(parent, command.localId);
    }
    return true;
  }

  // Independent read-model identity, never an outbox command or old-command mapping.
  static String serverControlId(String session) => 'server-control:$session';
  Map<String, dynamic>? legacyControlEvent(String local) {
    if (_unattributableCorruption) return null;
    for (final c in snapshot.commands) {
      if (root(c.localId) != StartRecoveryDisposition.legacyRetired) continue;
      final e = _event(c.localId)!;
      final raw = e['server_snapshot'];
      if (raw is Map && serverControlId(raw['session_id'] as String) == local) {
        return e;
      }
    }
    return null;
  }

  bool isLegacyControl({required String localId}) =>
      legacyControlEvent(localId) != null;
  List<CommandEnvelope> get controlSources {
    final ids = <String>{};
    final result = <CommandEnvelope>[];
    for (final c in snapshot.commands) {
      if (root(c.localId) != StartRecoveryDisposition.legacyRetired) continue;
      final e = _event(c.localId)!;
      if (e['server_snapshot'] == null) continue;
      final state = ServerControlSnapshot.fromJson(
        (e['server_snapshot'] as Map).cast<String, dynamic>(),
      );
      final id = serverControlId(state.sessionId);
      if (!ids.add(id)) continue;
      // Adapter for existing projection/execution readers only. Never inserted,
      // queued, dispatched, or attributed as acceptance of the historical command.
      result.add(
        CommandEnvelope(
          localId: id,
          commandId: id,
          type: CommandType.startIrrigationSession,
          accountId: snapshot.accountId,
          wellId: state.wellId,
          sequence: e['sequence_fence'] as int,
          occurredAt: state.startedAt,
          createdLocalAt: DateTime.parse(e['resolved_at'] as String),
          status: CommandStatus.confirmed,
          payload: (e['control_payload'] as Map).cast<String, Object?>(),
          localContext: (e['control_context'] as Map).cast<String, Object?>(),
        ),
      );
    }
    return result;
  }

  CommandEnvelope? controlSource(String local) =>
      controlSources.where((c) => c.localId == local).firstOrNull;
  IdMapping? controlMapping(String local) {
    final state = control(local);
    if (!isLegacyControl(localId: local) || state == null) return null;
    return IdMapping(
      localId: local,
      kind: EntityKind.session,
      serverId: state.sessionId,
      resolvedAt: state.startedAt,
    );
  }

  bool mayRecord(String key, String value) {
    if (!snapshot.records.keys.any((k) => k.startsWith(startRecoveryPrefix))) {
      return true;
    }
    if (!key.startsWith('session.manual_stop.request.v1/')) return true;
    try {
      final data = jsonDecode(value) as Map;
      final local = data['session_local_id'] as String;
      final parent = protectedRoot(local);
      if (parent == null) return true;
      return mayControl(local) &&
          data['account_id'] == snapshot.accountId &&
          data['well_id'] == control(local)?.wellId &&
          data['control_anchor'] == controlAnchor(local) &&
          key ==
              scopedControlKey(
                'session.manual_stop.request.v1/${Uri.encodeComponent(data['well_id'] as String)}/${Uri.encodeComponent(local)}',
                local,
              );
    } on Object {
      return false;
    }
  }

  bool mayCreate(CommandEnvelope command) {
    if (_unattributableCorruption ||
        isLegacyControl(localId: command.localId)) {
      return false;
    }
    final ancestors = {
      command.aggregateLocalId,
      ...command.prerequisites,
      ...command.references.map((r) => r.localId),
    };
    for (final id in ancestors.whereType<String>()) {
      final anchor = legacyControlEvent(id);
      if (anchor == null) continue;
      final state = control(id)!;
      final target = command.payload['p_session_id'];
      if (command.wellId != state.wellId ||
          command.accountId != snapshot.accountId ||
          command.sequence <= (anchor['sequence_fence'] as int) ||
          command.occurredAt.isBefore(state.segments.last.startedAt) ||
          !(target == state.sessionId ||
              target is Map &&
                  target[r'$ref'] == id &&
                  target[r'$kind'] == 'session')) {
        return false;
      }
    }
    for (final row in snapshot.commands.where(
      (row) => ancestors.contains(row.localId),
    )) {
      final parent = protectedRoot(row.localId);
      if (parent == null) continue;
      final canonical = control(parent);
      if (canonical == null ||
          canonical.endedAt != null ||
          (row.localId != parent && _old(parent, row.localId)) ||
          command.sequence <= (_event(parent)!['sequence_fence'] as int) ||
          command.occurredAt.isBefore(canonical.segments.last.startedAt)) {
        return false;
      }
    }
    return true;
  }
}

Future<StartRecoveryPolicy?> readStartRecoveryPolicy(
  OutboxStore store,
  String accountId,
) async => store is StartRecoveryLocalStore
    ? await (store as StartRecoveryLocalStore).currentStartRecoveryPolicy(
        accountId,
      )
    : null;

/// لا يقبل الرفض المحلي ولا الغياب ولا network كإثبات عدم التنفيذ.
StartRecoveryWrite<bool> resolveRejectedStartWrite({
  required StartRecoverySnapshot snapshot,
  required CommandEnvelope observed,
  required String observedEvidence,
  required Object receiptEnvelope,
  required String reason,
  required DateTime resolvedAt,
  required bool confirmed,
  required bool Function() isCurrent,
}) {
  final key = startRecoveryKey(observed.localId);
  final previous = snapshot.records[key];
  if (previous != null) {
    final old = jsonDecode(previous);
    if (old is Map &&
        old['evidence'] == observedEvidence &&
        old['reason'] == reason &&
        jsonEncode(old['validated_receipt']) == jsonEncode(receiptEnvelope) &&
        snapshot.policy.root(observed.localId) ==
            StartRecoveryDisposition.resolvedNonExecution &&
        isCurrent()) {
      return const StartRecoveryWrite(true, {});
    }
    throw StateError('start_resolution_semantic_conflict');
  }
  if (!confirmed ||
      reason.isEmpty ||
      reason.trim() != reason ||
      !isCurrent() ||
      startRecoveryCommandFingerprint(
            snapshot.commands
                .where((c) => c.localId == observed.localId)
                .single,
          ) !=
          startRecoveryCommandFingerprint(observed) ||
      observed.accountId != snapshot.accountId ||
      observed.type != CommandType.startOperationalSession ||
      observed.status != CommandStatus.review ||
      snapshot.evidence(observed.localId) != observedEvidence) {
    throw StateError('start_resolution_snapshot_changed');
  }
  final request = OperationalStartReceiptRequest.fromCommand(observed);
  final parsed = request == null
      ? null
      : parseOperationalStartReceipt(request, receiptEnvelope);
  final family = snapshot.family(observed.localId);
  final human = snapshot.records[humanCommandIntentBundleKey(observed.localId)];
  if (parsed is! OperationalStartReceiptResponse ||
      parsed.state != OperationalStartReceiptState.rejected ||
      observed.serverResponse != null &&
          (observed.serverResponse!['status'] != 'rejected' ||
              observed.serverResponse!.containsKey('id') ||
              observed.serverResponse!.containsKey('session_id')) ||
      classifyCommandIntent(
            observed,
            records: {humanCommandIntentBundleKey(observed.localId): ?human},
          ).origin !=
          CommandIntentOrigin.provenHuman ||
      snapshot.mappings.any((m) => family.any((c) => c.localId == m.localId)) ||
      family.any(
        (c) =>
            c.localId != observed.localId &&
            (c.accountId != observed.accountId ||
                c.wellId != observed.wellId ||
                c.status != CommandStatus.pending ||
                c.retryCount != 0 ||
                c.lastAttemptAt != null ||
                c.serverResponse != null),
      )) {
    throw StateError('start_resolution_unproven_non_execution');
  }
  // أي سجل محاولة تابع، حتى لو أُعيد status إلى pending، يمنع عزل تنفيذ محتمل.
  final children = family.where((c) => c.localId != observed.localId).toList();
  if (snapshot.records.keys.any(
    (k) => k.contains('dispatch') && children.any((c) => k.contains(c.localId)),
  )) {
    throw StateError('start_resolution_child_attempt');
  }
  return StartRecoveryWrite(true, {
    key: jsonEncode({
      'version': 1,
      'kind': 'resolved_non_execution',
      'resolution_id': 'resolved_non_execution:${observed.commandId}',
      'account_id': snapshot.accountId,
      'actor_account_id': snapshot.accountId,
      'well_id': observed.wellId,
      'root_local_id': observed.localId,
      'command_id': observed.commandId,
      'resolved_at': resolvedAt.toUtc().toIso8601String(),
      'reason': reason,
      'evidence': observedEvidence,
      'validated_receipt': receiptEnvelope,
      'isolated_child_ids': children.map((c) => c.localId).toList(),
    }),
  }, isCurrent: isCurrent);
}

bool _settledCompletion(
  StartRecoverySnapshot snapshot,
  CommandEnvelope child,
  CommandEnvelope root,
  ServerControlSnapshot canonical,
) {
  if (child.type != CommandType.completeIrrigationSession ||
      child.status != CommandStatus.confirmed ||
      child.aggregateLocalId != root.localId ||
      child.accountId != root.accountId ||
      child.wellId != root.wellId ||
      child.serverResponse == null ||
      canonical.endedAt == null) {
    return false;
  }
  final result = child.serverResponse!;
  final target = child.payload['p_session_id'];
  if (target != canonical.sessionId &&
      !(target is Map &&
          target.length == 2 &&
          target[r'$ref'] == root.localId &&
          target[r'$kind'] == 'session')) {
    return false;
  }
  for (final pair in [
    ('command_id', child.commandId),
    ('command_type', child.type.rpcName),
    ('well_id', child.wellId),
  ]) {
    if (result.containsKey(pair.$1) && result[pair.$1] != pair.$2) return false;
  }
  final request = CompletionReceiptRequest(
    accountId: root.accountId,
    wellId: root.wellId!,
    sessionId: canonical.sessionId,
    commandId: child.commandId,
    commandType: child.type.rpcName,
  );
  final parsed = parseCompletionReceipt(request, {
    'contract': 'get_completion_receipt',
    'version': 1,
    'retry_authorized': false,
    'well_id': request.wellId,
    'session_id': request.sessionId,
    'command_id': request.commandId,
    'command_type': request.commandType,
    'status': 'accepted',
    'receipt': result,
  });
  return parsed is CompletionReceiptResponse &&
      parsed.state == CompletionReceiptState.accepted &&
      DateTime.parse(result['ended_at'] as String)
          .isAtSameMomentAs(canonical.endedAt!) &&
      snapshot.mappings.any(
        (m) =>
            m.localId == child.localId &&
            m.kind == EntityKind.sessionCharge &&
            m.serverId == result['session_charge_id'],
      );
}

StartRecoveryWrite<bool> adoptStartPerspectiveWrite({
  required StartRecoverySnapshot snapshot,
  required CommandEnvelope observed,
  required String observedEvidence,
  required Map<String, Object?> receipt,
  Map<String, Object?>? validatedEnvelope,
  required ServerControlSnapshot canonical,
  required String reason,
  required DateTime at,
  required bool Function() isCurrent,
}) {
  final key = startRecoveryKey(observed.localId);
  final previous = snapshot.records[key];
  if (previous != null) {
    final old = jsonDecode(previous) as Map;
    if (snapshot.policy.root(observed.localId) ==
            StartRecoveryDisposition.adoptedServerPerspective &&
        old['evidence'] == observedEvidence &&
        old['reason'] == reason &&
        (observed.type != CommandType.startIrrigationSession ||
            jsonEncode(old['validated_envelope']) ==
                jsonEncode(validatedEnvelope)) &&
        jsonEncode(old['server_snapshot']) == jsonEncode(canonical.toJson()) &&
        jsonEncode(old['validated_receipt']) == jsonEncode(receipt) &&
        isCurrent()) {
      return const StartRecoveryWrite(true, {});
    }
    throw StateError('start_adoption_semantic_conflict');
  }
  final root = snapshot.commands
      .where((c) => c.localId == observed.localId)
      .single;
  final family = snapshot.family(root.localId);
  final binding = snapshot.mappings
      .where((m) => m.localId == root.localId && m.kind == EntityKind.session)
      .firstOrNull;
  final human = snapshot.records[humanCommandIntentBundleKey(root.localId)];
  if (!isCurrent() ||
      reason.trim().isEmpty ||
      observedEvidence != snapshot.evidence(root.localId) ||
      root.accountId != snapshot.accountId ||
      root.wellId != canonical.wellId ||
      receipt['id'] != canonical.sessionId ||
      !canReconcileOperationalStartReceipt(
        observed: observed,
        current: root,
        humanRecord: human,
        mapping: binding,
        receipt: receipt,
        validatedEnvelope: validatedEnvelope,
      )) {
    throw StateError('start_adoption_identity_changed');
  }
  final children = family.where((c) => c.localId != root.localId).toList();
  for (final child in children) {
    if (_settledCompletion(snapshot, child, root, canonical)) continue;
    // لا نعزل تنفيذًا ممكنًا بمجرد أن الحالة الخادمية تبدو سليمة.
    if (child.accountId != root.accountId ||
        child.wellId != root.wellId ||
        child.status != CommandStatus.pending ||
        child.retryCount != 0 ||
        child.lastAttemptAt != null ||
        child.serverResponse != null ||
        snapshot.mappings.any((m) => m.localId == child.localId) ||
        snapshot.records.keys.any(
          (k) => k.contains('dispatch') && k.contains(child.localId),
        )) {
      throw StateError('start_adoption_unsettled_child');
    }
  }
  final confirmed = root.copyWith(
    status: CommandStatus.confirmed,
    serverResponse: receipt,
    clearLastError: true,
  );
  final keys = snapshot.records.keys.where(
    (k) =>
        k == humanCommandIntentBundleKey(root.localId) ||
        k.startsWith('session.manual_stop.request.v1/') &&
            k.contains(Uri.encodeComponent(root.localId)),
  );
  return StartRecoveryWrite(
    true,
    {
      key: jsonEncode({
        'version': 1,
        'kind': 'adopted_server_perspective',
        'resolution_id': 'adopted_server_perspective:${root.commandId}',
        'account_id': snapshot.accountId,
        'actor_account_id': snapshot.accountId,
        'well_id': root.wellId,
        'root_local_id': root.localId,
        'command_id': root.commandId,
        'resolved_at': at.toUtc().toIso8601String(),
        'reason': reason,
        'evidence': observedEvidence,
        'validated_receipt': receipt,
        if (root.type == CommandType.startIrrigationSession)
          'validated_envelope': validatedEnvelope,
        'sequence_fence': snapshot.sequenceFence,
        'confirmed_root': startRecoveryCommandFingerprint(confirmed),
        'server_snapshot': canonical.toJson(),
        'isolated_child_ids': children.map((c) => c.localId).toList(),
        'child_fingerprints': {
          for (final c in children)
            c.localId: startRecoveryCommandFingerprint(c),
        },
        'child_classifications': {
          for (final c in children)
            c.localId: _settledCompletion(snapshot, c, root, canonical)
                ? 'settled_completion'
                : 'isolated_unsent',
        },
        'human_and_stop_evidence': {
          for (final k in keys) k: snapshot.records[k],
        },
      }),
    },
    confirmStart: root,
    acceptedReceipt: receipt,
    isCurrent: isCurrent,
  );
}

/// Product retirement: preserves all historical rows without asserting execution
/// or non-execution. Server truth is a separate control identity, not a receipt.
StartRecoveryWrite<bool> retireLegacyStartWrite({
  required StartRecoverySnapshot snapshot,
  required CommandEnvelope observed,
  required String evidence,
  required String wellId,
  required SessionDetailData? current,
  required DateTime at,
  required bool Function() isCurrent,
}) {
  final policy = snapshot.policy;
  if (!isCurrent()) throw StateError('legacy_retirement_scope_changed');
  if (policy.root(observed.localId) == StartRecoveryDisposition.legacyRetired) {
    return const StartRecoveryWrite(true, {});
  }
  final root = snapshot.commands
      .where((c) => c.localId == observed.localId)
      .single;
  if (policy.root(root.localId) != StartRecoveryDisposition.untouched ||
      root.type != CommandType.startIrrigationSession ||
      root.status == CommandStatus.confirmed ||
      root.accountId != snapshot.accountId ||
      root.wellId != wellId ||
      root.payload['p_well_id'] != wellId ||
      root.commandId.trim().isEmpty ||
      startRecoveryCommandFingerprint(root) !=
          startRecoveryCommandFingerprint(observed) ||
      snapshot.evidence(root.localId) != evidence ||
      snapshot
          .family(root.localId)
          .any(
            (c) => c.accountId != snapshot.accountId || c.wellId != wellId,
          )) {
    throw StateError('legacy_retirement_evidence_changed');
  }
  final canonical = current == null
      ? null
      : ServerControlSnapshot.fromDetail(current);
  if (canonical != null &&
      (canonical.wellId != wellId || canonical.endedAt != null)) {
    throw StateError('legacy_retirement_server_scope');
  }
  final s = current?.session;
  return StartRecoveryWrite(true, {
    startRecoveryKey(root.localId): jsonEncode({
      'version': 1,
      'kind': 'legacy_retired',
      'resolution_id': 'legacy_retired:${root.commandId}',
      'account_id': snapshot.accountId,
      'actor_account_id': snapshot.accountId,
      'root_local_id': root.localId,
      'command_id': root.commandId,
      'original_type': root.type.storageValue,
      'original_root_fingerprint': startRecoveryCommandFingerprint(root),
      'well_id': wellId,
      'resolved_at': at.toUtc().toIso8601String(),
      'original_evidence': evidence,
      'retired_family_fingerprints': {
        for (final c in snapshot.family(root.localId))
          c.localId: startRecoveryCommandFingerprint(c),
      },
      'retired_family_ids': snapshot
          .family(root.localId)
          .map((c) => c.localId)
          .toList(),
      'sequence_fence': snapshot.sequenceFence,
      'server_snapshot': canonical?.toJson(),
      'reason': 'user_repair_from_current_server_state',
      'control_payload': s == null
          ? null
          : {
              'p_well_id': wellId,
              'p_farmer_well_account_id': s.farmerAccountId,
              'p_farm_id': s.farmId,
              'p_pump_id': s.pumpId,
              'p_energy_source': s.energySourceCode,
            },
      'control_context': s == null
          ? null
          : {
              'farmer_name': s.farmerName,
              'farm_name': s.farmName,
              'pump_name': s.pumpName,
            },
    }),
  }, isCurrent: isCurrent);
}

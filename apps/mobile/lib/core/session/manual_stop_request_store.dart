import 'dart:convert';

import '../sync/command_envelope.dart';
import '../sync/command_reference.dart';
import '../sync/command_id_generator.dart';
import '../sync/command_type.dart';
import '../sync/start_recovery_policy.dart';
import '../sync/outbox_store.dart';

/// حقيقة محلية: طلب المشغّل الإيقاف، وليست نتيجة إكمال أو أمرًا لتنفيذه.
class ManualStopRequest {
  const ManualStopRequest._({
    required this.accountId,
    required this.wellId,
    required this.sessionLocalId,
    required this.sessionCommandId,
    required this.serverSessionId,
    required this.requestId,
    required this.requestedAt,
    this.controlAnchor,
  });

  final String accountId;
  final String wellId;
  final String sessionLocalId;
  final String sessionCommandId;
  final String? serverSessionId;
  final String requestId;
  final DateTime requestedAt;
  final String? controlAnchor;

  Map<String, Object?> toJson() => {
    'version': 1,
    if(controlAnchor != null) 'control_anchor':controlAnchor,
    'provenance': 'human_stop_request',
    'account_id': accountId,
    'well_id': wellId,
    'session_local_id': sessionLocalId,
    'session_command_id': sessionCommandId,
    'server_session_id': serverSessionId,
    'request_id': requestId,
    'requested_at': requestedAt.toIso8601String(),
    'source': 'operator_stop_action',
    // ينتظر تقييم الطلب فقط؛ لا يعني أن الجلسة مفتوحة أو تحتاج إكمالًا.
    'state': 'recorded',
  };
}

/// يحفظ طلبًا واحدًا مستقلًا عن أثر الإكمال السابق وحالته المالية.
///
/// تهيئة Outbox مسؤولية المستدعي، كما في قارئ أدلة الأوامر.
/// لا يستدعيه الاسترجاع أو المؤقت أو العامل. الربط اللاحق يجب أن يحصر
/// [recordHumanStopRequest] بمدخل فعل المستخدم الموثوق ويمرر وقت الحدث.
/// وجود source هنا ليس تحقق صلاحيات أو إثباتًا أمنيًا لمصدر المستدعي،
/// ولا يضيف هذا السجل دليلًا بشريًا إلى أي أمر إكمال قديم.
class ManualStopRequestStore {
  ManualStopRequestStore(this._store);

  final OutboxStore _store;

  /// الحساب معزول بواسطة Outbox؛ ترميز الجزأين يمنع التباس حدود الهوية.
  static String keyFor(String wellId, String sessionLocalId) =>
      'session.manual_stop.request.v1/'
      '${Uri.encodeComponent(wellId)}/${Uri.encodeComponent(sessionLocalId)}';

  /// أول كتابة ناجحة تفوز، وليس أصغر توقيت يصل لاحقًا.
  ///
  /// أمر البدء يثبت الهوية فقط، لا أن الجلسة ما زالت مفتوحة. حتى بعد
  /// إكمال مؤكد يبقى الطلب حقيقة تاريخية بلا تصريح بإكمال جديد.
  Future<ManualStopRequest> recordHumanStopRequest({
    required String accountId,
    required String wellId,
    required String sessionLocalId,
    required DateTime requestedAt,
  }) async {
    _checkScope(accountId, wellId, sessionLocalId);
    final session = await _session(accountId, wellId, sessionLocalId);
    final serverId = await _serverId(accountId, sessionLocalId);
    final recovery = await readStartRecoveryPolicy(_store,accountId);
    final anchor = recovery?.controlAnchor(sessionLocalId);
    final candidate = ManualStopRequest._(
      controlAnchor:anchor,
      accountId: accountId,
      wellId: wellId,
      sessionLocalId: sessionLocalId,
      sessionCommandId: session.commandId,
      serverSessionId: serverId,
      requestId: SecureIdGenerator().newId(),
      requestedAt: requestedAt.toUtc(),
    );
    // لا فحص وجود منفصل ثم كتابة؛ الحزمة نفسها تعيد أول قيمة ذريًا.
    // لا أوامر وهمية ولا تسلسل Outbox جديد ولا أثر تشغيلي تابع.
    final writer = _store;
    if (writer is! AtomicLocalRecordStore) {
      throw StateError('atomic_local_record_store_required');
    }
    final saved = await (writer as AtomicLocalRecordStore)
        .insertLocalRecordOnce(
          accountId: accountId,
          key: controlEpochKey(keyFor(wellId, sessionLocalId),anchor),
          value: jsonEncode(candidate.toJson()),
        );
    return _decode(saved, session, serverId);
  }

  /// يستعيد أثر طلب موجود؛ لا ينشئ نية بشرية أثناء الاستئناف أو المزامنة.
  Future<CommandEnvelope> materializeRecordedRequest(
    ManualStopRequest request,
  ) async {
    final accountId = request.accountId,
        well = request.wellId,
        local = request.sessionLocalId;
    final recovery = await readStartRecoveryPolicy(_store,accountId);
    if(request.controlAnchor != recovery?.controlAnchor(local)) throw StateError('isolated_stop_control_epoch');
    final start = await _session(accountId, well, local);
    if (_store is! SessionExecutionStore) {
      throw StateError('manual_stop_atomic_store_required');
    }
    final storage = _store as SessionExecutionStore;
    final prepared = await storage.prepareSessionExecutionCommand(
      accountId: accountId,
      wellId: well,
      sessionLocalId: local,
      type: CommandType.completeIrrigationSession,
      at: request.requestedAt,
      payload: {
        'p_session_id': CommandReference(
          localId: local,
          kind: EntityKind.session,
        ).toJson(),
      },
    );
    return storage.sessionExecutionTransaction<CommandEnvelope>(
      accountId: accountId,
      wellId: well,
      sessionLocalId: local,
      decide: (snapshot) {
        if (snapshot.root?.commandId != request.sessionCommandId) {
          throw StateError('manual_stop_identity_changed');
        }
        final old = snapshot.events
            .where((c) => c.type == CommandType.completeIrrigationSession)
            .toList();
        if (old.length > 1) {
          throw StateError('multiple_completions_require_review');
        }
        final materialized = {
          controlEpochKey(manualStopMaterializationKey(well, local),request.controlAnchor): request.requestId,
        };
        if (old.isNotEmpty) {
          return SessionExecutionWrite(old.single, values: materialized);
        }
        if (request.requestedAt.isBefore(start.occurredAt) ||
            snapshot.events.any(
              (c) => c.occurredAt.isAfter(request.requestedAt),
            )) {
          throw StateError('manual_stop_time_requires_review');
        }
        return SessionExecutionWrite(
          prepared,
          commands: [prepared],
          deferCompletionNotification: true,
          values: {
            ...materialized,
            controlEpochKey('session.completion.v1.$well.$local',request.controlAnchor): jsonEncode({
              'version': 1,
              'provenance': 'session_completion_effect',
              'account_id': accountId,
              'well_id': well,
              'session_local_id': local,
              'completion_local_id': prepared.localId,
              'completion_command_id': prepared.commandId,
              'completed_at': request.requestedAt.toUtc().toIso8601String(),
              'trigger': 'manual_stop',
              'request_id': request.requestId,
            }),
          },
        );
      },
    );
  }

  /// نطاق الحساب فقط، وطلبات لم يثبت ربطها بأمر؛ لا مسح لتاريخ أوامر الجلسات.
  Future<int> recoverRecordedRequests(String accountId) async {
    final recovery = await readStartRecoveryPolicy(_store,accountId);
    var blocked = 0;
    for (final raw in await _store.readLocalValuesByPrefix(
      accountId,
      'session.manual_stop.request.v1/',
    )) {
      try {
        final value = jsonDecode(raw);
        if (value is! Map ||
            value['account_id'] != accountId ||
            value['well_id'] is! String ||
            value['session_local_id'] is! String) {
          blocked++;
          continue;
        }
        final well = value['well_id'] as String,
            local = value['session_local_id'] as String;
        if(recovery?.protectedRoot(local) != null) {
          final state = recovery!.root(local);
          if(state == StartRecoveryDisposition.resolvedNonExecution || state == StartRecoveryDisposition.legacyRetired) continue;
          if(state == StartRecoveryDisposition.conflict) { blocked++; continue; }
          if(value['control_anchor'] != recovery.controlAnchor(local)) continue;
        }
        final done = await _store.readBundle(
          accountId,
          controlEpochKey(manualStopMaterializationKey(well, local),value['control_anchor'] as String?),
        );
        if (done == value['request_id']) continue;
        final request = await read(
          accountId: accountId,
          wellId: well,
          sessionLocalId: local,
        );
        if (request == null) {
          blocked++;
          continue;
        }
        await materializeRecordedRequest(request);
      } on Object {
        blocked++;
      }
    }
    return blocked;
  }

  /// قراءة exact key فقط؛ الغياب لا ينشئ طلبًا أو أثرًا آخر.
  Future<ManualStopRequest?> read({
    required String accountId,
    required String wellId,
    required String sessionLocalId,
  }) async {
    _checkScope(accountId, wellId, sessionLocalId);
    final recovery = await readStartRecoveryPolicy(_store,accountId);
    final anchor = recovery?.controlAnchor(sessionLocalId);
    final saved = await _store.readBundle(
      accountId,
      controlEpochKey(keyFor(wellId, sessionLocalId),anchor),
    );
    if (saved == null) return null;
    final session = await _session(accountId, wellId, sessionLocalId);
    final decoded = _decode(saved, session, await _serverId(accountId, sessionLocalId));
    if(decoded.controlAnchor != anchor) throw const FormatException('invalid_stop_control_anchor');
    return decoded;
  }

  Future<CommandEnvelope> _session(
    String accountId,
    String wellId,
    String localId,
  ) async {
    final row = await _store.commandByLocalId(accountId, localId) ?? (await readStartRecoveryPolicy(_store,accountId))?.controlSource(localId);
    if (row == null ||
        row.accountId != accountId ||
        row.wellId != wellId ||
        row.localId != localId ||
        !_id(row.commandId) ||
        row.type.produces != EntityKind.session ||
        !_id(row.payload[row.type.scopeArgument]) ||
        (row.type.scopeArgument == 'p_well_id' &&
            row.payload['p_well_id'] != wellId)) {
      throw StateError('unproven_manual_stop_session');
    }
    final recovery = await readStartRecoveryPolicy(_store,accountId);
    if(recovery != null && !recovery.mayControl(localId)) throw StateError('resolved_start_child_isolated');
    return row;
  }

  Future<String?> _serverId(String accountId, String localId) async {
    final mapping = await _store.mapping(
      accountId,
      localId,
      EntityKind.session,
    );
    if (mapping == null) return (await readStartRecoveryPolicy(_store,accountId))?.controlMapping(localId)?.serverId;
    if (mapping.localId != localId ||
        mapping.kind != EntityKind.session ||
        !_id(mapping.serverId)) {
      throw StateError('invalid_manual_stop_session_mapping');
    }
    return mapping.serverId;
  }

  static void _checkScope(String account, String well, String session) {
    if (!_id(account) || !_id(well) || !_id(session)) {
      throw ArgumentError('invalid_manual_stop_scope');
    }
  }

  static bool _id(Object? value) =>
      value is String && value.isNotEmpty && value.trim() == value;

  static final _requestId = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  static ManualStopRequest _decode(
    String raw,
    CommandEnvelope session,
    String? currentServerId,
  ) {
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('invalid_manual_stop_record');
    }
    final time = data['requested_at'];
    final at = time is String ? DateTime.tryParse(time) : null;
    final serverId = data['server_session_id'];
    if (data['version'] is! int ||
        data['version'] != 1 ||
        (data['control_anchor'] != null && !_id(data['control_anchor'])) ||
        data['provenance'] != 'human_stop_request' ||
        data['account_id'] != session.accountId ||
        data['well_id'] != session.wellId ||
        data['session_local_id'] != session.localId ||
        data['session_command_id'] != session.commandId ||
        data['source'] != 'operator_stop_action' ||
        data['state'] != 'recorded' ||
        data['request_id'] is! String ||
        !_requestId.hasMatch(data['request_id'] as String) ||
        at == null ||
        !at.isUtc ||
        at.toIso8601String() != time ||
        !data.containsKey('server_session_id') ||
        (serverId != null && (!_id(serverId) || serverId != currentServerId))) {
      throw const FormatException('invalid_manual_stop_record');
    }
    return ManualStopRequest._(
      controlAnchor:data['control_anchor'] as String?,
      accountId: session.accountId,
      wellId: session.wellId!,
      sessionLocalId: session.localId,
      sessionCommandId: session.commandId,
      serverSessionId: serverId as String?,
      requestId: data['request_id'] as String,
      requestedAt: at,
    );
  }
}

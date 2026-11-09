/// تنفيذ الطابور في الذاكرة — للاختبار فقط.
///
/// يطابق سلوك `SqliteOutboxStore` بنفس القيود: فرادة `commandId`،
/// وحجز شرطي، وعزل بالحساب. وجوده يجعل كل منطق المزامنة قابلًا
/// للاختبار بلا هاتف وبلا قاعدة بيانات.
library;

import 'command_id_generator.dart';
import 'command_intent_evidence_reader.dart';
import 'command_intent_policy.dart';

import 'dart:convert';

import 'command_envelope.dart';
import 'command_type.dart';
import 'outbox_store.dart';
import 'outbox_repository.dart';
import 'sync_status.dart';
import 'manual_session_entry.dart';

class InMemoryOutboxStore
    implements
        ManualSessionEntryFollowUpStore,
        SessionCorrectionInsertStore,
        SessionExecutionStore,
        AtomicCommandDispatchStore,
        OutboxStore,
        AtomicLocalRecordStore,
        BookingDispatchStore,
        FarmSelectionStore {
  final Map<String, List<CommandEnvelope>> _commands = {};
  final Map<String, Map<String, IdMapping>> _mappings = {};
  final Map<String, int> _sequences = {};
  final Map<String, DateTime> _lastSync = {};
  final Set<String> _usedCommandIds = {};
  final Map<String, String> _bundles = {};
  final Map<String, CommandEnvelope> _byLocalId = {};
  final Map<String, Set<String>> _byWell = {};
  final _bySession = <(String, String), Set<String>>{};
  final _byServerSession = <(String, String), Set<String>>{};
  final _paymentReads = <(String, String, String), Map<String, Object?>>{};
  bool _closed = false;

  @override
  Future<void> initialize() async {}

  @override
  Future<CommandEnvelope> insert(CommandEnvelope envelope) async {
    _assertOpen();

    if (_usedCommandIds.contains(envelope.commandId)) {
      throw DuplicateCommandIdException(envelope.commandId);
    }

    if (_byLocalId.containsKey(envelope.localId)) {
      throw StateError('duplicate_local_id');
    }
    _usedCommandIds.add(envelope.commandId);
    _commands.putIfAbsent(envelope.accountId, () => []).add(envelope);
    _byLocalId[envelope.localId] = envelope;
    _indexWell(envelope);
    _indexSession(envelope);

    return envelope;
  }

  @override
  Future<String?> readBundle(String accountId, String key) async {
    _assertOpen();
    return _bundles['$accountId::$key'];
  }

  @override
  Future<List<String>> readLocalValuesByPrefix(
    String accountId,
    String prefix,
  ) async {
    _assertOpen();
    final scoped = '$accountId::$prefix';
    return [
      for (final entry in _bundles.entries)
        if (entry.key.startsWith(scoped)) entry.value,
    ];
  }

  @override
  Future<String> insertLocalRecordOnce({
    required String accountId,
    required String key,
    required String value,
  }) => insertBundle(
    accountId: accountId,
    key: key,
    value: value,
    commands: const [],
  );

  @override
  Future<String> insertBundle({
    required String accountId,
    required String key,
    required String value,
    required List<CommandEnvelope> commands,
    Map<String, String> localValues = const {},
    bool Function()? isCurrent,
  }) async {
    _assertOpen();
    final bundleKey = '$accountId::$key';
    final prior = _bundles[bundleKey];
    if (prior != null) return prior;
    final ids = <String>{};
    final locals = <String>{};
    for (final command in commands) {
      if (command.accountId != accountId ||
          !ids.add(command.commandId) ||
          _usedCommandIds.contains(command.commandId) ||
          !locals.add(command.localId) ||
          _byLocalId.containsKey(command.localId)) {
        throw StateError('invalid_bundle');
      }
    }
    for (final command in commands.where((c) => c.type == CommandType.startOperationalSession)) {
      final existing = existingOperationalStart(_commands[accountId] ?? [], command.wellId!,
        sessionBoundLocalIds: {
          for (final m in _mappings[accountId]?.values ?? const <IdMapping>[])
            if (m.kind == EntityKind.session) m.localId,
        });
      if (existing != null) throw ExistingOperationalStart(existing);
    }
    if (isCurrent != null && !isCurrent()) throw StateError('stale_runtime');
    for (final command in commands) {
      _usedCommandIds.add(command.commandId);
      _commands.putIfAbsent(accountId, () => []).add(command);
      _byLocalId[command.localId] = command;
      _indexWell(command);
      _indexSession(command);
    }
    _bundles[bundleKey] = value;
    for (final entry in localValues.entries) {
      _bundles['$accountId::${entry.key}'] = entry.value;
    }
    return value;
  }

  @override
  Future<int> nextSequence(String accountId) async {
    _assertOpen();

    final next = (_sequences[accountId] ?? 0) + 1;
    _sequences[accountId] = next;

    return next;
  }

  @override
  Future<List<CommandEnvelope>> pendingCommands(String accountId) async {
    _assertOpen();

    final rows = (_commands[accountId] ?? const <CommandEnvelope>[])
        .where((row) => row.status != CommandStatus.confirmed)
        .toList();

    rows.sort((a, b) => a.sequence.compareTo(b.sequence));

    return rows;
  }

  @override
  Future<List<FarmCommandRow>> farmCommands({
    required String accountId,
    required String wellId,
    required Object farmer,
    int limit = 50,
    String query = '',
  }) async {
    if (limit < 1 || limit > 100) throw ArgumentError('حد الأراضي غير صالح');
    final rows = <FarmCommandRow>[];
    for (final c in await commandsForWell(accountId, wellId)) {
      if (c.type != CommandType.createFarm ||
          c.status == CommandStatus.review) {
        continue;
      }
      if (query.trim().isNotEmpty &&
          !(c.payload['p_name'] as String).contains(query.trim()) &&
          !(c.payload['p_distinguishing_label'] as String? ?? '').contains(
            query.trim(),
          )) {
        continue;
      }
      final raw = c.payload['p_farmer_well_account_id'];
      String? parent;
      if (raw is Map) {
        parent =
            _mappings[accountId]?[_mappingKey(
                  raw[r'$ref'] as String,
                  EntityKind.farmerWellAccount,
                )]
                ?.serverId;
      }
      if (raw.toString() != farmer.toString() && parent != farmer) continue;
      rows.add(
        FarmCommandRow(
          command: c,
          serverId:
              _mappings[accountId]?[_mappingKey(c.localId, EntityKind.farm)]
                  ?.serverId,
          farmerId: farmer is String
              ? farmer
              : (farmer as Map)[r'$ref'] as String?,
        ),
      );
    }
    rows.sort((a, b) => b.command.sequence.compareTo(a.command.sequence));
    return rows.take(limit).toList();
  }

  List<CommandEnvelope> _bookingRows(String accountId) =>
      (_commands[accountId] ?? <CommandEnvelope>[])
          .where((c) => c.type == CommandType.createBooking)
          .toList();

  @override
  Future<List<CommandEnvelope>> pendingLegacyCommands(String accountId) async =>
      (await pendingCommands(accountId))
          .where((c) => c.type != CommandType.createBooking)
          .toList();

  bool _farmReady(CommandEnvelope c) {
    final raw = c.payload['p_farm_id'];
    if (raw is! Map) return true;
    final id = raw[r'$ref'] as String;
    final p = _byLocalId[id];
    return _mappings[c.accountId]?[_mappingKey(id, EntityKind.farm)] != null ||
        p == null ||
        p.accountId != c.accountId ||
        p.status == CommandStatus.review;
  }

  @override
  Future<List<CommandEnvelope>> bookingCreatesReady(
    String accountId, {
    required DateTime now,
    int limit = 20,
  }) async {
    _assertOpen();
    if (limit < 1 || limit > 20) throw ArgumentError.value(limit, 'limit');
    final all = _bookingRows(accountId);
    final rows = all
        .where(
          (c) =>
              _farmReady(c) &&
              c.status == CommandStatus.pending &&
              (c.nextAttemptAt == null || !c.nextAttemptAt!.isAfter(now)) &&
              !all.any(
                (e) =>
                    e.wellId == c.wellId &&
                    e.sequence < c.sequence &&
                    (e.status == CommandStatus.dispatching ||
                        (e.status == CommandStatus.pending &&
                            e.nextAttemptAt?.isAfter(now) == true)),
              ),
        )
        .toList();
    rows.sort((a, b) {
      final order = a.sequence.compareTo(b.sequence);
      return order == 0 ? a.localId.compareTo(b.localId) : order;
    });
    return rows.take(limit).toList();
  }

  @override
  Future<List<CommandEnvelope>> bookingCreatesStale(
    String accountId, {
    required DateTime before,
    int limit = 20,
  }) async {
    _assertOpen();
    if (limit < 1 || limit > 20) throw ArgumentError.value(limit, 'limit');
    final rows = _bookingRows(accountId)
        .where(
          (c) =>
              c.status == CommandStatus.dispatching &&
              (c.lastAttemptAt == null || !c.lastAttemptAt!.isAfter(before)),
        )
        .toList();
    rows.sort(
      (a, b) => (a.lastAttemptAt ?? DateTime(1970)).compareTo(
        b.lastAttemptAt ?? DateTime(1970),
      ),
    );
    return rows.take(limit).toList();
  }

  @override
  Future<bool> claimBookingCreate(
    String accountId,
    String localId, {
    required DateTime attemptedAt,
  }) async {
    _assertOpen();
    final row = _byLocalId[localId];
    if (row == null ||
        row.accountId != accountId ||
        row.type != CommandType.createBooking ||
        row.status != CommandStatus.pending ||
        row.nextAttemptAt?.isAfter(attemptedAt) == true) {
      return false;
    }
    final all = _bookingRows(accountId);
    if (all.where((c) => c.status == CommandStatus.dispatching).length >= 3 ||
        all.any(
          (c) =>
              c.wellId == row.wellId &&
              (c.status == CommandStatus.dispatching ||
                  (c.status == CommandStatus.pending &&
                      c.sequence < row.sequence)),
        )) {
      return false;
    }
    _update(
      accountId,
      localId,
      (c) => c.copyWith(
        status: CommandStatus.dispatching,
        lastAttemptAt: attemptedAt,
      ),
    );
    return true;
  }

  @override
  Future<bool> finishBookingCreate(
    String accountId,
    String localId, {
    required DateTime claimedAt,
    required CommandStatus status,
    DateTime? nextAttemptAt,
    String? error,
    Map<String, Object?>? response,
    String? entityId,
  }) async {
    _assertOpen();
    final row = _byLocalId[localId];
    if (status == CommandStatus.dispatching) {
      throw ArgumentError('نتيجة غير نهائية للمحاولة');
    }
    if (row == null ||
        row.accountId != accountId ||
        row.type != CommandType.createBooking ||
        row.status != CommandStatus.dispatching ||
        row.lastAttemptAt != claimedAt) {
      return false;
    }
    _update(
      accountId,
      localId,
      (c) => c.copyWith(
        status: status,
        retryCount: c.retryCount + (status == CommandStatus.pending ? 1 : 0),
        nextAttemptAt: nextAttemptAt,
        clearNextAttemptAt: nextAttemptAt == null,
        lastError: error,
        clearLastError: error == null,
        serverResponse: response,
      ),
    );
    if (status == CommandStatus.confirmed && entityId != null) {
      await putMapping(
        accountId,
        IdMapping(
          localId: localId,
          kind: EntityKind.booking,
          serverId: entityId,
          resolvedAt: claimedAt,
        ),
      );
    }
    return true;
  }

  @override
  Future<DateTime?> bookingCreateNextWake(
    String accountId, {
    required DateTime now,
    required Duration staleClaimTimeout,
  }) async {
    DateTime? wake;
    for (final c in _bookingRows(accountId)) {
      if (!_farmReady(c)) continue;
      final next = c.status == CommandStatus.pending
          ? c.nextAttemptAt ?? now
          : c.status == CommandStatus.dispatching
          ? c.lastAttemptAt?.add(staleClaimTimeout) ?? now
          : null;
      if (next != null && (wake == null || next.isBefore(wake))) wake = next;
    }
    return wake;
  }

  @override
  Future<ManualSessionEntryFollowUp?> readManualSessionEntryFollowUp({
    required String accountId,
    required String wellId,
    required String localId,
  }) async {
    _assertOpen();
    // لا انتظار بين القراءات: لقطة واحدة في دورة تنفيذ الذاكرة.
    final command = _byLocalId[localId];
    if (command == null ||
        command.accountId != accountId ||
        command.wellId != wellId) {
      return null;
    }
    final bindings = (_mappings[accountId]?.values ?? const <IdMapping>[])
        .where((m) => m.localId == localId)
        .toList();
    final sessions = bindings
        .where((m) => m.kind == EntityKind.session)
        .toList();
    return manualSessionEntryFollowUpFromSnapshot(
      command,
      boundSessionId: sessions.isEmpty ? null : sessions.single.serverId,
      unsafeBinding:
          bindings.any((m) => m.kind != EntityKind.session) ||
          sessions.length > 1,
    );
  }

  @override
  Future<CommandEnvelope?> commandByLocalId(
    String accountId,
    String localId,
  ) async {
    _assertOpen();

    final row = _byLocalId[localId];
    return row?.accountId == accountId ? row : null;
  }

  @override
  Future<List<CommandEnvelope>> allCommands(String accountId) async {
    _assertOpen();

    final rows = [...?_commands[accountId]];
    rows.sort((a, b) => a.sequence.compareTo(b.sequence));

    return rows;
  }

  void _indexWell(CommandEnvelope command) {
    final root = _byLocalId[command.aggregateLocalId];
    final well =
        command.wellId ??
        command.payload['p_well_id'] as String? ??
        root?.wellId ??
        root?.payload['p_well_id'] as String?;
    if (well != null) {
      _byWell
          .putIfAbsent('${command.accountId}:$well', () => <String>{})
          .add(command.localId);
    }
  }

  @override
  Future<List<CommandEnvelope>> commandsForWell(
    String accountId,
    String wellId,
  ) async {
    _assertOpen();
    final rows = [
      for (final id in _byWell['$accountId:$wellId'] ?? const <String>{})
        _byLocalId[id]!,
    ];
    rows.sort((a, b) => a.sequence.compareTo(b.sequence));
    return rows;
  }

  void _indexSession(CommandEnvelope command) => _bySession
      .putIfAbsent((
        command.accountId,
        command.effectiveAggregateId,
      ), () => <String>{})
      .add(command.localId);

  @override
  Future<SessionOutboxSnapshot?> sessionSnapshot({
    required String accountId,
    required String wellId,
    String? localSessionId,
    String? serverSessionId,
  }) async {
    _assertOpen();
    if ((localSessionId == null) == (serverSessionId == null)) {
      throw ArgumentError('يلزم معرف جلسة واحد');
    }
    final candidates = localSessionId == null
        ? (_byServerSession[(accountId, serverSessionId!)] ?? <String>{})
        : {localSessionId};
    final roots = [
      for (final id in candidates)
        if (_byLocalId[id]?.accountId == accountId &&
            (_byLocalId[id]!.wellId ?? _byLocalId[id]!.payload['p_well_id']) ==
                wellId)
          _byLocalId[id]!,
    ];
    if (roots.length != 1) return null;
    final root = roots.single;
    if (root.type != CommandType.adoptExternalSession &&
        root.type != CommandType.startOperationalSession &&
          root.type != CommandType.startIrrigationSession &&
        root.type != CommandType.startAdhocSession &&
        root.type != CommandType.startBookingSession) {
      return null;
    }
    final commands = [
      for (final id in _bySession[(accountId, root.localId)] ?? <String>{})
        if (_byLocalId[id]!.wellId == null || _byLocalId[id]!.wellId == wellId)
          _byLocalId[id]!,
    ]..sort((a, b) => a.sequence.compareTo(b.sequence));
    return SessionOutboxSnapshot(
      commands: commands,
      mappings: [
        for (final c in commands)
          ?_mappings[accountId]?[_mappingKey(
            c.localId,
            c.localId == root.localId ? EntityKind.session : EntityKind.payment,
          )],
      ],
      paymentRead: _paymentReads[(accountId, wellId, root.localId)],
    );
  }

  @override
  Future<void> saveSessionPaymentRead({
    required String accountId,
    required String wellId,
    required String localSessionId,
    required Map<String, Object?> value,
  }) async {
    _assertOpen();
    _paymentReads[(accountId, wellId, localSessionId)] = Map.unmodifiable(
      value,
    );
  }

  @override
  Future<CommandEnvelope> insertSessionCorrection(CommandEnvelope command) async {
    _assertOpen();
    validateSessionCorrectionInsert(command);
    final existing = existingSessionCorrection(
      _commands[command.accountId] ?? const <CommandEnvelope>[], command,
    );
    if (existing != null) return existing;
    // لا await بين القرار وتحديث الفهارس داخل insert.
    return insert(command);
  }

  @override
  Future<CommandEnvelope> insertSessionPayment(CommandEnvelope command) async {
    _assertOpen();
    if (command.type != CommandType.recordPayment ||
        command.aggregateLocalId == null ||
        command.wellId == null) {
      throw ArgumentError('دفعة جلسة مطلوبة');
    }
    for (final id
        in _bySession[(command.accountId, command.aggregateLocalId!)] ??
            <String>{}) {
      final row = _byLocalId[id]!;
      if (row.type == CommandType.recordPayment &&
          (row.status != CommandStatus.confirmed ||
              _mappings[command.accountId]?[_mappingKey(
                    id,
                    EntityKind.payment,
                  )] ==
                  null)) {
        throw StateError('توجد دفعة محفوظة أو تحتاج مراجعة لهذه الجلسة');
      }
    }
    // insert لا يتنازل عن التنفيذ قبل تحديث الفهارس، فيطابق المعاملة المحلية.
    return insert(command);
  }

  @override
  Future<DispatchClaimResult> claimDispatch({
    required String accountId,
    required String wellId,
    required String localId,
    required String commandId,
    required DateTime attemptedAt,
    required DispatchClaimPolicy policy,
  }) async {
    _assertOpen();
    final commandReads = <(String, String), String>{};
    final bundleReads = <(String, String), String?>{};
    final mappingReads = <(String, String, EntityKind), String?>{};
    CommandEnvelope? row(String account, String id) {
      final c = _byLocalId[id];
      return c?.accountId == account ? c : null;
    }

    String? mappingValue(String account, String id, EntityKind kind) {
      final m = _mappings[account]?[_mappingKey(id, kind)];
      return m == null
          ? null
          : jsonEncode([m.localId, m.kind.storageValue, m.serverId]);
    }

    Future<CommandEnvelope?> readCommand(String account, String id) async {
      final c = row(account, id);
      commandReads.putIfAbsent((
        account,
        id,
      ), () => dispatchCommandFingerprint(c));
      return c == null ? null : freezeDispatchCommand(c);
    }

    Future<String?> readBundle(String account, String key) async {
      final value = _bundles['$account::$key'];
      bundleReads.putIfAbsent((account, key), () => value);
      return value;
    }

    Future<IdMapping?> readMapping(
      String account,
      String id,
      EntityKind kind,
    ) async {
      mappingReads.putIfAbsent((
        account,
        id,
        kind,
      ), () => mappingValue(account, id, kind));
      return _mappings[account]?[_mappingKey(id, kind)];
    }

    final reader = CommandIntentEvidenceReader.fromReads(
      readCommand,
      readBundle,
    );
    final (decision, context) = await inspectDispatchClaim(
      accountId: accountId,
      wellId: wellId,
      localId: localId,
      commandId: commandId,
      readCommand: readCommand,
      readBundle: readBundle,
      readMapping: readMapping,
      classify: () =>
          reader.read(accountId: accountId, wellId: wellId, localId: localId),
      policy: policy,
    );
    // بعد آخر await: مقارنة كل القراءات والكتابة بلا نقطة تسليم؛ تشمل
    // الكتابات القديمة التي لا تعرف واجهة الحجز الجديدة.
    _assertOpen();
    if (commandReads.entries.any(
          (e) => dispatchCommandFingerprint(row(e.key.$1, e.key.$2)) != e.value,
        ) ||
        bundleReads.entries.any(
          (e) => _bundles['${e.key.$1}::${e.key.$2}'] != e.value,
        ) ||
        mappingReads.entries.any(
          (e) => mappingValue(e.key.$1, e.key.$2, e.key.$3) != e.value,
        )) {
      return const DispatchClaimResult(DispatchClaimDecision.concurrentChange);
    }
    if (decision != DispatchClaimDecision.allow) {
      return DispatchClaimResult(decision, context: context);
    }
    final token = DispatchAttempt(
      accountId: accountId,
      wellId: wellId,
      localId: localId,
      commandId: commandId,
      commandType: context!.command.type,
      attemptId: SecureIdGenerator().newId(),
      startedAt: attemptedAt.toUtc(),
    );
    final history =
        '$accountId::${dispatchAttemptHistoryKey(localId, token.attemptId)}';
    if (_bundles.containsKey(history)) {
      throw StateError('duplicate_dispatch_attempt');
    }
    final claimed = context.command.copyWith(
      status: CommandStatus.dispatching,
      lastAttemptAt: token.startedAt,
    );
    _update(accountId, localId, (_) => claimed);
    final value = jsonEncode(token.toJson());
    _bundles[history] = value;
    _bundles['$accountId::${dispatchAttemptCurrentKey(localId)}'] = value;
    return DispatchClaimResult(
      DispatchClaimDecision.allow,
      context: context,
      command: claimed,
      attempt: token,
    );
  }

  @override
  Future<bool> releaseDispatchAttempt(
    DispatchAttempt attempt, {
    required String reason,
  }) async => _finishOwnedDispatch(attempt, reason: reason);

  @override
  Future<bool> finishDispatchAttempt(
    DispatchAttempt attempt, {
    required CommandStatus status,
    Map<String, Object?>? serverResponse,
    String? error,
    String? entityId,
  }) async {
    if (!const {
          CommandStatus.confirmed,
          CommandStatus.review,
        }.contains(status) ||
        (status == CommandStatus.confirmed && serverResponse == null)) {
      throw ArgumentError('invalid_dispatch_result');
    }
    return _finishOwnedDispatch(
      attempt,
      status: status,
      response: freezeDispatchReceipt(serverResponse),
      reason: error,
      entityId: entityId,
    );
  }

  bool _finishOwnedDispatch(
    DispatchAttempt attempt, {
    CommandStatus? status,
    Map<String, Object?>? response,
    String? reason,
    String? entityId,
  }) {
    _assertOpen();
    final c = _byLocalId[attempt.localId];
    final currentKey =
        '${attempt.accountId}::${dispatchAttemptCurrentKey(attempt.localId)}';
    final historyKey =
        '${attempt.accountId}::${dispatchAttemptHistoryKey(attempt.localId, attempt.attemptId)}';
    final current = _bundles[currentKey];
    if (!ownsDispatchAttempt(c, current, attempt) ||
        _bundles[historyKey] != current) {
      return false;
    }
    _update(
      attempt.accountId,
      attempt.localId,
      (c) => c.copyWith(
        status: status ?? CommandStatus.pending,
        retryCount: status == null ? c.retryCount + 1 : c.retryCount,
        lastError: reason,
        clearLastError: reason == null,
        serverResponse: response,
      ),
    );
    if (status == CommandStatus.confirmed &&
        entityId != null &&
        c!.type.produces != null) {
      final mapping = IdMapping(
        localId: c.localId,
        kind: c.type.produces!,
        serverId: entityId,
        resolvedAt: attempt.startedAt,
      );
      _mappings.putIfAbsent(
        attempt.accountId,
        () => {},
      )[_mappingKey(c.localId, c.type.produces!)] = mapping;
    }
    final value = jsonEncode(
      attempt.toJson(
        state: status == null
            ? DispatchAttemptState.retryRequested
            : status == CommandStatus.confirmed
            ? DispatchAttemptState.confirmed
            : DispatchAttemptState.review,
        reason: reason,
      ),
    );
    _bundles[currentKey] = value;
    _bundles[historyKey] = value;
    return true;
  }

  @override
  Future<bool> reviewOperationalStart(
    CommandEnvelope observed,
    String reason,
  ) async {
    _assertOpen();
    observed = freezeDispatchCommand(observed);
    final mapping =
        _mappings[observed.accountId]?[_mappingKey(
          observed.localId,
          EntityKind.session,
        )];
    if (!canReviewOperationalStart(
      observed: observed,
      current: _byLocalId[observed.localId],
      humanRecord:
          _bundles['${observed.accountId}::${humanCommandIntentBundleKey(observed.localId)}'],
      mapping: mapping,
    )) {
      return false;
    }
    _update(
      observed.accountId,
      observed.localId,
      (c) => c.copyWith(status: CommandStatus.review, lastError: reason),
    );
    return true;
  }

  @override
  Future<bool> reconcileOperationalStartReceipt(
    CommandEnvelope observed,
    Map<String, Object?> receipt,
  ) async {
    _assertOpen();
    receipt = freezeDispatchReceipt(receipt)!;
    observed = freezeDispatchCommand(observed);
    final mapping =
        _mappings[observed.accountId]?[_mappingKey(
          observed.localId,
          EntityKind.session,
        )];
    if (!canReconcileOperationalStartReceipt(
      observed: observed,
      current: _byLocalId[observed.localId],
      humanRecord:
          _bundles['${observed.accountId}::${humanCommandIntentBundleKey(observed.localId)}'],
      mapping: mapping,
      receipt: receipt,
    )) {
      return false;
    }
    _update(
      observed.accountId,
      observed.localId,
      (c) => c.copyWith(
        status: CommandStatus.confirmed,
        serverResponse: receipt,
        clearLastError: true,
      ),
    );
    _mappings
        .putIfAbsent(observed.accountId, () => {})
        .putIfAbsent(
          _mappingKey(observed.localId, EntityKind.session),
          () => IdMapping(
            localId: observed.localId,
            kind: EntityKind.session,
            serverId: receipt['id'] as String,
            resolvedAt: observed.occurredAt,
          ),
        );
    return true;
  }

  @override
  Future<bool> reconcileBookingStartReceipt(
    CommandEnvelope observed,
    Map<String, Object?> receipt,
  ) async {
    _assertOpen();
    receipt = freezeDispatchReceipt(receipt)!;
    observed = freezeDispatchCommand(observed);
    final mapping =
        _mappings[observed.accountId]?[_mappingKey(
          observed.localId,
          EntityKind.session,
        )];
    if (!canReconcileBookingStartReceipt(
      observed: observed,
      current: _byLocalId[observed.localId],
      manualRecord:
          _bundles['${observed.accountId}::booking.manual_start.v1.${observed.wellId}.${observed.payload['p_booking_id']}'],
      mapping: mapping,
      receipt: receipt,
    )) {
      return false;
    }
    _update(
      observed.accountId,
      observed.localId,
      (c) => c.copyWith(
        status: CommandStatus.confirmed,
        serverResponse: receipt,
        clearLastError: true,
      ),
    );
    _mappings
        .putIfAbsent(observed.accountId, () => {})
        .putIfAbsent(
          _mappingKey(observed.localId, EntityKind.session),
          () => IdMapping(
            localId: observed.localId,
            kind: EntityKind.session,
            serverId: receipt['session_id'] as String,
            resolvedAt: DateTime.parse(receipt['started_at'] as String),
          ),
        );
    return true;
  }

  @override
  Future<bool> reconcileCompletionReceipt(
    CommandEnvelope observed,
    String sessionId,
    Map<String, Object?> receipt,
  ) async {
    receipt = freezeDispatchReceipt(receipt)!;
    observed = freezeDispatchCommand(observed);
    _assertOpen();
    final root = observed.aggregateLocalId;
    final charge =
        _mappings[observed.accountId]?[_mappingKey(
          observed.localId,
          EntityKind.sessionCharge,
        )];
    if (!canReconcileCompletionReceipt(
      observed: observed,
      current: _byLocalId[observed.localId],
      root: root == null ? null : _byLocalId[root],
      sessionMapping: root == null
          ? null
          : _mappings[observed.accountId]?[_mappingKey(
              root,
              EntityKind.session,
            )],
      chargeMapping: charge,
      sessionId: sessionId,
      receipt: receipt,
    )) {
      return false;
    }
    _update(
      observed.accountId,
      observed.localId,
      (c) => c.copyWith(
        status: CommandStatus.confirmed,
        serverResponse: receipt,
        clearLastError: true,
      ),
    );
    _mappings
        .putIfAbsent(observed.accountId, () => {})
        .putIfAbsent(
          _mappingKey(observed.localId, EntityKind.sessionCharge),
          () => IdMapping(
            localId: observed.localId,
            kind: EntityKind.sessionCharge,
            serverId: receipt['session_charge_id'] as String,
            resolvedAt: DateTime.parse(receipt['ended_at'] as String),
          ),
        );
    return true;
  }

  @override
  Future<CommandEnvelope> prepareSessionExecutionCommand({
    required String accountId,
    required String wellId,
    required String sessionLocalId,
    required CommandType type,
    required DateTime at,
    required Map<String, Object?> payload,
  }) => OutboxRepository(store: this).prepare(
    accountId: accountId,
    wellId: wellId,
    aggregateLocalId: sessionLocalId,
    type: type,
    occurredAt: at,
    payload: payload,
  );

  @override
  Future<T> sessionExecutionTransaction<T>({
    required String accountId,
    required String wellId,
    required String sessionLocalId,
    required SessionExecutionWrite<T> Function(SessionExecutionSnapshot) decide,
  }) async {
    _assertOpen();
    final candidate = _byLocalId[sessionLocalId];
    final root =
        candidate?.accountId == accountId && candidate?.wellId == wellId
        ? candidate
        : null;
    final events =
        (_bySession[(accountId, sessionLocalId)] ?? const <String>{})
            .map((id) => _byLocalId[id]!)
            .where((c) => c.wellId == wellId)
            .toList()
          ..sort((a, b) => a.sequence.compareTo(b.sequence));
    final write = decide(SessionExecutionSnapshot(root: root, events: events));
    validateManualStopMaterialization(
      account: accountId,
      well: wellId,
      local: sessionLocalId,
      root: root,
      events: events,
      savedRequest:
          _bundles['$accountId::session.manual_stop.request.v1/${Uri.encodeComponent(wellId)}/${Uri.encodeComponent(sessionLocalId)}'],
      previousLink:
          _bundles['$accountId::${manualStopMaterializationKey(wellId, sessionLocalId)}'],
      previousEffect:
          _bundles['$accountId::session.completion.v1.$wellId.$sessionLocalId'],
      mapping:
          _mappings[accountId]?[_mappingKey(
            sessionLocalId,
            EntityKind.session,
          )],
      write: write,
    );
    final ids = <String>{};
    for (final c in write.commands) {
      if (_usedCommandIds.contains(c.commandId) ||
          !ids.add(c.commandId) ||
          _byLocalId.containsKey(c.localId)) {
        throw DuplicateCommandIdException(c.commandId);
      }
    }
    // No await between snapshot, guards and writes: no partial materialization.
    for (final c in write.commands) {
      _usedCommandIds.add(c.commandId);
      _commands.putIfAbsent(accountId, () => []).add(c);
      _byLocalId[c.localId] = c;
      _indexWell(c);
      _indexSession(c);
    }
    for (final entry in write.values.entries) {
      _bundles['$accountId::${entry.key}'] = entry.value;
    }
    return write.result;
  }

  @override
  Future<bool> claim(
    String accountId,
    String localId, {
    required DateTime attemptedAt,
  }) async {
    _assertOpen();

    final index = _indexOf(accountId, localId);

    if (index == null) {
      return false;
    }

    final rows = _commands[accountId]!;

    if (rows[index].status != CommandStatus.pending) {
      return false;
    }

    rows[index] = rows[index].copyWith(
      status: CommandStatus.dispatching,
      lastAttemptAt: attemptedAt,
    );
    _byLocalId[localId] = rows[index];

    return true;
  }

  @override
  Future<void> releaseForRetry(
    String accountId,
    String localId, {
    required String error,
    required DateTime attemptedAt,
  }) async {
    _update(
      accountId,
      localId,
      (row) => row.copyWith(
        status: CommandStatus.pending,
        retryCount: row.retryCount + 1,
        lastError: error,
        lastAttemptAt: attemptedAt,
      ),
    );
  }

  @override
  Future<void> markConfirmed(
    String accountId,
    String localId, {
    required Map<String, Object?> serverResponse,
    required DateTime attemptedAt,
  }) async {
    _update(
      accountId,
      localId,
      (row) => row.copyWith(
        status: CommandStatus.confirmed,
        clearLastError: true,
        lastAttemptAt: attemptedAt,
        serverResponse: serverResponse,
      ),
    );
  }

  @override
  Future<void> markNeedsReview(
    String accountId,
    String localId, {
    required String error,
    required DateTime attemptedAt,
    Map<String, Object?>? serverResponse,
  }) async {
    _update(
      accountId,
      localId,
      (row) => row.copyWith(
        status: CommandStatus.review,
        lastError: error,
        lastAttemptAt: attemptedAt,
        serverResponse: serverResponse,
      ),
    );
  }

  @override
  Future<void> putMapping(String accountId, IdMapping mapping) async {
    _assertOpen();

    if (mapping.kind == EntityKind.session) {
      final old =
          _mappings[accountId]?[_mappingKey(mapping.localId, mapping.kind)];
      if (old != null) {
        _byServerSession[(accountId, old.serverId)]?.remove(mapping.localId);
      }
      _byServerSession
          .putIfAbsent((accountId, mapping.serverId), () => <String>{})
          .add(mapping.localId);
    }
    _mappings.putIfAbsent(
      accountId,
      () => {},
    )[_mappingKey(mapping.localId, mapping.kind)] = mapping;
  }

  @override
  Future<IdMapping?> mapping(
    String accountId,
    String localId,
    EntityKind kind,
  ) async {
    _assertOpen();

    return _mappings[accountId]?[_mappingKey(localId, kind)];
  }

  @override
  Future<List<IdMapping>> mappings(String accountId) async {
    _assertOpen();

    return [...?_mappings[accountId]?.values];
  }

  @override
  Future<DateTime?> lastSuccessfulSyncAt(String accountId) async {
    _assertOpen();

    return _lastSync[accountId];
  }

  @override
  Future<void> setLastSuccessfulSyncAt(String accountId, DateTime at) async {
    _assertOpen();

    _lastSync[accountId] = at;
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  /// يُعيد فتح نفس البيانات — يحاكي تشغيل التطبيق من جديد بعد موته.
  ///
  /// البيانات هي نفسها لأن هذا المخزن نفسه هو «القرص» في الاختبار.
  Future<void> reopen() async {
    _closed = false;
  }

  int? _indexOf(String accountId, String localId) {
    final rows = _commands[accountId];

    if (rows == null) {
      return null;
    }

    for (var index = 0; index < rows.length; index += 1) {
      if (rows[index].localId == localId) {
        return index;
      }
    }

    return null;
  }

  void _update(
    String accountId,
    String localId,
    CommandEnvelope Function(CommandEnvelope row) transform,
  ) {
    _assertOpen();

    final index = _indexOf(accountId, localId);

    if (index == null) {
      return;
    }

    final rows = _commands[accountId]!;
    rows[index] = transform(rows[index]);
    _byLocalId[localId] = rows[index];
  }

  void _assertOpen() {
    if (_closed) {
      throw StateError('المخزن مغلق');
    }
  }

  static String _mappingKey(String localId, EntityKind kind) =>
      '$localId::${kind.storageValue}';
}

/// مدخل الطابور: الطريق الوحيد لتسجيل عملية ميدانية.
///
/// هنا — وهنا فقط — يُولَّد `commandId`. الواجهة تُنادي [enqueue]، ولا
/// تملك مولّد معرّفات ولا تصل إليه. المحرك لا يملك مولّدًا إطلاقًا،
/// فلا يوجد في المستودع أي مسار يولّد معرّفًا جديدًا لمحاولة إعادة —
/// وهو الثابت الذي تقوم عليه حماية التكرار كلها (القسم 2 والقسم 7).
library;

import 'dart:convert';

import 'command_envelope.dart';
import 'command_id_generator.dart';
import 'command_reference.dart';
import 'command_type.dart';
import 'outbox_store.dart';
import 'sync_status.dart';
import 'manual_session_entry.dart';

class OutboxRepository {
  OutboxRepository({
    required this._store,
    IdGenerator? idGenerator,
    DateTime Function()? clock,
  }) : _ids = idGenerator ?? SecureIdGenerator(),
       _clock = clock ?? DateTime.now;

  final OutboxStore _store;
  final IdGenerator _ids;
  final DateTime Function() _clock;

  Future<void> initialize() => _store.initialize();

  /// تُحضّر مرة لكل فعل إرسال؛ يعاد حفظ المغلف نفسه عند تكرار المعالجة.
  Future<CommandEnvelope> prepareManualSessionEntry({
    required String accountId,
    required ManualSessionEntryFacts facts,
  }) async {
    final command = await prepare(accountId: accountId, wellId: facts.wellId,
      type: facts.type, occurredAt: facts.startedAt, payload: facts.payload);
    if (ManualSessionEntryReceiptRequest.fromCommand(command) == null) {
      throw ArgumentError('invalid_manual_session_entry');
    }
    return command;
  }

  Future<CommandEnvelope> saveManualSessionEntry(CommandEnvelope command) async {
    if (ManualSessionEntryReceiptRequest.fromCommand(command) == null ||
        command.status != CommandStatus.pending || command.wasAttempted) {
      throw ArgumentError('invalid_manual_session_entry_intent');
    }
    final value = jsonEncode([command.commandId, command.wellId,
      command.type.storageValue, command.occurredAt.toIso8601String(), command.payload]);
    final saved = await _store.insertBundle(accountId: command.accountId,
      key: 'session.manual_entry.v1.${command.localId}', value: value,
      commands: [command]);
    if (saved != value) throw StateError('manual_session_entry_identity_changed');
    final row = await _store.commandByLocalId(command.accountId,command.localId);
    if (row == null) throw StateError('manual_session_entry_not_saved');
    return row;
  }

  /// ملاحظة محلية فقط؛ لا تقرأ الشبكة ولا تعيد إنشاء نية أو جلسة.
  Future<ManualSessionEntryRead?> readManualSessionEntry({
    required String accountId, required String wellId, required String localId,
  }) async => (await observeManualSessionEntry(accountId: accountId,
      wellId: wellId,localId: localId))?.outcome;

  Future<ManualSessionEntryObservation?> observeManualSessionEntry({
    required String accountId, required String wellId, required String localId,
  }) async {
    final c = await _store.commandByLocalId(accountId, localId);
    if (c == null || c.wellId != wellId) return null;
    final request = ManualSessionEntryReceiptRequest.fromCommand(c);
    if (request == null) return null;
    return ManualSessionEntryObservation(c,c.serverResponse == null ? null
      : parseManualSessionEntryResult(request,c.serverResponse));
  }

  /// يسجّل عملية ميدانية ويحفظها حفظًا دائمًا قبل أن يُرجِع أي شيء.
  ///
  /// [occurredAt] وقت وقوع العملية في الحقل — لا وقت الإرسال. يُرسل
  /// صراحة في كل محاولة (القسم 18).
  ///
  /// [aggregateLocalId] معرّف أمر بدء الجلسة لأحداثها اللاحقة. أوامر
  /// الأصل الواحد تُرسل بترتيبها، وأصول مختلفة تُرسل بالتوازي (القسم 6).
  Future<CommandEnvelope> enqueue({
    required String accountId,
    required CommandType type,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
    String? wellId,
    String? aggregateLocalId,
  }) async {
    final envelope = await prepare(
      accountId: accountId,
      type: type,
      payload: payload,
      occurredAt: occurredAt,
      wellId: wellId,
      aggregateLocalId: aggregateLocalId,
    );
    return _store.insert(envelope);
  }

  /// يحفظ نية تصحيح مستقلة قبل أي فرصة مزامنة، بحماية تكرار ذرية.
  Future<CommandEnvelope> enqueueSessionCorrection({
    required String accountId,
    required String wellId,
    required String sessionId,
    required int baseRevision,
    required String reason,
    required DateTime desiredStartedAt,
    required DateTime desiredEndedAt,
  }) async {
    final cleanReason = reason.trim();
    final start = desiredStartedAt.toUtc();
    final end = desiredEndedAt.toUtc();
    if (accountId.trim().isEmpty ||
        wellId.trim().isEmpty ||
        sessionId.trim().isEmpty ||
        baseRevision < 0 ||
        baseRevision > 9223372036854775806 ||
        cleanReason.isEmpty ||
        !start.isBefore(end)) {
      throw ArgumentError('invalid_session_correction');
    }
    final requestedAt = _clock().toUtc();
    if (end.isAfter(requestedAt)) {
      throw ArgumentError('session_correction_end_in_future');
    }
    if (_store is! SessionCorrectionInsertStore) {
      throw StateError('session_correction_insert_unavailable');
    }
    final command = await prepare(
      accountId: accountId,
      wellId: wellId,
      type: CommandType.correctIrrigationSession,
      occurredAt: requestedAt,
      payload: Map<String, Object?>.unmodifiable({
        'p_session_id': sessionId,
        'p_base_revision': baseRevision,
        'p_reason': cleanReason,
        'p_desired_started_at': start.toIso8601String(),
        'p_desired_ended_at': end.toIso8601String(),
      }),
    );
    return _store.insertSessionCorrection(command);
  }

  /// يبني أمرًا لمعاملة جماعية؛ لا يعلن حفظه ولا يرسله.
  Future<CommandEnvelope> prepare({
    required String accountId,
    required CommandType type,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
    String? wellId,
    String? aggregateLocalId,
    List<String> prerequisites = const [],
    Map<String, Object?> localContext = const {},
  }) async {
    return CommandEnvelope(
      localId: _ids.newId(),
      commandId: _ids.newId(),
      type: type,
      accountId: accountId,
      sequence: await _store.nextSequence(accountId),
      occurredAt: occurredAt.toUtc(),
      createdLocalAt: _clock().toUtc(),
      payload: payload,
      wellId: wellId,
      aggregateLocalId: aggregateLocalId,
      prerequisites: prerequisites,
      localContext: localContext,
    );
  }

  /// يبني مرجعًا إلى كيان سيُنتجه أمرٌ مسجَّل ولم يُرسل بعد.
  ///
  /// يرفض الأمر الذي لا يُنتج كيانًا (إيقاف/استئناف/تغيير طاقة):
  /// تلك تُرجِع معرّف حدث أو مقطع، لا كيانًا يشير إليه أمر آخر. لو
  /// سُمح بها لنشأ ربط زائف يُرسَل في وسيط خاطئ.
  CommandReference referenceTo(CommandEnvelope envelope) {
    final kind = envelope.type.produces;

    if (kind == null) {
      throw ArgumentError.value(
        envelope.type.rpcName,
        'envelope',
        'هذا الأمر لا يُنتج كيانًا يمكن الإشارة إليه',
      );
    }

    return CommandReference(localId: envelope.localId, kind: kind);
  }

  /// الأوامر التي لم تُؤكَّد بعد، مرتَّبة بترتيب إرسالها.
  Future<List<CommandEnvelope>> pending(String accountId) =>
      _store.pendingCommands(accountId);

  /// كل الأوامر — للعرض والتشخيص.
  Future<List<CommandEnvelope>> all(String accountId) =>
      _store.allCommands(accountId);

  Future<CommandEnvelope?> byLocalId(String accountId, String localId) =>
      _store.commandByLocalId(accountId, localId);

  /// المعرّف الخادمي لكيان أُنشئ محليًا، أو `null` إن لم يُحسم بعد.
  Future<String?> serverIdFor(
    String accountId,
    String localId,
    EntityKind kind,
  ) async {
    final mapping = await _store.mapping(accountId, localId, kind);

    return mapping?.serverId;
  }

  /// عدد العمليات المحفوظة على الجهاز وغير المؤكَّدة.
  Future<int> pendingCount(String accountId) async {
    final rows = await _store.pendingCommands(accountId);

    return rows.length;
  }

  /// العمليات التي تحتاج تدخلًا بشريًا.
  Future<List<CommandEnvelope>> needingReview(String accountId) async {
    final rows = await _store.pendingCommands(accountId);

    return rows.where((row) => row.status == CommandStatus.review).toList();
  }

  Future<DateTime?> lastSuccessfulSyncAt(String accountId) =>
      _store.lastSuccessfulSyncAt(accountId);

  Future<void> close() => _store.close();
}

/// مدخل الطابور: الطريق الوحيد لتسجيل عملية ميدانية.
///
/// هنا — وهنا فقط — يُولَّد `commandId`. الواجهة تُنادي [enqueue]، ولا
/// تملك مولّد معرّفات ولا تصل إليه. المحرك لا يملك مولّدًا إطلاقًا،
/// فلا يوجد في المستودع أي مسار يولّد معرّفًا جديدًا لمحاولة إعادة —
/// وهو الثابت الذي تقوم عليه حماية التكرار كلها (القسم 2 والقسم 7).
library;

import 'command_envelope.dart';
import 'command_id_generator.dart';
import 'command_reference.dart';
import 'command_type.dart';
import 'outbox_store.dart';
import 'sync_status.dart';

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
    final envelope = CommandEnvelope(
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
    );

    return _store.insert(envelope);
  }

  /// يبني مرجعًا إلى كيان سيُنتجه أمرٌ مسجَّل ولم يُرسل بعد.
  ///
  /// يرفض الأمر الذي لا يُنتج كيانًا (إيقاف/استئناف/تغيير طاقة/إنهاء):
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

/// بوابة التخزين الدائم للطابور.
///
/// كل ما تحت هذه البوابة قابل للاستبدال: التنفيذ الحالي `sqflite`،
/// وقد يصبح `drift` أو PowerSync في Stage 7 (القسم 3 من
/// `ANDROID_OFFLINE_BACKGROUND_SYNC.md` يفوّض اختيار المكتبة للتنفيذ).
/// المنطق فوق البوابة لا يعرف أيًّا منها.
///
/// كل الدوال مقيَّدة بـ`accountId` — ق-101: الحالة المحلية مربوطة
/// بالحساب المصادَق، والدخول بحساب آخر لا يكشف طابور السابق.
library;

import 'dart:convert';

import 'booking_start_receipt.dart';
import 'command_transport.dart';
import 'command_intent_policy.dart';
import 'command_reference.dart';
import 'command_envelope.dart';
import 'command_type.dart';
import 'sync_status.dart';

bool canReconcileBookingStartReceipt({
  required CommandEnvelope observed,
  required CommandEnvelope? current,
  required String? manualRecord,
  required IdMapping? mapping,
  required Map<String, Object?> receipt,
}) {
  final request = BookingStartReceiptRequest.fromCommand(observed);
  if (request == null ||
      current == null ||
      dispatchCommandFingerprint(current) !=
          dispatchCommandFingerprint(observed) ||
      !(const {
            CommandStatus.pending,
            CommandStatus.dispatching,
          }.contains(current.status) ||
          (current.status == CommandStatus.review &&
              current.serverResponse == null)) ||
      !validBookingStartReceipt(request, receipt) ||
      (mapping != null && mapping.serverId != receipt['session_id']) ||
      (observed.serverResponse != null &&
          observed.serverResponse!['session_id'] != receipt['session_id'])) {
    return false;
  }
  try {
    final proof = jsonDecode(manualRecord ?? '');
    return proof is Map &&
        proof.length == 2 &&
        proof['start_local_id'] == observed.localId &&
        proof['start_command_id'] == observed.commandId;
  } on FormatException {
    return false;
  }
}

// Receipt adoption uses the original row and the existing receipt validator.
// It neither grants retry permission nor changes dispatch attempt ownership.
bool canReconcileCompletionReceipt({
  required CommandEnvelope observed,
  required CommandEnvelope? current,
  required CommandEnvelope? root,
  required IdMapping? sessionMapping,
  required IdMapping? chargeMapping,
  required String sessionId,
  required Map<String, Object?> receipt,
}) {
  if (current == null ||
      dispatchCommandFingerprint(current) !=
          dispatchCommandFingerprint(observed) ||
      observed.type != CommandType.completeIrrigationSession ||
      observed.accountId.isEmpty ||
      observed.wellId == null ||
      observed.wellId!.isEmpty ||
      observed.commandId.isEmpty ||
      observed.localId.isEmpty ||
      sessionId.isEmpty ||
      !(const {
            CommandStatus.pending,
            CommandStatus.dispatching,
          }.contains(current.status) ||
          (current.status == CommandStatus.review &&
              current.serverResponse == null)) ||
      root == null ||
      root.localId != observed.aggregateLocalId ||
      root.accountId != observed.accountId ||
      root.wellId != observed.wellId ||
      root.type.produces != EntityKind.session ||
      sessionMapping?.serverId != sessionId ||
      sessionMapping?.localId != root.localId ||
      sessionMapping?.kind != EntityKind.session ||
      (chargeMapping != null &&
          (chargeMapping.localId != observed.localId ||
              chargeMapping.kind != EntityKind.sessionCharge ||
              chargeMapping.serverId != receipt['session_charge_id']))) {
    return false;
  }
  final target = observed.payload['p_session_id'];
  if (target != sessionId &&
      !(target is Map &&
          target.length == 2 &&
          target[r'$ref'] == root.localId &&
          target[r'$kind'] == 'session')) {
    return false;
  }
  for (final pair in [
    ('command_id', observed.commandId),
    ('command_type', observed.type.rpcName),
    ('well_id', observed.wellId),
  ]) {
    if (receipt.containsKey(pair.$1) && receipt[pair.$1] != pair.$2) {
      return false;
    }
  }
  final request = CompletionReceiptRequest(
    accountId: observed.accountId,
    wellId: observed.wellId!,
    sessionId: sessionId,
    commandId: observed.commandId,
    commandType: observed.type.rpcName,
  );
  final result = parseCompletionReceipt(request, {
    'contract': 'get_completion_receipt',
    'version': 1,
    'retry_authorized': false,
    'well_id': request.wellId,
    'session_id': request.sessionId,
    'command_id': request.commandId,
    'command_type': request.commandType,
    'status': 'accepted',
    'receipt': receipt,
  });
  return result is CompletionReceiptResponse &&
      result.state == CompletionReceiptState.accepted;
}

/// عقد اختياري غير موصول بالمرسل القديم؛ لا يغير دلالات claim القديمة.
abstract interface class AtomicCommandDispatchStore {
  Future<DispatchClaimResult> claimDispatch({
    required String accountId,
    required String wellId,
    required String localId,
    required String commandId,
    required DateTime attemptedAt,
    required DispatchClaimPolicy policy,
  });

  /// طلب إعادة محاولة صريح من مالك الحجز، وليس إثبات فشل خادمي.
  Future<bool> releaseDispatchAttempt(
    DispatchAttempt attempt, {
    required String reason,
  });
  Future<bool> finishDispatchAttempt(
    DispatchAttempt attempt, {
    required CommandStatus status,
    Map<String, Object?>? serverResponse,
    String? error,
    String? entityId,
  });

  Future<bool> reconcileBookingStartReceipt(
    CommandEnvelope observed,
    Map<String, Object?> receipt,
  );

  Future<bool> reconcileCompletionReceipt(
    CommandEnvelope observed,
    String sessionId,
    Map<String, Object?> receipt,
  );
}

enum DispatchClaimDecision {
  allow,
  automaticSuspended,
  originUnresolved,
  policySuspended,
  previousAttemptUnresolved,
  dependencyUnresolved,
  notPending,
  identityMismatch,
  notFound,
  concurrentChange,
}

typedef DispatchClaimPolicy = DispatchClaimDecision Function(
  DispatchClaimContext context,
);

class DispatchClaimContext {
  const DispatchClaimContext(
    this.command,
    this.intent,
    this.previousAttempt, [
    this.resolvedPayload,
  ]);
  final CommandEnvelope command;
  final CommandIntentClassification intent;
  final DispatchAttempt? previousAttempt;
  final Map<String, Object?>? resolvedPayload;
}

class DispatchClaimResult {
  const DispatchClaimResult(
    this.decision, {
    this.context,
    this.command,
    this.attempt,
  });
  final DispatchClaimDecision decision;
  final DispatchClaimContext? context;
  final CommandEnvelope? command;
  final DispatchAttempt? attempt;
  bool get isClaimed =>
      decision == DispatchClaimDecision.allow && attempt != null;
}

String dispatchAttemptCurrentKey(String localId) =>
    'command.dispatch.current.v1.$localId';
String dispatchAttemptHistoryKey(String localId, String attemptId) =>
    'command.dispatch.attempt.v1.$localId.$attemptId';

enum DispatchAttemptState { active, retryRequested, confirmed, review }

/// nonce تقني للمحاولة، لا معرّف أمر أعمال جديد. لا يدل على وصول الشبكة.
class DispatchAttempt {
  const DispatchAttempt({
    required this.accountId,
    required this.wellId,
    required this.localId,
    required this.commandId,
    required this.commandType,
    required this.attemptId,
    required this.startedAt,
    this.state = DispatchAttemptState.active,
    this.reason,
  });
  final String accountId, wellId, localId, commandId, attemptId;
  final CommandType commandType;
  final DateTime startedAt;
  final String? reason;
  final DispatchAttemptState state;

  Map<String, Object?> toJson({
    DispatchAttemptState? state,
    String? reason,
  }) =>
      {
        'version': 1,
        'account_id': accountId,
        'well_id': wellId,
        'local_id': localId,
        'command_id': commandId,
        'command_type': commandType.storageValue,
        'attempt_id': attemptId,
        'started_at': startedAt.toUtc().toIso8601String(),
        'state': (state ?? this.state).name,
        'reason': ?reason,
      };

  static DispatchAttempt? parse(String? raw) {
    try {
      final m = jsonDecode(raw ?? 'null');
      if (m is! Map ||
          m['version'] is! int ||
          m['version'] != 1 ||
          [
            'account_id',
            'well_id',
            'local_id',
            'command_id',
            'attempt_id',
            'started_at',
            'command_type',
            'state',
          ].any((k) => m[k] is! String || (m[k] as String).trim().isEmpty)) {
        return null;
      }
      final at = DateTime.tryParse(m['started_at'] as String);
      if (at == null) {
        return null;
      }
      return DispatchAttempt(
        accountId: m['account_id'] as String,
        wellId: m['well_id'] as String,
        localId: m['local_id'] as String,
        commandId: m['command_id'] as String,
        commandType: CommandType.fromStorage(m['command_type'] as String),
        attemptId: m['attempt_id'] as String,
        startedAt: at.toUtc(),
        state: DispatchAttemptState.values.byName(m['state'] as String),
        reason: m['reason'] is String ? m['reason'] as String : null,
      );
    } on Object {
      return null;
    }
  }

  bool matches(CommandEnvelope command) =>
      command.accountId == accountId &&
      command.wellId == wellId &&
      command.localId == localId &&
      command.commandId == commandId &&
      command.type == commandType;
}

bool ownsDispatchAttempt(
  CommandEnvelope? row,
  String? current,
  DispatchAttempt token,
) {
  final saved = DispatchAttempt.parse(current);
  return row != null &&
      token.matches(row) &&
      row.status == CommandStatus.dispatching &&
      row.lastAttemptAt == token.startedAt &&
      saved != null &&
      saved.matches(row) &&
      saved.attemptId == token.attemptId &&
      saved.startedAt == token.startedAt &&
      saved.state == DispatchAttemptState.active;
}

/// مقارنة متفائلة للذاكرة؛ لا يستخدمها SQLite بدل معاملته.
String dispatchCommandFingerprint(CommandEnvelope? c) => jsonEncode(
  c == null
      ? null
      : [
          c.localId,
          c.commandId,
          c.accountId,
          c.wellId,
          c.type.storageValue,
          c.sequence,
          c.occurredAt.toUtc().toIso8601String(),
          c.payload,
          c.localContext,
          c.prerequisites,
          c.aggregateLocalId,
          c.status.storageValue,
          c.retryCount,
          c.lastAttemptAt?.toUtc().toIso8601String(),
          c.serverResponse,
          c.lastError,
          c.nextAttemptAt?.toUtc().toIso8601String(),
        ],
);

Object? _freezeDispatchValue(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map((k, v) => MapEntry(k as String, _freezeDispatchValue(v))),
    );
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeDispatchValue));
  }
  return value;
}

Map<String, Object?>? freezeDispatchReceipt(Map<String, Object?>? value) =>
    value == null
    ? null
    : (_freezeDispatchValue(jsonDecode(jsonEncode(value))) as Map)
          .cast<String, Object?>();

CommandEnvelope freezeDispatchCommand(CommandEnvelope c) => CommandEnvelope(
  localId: c.localId,
  commandId: c.commandId,
  type: c.type,
  accountId: c.accountId,
  wellId: c.wellId,
  sequence: c.sequence,
  occurredAt: c.occurredAt,
  createdLocalAt: c.createdLocalAt,
  payload: (_freezeDispatchValue(c.payload) as Map).cast<String, Object?>(),
  localContext: (_freezeDispatchValue(c.localContext) as Map)
      .cast<String, Object?>(),
  prerequisites: List.unmodifiable(c.prerequisites),
  aggregateLocalId: c.aggregateLocalId,
  status: c.status,
  retryCount: c.retryCount,
  lastError: c.lastError,
  lastAttemptAt: c.lastAttemptAt,
  serverResponse: c.serverResponse == null
      ? null
      : (_freezeDispatchValue(c.serverResponse) as Map).cast<String, Object?>(),
  nextAttemptAt: c.nextAttemptAt,
);

/// فحص قراءة فقط. المستدعي يضمن معاملة SQLite أو CAS شاملًا قبل أي كتابة.
/// السياسة متزامنة ونقية: لا شبكة ولا كتابة من داخلها.
Future<(DispatchClaimDecision, DispatchClaimContext?)> inspectDispatchClaim({
  required String accountId,
  required String wellId,
  required String localId,
  required String commandId,
  required Future<CommandEnvelope?> Function(String, String) readCommand,
  required Future<String?> Function(String, String) readBundle,
  required Future<IdMapping?> Function(String, String, EntityKind) readMapping,
  required Future<CommandIntentClassification> Function() classify,
  required DispatchClaimPolicy policy,
}) async {
  final raw = await readCommand(accountId, localId);
  if (raw == null) {
    return (DispatchClaimDecision.notFound, null);
  }
  final c = freezeDispatchCommand(raw);
  if ([accountId, wellId, localId, commandId].any((v) => v.trim().isEmpty) ||
      c.accountId != accountId ||
      c.wellId != wellId ||
      c.localId != localId ||
      c.commandId != commandId) {
    return (DispatchClaimDecision.identityMismatch, null);
  }
  if (c.status == CommandStatus.dispatching) {
    return (DispatchClaimDecision.previousAttemptUnresolved, null);
  }
  if (c.status != CommandStatus.pending) {
    return (DispatchClaimDecision.notPending, null);
  }
  final produced = c.type.produces;
  if (q137OperationalCommand(c.type) &&
      produced != null &&
      await readMapping(accountId, localId, produced) != null) {
    return (DispatchClaimDecision.previousAttemptUnresolved, null);
  }
  final previousRaw = await readBundle(
    accountId,
    dispatchAttemptCurrentKey(localId),
  );
  final previous = DispatchAttempt.parse(previousRaw);
  if ((previousRaw != null &&
          (previous == null ||
              !previous.matches(c) ||
              previous.state != DispatchAttemptState.retryRequested ||
              previous.startedAt != c.lastAttemptAt)) ||
      (previousRaw == null && (c.lastAttemptAt != null || c.retryCount > 0))) {
    return (DispatchClaimDecision.previousAttemptUnresolved, null);
  }
  if (previous != null &&
      await readBundle(
            accountId,
            dispatchAttemptHistoryKey(localId, previous.attemptId),
          ) !=
          previousRaw) {
    return (DispatchClaimDecision.previousAttemptUnresolved, null);
  }
  final resolutions = <CommandReference, String>{};
  try {
    final references = c.references;
    for (final id in {
      ...c.prerequisites,
      ...references.map((r) => r.localId),
    }) {
      final parent = await readCommand(accountId, id);
      if (parent == null ||
          parent.accountId != accountId ||
          parent.localId != id ||
          (parent.wellId != null && parent.wellId != wellId) ||
          parent.sequence >= c.sequence ||
          parent.status != CommandStatus.confirmed) {
        return (DispatchClaimDecision.dependencyUnresolved, null);
      }
      for (final ref in references.where((r) => r.localId == id)) {
        final mapping = await readMapping(accountId, id, ref.kind);
        if (parent.type.produces != ref.kind ||
            mapping == null ||
            mapping.localId != id ||
            mapping.kind != ref.kind ||
            mapping.serverId.isEmpty) {
          return (DispatchClaimDecision.dependencyUnresolved, null);
        }
        resolutions[ref] = mapping.serverId;
      }
    }
  } on FormatException {
    return (DispatchClaimDecision.dependencyUnresolved, null);
  }
  final payload = resolveReferences(c.payload, (ref) => resolutions[ref]);
  final context = DispatchClaimContext(
    c,
    await classify(),
    previous,
    Map<String, Object?>.from(payload as Map),
  );
  return (policy(context), context);
}


/// المعرّف الخادمي المحسوم لكيان أُنشئ محليًا.
class IdMapping {
  const IdMapping({
    required this.localId,
    required this.kind,
    required this.serverId,
    required this.resolvedAt,
    this.matchedExisting = false,
  });

  final String localId;
  final EntityKind kind;
  final String serverId;
  final DateTime resolvedAt;

  /// هل طابق الخادم كيانًا قائمًا بدل إنشاء جديد؟
  ///
  /// `api.create_farmer` تُعيد `already_exists` — منع التكرار في ق-88.
  /// الربط صحيح في الحالتين، لكن الفرق يهم العرض والتشخيص.
  final bool matchedExisting;
}

/// صفوف جلسة واحدة وروابطها؛ لا لقطة مالية محسوبة ولا مسح لسجل البئر.
class SessionOutboxSnapshot {
  const SessionOutboxSnapshot({
    required this.commands,
    required this.mappings,
    this.paymentRead,
  });
  final List<CommandEnvelope> commands;
  final List<IdMapping> mappings;
  final Map<String, Object?>? paymentRead;
}

/// حفظ سجل محلي بلا أوامر. أول معاملة ناجحة تفوز ويُعاد السجل الموجود.
/// لا يستبدل السجل، ولا يولّد أمرًا أو يحدّث حالة جلسة.
/// يظل منفصلًا عن عقد Outbox القديم لتجنب تغيير مسار المزامنة الحالي.
abstract interface class AtomicLocalRecordStore {
  Future<String> insertLocalRecordOnce({
    required String accountId,
    required String key,
    required String value,
  });
}

abstract interface class OutboxStore {
  /// يهيّئ التخزين. يجب أن يُنادى قبل أي عملية أخرى.
  Future<void> initialize();

  /// يُدخل أمرًا جديدًا ويُعيد نسخته المخزَّنة.
  ///
  /// يجب أن يفشل إذا كان `commandId` موجودًا — الفرادة مفروضة في
  /// التخزين لا في الكود، فلا يمكن أن يحمل صفّان نفس المعرّف.
  Future<CommandEnvelope> insert(CommandEnvelope envelope);

  /// يحفظ مجموعة أوامر وسجلها في معاملة واحدة؛ المفتاح يمنع تكرار المجموعة.
  Future<String> insertBundle({
    required String accountId,
    required String key,
    required String value,
    required List<CommandEnvelope> commands,
    Map<String, String> localValues = const {},
    bool Function()? isCurrent,
  });

  Future<String?> readBundle(String accountId, String key);

  Future<List<String>> readLocalValuesByPrefix(String accountId, String prefix);

  /// يُعيد رقم التسلسل التالي لهذا الحساب.
  ///
  /// تصاعدي ولا يتراجع بعد إعادة تشغيل التطبيق.
  Future<int> nextSequence(String accountId);

  /// كل الأوامر غير المؤكَّدة مرتَّبة بالتسلسل تصاعديًا.
  Future<List<CommandEnvelope>> pendingCommands(String accountId);

  /// أمر واحد بمعرّفه المحلي.
  Future<CommandEnvelope?> commandByLocalId(String accountId, String localId);

  /// كل الأوامر — للعرض والتشخيص.
  Future<List<CommandEnvelope>> allCommands(String accountId);

  /// قراءة بئر واحدة للإسقاط التشغيلي، دون قراءة طابور الآبار الأخرى.
  Future<List<CommandEnvelope>> commandsForWell(
    String accountId,
    String wellId,
  );

  /// يلزم تحديد أحد معرفي الجلسة فقط؛ الغياب أو اختلاف النطاق يعيد null.
  Future<SessionOutboxSnapshot?> sessionSnapshot({
    required String accountId,
    required String wellId,
    String? localSessionId,
    String? serverSessionId,
  });

  /// قراءة خادم محفوظة في مساحة الطابور نفسها، وموسومة بإصدار الدفعات.
  Future<void> saveSessionPaymentRead({
    required String accountId,
    required String wellId,
    required String localSessionId,
    required Map<String, Object?> value,
  });

  /// الحفظ مع رفض دفعة جلسة أخرى غير محسومة، في معاملة محلية واحدة.
  Future<CommandEnvelope> insertSessionPayment(CommandEnvelope command);

  /// يحجز الأمر لمحاولة إرسال.
  ///
  /// تحديث شرطي: ينجح فقط إذا كانت الحالة `pending` لحظة التحديث.
  /// يُعيد `false` إذا سبقه غيره — فلا يُرسل الأمر مرتين من حلقتين
  /// متزامنتين، ولا بين التطبيق وعامل خلفي لاحقًا.
  ///
  /// [attemptedAt] يُكتب مع الحجز ليصير للحجز عمر معروف. بدونه لا
  /// يمكن التمييز بين حجز جارٍ الآن وحجزٍ مات التطبيق في منتصفه.
  Future<bool> claim(
    String accountId,
    String localId, {
    required DateTime attemptedAt,
  });

  /// يُحرِّر حجزًا ويُعيد الأمر إلى `pending` مع تسجيل سبب الفشل.
  Future<void> releaseForRetry(
    String accountId,
    String localId, {
    required String error,
    required DateTime attemptedAt,
  });

  /// يثبّت قبول الخادم: الحالة `confirmed` والردّ مخزَّن.
  Future<void> markConfirmed(
    String accountId,
    String localId, {
    required Map<String, Object?> serverResponse,
    required DateTime attemptedAt,
  });

  /// يحوّل الأمر إلى «يحتاج مراجعة» ويخرجه من إعادة المحاولة التلقائية.
  Future<void> markNeedsReview(
    String accountId,
    String localId, {
    required String error,
    required DateTime attemptedAt,
    Map<String, Object?>? serverResponse,
  });

  /// يسجّل ربط معرّف محلي بمعرّف خادمي.
  Future<void> putMapping(String accountId, IdMapping mapping);

  /// يقرأ ربطًا محسومًا، أو `null` إذا لم يُحسم بعد.
  Future<IdMapping?> mapping(String accountId, String localId, EntityKind kind);

  /// كل الروابط المحسومة لهذا الحساب.
  Future<List<IdMapping>> mappings(String accountId);

  /// وقت آخر مزامنة ناجحة، أو `null` إن لم تحدث بعد.
  Future<DateTime?> lastSuccessfulSyncAt(String accountId);

  Future<void> setLastSuccessfulSyncAt(String accountId, DateTime at);

  /// يُغلق التخزين. لا يحذف شيئًا.
  Future<void> close();
}

/// يُرفع عند محاولة إدخال أمر بمعرّف عملية مستخدَم أصلًا.
class DuplicateCommandIdException implements Exception {
  const DuplicateCommandIdException(this.commandId);

  final String commandId;

  @override
  String toString() => 'معرّف عملية مستخدَم أصلًا: $commandId';
}

/// قدرة اختيارية لمسار الحجوزات؛ لا يغيّر عقد الطابور القديم أو قراءاته.
abstract interface class BookingDispatchStore {
  Future<List<CommandEnvelope>> pendingLegacyCommands(String accountId);
  Future<List<CommandEnvelope>> bookingCreatesReady(
    String accountId, {
    required DateTime now,
    int limit = 20,
  });
  Future<List<CommandEnvelope>> bookingCreatesStale(
    String accountId, {
    required DateTime before,
    int limit = 20,
  });
  Future<bool> claimBookingCreate(
    String accountId,
    String localId, {
    required DateTime attemptedAt,
  });
  Future<bool> finishBookingCreate(
    String accountId,
    String localId, {
    required DateTime claimedAt,
    required CommandStatus status,
    DateTime? nextAttemptAt,
    String? error,
    Map<String, Object?>? response,
    String? entityId,
  });
  Future<DateTime?> bookingCreateNextWake(
    String accountId, {
    required DateTime now,
    required Duration staleClaimTimeout,
  });
}

/// قراءة اختيار الأراضي: صفحة واحدة مع الربط، دون قراءات لكل صف.
class FarmCommandRow {
  const FarmCommandRow({required this.command, this.serverId, this.farmerId});
  final CommandEnvelope command;
  final String? serverId;
  final String? farmerId;
}

abstract interface class FarmSelectionStore {
  Future<List<FarmCommandRow>> farmCommands({
    required String accountId,
    required String wellId,
    required Object farmer,
    int limit = 50,
    String query = '',
  });
}

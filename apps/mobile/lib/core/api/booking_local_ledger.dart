import 'dart:convert';

import '../session/time_integrity.dart';
import '../sync/sqlite_outbox_store.dart';
import '../sync/outbox_store.dart';
import '../sync/command_type.dart';
import '../sync/sync_status.dart';
import 'booking_repository.dart';

class CachedBookingSchedule {
  const CachedBookingSchedule(this.schedule, this.fetchedAt, {this.timeAnchor});
  final WellDaySchedule schedule;
  final DateTime fetchedAt;

  /// مرساة الزمن الخادمية الملتقطة لحظة الجلب نفسه. `null` لكل لقطة
  /// قديمة سبقت جسر الزمن: تُعرض القراءة ولا يُسلَّح عليها انتقال آلي.
  final SessionTimeAnchor? timeAnchor;

  /// اللقطة قراءة فقط، وليست إيصال أثر أعمال أو تفويضًا مستمرًا.
  bool get isCanonicalBusinessReceipt => false;
}

class ServerBookingSessionLink {
  const ServerBookingSessionLink({
    required this.sessionId,
    required this.bookingId,
    required this.wellId,
    required this.startedAt,
  });
  final String sessionId;
  final String bookingId;
  final String wellId;
  final DateTime startedAt;
  String get provenance => 'server_schedule';
  String get syncState => 'server_confirmed';

  Map<String, Object?> toJson() => {
    'session_id': sessionId,
    'booking_id': bookingId,
    'well_id': wellId,
    'started_at': startedAt.toUtc().toIso8601String(),
    'provenance': provenance,
    'sync_state': syncState,
  };

  factory ServerBookingSessionLink.fromJson(Map<String, dynamic> json) {
    if (json['provenance'] != 'server_schedule' ||
        json['sync_state'] != 'server_confirmed') {
      throw StateError('ربط جلسة غير موثوق');
    }
    return ServerBookingSessionLink(
      sessionId: json['session_id'] as String,
      bookingId: json['booking_id'] as String,
      wellId: json['well_id'] as String,
      startedAt: DateTime.parse(json['started_at'] as String),
    );
  }
}

/// جلسة تشغيلية محلية مؤقتة. ليست جلسة خادم ولا تحمل أي أثر مالي.
class LocalProvisionalBookingSession {
  const LocalProvisionalBookingSession({
    required this.localSessionId,
    required this.wellId,
    required this.chainId,
    required this.serverSessionId,
    required this.nextBookingId,
    required this.commandId,
    required this.transitionKey,
    required this.closedLocallyAt,
    required this.startedLocallyAt,
    required this.decisionRevision,
    required this.automationRevision,
    this.reconciliationState = 'awaiting_reconciliation',
  });

  final String localSessionId;
  final String wellId;
  final String chainId;
  final String serverSessionId;
  final String nextBookingId;
  final String commandId;
  final String transitionKey;
  final DateTime closedLocallyAt;
  final DateTime startedLocallyAt;
  final int decisionRevision;
  final int automationRevision;
  final String reconciliationState;

  String get provenance => 'local_offline_provisional';

  Map<String, Object?> toJson() => {
    'local_session_id': localSessionId,
    'well_id': wellId,
    'chain_id': chainId,
    'server_session_id': serverSessionId,
    'next_booking_id': nextBookingId,
    'command_id': commandId,
    'transition_key': transitionKey,
    'closed_locally_at': closedLocallyAt.toUtc().toIso8601String(),
    'started_locally_at': startedLocallyAt.toUtc().toIso8601String(),
    'decision_revision': decisionRevision,
    'automation_revision': automationRevision,
    'provenance': provenance,
    'reconciliation_state': reconciliationState,
  };

  factory LocalProvisionalBookingSession.fromJson(Map<String, dynamic> json) {
    if (json['provenance'] != 'local_offline_provisional' ||
        !{
          'awaiting_reconciliation',
          'reconciled',
          'requires_review',
        }.contains(json['reconciliation_state'])) {
      throw StateError('جلسة تشغيل محلية غير موثوقة');
    }
    return LocalProvisionalBookingSession(
      localSessionId: json['local_session_id'] as String,
      wellId: json['well_id'] as String,
      chainId: json['chain_id'] as String,
      serverSessionId: json['server_session_id'] as String,
      nextBookingId: json['next_booking_id'] as String,
      commandId: json['command_id'] as String,
      transitionKey: json['transition_key'] as String,
      closedLocallyAt: DateTime.parse(json['closed_locally_at'] as String),
      startedLocallyAt: DateTime.parse(json['started_locally_at'] as String),
      decisionRevision: json['decision_revision'] as int,
      automationRevision: json['automation_revision'] as int,
      reconciliationState: json['reconciliation_state'] as String,
    );
  }

  LocalProvisionalBookingSession withReconciliationState(String state) =>
      LocalProvisionalBookingSession(
        localSessionId: localSessionId,
        wellId: wellId,
        chainId: chainId,
        serverSessionId: serverSessionId,
        nextBookingId: nextBookingId,
        commandId: commandId,
        transitionKey: transitionKey,
        closedLocallyAt: closedLocallyAt,
        startedLocallyAt: startedLocallyAt,
        decisionRevision: decisionRevision,
        automationRevision: automationRevision,
        reconciliationState: state,
      );
}

enum BookingIntentState {
  awaitingReconciliation,
  reconciled,
  rejectedRequiresReview,
  missedStartRequiresReview,
}

class BookingServerOutcome {
  const BookingServerOutcome.pending()
    : kind = 'pending',
      commandId = null,
      bookingId = null,
      sessionId = null,
      reason = null;
  const BookingServerOutcome.accepted({
    required this.commandId,
    required this.bookingId,
    required this.sessionId,
  }) : kind = 'accepted',
       reason = null;
  const BookingServerOutcome.rejected(this.reason)
    : kind = 'rejected',
      commandId = null,
      bookingId = null,
      sessionId = null;
  final String kind;
  final String? commandId;
  final String? bookingId;
  final String? sessionId;
  final String? reason;
}

class BookingTransitionIntent {
  const BookingTransitionIntent({
    required this.commandId,
    required this.wellId,
    required this.transitionKey,
    required this.chainId,
    required this.currentSessionId,
    required this.nextBookingId,
    required this.decisionRevision,
    required this.automationRevision,
    required this.state,
    this.canonicalCommandId,
    this.canonicalSessionId,
    this.canonicalMatchKind,
    this.canonicalReceipt,
    this.reviewReason,
  });

  final String commandId;
  final String wellId;
  final String transitionKey;
  final String chainId;
  final String currentSessionId;
  final String nextBookingId;
  final int decisionRevision;
  final int automationRevision;
  final BookingIntentState state;
  final String? canonicalCommandId;
  final String? canonicalSessionId;
  final String? canonicalMatchKind;
  final Map<String, dynamic>? canonicalReceipt;
  final String? reviewReason;

  bool get hasCanonicalReceipt =>
      state == BookingIntentState.reconciled &&
      canonicalCommandId != null &&
      canonicalCommandId!.isNotEmpty &&
      canonicalSessionId != null &&
      canonicalSessionId!.isNotEmpty &&
      (canonicalMatchKind == 'exact_command' ||
          canonicalMatchKind == 'logical_intent') &&
      canonicalReceipt != null;

  Map<String, Object?> toJson() => {
    'command_id': commandId,
    'well_id': wellId,
    'transition_key': transitionKey,
    'chain_id': chainId,
    'current_session_id': currentSessionId,
    'next_booking_id': nextBookingId,
    'decision_revision': decisionRevision,
    'automation_revision': automationRevision,
    'state': state.name,
    if (canonicalCommandId != null) 'canonical_command_id': canonicalCommandId,
    if (canonicalSessionId != null) 'canonical_session_id': canonicalSessionId,
    if (canonicalMatchKind != null) 'canonical_match_kind': canonicalMatchKind,
    if (canonicalReceipt != null) 'canonical_receipt': canonicalReceipt,
    if (reviewReason != null) 'review_reason': reviewReason,
  };

  factory BookingTransitionIntent.fromJson(Map<String, dynamic> json) {
    final intent = BookingTransitionIntent(
      commandId: json['command_id'] as String,
      wellId: json['well_id'] as String,
      transitionKey: json['transition_key'] as String,
      chainId: json['chain_id'] as String,
      currentSessionId: json['current_session_id'] as String,
      nextBookingId: json['next_booking_id'] as String,
      decisionRevision: json['decision_revision'] as int,
      automationRevision: json['automation_revision'] as int,
      state: BookingIntentState.values.byName(json['state'] as String),
      canonicalCommandId: json['canonical_command_id'] as String?,
      canonicalSessionId: json['canonical_session_id'] as String?,
      canonicalMatchKind: json['canonical_match_kind'] as String?,
      canonicalReceipt: json['canonical_receipt'] is Map
          ? Map<String, dynamic>.from(json['canonical_receipt'] as Map)
          : null,
      reviewReason: json['review_reason'] as String?,
    );
    if (intent.state == BookingIntentState.reconciled &&
        !intent.hasCanonicalReceipt) {
      throw StateError('نية متصالحة بلا إيصال خادمي مطابق');
    }
    return intent;
  }

  BookingTransitionIntent _withState(
    BookingIntentState next, {
    String? canonicalCommandId,
    String? canonicalSessionId,
    String? canonicalMatchKind,
    Map<String, dynamic>? canonicalReceipt,
    String? reviewReason,
  }) => BookingTransitionIntent(
    commandId: commandId,
    wellId: wellId,
    transitionKey: transitionKey,
    chainId: chainId,
    currentSessionId: currentSessionId,
    nextBookingId: nextBookingId,
    decisionRevision: decisionRevision,
    automationRevision: automationRevision,
    state: next,
    canonicalCommandId: canonicalCommandId,
    canonicalSessionId: canonicalSessionId,
    canonicalMatchKind: canonicalMatchKind,
    canonicalReceipt: canonicalReceipt,
    reviewReason: reviewReason,
  );
}

/// لقطات قراءة ونوايا بلا أي إرسال لأمر أعمال.
/// سجل جديد مستقل تمامًا عن الأدلة المؤقتة القديمة.
/// الأوامر هي مصدر حالة المصالحة الدائم؛ لا يحمل هوية خادم افتراضية.
class PhoneOwnedBookingTransition {
  const PhoneOwnedBookingTransition({
    required this.intent,
    required this.occurredAt,
    required this.completeLocalId,
    required this.completeCommandId,
    required this.startLocalId,
    required this.startCommandId,
    required this.bookingSnapshot,
    this.reconciliationState = 'pending',
  });
  final BookingTransitionIntent intent;
  final DateTime occurredAt;
  final String completeLocalId;
  final String completeCommandId;
  final String startLocalId;
  final String startCommandId;
  final Map<String, Object?> bookingSnapshot;
  final String reconciliationState;
  String get provenance => 'phone_owned_live_transition';
  static String storageKey(String wellId, String transitionKey) {
    // النسخ والتالي تُحفظ في السجل، لكن لا تُنشئ حدًا ثانيًا للجلسة السابقة.
    final parts = transitionKey.split(':');
    if (parts.length != 5) throw StateError('invalid_transition_key');
    return 'booking.phone_live.v1.$wellId.${parts[0]}:${parts[1]}';
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'provenance': provenance,
    'intent': intent.toJson(),
    'occurred_at': occurredAt.toUtc().toIso8601String(),
    'complete_local_id': completeLocalId,
    'complete_command_id': completeCommandId,
    'start_local_id': startLocalId,
    'start_command_id': startCommandId,
    'booking_snapshot': bookingSnapshot,
    'reconciliation_state': reconciliationState,
  };
  factory PhoneOwnedBookingTransition.fromJson(
    Map<String, dynamic> json, {
    String? state,
  }) {
    if (json['version'] != 1 ||
        json['provenance'] != 'phone_owned_live_transition') {
      throw StateError('invalid_phone_transition');
    }
    return PhoneOwnedBookingTransition(
      intent: BookingTransitionIntent.fromJson(
        Map<String, dynamic>.from(json['intent'] as Map),
      ),
      occurredAt: DateTime.parse(json['occurred_at'] as String).toUtc(),
      completeLocalId: json['complete_local_id'] as String,
      completeCommandId: json['complete_command_id'] as String,
      startLocalId: json['start_local_id'] as String,
      startCommandId: json['start_command_id'] as String,
      bookingSnapshot: Map<String, Object?>.from(
        json['booking_snapshot'] as Map,
      ),
      reconciliationState: state ?? json['reconciliation_state'] as String,
    );
  }
  static Future<PhoneOwnedBookingTransition?> load(
    OutboxStore store,
    String accountId,
    String wellId,
    String transitionKey,
  ) async {
    final raw = await store.readBundle(
      accountId,
      storageKey(wellId, transitionKey),
    );
    if (raw == null) return null;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final record = PhoneOwnedBookingTransition.fromJson(json);
    final complete = await store.commandByLocalId(
      accountId,
      record.completeLocalId,
    );
    final start = await store.commandByLocalId(accountId, record.startLocalId);
    final mapping = await store.mapping(
      accountId,
      record.startLocalId,
      EntityKind.session,
    );
    final invalid =
        record.intent.wellId != wellId ||
        complete == null ||
        start == null ||
        complete.type != CommandType.completeIrrigationSession ||
        start.type != CommandType.startBookingSession ||
        complete.occurredAt != record.occurredAt ||
        start.occurredAt != record.occurredAt ||
        start.prerequisites.length != 1 ||
        start.prerequisites.single != record.completeLocalId ||
        start.payload['p_booking_id'] != record.intent.nextBookingId ||
        (start.status == CommandStatus.confirmed &&
            (mapping == null ||
                mapping.serverId != start.serverResponse?['session_id'])) ||
        complete.commandId != record.completeCommandId ||
        start.commandId != record.startCommandId ||
        complete.status == CommandStatus.review ||
        start.status == CommandStatus.review;
    return PhoneOwnedBookingTransition.fromJson(
      json,
      state: invalid
          ? 'requires_review'
          : start.status == CommandStatus.confirmed
          ? 'server_linked'
          : 'pending',
    );
  }
}

class BookingLocalLedger {
  static String bookedLifecycleKey(String wellId) =>
      'booking.lifecycle.v1.$wellId';

  /// مؤشر بئر واحد؛ سجل الحدث والأوامر يُحفظان ذريًا في OutboxStore.
  static Future<Map<String, dynamic>?> loadBookedLifecycle(
    OutboxStore store,
    String accountId,
    String wellId,
  ) async {
    final raw = await store.readBundle(accountId, bookedLifecycleKey(wellId));
    if (raw == null) return null;
    final value = jsonDecode(raw) as Map<String, dynamic>;
    if (value['version'] != 1 ||
        value['provenance'] != 'phone_owned_booked_lifecycle' ||
        value['well_id'] != wellId) {
      throw StateError('invalid_booked_lifecycle');
    }
    final endId = value['end_chain_local_id'];
    if (endId != null) {
      final command = await store.commandByLocalId(accountId, endId as String);
      if (command == null ||
          command.type != CommandType.endBookingTransitionChain ||
          command.wellId != wellId ||
          command.commandId != value['end_chain_command_id']) {
        throw StateError('missing_or_corrupt_end_chain_command');
      }
      if (command.status == CommandStatus.confirmed &&
          (command.serverResponse?['contract'] !=
                  'end_booking_transition_chain' ||
              command.serverResponse?['version'] != 1 ||
              command.serverResponse?['status'] != 'ended')) {
        throw StateError('invalid_end_chain_confirmation');
      }
      value['server_chain_state'] = command.status == CommandStatus.confirmed
          ? 'ended'
          : 'pending';
      if (command.status == CommandStatus.review) {
        value['state'] = 'requires_review';
        value['server_chain_state'] = 'requires_review';
        value['review_reason'] =
            command.serverResponse?['reason_code'] ?? command.lastError;
      }
    }
    return value;
  }

  BookingLocalLedger(this.store);
  final SqliteOutboxStore store;

  String _scheduleKey(String wellId, String day) =>
      'booking.schedule.$wellId.$day';
  String _latestKey(String wellId) => 'booking.latest.$wellId';
  String _intentKey(String wellId, String key) => 'booking.intent.$wellId.$key';
  String _sessionKey(String wellId) => 'booking.server_session.$wellId';
  String _provisionalSessionKey(String wellId, String transitionKey) =>
      'booking.provisional_session.$wellId.$transitionKey';
  String _automationKey(String wellId) => 'booking.automation.$wellId';

  Future<void> saveAutomation({
    required String accountId,
    required String wellId,
    required Object? response,
  }) async {
    final state = BookingAutomationState.fromContract(response);
    if (state.wellId != wellId) throw StateError('إعداد بئر مختلف');
    await store.writeLocalValue(
      accountId,
      _automationKey(wellId),
      jsonEncode(response),
    );
  }

  Future<BookingAutomationState?> loadAutomation(
    String accountId,
    String wellId,
  ) async {
    final raw = await store.readLocalValue(accountId, _automationKey(wellId));
    if (raw == null) return null;
    try {
      final state = BookingAutomationState.fromContract(jsonDecode(raw));
      return state.wellId == wellId ? state : null;
    } catch (_) {
      return null;
    }
  }

  Future<ServerBookingSessionLink> importServerSession({
    required String accountId,
    required String wellId,
    required String sessionId,
    required String bookingId,
    required DateTime startedAt,
  }) async {
    if (sessionId.isEmpty || bookingId.isEmpty || wellId.isEmpty) {
      throw StateError('ربط جلسة ناقص');
    }
    final candidate = ServerBookingSessionLink(
      sessionId: sessionId,
      bookingId: bookingId,
      wellId: wellId,
      startedAt: startedAt,
    );
    final persisted = await store.writeLocalValueOnce(
      accountId,
      _sessionKey(wellId),
      jsonEncode(candidate.toJson()),
    );
    final existing = ServerBookingSessionLink.fromJson(
      jsonDecode(persisted) as Map<String, dynamic>,
    );
    if (existing.wellId != wellId ||
        existing.sessionId != sessionId ||
        existing.bookingId != bookingId ||
        existing.startedAt.toUtc() != startedAt.toUtc()) {
      throw StateError('جلسة الخادم تختلف عن الربط المحلي؛ تحتاج مراجعة');
    }
    return existing;
  }

  /// يحذف رابط التوافق فقط بعد قراءة خادم حديثة تثبت غياب الجلسة.
  Future<void> clearServerSession(String accountId, String wellId) =>
      store.deleteLocalValue(accountId, _sessionKey(wellId));

  Future<ServerBookingSessionLink?> loadServerSession(
    String accountId,
    String wellId,
  ) async {
    final raw = await store.readLocalValue(accountId, _sessionKey(wellId));
    if (raw == null) return null;
    try {
      final link = ServerBookingSessionLink.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return link.wellId == wellId ? link : null;
    } catch (_) {
      return null;
    }
  }

  /// يقدّم رابط جلسة الخادم فقط مع إيصال مصالحة يتحقق من إغلاق الرابط
  /// السابق. يبقى الرابط السابق محفوظًا في الدليل المحلي المؤقت للانتقال.
  Future<ServerBookingSessionLink> advanceServerSessionFromReceipt({
    required String accountId,
    required String wellId,
    required String closedSessionId,
    required String startedSessionId,
    required String startedBookingId,
    required DateTime startedAt,
  }) async {
    final prior = await loadServerSession(accountId, wellId);
    if (prior != null && prior.sessionId != closedSessionId) {
      throw StateError('إيصال الخادم لا يطابق الجلسة المحلية المرتبطة');
    }
    final next = ServerBookingSessionLink(
      sessionId: startedSessionId,
      bookingId: startedBookingId,
      wellId: wellId,
      startedAt: startedAt,
    );
    await store.writeLocalValue(
      accountId,
      _sessionKey(wellId),
      jsonEncode(next.toJson()),
    );
    return next;
  }

  Future<LocalProvisionalBookingSession?> loadProvisionalSession(
    String accountId,
    String wellId,
    String transitionKey,
  ) async {
    final raw = await store.readLocalValue(
      accountId,
      _provisionalSessionKey(wellId, transitionKey),
    );
    if (raw == null) return null;
    try {
      final session = LocalProvisionalBookingSession.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return session.wellId == wellId ? session : null;
    } catch (_) {
      return null;
    }
  }

  Future<List<LocalProvisionalBookingSession>> loadProvisionalSessions(
    String accountId,
    String wellId,
  ) async {
    final values = await store.readLocalValuesByPrefix(
      accountId,
      'booking.provisional_session.$wellId.',
    );
    final sessions = <LocalProvisionalBookingSession>[];
    for (final value in values) {
      try {
        final session = LocalProvisionalBookingSession.fromJson(
          jsonDecode(value) as Map<String, dynamic>,
        );
        if (session.wellId == wellId) sessions.add(session);
      } catch (_) {
        // الدليل الفاسد لا يصبح جلسة تشغيلية قابلة للعرض أو الاستمرار.
      }
    }
    sessions.sort((a, b) => b.startedLocallyAt.compareTo(a.startedLocallyAt));
    return List.unmodifiable(sessions);
  }

  Future<(BookingTransitionIntent, LocalProvisionalBookingSession)>
  recordOperationalTransition({
    required String accountId,
    required BookingTransitionIntent intent,
    required String localSessionId,
    required DateTime occurredAt,
    bool Function()? isCurrent,
  }) async {
    final pair = await store.writeLocalPairOnce(
      accountId: accountId,
      primaryKey: _intentKey(intent.wellId, intent.transitionKey),
      primaryValue: jsonEncode(intent.toJson()),
      secondaryKey: _provisionalSessionKey(intent.wellId, intent.transitionKey),
      isCurrent: isCurrent,
      secondaryValue: (raw) {
        final stored = BookingTransitionIntent.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (stored.state != BookingIntentState.awaitingReconciliation ||
            stored.wellId != intent.wellId ||
            stored.chainId != intent.chainId ||
            stored.currentSessionId != intent.currentSessionId ||
            stored.nextBookingId != intent.nextBookingId ||
            stored.decisionRevision != intent.decisionRevision ||
            stored.automationRevision != intent.automationRevision) {
          throw StateError('تعارض نية محفوظة');
        }
        return jsonEncode(
          LocalProvisionalBookingSession(
            localSessionId: localSessionId,
            wellId: stored.wellId,
            chainId: stored.chainId,
            serverSessionId: stored.currentSessionId,
            nextBookingId: stored.nextBookingId,
            commandId: stored.commandId,
            transitionKey: stored.transitionKey,
            closedLocallyAt: occurredAt,
            startedLocallyAt: occurredAt,
            decisionRevision: stored.decisionRevision,
            automationRevision: stored.automationRevision,
          ).toJson(),
        );
      },
    );
    return (
      BookingTransitionIntent.fromJson(
        jsonDecode(pair.$1) as Map<String, dynamic>,
      ),
      LocalProvisionalBookingSession.fromJson(
        jsonDecode(pair.$2) as Map<String, dynamic>,
      ),
    );
  }

  Future<LocalProvisionalBookingSession> recordProvisionalSession({
    required String accountId,
    required BookingTransitionIntent intent,
    required String localSessionId,
    required DateTime occurredAt,
  }) async {
    if (localSessionId.isEmpty ||
        intent.state != BookingIntentState.awaitingReconciliation) {
      throw StateError('جلسة انتقال محلية غير صالحة');
    }
    final proposed = LocalProvisionalBookingSession(
      localSessionId: localSessionId,
      wellId: intent.wellId,
      chainId: intent.chainId,
      serverSessionId: intent.currentSessionId,
      nextBookingId: intent.nextBookingId,
      commandId: intent.commandId,
      transitionKey: intent.transitionKey,
      closedLocallyAt: occurredAt,
      startedLocallyAt: occurredAt,
      decisionRevision: intent.decisionRevision,
      automationRevision: intent.automationRevision,
    );
    final persisted = await store.writeLocalValueOnce(
      accountId,
      _provisionalSessionKey(intent.wellId, intent.transitionKey),
      jsonEncode(proposed.toJson()),
    );
    final existing = LocalProvisionalBookingSession.fromJson(
      jsonDecode(persisted) as Map<String, dynamic>,
    );
    if (existing.wellId != intent.wellId ||
        existing.transitionKey != intent.transitionKey ||
        existing.commandId != intent.commandId ||
        existing.serverSessionId != intent.currentSessionId ||
        existing.nextBookingId != intent.nextBookingId) {
      throw StateError('جلسة انتقال محلية تختلف عن الدليل المحفوظ');
    }
    return existing;
  }

  Future<void> _setProvisionalReconciliationState({
    required String accountId,
    required BookingTransitionIntent intent,
    required String state,
  }) async {
    final session = await loadProvisionalSession(
      accountId,
      intent.wellId,
      intent.transitionKey,
    );
    if (session == null ||
        session.transitionKey != intent.transitionKey ||
        session.commandId != intent.commandId) {
      return;
    }
    await store.writeLocalValue(
      accountId,
      _provisionalSessionKey(intent.wellId, intent.transitionKey),
      jsonEncode(session.withReconciliationState(state).toJson()),
    );
  }

  /// يحفظ الجدول والمرساة الزمنية في payload واحد ذري: ما يُقرأ لاحقًا
  /// هو زوج (schedule, anchor) لا يمكن أن يتزاوج فيه جدول جديد بمرساة
  /// قديمة. المرساة nullable: غيابها = لقطة بلا انتقال آلي موثوق.
  Future<void> saveSchedule({
    required String accountId,
    required String wellId,
    required Object? response,
    required DateTime fetchedAt,
    SessionTimeAnchor? timeAnchor,
  }) async {
    final schedule = WellDaySchedule.fromContract(response);
    if (schedule.wellId != wellId) throw StateError('جدول بئر مختلف');
    if (timeAnchor != null &&
        (timeAnchor.serverTime == null ||
            timeAnchor.serverTime != schedule.serverTime)) {
      throw StateError('مرساة لا تطابق لقطة الخادم');
    }
    final day = _day(schedule.requestedDay);
    if (schedule.bookings.any(
          (booking) => booking.wellId != wellId || booking.scheduledDay != day,
        ) ||
        (schedule.currentSession != null &&
            schedule.currentSession!.wellId != wellId)) {
      throw StateError('جدول الحجوزات يحتوي بيانات بئر أو يوم مختلف');
    }
    final payload = jsonEncode({
      'fetched_at': fetchedAt.toUtc().toIso8601String(),
      'response': response,
      if (timeAnchor != null) 'time_anchor': _encodeAnchor(timeAnchor),
    });
    await store.writeLocalValue(accountId, _scheduleKey(wellId, day), payload);
    await store.writeLocalValue(accountId, _latestKey(wellId), day);
  }

  /// المرساة تُسافر داخل نفس payload الجدول فلا تتزاوج مرساة قديمة
  /// برد جديد. غياب المفتاح (cache من PR #60) يقرأ بنجاح بـanchor
  /// فارغة، والفساد يُقرأ كغياب لا كـcrash.
  Map<String, Object?> _encodeAnchor(SessionTimeAnchor anchor) => {
    'server_time': anchor.serverTime?.toUtc().toIso8601String(),
    'wall_clock': anchor.wallClock.toUtc().toIso8601String(),
    'monotonic_ms': anchor.monotonic.inMilliseconds,
    'boot_id': anchor.bootId,
  };

  SessionTimeAnchor? _decodeAnchor(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) return null;
    try {
      final json = Map<String, dynamic>.from(raw);
      final serverTime = json['server_time'];
      final wallClock = DateTime.parse(json['wall_clock'] as String);
      final monotonic = json['monotonic_ms'];
      final bootId = json['boot_id'];
      if (wallClock.toUtc().year < 2000 ||
          monotonic is! num ||
          monotonic < 0 ||
          bootId is! String ||
          bootId.isEmpty) {
        return null;
      }
      return SessionTimeAnchor(
        serverTime: serverTime == null
            ? null
            : DateTime.parse(serverTime as String),
        wallClock: wallClock,
        monotonic: Duration(milliseconds: monotonic as int),
        bootId: bootId,
      );
    } catch (_) {
      return null;
    }
  }

  Future<CachedBookingSchedule?> loadSchedule(
    String accountId,
    String wellId,
    String day,
  ) async {
    final raw = await store.readLocalValue(
      accountId,
      _scheduleKey(wellId, day),
    );
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final schedule = WellDaySchedule.fromContract(json['response']);
      if (schedule.wellId != wellId ||
          _day(schedule.requestedDay) != day ||
          schedule.bookings.any(
            (booking) =>
                booking.wellId != wellId || booking.scheduledDay != day,
          ) ||
          (schedule.currentSession != null &&
              schedule.currentSession!.wellId != wellId)) {
        return null;
      }
      final decodedAnchor = _decodeAnchor(json['time_anchor']);
      final anchor = decodedAnchor?.serverTime == schedule.serverTime
          ? decodedAnchor
          : null;
      return CachedBookingSchedule(
        schedule,
        DateTime.parse(json['fetched_at'] as String),
        timeAnchor: anchor,
      );
    } catch (_) {
      return null;
    }
  }

  Future<CachedBookingSchedule?> loadLatestSchedule(
    String accountId,
    String wellId,
  ) async {
    final day = await store.readLocalValue(accountId, _latestKey(wellId));
    return day == null ? null : loadSchedule(accountId, wellId, day);
  }

  Future<BookingTransitionIntent> recordIntent({
    required String accountId,
    required String wellId,
    required String transitionKey,
    required String commandId,
    required String chainId,
    required String currentSessionId,
    required String nextBookingId,
    required int decisionRevision,
    required int automationRevision,
  }) async {
    if (wellId.isEmpty ||
        transitionKey.isEmpty ||
        commandId.isEmpty ||
        chainId.isEmpty ||
        currentSessionId.isEmpty ||
        nextBookingId.isEmpty ||
        currentSessionId == nextBookingId ||
        decisionRevision < 0 ||
        automationRevision < 0) {
      throw StateError('نية انتقال غير صالحة');
    }
    final proposed = BookingTransitionIntent(
      commandId: commandId,
      wellId: wellId,
      transitionKey: transitionKey,
      chainId: chainId,
      currentSessionId: currentSessionId,
      nextBookingId: nextBookingId,
      decisionRevision: decisionRevision,
      automationRevision: automationRevision,
      state: BookingIntentState.awaitingReconciliation,
    );
    final persisted = await store.writeLocalValueOnce(
      accountId,
      _intentKey(wellId, transitionKey),
      jsonEncode(proposed.toJson()),
    );
    final existing = BookingTransitionIntent.fromJson(
      jsonDecode(persisted) as Map<String, dynamic>,
    );
    if (existing.wellId != wellId ||
        existing.transitionKey != transitionKey ||
        existing.chainId != chainId ||
        existing.currentSessionId != currentSessionId ||
        existing.nextBookingId != nextBookingId ||
        existing.decisionRevision != decisionRevision ||
        existing.automationRevision != automationRevision) {
      throw StateError('تعارض نية انتقال محفوظة');
    }
    return existing;
  }

  Future<List<BookingTransitionIntent>> loadAwaitingIntents(
    String accountId,
    String wellId,
  ) async {
    final values = await store.readLocalValuesByPrefix(
      accountId,
      'booking.intent.$wellId.',
    );
    final intents = <BookingTransitionIntent>[];
    for (final raw in values) {
      try {
        final intent = BookingTransitionIntent.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (intent.wellId == wellId &&
            intent.state == BookingIntentState.awaitingReconciliation) {
          intents.add(intent);
        }
      } catch (_) {
        // تلف دليل محلي لا يصبح نية قابلة لإعادة التشغيل أو المصالحة.
      }
    }
    return intents;
  }

  Future<BookingTransitionIntent?> loadIntent(
    String accountId,
    String wellId,
    String transitionKey,
  ) async {
    final raw = await store.readLocalValue(
      accountId,
      _intentKey(wellId, transitionKey),
    );
    if (raw == null) return null;
    try {
      final intent = BookingTransitionIntent.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return intent.wellId == wellId && intent.transitionKey == transitionKey
          ? intent
          : null;
    } catch (_) {
      return null;
    }
  }

  /// لا يُستدعى إلا بنتيجة خادمية موثوقة. القراءة القديمة ليست إيصالًا.
  Future<BookingTransitionIntent> reconcileIntent(
    String accountId,
    BookingTransitionIntent intent,
    BookingServerOutcome outcome,
  ) async {
    final existing = await loadIntent(
      accountId,
      intent.wellId,
      intent.transitionKey,
    );
    if (existing == null || existing.commandId != intent.commandId) {
      throw StateError('نية الانتقال الأصلية غير موجودة');
    }
    if (existing.state == BookingIntentState.reconciled ||
        existing.state == BookingIntentState.rejectedRequiresReview ||
        existing.state == BookingIntentState.missedStartRequiresReview) {
      return existing;
    }
    final BookingTransitionIntent next;
    if (outcome.kind == 'accepted') {
      // لا تسمح واجهة الاختبار القديمة بتحمل كامل إيصال القراءة؛ إبقاؤها
      // مراجعة يمنع نجاحًا كاذبًا. المصالحة الفعلية تستدعي الدالة أدناه.
      next = existing._withState(
        BookingIntentState.rejectedRequiresReview,
        reviewReason: 'incomplete_canonical_evidence',
      );
    } else if (outcome.kind == 'pending') {
      next = existing;
    } else {
      next = existing._withState(
        BookingIntentState.rejectedRequiresReview,
        reviewReason: outcome.reason ?? 'canonical_evidence_mismatch',
      );
    }
    await store.writeLocalValue(
      accountId,
      _intentKey(existing.wellId, existing.transitionKey),
      jsonEncode(next.toJson()),
    );
    await _setProvisionalReconciliationState(
      accountId: accountId,
      intent: existing,
      state: next.state == BookingIntentState.reconciled
          ? 'reconciled'
          : 'requires_review',
    );
    return next;
  }

  /// يستهلك فقط إسقاط عقد القراءة المحقق. لا يرسل أمر أعمال ولا يبدّل
  /// command_id المحلي؛ المطابقة المنطقية تحمل command كنونيًا منفصلًا.
  Future<BookingTransitionIntent> reconcileReadResult(
    String accountId,
    BookingTransitionIntent intent,
    BookingTransitionReconciliation result,
  ) async {
    final existing = await loadIntent(
      accountId,
      intent.wellId,
      intent.transitionKey,
    );
    if (existing == null || existing.commandId != intent.commandId) {
      throw StateError('نية الانتقال الأصلية غير موجودة');
    }
    if (existing.state == BookingIntentState.reconciled ||
        existing.state == BookingIntentState.rejectedRequiresReview ||
        existing.state == BookingIntentState.missedStartRequiresReview) {
      return existing;
    }

    final requestMatches =
        result.requestedCommandId == existing.commandId &&
        result.wellId == existing.wellId &&
        result.chainId == existing.chainId &&
        result.currentSessionId == existing.currentSessionId &&
        result.nextBookingId == existing.nextBookingId &&
        result.decisionRevision == existing.decisionRevision &&
        result.automationRevision == existing.automationRevision;
    final receipt = result.receipt;
    final receiptMatches =
        receipt != null &&
        receipt.closedSessionId == existing.currentSessionId &&
        receipt.startedBookingId == existing.nextBookingId &&
        receipt.startedSessionId.isNotEmpty;

    BookingTransitionIntent next;
    if (requestMatches && result.isCanonicalMatch && receiptMatches) {
      try {
        await advanceServerSessionFromReceipt(
          accountId: accountId,
          wellId: existing.wellId,
          closedSessionId: receipt.closedSessionId,
          startedSessionId: receipt.startedSessionId,
          startedBookingId: receipt.startedBookingId,
          startedAt: receipt.startedAt,
        );
        next = existing._withState(
          BookingIntentState.reconciled,
          canonicalCommandId: result.canonicalCommandId,
          canonicalSessionId: receipt.startedSessionId,
          canonicalMatchKind: result.matchKind,
          canonicalReceipt: receipt.toJson(),
        );
      } catch (_) {
        next = existing._withState(
          BookingIntentState.rejectedRequiresReview,
          reviewReason: 'server_session_conflict',
        );
      }
    } else {
      next = existing._withState(
        BookingIntentState.rejectedRequiresReview,
        reviewReason: requestMatches
            ? (result.reviewReason ?? 'canonical_evidence_mismatch')
            : 'intent_mismatch',
      );
    }
    await store.writeLocalValue(
      accountId,
      _intentKey(existing.wellId, existing.transitionKey),
      jsonEncode(next.toJson()),
    );
    await _setProvisionalReconciliationState(
      accountId: accountId,
      intent: existing,
      state: next.state == BookingIntentState.reconciled
          ? 'reconciled'
          : 'requires_review',
    );
    return next;
  }

  Future<BookingTransitionIntent> markMissedStart(
    String accountId,
    BookingTransitionIntent intent,
  ) async {
    final existing = await loadIntent(
      accountId,
      intent.wellId,
      intent.transitionKey,
    );
    if (existing == null || existing.commandId != intent.commandId) {
      throw StateError('نية الانتقال الأصلية غير موجودة');
    }
    if (existing.state == BookingIntentState.reconciled) return existing;
    final missed = existing._withState(
      BookingIntentState.missedStartRequiresReview,
      reviewReason: 'missed_transition',
    );
    await store.writeLocalValue(
      accountId,
      _intentKey(existing.wellId, existing.transitionKey),
      jsonEncode(missed.toJson()),
    );
    await _setProvisionalReconciliationState(
      accountId: accountId,
      intent: existing,
      state: 'requires_review',
    );
    return missed;
  }

  String _day(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}

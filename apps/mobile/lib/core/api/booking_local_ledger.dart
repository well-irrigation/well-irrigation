import 'dart:convert';

import '../sync/sqlite_outbox_store.dart';
import 'booking_repository.dart';

class CachedBookingSchedule {
  const CachedBookingSchedule(this.schedule, this.fetchedAt);
  final WellDaySchedule schedule;
  final DateTime fetchedAt;

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
class BookingLocalLedger {
  BookingLocalLedger(this.store);
  final SqliteOutboxStore store;

  String _scheduleKey(String wellId, String day) =>
      'booking.schedule.$wellId.$day';
  String _latestKey(String wellId) => 'booking.latest.$wellId';
  String _intentKey(String wellId, String key) => 'booking.intent.$wellId.$key';
  String _sessionKey(String wellId) => 'booking.server_session.$wellId';
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

  Future<void> saveSchedule({
    required String accountId,
    required String wellId,
    required Object? response,
    required DateTime fetchedAt,
  }) async {
    final schedule = WellDaySchedule.fromContract(response);
    if (schedule.wellId != wellId) throw StateError('جدول بئر مختلف');
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
    });
    await store.writeLocalValue(accountId, _scheduleKey(wellId, day), payload);
    await store.writeLocalValue(accountId, _latestKey(wellId), day);
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
      return CachedBookingSchedule(
        schedule,
        DateTime.parse(json['fetched_at'] as String),
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

    final requestMatches = result.requestedCommandId == existing.commandId &&
        result.wellId == existing.wellId &&
        result.chainId == existing.chainId &&
        result.currentSessionId == existing.currentSessionId &&
        result.nextBookingId == existing.nextBookingId &&
        result.decisionRevision == existing.decisionRevision &&
        result.automationRevision == existing.automationRevision;
    final receipt = result.receipt;
    final receiptMatches = receipt != null &&
        receipt.closedSessionId == existing.currentSessionId &&
        receipt.startedBookingId == existing.nextBookingId &&
        receipt.startedSessionId.isNotEmpty;

    BookingTransitionIntent next;
    if (requestMatches && result.isCanonicalMatch && receiptMatches) {
      try {
        await importServerSession(
          accountId: accountId,
          wellId: existing.wellId,
          sessionId: receipt.startedSessionId,
          bookingId: receipt.startedBookingId,
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
    return missed;
  }

  String _day(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}

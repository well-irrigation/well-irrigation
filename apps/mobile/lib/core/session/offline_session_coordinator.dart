// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/operations_repository.dart';
import '../api/booking_local_ledger.dart';
import '../api/booking_repository.dart';
import '../booking/booking_reactivity.dart';
import 'local_booking_transition_resolver.dart';
import '../sync/command_envelope.dart';
import '../sync/command_reference.dart';
import '../sync/command_transport.dart';
import '../sync/command_type.dart';
import '../sync/entity_reference.dart';
import '../sync/farmer_identity_review.dart';
import '../sync/outbox_repository.dart';
import '../sync/outbox_store.dart';
import '../sync/sqlite_outbox_store.dart';
import '../sync/supabase_command_transport.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_status.dart';
import 'active_session_projector.dart';
import 'active_session_record.dart';
import 'session_crop_snapshot.dart';
import 'time_integrity.dart';

/// نتيجة قراءة فقط من الطابور وقراءة مالية خادمية محفوظة فيه.
/// إصدار الدفعات يمنع رفع قراءة بدأت قبل الإقرار إلى حقيقة سارية بعده.
class CompletedSessionPaymentState {
  CompletedSessionPaymentState({
    required this.record,
    required this.revision,
    Map<String, Object?>? paymentRead,
  }) : storedRead = paymentRead,
       paymentRead = paymentRead?['revision'] == revision ? paymentRead : null;
  final ActiveSessionRecord record;
  final String revision;
  final Map<String, Object?>? paymentRead;
  final Map<String, Object?>? storedRead;
  SessionDetailData? get cachedDetail {
    final raw = storedRead?['detail'];
    if (raw is! Map) return null;
    final value = Map<String, dynamic>.from(raw);
    return SessionDetailData(
      session: SessionHistoryItem.fromContract(
        Map<String, dynamic>.from(value['session'] as Map),
      ),
      segments: [
        for (final segment in value['segments'] as List)
          SessionSegmentItem.fromContract(
            Map<String, dynamic>.from(segment as Map),
          ),
      ],
      crops: List<String>.from(value['crops'] as List),
      paymentMethod: value['payment_method'] as String?,
      paymentReference: value['payment_reference'] as String?,
      paidAt: value['paid_at'] == null
          ? null
          : DateTime.parse(value['paid_at'] as String),
    );
  }

  bool get hasPendingPayment => record.payments.any((p) => !p.isPosted);
  bool get needsReview =>
      record.payments.any((p) => p.status == CommandStatus.review);
  bool get needsCanonicalRead =>
      record.payments.any((p) => p.isPosted) && paymentRead == null;
  String? get paymentStatus => paymentRead?['payment_status'] as String?;
  bool get canRecordPayment =>
      record.completedAt != null &&
      record.completionCommandLocalId != null &&
      !hasPendingPayment &&
      !needsCanonicalRead &&
      (paymentRead?['has_charge'] != true ||
          (paymentRead?['remaining_amount_minor'] as int? ?? 0) > 0) &&
      paymentStatus != 'settled' &&
      (paymentStatus == null ||
          const ['unpaid', 'partial', 'not_billed'].contains(paymentStatus));
}

/// نتيجة فحص أو تسجيل انتقال تشغيلي محلي مؤقت.
///
/// لا تمثل إيصال خادم؛ liveTransition يحمل دليل الأوامر الحقيقية المتينة.
class LocalBookingTransitionResult {
  const LocalBookingTransitionResult({
    required this.outcome,
    required this.reason,
    this.intent,
    this.session,
    this.liveTransition,
  });

  final LocalBookingTransitionOutcome outcome;
  final String reason;
  final BookingTransitionIntent? intent;
  final LocalProvisionalBookingSession? session;
  final PhoneOwnedBookingTransition? liveTransition;

  bool get transitioned =>
      outcome == LocalBookingTransitionOutcome.transitioned ||
      outcome == LocalBookingTransitionOutcome.alreadyRecorded;
}

enum LocalBookingTransitionOutcome {
  notDue,
  transitioned,
  alreadyRecorded,
  blocked,
  missedRequiresReview,
  timeIntegrityRequiresReview,
}

/// زمن تنفيذ موثوق للانتقال الآلي، ينتج عن resolver مركزي فقط.
///
/// النوع الخاص يمنع إنشائه من `DateTime.now` أو ساعة الحائط: الطريق
/// الوحيد إليه عبر [OfflineSessionCoordinator] الذي يتحقق من المرساة
/// والجسر بنفسه قبل منحه.
class TrustedTransitionTime {
  const TrustedTransitionTime._(this.at);

  final DateTime at;

  /// يُبنى فقط من نتيجة resolver موثوقة — لا مسار عام ينشئه من wall clock.
  static TrustedTransitionTime fromResolved(ServerAlignedNow resolved) =>
      TrustedTransitionTime._(resolved.at);
}

/// منسق جلسات السقي والعمل دون اتصال والمزامنة المتينة (ق-89 / ق-90 / ق-114)
///
/// يربط:
/// - الطابور المتين المحلي (`OutboxRepository` / SQLite / In-Memory).
/// - مُسقط الجلسة الحية الخالص (`ActiveSessionProjector`).
/// - محرك المزامنة المرتب مع الخادم (`SyncEngine` / `SupabaseCommandTransport`).
class OfflineSessionCoordinator {
  OfflineSessionCoordinator({
    OutboxStore? store,
    SupabaseClient? supabaseClient,
    CommandTransport? commandTransport,
    PricingResolver? pricingResolver,
    Future<bool> Function(String accountId)? commandQueuedScheduler,
    BookingLocalLedger? bookingLedger,
    TimeIntegritySource? timeIntegritySource,
  }) : _store = store ?? SqliteOutboxStore(),
       _commandQueuedScheduler = commandQueuedScheduler,
       // لا سعر افتراضي في العميل (م-41D6): اللقطات تُغذّى من
       // `api.get_active_price_schedule` عبر `updatePricing`. حتى تُغذّى،
       // كل مقطع محتسب «بانتظار المزامنة» ولا يُسعَّر بصفر (القرار 341).
       _pricingResolver = pricingResolver ?? const PricingResolver.none() {
    _bookingLedger =
        bookingLedger ??
        (_store is SqliteOutboxStore ? BookingLocalLedger(_store) : null);
    _timeIntegritySource = timeIntegritySource ?? AndroidTimeIntegritySource();
    _outbox = OutboxRepository(store: _store);
    _projector = ActiveSessionProjector(
      store: _store,
      pricing: _pricingResolver,
      bookedTimeSource: _timeIntegritySource,
    );
    final transport =
        commandTransport ??
        (supabaseClient == null
            ? null
            : SupabaseCommandTransport(supabaseClient));
    if (transport != null) {
      _syncEngine = SyncEngine(store: _store, transport: transport);
    }
  }

  static OfflineSessionCoordinator? _instance;
  static SupabaseClient? _foregroundSupabaseClient;

  /// يربط النسخة العامة بعميل التطبيق الحقيقي قبل أن تستخدمها الشاشات.
  static void configureForegroundSync(SupabaseClient client) {
    if (_instance != null) {
      throw StateError('يجب ربط مزامنة المقدمة قبل إنشاء المنسق العام');
    }
    _foregroundSupabaseClient = client;
  }

  static OfflineSessionCoordinator get instance => _instance ??=
      OfflineSessionCoordinator(supabaseClient: _foregroundSupabaseClient);

  final OutboxStore _store;
  BookingLocalLedger? _bookingLedger;

  /// جسر قراءة الزمن المحلي. `null` = لا انتقال آلي موثوق أبدًا.
  TimeIntegritySource? _timeIntegritySource;
  ServerBookingSessionLink? _serverBookingSession;
  ServerBookingSessionLink? get serverBookingSession => _serverBookingSession;

  Future<ServerBookingSessionLink?> restoreServerBookingSession({
    required String accountId,
    required String wellId,
  }) async {
    _serverBookingSession = await _bookingLedger?.loadServerSession(
      accountId,
      wellId,
    );
    return _serverBookingSession;
  }

  /// يسترجع أحدث جلسة تشغيلية محلية معلقة لهذا البئر من الدليل المتين.
  /// لا يحولها إلى جلسة خادم ولا يغير حالتها.
  Future<LocalProvisionalBookingSession?> restoreProvisionalBookingSession({
    required String accountId,
    required String wellId,
  }) async {
    final sessions = await _bookingLedger?.loadProvisionalSessions(
      accountId,
      wellId,
    );
    if (sessions == null) return null;
    for (final session in sessions) {
      if (session.reconciliationState == 'awaiting_reconciliation') {
        return session;
      }
    }
    return sessions.isEmpty ? null : sessions.first;
  }

  /// يُستدعى بعد قراءة جدول خادمية ناجحة غير مخزنة مؤقتًا فقط.
  Future<ServerBookingSessionLink?> reconcileServerBookingSession({
    required String accountId,
    required String wellId,
    required CurrentBookingSession? current,
  }) async {
    final ledger = _bookingLedger;
    if (ledger == null) throw StateError('لا يوجد تخزين متين لربط الجلسة');
    if (current == null) {
      await ledger.clearServerSession(accountId, wellId);
      _serverBookingSession = null;
      return null;
    }
    if (current.wellId != wellId ||
        current.bookingId == null ||
        current.status != 'open') {
      throw StateError('جلسة خادم غير قابلة للمصالحة');
    }
    final local = currentActiveSession;
    if (local?.phoneOwned == true &&
        local?.wellId == wellId &&
        local?.serverSessionId != current.sessionId) {
      // لقطة الخادم قد تبقى على A إلى أن يصل الأمران؛ B المحلية حاكمة للعرض.
      return ledger.loadServerSession(accountId, wellId);
    }
    if (local != null &&
        local.wellId == wellId &&
        local.serverSessionId != current.sessionId) {
      throw StateError('جلسة الخادم تختلف عن الجلسة المحلية');
    }
    _serverBookingSession = await ledger.importServerSession(
      accountId: accountId,
      wellId: wellId,
      sessionId: current.sessionId,
      bookingId: current.bookingId!,
      startedAt: current.startedAt,
    );
    return _serverBookingSession;
  }

  /// يفحص الزمن قبل أي قرار أو كتابة: يقرأ جسر الزمن مرة واحدة ويحسم
  /// «الآن» الخادمي من مرساة اللقطة المخزنة ذريًّا معها. يعيد `null`
  /// عند كل سبب يجعل الانتقال الآلي غير موثوق — والشاشة تعرض حالة
  /// مراجعة، ولا catch-up ولا حسم من ساعة حائط.
  Future<ServerAlignedNow?> _resolveTrustedTransitionNow(
    CachedBookingSchedule cachedSchedule,
  ) async {
    final anchor = cachedSchedule.timeAnchor;
    if (anchor == null ||
        anchor.serverTime == null ||
        anchor.serverTime != cachedSchedule.schedule.serverTime) {
      return null;
    }
    final source = _timeIntegritySource;
    if (source == null) return null;
    final TimeReading reading;
    try {
      reading = await source.read();
    } catch (_) {
      return null;
    }
    final resolved = resolveServerAlignedNow(anchor: anchor, reading: reading);
    return resolved.trustedForAutomaticTransition ? resolved : null;
  }

  /// منظور أهلية فقط: اللقطة الكنونية تبقى محفوظة كما وصلت.
  /// هوية الجلسة هنا محلية صريحة؛ serverSessionId لا يُخترع قبل القبول.
  WellDaySchedule? phoneOwnedBookingSchedule(
    WellDaySchedule schedule, {
    required BookingAutomationState? automation,
  }) {
    final active = currentActiveSession;
    if (active == null ||
        !active.phoneOwned ||
        active.wellId != schedule.wellId) {
      return schedule;
    }
    final context = active.bookingContext;
    if (active.syncState == SessionSyncState.conflict ||
        automation?.activeChainId != context['chain_id'] ||
        automation?.revision != context['automation_revision'] ||
        automation?.activeChainDecisionRevision !=
            context['decision_revision']) {
      return null;
    }
    final bookings = schedule.bookings
        .where((b) => b.id == active.bookingId)
        .toList();
    if (bookings.length != 1) return null;
    final current = bookings.single;
    if (current.status != 'confirmed' ||
        current.farmId != context['p_farm_id'] ||
        current.farmerWellAccountId != context['p_farmer_well_account_id'] ||
        current.expectedEnergySource != context['p_energy_source'] ||
        current.alternativeEnergySource !=
            context['alternative_energy_source'] ||
        current.expectedDurationMinutes !=
            context['expected_duration_minutes'] ||
        current.scheduledStart.toUtc().toIso8601String() !=
            context['scheduled_start'] ||
        current.scheduledEnd.toUtc().toIso8601String() !=
            context['scheduled_end']) {
      return null;
    }
    final consumed = (context['consumed_booking_ids'] as List? ?? const [])
        .cast<String>()
        .toSet();
    return WellDaySchedule(
      wellId: schedule.wellId,
      requestedDay: schedule.requestedDay,
      serverTime: schedule.serverTime,
      timezone: schedule.timezone,
      dayStart: schedule.dayStart,
      dayEnd: schedule.dayEnd,
      wellTimezone: schedule.wellTimezone,
      sourceResponse: schedule.sourceResponse,
      bookings: schedule.bookings
          .where((b) => !consumed.contains(b.id))
          .toList(),
      currentSession: CurrentBookingSession(
        sessionId: active.localId,
        status: 'open',
        startedAt: active.startedAt,
        wellId: schedule.wellId,
        bookingId: active.bookingId,
      ),
    );
  }

  Future<PhoneOwnedBookingTransition?> restorePhoneOwnedTransition({
    required String accountId,
    required String wellId,
    required String transitionKey,
  }) => PhoneOwnedBookingTransition.load(
    _store,
    accountId,
    wellId,
    transitionKey,
  );

  /// واجهة توافق للسجلات المؤقتة القديمة؛ لا تستخدمها شاشة التشغيل الحية.
  Future<LocalBookingTransitionResult> runCachedDueBookingTransition({
    required String accountId,
    required String wellId,
    required CachedBookingSchedule? cachedSchedule,
    required BookingAutomationState? automation,
    required String commandId,
    required String localSessionId,
    required bool scheduledCallback,
    bool Function()? isCurrent,
  }) => _runDueBookingTransition(
    accountId: accountId,
    wellId: wellId,
    cachedSchedule: cachedSchedule,
    automation: automation,
    commandId: commandId,
    localSessionId: localSessionId,
    scheduledCallback: scheduledCallback,
    isCurrent: isCurrent,
    phoneOwned: false,
  );

  /// المدخل التشغيلي للهاتف: إكمال وبدء حقيقيان داخل الطابور المتين.
  Future<LocalBookingTransitionResult> runPhoneOwnedDueBookingTransition({
    required String accountId,
    required String wellId,
    required CachedBookingSchedule? cachedSchedule,
    required BookingAutomationState? automation,
    required String commandId,
    required String localSessionId,
    required bool scheduledCallback,
    bool Function()? isCurrent,
  }) => _runDueBookingTransition(
    accountId: accountId,
    wellId: wellId,
    cachedSchedule: cachedSchedule,
    automation: automation,
    commandId: commandId,
    localSessionId: localSessionId,
    scheduledCallback: scheduledCallback,
    isCurrent: isCurrent,
    phoneOwned: true,
  );

  Future<LocalBookingTransitionResult> _runDueBookingTransition({
    required String accountId,
    required String wellId,
    required CachedBookingSchedule? cachedSchedule,
    required BookingAutomationState? automation,
    required String commandId,
    required String localSessionId,
    required bool scheduledCallback,
    bool Function()? isCurrent,
    required bool phoneOwned,
  }) async {
    final ledger = _bookingLedger;
    if (ledger == null) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'durable_ledger_unavailable',
      );
    }
    if (cachedSchedule == null) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'no_cached_schedule',
      );
    }

    final schedule = cachedSchedule.schedule;
    if (!_isStructurallyValidCachedSchedule(schedule, wellId)) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'invalid_cached_schedule',
      );
    }

    // حسم الزمن قبل أي فحص آخر لأسباب الأعمال: بلا زمن موثوق لا قرار.
    // الإقلاع المختلف أو العدّاد الرجعي أو المرساة الفاسدة كلها مراجعة
    // زمنية — لا إثباتًا أن الموعد فات.
    final resolved = await _resolveTrustedTransitionNow(cachedSchedule);
    if (resolved == null) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.timeIntegrityRequiresReview,
        reason: 'time_integrity_requires_review',
      );
    }
    var executedAt = resolved.at;
    if (executedAt.isBefore(schedule.dayStart) ||
        !executedAt.isBefore(schedule.dayEnd)) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'wrong_well_day',
      );
    }
    if (automation == null ||
        automation.wellId != wellId ||
        !automation.enabled ||
        !automation.settingsRowExists ||
        automation.firstSession != 'manual' ||
        automation.activeChainStatus != 'active' ||
        automation.activeChainId == null ||
        automation.activeChainDecisionRevision == null ||
        automation.revision == null) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'automation_not_eligible',
      );
    }

    await initialize();
    final activeLocal = await projectActiveSession(
      accountId: accountId,
      wellId: wellId,
    );
    final current = schedule.currentSession;
    final localMatches =
        activeLocal != null &&
        activeLocal.wellId == wellId &&
        (activeLocal.localId == current?.sessionId ||
            activeLocal.serverSessionId == current?.sessionId);
    final linked = await restoreServerBookingSession(
      accountId: accountId,
      wellId: wellId,
    );
    if (current == null ||
        current.status != 'open' ||
        current.wellId != wellId ||
        current.bookingId == null) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'no_server_linked_current_session',
      );
    }
    final legitimatePrevious =
        localMatches ||
        (linked != null &&
            linked.sessionId == current.sessionId &&
            linked.bookingId == current.bookingId &&
            linked.wellId == wellId &&
            linked.startedAt == current.startedAt);

    final candidate = resolveLocalBookingTransition(
      schedule: schedule,
      automation: automation,
    );
    if (candidate == null) {
      return LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: automation.activeChainNextBookingId == current.bookingId
            ? 'ambiguous_booking_chain'
            : 'next_booking_not_executable',
      );
    }
    final nextBooking = candidate.nextBooking;

    final transitionKey = _bookingTransitionKey(
      chainId: automation.activeChainId!,
      currentSessionId: current.sessionId,
      nextBookingId: nextBooking.id,
      decisionRevision: automation.activeChainDecisionRevision!,
      automationRevision: automation.revision!,
    );
    final existingLive = await restorePhoneOwnedTransition(
      accountId: accountId,
      wellId: wellId,
      transitionKey: transitionKey,
    );
    if (existingLive != null) {
      if (!phoneOwned) {
        return const LocalBookingTransitionResult(
          outcome: LocalBookingTransitionOutcome.blocked,
          reason: 'phone_owned_transition_already_exists',
        );
      }
      await projectActiveSession(accountId: accountId, wellId: wellId);
      return LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.alreadyRecorded,
        reason: 'phone_owned_live_transition',
        intent: existingLive.intent,
        liveTransition: existingLive,
      );
    }
    if (!legitimatePrevious) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'no_server_linked_current_session',
      );
    }
    if (nextBooking.id.isEmpty || nextBooking.farmerWellAccountId.isEmpty) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'missing_booking_execution_data',
      );
    }
    final source = nextBooking.expectedEnergySource;
    final alternative = nextBooking.alternativeEnergySource;
    if (!const {'solar', 'well_diesel', 'farmer_diesel'}.contains(source) ||
        (alternative != null &&
            (!const {'well_diesel', 'farmer_diesel'}.contains(alternative) ||
                source != 'solar'))) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'invalid_booking_energy',
      );
    }
    // نافذة الشمس القائمة من عقد M113؛ لا نغيّر أهلية لقطة الحجز.
    if (source == 'solar') {
      final localStart = nextBooking.scheduledStart.toUtc().add(
        const Duration(hours: 3),
      );
      final solarEnd = DateTime.utc(
        localStart.year,
        localStart.month,
        localStart.day,
        15,
      );
      if (localStart.hour < 6 ||
          localStart.hour >= 18 ||
          (nextBooking.scheduledEnd.isAfter(solarEnd) && alternative == null)) {
        return const LocalBookingTransitionResult(
          outcome: LocalBookingTransitionOutcome.blocked,
          reason: 'booking_energy_not_executable',
        );
      }
    }
    final pendingProvisional = await ledger.loadProvisionalSessions(
      accountId,
      wellId,
    );
    if (pendingProvisional.any(
      (session) =>
          session.reconciliationState == 'awaiting_reconciliation' &&
          session.transitionKey != transitionKey,
    )) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'local_conflict',
      );
    }
    final existing = await ledger.loadIntent(accountId, wellId, transitionKey);
    if (existing != null) {
      if (existing.state != BookingIntentState.awaitingReconciliation) {
        return LocalBookingTransitionResult(
          outcome: LocalBookingTransitionOutcome.blocked,
          reason: 'existing_intent_requires_review',
          intent: existing,
        );
      }
      if (!phoneOwned) {
        final priorSession = await ledger.loadProvisionalSession(
          accountId,
          wellId,
          transitionKey,
        );
        return LocalBookingTransitionResult(
          outcome: priorSession == null
              ? LocalBookingTransitionOutcome.blocked
              : LocalBookingTransitionOutcome.alreadyRecorded,
          reason: priorSession == null
              ? 'missing_provisional_evidence'
              : 'already_recorded',
          intent: existing,
          session: priorSession,
        );
      }
      // السجل القديم دليل مؤقت فقط؛ لا يتحول إلى انتقال حي أو أوامر.
      return LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'legacy_provisional_requires_review',
        intent: existing,
      );
    }

    final dueAt = candidate.dueAt;
    if (executedAt.isBefore(dueAt)) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'not_due',
      );
    }

    final finalTime = await _resolveTrustedTransitionNow(cachedSchedule);
    if (isCurrent != null && !isCurrent()) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'stale_runtime',
      );
    }
    if (finalTime == null || finalTime.at.isBefore(resolved.at)) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.timeIntegrityRequiresReview,
        reason: 'time_integrity_requires_review',
      );
    }
    final rederived = resolveLocalBookingTransition(
      schedule: schedule,
      automation: automation,
    );
    if (rederived == null || !candidate.sameDecisionAs(rederived)) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'candidate_changed',
      );
    }
    executedAt = finalTime.at;
    if (executedAt.isBefore(dueAt) || !executedAt.isBefore(schedule.dayEnd)) {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'not_due',
      );
    }
    final proposed = BookingTransitionIntent(
      wellId: wellId,
      transitionKey: transitionKey,
      commandId: commandId,
      chainId: automation.activeChainId!,
      currentSessionId: current.sessionId,
      nextBookingId: nextBooking.id,
      decisionRevision: automation.activeChainDecisionRevision!,
      automationRevision: automation.revision!,
      state: BookingIntentState.awaitingReconciliation,
    );
    if (!scheduledCallback) {
      final intent = await ledger.recordIntent(
        accountId: accountId,
        wellId: wellId,
        transitionKey: transitionKey,
        commandId: commandId,
        chainId: proposed.chainId,
        currentSessionId: current.sessionId,
        nextBookingId: nextBooking.id,
        decisionRevision: proposed.decisionRevision,
        automationRevision: proposed.automationRevision,
      );
      final missed = await ledger.markMissedStart(accountId, intent);
      return LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.missedRequiresReview,
        reason: 'missed_start_requires_review',
        intent: missed,
      );
    }
    if (!phoneOwned) {
      try {
        final pair = await ledger.recordOperationalTransition(
          accountId: accountId,
          intent: proposed,
          localSessionId: localSessionId,
          occurredAt: executedAt,
          isCurrent: isCurrent,
        );
        return LocalBookingTransitionResult(
          outcome: LocalBookingTransitionOutcome.transitioned,
          reason: 'local_offline_provisional',
          intent: pair.$1,
          session: pair.$2,
        );
      } on StateError {
        return const LocalBookingTransitionResult(
          outcome: LocalBookingTransitionOutcome.blocked,
          reason: 'stale_or_conflicting_runtime',
        );
      }
    }
    await initialize();
    final localA = activeLocal;
    if (localA != null &&
        (localA.wellId != wellId ||
            (localA.serverSessionId != current.sessionId &&
                localA.localId != current.sessionId))) {
      final prior = await restorePhoneOwnedTransition(
        accountId: accountId,
        wellId: wellId,
        transitionKey: transitionKey,
      );
      if (prior != null) {
        return LocalBookingTransitionResult(
          outcome: LocalBookingTransitionOutcome.alreadyRecorded,
          reason: 'phone_owned_live_transition',
          intent: prior.intent,
          liveTransition: prior,
        );
      }
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'local_session_conflict',
      );
    }
    final priorStart = localA == null
        ? null
        : await _sessionStart(accountId, localA.localId);
    final complete = await _outbox.prepare(
      accountId: accountId,
      wellId: wellId,
      aggregateLocalId: localA?.localId ?? current.sessionId,
      type: CommandType.completeIrrigationSession,
      occurredAt: executedAt,
      payload: {
        'p_session_id': priorStart == null
            ? current.sessionId
            : _outbox.referenceTo(priorStart).toJson(),
      },
    );
    final context = <String, Object?>{
      ...await _bookingPumpContext(accountId, wellId),
      if (localA?.pumpId != null) 'p_pump_id': localA!.pumpId,
      if (localA?.pumpName != null) 'pump_name': localA!.pumpName,
      'trusted_time_anchor': _bookedAnchor(cachedSchedule),
      'booking_id': nextBooking.id,
      'consumed_booking_ids': <String>{
        ...((priorStart?.localContext['consumed_booking_ids'] as List?) ??
                const [])
            .cast<String>(),
        current.bookingId!,
      }.toList(),
      'chain_id': proposed.chainId,
      'previous_session_local_id': localA?.localId,
      'previous_server_session_id': priorStart == null
          ? current.sessionId
          : localA?.serverSessionId,
      'decision_revision': proposed.decisionRevision,
      'automation_revision': proposed.automationRevision,
      'p_farm_id': nextBooking.farmId,
      'p_farmer_well_account_id': nextBooking.farmerWellAccountId,
      'p_energy_source': nextBooking.expectedEnergySource,
      'alternative_energy_source': nextBooking.alternativeEnergySource,
      'farmer_name': nextBooking.farmerName,
      'farm_name': nextBooking.farmName,
      'public_code': nextBooking.publicCode,
      'expected_duration_minutes': nextBooking.expectedDurationMinutes,
      'scheduled_start': nextBooking.scheduledStart.toUtc().toIso8601String(),
      'scheduled_end': nextBooking.scheduledEnd.toUtc().toIso8601String(),
      'transition_key': transitionKey,
    };
    final start = await _outbox.prepare(
      accountId: accountId,
      wellId: wellId,
      type: CommandType.startBookingSession,
      occurredAt: executedAt,
      payload: {'p_booking_id': nextBooking.id, 'p_crops': <String>[]},
      prerequisites: [complete.localId],
      localContext: context,
    );
    final proposedLive = PhoneOwnedBookingTransition(
      intent: proposed,
      occurredAt: executedAt,
      completeLocalId: complete.localId,
      completeCommandId: complete.commandId,
      startLocalId: start.localId,
      startCommandId: start.commandId,
      bookingSnapshot: context,
    );
    final String saved;
    try {
      saved = await _store.insertBundle(
        accountId: accountId,
        key: PhoneOwnedBookingTransition.storageKey(wellId, transitionKey),
        value: jsonEncode(proposedLive.toJson()),
        commands: [complete, start],
        isCurrent: isCurrent,
      );
    } on StateError {
      return const LocalBookingTransitionResult(
        outcome: LocalBookingTransitionOutcome.blocked,
        reason: 'stale_or_conflicting_runtime',
      );
    }
    final live = PhoneOwnedBookingTransition.fromJson(
      jsonDecode(saved) as Map<String, dynamic>,
    );
    await projectActiveSession(accountId: accountId, wellId: wellId);
    if (live.startLocalId == start.localId) {
      await _triggerSync(
        accountId,
        sessionLocalId: live.startLocalId,
        wellId: wellId,
      );
    }
    return LocalBookingTransitionResult(
      outcome: live.startLocalId == start.localId
          ? LocalBookingTransitionOutcome.transitioned
          : LocalBookingTransitionOutcome.alreadyRecorded,
      reason: 'phone_owned_live_transition',
      intent: live.intent,
      liveTransition: live,
    );
  }

  Map<String, Object?> _bookedAnchor(CachedBookingSchedule cached) {
    final anchor = cached.timeAnchor!;
    return {
      'server_time': anchor.serverTime!.toUtc().toIso8601String(),
      'wall_clock': anchor.wallClock.toUtc().toIso8601String(),
      'monotonic_us': anchor.monotonic.inMicroseconds,
      'boot_id': anchor.bootId,
    };
  }

  Map<String, Object?> _bookedContext(
    BookingDayItem booking,
    BookingAutomationState? automation, {
    bool manual = false,
    Map<String, Object?> previous = const {},
  }) => {
    'booking_id': booking.id,
    'manual_start': manual,
    'chain_id': automation?.activeChainId,
    'decision_revision': automation?.activeChainDecisionRevision,
    'automation_revision': automation?.revision,
    'p_farm_id': booking.farmId,
    'p_farmer_well_account_id': booking.farmerWellAccountId,
    'p_energy_source': booking.expectedEnergySource,
    'alternative_energy_source': booking.alternativeEnergySource,
    'farmer_name': booking.farmerName,
    'farm_name': booking.farmName,
    'public_code': booking.publicCode,
    'expected_duration_minutes': booking.expectedDurationMinutes,
    'scheduled_start': booking.scheduledStart.toUtc().toIso8601String(),
    'scheduled_end': booking.scheduledEnd.toUtc().toIso8601String(),
    'consumed_booking_ids': previous['consumed_booking_ids'] ?? <String>[],
  };

  bool _bookingExecutable(BookingDayItem booking, WellDaySchedule schedule) {
    final source = booking.expectedEnergySource;
    final alternative = booking.alternativeEnergySource;
    if (booking.wellId != schedule.wellId ||
        !booking.canStartManually ||
        booking.id.isEmpty ||
        booking.farmId!.isEmpty ||
        booking.farmerWellAccountId.isEmpty ||
        booking.expectedDurationMinutes <= 0 ||
        !booking.scheduledStart.isBefore(booking.scheduledEnd) ||
        booking.scheduledStart.isBefore(schedule.dayStart) ||
        booking.scheduledEnd.isAfter(schedule.dayEnd) ||
        !const {'solar', 'well_diesel', 'farmer_diesel'}.contains(source) ||
        (alternative != null &&
            (source != 'solar' ||
                !const {
                  'well_diesel',
                  'farmer_diesel',
                }.contains(alternative)))) {
      return false;
    }
    if (source == 'solar') {
      final local = booking.scheduledStart.toUtc().add(
        const Duration(hours: 3),
      );
      final solarEnd = DateTime.utc(local.year, local.month, local.day, 15);
      if (local.hour < 6 ||
          local.hour >= 18 ||
          (booking.scheduledEnd.isAfter(solarEnd) && alternative == null)) {
        return false;
      }
    }
    return true;
  }

  bool _matchesBookingContext(
    BookingDayItem booking,
    Map<String, Object?> context,
  ) =>
      booking.id == context['booking_id'] &&
      booking.status == 'confirmed' &&
      booking.farmId == context['p_farm_id'] &&
      booking.farmerWellAccountId == context['p_farmer_well_account_id'] &&
      booking.expectedEnergySource == context['p_energy_source'] &&
      booking.alternativeEnergySource == context['alternative_energy_source'] &&
      booking.expectedDurationMinutes == context['expected_duration_minutes'] &&
      booking.scheduledStart.toUtc().toIso8601String() ==
          context['scheduled_start'] &&
      booking.scheduledEnd.toUtc().toIso8601String() ==
          context['scheduled_end'];

  /// البدء الأول فعل بشري؛ يُثبت محليًا قبل أي إرسال للشبكة.
  Future<CommandEnvelope> startBookedSession({
    required String accountId,
    required String wellId,
    required String bookingId,
    Pump? displayPump,
    required CachedBookingSchedule cachedSchedule,
    required BookingAutomationState? automation,
    bool Function()? isCurrent,
  }) async {
    await initialize();
    final key = 'booking.manual_start.v1.$wellId.$bookingId';
    final saved = await _store.readBundle(accountId, key);
    if (saved != null) {
      final id = (jsonDecode(saved) as Map)['start_local_id'] as String;
      final command = await _store.commandByLocalId(accountId, id);
      if (command == null || command.type != CommandType.startBookingSession) {
        throw StateError('missing_booking_start');
      }
      await projectActiveSession(accountId: accountId, wellId: wellId);
      return command;
    }
    final schedule = cachedSchedule.schedule;
    final matches = schedule.bookings.where((b) => b.id == bookingId).toList();
    final actual = await _resolveTrustedTransitionNow(cachedSchedule);
    if (schedule.wellId != wellId ||
        matches.length != 1 ||
        !_bookingExecutable(matches.single, schedule) ||
        actual == null ||
        actual.at.isBefore(schedule.dayStart) ||
        !actual.at.isBefore(schedule.dayEnd) ||
        schedule.currentSession != null ||
        await projectActiveSession(accountId: accountId, wellId: wellId) !=
            null ||
        await _bookingLedger?.loadServerSession(accountId, wellId) != null) {
      throw StateError('booking_start_not_authorized');
    }
    final lifecycle = await BookingLocalLedger.loadBookedLifecycle(
      _store,
      accountId,
      wellId,
    );
    if (lifecycle?['state'] == 'waiting_for_next_due' ||
        lifecycle?['state'] == 'requires_review' ||
        (automation != null && automation.wellId != wellId)) {
      throw StateError('existing_booked_chain_requires_review');
    }
    final legacy = await _bookingLedger?.loadProvisionalSessions(
      accountId,
      wellId,
    );
    if (legacy?.any((s) => s.reconciliationState != 'reconciled') ?? false) {
      throw StateError('legacy_booking_requires_review');
    }
    final start = await _outbox.prepare(
      accountId: accountId,
      wellId: wellId,
      type: CommandType.startBookingSession,
      occurredAt: actual.at,
      payload: {'p_booking_id': bookingId, 'p_crops': <String>[]},
      localContext: {
        ..._bookedContext(matches.single, automation, manual: true),
        ...await _bookingPumpContext(accountId, wellId, selected: displayPump),
        'trusted_time_anchor': _bookedAnchor(cachedSchedule),
      },
    );
    final state = jsonEncode({
      'version': 1,
      'provenance': 'phone_owned_booked_lifecycle',
      'well_id': wellId,
      'state': 'running',
      'start_local_id': start.localId,
      'start_command_id': start.commandId,
      'automation_revision': automation?.revision,
      'chain_id': automation?.activeChainId,
      'decision_revision': automation?.activeChainDecisionRevision,
    });
    final persisted = await _store.insertBundle(
      accountId: accountId,
      key: key,
      value: jsonEncode({
        'start_local_id': start.localId,
        'start_command_id': start.commandId,
      }),
      localValues: {BookingLocalLedger.bookedLifecycleKey(wellId): state},
      commands: [start],
      isCurrent: isCurrent,
    );
    final id = (jsonDecode(persisted) as Map)['start_local_id'] as String;
    await projectActiveSession(accountId: accountId, wellId: wellId);
    if (id == start.localId) {
      await _triggerSync(accountId, sessionLocalId: id, wellId: wellId);
    }
    return (await _store.commandByLocalId(accountId, id))!;
  }

  /// قرار محدود بالبئر؛ يُعاد بناؤه عند تحديث اللقطة، لا كل ثانية.
  Future<BookedSessionAction?> prepareBookedSessionAction({
    required String accountId,
    required String wellId,
    required CachedBookingSchedule cachedSchedule,
    required BookingAutomationState? automation,
  }) async {
    await initialize();
    final state = await BookingLocalLedger.loadBookedLifecycle(
      _store,
      accountId,
      wellId,
    );
    if (state?['state'] == 'requires_review') {
      throw StateError('booked_lifecycle_requires_review');
    }
    if (automation == null ||
        automation.wellId != wellId ||
        !automation.enabled ||
        !automation.settingsRowExists ||
        automation.firstSession != 'manual' ||
        automation.revision == null ||
        cachedSchedule.schedule.wellId != wellId) {
      return null;
    }
    if (automation.activeChainId != null &&
        !const {
          'active',
          'decision_required',
        }.contains(automation.activeChainStatus)) {
      throw StateError('booked_chain_state_changed');
    }
    CommandEnvelope? armedCompletion;
    if (state?['state'] == 'waiting_for_next_due' ||
        state?['state'] == 'finished') {
      armedCompletion = await _store.commandByLocalId(
        accountId,
        state!['complete_local_id'] as String,
      );
      final reference = armedCompletion?.payload['p_session_id'];
      final expectedReference = CommandReference(
        localId: state['previous_session_local_id'] as String,
        kind: EntityKind.session,
      );
      if (armedCompletion == null ||
          armedCompletion.type != CommandType.completeIrrigationSession ||
          armedCompletion.commandId != state['complete_command_id'] ||
          armedCompletion.wellId != wellId ||
          armedCompletion.aggregateLocalId !=
              state['previous_session_local_id'] ||
          !CommandReference.isReference(reference) ||
          CommandReference.fromJson(
                (reference as Map).cast<Object?, Object?>(),
              ) !=
              expectedReference ||
          armedCompletion.occurredAt.toUtc().toIso8601String() !=
              state['actual_transition_at'] ||
          armedCompletion.status == CommandStatus.review) {
        throw StateError('completion_prerequisite_requires_review');
      }
    }
    final active = await projectActiveSession(
      accountId: accountId,
      wellId: wellId,
    );
    if ((state?['state'] == 'waiting_for_next_due' ||
            state?['state'] == 'finished') &&
        active != null) {
      throw StateError('gap_local_session_conflict');
    }
    final schedule = cachedSchedule.schedule;
    if (active == null) {
      if (state?['state'] != 'waiting_for_next_due') return null;
      if (state!['automation_revision'] != automation.revision ||
          state['chain_id'] != automation.activeChainId ||
          state['decision_revision'] !=
              automation.activeChainDecisionRevision) {
        throw StateError('armed_chain_revision_changed');
      }
      final complete = armedCompletion!;
      final context = Map<String, Object?>.from(state['next_booking'] as Map);
      final matches = schedule.bookings
          .where((b) => b.id == context['booking_id'])
          .toList();
      if (matches.length != 1 ||
          !_matchesBookingContext(matches.single, context) ||
          !_bookingExecutable(matches.single, schedule)) {
        throw StateError('armed_booking_changed');
      }
      final remote = schedule.currentSession;
      final previousMapping = await _store.mapping(
        accountId,
        state['previous_session_local_id'] as String,
        EntityKind.session,
      );
      if (remote != null &&
          remote.sessionId != state['previous_session_local_id'] &&
          remote.sessionId != state['previous_server_session_id'] &&
          remote.sessionId != previousMapping?.serverId) {
        throw StateError('gap_server_session_conflict');
      }
      return BookedSessionAction(
        key: 'booking.lifecycle_start.v1.$wellId.${complete.localId}',
        dueAt: matches.single.scheduledStart,
        nextBooking: matches.single,
        previousCompletion: complete,
        state: state,
        automation: automation,
      );
    }
    if (!active.phoneOwned || active.bookingId == null) return null;
    if (active.syncState == SessionSyncState.conflict) {
      throw StateError('booked_session_requires_review');
    }
    final context = active.bookingContext;
    final duration = active.bookedDurationMinutes;
    final matches = schedule.bookings
        .where((b) => b.id == active.bookingId)
        .toList();
    if (duration == null ||
        matches.length != 1 ||
        !_matchesBookingContext(matches.single, context)) {
      throw StateError('booked_session_snapshot_changed');
    }
    if (matches.single.session != null &&
        matches.single.session!.status != 'open') {
      throw StateError('booked_session_closed_elsewhere');
    }
    if (context['automation_revision'] != automation.revision ||
        (context['chain_id'] != null &&
            context['chain_id'] != automation.activeChainId) ||
        (context['decision_revision'] != null &&
            context['decision_revision'] !=
                automation.activeChainDecisionRevision)) {
      throw StateError('booked_chain_revision_changed');
    }
    final consumed = <String>{
      active.bookingId!,
      ...((context['consumed_booking_ids'] as List?) ?? const [])
          .cast<String>(),
    };
    final candidates = schedule.bookings
        .where(
          (b) => !consumed.contains(b.id) && _bookingExecutable(b, schedule),
        )
        .toList();
    int compare(BookingDayItem a, BookingDayItem b) {
      final time = a.scheduledStart.compareTo(b.scheduledStart);
      if (time != 0) return time;
      final priority = b.priority.compareTo(a.priority);
      return priority != 0 ? priority : a.publicCode.compareTo(b.publicCode);
    }

    candidates.sort(compare);
    if (candidates.length > 1 && compare(candidates[0], candidates[1]) == 0) {
      throw StateError('ambiguous_booking_chain');
    }
    final next = candidates.isEmpty ? null : candidates.first;
    final pointed = automation.activeChainNextBookingId;
    if (pointed != null && pointed != active.bookingId && pointed != next?.id) {
      throw StateError('booking_chain_pointer_changed');
    }
    final remote = schedule.currentSession;
    if (remote != null &&
        remote.sessionId != active.localId &&
        remote.sessionId != active.serverSessionId &&
        remote.sessionId != context['previous_session_local_id'] &&
        remote.sessionId != context['previous_server_session_id'] &&
        !phoneHasClosedSession(accountId, wellId, remote.sessionId)) {
      throw StateError('booked_server_session_conflict');
    }
    return BookedSessionAction(
      key: 'booking.lifecycle_close.v1.$wellId.${active.localId}',
      dueAt: active.bookedOperationalEnd!,
      active: active,
      nextBooking: next,
      automation: automation,
    );
  }

  Future<LocalBookingTransitionResult> runBookedSessionAction({
    required String accountId,
    required String wellId,
    required CachedBookingSchedule cachedSchedule,
    required BookingAutomationState? automation,
    required BookedSessionAction action,
    required bool scheduledCallback,
    bool Function()? isCurrent,
  }) async {
    LocalBookingTransitionResult result(
      LocalBookingTransitionOutcome outcome,
      String reason,
    ) => LocalBookingTransitionResult(outcome: outcome, reason: reason);
    if (await _store.readBundle(accountId, action.key) != null) {
      await projectActiveSession(accountId: accountId, wellId: wellId);
      return result(
        LocalBookingTransitionOutcome.alreadyRecorded,
        'booked_lifecycle_recorded',
      );
    }
    final resolved = await _resolveTrustedTransitionNow(cachedSchedule);
    if (resolved == null) {
      return result(
        LocalBookingTransitionOutcome.timeIntegrityRequiresReview,
        'time_integrity_requires_review',
      );
    }
    final latest = await prepareBookedSessionAction(
      accountId: accountId,
      wellId: wellId,
      cachedSchedule: cachedSchedule,
      automation: automation,
    );
    if (latest == null ||
        !action.sameDecisionAs(latest) ||
        (isCurrent != null && !isCurrent())) {
      return result(
        LocalBookingTransitionOutcome.blocked,
        'stale_booked_lifecycle',
      );
    }
    if (resolved.at.isBefore(action.dueAt)) {
      return result(LocalBookingTransitionOutcome.notDue, 'not_due');
    }
    if (!scheduledCallback) {
      final review = {
        ...action.state,
        'version': 1,
        'provenance': 'phone_owned_booked_lifecycle',
        'well_id': wellId,
        'state': 'requires_review',
        'review_reason': 'missed_booked_lifecycle',
        'due_at': action.dueAt.toUtc().toIso8601String(),
        'action_key': action.key,
      };
      final encoded = jsonEncode(review);
      await _store.insertBundle(
        accountId: accountId,
        key: '${action.key}.missed',
        value: encoded,
        commands: [],
        localValues: {BookingLocalLedger.bookedLifecycleKey(wellId): encoded},
        isCurrent: isCurrent,
      );
      return result(
        LocalBookingTransitionOutcome.missedRequiresReview,
        'missed_start_requires_review',
      );
    }
    final commands = <CommandEnvelope>[];
    final active = action.active;
    CommandEnvelope complete;
    if (active != null) {
      final root = await _sessionStart(accountId, active.localId);
      complete = await _outbox.prepare(
        accountId: accountId,
        wellId: wellId,
        aggregateLocalId: active.localId,
        type: CommandType.completeIrrigationSession,
        occurredAt: resolved.at,
        payload: {'p_session_id': _outbox.referenceTo(root).toJson()},
      );
      commands.add(complete);
    } else {
      complete = action.previousCompletion!;
    }
    final next = action.nextBooking;
    final startsNext =
        next != null && !resolved.at.isBefore(next.scheduledStart);
    final consumed = <String>{
      ...((active?.bookingContext['consumed_booking_ids'] as List?) ??
              (action.state['consumed_booking_ids'] as List?) ??
              const [])
          .cast<String>(),
      if (active?.bookingId != null) active!.bookingId!,
    }.toList();
    final state = <String, Object?>{
      'version': 1,
      'provenance': 'phone_owned_booked_lifecycle',
      'well_id': wellId,
      'state': next == null
          ? 'finished'
          : startsNext
          ? 'running'
          : 'waiting_for_next_due',
      'actual_transition_at': resolved.at.toUtc().toIso8601String(),
      'previous_session_local_id':
          active?.localId ?? action.state['previous_session_local_id'],
      'previous_server_session_id':
          active?.serverSessionId ?? action.state['previous_server_session_id'],
      'previous_booking_id':
          active?.bookingId ?? action.state['previous_booking_id'],
      'complete_local_id': complete.localId,
      'complete_command_id': complete.commandId,
      'p_pump_id': active?.pumpId ?? action.state['p_pump_id'],
      'pump_name': active?.pumpName ?? action.state['pump_name'],
      'chain_id': automation!.activeChainId,
      'decision_revision': automation.activeChainDecisionRevision,
      'automation_revision': automation.revision,
      'consumed_booking_ids': consumed,
      if (next != null) 'next_booking': _bookedContext(next, automation),
      if (next != null) 'next_booking_id': next.id,
      if (next != null)
        'next_scheduled_start': next.scheduledStart.toUtc().toIso8601String(),
    };
    if (startsNext) {
      final context = {
        ..._bookedContext(next, automation),
        'p_pump_id': state['p_pump_id'],
        'pump_name': state['pump_name'],
        'consumed_booking_ids': consumed,
        'trusted_time_anchor': _bookedAnchor(cachedSchedule),
        'previous_session_local_id': state['previous_session_local_id'],
        'previous_server_session_id': state['previous_server_session_id'],
      };
      final start = await _outbox.prepare(
        accountId: accountId,
        wellId: wellId,
        type: CommandType.startBookingSession,
        occurredAt: resolved.at,
        payload: {'p_booking_id': next.id, 'p_crops': <String>[]},
        prerequisites: [complete.localId],
        localContext: context,
      );
      commands.add(start);
      state['start_local_id'] = start.localId;
      state['start_command_id'] = start.commandId;
    }
    final laterConfirmed =
        next == null &&
        active != null &&
        cachedSchedule.schedule.bookings.any(
          (booking) =>
              booking.wellId == wellId &&
              booking.status == 'confirmed' &&
              booking.scheduledStart.isAfter(
                DateTime.parse(
                  active.bookingContext['scheduled_start'] as String,
                ),
              ) &&
              !booking.scheduledStart.isBefore(
                cachedSchedule.schedule.dayStart,
              ) &&
              booking.scheduledStart.isBefore(cachedSchedule.schedule.dayEnd),
        );
    if (next == null && laterConfirmed) {
      state['state'] = 'requires_review';
      state['review_reason'] = 'next_booking_not_executable';
    }
    if (next == null && active != null && !laterConfirmed) {
      final endChain = await _outbox.prepare(
        accountId: accountId,
        wellId: wellId,
        aggregateLocalId: active.localId,
        type: CommandType.endBookingTransitionChain,
        occurredAt: resolved.at,
        payload: {'p_session_id': complete.payload['p_session_id']},
        prerequisites: [complete.localId],
      );
      commands.add(endChain);
      state['end_chain_local_id'] = endChain.localId;
      state['end_chain_command_id'] = endChain.commandId;
    }
    // إعادة حسم الزمن والحراس قبل المعاملة، دون أي اعتماد على ساعة الحائط.
    final check = await _resolveTrustedTransitionNow(cachedSchedule);
    if (check == null) {
      return result(
        LocalBookingTransitionOutcome.timeIntegrityRequiresReview,
        'time_integrity_requires_review',
      );
    }
    if (isCurrent != null && !isCurrent()) {
      return result(
        LocalBookingTransitionOutcome.blocked,
        'stale_booked_lifecycle',
      );
    }
    final encoded = jsonEncode(state);
    final saved = await _store.insertBundle(
      accountId: accountId,
      key: action.key,
      value: encoded,
      commands: commands,
      localValues: {BookingLocalLedger.bookedLifecycleKey(wellId): encoded},
      isCurrent: isCurrent,
    );
    await projectActiveSession(accountId: accountId, wellId: wellId);
    if (saved == encoded) {
      await _triggerSync(
        accountId,
        sessionLocalId:
            state['start_local_id'] as String? ?? complete.aggregateLocalId,
        wellId: wellId,
      );
    }
    return result(
      saved == encoded
          ? LocalBookingTransitionOutcome.transitioned
          : LocalBookingTransitionOutcome.alreadyRecorded,
      'phone_owned_booked_lifecycle',
    );
  }

  bool _isStructurallyValidCachedSchedule(
    WellDaySchedule schedule,
    String wellId,
  ) {
    if (schedule.wellId != wellId ||
        !schedule.dayStart.isBefore(schedule.dayEnd) ||
        schedule.wellTimezone.isEmpty ||
        schedule.bookings.isEmpty) {
      return false;
    }
    return schedule.bookings.every(
      (booking) =>
          booking.wellId == wellId &&
          !booking.scheduledStart.isBefore(schedule.dayStart) &&
          !booking.scheduledEnd.isAfter(schedule.dayEnd) &&
          booking.scheduledStart.isBefore(booking.scheduledEnd),
    );
  }

  String _bookingTransitionKey({
    required String chainId,
    required String currentSessionId,
    required String nextBookingId,
    required int decisionRevision,
    required int automationRevision,
  }) =>
      '$chainId:$currentSessionId:$nextBookingId:'
      '$decisionRevision:$automationRevision';

  late final OutboxRepository _outbox;
  late ActiveSessionProjector _projector;
  SyncEngine? _syncEngine;
  PricingResolver _pricingResolver;
  Future<bool> Function(String accountId)? _commandQueuedScheduler;

  /// يربط جدولة الخلفية بعمر التطبيق؛ لا يغير ملكية أو حالة أي أمر.
  void setCommandQueuedScheduler(
    Future<bool> Function(String accountId)? scheduler,
  ) {
    _commandQueuedScheduler = scheduler;
  }

  /// إحلال لقطات التسعير المقروءة من العقد محلّ ما قبلها.
  ///
  /// تُنادى من الشاشة بعد نجاح `api.get_active_price_schedule`، وبقائمة
  /// فارغة إن فشلت القراءة — فيعود المستحق «بانتظار المزامنة» بدل أن يبقى
  /// معروضًا بسعر لم يُعده العقد (م-41D6).
  void updatePricing(List<PricingSnapshot> snapshots) {
    _pricingResolver = PricingResolver(List.unmodifiable(snapshots));
    _projector = ActiveSessionProjector(
      store: _store,
      pricing: _pricingResolver,
      bookedTimeSource: _timeIntegritySource,
    );
  }

  bool _initialized = false;
  Timer? _tickerTimer;
  // نتائج الإكمال من الإسقاط الموجود؛ لا مؤقت ولا مخزن عرض موازٍ.
  final _completionController =
      StreamController<ActiveSessionRecord>.broadcast();
  Stream<ActiveSessionRecord> get completionResultStream =>
      _completionController.stream;

  final _completionDetailViews = <(String, String, String), int>{};

  /// تسجيل قارئ تفاصيل مركب فقط؛ لا يخزن حقائق مالية ولا يجلب شبكة.
  Stream<ActiveSessionRecord> watchCompletionResult({
    required String accountId,
    required String wellId,
    required String serverSessionId,
  }) async* {
    final key = (accountId, wellId, serverSessionId);
    _completionDetailViews[key] = (_completionDetailViews[key] ?? 0) + 1;
    try {
      yield* completionResultStream.where(
        (r) =>
            r.accountId == accountId &&
            r.wellId == wellId &&
            r.serverSessionId == serverSessionId,
      );
    } finally {
      final remaining = (_completionDetailViews[key] ?? 1) - 1;
      if (remaining == 0) {
        _completionDetailViews.remove(key);
      } else {
        _completionDetailViews[key] = remaining;
      }
    }
  }

  final _sessionController = StreamController<ActiveSessionRecord?>.broadcast();

  Stream<ActiveSessionRecord?> get activeSessionStream =>
      _sessionController.stream;

  Future<void> initialize() async {
    if (_initialized) {
      await _outbox.initialize();
      return;
    }
    await _outbox.initialize();
    _initialized = true;

    // تشغيل مؤقت تحديث العداد اللحظي
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_sessionController.isClosed) {
        _sessionController.add(_currentProjectedSession);
      }
    });
  }

  final Map<String, Set<String>> _phoneClosedSessions = {};

  bool phoneHasClosedSession(
    String accountId,
    String wellId,
    String sessionId,
  ) => _phoneClosedSessions['$accountId:$wellId']?.contains(sessionId) ?? false;

  void _observePhoneClosures(
    String accountId,
    List<ActiveSessionRecord> records,
  ) {
    final byLocalId = {for (final record in records) record.localId: record};
    for (final record in records.where(
      (s) => s.phoneOwned && s.wellId != null,
    )) {
      final closed = _phoneClosedSessions.putIfAbsent(
        '$accountId:${record.wellId}',
        () => <String>{},
      );
      final previousServer =
          record.bookingContext['previous_server_session_id'] as String?;
      final previousLocal =
          record.bookingContext['previous_session_local_id'] as String?;
      if (previousServer != null) closed.add(previousServer);
      if (previousLocal != null) {
        closed.add(previousLocal);
        final resolved = byLocalId[previousLocal]?.serverSessionId;
        if (resolved != null) closed.add(resolved);
      }
      if (!record.businessState.isActive) {
        closed.add(record.localId);
        if (record.serverSessionId != null) closed.add(record.serverSessionId!);
      }
    }
  }

  final Map<String, Map<String, BookingScope>> _presentationScopes = {};

  Future<void> _publishBookingPresentation(
    String accountId,
    List<ActiveSessionRecord> records,
    String? wellId,
  ) async {
    final wells = {
      ?wellId,
      ...records.map((r) => r.wellId).whereType<String>(),
    };
    for (final well in wells) {
      final lifecycle = await BookingLocalLedger.loadBookedLifecycle(
        _store,
        accountId,
        well,
      );
      final completed = records
          .where((r) => r.wellId == well && r.completedAt != null)
          .fold<ActiveSessionRecord?>(
            null,
            (latest, r) =>
                latest == null ||
                    r.completedAt!.isAfter(latest.completedAt!) ||
                    (r.completedAt == latest.completedAt &&
                        r.localId.compareTo(latest.localId) > 0)
                ? r
                : latest,
          );
      if (completed != null && !_completionController.isClosed) {
        _completionController.add(completed);
        // الأقدم يُنشر فقط إن كانت تفاصيله مركبة؛ لا أحداث لكل السجل.
        for (final record in records.where(
          (r) =>
              r.wellId == well &&
              r.completedAt != null &&
              r.localId != completed.localId &&
              r.serverSessionId != null &&
              _completionDetailViews.containsKey((
                accountId,
                well,
                r.serverSessionId!,
              )),
        )) {
          _completionController.add(record);
        }
      }
      final scope = BookingReactivity.instance.scope(accountId, well);
      (_presentationScopes[accountId] ??= {})[well] = scope;
      scope.project(
        records.where((r) => r.wellId == well),
        closed: _phoneClosedSessions['$accountId:$well'] ?? const <String>{},
        localChain:
            lifecycle != null &&
            (lifecycle['state'] != 'running' ||
                lifecycle.containsKey('next_booking_id')),
        next: lifecycle?['next_booking_id'] as String?,
      );
    }
  }

  /// كتالوج العرض المحلي فقط؛ لا يضاف أي حقل إلى حمولة RPC.
  Future<void> cacheBookingPumps(
    String accountId,
    String wellId,
    List<Pump> pumps,
  ) async {
    await initialize();
    final encoded = jsonEncode([
      for (final p in pumps.where(
        (p) => p.wellId == wellId && p.status == 'active',
      ))
        {'id': p.id, 'name': p.name},
    ]);
    final key = 'booking.pumps.v1.$wellId';
    final store = _store;
    if (store is SqliteOutboxStore) {
      await store.writeLocalValue(accountId, key, encoded);
    } else {
      await store.insertBundle(
        accountId: accountId,
        key: '$key.$encoded',
        value: encoded,
        commands: [],
        localValues: {key: encoded},
      );
    }
  }

  Future<Pump?> cachedBookingPump(
    String accountId,
    String wellId,
    String pumpId,
  ) async {
    await initialize();
    final raw = await _store.readBundle(accountId, 'booking.pumps.v1.$wellId');
    if (raw == null) return null;
    final pumps = jsonDecode(raw) as List;
    final matches = pumps
        .whereType<Map>()
        .where((p) => p['id'] == pumpId)
        .toList();
    if (matches.length != 1 || matches.single['name'] is! String) return null;
    return Pump(
      id: pumpId,
      wellId: wellId,
      name: matches.single['name'] as String,
      publicCode: '',
    );
  }

  Future<Map<String, Object?>> _bookingPumpContext(
    String accountId,
    String wellId, {
    Pump? selected,
  }) async {
    if (selected != null &&
        selected.wellId == wellId &&
        selected.id.isNotEmpty) {
      return {'p_pump_id': selected.id, 'pump_name': selected.name};
    }
    final raw = await _store.readBundle(accountId, 'booking.pumps.v1.$wellId');
    final pumps = raw == null ? const [] : jsonDecode(raw) as List;
    // عدة مضخات بلا هوية مثبتة لا تُختزل إلى اختيار عشوائي.
    if (pumps.length != 1) return {};
    final pump = pumps.single as Map;
    return {'p_pump_id': pump['id'], 'pump_name': pump['name']};
  }

  ActiveSessionRecord? _currentProjectedSession;
  int _syncProjectionGeneration = 0;
  int _freshProjectionGeneration = 0;
  ActiveSessionRecord? get currentActiveSession => _currentProjectedSession;

  Future<List<ActiveSessionRecord>> unresolvedSessions(String accountId) async {
    await initialize();
    return _projector.unresolvedSessions(accountId, now: DateTime.now());
  }

  Future<ActiveSessionRecord?> unresolvedSession(
    String accountId,
    String startCommandLocalId,
  ) async {
    await initialize();
    return _projector.unresolvedSession(
      accountId,
      startCommandLocalId,
      now: DateTime.now(),
    );
  }

  /// استرجاع وإسقاط الجلسة النشطة الحالية لبئر معين
  Future<ActiveSessionRecord?> projectActiveSession({
    required String accountId,
    String? wellId,
  }) async {
    await initialize();

    final now = DateTime.now();
    final records = await _projector.projectAll(
      accountId,
      now: now,
      wellId: wellId,
    );
    _observePhoneClosures(accountId, records);
    await _publishBookingPresentation(accountId, records, wellId);
    final activeSessions = records
        .where((s) => s.businessState.isActive)
        .toList();

    if (activeSessions.isEmpty) {
      _currentProjectedSession = null;
      _sessionController.add(null);
      return null;
    }

    // طلب بئر محدد لا يجوز أن يسقط إلى جلسة بئر آخر.
    final candidates = wellId == null
        ? activeSessions
        : activeSessions.where((session) => session.wellId == wellId).toList();
    final match = candidates.length == 1 ? candidates.single : null;

    _currentProjectedSession = match;
    _sessionController.add(_currentProjectedSession);
    return _currentProjectedSession;
  }

  /// إسقاط جديد من المخزن المتين — لا نتيجة مخبَّأة.
  ///
  /// يقرأ `allCommands` و`mappings` من SQLite مباشرة ويحمي النتيجة بجيل
  /// تصاعدي: إسقاط أقدم لا يكتب على أحدث.
  ///
  /// يُستخدم عند دخول شاشة التشغيل أو العودة إليها لالتقاط تأكيدات
  /// أجراها WorkManager عبر اتصال SQLite مستقل.
  Future<ActiveSessionRecord?> freshProjectActiveSession({
    required String accountId,
    String? wellId,
  }) async {
    final generation = ++_freshProjectionGeneration;
    await initialize();

    final now = DateTime.now();
    final records = await _projector.projectAll(
      accountId,
      now: now,
      wellId: wellId,
    );
    _observePhoneClosures(accountId, records);
    await _publishBookingPresentation(accountId, records, wellId);
    final activeSessions = records
        .where((s) => s.businessState.isActive)
        .toList();

    if (generation != _freshProjectionGeneration) {
      return _currentProjectedSession;
    }

    if (activeSessions.isEmpty) {
      _currentProjectedSession = null;
      _sessionController.add(null);
      return null;
    }

    final candidates = wellId == null
        ? activeSessions
        : activeSessions.where((s) => s.wellId == wellId).toList();
    final match = candidates.length == 1 ? candidates.single : null;

    if (generation != _freshProjectionGeneration) {
      return _currentProjectedSession;
    }

    _currentProjectedSession = match;
    _sessionController.add(_currentProjectedSession);
    return _currentProjectedSession;
  }

  final Map<String, Future<FarmerAccount>> _inFlightFarmerEnqueues = {};
  final Map<String, Future<Farm>> _inFlightFarmEnqueues = {};

  /// استرجاع المزارعين المعلقين في الطابور المتين لبئر وحساب محددين (UX-Honesty / م-21).
  Future<List<FarmerAccount>> pendingFarmers({
    required String accountId,
    required String wellId,
  }) async {
    await initialize();
    final commands = await _store.pendingCommands(accountId);
    final list = <FarmerAccount>[];
    for (final cmd in commands) {
      if (cmd.type == CommandType.createFarmer &&
          cmd.wellId == wellId &&
          cmd.status != CommandStatus.confirmed &&
          cmd.status != CommandStatus.review) {
        final mapping = await _store.mapping(
          accountId,
          cmd.localId,
          EntityKind.farmerWellAccount,
        );
        if (mapping != null) continue;

        final name = cmd.payload['p_full_name'] as String? ?? '';
        final phone = cmd.payload['p_phone'] as String?;
        if (name.isNotEmpty) {
          list.add(
            FarmerAccount.pending(
              reference: CommandReference(
                localId: cmd.localId,
                kind: EntityKind.farmerWellAccount,
              ),
              fullName: name,
              phone: phone,
            ),
          );
        }
      }
    }
    return list;
  }

  /// استرجاع الأراضي المعلقة في الطابور المتين لبئر ومزارع محددين (UX-Honesty / م-21).
  Future<List<Farm>> pendingFarms({
    required String accountId,
    required String wellId,
    EntityReference? farmerReference,
  }) async {
    await initialize();
    final commands = await _store.pendingCommands(accountId);
    final list = <Farm>[];
    for (final cmd in commands) {
      if (cmd.type == CommandType.createFarm &&
          cmd.wellId == wellId &&
          cmd.status != CommandStatus.confirmed &&
          cmd.status != CommandStatus.review) {
        final mapping = await _store.mapping(
          accountId,
          cmd.localId,
          EntityKind.farm,
        );
        if (mapping != null) continue;

        final name = cmd.payload['p_name'] as String? ?? '';
        final label = cmd.payload['p_distinguishing_label'] as String?;
        final rawFarmerRef = cmd.payload['p_farmer_well_account_id'];

        final EntityReference farmFarmerRef;
        if (rawFarmerRef is Map && CommandReference.isReference(rawFarmerRef)) {
          farmFarmerRef = PendingLocalEntityReference(
            CommandReference.fromJson(rawFarmerRef as Map<Object?, Object?>),
          );
        } else if (rawFarmerRef is String) {
          farmFarmerRef = ServerEntityReference(rawFarmerRef);
        } else {
          farmFarmerRef = const ServerEntityReference('');
        }

        if (farmerReference != null) {
          var matches = (farmFarmerRef == farmerReference);
          if (!matches && farmFarmerRef.isPending && farmerReference.isServer) {
            final fMapping = await _store.mapping(
              accountId,
              farmFarmerRef.localReference!.localId,
              EntityKind.farmerWellAccount,
            );
            if (fMapping?.serverId == farmerReference.serverId) {
              matches = true;
            }
          }
          if (!matches) continue;
        }

        if (name.isNotEmpty) {
          list.add(
            Farm.pending(
              reference: CommandReference(
                localId: cmd.localId,
                kind: EntityKind.farm,
              ),
              wellId: wellId,
              name: name,
              distinguishingLabel: label,
              farmerReference: farmFarmerRef,
            ),
          );
        }
      }
    }
    return list;
  }

  /// إنشاء مزارع جديد وحفظه متينًا في الطابور المحلي أولًا (ق-89 / ق-114 / م-21).
  Future<FarmerAccount> enqueueFarmer({
    required String accountId,
    required String wellId,
    required String fullName,
    String? phone,
    String? notes,
    String? actionToken,
  }) async {
    final cleanName = fullName.trim();
    if (cleanName.isEmpty) {
      throw ArgumentError('اسم المزارع مطلوب');
    }

    if (actionToken != null && actionToken.isNotEmpty) {
      final key = '$accountId:$wellId:$actionToken';
      final inFlight = _inFlightFarmerEnqueues[key];
      if (inFlight != null) {
        return inFlight;
      }

      final future = _doEnqueueFarmer(
        accountId: accountId,
        wellId: wellId,
        fullName: cleanName,
        phone: phone,
        notes: notes,
      );
      _inFlightFarmerEnqueues[key] = future;
      try {
        return await future;
      } finally {
        _inFlightFarmerEnqueues.remove(key);
      }
    }

    return _doEnqueueFarmer(
      accountId: accountId,
      wellId: wellId,
      fullName: cleanName,
      phone: phone,
      notes: notes,
    );
  }

  Future<FarmerAccount> _doEnqueueFarmer({
    required String accountId,
    required String wellId,
    required String fullName,
    String? phone,
    String? notes,
  }) async {
    await initialize();

    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: wellId,
      type: CommandType.createFarmer,
      occurredAt: DateTime.now(),
      payload: {
        'p_well_id': wellId,
        'p_full_name': fullName,
        if (phone != null && phone.trim().isNotEmpty) 'p_phone': phone.trim(),
        if (notes != null && notes.trim().isNotEmpty) 'p_notes': notes.trim(),
      },
    );

    await _triggerSync(accountId, wellId: wellId);

    return FarmerAccount.pending(
      reference: CommandReference(
        localId: envelope.localId,
        kind: EntityKind.farmerWellAccount,
      ),
      fullName: fullName,
      phone: phone?.trim(),
    );
  }

  /// إنشاء أرض جديدة وحفظها متينًا في الطابور المحلي أولًا (ق-89 / ق-114 / م-21).
  Future<Farm> enqueueFarm({
    required String accountId,
    required String wellId,
    required String name,
    String? distinguishingLabel,
    required EntityReference farmerReference,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw ArgumentError('اسم الأرض مطلوب');
    }

    final cleanLabel = distinguishingLabel?.trim();
    final key =
        '$accountId:$wellId:${farmerReference.toPayload()}:$cleanName:$cleanLabel';
    final inFlight = _inFlightFarmEnqueues[key];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _doEnqueueFarm(
      accountId: accountId,
      wellId: wellId,
      name: cleanName,
      distinguishingLabel: cleanLabel,
      farmerReference: farmerReference,
    );
    _inFlightFarmEnqueues[key] = future;
    try {
      return await future;
    } finally {
      _inFlightFarmEnqueues.remove(key);
    }
  }

  Future<Farm> _doEnqueueFarm({
    required String accountId,
    required String wellId,
    required String name,
    String? distinguishingLabel,
    required EntityReference farmerReference,
  }) async {
    await initialize();

    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: wellId,
      type: CommandType.createFarm,
      occurredAt: DateTime.now(),
      payload: {
        'p_well_id': wellId,
        'p_name': name,
        'p_farmer_well_account_id': farmerReference.toPayload(),
        if (distinguishingLabel != null && distinguishingLabel.isNotEmpty)
          'p_distinguishing_label': distinguishingLabel,
      },
    );

    await _triggerSync(accountId, wellId: wellId);

    return Farm.pending(
      reference: CommandReference(
        localId: envelope.localId,
        kind: EntityKind.farm,
      ),
      wellId: wellId,
      name: name,
      distinguishingLabel: distinguishingLabel,
      farmerReference: farmerReference,
    );
  }

  /// استرجاع مزارع إما بالمعرّف الخادمي أو عبر إعادة البناء من الطابور المحلي (UX-Honesty / م-21).
  Future<FarmerAccount?> resolveFarmer(
    String accountId,
    String identifier, {
    List<FarmerAccount>? cachedList,
  }) async {
    await initialize();

    if (cachedList != null) {
      for (final f in cachedList) {
        if (f.id == identifier || f.entityReference.serverId == identifier) {
          return f;
        }
      }
    }

    final command = await _outbox.byLocalId(accountId, identifier);
    if (command != null && command.type == CommandType.createFarmer) {
      final mapping = await _store.mapping(
        accountId,
        identifier,
        EntityKind.farmerWellAccount,
      );
      if (mapping != null && cachedList != null) {
        for (final f in cachedList) {
          if (f.id == mapping.serverId) return f;
        }
      }

      final name = command.payload['p_full_name'] as String? ?? 'مزارع محلي';
      final phone = command.payload['p_phone'] as String?;
      return FarmerAccount.pending(
        reference: CommandReference(
          localId: command.localId,
          kind: EntityKind.farmerWellAccount,
        ),
        fullName: name,
        phone: phone,
      );
    }

    final mappings = await _store.mappings(accountId);
    for (final m in mappings) {
      if (m.kind == EntityKind.farmerWellAccount &&
          (m.localId == identifier || m.serverId == identifier)) {
        if (cachedList != null) {
          for (final f in cachedList) {
            if (f.id == m.serverId) return f;
          }
        }
      }
    }

    return null;
  }

  /// استرجاع أرض إما بالمعرّف الخادمي أو عبر إعادة البناء من الطابور المحلي (UX-Honesty / م-21).
  Future<Farm?> resolveFarm(
    String accountId,
    String identifier, {
    List<Farm>? cachedList,
  }) async {
    await initialize();

    if (cachedList != null) {
      for (final f in cachedList) {
        if (f.id == identifier || f.entityReference.serverId == identifier) {
          return f;
        }
      }
    }

    final command = await _outbox.byLocalId(accountId, identifier);
    if (command != null && command.type == CommandType.createFarm) {
      final mapping = await _store.mapping(
        accountId,
        identifier,
        EntityKind.farm,
      );
      if (mapping != null && cachedList != null) {
        for (final f in cachedList) {
          if (f.id == mapping.serverId) return f;
        }
      }

      final name = command.payload['p_name'] as String? ?? 'أرض محلية';
      final label = command.payload['p_distinguishing_label'] as String?;
      final rawFarmerRef = command.payload['p_farmer_well_account_id'];
      final EntityReference farmerRef;
      if (rawFarmerRef is Map && CommandReference.isReference(rawFarmerRef)) {
        farmerRef = PendingLocalEntityReference(
          CommandReference.fromJson(rawFarmerRef as Map<Object?, Object?>),
        );
      } else if (rawFarmerRef is String) {
        farmerRef = ServerEntityReference(rawFarmerRef);
      } else {
        farmerRef = const ServerEntityReference('');
      }

      return Farm.pending(
        reference: CommandReference(
          localId: command.localId,
          kind: EntityKind.farm,
        ),
        wellId: command.wellId ?? '',
        name: name,
        distinguishingLabel: label,
        farmerReference: farmerRef,
      );
    }

    return null;
  }

  /// 1. بدء جلسة سقي جديدة وحفظها فوراً في الطابور المتين (ق-89 / ق-114)
  ///
  /// [crops] محاصيل هذه الجلسة (ق-131 البند 1): تسافر داخل أمر البدء
  /// نفسه في الطابور المتين، فتصل إلى الخادم مع المزامنة ولا تختفي
  /// بعدها، والفراغ مسموح ولا يمنع البدء.
  ///
  /// [plannedDurationMinutes] المدة المخطّطة (ق-132/750). `null` يعني
  /// «لم يحدد المستخدم مدة» فيسافر الأمر بالنوع القديم وحمولته الحرفية
  /// — لا مدة ضمنية ولا افتراض. بقيمة موجبة يسافر إلى عقد
  /// `start_adhoc_session` الحاكم. توفّر حجوزات قادمة لا يتحقق منه
  /// العميل إطلاقًا — الخادم وحده حاكم، والرفض يصير مراجعة بشرية.
  Future<CommandEnvelope> startSession({
    required String accountId,
    required String wellId,
    required String pumpId,
    required String farmId,
    required String farmerAccountId,
    required String energySource,
    List<String> crops = const [],
    EntityReference? farmReference,
    EntityReference? farmerReference,
    DateTime? startedAt,
    int? plannedDurationMinutes,
    String? farmerName,
    String? farmName,
    String? pumpName,
  }) async {
    await initialize();

    if (plannedDurationMinutes != null && plannedDurationMinutes <= 0) {
      throw ArgumentError.value(
        plannedDurationMinutes,
        'plannedDurationMinutes',
        'المدة المخطّطة يجب أن تكون دقائق موجبة',
      );
    }

    final eventTime = startedAt ?? DateTime.now();
    final effectiveFarm = farmReference != null
        ? farmReference.toPayload()
        : (farmId.isNotEmpty
              ? farmId
              : throw ArgumentError('معرف الأرض مطلوب'));
    final effectiveFarmer = farmerReference != null
        ? farmerReference.toPayload()
        : (farmerAccountId.isNotEmpty
              ? farmerAccountId
              : throw ArgumentError('معرف حساب المزارع مطلوب'));

    final prepared = await _outbox.prepare(
      accountId: accountId,
      wellId: wellId,
      type: plannedDurationMinutes == null
          ? CommandType.startIrrigationSession
          : CommandType.startAdhocSession,
      occurredAt: eventTime,
      localContext: {
        'farmer_name': ?farmerName,
        'farm_name': ?farmName,
        'pump_name': ?pumpName,
      },
      payload: {
        'p_well_id': wellId,
        'p_pump_id': pumpId,
        'p_farm_id': effectiveFarm,
        'p_farmer_well_account_id': effectiveFarmer,
        'p_energy_source': energySource,
        'p_planned_duration_minutes': ?plannedDurationMinutes,
        'p_crops': normalizeCropSnapshot(crops),
      },
    );

    final envelope = await _store.insert(prepared);

    await projectActiveSession(accountId: accountId, wellId: wellId);
    await _triggerSync(
      accountId,
      sessionLocalId: envelope.localId,
      wellId: wellId,
    );
    return envelope;
  }

  /// 2. إيقاف الجلسة مؤقتاً (ق-89 / ق-114)
  Future<CommandEnvelope> pauseSession({
    required String accountId,
    required String sessionLocalId,
    required String reason,
    DateTime? pausedAt,
  }) async {
    await initialize();
    if (reason != 'operator_pause' && reason != 'farmer_requested_pause') {
      throw ArgumentError.value(reason, 'reason', 'سبب إيقاف غير معتمد');
    }

    final eventTime = pausedAt ?? DateTime.now();
    final start = await _sessionStart(accountId, sessionLocalId);
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: start.wellId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.pauseIrrigationSession,
      occurredAt: eventTime,
      payload: {
        'p_session_id': _outbox.referenceTo(start).toJson(),
        'p_reason': reason,
      },
    );

    await _projectExactSession(accountId, sessionLocalId);
    await _triggerSync(accountId, sessionLocalId: sessionLocalId);
    return envelope;
  }

  /// 3. استئناف الجلسة (ق-89 / ق-114)
  Future<CommandEnvelope> resumeSession({
    required String accountId,
    required String sessionLocalId,
    DateTime? resumedAt,
  }) async {
    await initialize();

    final eventTime = resumedAt ?? DateTime.now();
    final start = await _sessionStart(accountId, sessionLocalId);
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: start.wellId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.resumeIrrigationSession,
      occurredAt: eventTime,
      payload: {'p_session_id': _outbox.referenceTo(start).toJson()},
    );

    await _projectExactSession(accountId, sessionLocalId);
    await _triggerSync(accountId, sessionLocalId: sessionLocalId);
    return envelope;
  }

  /// 4. تغيير مصدر الطاقة أثناء السقي (ق-81 / ق-114)
  Future<CommandEnvelope> changeEnergySource({
    required String accountId,
    required String sessionLocalId,
    required String newEnergySource,
    DateTime? changedAt,
  }) async {
    await initialize();

    final eventTime = changedAt ?? DateTime.now();
    final start = await _sessionStart(accountId, sessionLocalId);
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: start.wellId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.changeSessionEnergySource,
      occurredAt: eventTime,
      payload: {
        'p_session_id': _outbox.referenceTo(start).toJson(),
        'p_new_source': newEnergySource,
      },
    );

    await _projectExactSession(accountId, sessionLocalId);
    await _triggerSync(accountId, sessionLocalId: sessionLocalId);
    return envelope;
  }

  /// 5. إنهاء جلسة السقي واحتساب المستحق (ق-92 / ق-114)
  Future<CommandEnvelope> completeSession({
    required String accountId,
    required String sessionLocalId,
    DateTime? completedAt,
  }) async {
    await initialize();

    final eventTime = completedAt ?? DateTime.now();
    final start = await _sessionStart(accountId, sessionLocalId);
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: start.wellId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.completeIrrigationSession,
      occurredAt: eventTime,
      payload: {'p_session_id': _outbox.referenceTo(start).toJson()},
    );

    await _projectExactSession(accountId, sessionLocalId);
    await _triggerSync(accountId, sessionLocalId: sessionLocalId);
    return envelope;
  }

  static Map<String, Object?> _cacheDetail(SessionDetailData data) {
    final s = data.session;
    return {
      'session': {
        'id': s.id,
        'well_id': s.wellId,
        'farmer_name': s.farmerName,
        'farmer_public_code': s.farmerCode,
        'farmer_well_account_id': s.farmerAccountId,
        'farm_name': s.farmName,
        'pump_name': s.pumpName,
        'operator_name': s.operatorName,
        'started_at': s.startedAt.toIso8601String(),
        'ended_at': s.endedAt?.toIso8601String(),
        'status': s.status,
        'energy_source': s.energySourceCode,
        'actual_seconds': s.actualSeconds,
        'billable_seconds': s.billableSeconds,
        'total_amount_minor': s.totalAmountYER,
        'paid_amount_minor': s.paidAmountYER,
        'payment_status': s.paymentStatus,
        'has_charge': s.hasCharge,
        'has_invoice': s.hasInvoice,
      },
      'segments': [
        for (final seg in data.segments)
          {
            'sequence_number': seg.sequenceNumber,
            'segment_type': seg.segmentType,
            'is_stop': seg.isStop,
            'is_billable': seg.isBillable,
            'energy_source': seg.energySourceCode,
            'started_at': seg.startedAt.toIso8601String(),
            'ended_at': seg.endedAt?.toIso8601String(),
            'actual_seconds': seg.actualSeconds,
            'billable_seconds': seg.billableSeconds,
            'applied_rate_minor': seg.appliedRateYER,
            'time_charge_minor': seg.timeChargeYER,
            'fuel_charge_minor': seg.fuelChargeYER,
            'total_charge_minor': seg.totalChargeYER,
            'notes': seg.notes,
          },
      ],
      'crops': data.crops,
      'payment_method': data.paymentMethod,
      'payment_reference': data.paymentReference,
      'paid_at': data.paidAt?.toIso8601String(),
    };
  }

  // قفل قصير لكل حساب/بئر/جلسة، ولا يحتفظ بحقيقة مالية بعد انتهاء العمل.
  final _paymentSections = <(String, String, String), Future<void>>{};
  Future<T> _withSessionPaymentSection<T>(
    (String, String, String) key,
    Future<T> Function() action,
  ) async {
    final previous = _paymentSections[key];
    final release = Completer<void>();
    _paymentSections[key] = release.future;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      release.complete();
      if (identical(_paymentSections[key], release.future)) {
        _paymentSections.remove(key);
      }
    }
  }

  Future<CompletedSessionPaymentState?> _restoreSessionPayment({
    required String accountId,
    required String wellId,
    String? localSessionId,
    String? serverSessionId,
  }) async {
    await initialize();
    final snapshot = await _store.sessionSnapshot(
      accountId: accountId,
      wellId: wellId,
      localSessionId: localSessionId,
      serverSessionId: serverSessionId,
    );
    if (snapshot == null) return null;
    final record = _projector.projectCompletedSnapshot(
      snapshot,
      now: DateTime.now(),
    );
    if (record == null) return null;
    final mappedIds = {
      for (final m in snapshot.mappings) m.localId: m.serverId,
    };
    final revision = jsonEncode([
      for (final c in snapshot.commands.where(
        (c) =>
            c.type == CommandType.completeIrrigationSession ||
            c.type == CommandType.recordPayment,
      ))
        [
          c.localId,
          c.status.storageValue,
          c.serverResponse,
          mappedIds[c.localId],
        ],
    ]);
    return CompletedSessionPaymentState(
      record: record,
      revision: revision,
      paymentRead: snapshot.paymentRead,
    );
  }

  /// استعادة عند الدخول، بلا انتظار حدث أو تشغيل إسقاط البئر/المزامنة.
  Future<CompletedSessionPaymentState?> restoreCompletedSession({
    required String accountId,
    required String wellId,
    required String serverSessionId,
  }) => _restoreSessionPayment(
    accountId: accountId,
    wellId: wellId,
    serverSessionId: serverSessionId,
  );

  /// يحفظ حقائق القراءة كما أعادها الخادم؛ لا يحسب السداد من مبالغ الطلبات.
  Future<void> rememberSessionPaymentRead({
    required String accountId,
    required String wellId,
    required SessionDetailData detail,
    required String revision,
  }) async {
    final initial = await restoreCompletedSession(
      accountId: accountId,
      wellId: wellId,
      serverSessionId: detail.session.id,
    );
    if (initial == null) return;
    await _withSessionPaymentSection(
      (accountId, wellId, initial.record.localId),
      () async {
        final current = await _restoreSessionPayment(
          accountId: accountId,
          wellId: wellId,
          localSessionId: initial.record.localId,
        );
        final s = detail.session;
        if (current == null ||
            current.revision != revision ||
            s.wellId != wellId ||
            current.record.serverSessionId != s.id) {
          return;
        }
        await _store.saveSessionPaymentRead(
          accountId: accountId,
          wellId: wellId,
          localSessionId: current.record.localId,
          value: {
            'revision': revision,
            'payment_status': s.paymentStatus,
            'has_charge': s.hasCharge,
            'has_invoice': s.hasInvoice,
            'total_amount_minor': s.totalAmountYER,
            'paid_amount_minor': s.paidAmountYER,
            'remaining_amount_minor': s.remainingAmountYER,
            'detail': _cacheDetail(detail),
          },
        );
      },
    );
  }

  /// 6. تسجيل دفعة مالية وسند قبض (UX-10 / ق-91)
  Future<CommandEnvelope> recordPayment({
    required String accountId,
    required String wellId,
    required String farmerAccountId,
    required int amountMinor,
    required String paymentMethod,
    String? note,
    String? sessionLocalId,
    String? sessionCompletionLocalId,
    DateTime? paidAt,
  }) async {
    if (sessionLocalId == null) {
      return _savePayment(
        accountId: accountId,
        wellId: wellId,
        farmerAccountId: farmerAccountId,
        amountMinor: amountMinor,
        paymentMethod: paymentMethod,
        note: note,
        sessionCompletionLocalId: sessionCompletionLocalId,
        paidAt: paidAt,
      );
    }
    return _withSessionPaymentSection(
      (accountId, wellId, sessionLocalId),
      () async {
        final state = await _restoreSessionPayment(
          accountId: accountId,
          wellId: wellId,
          localSessionId: sessionLocalId,
        );
        if (state == null ||
            !state.canRecordPayment ||
            state.record.farmerReference != farmerAccountId ||
            state.record.completionCommandLocalId != sessionCompletionLocalId) {
          throw StateError(
            'لا يمكن إنشاء دفعة أخرى قبل حسم الحالة الحالية للجلسة',
          );
        }
        return _savePayment(
          accountId: accountId,
          wellId: wellId,
          farmerAccountId: farmerAccountId,
          amountMinor: amountMinor,
          paymentMethod: paymentMethod,
          note: note,
          sessionLocalId: sessionLocalId,
          sessionCompletionLocalId: sessionCompletionLocalId,
          paidAt: paidAt,
        );
      },
    );
  }

  Future<CommandEnvelope> _savePayment({
    required String accountId,
    required String wellId,
    required String farmerAccountId,
    required int amountMinor,
    required String paymentMethod,
    String? note,
    String? sessionLocalId,
    String? sessionCompletionLocalId,
    DateTime? paidAt,
  }) async {
    await initialize();

    final eventTime = paidAt ?? DateTime.now();
    Map<String, Object?>? chargeReference;
    if (sessionCompletionLocalId != null) {
      if (sessionLocalId == null) {
        throw StateError('ربط تكلفة الجلسة يتطلب مرجع الجلسة المحلية');
      }
      final start = await _sessionStart(accountId, sessionLocalId);
      if ((start.wellId ?? start.payload['p_well_id']) != wellId) {
        throw StateError('بئر الدفعة لا يطابق بئر الجلسة');
      }
      final completion = await _outbox.byLocalId(
        accountId,
        sessionCompletionLocalId,
      );
      if (completion == null ||
          completion.type != CommandType.completeIrrigationSession ||
          completion.aggregateLocalId != sessionLocalId) {
        throw StateError('أمر إنهاء الجلسة غير صالح لربط الدفعة');
      }
      chargeReference = _outbox.referenceTo(completion).toJson();
    } else if (sessionLocalId != null) {
      throw StateError('دفعة الجلسة تتطلب مرجع أمر الإنهاء');
    }
    final prepared = await _outbox.prepare(
      accountId: accountId,
      wellId: wellId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.recordPayment,
      occurredAt: eventTime,
      payload: {
        'p_well_id': wellId,
        'p_farmer_well_account_id': farmerAccountId,
        'p_amount_minor': amountMinor,
        'p_method': paymentMethod,
        'p_session_charge_id': ?chargeReference,
        'p_note': ?note,
      },
    );

    final envelope = sessionLocalId == null
        ? await _store.insert(prepared)
        : await _store.insertSessionPayment(prepared);
    if (sessionLocalId != null) {
      final updated = await _restoreSessionPayment(
        accountId: accountId,
        wellId: wellId,
        localSessionId: sessionLocalId,
      );
      if (updated != null && !_completionController.isClosed) {
        _completionController.add(updated.record);
      }
    } else {
      await projectActiveSession(accountId: accountId, wellId: wellId);
    }
    await _triggerSync(
      accountId,
      sessionLocalId: sessionLocalId,
      wellId: wellId,
      paymentOnly: sessionLocalId != null,
    );
    return envelope;
  }

  Future<CommandEnvelope> _sessionStart(
    String accountId,
    String sessionLocalId,
  ) async {
    final start = await _outbox.byLocalId(accountId, sessionLocalId);
    if (start == null || !_isSessionStartType(start.type)) {
      throw StateError('مرجع جلسة محلي غير صالح: $sessionLocalId');
    }
    return start;
  }

  /// أمر البدء سواء بالعقد القديم أو بعقد المدة المخطّطة (ق-132/750).
  static bool _isSessionStartType(CommandType type) =>
      type == CommandType.startIrrigationSession ||
      type == CommandType.startAdhocSession ||
      type == CommandType.startBookingSession;

  Future<ActiveSessionRecord?> _projectExactSession(
    String accountId,
    String sessionLocalId,
  ) async {
    final root = await _store.commandByLocalId(accountId, sessionLocalId);
    final wellId = root?.wellId ?? root?.payload['p_well_id'] as String?;
    final records = root == null
        ? <ActiveSessionRecord>[]
        : await _projector.projectAll(
            accountId,
            wellId: wellId,
            now: DateTime.now(),
          );
    final record = records
        .where((r) => r.localId == sessionLocalId)
        .firstOrNull;
    if (record != null) {
      _observePhoneClosures(accountId, records);
      await _publishBookingPresentation(accountId, records, wellId);
    }
    // تحديث مالية جلسة منتهية لا يمحو الجلسة التالية الجارية.
    final active = records.where((r) => r.businessState.isActive).toList();
    _currentProjectedSession = active.length == 1 ? active.single : null;
    _sessionController.add(_currentProjectedSession);
    return record;
  }

  Future<void> _triggerSync(
    String accountId, {
    String? sessionLocalId,
    String? wellId,
    bool paymentOnly = false,
  }) async {
    try {
      await _commandQueuedScheduler?.call(accountId);
    } catch (_) {
      // الأمر محفوظ؛ تعطل جدولة النظام لا يحوّله إلى فشل حفظ.
    }
    if (_syncEngine == null) return;
    final projectionGeneration = ++_syncProjectionGeneration;
    _syncEngine!
        .run(accountId)
        .then((_) async {
          if (!paymentOnly &&
              projectionGeneration != _syncProjectionGeneration) {
            return;
          }
          if (paymentOnly && sessionLocalId != null && wellId != null) {
            final updated = await _restoreSessionPayment(
              accountId: accountId,
              wellId: wellId,
              localSessionId: sessionLocalId,
            );
            if (updated != null && !_completionController.isClosed) {
              _completionController.add(updated.record);
            }
          } else if (sessionLocalId != null) {
            await _projectExactSession(accountId, sessionLocalId);
          } else {
            await projectActiveSession(accountId: accountId, wellId: wellId);
          }
        })
        .catchError((_) {});
  }

  /// جلب عدد العمليات المعلقة في الطابور المتين (القرار 563 / القرار 578)
  ///
  /// [accountId] هوية صاحب الطابور كما أعادها العقد. كان اختياريًّا فيسقط إلى
  /// مفتاح ثابت، فيُقرأ الطابور بمفتاح ويُكتب بآخر ويظهر «لا معلّق» كذبًا.
  Future<int> getPendingOperationsCount(String accountId) async {
    await initialize();
    return _outbox.pendingCount(accountId);
  }

  /// المخزن الافتراضي يفتح ملف الطابور نفسه الذي يستخدمه العامل الخلفي.
  bool get usesDurableStore => _store is SqliteOutboxStore;

  /// هل يوجد ناقل مزامنة موصول بهذا المنسق؟ بلا ناقل لا يجوز الادعاء أن
  /// المزامنة جرت.
  bool get canSyncNow => _syncEngine != null;

  /// آخر مزامنة ناجحة مسجَّلة في الطابور؛ `null` تعني «لم تحدث بعد».
  Future<DateTime?> lastSuccessfulSyncAt(String accountId) async {
    await initialize();
    return _outbox.lastSuccessfulSyncAt(accountId);
  }

  /// تشغيل المزامنة الآن بطلب صريح من المستخدم. يفشل صريحًا إن لم يكن
  /// هناك ناقل موصول، ولا يُدَّعى إرسال لم يحدث.
  Future<SyncRunReport> syncNow(String accountId) async {
    final engine = _syncEngine;
    if (engine == null) {
      throw StateError('لا يوجد ناقل مزامنة موصول بهذا المنسق');
    }
    await initialize();
    final report = await engine.run(accountId);
    if (report.confirmed > 0 || report.needsReview > 0) {
      // فقط نطاقات العرض المركّبة التي سبق إسقاطها، بلا جلب شبكة أو مسح حساب.
      final mounted =
          _presentationScopes[accountId]?.entries
              .where((entry) => entry.value.isMounted)
              .map((entry) => entry.key)
              .toList() ??
          const <String>[];
      for (final well in mounted) {
        final records = await _projector.projectAll(
          accountId,
          wellId: well,
          now: DateTime.now(),
        );
        _observePhoneClosures(accountId, records);
        await _publishBookingPresentation(accountId, records, well);
      }
    }
    return report;
  }

  final _inFlightResolutions = <String>{};

  /// استعراض عمليات إنشاء المزارعين التي تحتاج مراجعة وحسمًا بشريًا (ق-88 / ق-114).
  Future<List<FarmerIdentityReview>> getFarmerIdentityReviews(
    String accountId, {
    String? wellId,
  }) async {
    await initialize();
    final commands = await _store.pendingCommands(accountId);
    final reviews = <FarmerIdentityReview>[];
    for (final cmd in commands) {
      if (cmd.type == CommandType.createFarmer &&
          cmd.status == CommandStatus.review) {
        if (wellId != null &&
            cmd.wellId != wellId &&
            cmd.payload['p_well_id'] != wellId) {
          continue;
        }
        final review = FarmerIdentityReview.fromCommand(cmd);
        if (review != null) {
          reviews.add(review);
        }
      }
    }
    return reviews;
  }

  /// هل هناك قرار حسم قيد الإرسال أو مسجل في الطابور لهذا المزارع؟
  /// يمنع تكرار النقر وتكرار إدراج أوامر الحسم في الطابور.
  Future<bool> hasPendingResolutionFor(
    String accountId,
    String originalCommandLocalId,
  ) async {
    if (_inFlightResolutions.contains(originalCommandLocalId)) return true;
    await initialize();
    final commands = await _store.pendingCommands(accountId);
    return commands.any(
      (c) =>
          c.type == CommandType.resolveFarmerIdentity &&
          c.aggregateLocalId == originalCommandLocalId &&
          c.status != CommandStatus.confirmed,
    );
  }

  /// إدراج أمر حسم هوية المزارع باستخدام شخص قائم (use_existing).
  Future<CommandEnvelope> resolveFarmerWithExisting({
    required String accountId,
    required FarmerIdentityReview review,
    required String selectedPersonId,
  }) async {
    await initialize();
    if (await hasPendingResolutionFor(accountId, review.commandLocalId)) {
      throw StateError('يوجد قرار حسم معلّق بالفعل لهذا المزارع');
    }
    _inFlightResolutions.add(review.commandLocalId);
    try {
      final envelope = await _outbox.enqueue(
        accountId: accountId,
        wellId: review.wellId,
        type: CommandType.resolveFarmerIdentity,
        occurredAt: DateTime.now(),
        aggregateLocalId: review.commandLocalId,
        payload: {
          'p_well_id': review.wellId,
          'p_original_command_id': review.commandId,
          'p_resolution_action': 'use_existing',
          'p_selected_person_id': selectedPersonId,
        },
      );
      await _triggerSync(accountId, wellId: review.wellId);
      return envelope;
    } finally {
      _inFlightResolutions.remove(review.commandLocalId);
    }
  }

  /// إدراج أمر حسم هوية المزارع كشخص مختلف (different_person).
  Future<CommandEnvelope> resolveFarmerAsDifferentPerson({
    required String accountId,
    required FarmerIdentityReview review,
    required String fullName,
    String? phone,
    String? preferredName,
    String? notes,
    int? creditLimitMinor,
  }) async {
    await initialize();
    if (await hasPendingResolutionFor(accountId, review.commandLocalId)) {
      throw StateError('يوجد قرار حسم معلّق بالفعل لهذا المزارع');
    }
    _inFlightResolutions.add(review.commandLocalId);
    try {
      final envelope = await _outbox.enqueue(
        accountId: accountId,
        wellId: review.wellId,
        type: CommandType.resolveFarmerIdentity,
        occurredAt: DateTime.now(),
        aggregateLocalId: review.commandLocalId,
        payload: {
          'p_well_id': review.wellId,
          'p_original_command_id': review.commandId,
          'p_resolution_action': 'different_person',
          'p_full_name': fullName.trim(),
          if (phone != null && phone.trim().isNotEmpty) 'p_phone': phone.trim(),
          if (preferredName != null && preferredName.trim().isNotEmpty)
            'p_preferred_name': preferredName.trim(),
          if (notes != null && notes.trim().isNotEmpty) 'p_notes': notes.trim(),
          'p_credit_limit_minor': ?creditLimitMinor,
        },
      );
      await _triggerSync(accountId, wellId: review.wellId);
      return envelope;
    } finally {
      _inFlightResolutions.remove(review.commandLocalId);
    }
  }

  void dispose() {
    _tickerTimer?.cancel();
    _tickerTimer = null;
    _initialized = false;
    if (!_sessionController.isClosed) {
      _sessionController.close();
      _completionController.close();
    }
    _instance = null;
  }
}

/// قرار تسليح محلي؛ الهوية والمراجعات تمنع callback قديمًا من التنفيذ.
class BookedSessionAction {
  const BookedSessionAction({
    required this.key,
    required this.dueAt,
    required this.automation,
    this.active,
    this.nextBooking,
    this.previousCompletion,
    this.state = const {},
  });
  final String key;
  final DateTime dueAt;
  final ActiveSessionRecord? active;
  final BookingDayItem? nextBooking;
  final CommandEnvelope? previousCompletion;
  final BookingAutomationState automation;
  final Map<String, dynamic> state;
  bool sameDecisionAs(BookedSessionAction other) =>
      key == other.key &&
      dueAt == other.dueAt &&
      nextBooking?.id == other.nextBooking?.id &&
      nextBooking?.scheduledStart == other.nextBooking?.scheduledStart &&
      nextBooking?.scheduledEnd == other.nextBooking?.scheduledEnd &&
      nextBooking?.expectedDurationMinutes ==
          other.nextBooking?.expectedDurationMinutes &&
      nextBooking?.farmId == other.nextBooking?.farmId &&
      nextBooking?.farmerWellAccountId ==
          other.nextBooking?.farmerWellAccountId &&
      nextBooking?.expectedEnergySource ==
          other.nextBooking?.expectedEnergySource &&
      nextBooking?.alternativeEnergySource ==
          other.nextBooking?.alternativeEnergySource &&
      automation.revision == other.automation.revision &&
      automation.activeChainId == other.automation.activeChainId &&
      automation.activeChainDecisionRevision ==
          other.automation.activeChainDecisionRevision;
}

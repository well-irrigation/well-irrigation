import 'package:supabase_flutter/supabase_flutter.dart';

import 'booking_local_ledger.dart';
import '../sync/command_id_generator.dart';
import '../sync/sqlite_outbox_store.dart';

Map<String, dynamic> _requiredMap(Object? value, String label) {
  if (value is! Map) {
    throw StateError('$label غير صالح');
  }
  return Map<String, dynamic>.from(value);
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw StateError('عقد الحجوزات أعاد قيمة غير صالحة للحقل $key');
  }
  return value;
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw StateError('عقد الحجوزات أعاد قيمة غير صالحة للحقل $key');
  }
  return value;
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  final parsed = value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '');
  if (parsed == null) {
    throw StateError('عقد الحجوزات أعاد رقمًا غير صالح للحقل $key');
  }
  return parsed;
}

int? _optionalInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  final parsed = value is num ? value.toInt() : int.tryParse(value.toString());
  if (parsed == null) {
    throw StateError('عقد الحجوزات أعاد رقمًا غير صالح للحقل $key');
  }
  return parsed;
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) {
    throw StateError('عقد الحجوزات أعاد حالة غير صالحة للحقل $key');
  }
  return value;
}

DateTime _requiredTime(Map<String, dynamic> json, String key) {
  final value = json[key];
  final parsed = DateTime.tryParse(value?.toString() ?? '');
  if (parsed == null) {
    throw StateError('عقد الحجوزات أعاد وقتًا غير صالح للحقل $key');
  }
  return parsed;
}

DateTime? _optionalTime(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  final parsed = DateTime.tryParse(value.toString());
  if (parsed == null) {
    throw StateError('عقد الحجوزات أعاد وقتًا غير صالح للحقل $key');
  }
  return parsed;
}

class BookingSessionSummary {
  const BookingSessionSummary({
    required this.sessionId,
    required this.status,
    required this.startedAt,
    this.endedAt,
  });

  factory BookingSessionSummary.fromJson(Map<String, dynamic> json) {
    return BookingSessionSummary(
      sessionId: _requiredString(json, 'session_id'),
      status: _requiredString(json, 'status'),
      startedAt: _requiredTime(json, 'started_at'),
      endedAt: _optionalTime(json, 'ended_at'),
    );
  }

  final String sessionId;
  final String status;
  final DateTime startedAt;
  final DateTime? endedAt;
}

class CurrentBookingSession {
  const CurrentBookingSession({
    required this.sessionId,
    required this.status,
    required this.startedAt,
    required this.wellId,
    this.bookingId,
    this.bookingPublicCode,
  });

  factory CurrentBookingSession.fromJson(Map<String, dynamic> json) {
    return CurrentBookingSession(
      sessionId: _requiredString(json, 'session_id'),
      status: _requiredString(json, 'status'),
      startedAt: _requiredTime(json, 'started_at'),
      wellId: _requiredString(json, 'well_id'),
      bookingId: _optionalString(json, 'booking_id'),
      bookingPublicCode: _optionalString(json, 'booking_public_code'),
    );
  }

  final String sessionId;
  final String status;
  final DateTime startedAt;
  final String wellId;
  final String? bookingId;
  final String? bookingPublicCode;
}

class BookingDayItem {
  const BookingDayItem({
    required this.id,
    required this.publicCode,
    required this.wellId,
    required this.farmerWellAccountId,
    this.farmId,
    required this.scheduledStart,
    required this.scheduledEnd,
    required this.scheduledDay,
    required this.expectedDurationMinutes,
    required this.status,
    required this.priority,
    required this.statusGroup,
    this.farmerName,
    this.farmName,
    this.expectedEnergySource,
    this.alternativeEnergySource,
    this.notes,
    this.session,
  });

  factory BookingDayItem.fromJson(Map<String, dynamic> json) {
    final rawSession = json['session'];
    return BookingDayItem(
      id: _requiredString(json, 'id'),
      publicCode: _requiredString(json, 'public_code'),
      wellId: _requiredString(json, 'well_id'),
      farmerWellAccountId: _requiredString(json, 'farmer_well_account_id'),
      farmerName: _optionalString(json, 'farmer_name'),
      farmId: _optionalString(json, 'farm_id'),
      farmName: _optionalString(json, 'farm_name'),
      scheduledStart: _requiredTime(json, 'scheduled_start'),
      scheduledEnd: _requiredTime(json, 'scheduled_end'),
      scheduledDay: _requiredString(json, 'scheduled_day'),
      expectedDurationMinutes: _requiredInt(json, 'expected_duration_minutes'),
      expectedEnergySource: _optionalString(json, 'expected_energy_source'),
      alternativeEnergySource: _optionalString(
        json,
        'alternative_energy_source',
      ),
      status: _requiredString(json, 'status'),
      priority: _requiredInt(json, 'priority'),
      statusGroup: _requiredString(json, 'status_group'),
      notes: _optionalString(json, 'notes'),
      session: rawSession == null
          ? null
          : BookingSessionSummary.fromJson(
              _requiredMap(rawSession, 'جلسة الحجز'),
            ),
    );
  }

  final String id;
  final String publicCode;
  final String wellId;
  final String farmerWellAccountId;
  final String? farmerName;
  final String? farmId;
  final String? farmName;
  final DateTime scheduledStart;
  final DateTime scheduledEnd;
  final String scheduledDay;
  final int expectedDurationMinutes;
  final String? expectedEnergySource;
  final String? alternativeEnergySource;
  final String status;
  final int priority;
  final String statusGroup;
  final String? notes;
  final BookingSessionSummary? session;

  bool get canStartManually =>
      status == 'confirmed' &&
      session == null &&
      farmId != null &&
      expectedEnergySource != null;
}

class WellDaySchedule {
  const WellDaySchedule({
    required this.wellId,
    required this.requestedDay,
    required this.timezone,
    required this.dayStart,
    required this.dayEnd,
    required this.wellTimezone,
    required this.bookings,
    this.currentSession,
    this.sourceResponse,
  });

  factory WellDaySchedule.fromContract(Object? response) {
    final json = _requiredMap(response, 'استجابة جدول اليوم');
    if (json['status'] != 'ok') {
      throw StateError('عقد جدول اليوم لم يُعِد status=ok');
    }
    final rawBookings = json['bookings'];
    if (rawBookings is! List) {
      throw StateError('عقد جدول اليوم لم يُعِد قائمة حجوزات');
    }
    final rawCurrent = json['current_session'];
    final requestedDay = DateTime.tryParse(
      _requiredString(json, 'requested_day'),
    );
    if (requestedDay == null) {
      throw StateError('عقد جدول اليوم أعاد requested_day غير صالح');
    }

    return WellDaySchedule(
      wellId: _requiredString(json, 'well_id'),
      requestedDay: requestedDay,
      timezone: _requiredString(json, 'timezone'),
      dayStart: _requiredTime(json, 'day_start'),
      dayEnd: _requiredTime(json, 'day_end'),
      wellTimezone: _requiredString(json, 'well_timezone'),
      currentSession: rawCurrent == null
          ? null
          : CurrentBookingSession.fromJson(
              _requiredMap(rawCurrent, 'الجلسة الجارية'),
            ),
      bookings: rawBookings
          .map(
            (item) => BookingDayItem.fromJson(_requiredMap(item, 'عنصر حجز')),
          )
          .toList(growable: false),
      sourceResponse: json,
    );
  }

  final String wellId;
  final DateTime requestedDay;
  final String timezone;
  final DateTime dayStart;
  final DateTime dayEnd;
  final String wellTimezone;
  final CurrentBookingSession? currentSession;
  final List<BookingDayItem> bookings;
  final Map<String, dynamic>? sourceResponse;
}

class BookingScheduleView {
  const BookingScheduleView({
    required this.schedule,
    required this.isCached,
    required this.fetchedAt,
  });
  final WellDaySchedule schedule;
  final bool isCached;
  final DateTime fetchedAt;
}

class BookingAutomationState {
  const BookingAutomationState({
    required this.wellId,
    required this.enabled,
    required this.settingsRowExists,
    required this.firstSession,
    this.revision,
    this.activeChainId,
    this.activeChainStatus,
    this.activeChainNextBookingId,
    this.activeChainDecisionRevision,
    this.sourceResponse,
  });

  factory BookingAutomationState.fromContract(Object? response) {
    final json = _requiredMap(response, 'استجابة إعداد الانتقال التلقائي');
    if (json['contract'] != 'get_well_booking_automation' ||
        json['version'] != 1) {
      throw StateError('إصدار عقد إعداد الانتقال التلقائي غير متوافق');
    }
    final rawChain = json['active_chain'];
    String? chainId;
    String? chainStatus;
    String? nextBookingId;
    int? chainDecisionRevision;
    if (rawChain != null) {
      final chain = _requiredMap(rawChain, 'سلسلة الانتقال');
      chainId = _requiredString(chain, 'chain_id');
      chainStatus = _requiredString(chain, 'status');
      nextBookingId = _optionalString(chain, 'next_booking_id');
      chainDecisionRevision = _optionalInt(chain, 'decision_revision');
    }

    final firstSession = _requiredString(json, 'first_session');
    if (firstSession != 'manual') {
      throw StateError('عقد الأتمتة لم يثبت أن أول جلسة يدوية');
    }

    return BookingAutomationState(
      wellId: _requiredString(json, 'well_id'),
      enabled: _requiredBool(json, 'booking_auto_transition_enabled'),
      revision: _optionalInt(json, 'booking_auto_transition_revision'),
      settingsRowExists: _requiredBool(json, 'settings_row_exists'),
      firstSession: firstSession,
      activeChainId: chainId,
      activeChainStatus: chainStatus,
      activeChainNextBookingId: nextBookingId,
      activeChainDecisionRevision: chainDecisionRevision,
      sourceResponse: json,
    );
  }

  final String wellId;
  final bool enabled;
  final int? revision;
  final bool settingsRowExists;
  final String firstSession;
  final String? activeChainId;
  final String? activeChainStatus;
  final String? activeChainNextBookingId;
  final int? activeChainDecisionRevision;
  final Map<String, dynamic>? sourceResponse;

  BookingAutomationState applyUpdate(BookingAutomationUpdate update) {
    if (update.wellId != wellId) {
      throw StateError('رد تحديث الأتمتة يعود إلى بئر مختلف');
    }
    return BookingAutomationState(
      wellId: wellId,
      enabled: update.enabled,
      revision: update.revision,
      settingsRowExists: true,
      firstSession: firstSession,
      activeChainId: activeChainId,
      activeChainStatus: activeChainStatus,
      activeChainNextBookingId: activeChainNextBookingId,
      activeChainDecisionRevision: activeChainDecisionRevision,
      sourceResponse: null,
    );
  }
}

class BookingAutomationUpdate {
  const BookingAutomationUpdate({
    required this.wellId,
    required this.enabled,
    required this.revision,
  });

  factory BookingAutomationUpdate.fromContract(Object? response) {
    final json = _requiredMap(response, 'استجابة تحديث الانتقال التلقائي');
    if (json['contract'] != 'set_well_booking_automation' ||
        json['version'] != 1 ||
        json['setting_saved'] != true) {
      throw StateError('عقد تحديث الانتقال التلقائي غير متوافق');
    }
    return BookingAutomationUpdate(
      wellId: _requiredString(json, 'well_id'),
      enabled: _requiredBool(json, 'booking_auto_transition_enabled'),
      revision: _requiredInt(json, 'booking_auto_transition_revision'),
    );
  }

  final String wellId;
  final bool enabled;
  final int revision;
}

class BookingStartResult {
  const BookingStartResult({
    required this.bookingId,
    required this.sessionId,
    required this.sessionStatus,
    required this.wellId,
    required this.startedAt,
    required this.operationalEndAt,
  });

  factory BookingStartResult.fromContract(Object? response) {
    final json = _requiredMap(response, 'استجابة بدء الحجز');
    return BookingStartResult(
      bookingId: _requiredString(json, 'booking_id'),
      sessionId: _requiredString(json, 'session_id'),
      sessionStatus: _requiredString(json, 'session_status'),
      wellId: _requiredString(json, 'well_id'),
      startedAt: _requiredTime(json, 'started_at'),
      operationalEndAt: _requiredTime(json, 'operational_end_at'),
    );
  }

  final String bookingId;
  final String sessionId;
  final String sessionStatus;
  final String wellId;
  final DateTime startedAt;
  final DateTime operationalEndAt;
}

class BookingReconciliationReceipt {
  const BookingReconciliationReceipt({
    required this.closedSessionId,
    required this.closedAt,
    required this.startedSessionId,
    required this.startedBookingId,
    required this.startedAt,
  });

  factory BookingReconciliationReceipt.fromJson(Map<String, dynamic> json) {
    final closed = _requiredMap(json['closed_session'], 'الجلسة المغلقة');
    final started = _requiredMap(json['started_session'], 'الجلسة المفتوحة');
    return BookingReconciliationReceipt(
      closedSessionId: _requiredString(closed, 'id'),
      closedAt: _requiredTime(closed, 'ended_at'),
      startedSessionId: _requiredString(started, 'id'),
      startedBookingId: _requiredString(started, 'booking_id'),
      startedAt: _requiredTime(started, 'started_at'),
    );
  }

  final String closedSessionId;
  final DateTime closedAt;
  final String startedSessionId;
  final String startedBookingId;
  final DateTime startedAt;

  Map<String, Object?> toJson() => {
    'closed_session': {
      'id': closedSessionId,
      'ended_at': closedAt.toUtc().toIso8601String(),
    },
    'started_session': {
      'id': startedSessionId,
      'booking_id': startedBookingId,
      'started_at': startedAt.toUtc().toIso8601String(),
    },
  };
}

class BookingTransitionReconciliation {
  const BookingTransitionReconciliation({
    required this.status,
    required this.requestedCommandId,
    required this.wellId,
    required this.chainId,
    required this.currentSessionId,
    required this.nextBookingId,
    required this.decisionRevision,
    required this.automationRevision,
    required this.matchKind,
    required this.canonicalCommandId,
    required this.canonicalResult,
    required this.receipt,
    required this.reviewReason,
  });

  factory BookingTransitionReconciliation.fromContract(Object? response) {
    final json = _requiredMap(response, 'استجابة مصالحة انتقال الحجز');
    if (json['contract'] != 'get_booking_transition_reconciliation' ||
        json['version'] != 1) {
      throw StateError('إصدار عقد مصالحة الحجز غير متوافق');
    }
    final status = _requiredString(json, 'status');
    if (!{'found', 'not_found', 'conflict', 'rejected'}.contains(status)) {
      throw StateError('حالة مصالحة الحجز غير معروفة');
    }
    final matchKind = _optionalString(json, 'match_kind');
    if (matchKind != null &&
        matchKind != 'exact_command' &&
        matchKind != 'logical_intent') {
      throw StateError('نوع مطابقة الحجز غير صالح');
    }
    final canonicalResult = _optionalString(json, 'canonical_result');
    if (canonicalResult != null &&
        !{'accepted', 'replayed', 'rejected'}.contains(canonicalResult)) {
      throw StateError('نتيجة خادم الحجز غير صالحة');
    }
    final rawReceipt = json['business_receipt'];
    final receipt = rawReceipt == null
        ? null
        : BookingReconciliationReceipt.fromJson(
            _requiredMap(rawReceipt, 'إيصال المصالحة'),
          );
    final result = BookingTransitionReconciliation(
      status: status,
      requestedCommandId: _requiredString(json, 'requested_command_id'),
      canonicalCommandId: _optionalString(json, 'canonical_command_id'),
      wellId: _requiredString(json, 'well_id'),
      chainId: _requiredString(json, 'chain_id'),
      currentSessionId: _requiredString(json, 'current_session_id'),
      nextBookingId: _requiredString(json, 'next_booking_id'),
      decisionRevision: _requiredInt(json, 'decision_revision'),
      automationRevision: _requiredInt(json, 'automation_revision'),
      matchKind: matchKind,
      canonicalResult: canonicalResult,
      receipt: receipt,
      reviewReason: _optionalString(json, 'review_reason'),
    );
    if (result.isCanonicalMatch &&
        (result.canonicalCommandId == null ||
            result.receipt == null ||
            result.matchKind == null)) {
      throw StateError('إيصال مصالحة كنوني ناقص');
    }
    return result;
  }

  final String status;
  final String requestedCommandId;
  final String wellId;
  final String chainId;
  final String currentSessionId;
  final String nextBookingId;
  final int decisionRevision;
  final int automationRevision;
  final String? matchKind;
  final String? canonicalCommandId;
  final String? canonicalResult;
  final BookingReconciliationReceipt? receipt;
  final String? reviewReason;

  bool get isCanonicalMatch =>
      status == 'found' &&
      (canonicalResult == 'accepted' || canonicalResult == 'replayed');
}

class BookingRepository {
  BookingRepository([
    this._client,
    IdGenerator? idGenerator,
    BookingLocalLedger? localLedger,
  ]) : _ids = idGenerator ?? SecureIdGenerator(),
       _localLedger = localLedger ?? BookingLocalLedger(SqliteOutboxStore());

  final SupabaseClient? _client;
  final IdGenerator _ids;
  final BookingLocalLedger _localLedger;

  Future<BookingScheduleView> fetchScheduleView({
    required String accountId,
    required String wellId,
  }) async {
    try {
      final schedule = await fetchTodaySchedule(wellId);
      final fetchedAt = DateTime.now().toUtc();
      if (schedule.sourceResponse != null) {
        await _localLedger.saveSchedule(
          accountId: accountId,
          wellId: wellId,
          response: schedule.sourceResponse!,
          fetchedAt: fetchedAt,
        );
      }
      return BookingScheduleView(
        schedule: schedule,
        isCached: false,
        fetchedAt: fetchedAt,
      );
    } catch (_) {
      final cached = await _localLedger.loadLatestSchedule(accountId, wellId);
      if (cached == null) rethrow;
      return BookingScheduleView(
        schedule: cached.schedule,
        isCached: true,
        fetchedAt: cached.fetchedAt,
      );
    }
  }

  Future<(BookingAutomationState, bool)> fetchAutomationView({
    required String accountId,
    required String wellId,
  }) async {
    try {
      final state = await fetchAutomation(wellId);
      if (state.sourceResponse != null) {
        await _localLedger.saveAutomation(
          accountId: accountId,
          wellId: wellId,
          response: state.sourceResponse!,
        );
      }
      return (state, false);
    } catch (_) {
      final cached = await _localLedger.loadAutomation(accountId, wellId);
      if (cached == null) rethrow;
      return (cached, true);
    }
  }

  SupabaseClient? get _effectiveClient {
    if (_client != null) return _client;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  String newCommandId() => _ids.newId();

  Future<WellDaySchedule> fetchTodaySchedule(String wellId) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }
    final response = await client
        .schema('api')
        .rpc('get_well_day_schedule', params: {'p_well_id': wellId});
    final schedule = WellDaySchedule.fromContract(response);
    if (schedule.wellId != wellId) {
      throw StateError('جدول اليوم عاد لبئر مختلف');
    }
    return schedule;
  }

  Future<BookingAutomationState> fetchAutomation(String wellId) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }
    final response = await client
        .schema('api')
        .rpc('get_well_booking_automation', params: {'p_well_id': wellId});
    final state = BookingAutomationState.fromContract(response);
    if (state.wellId != wellId) {
      throw StateError('إعداد الانتقال التلقائي عاد لبئر مختلف');
    }
    return state;
  }

  Future<BookingTransitionReconciliation>
  getBookingTransitionReconciliation({
    required String wellId,
    required String chainId,
    required String currentSessionId,
    required String nextBookingId,
    required int decisionRevision,
    required int automationRevision,
    required String commandId,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }
    final response = await client.schema('api').rpc(
      'get_booking_transition_reconciliation',
      params: {
        'p_well_id': wellId,
        'p_chain_id': chainId,
        'p_current_session_id': currentSessionId,
        'p_next_booking_id': nextBookingId,
        'p_decision_revision': decisionRevision,
        'p_automation_revision': automationRevision,
        'p_command_id': commandId,
      },
    );
    final result = BookingTransitionReconciliation.fromContract(response);
    if (result.requestedCommandId != commandId ||
        result.wellId != wellId ||
        result.chainId != chainId ||
        result.currentSessionId != currentSessionId ||
        result.nextBookingId != nextBookingId ||
        result.decisionRevision != decisionRevision ||
        result.automationRevision != automationRevision) {
      throw StateError('عقد المصالحة أعاد نية مختلفة');
    }
    return result;
  }

  /// يعيد محاولة القراءة فقط. فشل الشبكة يُرفع بلا تغيير للنية المحلية؛
  /// لا توجد هنا إعادة إرسال أو تنفيذ أعمال.
  Future<List<BookingTransitionIntent>> reconcilePendingLocalIntents({
    required String accountId,
    required String wellId,
  }) async {
    final pending = await _localLedger.loadAwaitingIntents(accountId, wellId);
    final reconciled = <BookingTransitionIntent>[];
    for (final intent in pending) {
      final result = await getBookingTransitionReconciliation(
        wellId: intent.wellId,
        chainId: intent.chainId,
        currentSessionId: intent.currentSessionId,
        nextBookingId: intent.nextBookingId,
        decisionRevision: intent.decisionRevision,
        automationRevision: intent.automationRevision,
        commandId: intent.commandId,
      );
      reconciled.add(
        await _localLedger.reconcileReadResult(accountId, intent, result),
      );
    }
    return reconciled;
  }

  Future<BookingAutomationUpdate> setAutomation({
    required String wellId,
    required bool enabled,
    required int? expectedRevision,
    required String commandId,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }
    final response = await client
        .schema('api')
        .rpc(
          'set_well_booking_automation',
          params: {
            'p_well_id': wellId,
            'p_enabled': enabled,
            'p_expected_revision': expectedRevision,
            'p_command_id': commandId,
          },
        );
    return BookingAutomationUpdate.fromContract(response);
  }

  Future<BookingStartResult> startBooking({
    required String bookingId,
    required DateTime startedAt,
    required String commandId,
    List<String> crops = const [],
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }
    final response = await client
        .schema('api')
        .rpc(
          'start_irrigation_session_from_booking',
          params: {
            'p_booking_id': bookingId,
            'p_started_at': startedAt.toUtc().toIso8601String(),
            'p_command_id': commandId,
            'p_crops': crops,
          },
        );
    return BookingStartResult.fromContract(response);
  }
}

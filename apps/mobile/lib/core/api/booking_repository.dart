import 'package:supabase_flutter/supabase_flutter.dart';

import '../sync/command_id_generator.dart';

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
    required this.farmId,
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
      farmId: _requiredString(json, 'farm_id'),
      farmName: _optionalString(json, 'farm_name'),
      scheduledStart: _requiredTime(json, 'scheduled_start'),
      scheduledEnd: _requiredTime(json, 'scheduled_end'),
      scheduledDay: _requiredString(json, 'scheduled_day'),
      expectedDurationMinutes: _requiredInt(
        json,
        'expected_duration_minutes',
      ),
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
  final String farmId;
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

  bool get canStartManually => status == 'confirmed' && session == null;
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
            (item) => BookingDayItem.fromJson(
              _requiredMap(item, 'عنصر حجز'),
            ),
          )
          .toList(growable: false),
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
    if (rawChain != null) {
      final chain = _requiredMap(rawChain, 'سلسلة الانتقال');
      chainId = _requiredString(chain, 'chain_id');
      chainStatus = _requiredString(chain, 'status');
      nextBookingId = _optionalString(chain, 'next_booking_id');
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

class BookingRepository {
  BookingRepository([this._client, IdGenerator? idGenerator])
    : _ids = idGenerator ?? SecureIdGenerator();

  final SupabaseClient? _client;
  final IdGenerator _ids;

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
        .rpc(
          'get_well_booking_automation',
          params: {'p_well_id': wellId},
        );
    final state = BookingAutomationState.fromContract(response);
    if (state.wellId != wellId) {
      throw StateError('إعداد الانتقال التلقائي عاد لبئر مختلف');
    }
    return state;
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

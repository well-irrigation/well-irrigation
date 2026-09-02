import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/digit_utils.dart';

/// نماذج وبيانات التشغيل الميداني وسجل الجلسات (UX-07 / UX-08 / UX-13 / ق-80 / ق-84 / ق-98 / ق-114)

class FarmerAccount {
  const FarmerAccount({
    required this.id,
    required this.fullName,
    required this.publicCode,
    this.phone,
    this.status = 'active',
  });

  factory FarmerAccount.fromJson(Map<String, dynamic> json) {
    return FarmerAccount(
      id: json['id'] as String? ?? '',
      fullName: json['full_name'] as String? ?? '',
      publicCode: json['public_code'] as String? ?? '',
      phone: json['phone'] as String?,
      status: json['status'] as String? ?? 'active',
    );
  }

  final String id; // farmer_well_account_id
  final String fullName;
  final String publicCode;
  final String? phone;
  final String status;
}

class Farm {
  const Farm({
    required this.id,
    required this.wellId,
    required this.name,
    this.farmerAccountId,
    this.status = 'active',
  });

  factory Farm.fromJson(Map<String, dynamic> json) {
    return Farm(
      id: json['id'] as String? ?? '',
      wellId: json['well_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      farmerAccountId: json['farmer_well_account_id'] as String?,
      status: json['status'] as String? ?? 'active',
    );
  }

  final String id; // farm_id
  final String wellId;
  final String name;
  final String? farmerAccountId;
  final String status;
}

class Pump {
  const Pump({
    required this.id,
    required this.wellId,
    required this.name,
    required this.publicCode,
    this.status = 'active',
  });

  factory Pump.fromJson(Map<String, dynamic> json) {
    return Pump(
      id: json['id'] as String? ?? '',
      wellId: json['well_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      publicCode: json['public_code'] as String? ?? '',
      status: json['status'] as String? ?? 'active',
    );
  }

  final String id; // pump_id
  final String wellId;
  final String name;
  final String publicCode;
  final String status;
}

/// تخطيط صريح لرموز مصدر الطاقة كما تُخزَّن في `ops.session_segments`
/// (م-41C2). لا Blind Remap: الرمز غير المعروف يُعاد كما هو حتى يظهر
/// النقص في الشاشة بدل أن يُترجم بالتخمين.
const Map<String, String> kEnergySourceLabels = {
  'solar': 'طاقة شمسية',
  'well_diesel': 'ديزل البئر',
  'farmer_diesel': 'ديزل المزارع',
};

String energySourceLabel(String? code) {
  if (code == null || code.isEmpty) return 'غير محدد';
  return kEnergySourceLabels[code] ?? code;
}

/// تخطيط صريح لرموز `segment_type` التسعة المسموح بها في القاعدة.
const Map<String, String> kSegmentTypeLabels = {
  'solar_run': 'تشغيل بالطاقة الشمسية',
  'well_diesel_run': 'تشغيل بديزل البئر',
  'farmer_diesel_run': 'تشغيل بديزل المزارع',
  'billable_stop': 'توقف محسوب على المزارع',
  'non_billable_stop': 'توقف غير محسوب',
  'breakdown': 'تعطل',
  'operator_pause': 'إيقاف من المشغل',
  'farmer_requested_pause': 'إيقاف بطلب المزارع',
  'source_change_pause': 'إيقاف لتغيير مصدر الطاقة',
};

String segmentTypeLabel(String? code) {
  if (code == null || code.isEmpty) return 'مقطع غير محدد';
  return kSegmentTypeLabels[code] ?? code;
}

class SessionHistoryItem {
  const SessionHistoryItem({
    required this.id,
    required this.wellId,
    required this.farmerName,
    required this.farmerCode,
    required this.farmerAccountId,
    required this.farmName,
    required this.pumpName,
    required this.operatorName,
    required this.startedAt,
    this.endedAt,
    this.status = 'closed',
    this.energySourceCode,
    this.billableSeconds = 0,
    this.totalAmountYER = 0,
    this.paidAmountYER = 0,
    this.paymentStatus = 'not_billed',
    this.hasCharge = false,
    this.hasInvoice = false,
    this.isSynced = true,
  });

  /// بناء العنصر من عقد `api.list_well_sessions` / `api.get_session_detail`.
  /// الجلسة غير المفوترة تصل بمبالغ null، فتبقى أصفارًا مع `hasCharge=false`
  /// وحالة `not_billed` — لا مبلغ مخترع ولا حالة سداد مصطنعة (ق-99).
  factory SessionHistoryItem.fromContract(Map<String, dynamic> json) {
    return SessionHistoryItem(
      id: json['id'] as String? ?? '',
      wellId: json['well_id'] as String? ?? '',
      farmerName: json['farmer_name'] as String? ?? 'غير محدد',
      farmerCode: json['farmer_public_code'] as String? ?? '',
      farmerAccountId: json['farmer_well_account_id'] as String? ?? '',
      farmName: json['farm_name'] as String? ?? 'غير محددة',
      pumpName: json['pump_name'] as String? ?? 'غير محددة',
      operatorName: json['operator_name'] as String? ?? 'غير محدد',
      startedAt:
          DateTime.tryParse(json['started_at'] as String? ?? '')?.toLocal() ??
              DateTime.now(),
      endedAt: json['ended_at'] != null
          ? DateTime.tryParse(json['ended_at'] as String)?.toLocal()
          : null,
      status: json['status'] as String? ?? 'closed',
      energySourceCode: json['energy_source'] as String?,
      billableSeconds: (json['billable_seconds'] as num?)?.toInt() ?? 0,
      totalAmountYER: (json['total_amount_minor'] as num?)?.toInt() ?? 0,
      paidAmountYER: (json['paid_amount_minor'] as num?)?.toInt() ?? 0,
      paymentStatus: json['payment_status'] as String? ?? 'not_billed',
      hasCharge: json['has_charge'] as bool? ?? false,
      hasInvoice: json['has_invoice'] as bool? ?? false,
    );
  }

  final String id;
  final String wellId;
  final String farmerName;
  final String farmerCode;
  final String farmerAccountId;
  final String farmName;
  final String pumpName;
  final String operatorName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String status;

  /// رمز القاعدة كما هو (`solar` / `well_diesel` / `farmer_diesel`)
  final String? energySourceCode;
  final int billableSeconds;
  final int totalAmountYER;
  final int paidAmountYER;

  /// `not_billed` / `unpaid` / `partial` / `settled` كما يحسمها العقد
  final String paymentStatus;
  final bool hasCharge;
  final bool hasInvoice;
  final bool isSynced;

  String get energySource => energySourceLabel(energySourceCode);

  bool get isBilled => hasCharge;

  int get remainingAmountYER =>
      (totalAmountYER - paidAmountYER) > 0 ? (totalAmountYER - paidAmountYER) : 0;

  bool get isFullySettled => hasCharge && paymentStatus == 'settled';
}

class SessionSegmentItem {
  const SessionSegmentItem({
    required this.sequenceNumber,
    required this.segmentType,
    required this.isStop,
    required this.isBillable,
    required this.startedAt,
    this.endedAt,
    this.energySourceCode,
    this.actualSeconds = 0,
    this.billableSeconds = 0,
    this.appliedRateYER = 0,
    this.timeChargeYER = 0,
    this.fuelChargeYER = 0,
    this.totalChargeYER = 0,
    this.notes,
  });

  /// المقطع كما تعيده القاعدة: أعمدة الثواني والمبالغ المخزّنة، لا حساب محلي.
  factory SessionSegmentItem.fromContract(Map<String, dynamic> json) {
    return SessionSegmentItem(
      sequenceNumber: (json['sequence_number'] as num?)?.toInt() ?? 0,
      segmentType: json['segment_type'] as String? ?? '',
      isStop: json['is_stop'] as bool? ?? false,
      isBillable: json['is_billable'] as bool? ?? false,
      startedAt:
          DateTime.tryParse(json['started_at'] as String? ?? '')?.toLocal() ??
              DateTime.now(),
      endedAt: json['ended_at'] != null
          ? DateTime.tryParse(json['ended_at'] as String)?.toLocal()
          : null,
      energySourceCode: json['energy_source'] as String?,
      actualSeconds: (json['actual_seconds'] as num?)?.toInt() ?? 0,
      billableSeconds: (json['billable_seconds'] as num?)?.toInt() ?? 0,
      appliedRateYER: (json['applied_rate_minor'] as num?)?.toInt() ?? 0,
      timeChargeYER: (json['time_charge_minor'] as num?)?.toInt() ?? 0,
      fuelChargeYER: (json['fuel_charge_minor'] as num?)?.toInt() ?? 0,
      totalChargeYER: (json['total_charge_minor'] as num?)?.toInt() ?? 0,
      notes: json['notes'] as String?,
    );
  }

  final int sequenceNumber;
  final String segmentType;
  final bool isStop;
  final bool isBillable;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? energySourceCode;
  final int actualSeconds;
  final int billableSeconds;
  final int appliedRateYER;
  final int timeChargeYER;
  final int fuelChargeYER;
  final int totalChargeYER;
  final String? notes;

  String get energySource => energySourceLabel(energySourceCode);
  String get typeLabel => segmentTypeLabel(segmentType);
}

class SessionDetailData {
  const SessionDetailData({
    required this.session,
    required this.segments,
    this.paymentMethod,
    this.paymentReference,
    this.paidAt,
  });

  final SessionHistoryItem session;
  final List<SessionSegmentItem> segments;
  final String? paymentMethod;
  final String? paymentReference;
  final DateTime? paidAt;
}

class FarmerDetailData {
  const FarmerDetailData({
    required this.account,
    required this.farms,
    required this.totalSessionsCount,
    required this.totalBilledYER,
    required this.totalPaidYER,
    required this.netBalanceYER,
    required this.recentSessions,
  });

  final FarmerAccount account;
  final List<Farm> farms;
  final int totalSessionsCount;
  final int totalBilledYER;
  final int totalPaidYER;
  final int netBalanceYER;
  final List<SessionHistoryItem> recentSessions;
}

class OperationsRepository {
  const OperationsRepository([this._client]);

  final SupabaseClient? _client;

  SupabaseClient? get _effectiveClient {
    if (_client != null) return _client;
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  /// استخراج عناصر عقد قراءة من مغلّف `{contract, version, items}` (ق-98)
  List<Map<String, dynamic>> _contractItems(dynamic response) {
    if (response is! Map) {
      throw StateError('استجابة عقد القراءة غير متوقعة');
    }
    final items = response['items'];
    if (items is! List) {
      throw StateError('عقد القراءة لم يُعِد قائمة عناصر');
    }
    return items
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// جلب قائمة المزارعين المسجلين في البئر مع إمكانية البحث بالاسم أو الهاتف
  /// عبر عقد `api.list_well_farmers` (م-41C1 / ق-98). لا بيانات تجريبية:
  /// أي فشل يصل إلى الشاشة كخطأ صريح.
  Future<List<FarmerAccount>> fetchFarmers(
    String wellId, {
    String? query,
  }) async {
    final cleanQuery = query != null ? normalizeArabicDigits(query).trim() : null;
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    final response = await client.schema('api').rpc(
      'list_well_farmers',
      params: {
        'p_well_id': wellId,
        'p_query': (cleanQuery != null && cleanQuery.isNotEmpty) ? cleanQuery : null,
      },
    );

    return _contractItems(response).map(FarmerAccount.fromJson).toList();
  }

  /// جلب أراضي البئر أو أراضي مزارع معين عبر عقد `api.list_well_farms`
  Future<List<Farm>> fetchFarms(
    String wellId, {
    String? farmerAccountId,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    final response = await client.schema('api').rpc(
      'list_well_farms',
      params: {
        'p_well_id': wellId,
        'p_farmer_well_account_id':
            (farmerAccountId != null && farmerAccountId.isNotEmpty) ? farmerAccountId : null,
      },
    );

    return _contractItems(response).map(Farm.fromJson).toList();
  }

  /// جلب مضخات البئر عبر عقد `api.list_well_pumps`
  Future<List<Pump>> fetchPumps(String wellId) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    final response = await client.schema('api').rpc(
      'list_well_pumps',
      params: {'p_well_id': wellId},
    );

    return _contractItems(response).map(Pump.fromJson).toList();
  }

  /// إنشاء مزارع جديد في البئر ذرياً (api.create_farmer - ق-80 / ق-84)
  Future<FarmerAccount> createFarmer({
    required String wellId,
    required String fullName,
    String? phone,
    String? notes,
  }) async {
    final cleanPhone = phone != null && phone.trim().isNotEmpty
        ? normalizeArabicDigits(phone).trim()
        : null;

    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    final result = await client.schema('api').rpc(
      'create_farmer',
      params: {
        'p_well_id': wellId,
        'p_full_name': fullName.trim(),
        'p_phone': cleanPhone,
        'p_notes': notes,
      },
    );

    final resMap = result is Map<String, dynamic> ? result : <String, dynamic>{};
    final accountId = resMap['farmer_well_account_id'] as String? ?? '';
    if (accountId.isEmpty) {
      throw StateError('عقد create_farmer لم يُعِد معرّف حساب المزارع');
    }

    return FarmerAccount(
      id: accountId,
      fullName: fullName.trim(),
      publicCode: resMap['public_code'] as String? ?? '',
      phone: cleanPhone,
    );
  }

  /// إنشاء أرض زراعية جديدة وربطها بالمزارع (api.create_farm - ق-80)
  Future<Farm> createFarm({
    required String wellId,
    required String name,
    required String farmerAccountId,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    final result = await client.schema('api').rpc(
      'create_farm',
      params: {
        'p_well_id': wellId,
        'p_name': name.trim(),
        'p_farmer_well_account_id': farmerAccountId,
      },
    );

    final resMap = result is Map<String, dynamic> ? result : <String, dynamic>{};
    final farmId = resMap['farm_id'] as String? ?? '';
    if (farmId.isEmpty) {
      throw StateError('عقد create_farm لم يُعِد معرّف الأرض');
    }

    return Farm(
      id: farmId,
      wellId: wellId,
      name: name.trim(),
      farmerAccountId: farmerAccountId,
    );
  }

  /// بدء جلسة سقي جديدة (api.start_irrigation_session - ق-114)
  ///
  /// كتابات الجلسة الخمس (بدء/إيقاف/استئناف/تغيير طاقة/إنهاء) ترفض العمل
  /// بلا عميل. العودة بنجاح صامت — أو بمعرّف جلسة مُلفَّق — كانت تُظهر
  /// للمشغّل جلسة لا وجود لها في القاعدة (ق-113 / م-41D4).
  Future<String> startIrrigationSession({
    required String wellId,
    required String pumpId,
    required String farmId,
    required String farmerAccountId,
    required String energySource,
    String? commandId,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    final result = await client.schema('api').rpc(
      'start_irrigation_session',
      params: {
        'p_well_id': wellId,
        'p_pump_id': pumpId,
        'p_farm_id': farmId,
        'p_farmer_well_account_id': farmerAccountId,
        'p_energy_source': energySource,
        if (commandId != null) ...{'p_command_id': commandId},
      },
    );

    return result.toString();
  }

  /// إيقاف الجلسة مؤقتاً (api.pause_irrigation_session)
  Future<void> pauseIrrigationSession({
    required String sessionId,
    required String reason,
    String? commandId,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    await client.schema('api').rpc(
      'pause_irrigation_session',
      params: {
        'p_session_id': sessionId,
        'p_reason': reason,
        if (commandId != null) ...{'p_command_id': commandId},
      },
    );
  }

  /// استئناف الجلسة (api.resume_irrigation_session)
  Future<void> resumeIrrigationSession({
    required String sessionId,
    String? commandId,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    await client.schema('api').rpc(
      'resume_irrigation_session',
      params: {
        'p_session_id': sessionId,
        if (commandId != null) ...{'p_command_id': commandId},
      },
    );
  }

  /// تغيير مصدر الطاقة أثناء السقي (api.change_session_energy_source)
  Future<void> changeEnergySource({
    required String sessionId,
    required String newEnergySource,
    String? commandId,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    await client.schema('api').rpc(
      'change_session_energy_source',
      params: {
        'p_session_id': sessionId,
        'p_new_energy_source': newEnergySource,
        if (commandId != null) ...{'p_command_id': commandId},
      },
    );
  }

  /// إنهاء جلسة السقي وإصدار الفاتورة والمستحق (api.complete_irrigation_session)
  Future<Map<String, dynamic>> completeIrrigationSession({
    required String sessionId,
    String? commandId,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      // فاتورة مُلفَّقة (10500) كانت تُطبع للمزارع كأنها محسوبة في القاعدة.
      throw StateError('Supabase client is unavailable');
    }

    final result = await client.schema('api').rpc(
      'complete_irrigation_session',
      params: {
        'p_session_id': sessionId,
        if (commandId != null) ...{'p_command_id': commandId},
      },
    );

    if (result is Map<String, dynamic>) {
      return result;
    }
    return {'raw': result};
  }

  /// حدود النافذة الزمنية للمرشّح بالتوقيت المحلي للجهاز.
  ///
  /// عقد حدود اليوم على الخادم ما زال مفتوحًا (لا منطقة زمنية محسومة في
  /// القاعدة)، فالنافذة تُحسب هنا صراحةً وتُرسل كوسيطين للعقد بدل أن
  /// يفترض الخادم منطقة زمنية أو يفلتر العميل بعد الجلب.
  static (DateTime?, DateTime?) historyWindow(String? filter, {DateTime? now}) {
    final ref = now ?? DateTime.now();
    switch (filter) {
      case 'today':
        final start = DateTime(ref.year, ref.month, ref.day);
        return (start, start.add(const Duration(days: 1)));
      case 'week':
        return (ref.subtract(const Duration(days: 7)), null);
      case 'month':
        return (ref.subtract(const Duration(days: 30)), null);
      default:
        return (null, null);
    }
  }

  /// جلب سجل جلسات السقي للبئر عبر عقد `api.list_well_sessions`
  /// (م-41C2 / ق-98). لا بيانات تجريبية ولا فلترة مالية محلية: المبالغ
  /// وحالة السداد تصل محسومة من القاعدة، والفشل يصل إلى الشاشة صريحًا.
  Future<List<SessionHistoryItem>> fetchSessionHistory({
    required String wellId,
    String? farmerAccountId,
    String? filter, // 'all', 'today', 'week', 'month', 'unpaid'
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    final (from, to) = historyWindow(filter);

    final response = await client.schema('api').rpc(
      'list_well_sessions',
      params: {
        'p_well_id': wellId,
        'p_farmer_well_account_id':
            (farmerAccountId != null && farmerAccountId.isNotEmpty)
                ? farmerAccountId
                : null,
        'p_from': from?.toUtc().toIso8601String(),
        'p_to': to?.toUtc().toIso8601String(),
        'p_unpaid_only': filter == 'unpaid',
      },
    );

    return _contractItems(response)
        .map(SessionHistoryItem.fromContract)
        .toList();
  }

  /// جلب تفصيل الجلسة ومقاطعها عبر عقد `api.get_session_detail`
  /// (م-41C2). المقاطع تُقرأ بأعمدتها الحقيقية: `sequence_number` و
  /// `actual_seconds` و`billable_seconds` والمبالغ المخزّنة — لا حساب
  /// محلي ولا تخمين لتسعيرة مفقودة.
  Future<SessionDetailData> fetchSessionDetail(String sessionId) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    final response = await client.schema('api').rpc(
      'get_session_detail',
      params: {'p_session_id': sessionId},
    );

    if (response is! Map) {
      throw StateError('استجابة عقد تفصيل الجلسة غير متوقعة');
    }

    final sessionJson = response['session'];
    if (sessionJson is! Map) {
      throw StateError('عقد تفصيل الجلسة لم يُعِد بيانات الجلسة');
    }

    final segments = (response['segments'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => SessionSegmentItem.fromContract(Map<String, dynamic>.from(e)))
        .toList();

    final paymentJson = response['payment'];
    final payment = paymentJson is Map
        ? Map<String, dynamic>.from(paymentJson)
        : const <String, dynamic>{};

    return SessionDetailData(
      session: SessionHistoryItem.fromContract(
        Map<String, dynamic>.from(sessionJson),
      ),
      segments: segments,
      paymentMethod: payment['method'] as String?,
      paymentReference: payment['reference'] as String?,
      paidAt: payment['paid_at'] != null
          ? DateTime.tryParse(payment['paid_at'] as String)?.toLocal()
          : null,
    );
  }

  /// جلب الملف الشخصي الكامل للمزارع وأراضيه وكشف حسابه (UX-13 / 380)
  Future<FarmerDetailData> fetchFarmerDetail({
    required String wellId,
    required String farmerAccountId,
  }) async {
    final farmers = await fetchFarmers(wellId);
    final account = farmers.firstWhere(
      (f) => f.id == farmerAccountId,
      orElse: () => throw StateError('حساب المزارع غير موجود في هذا البئر'),
    );

    final farms = await fetchFarms(wellId, farmerAccountId: farmerAccountId);
    final sessions = await fetchSessionHistory(wellId: wellId, farmerAccountId: farmerAccountId);

    int billed = 0;
    int paid = 0;
    for (final s in sessions) {
      billed += s.totalAmountYER;
      paid += s.paidAmountYER;
    }

    return FarmerDetailData(
      account: account,
      farms: farms,
      totalSessionsCount: sessions.length,
      totalBilledYER: billed,
      totalPaidYER: paid,
      netBalanceYER: billed - paid,
      recentSessions: sessions,
    );
  }
}

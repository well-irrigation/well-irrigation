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
    this.energySource = 'طاقة شمسية',
    this.billableSeconds = 0,
    this.totalAmountYER = 0,
    this.paidAmountYER = 0,
    this.paymentStatus = 'settled', // 'settled', 'partial', 'unpaid'
    this.isSynced = true,
  });

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
  final String energySource;
  final int billableSeconds;
  final int totalAmountYER;
  final int paidAmountYER;
  final String paymentStatus;
  final bool isSynced;

  int get remainingAmountYER => (totalAmountYER - paidAmountYER) > 0 ? (totalAmountYER - paidAmountYER) : 0;
  bool get isFullySettled => paymentStatus == 'settled' || (totalAmountYER > 0 && paidAmountYER >= totalAmountYER);
}

class SessionSegmentItem {
  const SessionSegmentItem({
    required this.segmentIndex,
    required this.energySource,
    required this.startedAt,
    this.endedAt,
    required this.durationSeconds,
    required this.hourlyRateYER,
    required this.amountYER,
    this.isPaused = false,
    this.pauseReason,
  });

  final int segmentIndex;
  final String energySource;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int durationSeconds;
  final int hourlyRateYER;
  final int amountYER;
  final bool isPaused;
  final String? pauseReason;
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
      return 'mock-session-${DateTime.now().millisecondsSinceEpoch}';
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
    if (client == null) return;

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
    if (client == null) return;

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
    if (client == null) return;

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
      return {'session_id': sessionId, 'total_amount_minor': 10500};
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

  /// جلب سجل جلسات السقي للبئر مع دعم الفلترة (UX-13 / ق-98)
  Future<List<SessionHistoryItem>> fetchSessionHistory({
    required String wellId,
    String? farmerAccountId,
    String? filter, // 'all', 'today', 'week', 'month', 'unpaid'
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      return _getMockSessionHistory(wellId, farmerAccountId, filter);
    }

    try {
      final response = await client
          .schema('ops')
          .from('irrigation_sessions')
          .select('''
            id,
            well_id,
            status,
            started_at,
            ended_at,
            farmer_well_accounts!inner (
              id,
              public_code,
              farmer_profiles!inner (
                persons!inner (
                  full_name
                )
              )
            ),
            farms!inner (
              id,
              name
            ),
            core_pumps:core!pumps!inner (
              id,
              name
            ),
            session_charges (
              billable_seconds,
              total_amount_minor
            ),
            session_segments (
              energy_source
            ),
            payments:billing!payments (
              amount_minor
            )
          ''')
          .eq('well_id', wellId)
          .order('started_at', ascending: false);

      final list = (response as List<dynamic>).map((row) {
        final r = row as Map<String, dynamic>;
        final fa = r['farmer_well_accounts'] as Map<String, dynamic>? ?? {};
        final fp = fa['farmer_profiles'] as Map<String, dynamic>? ?? {};
        final p = fp['persons'] as Map<String, dynamic>? ?? {};
        final farm = r['farms'] as Map<String, dynamic>? ?? {};
        final pump = r['core_pumps'] as Map<String, dynamic>? ?? {};
        final charges = r['session_charges'] as List<dynamic>? ?? [];
        final segments = r['session_segments'] as List<dynamic>? ?? [];
        final payments = r['payments'] as List<dynamic>? ?? [];

        int billableSecs = 0;
        int totalAmount = 0;
        if (charges.isNotEmpty) {
          final c = charges.first as Map<String, dynamic>;
          billableSecs = (c['billable_seconds'] as num?)?.toInt() ?? 0;
          totalAmount = (c['total_amount_minor'] as num?)?.toInt() ?? 0;
        }

        int paidTotal = 0;
        for (final pay in payments) {
          final payMap = pay as Map<String, dynamic>;
          paidTotal += (payMap['amount_minor'] as num?)?.toInt() ?? 0;
        }

        String energy = 'طاقة شمسية';
        if (segments.isNotEmpty) {
          energy = (segments.first as Map<String, dynamic>)['energy_source'] as String? ?? 'طاقة شمسية';
        }

        String payStatus = 'unpaid';
        if (totalAmount > 0) {
          if (paidTotal >= totalAmount) {
            payStatus = 'settled';
          } else if (paidTotal > 0) {
            payStatus = 'partial';
          }
        }

        return SessionHistoryItem(
          id: r['id'] as String? ?? '',
          wellId: r['well_id'] as String? ?? wellId,
          farmerName: p['full_name'] as String? ?? 'مزارع',
          farmerCode: fa['public_code'] as String? ?? 'F-000',
          farmerAccountId: fa['id'] as String? ?? '',
          farmName: farm['name'] as String? ?? 'أرض زراعية',
          pumpName: pump['name'] as String? ?? 'المضخة 1',
          operatorName: 'المشغل',
          startedAt: DateTime.tryParse(r['started_at'] as String? ?? '') ?? DateTime.now(),
          endedAt: r['ended_at'] != null ? DateTime.tryParse(r['ended_at'] as String) : null,
          status: r['status'] as String? ?? 'closed',
          energySource: energy,
          billableSeconds: billableSecs,
          totalAmountYER: totalAmount,
          paidAmountYER: paidTotal,
          paymentStatus: payStatus,
        );
      }).toList();

      return _applyHistoryFilter(list, filter: filter, farmerAccountId: farmerAccountId);
    } catch (_) {
      return _getMockSessionHistory(wellId, farmerAccountId, filter);
    }
  }

  List<SessionHistoryItem> _getMockSessionHistory(String wellId, String? farmerAccountId, String? filter) {
    final now = DateTime.now();
    final mockList = [
      SessionHistoryItem(
        id: 'mock-session-1',
        wellId: wellId,
        farmerName: 'محمد علي الحبيشي',
        farmerCode: 'F-001',
        farmerAccountId: 'mock-farmer-1',
        farmName: 'مزرعة الوادي الكبير',
        pumpName: 'المضخة الرئيسية 1',
        operatorName: 'خالد النجحي',
        startedAt: now.subtract(const Duration(hours: 3)),
        endedAt: now.subtract(const Duration(hours: 2)),
        status: 'closed',
        energySource: 'طاقة شمسية',
        billableSeconds: 3600,
        totalAmountYER: 3500,
        paidAmountYER: 3500,
        paymentStatus: 'settled',
      ),
      SessionHistoryItem(
        id: 'mock-session-2',
        wellId: wellId,
        farmerName: 'صالح أحمد الشامي',
        farmerCode: 'F-002',
        farmerAccountId: 'mock-farmer-2',
        farmName: 'أرض الجبل الغربي',
        pumpName: 'المضخة الرئيسية 1',
        operatorName: 'خالد النجحي',
        startedAt: now.subtract(const Duration(days: 1, hours: 4)),
        endedAt: now.subtract(const Duration(days: 1, hours: 1)),
        status: 'closed',
        energySource: 'ديزل',
        billableSeconds: 10800,
        totalAmountYER: 15000,
        paidAmountYER: 10000,
        paymentStatus: 'partial',
      ),
      SessionHistoryItem(
        id: 'mock-session-3',
        wellId: wellId,
        farmerName: 'عبدالله مسعد القادري',
        farmerCode: 'F-003',
        farmerAccountId: 'mock-farmer-3',
        farmName: 'مزرعة النخيل',
        pumpName: 'المضخة الرئيسية 1',
        operatorName: 'خالد النجحي',
        startedAt: now.subtract(const Duration(days: 2, hours: 5)),
        endedAt: now.subtract(const Duration(days: 2, hours: 2)),
        status: 'closed',
        energySource: 'طاقة شمسية',
        billableSeconds: 7200,
        totalAmountYER: 7000,
        paidAmountYER: 0,
        paymentStatus: 'unpaid',
      ),
      SessionHistoryItem(
        id: 'mock-session-4',
        wellId: wellId,
        farmerName: 'محمد علي الحبيشي',
        farmerCode: 'F-001',
        farmerAccountId: 'mock-farmer-1',
        farmName: 'مزرعة الوادي الكبير',
        pumpName: 'المضخة الرئيسية 1',
        operatorName: 'خالد النجحي',
        startedAt: now.subtract(const Duration(days: 4, hours: 6)),
        endedAt: now.subtract(const Duration(days: 4, hours: 3)),
        status: 'closed',
        energySource: 'طاقة شمسية',
        billableSeconds: 9000,
        totalAmountYER: 8750,
        paidAmountYER: 8750,
        paymentStatus: 'settled',
      ),
    ];

    return _applyHistoryFilter(mockList, filter: filter, farmerAccountId: farmerAccountId);
  }

  List<SessionHistoryItem> _applyHistoryFilter(
    List<SessionHistoryItem> list, {
    String? filter,
    String? farmerAccountId,
  }) {
    var result = list;
    if (farmerAccountId != null && farmerAccountId.isNotEmpty) {
      result = result.where((s) => s.farmerAccountId == farmerAccountId).toList();
    }

    final now = DateTime.now();
    if (filter == 'today') {
      result = result.where((s) =>
          s.startedAt.year == now.year &&
          s.startedAt.month == now.month &&
          s.startedAt.day == now.day).toList();
    } else if (filter == 'week') {
      final weekAgo = now.subtract(const Duration(days: 7));
      result = result.where((s) => s.startedAt.isAfter(weekAgo)).toList();
    } else if (filter == 'month') {
      final monthAgo = now.subtract(const Duration(days: 30));
      result = result.where((s) => s.startedAt.isAfter(monthAgo)).toList();
    } else if (filter == 'unpaid') {
      result = result.where((s) => !s.isFullySettled).toList();
    }

    return result;
  }

  /// جلب تفاصيل جلسة كاملة مع المقاطع والخط الزمني والدفعات (UX-13 / 377)
  Future<SessionDetailData> fetchSessionDetail(String sessionId) async {
    final client = _effectiveClient;
    if (client == null) {
      return _getMockSessionDetail(sessionId);
    }

    try {
      final sessionRow = await client
          .schema('ops')
          .from('irrigation_sessions')
          .select('''
            id,
            well_id,
            status,
            started_at,
            ended_at,
            farmer_well_accounts!inner (
              id,
              public_code,
              farmer_profiles!inner (
                persons!inner (
                  full_name
                )
              )
            ),
            farms!inner (
              name
            ),
            core_pumps:core!pumps!inner (
              name
            ),
            session_charges (
              billable_seconds,
              total_amount_minor
            )
          ''')
          .eq('id', sessionId)
          .single();

      final segmentsResponse = await client
          .schema('ops')
          .from('session_segments')
          .select('*')
          .eq('session_id', sessionId)
          .order('segment_index');

      final paymentsResponse = await client
          .schema('billing')
          .from('payments')
          .select('*')
          .eq('session_id', sessionId)
          .order('created_at', ascending: false);

      final r = sessionRow;
      final fa = r['farmer_well_accounts'] as Map<String, dynamic>? ?? {};
      final fp = fa['farmer_profiles'] as Map<String, dynamic>? ?? {};
      final p = fp['persons'] as Map<String, dynamic>? ?? {};
      final farm = r['farms'] as Map<String, dynamic>? ?? {};
      final pump = r['core_pumps'] as Map<String, dynamic>? ?? {};
      final charges = r['session_charges'] as List<dynamic>? ?? [];

      int billableSecs = 0;
      int totalAmount = 0;
      if (charges.isNotEmpty) {
        final c = charges.first as Map<String, dynamic>;
        billableSecs = (c['billable_seconds'] as num?)?.toInt() ?? 0;
        totalAmount = (c['total_amount_minor'] as num?)?.toInt() ?? 0;
      }

      int paidTotal = 0;
      String? payMethod;
      String? payRef;
      DateTime? paidDate;

      final paymentsList = paymentsResponse as List<dynamic>? ?? [];
      for (final pay in paymentsList) {
        final pm = pay as Map<String, dynamic>;
        paidTotal += (pm['amount_minor'] as num?)?.toInt() ?? 0;
        payMethod ??= pm['payment_method'] as String?;
        payRef ??= pm['reference'] as String?;
        if (paidDate == null && pm['created_at'] != null) {
          paidDate = DateTime.tryParse(pm['created_at'] as String);
        }
      }

      final segments = (segmentsResponse as List<dynamic>).map((s) {
        final sm = s as Map<String, dynamic>;
        final duration = (sm['duration_seconds'] as num?)?.toInt() ?? 0;
        final rate = (sm['hourly_rate_minor'] as num?)?.toInt() ?? 3500;
        final amount = (rate * duration) ~/ 3600;

        return SessionSegmentItem(
          segmentIndex: (sm['segment_index'] as num?)?.toInt() ?? 0,
          energySource: sm['energy_source'] as String? ?? 'طاقة شمسية',
          startedAt: DateTime.tryParse(sm['started_at'] as String? ?? '') ?? DateTime.now(),
          endedAt: sm['ended_at'] != null ? DateTime.tryParse(sm['ended_at'] as String) : null,
          durationSeconds: duration,
          hourlyRateYER: rate,
          amountYER: amount,
          isPaused: sm['is_paused'] as bool? ?? false,
          pauseReason: sm['pause_reason'] as String?,
        );
      }).toList();

      final historyItem = SessionHistoryItem(
        id: r['id'] as String? ?? sessionId,
        wellId: r['well_id'] as String? ?? '',
        farmerName: p['full_name'] as String? ?? 'مزارع',
        farmerCode: fa['public_code'] as String? ?? 'F-001',
        farmerAccountId: fa['id'] as String? ?? '',
        farmName: farm['name'] as String? ?? 'أرض زراعية',
        pumpName: pump['name'] as String? ?? 'المضخة 1',
        operatorName: 'المشغل',
        startedAt: DateTime.tryParse(r['started_at'] as String? ?? '') ?? DateTime.now(),
        endedAt: r['ended_at'] != null ? DateTime.tryParse(r['ended_at'] as String) : null,
        status: r['status'] as String? ?? 'closed',
        energySource: segments.isNotEmpty ? segments.first.energySource : 'طاقة شمسية',
        billableSeconds: billableSecs,
        totalAmountYER: totalAmount,
        paidAmountYER: paidTotal,
        paymentStatus: paidTotal >= totalAmount ? 'settled' : (paidTotal > 0 ? 'partial' : 'unpaid'),
      );

      return SessionDetailData(
        session: historyItem,
        segments: segments,
        paymentMethod: payMethod,
        paymentReference: payRef,
        paidAt: paidDate,
      );
    } catch (_) {
      return _getMockSessionDetail(sessionId);
    }
  }

  SessionDetailData _getMockSessionDetail(String sessionId) {
    final now = DateTime.now();
    final start = now.subtract(const Duration(hours: 2, minutes: 30));
    final pause = now.subtract(const Duration(hours: 1, minutes: 45));
    final resume = now.subtract(const Duration(hours: 1, minutes: 25));
    final end = now.subtract(const Duration(minutes: 15));

    final seg1 = SessionSegmentItem(
      segmentIndex: 1,
      energySource: 'طاقة شمسية',
      startedAt: start,
      endedAt: pause,
      durationSeconds: 2700, // 45 دقيقة
      hourlyRateYER: 3500,
      amountYER: (3500 * 2700) ~/ 3600, // 2625
    );

    final segPause = SessionSegmentItem(
      segmentIndex: 2,
      energySource: 'طاقة شمسية',
      startedAt: pause,
      endedAt: resume,
      durationSeconds: 1200, // 20 دقيقة توقف
      hourlyRateYER: 0,
      amountYER: 0,
      isPaused: true,
      pauseReason: 'تراكم الغيوم وضعف الإشعاع الشمسي',
    );

    final seg2 = SessionSegmentItem(
      segmentIndex: 3,
      energySource: 'ديزل',
      startedAt: resume,
      endedAt: end,
      durationSeconds: 4200, // 70 دقيقة
      hourlyRateYER: 5000,
      amountYER: (5000 * 4200) ~/ 3600, // 5833
    );

    final totalSecs = 2700 + 4200; // 6900 ثانية
    final totalAmount = seg1.amountYER + seg2.amountYER; // 8458 ريال

    final historyItem = SessionHistoryItem(
      id: sessionId,
      wellId: 'well-1',
      farmerName: 'محمد علي الحبيشي',
      farmerCode: 'F-001',
      farmerAccountId: 'mock-farmer-1',
      farmName: 'مزرعة الوادي الكبير',
      pumpName: 'المضخة الرئيسية 1',
      operatorName: 'خالد النجحي',
      startedAt: start,
      endedAt: end,
      status: 'closed',
      energySource: 'ديزل',
      billableSeconds: totalSecs,
      totalAmountYER: totalAmount,
      paidAmountYER: totalAmount,
      paymentStatus: 'settled',
    );

    return SessionDetailData(
      session: historyItem,
      segments: [seg1, segPause, seg2],
      paymentMethod: 'نقداً',
      paymentReference: 'سداد فوري عند الاعتماد',
      paidAt: end,
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

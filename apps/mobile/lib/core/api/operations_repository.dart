import 'package:supabase_flutter/supabase_flutter.dart';

import '../sync/command_reference.dart';
import '../sync/entity_reference.dart';
import '../utils/digit_utils.dart';

/// نماذج وبيانات التشغيل الميداني وسجل الجلسات (UX-07 / UX-08 / UX-13 / ق-80 / ق-84 / ق-98 / ق-114)

class FarmerAccount {
  const FarmerAccount({
    required this.id,
    required this.fullName,
    required this.publicCode,
    this.phone,
    this.status = 'active',
    this.reference,
  });

  factory FarmerAccount.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    return FarmerAccount(
      id: id,
      fullName: json['full_name'] as String? ?? '',
      publicCode: json['public_code'] as String? ?? '',
      phone: json['phone'] as String?,
      status: json['status'] as String? ?? 'active',
      reference: id.isNotEmpty ? ServerEntityReference(id) : null,
    );
  }

  factory FarmerAccount.pending({
    required CommandReference reference,
    required String fullName,
    String? phone,
  }) {
    return FarmerAccount(
      id: '',
      fullName: fullName,
      publicCode: 'قيد الحفظ',
      phone: phone,
      status: 'pending',
      reference: PendingLocalEntityReference(reference),
    );
  }

  final String id; // farmer_well_account_id
  final String fullName;
  final String publicCode;
  final String? phone;
  final String status;
  final EntityReference? reference;

  bool get isPending =>
      reference?.isPending ?? (status == 'pending' || id.isEmpty);

  EntityReference get entityReference =>
      reference ??
      (id.isNotEmpty
          ? ServerEntityReference(id)
          : throw StateError('حساب المزارع ليس له مرجع صالح'));
}

/// سطر في دليل المزارعين كما يعيده عقد 099: الهوية والأراضي والمال وآخر سقي.
///
/// كل رقم هنا **من الخادم**: عدد الأراضي، والمبالغ من عرض الأرصدة، وتاريخ آخر
/// جلسة منتهية. ولا يُحسب شيء في العميل (ق-99). و`lastSessionDay` هو اليوم
/// بمنطقة الجهة كما حسبه الخادم — فلا يختلف «آخر سقي» باختلاف منطقة الجهاز.
class FarmerDirectoryEntry {
  const FarmerDirectoryEntry({
    required this.id,
    required this.fullName,
    required this.publicCode,
    required this.status,
    required this.farmsCount,
    required this.debtYER,
    required this.advanceYER,
    required this.sessionsCount,
    required this.hasOpenSession,
    this.phone,
    this.lastSessionAt,
    this.lastSessionDay,
  });

  factory FarmerDirectoryEntry.fromJson(Map<String, dynamic> json) {
    String requiredText(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw StateError('دليل المزارعين أعاد حقلًا نصيًا غير صالح: $key');
      }
      return value;
    }

    int requiredInt(String key) {
      final value = json[key];
      final parsed = value is num
          ? value.toInt()
          : int.tryParse(value?.toString() ?? '');
      if (parsed == null || parsed < 0) {
        throw StateError('دليل المزارعين أعاد رقمًا غير صالح: $key');
      }
      return parsed;
    }

    DateTime? optionalTime(String key) {
      final value = json[key];
      if (value == null) return null;
      final parsed = DateTime.tryParse(value.toString());
      if (parsed == null) {
        throw StateError('دليل المزارعين أعاد تاريخًا غير صالح: $key');
      }
      return parsed;
    }

    final openSession = json['has_open_session'];
    if (openSession is! bool) {
      throw StateError('دليل المزارعين لم يُعِد حالة الجلسة الجارية');
    }

    return FarmerDirectoryEntry(
      id: requiredText('id'),
      fullName: requiredText('full_name'),
      publicCode: requiredText('public_code'),
      status: requiredText('status'),
      phone: json['phone'] as String?,
      farmsCount: requiredInt('farms_count'),
      debtYER: requiredInt('debt_minor'),
      advanceYER: requiredInt('advance_minor'),
      sessionsCount: requiredInt('sessions_count'),
      hasOpenSession: openSession,
      lastSessionAt: optionalTime('last_session_at'),
      lastSessionDay: optionalTime('last_session_day'),
    );
  }

  final String id;
  final String fullName;
  final String publicCode;
  final String status;
  final String? phone;
  final int farmsCount;
  final int debtYER;
  final int advanceYER;
  final int sessionsCount;
  final bool hasOpenSession;
  final DateTime? lastSessionAt;
  final DateTime? lastSessionDay;

  bool get hasDebt => debtYER > 0;
  bool get hasNeverIrrigated => lastSessionAt == null && !hasOpenSession;
}

class FarmerDirectoryData {
  const FarmerDirectoryData({required this.entries, required this.currentDay});

  factory FarmerDirectoryData.fromContract(dynamic response) {
    if (response is! Map) {
      throw StateError('استجابة دليل المزارعين غير متوقعة');
    }
    if (response['contract'] != 'list_well_farmer_directory' ||
        response['version'] != 1) {
      throw StateError('إصدار عقد دليل المزارعين غير متوافق');
    }

    final items = response['items'];
    if (items is! List) {
      throw StateError('دليل المزارعين لم يُعِد قائمة عناصر');
    }

    final currentDay = DateTime.tryParse(
      response['current_day']?.toString() ?? '',
    );
    if (currentDay == null) {
      throw StateError('دليل المزارعين لم يُعِد يوم البئر الحالي');
    }

    return FarmerDirectoryData(
      entries: items
          .map((item) {
            if (item is! Map) {
              throw StateError('دليل المزارعين أعاد عنصرًا غير صالح');
            }
            return FarmerDirectoryEntry.fromJson(
              Map<String, dynamic>.from(item),
            );
          })
          .toList(growable: false),
      currentDay: currentDay,
    );
  }

  final List<FarmerDirectoryEntry> entries;

  /// اليوم الحالي بمنطقة الجهة كما يعيده عقد 099.
  final DateTime currentDay;
}

class Farm {
  const Farm({
    required this.id,
    required this.wellId,
    required this.name,
    this.distinguishingLabel,
    this.farmerAccountId,
    this.farmerReference,
    this.status = 'active',
    this.reference,
  });

  factory Farm.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    final fId = json['farmer_well_account_id'] as String?;
    return Farm(
      id: id,
      wellId: json['well_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      distinguishingLabel: json['distinguishing_label'] as String?,
      farmerAccountId: fId,
      farmerReference: fId != null && fId.isNotEmpty
          ? ServerEntityReference(fId)
          : null,
      status: json['status'] as String? ?? 'active',
      reference: id.isNotEmpty ? ServerEntityReference(id) : null,
    );
  }

  factory Farm.pending({
    required CommandReference reference,
    required String wellId,
    required String name,
    String? distinguishingLabel,
    required EntityReference farmerReference,
  }) {
    return Farm(
      id: '',
      wellId: wellId,
      name: name,
      distinguishingLabel: distinguishingLabel,
      farmerAccountId: farmerReference.serverId,
      farmerReference: farmerReference,
      status: 'pending',
      reference: PendingLocalEntityReference(reference),
    );
  }

  final String id; // farm_id
  final String wellId;
  final String name;
  final String? distinguishingLabel;
  final String? farmerAccountId;
  final EntityReference? farmerReference;
  final String status;
  final EntityReference? reference;

  bool get isPending =>
      reference?.isPending ?? (status == 'pending' || id.isEmpty);

  EntityReference get entityReference =>
      reference ??
      (id.isNotEmpty
          ? ServerEntityReference(id)
          : throw StateError('الأرض ليس لها مرجع صالح'));

  /// الاسم المعروض للأرض: إذا وُجدت صفة مميزة يُعرض "الاسم — الصفة"،
  /// مع بقاء [name] و[distinguishingLabel] مستقلين في الكيان وقاعدة البيانات.
  String get displayName =>
      (distinguishingLabel != null && distinguishingLabel!.trim().isNotEmpty)
      ? '$name — ${distinguishingLabel!.trim()}'
      : name;
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

/// مصادر الطاقة الثلاثة التي تقبلها القاعدة في `p_energy_source`
/// (هجرة 066، `ops.create_priced_session_segment`).
///
/// اختيار المصدر قرار تشغيلي لا تسعيري (م-41D6): صلاحية `session.start`
/// يملكها المشغل والمدير، أما `price.manage` فللمالك وحده — فلو بُنيت
/// أزرار المصدر من قواعد السعر لبقي المشغل بلا أزرار ولم يستطع بدء جلسة
/// يقبلها الخادم. الأسعار وحدها تأتي من العقد، والمصدر من هذه القائمة.
const List<String> kSessionEnergySources = [
  'solar',
  'well_diesel',
  'farmer_diesel',
];

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
    this.actualSeconds,
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
      actualSeconds: (json['actual_seconds'] as num?)?.toInt(),
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

  /// مدة التنفيذ الفعلية بالثواني كما يعيدها العقد (ق-131 البند 7):
  /// مجموع `actual_seconds` لمقاطع الجلسة المقفلة بما فيها التوقفات،
  /// ومغلفها المخزَّن للقديمة بلا مقاطع. والجارية بلا مدة نهائية فتبقى
  /// null — لا تلفيق من بيانات الفوترة.
  final int? actualSeconds;

  /// المدة المفوترة بالثواني كما خُزّنت في `billing.session_charges`:
  /// كمية مالية مستقلة لا تُستبدل بالفعلي ولا تُشتق منه (ق-131).
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

  int get remainingAmountYER => (totalAmountYER - paidAmountYER) > 0
      ? (totalAmountYER - paidAmountYER)
      : 0;

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
    this.crops = const [],
    this.paymentMethod,
    this.paymentReference,
    this.paidAt,
  });

  final SessionHistoryItem session;
  final List<SessionSegmentItem> segments;

  /// محاصيل هذه الجلسة كما حُفظت وقت بدئها (ق-131 البند 1) — لقطة
  /// مستقلة لا تتبع الأرض، والجلسات الأقدم من الميزة قائمة فارغة.
  final List<String> crops;
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
    final cleanQuery = query != null
        ? normalizeArabicDigits(query).trim()
        : null;
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    final response = await client
        .schema('api')
        .rpc(
          'list_well_farmers',
          params: {
            'p_well_id': wellId,
            'p_query': (cleanQuery != null && cleanQuery.isNotEmpty)
                ? cleanQuery
                : null,
          },
        );

    return _contractItems(response).map(FarmerAccount.fromJson).toList();
  }

  /// دليل المزارعين الغنيّ — `api.list_well_farmer_directory` (هجرة 099).
  ///
  /// يعيد العناصر ومعها يوم البئر الحالي المحسوب من حدّ منتصف الليل المحلي؛
  /// فلا تقارن الشاشة يوم البئر بيوم الجهاز عند عرض «اليوم/أمس».
  ///
  /// يختلف عن [fetchFarmers] بأنه يعيد عدد الأراضي والأرصدة وآخر سقي،
  /// **ومرتَّبًا من الخادم بآخر سقي**. و[fetchFarmers] يبقى لسياق اختيار
  /// المزارع أثناء بدء جلسة: هناك يُحتاج الاسم والرقم وحدهما، وحمله بأرقام
  /// مالية يوسّع سطح الكشف بلا حاجة.
  ///
  /// والترتيب لا يُعاد في العميل: الخادم يعلن أساسه في `sort` بالحمولة،
  /// وإعادة ترتيبه هنا تجعل شاشتين تعرضان الترتيب نفسه بأساسين مختلفين.
  Future<FarmerDirectoryData> fetchFarmerDirectory(
    String wellId, {
    String? query,
  }) async {
    final cleanQuery = query != null
        ? normalizeArabicDigits(query).trim()
        : null;
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    final response = await client
        .schema('api')
        .rpc(
          'list_well_farmer_directory',
          params: {
            'p_well_id': wellId,
            'p_query': (cleanQuery != null && cleanQuery.isNotEmpty)
                ? cleanQuery
                : null,
          },
        );

    return FarmerDirectoryData.fromContract(response);
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

    final response = await client
        .schema('api')
        .rpc(
          'list_well_farms',
          params: {
            'p_well_id': wellId,
            'p_farmer_well_account_id':
                (farmerAccountId != null && farmerAccountId.isNotEmpty)
                ? farmerAccountId
                : null,
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

    final response = await client
        .schema('api')
        .rpc('list_well_pumps', params: {'p_well_id': wellId});

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

    final result = await client
        .schema('api')
        .rpc(
          'create_farmer',
          params: {
            'p_well_id': wellId,
            'p_full_name': fullName.trim(),
            'p_phone': cleanPhone,
            'p_notes': notes,
          },
        );

    final resMap = result is Map<String, dynamic>
        ? result
        : <String, dynamic>{};
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
    String? distinguishingLabel,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    final result = await client
        .schema('api')
        .rpc(
          'create_farm',
          params: {
            'p_well_id': wellId,
            'p_name': name.trim(),
            'p_farmer_well_account_id': farmerAccountId,
            if (distinguishingLabel != null &&
                distinguishingLabel.trim().isNotEmpty)
              'p_distinguishing_label': distinguishingLabel.trim(),
          },
        );

    final resMap = result is Map<String, dynamic>
        ? result
        : <String, dynamic>{};
    final farmId = resMap['farm_id'] as String? ?? '';
    if (farmId.isEmpty) {
      throw StateError('عقد create_farm لم يُعِد معرّف الأرض');
    }

    return Farm(
      id: farmId,
      wellId: wellId,
      name: name.trim(),
      distinguishingLabel: distinguishingLabel?.trim(),
      farmerAccountId: farmerAccountId,
    );
  }

  /// بدء جلسة سقي جديدة (api.start_irrigation_session - ق-114)
  ///
  /// كتابات الجلسة الخمس (بدء/إيقاف/استئناف/تغيير طاقة/إنهاء) ترفض العمل
  /// بلا عميل. العودة بنجاح صامت — أو بمعرّف جلسة مُلفَّق — كانت تُظهر
  /// للمشغّل جلسة لا وجود لها في القاعدة (ق-113 / م-41D4).
  ///
  /// [crops] محاصيل هذه الجلسة (ق-131 البند 1): لقطة اختيارية تُحفظ مع
  /// الجلسة نفسها على الخادم، والفراغ مسموح ولا يمنع البدء.
  Future<String> startIrrigationSession({
    required String wellId,
    required String pumpId,
    required String farmId,
    required String farmerAccountId,
    required String energySource,
    List<String> crops = const [],
    String? commandId,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    final result = await client
        .schema('api')
        .rpc(
          'start_irrigation_session',
          params: {
            'p_well_id': wellId,
            'p_pump_id': pumpId,
            'p_farm_id': farmId,
            'p_farmer_well_account_id': farmerAccountId,
            'p_energy_source': energySource,
            'p_crops': crops,
            if (commandId != null) ...{'p_command_id': commandId},
          },
        );

    return result.toString();
  }

  /// جلب المحاصيل المستخدمة سابقًا في جلسات الأرض عبر عقد
  /// `api.list_farm_recent_crops` (ق-131 البند 1): الاقتراحات مشتقة من
  /// التاريخ لا من قائمة ثابتة، والفشل يصل إلى الشاشة صريحًا.
  Future<List<String>> fetchFarmRecentCrops({required String farmId}) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    final response = await client
        .schema('api')
        .rpc('list_farm_recent_crops', params: {'p_farm_id': farmId});

    return cropsFromContract(response);
  }

  /// قراءة قائمة المحاصيل من ردّ العقد كما هو: مصفوفة نصوص تحت مفتاح
  /// `crops`، والغائب قائمة فارغة لا اختراع (ق-131 البند 1).
  static List<String> cropsFromContract(Object? response) {
    if (response is! Map) {
      throw StateError('استجابة عقد محاصيل الأرض غير متوقعة');
    }
    return (response['crops'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList();
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

    await client
        .schema('api')
        .rpc(
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

    await client
        .schema('api')
        .rpc(
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

    await client
        .schema('api')
        .rpc(
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

    final result = await client
        .schema('api')
        .rpc(
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

    final response = await client
        .schema('api')
        .rpc(
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

    final response = await client
        .schema('api')
        .rpc('get_session_detail', params: {'p_session_id': sessionId});

    if (response is! Map) {
      throw StateError('استجابة عقد تفصيل الجلسة غير متوقعة');
    }

    final sessionJson = response['session'];
    if (sessionJson is! Map) {
      throw StateError('عقد تفصيل الجلسة لم يُعِد بيانات الجلسة');
    }

    final segments = (response['segments'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map(
          (e) => SessionSegmentItem.fromContract(Map<String, dynamic>.from(e)),
        )
        .toList();

    final paymentJson = response['payment'];
    final payment = paymentJson is Map
        ? Map<String, dynamic>.from(paymentJson)
        : const <String, dynamic>{};

    final crops = cropsFromContract(response);

    return SessionDetailData(
      session: SessionHistoryItem.fromContract(
        Map<String, dynamic>.from(sessionJson),
      ),
      segments: segments,
      crops: crops,
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
    final sessions = await fetchSessionHistory(
      wellId: wellId,
      farmerAccountId: farmerAccountId,
    );

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

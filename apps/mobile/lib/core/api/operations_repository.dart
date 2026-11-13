import 'package:supabase_flutter/supabase_flutter.dart';

import '../sync/command_reference.dart';
import '../sync/entity_reference.dart';
import '../utils/digit_utils.dart';
import 'manual_session_entry_capability.dart';
import 'session_financial_adjustment.dart';

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

/// حالة المزارع لحظة اختياره لجلسة (ق-131 البند 11): ثلاث حقائق يعيدها
/// عقد `api.get_farmer_selection_status` كما خُزّنت — الدين والمقدم من
/// عرض الأرصدة الحاكم (060)، وكمية ديزله بالمللتر من الحركات المرحّلة.
/// معلومة إخبارية غير مانعة: لا تحجب بدء السقي، ولا تُقاص، ولا يُحوَّل
/// الديزل مالًا (ق-131 البند 9)، ولا يُحسب شيء في العميل (ق-99).
class FarmerSelectionStatus {
  const FarmerSelectionStatus({
    required this.farmerWellAccountId,
    required this.wellId,
    required this.debtMinor,
    required this.advanceMinor,
    required this.farmerFuelBalanceMl,
  });

  factory FarmerSelectionStatus.fromContract(Map<String, dynamic> json) {
    if (json['contract'] != 'get_farmer_selection_status' ||
        json['version'] != 1) {
      throw StateError('إصدار عقد حالة المزارع غير متوافق');
    }

    int requiredInt(String key) {
      final value = json[key];
      final parsed = value is num
          ? value.toInt()
          : int.tryParse(value?.toString() ?? '');
      if (parsed == null || parsed < 0) {
        throw StateError('عقد حالة المزارع أعاد رقمًا غير صالح: $key');
      }
      return parsed;
    }

    return FarmerSelectionStatus(
      farmerWellAccountId: json['farmer_well_account_id'] as String? ?? '',
      wellId: json['well_id'] as String? ?? '',
      debtMinor: requiredInt('debt_minor'),
      advanceMinor: requiredInt('advance_minor'),
      farmerFuelBalanceMl: requiredInt('farmer_fuel_balance_ml'),
    );
  }

  final String farmerWellAccountId;
  final String wellId;

  /// المديونية بالريال الكامل كما يحدّها العرض الحاكم (060): صفر حقيقي
  /// يعني لا مديونية، ولا قيمة سالبة تُقرأ هنا.
  final int debtMinor;

  /// رصيد المقدم بالريال الكامل من دفعات advance المرحّلة — مستقل عن
  /// الدين ولا يُعوَّض به تلقائيًا (ق-131 البند 10 لاحق).
  final int advanceMinor;

  /// كمية ديزل المزارع المملوكة **بالمللتر** كما في حركات المخزون —
  /// الوحدة الحاكمة تبقى خامًا في النموذج، والليتر عرضٌ وحده.
  final int farmerFuelBalanceMl;

  bool get hasDebt => debtMinor > 0;
  bool get hasAdvance => advanceMinor > 0;
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

const _sessionCorrectionKeys = [
  'original_started_at',
  'original_ended_at',
  'effective_started_at',
  'effective_ended_at',
  'operational_revision',
  'financial_status',
  'financial_applied_revision',
];

String _readString(Map json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('حقل عقد القراءة غير صالح: $key');
  }
  return value;
}

// يقبل إزاحات ISO الصريحة وكسورها دون ربط التحليل بتوقيت الجهاز.
final _correctionTimestampPattern = RegExp(
  r'^([+-]?\d{4,6})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2}):(\d{2})'
  r'(?:[.,](\d+))?([Zz]|([+-])(\d{2})(?::?(\d{2}))?)$',
);

DateTime? _readTime(Map json, String key, {bool nullable = false}) {
  final value = json[key];
  if (nullable && json.containsKey(key) && value == null) return null;
  FormatException invalid() => FormatException('وقت عقد القراءة غير صالح: $key');
  final match = value is String
      ? _correctionTimestampPattern.firstMatch(value)
      : null;
  if (match == null || match.end != (value as String).length) throw invalid();

  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final hour = int.parse(match[4]!);
  final minute = int.parse(match[5]!);
  final second = int.parse(match[6]!);
  final offsetHour = match[10] == null ? 0 : int.parse(match[10]!);
  final offsetMinute = match[11] == null ? 0 : int.parse(match[11]!);
  if (offsetHour > 23 || offsetMinute > 59) throw invalid();

  // نتحقق من المكونات كما كُتبت قبل تطبيق الإزاحة: DateTime يطبّع
  // تجاوزات اليوم والشهر والوقت، فلا يكفي نجاح parse لإثبات صحتها.
  final DateTime wallTime;
  try {
    wallTime = DateTime.utc(year, month, day, hour, minute, second);
  } on ArgumentError {
    throw invalid();
  }
  if (wallTime.year != year ||
      wallTime.month != month ||
      wallTime.day != day ||
      wallTime.hour != hour ||
      wallTime.minute != minute ||
      wallTime.second != second) {
    throw invalid();
  }
  // التحليل الأصلي يحفظ الإزاحة ودقة الكسور التي يدعمها DateTime.
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw invalid();
  return parsed.toLocal();
}

int? _readRevision(Map json, String key, {bool nullable = false}) {
  final value = json[key];
  if (nullable && json.containsKey(key) && value == null) return null;
  if (value is! int || value < 0) {
    throw FormatException('مراجعة عقد القراءة غير صالحة: $key');
  }
  return value;
}

String _readFinancialStatus(Map json, {bool correction = false}) {
  final value = _readString(json, 'financial_status');
  if (!const {
        'pending',
        'applied',
        'financial_review_required',
      }.contains(value) &&
      (correction || value != 'not_applicable')) {
    throw const FormatException('حالة الأثر المالي غير صالحة');
  }
  return value;
}

Map _readCorrectionEnvelope(Object? raw, String contract, String sessionId) {
  if (raw is! Map ||
      raw['contract'] != contract ||
      raw['version'] is! int ||
      raw['version'] != 1 ||
      raw['session_id'] != sessionId ||
      sessionId.trim().isEmpty) {
    throw const FormatException('غلاف قراءة التصحيح غير صالح');
  }
  return raw;
}

bool _readReviewRequired(Map json, String financialStatus) {
  final value = json['financial_review_required'];
  if (value is! bool ||
      value != (financialStatus == 'financial_review_required')) {
    throw const FormatException('حالة مراجعة المبلغ غير متسقة');
  }
  return value;
}

String? _readReviewReason(Map json) {
  final value = json['financial_review_reason'];
  if (value == null) return null;
  return _readString(json, 'financial_review_reason');
}

class SessionCorrectionHistory {
  SessionCorrectionHistory._(
    this.sessionId,
    Iterable<SessionCorrectionItem> items,
  ) : items = List.unmodifiable(items);

  factory SessionCorrectionHistory.fromContract(
    Object? raw, {
    required String sessionId,
  }) {
    final json = _readCorrectionEnvelope(
      raw,
      'get_session_corrections',
      sessionId,
    );
    final items = json['items'];
    if (items is! List) throw const FormatException('سجل التصحيحات غير صالح');
    return SessionCorrectionHistory._(
      sessionId,
      items.map((item) {
        if (item is! Map) throw const FormatException('عنصر التصحيح غير صالح');
        return SessionCorrectionItem.fromContract(item, sessionId: sessionId);
      }),
    );
  }

  String get contract => 'get_session_corrections';
  int get version => 1;
  final String sessionId;
  final List<SessionCorrectionItem> items;
}

class SessionCorrectionItem {
  const SessionCorrectionItem._({
    required this.correctionId,
    required this.sessionId,
    required this.previousRevision,
    required this.newRevision,
    required this.operationalRevision,
    required this.beforeStartedAt,
    required this.beforeEndedAt,
    required this.afterStartedAt,
    required this.afterEndedAt,
    required this.reason,
    required this.requestedAt,
    required this.acceptedAt,
    required this.financialStatus,
    required this.financialReviewRequired,
    required this.financialReviewReason,
  });

  factory SessionCorrectionItem.fromContract(
    Map json, {
    required String sessionId,
  }) {
    if (json['session_id'] != sessionId) {
      throw const FormatException('جلسة عنصر التصحيح غير مطابقة');
    }
    final previous = _readRevision(json, 'previous_revision')!;
    final next = _readRevision(json, 'new_revision')!;
    final operational = _readRevision(json, 'operational_revision')!;
    if (next != previous + 1 || operational != next) {
      throw const FormatException('مراجعات التصحيح غير متسقة');
    }
    final financial = _readFinancialStatus(json, correction: true);
    return SessionCorrectionItem._(
      correctionId: _readString(json, 'correction_id'),
      sessionId: sessionId,
      previousRevision: previous,
      newRevision: next,
      operationalRevision: operational,
      beforeStartedAt: _readTime(json, 'before_started_at')!,
      beforeEndedAt: _readTime(json, 'before_ended_at')!,
      afterStartedAt: _readTime(json, 'after_started_at')!,
      afterEndedAt: _readTime(json, 'after_ended_at')!,
      reason: _readString(json, 'reason'),
      requestedAt: _readTime(json, 'requested_at')!,
      acceptedAt: _readTime(json, 'accepted_at')!,
      financialStatus: financial,
      financialReviewRequired: _readReviewRequired(json, financial),
      financialReviewReason: _readReviewReason(json),
    );
  }

  final String correctionId, sessionId, reason, financialStatus;
  final int previousRevision, newRevision, operationalRevision;
  final DateTime beforeStartedAt, beforeEndedAt, afterStartedAt, afterEndedAt;
  final DateTime requestedAt, acceptedAt;
  final bool financialReviewRequired;
  final String? financialReviewReason;
}

class SessionCorrectionStatus {
  const SessionCorrectionStatus._({
    required this.sessionId,
    required this.operationalRevision,
    required this.status,
    required this.financialStatus,
    this.correctionId,
    this.financialReviewRequired = false,
    this.financialReviewReason,
  });

  factory SessionCorrectionStatus.fromContract(
    Object? raw, {
    required String sessionId,
  }) {
    final json = _readCorrectionEnvelope(
      raw,
      'get_session_correction_status',
      sessionId,
    );
    final revision = _readRevision(json, 'operational_revision')!;
    final financial = _readFinancialStatus(json, correction: revision > 0);
    final status = _readString(json, 'status');
    if (revision == 0) {
      if (status != 'not_corrected' ||
          financial != 'not_applicable' ||
          json['correction_id'] != null) {
        throw const FormatException('حالة الجلسة غير المصححة غير متسقة');
      }
      return SessionCorrectionStatus._(
        sessionId: sessionId,
        operationalRevision: revision,
        status: status,
        financialStatus: financial,
      );
    }
    if (status != financial) {
      throw const FormatException('حالة التصحيح غير متسقة');
    }
    return SessionCorrectionStatus._(
      sessionId: sessionId,
      operationalRevision: revision,
      status: status,
      financialStatus: financial,
      correctionId: _readString(json, 'correction_id'),
      financialReviewRequired: _readReviewRequired(json, financial),
      financialReviewReason: _readReviewReason(json),
    );
  }

  String get contract => 'get_session_correction_status';
  int get version => 1;
  final String sessionId, status, financialStatus;
  final int operationalRevision;
  final String? correctionId, financialReviewReason;
  final bool financialReviewRequired;
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
    this.farmId,
    this.pumpId,
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
    this.originalStartedAt,
    this.originalEndedAt,
    this.effectiveStartedAt,
    this.effectiveEndedAt,
    this.operationalRevision,
    this.financialStatus,
    this.financialAppliedRevision,
  });

  /// بناء العنصر من عقد `api.list_well_sessions` / `api.get_session_detail`.
  /// الجلسة غير المفوترة تصل بمبالغ null، فتبقى أصفارًا مع `hasCharge=false`
  /// وحالة `not_billed` — لا مبلغ مخترع ولا حالة سداد مصطنعة (ق-99).
  factory SessionHistoryItem.fromContract(
    Map<String, dynamic> json, {
    bool requireCorrectionFacts = false,
  }) {
    final explicit =
        requireCorrectionFacts || _sessionCorrectionKeys.any(json.containsKey);
    final completed =
        json['status'] == 'closed' || json['status'] == 'forgotten';
    final originalStart = explicit
        ? _readTime(json, 'original_started_at')
        : null;
    final originalEnd = explicit
        ? _readTime(json, 'original_ended_at', nullable: !completed)
        : null;
    final effectiveStart = explicit
        ? _readTime(json, 'effective_started_at')
        : null;
    final effectiveEnd = explicit
        ? _readTime(json, 'effective_ended_at', nullable: !completed)
        : null;
    return SessionHistoryItem(
      originalStartedAt: originalStart,
      originalEndedAt: originalEnd,
      effectiveStartedAt: effectiveStart,
      effectiveEndedAt: effectiveEnd,
      operationalRevision: explicit
          ? _readRevision(json, 'operational_revision')
          : null,
      financialStatus: explicit ? _readFinancialStatus(json) : null,
      financialAppliedRevision: explicit
          ? _readRevision(json, 'financial_applied_revision', nullable: true)
          : null,
      id: json['id'] as String? ?? '',
      wellId: json['well_id'] as String? ?? '',
      farmerName: json['farmer_name'] as String? ?? 'غير محدد',
      farmerCode: json['farmer_public_code'] as String? ?? '',
      farmerAccountId: json['farmer_well_account_id'] as String? ?? '',
      farmId: json['farm_id'] as String?,
      pumpId: json['pump_id'] as String?,
      farmName: json['farm_name'] as String? ?? 'غير محددة',
      pumpName: json['pump_name'] as String? ?? 'غير محددة',
      operatorName: json['operator_name'] as String? ?? 'غير محدد',
      startedAt: explicit
          ? effectiveStart!
          : DateTime.tryParse(json['started_at'] as String? ?? '')?.toLocal() ??
                DateTime.now(),
      endedAt: explicit
          ? effectiveEnd
          : json['ended_at'] != null
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

  final String? farmId, pumpId;
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

  /// غياب العقد الصريح في القراءات القديمة يبقى مجهولًا، لا مراجعة صفر مصطنعة.
  final DateTime? originalStartedAt, originalEndedAt;
  final DateTime? effectiveStartedAt, effectiveEndedAt;
  final int? operationalRevision, financialAppliedRevision;
  final String? financialStatus;

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
    this.originalStartedAt,
    this.originalEndedAt,
    this.financialEvidenceBasis,
    this.financialEvidenceRevision,
  });

  /// المقطع كما تعيده القاعدة: أعمدة الثواني والمبالغ المخزّنة، لا حساب محلي.
  factory SessionSegmentItem.fromContract(Map<String, dynamic> json) {
    final explicit = const [
      'original_started_at',
      'original_ended_at',
      'financial_evidence_basis',
      'financial_evidence_revision',
    ].any(json.containsKey);
    final basis = explicit
        ? _readString(json, 'financial_evidence_basis')
        : null;
    if (explicit &&
        basis != 'original_execution' &&
        basis != 'applied_reconciliation') {
      throw const FormatException('مصدر الدليل المالي غير صالح');
    }
    return SessionSegmentItem(
      originalStartedAt: explicit
          ? _readTime(json, 'original_started_at')
          : null,
      originalEndedAt: explicit
          ? _readTime(json, 'original_ended_at', nullable: true)
          : null,
      financialEvidenceBasis: basis,
      financialEvidenceRevision: explicit
          ? _readRevision(json, 'financial_evidence_revision')
          : null,
      sequenceNumber: (json['sequence_number'] as num?)?.toInt() ?? 0,
      segmentType: json['segment_type'] as String? ?? '',
      isStop: json['is_stop'] as bool? ?? false,
      isBillable: json['is_billable'] as bool? ?? false,
      startedAt: explicit
          ? _readTime(json, 'started_at')!
          : DateTime.tryParse(json['started_at'] as String? ?? '')?.toLocal() ??
                DateTime.now(),
      endedAt: explicit
          ? _readTime(json, 'ended_at', nullable: true)
          : json['ended_at'] != null
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
  final DateTime? originalStartedAt, originalEndedAt;
  final String? financialEvidenceBasis;
  final int? financialEvidenceRevision;

  String get energySource => energySourceLabel(energySourceCode);
  String get typeLabel => segmentTypeLabel(segmentType);
}

class SessionDetailData {
  const SessionDetailData({
    required this.session,
    required this.segments,
    required this.canReadSessionCorrections,
    required this.canCorrectSession,
    this.crops = const [],
    this.paymentMethod,
    this.paymentReference,
    this.paidAt,
  });

  final SessionHistoryItem session;
  final List<SessionSegmentItem> segments;
  final bool canReadSessionCorrections;
  final bool canCorrectSession;

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

class OperationsRepository implements ManualSessionEntryCapabilityReader {
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

  /// قراءة جديدة بلا مخبأ؛ تبديل الهوية أثناء الطلب يبطل النتيجة القديمة.
  @override
  Future<ManualSessionEntryCapability> fetchManualSessionEntryCapability({
    required String accountId,
    required String wellId,
  }) async {
    if (accountId.isEmpty || accountId.trim() != accountId ||
        wellId.isEmpty || wellId.trim() != wellId) {
      throw const ManualSessionEntryCapabilityUnavailable(
        ManualSessionEntryCapabilityFailure.malformed,
      );
    }
    final client = _effectiveClient;
    if (client == null) {
      throw const ManualSessionEntryCapabilityUnavailable(
        ManualSessionEntryCapabilityFailure.unavailable,
      );
    }
    bool sameIdentity() {
      final session = client.auth.currentSession;
      return session != null && !session.isExpired && session.user.id == accountId;
    }
    if (!sameIdentity()) {
      throw const ManualSessionEntryCapabilityUnavailable(
        ManualSessionEntryCapabilityFailure.authentication,
      );
    }
    final Object? raw;
    try {
      raw = await client.schema('api').rpc(
        'get_manual_session_entry_capability', params: {'p_well_id': wellId},
      ).timeout(const Duration(seconds: 20));
    } on PostgrestException catch (error) {
      throw ManualSessionEntryCapabilityUnavailable(switch (error.code) {
        '42501' => ManualSessionEntryCapabilityFailure.forbidden,
        '28000' || 'PGRST301' || 'PGRST302' => ManualSessionEntryCapabilityFailure.authentication,
        _ => ManualSessionEntryCapabilityFailure.network,
      });
    } on AuthException {
      throw const ManualSessionEntryCapabilityUnavailable(
        ManualSessionEntryCapabilityFailure.authentication,
      );
    } on FormatException {
      throw const ManualSessionEntryCapabilityUnavailable(
        ManualSessionEntryCapabilityFailure.malformed,
      );
    } on Object {
      throw const ManualSessionEntryCapabilityUnavailable(
        ManualSessionEntryCapabilityFailure.network,
      );
    }
    if (!sameIdentity()) {
      throw const ManualSessionEntryCapabilityUnavailable(
        ManualSessionEntryCapabilityFailure.identityChanged,
      );
    }
    return ManualSessionEntryCapability.fromContract(raw, wellId: wellId);
  }

  Future<SessionFinancialAdjustmentCapability>
  getSessionFinancialAdjustmentCapability({
    required String accountId,
    required String sessionId,
  }) => _readSessionFinancialContract(
    accountId: accountId,
    sessionId: sessionId,
    rpc: 'get_session_financial_adjustment_capability',
    parse: (raw) => SessionFinancialAdjustmentCapability.fromContract(
      raw,
      sessionId: sessionId,
    ),
  );

  Future<SessionFinancialState> getSessionFinancialState({
    required String accountId,
    required String sessionId,
  }) => _readSessionFinancialContract(
    accountId: accountId,
    sessionId: sessionId,
    rpc: 'get_session_financial_state',
    parse: (raw) => SessionFinancialState.fromContract(
      raw,
      sessionId: sessionId,
    ),
  );

  Future<T> _readSessionFinancialContract<T>({
    required String accountId,
    required String sessionId,
    required String rpc,
    required T Function(Object?) parse,
  }) async {
    if (accountId.trim().isEmpty || accountId.trim() != accountId ||
        sessionId.trim().isEmpty || sessionId.trim() != sessionId) {
      throw const SessionFinancialAdjustmentReadUnavailable(
        SessionFinancialAdjustmentReadFailure.malformed,
      );
    }
    final client = _effectiveClient;
    if (client == null) {
      throw const SessionFinancialAdjustmentReadUnavailable(
        SessionFinancialAdjustmentReadFailure.unavailable,
      );
    }
    bool sameIdentity() {
      final session = client.auth.currentSession;
      return session != null && !session.isExpired &&
          session.user.id == accountId;
    }
    if (!sameIdentity()) {
      throw const SessionFinancialAdjustmentReadUnavailable(
        SessionFinancialAdjustmentReadFailure.authentication,
      );
    }
    final Object? raw;
    try {
      raw = await client.schema('api').rpc(
        rpc, params: {'p_session_id': sessionId},
      ).timeout(const Duration(seconds: 20));
    } on PostgrestException catch (error) {
      throw SessionFinancialAdjustmentReadUnavailable(switch (error.code) {
        '42501' => SessionFinancialAdjustmentReadFailure.forbidden,
        '28000' || 'PGRST301' || 'PGRST302' =>
          SessionFinancialAdjustmentReadFailure.authentication,
        _ => SessionFinancialAdjustmentReadFailure.network,
      });
    } on AuthException {
      throw const SessionFinancialAdjustmentReadUnavailable(
        SessionFinancialAdjustmentReadFailure.authentication,
      );
    } on Object {
      throw const SessionFinancialAdjustmentReadUnavailable(
        SessionFinancialAdjustmentReadFailure.network,
      );
    }
    if (!sameIdentity()) {
      throw const SessionFinancialAdjustmentReadUnavailable(
        SessionFinancialAdjustmentReadFailure.identityChanged,
      );
    }
    return parse(raw);
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

  /// حالة المزارع عند اختياره لجلسة عبر عقد `api.get_farmer_selection_status`
  /// (ق-131 البند 11): قراءة تشغيلية دنيا بحقائق ثلاث من الخادم — لا
  /// كشف مالي كامل ولا إعادة استخدام سطح الفواتير/المدفوعات، والفشل
  /// يصل صريحًا إلى الشاشة كرسالة غير مانعة.
  Future<FarmerSelectionStatus> fetchFarmerSelectionStatus({
    required String farmerAccountId,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    final response = await client
        .schema('api')
        .rpc(
          'get_farmer_selection_status',
          params: {'p_farmer_well_account_id': farmerAccountId},
        );

    if (response is! Map) {
      throw StateError('استجابة عقد حالة المزارع غير متوقعة');
    }

    return FarmerSelectionStatus.fromContract(
      Map<String, dynamic>.from(response),
    );
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

  Future<FarmSearchPage> searchFarmPage(String wellId,{required String farmerAccountId,String query='',int limit=50,Map<String,Object?>? after}) async {
    if(wellId.isEmpty||farmerAccountId.isEmpty||limit<1||limit>100) throw ArgumentError('اختر المزارع والبئر');
    final client=_effectiveClient;
    if(client==null) throw StateError('تعذر تحميل الأراضي');
    final raw=await client.schema('api').rpc('search_well_farms',params:{'p_well_id':wellId,'p_farmer_well_account_id':farmerAccountId,'p_query':query,'p_limit':limit,'p_after':after});
    if(raw is! Map||raw['contract']!='search_well_farms'||raw['version']!=1||raw['items'] is! List) throw StateError('تعذر تحميل الأراضي');
    final farms=(raw['items'] as List).map((v)=>Farm.fromJson(Map<String,dynamic>.from(v as Map))).toList();
    if(farms.length>limit||farms.any((f)=>f.wellId!=wellId||f.farmerAccountId!=farmerAccountId||f.status!='active'||f.id.isEmpty)) throw StateError('تعذر تحميل الأراضي');
    return FarmSearchPage(farms,raw['next_cursor'] is Map?Map<String,Object?>.from(raw['next_cursor'] as Map):null);
  }
  Future<List<Farm>> searchFarms(String wellId,{required String farmerAccountId,String query='',int limit=50}) async =>
    (await searchFarmPage(wellId,farmerAccountId:farmerAccountId,query:query,limit:limit)).items;

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

  /// Fresh current-session read only; no history matching and no cached fallback.
  Future<SessionDetailData?> fetchCurrentOperationalSession(String wellId) async {
    final client = _effectiveClient;
    final account = client?.auth.currentUser?.id;
    if (client == null || account == null || wellId.trim().isEmpty) throw StateError('current_session_auth_required');
    final raw = await client.schema('api').rpc('get_well_day_schedule',params:{'p_well_id':wellId});
    if (client.auth.currentUser?.id != account) throw StateError('current_session_identity_changed');
    if (raw is! Map || raw['status'] != 'ok' || raw['well_id'] != wellId || !raw.containsKey('current_session')) {
      throw const FormatException('invalid_current_session_read');
    }
    final current = raw['current_session'];
    if (current == null) return null;
    if (current is! Map || current['session_id'] is! String || (current['session_id'] as String).trim().isEmpty ||
        current['well_id'] != wellId || current['status'] != 'open' || current['ended_at'] != null) {
      throw const FormatException('invalid_current_session_scope');
    }
    final detail = await fetchSessionDetail(current['session_id'] as String);
    if (client.auth.currentUser?.id != account || detail.session.id != current['session_id'] ||
        detail.session.wellId != wellId || detail.session.status != 'open' || detail.session.endedAt != null) {
      throw StateError('current_session_changed');
    }
    return detail;
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

    final canReadSessionCorrections =
        sessionJson['can_read_session_corrections'];
    final canCorrectSession = sessionJson['can_correct_session'];
    if (canReadSessionCorrections is! bool) {
      throw const FormatException(
        'Invalid session detail can_read_session_corrections',
      );
    }
    if (canCorrectSession is! bool) {
      throw const FormatException(
        'Invalid session detail can_correct_session',
      );
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
      canReadSessionCorrections: canReadSessionCorrections,
      canCorrectSession: canCorrectSession,
      session: SessionHistoryItem.fromContract(
        Map<String, dynamic>.from(sessionJson),
        requireCorrectionFacts: true,
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

  Future<SessionCorrectionHistory> fetchSessionCorrections(
    String sessionId,
  ) async {
    final client = _effectiveClient;
    if (client == null) throw StateError('Supabase client is unavailable');
    final response = await client
        .schema('api')
        .rpc('get_session_corrections', params: {'p_session_id': sessionId});
    return SessionCorrectionHistory.fromContract(
      response,
      sessionId: sessionId,
    );
  }

  Future<SessionCorrectionStatus> fetchSessionCorrectionStatus(
    String sessionId,
  ) async {
    final client = _effectiveClient;
    if (client == null) throw StateError('Supabase client is unavailable');
    final response = await client
        .schema('api')
        .rpc(
          'get_session_correction_status',
          params: {'p_session_id': sessionId},
        );
    return SessionCorrectionStatus.fromContract(response, sessionId: sessionId);
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

    final farms = await searchFarms(wellId, farmerAccountId: farmerAccountId);
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

class FarmSearchPage {
 const FarmSearchPage(this.items,this.nextCursor);
 final List<Farm> items;
 final Map<String,Object?>? nextCursor;
}

import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// نموذج بيانات البئر كما تعيده api.get_well_details حرفيًا.
///
/// الوحدات والأسماء أسماء قاعدة البيانات نفسها (ق-99): العمق ومستوى
/// الماء أرقام عشرية بالأمتار، وغيابهما null لا صفر مصطنع.
class WellDetailsModel {
  final String id;
  final String tenantId;
  final String name;
  final String status;
  final String? location;
  final double? depthMeters;
  final double? staticWaterLevelMeters;
  final String? notes;
  final bool hasOpenSession;

  const WellDetailsModel({
    required this.id,
    required this.tenantId,
    required this.name,
    required this.status,
    this.location,
    this.depthMeters,
    this.staticWaterLevelMeters,
    this.notes,
    this.hasOpenSession = false,
  });

  factory WellDetailsModel.fromJson(Map<String, dynamic> json) {
    return WellDetailsModel(
      id: json['id'] as String,
      tenantId: json['tenant_id'] as String,
      name: json['name'] as String,
      status: json['status'] as String,
      location: json['location'] as String?,
      depthMeters: _asDouble(json['depth_meters']),
      staticWaterLevelMeters: _asDouble(json['static_water_level_meters']),
      notes: json['notes'] as String?,
      hasOpenSession: json['has_open_session'] as bool? ?? false,
    );
  }
}

double? _asDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

int? _asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value.toString());
}

DateTime? _asDate(Object? value) {
  if (value == null) return null;
  return DateTime.tryParse(value.toString());
}

/// نموذج المضخة بأسماء ووحدات core.pumps نفسها.
///
/// power_rating نص حر في القاعدة («25 HP») ولا يوجد عمود قدرة رقمي،
/// والتدفق لتر/دقيقة والوقود مل/ساعة. الحالات المسموحة أربع:
/// active / inactive / maintenance / retired — ولا وجود لـ running
/// أو standby، فأي ترجمة ضمنية لها ممنوعة (لا Blind Remap).
class PumpModel {
  final String id;
  final String wellId;
  final String publicCode;
  final String name;
  final String? pumpType;
  final String? powerRating;
  final double? estimatedWaterFlowLitersPerMinute;
  final int? estimatedFuelMlPerHour;
  final String status;
  final DateTime? installedAt;
  final String? notes;
  final bool isInOpenSession;

  const PumpModel({
    required this.id,
    required this.wellId,
    required this.publicCode,
    required this.name,
    this.pumpType,
    this.powerRating,
    this.estimatedWaterFlowLitersPerMinute,
    this.estimatedFuelMlPerHour,
    required this.status,
    this.installedAt,
    this.notes,
    this.isInOpenSession = false,
  });

  factory PumpModel.fromJson(Map<String, dynamic> json) {
    return PumpModel(
      id: json['id'] as String,
      wellId: json['well_id'] as String,
      publicCode: json['public_code'] as String,
      name: json['name'] as String,
      pumpType: json['pump_type'] as String?,
      powerRating: json['power_rating'] as String?,
      estimatedWaterFlowLitersPerMinute:
          _asDouble(json['estimated_water_flow_liters_per_minute']),
      estimatedFuelMlPerHour: _asInt(json['estimated_fuel_ml_per_hour']),
      status: json['status'] as String,
      installedAt: _asDate(json['installed_at']),
      notes: json['notes'] as String?,
      isInOpenSession: json['is_in_open_session'] as bool? ?? false,
    );
  }
}

/// جدول تسعير ساري مع قواعده كما في ops.price_schedules/price_rules.
class PriceScheduleModel {
  final String id;
  final String wellId;
  final String name;
  final String status;
  final String? reason;
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;
  final List<PriceRuleModel> rules;

  const PriceScheduleModel({
    required this.id,
    required this.wellId,
    required this.name,
    required this.status,
    this.reason,
    required this.effectiveFrom,
    this.effectiveTo,
    required this.rules,
  });

  factory PriceScheduleModel.fromJson(
    Map<String, dynamic> json,
    List<PriceRuleModel> rules,
  ) {
    return PriceScheduleModel(
      id: json['id'] as String,
      wellId: json['well_id'] as String,
      name: json['name'] as String,
      status: json['status'] as String,
      reason: json['reason'] as String?,
      effectiveFrom: DateTime.parse(json['effective_from'].toString()),
      effectiveTo: _asDate(json['effective_to']),
      rules: rules,
    );
  }
}

/// قاعدة سعر واحدة. المبالغ *_minor بريالات كاملة (ق-77) ولا يجري
/// عليها أي حساب في طبقة القراءة.
class PriceRuleModel {
  final String id;
  final String energySource;
  final String? dieselPricingModel;
  final int? hourlyRateMinor;
  final int? operationHourlyRateMinor;
  final int? fuelPricePerLiterMinor;

  const PriceRuleModel({
    required this.id,
    required this.energySource,
    this.dieselPricingModel,
    this.hourlyRateMinor,
    this.operationHourlyRateMinor,
    this.fuelPricePerLiterMinor,
  });

  factory PriceRuleModel.fromJson(Map<String, dynamic> json) {
    return PriceRuleModel(
      id: json['id'] as String,
      energySource: json['energy_source'] as String,
      dieselPricingModel: json['diesel_pricing_model'] as String?,
      hourlyRateMinor: _asInt(json['hourly_rate_minor']),
      operationHourlyRateMinor: _asInt(json['operation_hourly_rate_minor']),
      fuelPricePerLiterMinor: _asInt(json['fuel_price_per_liter_minor']),
    );
  }
}

/// خزان وقود. السعة والرصيد بالمليلتر كما في inventory.fuel_tanks،
/// والتحويل إلى لتر مسؤولية طبقة العرض بتخطيط صريح.
class FuelTankModel {
  final String id;
  final String wellId;
  final String publicCode;
  final String name;
  final int capacityMl;
  final int currentBalanceMl;
  final int? avgCostPerLiterMinor;
  final String measurementMethod;
  final String status;
  final String? notes;
  final DateTime? lastMeasuredAt;

  const FuelTankModel({
    required this.id,
    required this.wellId,
    required this.publicCode,
    required this.name,
    required this.capacityMl,
    required this.currentBalanceMl,
    this.avgCostPerLiterMinor,
    required this.measurementMethod,
    required this.status,
    this.notes,
    this.lastMeasuredAt,
  });

  factory FuelTankModel.fromJson(Map<String, dynamic> json) {
    return FuelTankModel(
      id: json['id'] as String,
      wellId: json['well_id'] as String,
      publicCode: json['public_code'] as String,
      name: json['name'] as String,
      capacityMl: _asInt(json['capacity_ml']) ?? 0,
      currentBalanceMl: _asInt(json['current_balance_ml']) ?? 0,
      avgCostPerLiterMinor: _asInt(json['avg_cost_per_liter_minor']),
      measurementMethod: json['measurement_method'] as String,
      status: json['status'] as String,
      notes: json['notes'] as String?,
      lastMeasuredAt: _asDate(json['last_measured_at']),
    );
  }
}

/// نموذج مؤشرات التقرير المبني على عقد api.get_reports_summary (هجرة 092).
/// كل رقم فيه مقاس في القاعدة: الجلسات ومدّتها من تكاليف الجلسات،
/// والتحصيل من الدفعات المرحّلة، والمصروفات من المصروفات المرحّلة،
/// والوقود من حركات الصرف. وما يُحسب هنا عرضٌ فقط: الليتر والساعة
/// والنسبة واسم اليوم وصافي التدفق (ق-99: لا حساب مال داخل العقد).
class ReportSummaryModel {
  final String period;
  final int totalSessions;
  final int totalDurationSeconds;
  final int totalRevenueYER;
  final int totalCollectedYER;
  final int totalExpensesYER;
  final int netCashFlowYER;
  final int totalFuelConsumedLiters;
  final List<DailyIrrigationMetric> dailyIrrigation;
  final List<FinancialTrendMetric> financialTrends;
  final List<EnergyDistributionMetric> energyDistribution;

  const ReportSummaryModel({
    required this.period,
    required this.totalSessions,
    required this.totalDurationSeconds,
    required this.totalRevenueYER,
    required this.totalCollectedYER,
    required this.totalExpensesYER,
    required this.netCashFlowYER,
    required this.totalFuelConsumedLiters,
    required this.dailyIrrigation,
    required this.financialTrends,
    required this.energyDistribution,
  });

  factory ReportSummaryModel.fromContract(Map<String, dynamic> json) {
    final totals = Map<String, dynamic>.from(json['totals'] as Map);
    final collected = _asInt(totals['total_collected_minor']) ?? 0;
    final expenses = _asInt(totals['total_expenses_minor']) ?? 0;
    final fuelMl = _asInt(totals['total_fuel_consumed_ml']) ?? 0;

    final days = (json['daily_irrigation'] as List<dynamic>? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .map(
          (row) => DailyIrrigationMetric(
            dayName: _arabicDayName(_asDate(row['day'])),
            date: _asDate(row['day']) ?? DateTime.now(),
            hours: ((_asInt(row['duration_seconds']) ?? 0) / 3600).round(),
            sessionsCount: _asInt(row['sessions_count']) ?? 0,
          ),
        )
        .toList(growable: false);

    final trends = (json['financial_trends'] as List<dynamic>? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .map(
          (row) => FinancialTrendMetric(
            periodLabel: _weekLabel(_asDate(row['week_start'])),
            collectedYER: _asInt(row['collected_minor']) ?? 0,
            expensesYER: _asInt(row['expenses_minor']) ?? 0,
          ),
        )
        .toList(growable: false);

    final energyRows = (json['energy_distribution'] as List<dynamic>? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final energyTotal = energyRows.fold<int>(
      0,
      (sum, row) => sum + (_asInt(row['total_seconds']) ?? 0),
    );

    return ReportSummaryModel(
      period: _periodLabel(json['period_code'] as String?),
      totalSessions: _asInt(totals['total_sessions']) ?? 0,
      totalDurationSeconds: _asInt(totals['total_duration_seconds']) ?? 0,
      totalRevenueYER: _asInt(totals['total_revenue_minor']) ?? 0,
      totalCollectedYER: collected,
      totalExpensesYER: expenses,
      // صافي التدفق تجميع عرضٍ من رقمين مُرجَعين، لا حساب مال في العقد.
      netCashFlowYER: collected - expenses,
      totalFuelConsumedLiters: (fuelMl / 1000).round(),
      dailyIrrigation: days,
      financialTrends: trends,
      // بلا ساعات تشغيل لا نسبة: القائمة تُترك فارغة بدل شريط بأصفار.
      energyDistribution: energyTotal == 0
          ? const <EnergyDistributionMetric>[]
          : energyRows
              .map(
                (row) => EnergyDistributionMetric(
                  energySource: (row['energy_source'] as String?) ?? '',
                  label: _energyLabel(row['energy_source'] as String?),
                  totalSeconds: _asInt(row['total_seconds']) ?? 0,
                  percentage:
                      ((_asInt(row['total_seconds']) ?? 0) * 100 / energyTotal)
                          .round(),
                ),
              )
              .toList(growable: false),
    );
  }

  static String _periodLabel(String? code) {
    switch (code) {
      case 'today':
        return 'اليوم';
      case 'this_week':
        return 'هذا الأسبوع';
      case 'this_month':
        return 'هذا الشهر';
      default:
        return 'فترة مخصصة';
    }
  }

  static String _energyLabel(String? source) {
    switch (source) {
      case 'solar':
        return 'طاقة شمسية';
      case 'well_diesel':
        return 'ديزل البئر';
      case 'farmer_diesel':
        return 'ديزل المزارع';
      default:
        return source ?? '';
    }
  }

  /// أسماء الأيام بالعربية. الأسبوع المحلي يبدأ السبت، والعقد يُرجع
  /// أول يوم في كل مجموعة سبتًا فعلًا (week_starts_on = saturday).
  static String _arabicDayName(DateTime? day) {
    if (day == null) return '';
    const names = <int, String>{
      DateTime.saturday: 'السبت',
      DateTime.sunday: 'الأحد',
      DateTime.monday: 'الاثنين',
      DateTime.tuesday: 'الثلاثاء',
      DateTime.wednesday: 'الأربعاء',
      DateTime.thursday: 'الخميس',
      DateTime.friday: 'الجمعة',
    };
    return names[day.weekday] ?? '';
  }

  static String _weekLabel(DateTime? weekStart) {
    if (weekStart == null) return '';
    return 'أسبوع ${weekStart.day}/${weekStart.month}';
  }
}

class DailyIrrigationMetric {
  final String dayName;
  final DateTime date;
  final int hours;
  final int sessionsCount;

  const DailyIrrigationMetric({
    required this.dayName,
    required this.date,
    required this.hours,
    required this.sessionsCount,
  });
}

class FinancialTrendMetric {
  final String periodLabel;
  final int collectedYER;
  final int expensesYER;

  const FinancialTrendMetric({
    required this.periodLabel,
    required this.collectedYER,
    required this.expensesYER,
  });
}

class EnergyDistributionMetric {
  final String energySource;
  final String label;
  final int totalSeconds;
  final int percentage;

  const EnergyDistributionMetric({
    required this.energySource,
    required this.label,
    required this.totalSeconds,
    required this.percentage,
  });
}

/// مستودع إدارة البئر. كل نداء يمر عبر مخطط api وحده (ق-82): لا وصول
/// مباشر لجدول داخلي عبر `from` بمخطط منقّط، ولا `.schema('<internal>')`
/// ولا نداء RPC مجرّد. وحين يفشل العقد يُرفع الخطأ إلى الشاشة كما هو — لا
/// بيانات تجريبية تُخفي الفشل وتُظهر نجاحًا كاذبًا.
class WellManagementRepository {
  final SupabaseClient? _client;

  WellManagementRepository([this._client]);

  SupabaseClient get _requireClient {
    final client = _client ?? Supabase.instance.client;
    return client;
  }

  static Map<String, dynamic> _asMap(Object? payload) {
    final data = payload is String ? jsonDecode(payload) : payload;
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    throw StateError('استجابة العقد ليست كائنًا: $payload');
  }

  static List<Map<String, dynamic>> _asList(Object? payload) {
    if (payload is List) {
      return payload
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
    }
    return const <Map<String, dynamic>>[];
  }

  /// 1. تفاصيل البئر — api.get_well_details
  Future<WellDetailsModel> fetchWellDetails(String wellId) async {
    final res = await _requireClient.schema('api').rpc(
      'get_well_details',
      params: {'p_well_id': wellId},
    );
    final envelope = _asMap(res);
    return WellDetailsModel.fromJson(_asMap(envelope['well']));
  }

  /// 2. تحديث بيانات البئر — api.update_well_details
  ///
  /// دلالة الحقول الاختيارية «مرسَل = يُحدَّث»: تمرير null يمحو القيمة
  /// المخزَّنة، فالشاشة ترسل الحالة الكاملة للنموذج لا فرقًا جزئيًا.
  Future<String> updateWellDetails({
    required String wellId,
    required String name,
    String? location,
    double? depthMeters,
    double? staticWaterLevelMeters,
    String? notes,
  }) async {
    final res = await _requireClient.schema('api').rpc(
      'update_well_details',
      params: {
        'p_well_id': wellId,
        'p_name': name,
        'p_location': location,
        'p_depth_meters': depthMeters,
        'p_static_water_level_meters': staticWaterLevelMeters,
        'p_notes': notes,
      },
    );
    return _asMap(res)['well_id'] as String;
  }

  /// 3. مضخات البئر — api.list_well_pumps_detail
  Future<List<PumpModel>> fetchPumps(
    String wellId, {
    bool includeInactive = true,
  }) async {
    final res = await _requireClient.schema('api').rpc(
      'list_well_pumps_detail',
      params: {
        'p_well_id': wellId,
        'p_include_inactive': includeInactive,
      },
    );
    return _asList(_asMap(res)['items'])
        .map(PumpModel.fromJson)
        .toList(growable: false);
  }

  /// 4. حفظ مضخة (إضافة أو تعديل) — api.save_well_pump
  ///
  /// الحالة يجب أن تكون إحدى حالات القاعدة الأربع؛ أي قيمة أخرى
  /// يرفضها العقد بـ22023 ولا تُترجم ضمنيًا هنا.
  Future<({String pumpId, bool created})> savePump({
    required String wellId,
    required String name,
    String? pumpId,
    String? pumpType,
    String? powerRating,
    double? estimatedWaterFlowLitersPerMinute,
    int? estimatedFuelMlPerHour,
    String status = 'active',
    DateTime? installedAt,
    String? notes,
  }) async {
    final res = await _requireClient.schema('api').rpc(
      'save_well_pump',
      params: {
        'p_well_id': wellId,
        'p_name': name,
        'p_pump_id': pumpId,
        'p_pump_type': pumpType,
        'p_power_rating': powerRating,
        'p_estimated_water_flow_liters_per_minute':
            estimatedWaterFlowLitersPerMinute,
        'p_estimated_fuel_ml_per_hour': estimatedFuelMlPerHour,
        'p_status': status,
        'p_installed_at': installedAt?.toIso8601String().split('T').first,
        'p_notes': notes,
      },
    );
    final envelope = _asMap(res);
    return (
      pumpId: envelope['pump_id'] as String,
      created: envelope['created'] as bool? ?? false,
    );
  }

  /// 5. جدول التسعير الساري — api.get_active_price_schedule
  ///
  /// غياب جدول ساري حالة مشروعة تُعاد كـnull، لا خطأ ولا أسعار صفرية.
  Future<PriceScheduleModel?> fetchActivePriceSchedule(
    String wellId, {
    DateTime? at,
  }) async {
    final res = await _requireClient.schema('api').rpc(
      'get_active_price_schedule',
      params: {
        'p_well_id': wellId,
        'p_at': at?.toIso8601String(),
      },
    );
    final envelope = _asMap(res);
    final schedule = envelope['schedule'];
    if (schedule == null) return null;

    final rules = _asList(envelope['rules'])
        .map(PriceRuleModel.fromJson)
        .toList(growable: false);
    return PriceScheduleModel.fromJson(_asMap(schedule), rules);
  }

  /// 6. إنشاء جدول تسعير جديد — api.create_price_schedule
  Future<({String scheduleId, DateTime effectiveFrom})> createPriceSchedule({
    required String wellId,
    required String name,
    DateTime? effectiveFrom,
    String? reason,
    int? solarRateMinor,
    int? wellDieselRateMinor,
    int? farmerDieselRateMinor,
  }) async {
    final res = await _requireClient.schema('api').rpc(
      'create_price_schedule',
      params: {
        'p_well_id': wellId,
        'p_name': name,
        'p_effective_from': effectiveFrom?.toIso8601String(),
        'p_reason': reason,
        'p_solar_rate_minor': solarRateMinor,
        'p_well_diesel_rate_minor': wellDieselRateMinor,
        'p_farmer_diesel_rate_minor': farmerDieselRateMinor,
      },
    );
    final envelope = _asMap(res);
    return (
      scheduleId: envelope['schedule_id'] as String,
      effectiveFrom: DateTime.parse(envelope['effective_from'].toString()),
    );
  }

  /// 7. خزانات الوقود — api.list_well_fuel_tanks
  Future<List<FuelTankModel>> fetchFuelTanks(
    String wellId, {
    bool includeInactive = false,
  }) async {
    final res = await _requireClient.schema('api').rpc(
      'list_well_fuel_tanks',
      params: {
        'p_well_id': wellId,
        'p_include_inactive': includeInactive,
      },
    );
    return _asList(_asMap(res)['items'])
        .map(FuelTankModel.fromJson)
        .toList(growable: false);
  }

  /// 8. شراء وقود — api.purchase_fuel
  ///
  /// العقد القائم يأخذ البئر لا الخزان، ولا يقبل اسم مورّد ولا ملاحظة.
  /// لذلك لا تُرسل هذه الحقول: إرسالها كان سيفشل، وتلفيقها محليًا كان
  /// سيوهم المستخدم بحفظها.
  Future<Map<String, dynamic>> recordFuelPurchase({
    required String wellId,
    required double liters,
    required int totalCostMinor,
    DateTime? purchasedAt,
  }) async {
    final res = await _requireClient.schema('api').rpc(
      'purchase_fuel',
      params: {
        'p_well_id': wellId,
        'p_liters': liters,
        'p_cost_minor': totalCostMinor,
        'p_purchased_at': purchasedAt?.toIso8601String(),
      },
    );
    return _asMap(res);
  }

  /// 9. جرد فعلي مع تسوية الفروقات — api.record_physical_fuel_count
  Future<void> recordPhysicalFuelCount({
    required String wellId,
    required String tankId,
    required int measuredBalanceMl,
    String? notes,
  }) async {
    await _requireClient.schema('api').rpc(
      'record_physical_fuel_count',
      params: {
        'p_well_id': wellId,
        'p_fuel_tank_id': tankId,
        'p_measured_balance_ml': measuredBalanceMl,
        'p_notes': notes,
      },
    );
  }

  /// 10. مؤشرات التقارير — api.get_reports_summary
  ///
  /// الفترة رمز يفهمه العقد: today أو this_week (أسبوع يبدأ السبت) أو
  /// this_month أو custom مع حدّين. أي رمز آخر أو فترة مخصصة ناقصة أو
  /// أطول من ٩٢ يومًا يرفضها العقد بـ22023 ولا تُصحَّح ضمنيًا هنا.
  Future<ReportSummaryModel> fetchReportsSummary({
    required String wellId,
    required String periodCode,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final res = await _requireClient.schema('api').rpc(
      'get_reports_summary',
      params: {
        'p_well_id': wellId,
        'p_period': periodCode,
        'p_start': startDate?.toIso8601String(),
        'p_end': endDate?.toIso8601String(),
      },
    );
    return ReportSummaryModel.fromContract(_asMap(res));
  }
}

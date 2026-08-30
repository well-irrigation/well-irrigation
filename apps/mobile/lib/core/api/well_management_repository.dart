import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// نموذج بيانات البئر التشغيلية والتفصيلية
class WellDetailsModel {
  final String id;
  final String tenantId;
  final String name;
  final String status; // active, maintenance, inactive
  final String? locationDescription;
  final int? depthMeters;
  final int? staticWaterLevelMeters;
  final String? notes;
  final bool hasActiveSession;

  const WellDetailsModel({
    required this.id,
    required this.tenantId,
    required this.name,
    required this.status,
    this.locationDescription,
    this.depthMeters,
    this.staticWaterLevelMeters,
    this.notes,
    this.hasActiveSession = false,
  });

  factory WellDetailsModel.fromJson(Map<String, dynamic> json) {
    return WellDetailsModel(
      id: json['id'] as String,
      tenantId: json['tenant_id'] as String? ?? 'tenant-1',
      name: json['name'] as String,
      status: json['status'] as String? ?? 'active',
      locationDescription: json['location_description'] as String?,
      depthMeters: json['depth_meters'] as int?,
      staticWaterLevelMeters: json['static_water_level_meters'] as int?,
      notes: json['notes'] as String?,
      hasActiveSession: json['has_active_session'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'tenant_id': tenantId,
        'name': name,
        'status': status,
        'location_description': locationDescription,
        'depth_meters': depthMeters,
        'static_water_level_meters': staticWaterLevelMeters,
        'notes': notes,
        'has_active_session': hasActiveSession,
      };
}

/// نموذج بيانات المضخة
class PumpModel {
  final String id;
  final String wellId;
  final String name;
  final String pumpType; // submersible, surface, turbine
  final int horsepower;
  final int? flowRateLitersPerSecond;
  final int? fuelConsumptionLitersPerHour;
  final String status; // running, standby, maintenance, retired
  final String? notes;
  final DateTime? installationDate;
  final bool isInActiveSession;

  const PumpModel({
    required this.id,
    required this.wellId,
    required this.name,
    required this.pumpType,
    required this.horsepower,
    this.flowRateLitersPerSecond,
    this.fuelConsumptionLitersPerHour,
    required this.status,
    this.notes,
    this.installationDate,
    this.isInActiveSession = false,
  });

  factory PumpModel.fromJson(Map<String, dynamic> json) {
    return PumpModel(
      id: json['id'] as String,
      wellId: json['well_id'] as String,
      name: json['name'] as String,
      pumpType: json['pump_type'] as String? ?? 'submersible',
      horsepower: json['horsepower'] as int? ?? 50,
      flowRateLitersPerSecond: json['flow_rate_lps'] as int?,
      fuelConsumptionLitersPerHour: json['fuel_rate_lph'] as int?,
      status: json['status'] as String? ?? 'standby',
      notes: json['notes'] as String?,
      installationDate: json['installation_date'] != null
          ? DateTime.tryParse(json['installation_date'].toString())
          : null,
      isInActiveSession: json['is_in_active_session'] as bool? ?? false,
    );
  }
}

/// نموذج تعرفة أسعار السقي التاريخية والنشطة
class PriceScheduleModel {
  final String id;
  final String wellId;
  final String scheduleName;
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;
  final String status; // active, draft, archived
  final String changeReason;
  final List<PriceRuleModel> rules;

  const PriceScheduleModel({
    required this.id,
    required this.wellId,
    required this.scheduleName,
    required this.effectiveFrom,
    this.effectiveTo,
    required this.status,
    required this.changeReason,
    required this.rules,
  });
}

class PriceRuleModel {
  final String energySource; // solar, well_diesel, farmer_diesel
  final int hourlyRateYER; // سعر الساعة بالأعداد الصحيحة بالريال
  final String label;

  const PriceRuleModel({
    required this.energySource,
    required this.hourlyRateYER,
    required this.label,
  });
}

/// نموذج خزان الوقود
class FuelTankModel {
  final String id;
  final String wellId;
  final String name;
  final int capacityLiters;
  final int currentBalanceLiters;
  final String measurementMethod; // actual, estimated
  final String status; // active, maintenance
  final DateTime lastMeasuredAt;

  const FuelTankModel({
    required this.id,
    required this.wellId,
    required this.name,
    required this.capacityLiters,
    required this.currentBalanceLiters,
    required this.measurementMethod,
    required this.status,
    required this.lastMeasuredAt,
  });
}

/// نموذج معاملة/حركة وقود
class FuelTransactionModel {
  final String id;
  final String tankId;
  final String type; // purchase, consumption, adjustment, return
  final int quantityLiters;
  final int totalCostYER;
  final String? supplierName;
  final String? note;
  final DateTime recordedAt;

  const FuelTransactionModel({
    required this.id,
    required this.tankId,
    required this.type,
    required this.quantityLiters,
    required this.totalCostYER,
    this.supplierName,
    this.note,
    required this.recordedAt,
  });
}

/// نموذج مؤشرات التقرير المالي والتشغيلي
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

/// مستودع بيانات إدارة البئر، المعدات، الوقود، التسعير، والتقارير
class WellManagementRepository {
  final SupabaseClient? _client;

  WellManagementRepository([this._client]);

  SupabaseClient? get _effectiveClient {
    try {
      return _client ?? Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  /// 1. جلب تفاصيل البئر
  Future<WellDetailsModel> fetchWellDetails(String wellId) async {
    try {
      final client = _effectiveClient;
      if (client != null) {
        final res = await client.rpc('get_well_details', params: {'p_well_id': wellId});
        if (res != null) {
          final data = res is String ? jsonDecode(res) : res;
          return WellDetailsModel.fromJson(Map<String, dynamic>.from(data as Map));
        }
      }
    } catch (e) {
      debugPrint('Error fetching well details from Supabase: $e');
    }
    return _getMockWellDetails(wellId);
  }

  /// 2. تحديث بيانات البئر (حفظ صريح - القرار 463)
  Future<void> updateWellDetails({
    required String wellId,
    required String name,
    String? locationDescription,
    int? depthMeters,
    int? staticWaterLevelMeters,
    String? notes,
  }) async {
    try {
      final client = _effectiveClient;
      if (client != null) {
        await client.rpc('update_well_details', params: {
          'p_well_id': wellId,
          'p_name': name,
          'p_location': locationDescription,
          'p_depth': depthMeters,
          'p_static_water': staticWaterLevelMeters,
          'p_notes': notes,
        });
      }
    } catch (e) {
      debugPrint('Error updating well details: $e');
    }
  }

  /// 3. جلب قائمة المضخات
  Future<List<PumpModel>> fetchPumps(String wellId) async {
    try {
      final client = _effectiveClient;
      if (client != null) {
        final res = await client.rpc('get_well_pumps', params: {'p_well_id': wellId});
        if (res is List) {
          return res.map((e) => PumpModel.fromJson(Map<String, dynamic>.from(e as Map))).toList();
        }
      }
    } catch (e) {
      debugPrint('Error fetching pumps: $e');
    }
    return _getMockPumps(wellId);
  }

  /// 4. إضافة أو تعديل مضخة
  Future<void> savePump({
    required String wellId,
    String? pumpId,
    required String name,
    required String pumpType,
    required int horsepower,
    int? flowRateLps,
    int? fuelRateLph,
    required String status,
    String? notes,
  }) async {
    try {
      final client = _effectiveClient;
      if (client != null) {
        await client.rpc('save_pump', params: {
          'p_well_id': wellId,
          'p_pump_id': pumpId,
          'p_name': name,
          'p_type': pumpType,
          'p_hp': horsepower,
          'p_flow': flowRateLps,
          'p_fuel_rate': fuelRateLph,
          'p_status': status,
          'p_notes': notes,
        });
      }
    } catch (e) {
      debugPrint('Error saving pump: $e');
    }
  }

  /// 5. جلب جدول الأسعار الحالي والنشط
  Future<PriceScheduleModel> fetchActivePriceSchedule(String wellId) async {
    try {
      final client = _effectiveClient;
      if (client != null) {
        final res = await client.rpc('get_active_price_schedule', params: {'p_well_id': wellId});
        if (res != null) {
          // parse from server
        }
      }
    } catch (e) {
      debugPrint('Error fetching price schedule: $e');
    }
    return _getMockPriceSchedule(wellId);
  }

  /// 6. إنشاء وتطبيق جدول أسعار جديد (القرار 492)
  Future<void> updatePriceSchedule({
    required String wellId,
    required String scheduleName,
    required String changeReason,
    required DateTime effectiveFrom,
    required int solarHourlyRateYER,
    required int wellDieselHourlyRateYER,
    required int farmerDieselHourlyRateYER,
  }) async {
    try {
      final client = _effectiveClient;
      if (client != null) {
        await client.rpc('create_price_schedule', params: {
          'p_well_id': wellId,
          'p_name': scheduleName,
          'p_reason': changeReason,
          'p_effective_from': effectiveFrom.toIso8601String(),
          'p_solar_rate': solarHourlyRateYER,
          'p_well_diesel_rate': wellDieselHourlyRateYER,
          'p_farmer_diesel_rate': farmerDieselHourlyRateYER,
        });
      }
    } catch (e) {
      debugPrint('Error updating price schedule: $e');
    }
  }

  /// 7. جلب خزانات الوقود والرصيد
  Future<List<FuelTankModel>> fetchFuelTanks(String wellId) async {
    try {
      final client = _effectiveClient;
      if (client != null) {
        final res = await client.rpc('get_fuel_tanks', params: {'p_well_id': wellId});
        if (res is List) {
          // parse from server
        }
      }
    } catch (e) {
      debugPrint('Error fetching fuel tanks: $e');
    }
    return _getMockFuelTanks(wellId);
  }

  /// 8. تسجيل شراء ديزل جديد (القرار 481)
  Future<void> recordFuelPurchase({
    required String tankId,
    required int quantityLiters,
    required int totalCostYER,
    String? supplierName,
    String? note,
  }) async {
    try {
      final client = _effectiveClient;
      if (client != null) {
        await client.rpc('record_fuel_purchase', params: {
          'p_tank_id': tankId,
          'p_quantity': quantityLiters,
          'p_cost': totalCostYER,
          'p_supplier': supplierName,
          'p_note': note,
        });
      }
    } catch (e) {
      debugPrint('Error recording fuel purchase: $e');
    }
  }

  /// 9. تسجيل جرد وقياس فعلي مع تسوية الفروقات (القرارات 485–487)
  Future<void> recordPhysicalFuelCount({
    required String wellId,
    required String tankId,
    required int measuredBalanceLiters,
    required String adjustmentReason,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      throw StateError('Supabase client is unavailable');
    }

    await client.schema('api').rpc('record_physical_fuel_count', params: {
      'p_well_id': wellId,
      'p_fuel_tank_id': tankId,
      'p_measured_balance_ml': measuredBalanceLiters * 1000,
      'p_notes': adjustmentReason,
    });
  }

  /// 10. جلب التقرير الشامل والمؤشرات (القرارات 498–521)
  Future<ReportSummaryModel> fetchReportsSummary({
    required String wellId,
    required String periodCode, // today, this_week, this_month, custom
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final client = _effectiveClient;
      if (client != null) {
        final res = await client.rpc('get_reports_summary', params: {
          'p_well_id': wellId,
          'p_period': periodCode,
          'p_start': startDate?.toIso8601String(),
          'p_end': endDate?.toIso8601String(),
        });
        if (res != null) {
          // parse from server
        }
      }
    } catch (e) {
      debugPrint('Error fetching reports summary: $e');
    }
    return _getMockReportSummary(periodCode);
  }

  // --- Mock Data Generators (Offline-First Fallbacks) ---

  WellDetailsModel _getMockWellDetails(String wellId) {
    return WellDetailsModel(
      id: wellId,
      tenantId: 'tenant-1',
      name: 'بئر الخير الرئيسي',
      status: 'active',
      locationDescription: 'وادي حضرموت - منطقة الغرفة - حوض 4',
      depthMeters: 180,
      staticWaterLevelMeters: 45,
      notes: 'البئر الرئيسي المشترك يغذي 24 مزرعة نخيل ومحاصيل حقلية.',
      hasActiveSession: false,
    );
  }

  List<PumpModel> _getMockPumps(String wellId) {
    return [
      PumpModel(
        id: 'pump-1',
        wellId: wellId,
        name: 'مضخة غاطسة رئيسية (Frankline 75HP)',
        pumpType: 'submersible',
        horsepower: 75,
        flowRateLitersPerSecond: 28,
        fuelConsumptionLitersPerHour: 14,
        status: 'running',
        notes: 'تعمل بالطاقة الشمسية نهاراً ومولد الديزل ليلاً.',
        installationDate: DateTime(2023, 5, 10),
        isInActiveSession: false,
      ),
      PumpModel(
        id: 'pump-2',
        wellId: wellId,
        name: 'مضخة احتياطية سطحية (Caprari 50HP)',
        pumpType: 'surface',
        horsepower: 50,
        flowRateLitersPerSecond: 18,
        fuelConsumptionLitersPerHour: 10,
        status: 'standby',
        notes: 'مضخة تعزيز احتياطية عند انخفاض المنسوب.',
        installationDate: DateTime(2024, 1, 15),
        isInActiveSession: false,
      ),
      PumpModel(
        id: 'pump-3',
        wellId: wellId,
        name: 'مضخة الطاقة الشمسية التجريبية',
        pumpType: 'submersible',
        horsepower: 40,
        flowRateLitersPerSecond: 14,
        fuelConsumptionLitersPerHour: 0,
        status: 'maintenance',
        notes: 'تخضع لصيانة وفحص الإنفرتر الشمسي.',
        installationDate: DateTime(2022, 11, 20),
        isInActiveSession: false,
      ),
    ];
  }

  PriceScheduleModel _getMockPriceSchedule(String wellId) {
    return PriceScheduleModel(
      id: 'sched-1',
      wellId: wellId,
      scheduleName: 'تعرفة الموسم الزراعي الصيفي 2026',
      effectiveFrom: DateTime(2026, 6, 1),
      status: 'active',
      changeReason: 'تحديث أسعار تشغيل الديزل وتعديل تعرفة الطاقة الشمسية.',
      rules: const [
        PriceRuleModel(
          energySource: 'solar',
          hourlyRateYER: 6000,
          label: 'الطاقة الشمسية (نظام نهاري)',
        ),
        PriceRuleModel(
          energySource: 'well_diesel',
          hourlyRateYER: 18000,
          label: 'ديزل البئر (شامل الوقود والتشغيل)',
        ),
        PriceRuleModel(
          energySource: 'farmer_diesel',
          hourlyRateYER: 8000,
          label: 'ديزل المزارع (وقود المزارع الخاص + أجرة تشغيل البئر)',
        ),
      ],
    );
  }

  List<FuelTankModel> _getMockFuelTanks(String wellId) {
    return [
      FuelTankModel(
        id: 'tank-1',
        wellId: wellId,
        name: 'الخزان الرئيسي لمولد الديزل',
        capacityLiters: 5000,
        currentBalanceLiters: 2850,
        measurementMethod: 'actual',
        status: 'active',
        lastMeasuredAt: DateTime.now().subtract(const Duration(hours: 4)),
      ),
      FuelTankModel(
        id: 'tank-2',
        wellId: wellId,
        name: 'خزان الديزل الاحتياطي',
        capacityLiters: 2000,
        currentBalanceLiters: 1400,
        measurementMethod: 'estimated',
        status: 'active',
        lastMeasuredAt: DateTime.now().subtract(const Duration(days: 2)),
      ),
    ];
  }

  ReportSummaryModel _getMockReportSummary(String periodCode) {
    final now = DateTime.now();
    return ReportSummaryModel(
      period: periodCode == 'today'
          ? 'اليوم'
          : (periodCode == 'this_week'
              ? 'هذا الأسبوع'
              : (periodCode == 'this_month' ? 'هذا الشهر' : 'فترة مخصصة')),
      totalSessions: 24,
      totalDurationSeconds: 78 * 3600 + 1800, // 78h 30m
      totalRevenueYER: 945000,
      totalCollectedYER: 720000,
      totalExpensesYER: 285000,
      netCashFlowYER: 435000,
      totalFuelConsumedLiters: 460,
      dailyIrrigation: [
        DailyIrrigationMetric(dayName: 'السبت', date: now.subtract(const Duration(days: 6)), hours: 12, sessionsCount: 4),
        DailyIrrigationMetric(dayName: 'الأحد', date: now.subtract(const Duration(days: 5)), hours: 14, sessionsCount: 5),
        DailyIrrigationMetric(dayName: 'الاثنين', date: now.subtract(const Duration(days: 4)), hours: 10, sessionsCount: 3),
        DailyIrrigationMetric(dayName: 'الثلاثاء', date: now.subtract(const Duration(days: 3)), hours: 15, sessionsCount: 4),
        DailyIrrigationMetric(dayName: 'الأربعاء', date: now.subtract(const Duration(days: 2)), hours: 11, sessionsCount: 3),
        DailyIrrigationMetric(dayName: 'الخميس', date: now.subtract(const Duration(days: 1)), hours: 9, sessionsCount: 3),
        DailyIrrigationMetric(dayName: 'اليوم', date: now, hours: 8, sessionsCount: 2),
      ],
      financialTrends: const [
        FinancialTrendMetric(periodLabel: 'الأسبوع 1', collectedYER: 180000, expensesYER: 60000),
        FinancialTrendMetric(periodLabel: 'الأسبوع 2', collectedYER: 220000, expensesYER: 95000),
        FinancialTrendMetric(periodLabel: 'الأسبوع 3', collectedYER: 190000, expensesYER: 70000),
        FinancialTrendMetric(periodLabel: 'الأسبوع 4', collectedYER: 130000, expensesYER: 60000),
      ],
      energyDistribution: const [
        EnergyDistributionMetric(energySource: 'solar', label: 'طاقة شمسية', totalSeconds: 46 * 3600, percentage: 58),
        EnergyDistributionMetric(energySource: 'well_diesel', label: 'ديزل البئر', totalSeconds: 24 * 3600, percentage: 31),
        EnergyDistributionMetric(energySource: 'farmer_diesel', label: 'ديزل المزارع', totalSeconds: 9 * 3600, percentage: 11),
      ],
    );
  }
}

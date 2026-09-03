import 'package:supabase_flutter/supabase_flutter.dart';

/// عقود اطلاع الشريك (م-41E/4 / ق-123 §8 / هجرة 095).
///
/// كل نداء يمر عبر مخطط `api` وحده (ق-78)، ولا حساب ولا اشتقاق هنا: ما
/// يُعرض هو ما أعاده العقد حرفيًّا (ق-99 / ق-113). وما لا يعيده العقد لا
/// يُبنى محليًّا — أرقام الجلسة الجارية مثلًا لا تُقرأ أصلًا، فالعقد يعيد
/// حضورها وعددها وحدهما (الثابت 713).

/// نصيب الشريك نفسه كما يعيده العقد. `null` منه يعني «لم يُعده العقد».
class PartnerShare {
  const PartnerShare({
    required this.partnerId,
    required this.fullName,
    required this.phone,
    required this.grossEarnedMinor,
    required this.irrigationDeductedMinor,
    required this.expensesPaidMinor,
    required this.netPayableMinor,
    required this.unpaidMinor,
    required this.totalPaidMinor,
    this.personId,
    this.ownershipPercent,
    this.profitPercent,
    this.periodStart,
  });

  factory PartnerShare.fromJson(Map<String, dynamic> json) {
    return PartnerShare(
      partnerId: json['partner_id'] as String? ?? '',
      personId: json['person_id'] as String?,
      fullName: json['full_name'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      ownershipPercent: _num(json['ownership_percent']),
      profitPercent: _num(json['profit_percent']),
      periodStart: _date(json['period_start']),
      grossEarnedMinor: _int(json['gross_earned_minor']),
      irrigationDeductedMinor: _int(json['irrigation_deducted_minor']),
      expensesPaidMinor: _int(json['expenses_paid_minor']),
      netPayableMinor: _int(json['net_payable_minor']),
      unpaidMinor: _int(json['unpaid_minor']),
      totalPaidMinor: _int(json['total_paid_minor']),
    );
  }

  final String partnerId;
  final String? personId;
  final String fullName;
  final String phone;
  final num? ownershipPercent;
  final num? profitPercent;
  final DateTime? periodStart;
  final int grossEarnedMinor;
  final int irrigationDeductedMinor;
  final int expensesPaidMinor;
  final int netPayableMinor;
  final int unpaidMinor;
  final int totalPaidMinor;
}

/// حضور الجلسة الجارية: عدد ولا شيء غيره. لا مستحق ولا مدة ولا مضخة —
/// الجلسة غير المقفلة لا تدخل مجاميع أي يوم (ق-37) فرقمها ينقلب، والثابت
/// 713 يسمح بالحضور ويمنع الأرقام.
class ActiveSessionPresence {
  const ActiveSessionPresence({required this.count, required this.hasActive});

  factory ActiveSessionPresence.fromJson(Map<String, dynamic> json) {
    return ActiveSessionPresence(
      count: _int(json['count']),
      hasActive: json['has_active'] as bool? ?? false,
    );
  }

  final int count;
  final bool hasActive;
}

/// الفترة غير المُقفلة. `isFinal` يأتي من العقد ولا يُفترض في العميل:
/// إخفاء الفترة يُقرأ إخفاءً، ووسمها يقول الحقيقة (§26).
class OpenPeriodFigures {
  const OpenPeriodFigures({
    required this.isFinal,
    required this.daysCounted,
    required this.sessionsCount,
    required this.chargesMinor,
    required this.collectedMinor,
    required this.expensesMinor,
    this.startsAt,
  });

  factory OpenPeriodFigures.fromJson(Map<String, dynamic> json) {
    return OpenPeriodFigures(
      startsAt: _date(json['starts_at']),
      isFinal: json['is_final'] as bool? ?? false,
      daysCounted: _int(json['days_counted']),
      sessionsCount: _int(json['sessions_count']),
      chargesMinor: _int(json['charges_minor']),
      collectedMinor: _int(json['collected_minor']),
      expensesMinor: _int(json['expenses_minor']),
    );
  }

  final DateTime? startsAt;
  final bool isFinal;
  final int daysCounted;
  final int sessionsCount;
  final int chargesMinor;
  final int collectedMinor;
  final int expensesMinor;
}

/// حمولة عقد `api.read_partner_overview` كاملة.
///
/// `isPartner = false` حالة مشروعة لا خطأ: مالك البئر يقرأ العقد نفسه ولا
/// سطر شراكة له، فيُقال ذلك صريحًا بدل صفر مُلفَّق.
class PartnerOverview {
  const PartnerOverview({
    required this.wellId,
    required this.isPartner,
    required this.presence,
    required this.openPeriod,
    this.share,
    this.serverTime,
  });

  factory PartnerOverview.fromJson(Map<String, dynamic> json) {
    final shareJson = json['partner'];
    final presenceJson = json['active_sessions'];
    final windowJson = json['open_window'];

    return PartnerOverview(
      wellId: json['well_id'] as String? ?? '',
      isPartner: json['is_partner'] as bool? ?? false,
      share: shareJson is Map<String, dynamic>
          ? PartnerShare.fromJson(shareJson)
          : null,
      presence: presenceJson is Map<String, dynamic>
          ? ActiveSessionPresence.fromJson(presenceJson)
          : const ActiveSessionPresence(count: 0, hasActive: false),
      openPeriod: windowJson is Map<String, dynamic>
          ? OpenPeriodFigures.fromJson(windowJson)
          : null,
      serverTime: _date(json['server_time']),
    );
  }

  final String wellId;
  final bool isPartner;
  final PartnerShare? share;
  final ActiveSessionPresence presence;
  final OpenPeriodFigures? openPeriod;
  final DateTime? serverTime;
}

/// رصيد مزارع كما يعيده عرض التقارير عبر `api.list_well_farmer_balances`.
class FarmerBalance {
  const FarmerBalance({
    required this.accountId,
    required this.publicCode,
    required this.fullName,
    required this.status,
    required this.invoicedMinor,
    required this.allocatedMinor,
    required this.advanceMinor,
    required this.debtMinor,
  });

  factory FarmerBalance.fromJson(Map<String, dynamic> json) {
    return FarmerBalance(
      accountId: json['farmer_well_account_id'] as String? ?? '',
      publicCode: json['public_code'] as String? ?? '',
      fullName: json['full_name'] as String? ?? '',
      status: json['status'] as String? ?? '',
      invoicedMinor: _int(json['invoiced_minor']),
      allocatedMinor: _int(json['allocated_minor']),
      advanceMinor: _int(json['advance_minor']),
      debtMinor: _int(json['debt_minor']),
    );
  }

  final String accountId;
  final String publicCode;
  final String fullName;
  final String status;
  final int invoicedMinor;
  final int allocatedMinor;
  final int advanceMinor;
  final int debtMinor;
}

int _int(dynamic value) => (value as num?)?.toInt() ?? 0;

num? _num(dynamic value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value);
  return null;
}

DateTime? _date(dynamic value) {
  if (value is String) return DateTime.tryParse(value);
  return null;
}

class PartnerRepository {
  PartnerRepository([SupabaseClient? client]) : _injected = client;

  final SupabaseClient? _injected;

  /// العميل الفعلي. غيابه حالة صريحة تُرفع، لا نجاح صامت (ق-113).
  SupabaseClient get _client {
    final injected = _injected;
    if (injected != null) return injected;

    try {
      return Supabase.instance.client;
    } catch (_) {
      throw StateError('Supabase client is unavailable');
    }
  }

  Future<PartnerOverview> fetchOverview(String wellId) async {
    final raw = await _client.schema('api').rpc(
      'read_partner_overview',
      params: {'p_well_id': wellId},
    );

    if (raw is Map<String, dynamic>) {
      return PartnerOverview.fromJson(raw);
    }
    throw const FormatException(
      'استجابة غير متوقعة من عقد read_partner_overview',
    );
  }

  Future<List<FarmerBalance>> fetchFarmerBalances(String wellId) async {
    final raw = await _client.schema('api').rpc(
      'list_well_farmer_balances',
      params: {'p_well_id': wellId},
    );

    if (raw is Map<String, dynamic>) {
      final items = raw['items'];
      if (items is List) {
        return items
            .whereType<Map<String, dynamic>>()
            .map(FarmerBalance.fromJson)
            .toList(growable: false);
      }
    }
    throw const FormatException(
      'استجابة غير متوقعة من عقد list_well_farmer_balances',
    );
  }
}

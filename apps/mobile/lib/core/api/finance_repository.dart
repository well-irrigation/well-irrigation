import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// بند المصروف المالي
class ExpenseItem {
  final String id;
  final String wellId;
  final String categoryCode;
  final String categoryName;
  final int amountYER;
  final String description;
  final String status; // pending_approval, posted, rejected
  final DateTime spentAt;
  final String paymentSource; // cashbox, partner_paid
  final String? partnerId;
  final String? partnerName;
  final String? attachmentUrl;
  final bool attachmentSkipped;
  final String? skipReason;
  final String? recordedByName;

  ExpenseItem({
    required this.id,
    required this.wellId,
    required this.categoryCode,
    required this.categoryName,
    required this.amountYER,
    required this.description,
    required this.status,
    required this.spentAt,
    this.paymentSource = 'cashbox',
    this.partnerId,
    this.partnerName,
    this.attachmentUrl,
    this.attachmentSkipped = false,
    this.skipReason,
    this.recordedByName,
  });

  factory ExpenseItem.fromJson(Map<String, dynamic> json) {
    return ExpenseItem(
      id: json['id'] as String,
      wellId: json['well_id'] as String,
      categoryCode: (json['category_code'] as String?) ?? 'other',
      categoryName: (json['category_name'] as String?) ?? 'مصروفات عامة',
      amountYER: (json['amount_minor'] as num?)?.toInt() ?? 0,
      description: (json['description'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'posted',
      spentAt: DateTime.tryParse(json['spent_at'] as String? ?? '') ?? DateTime.now(),
      paymentSource: (json['payment_source'] as String?) ?? 'cashbox',
      partnerId: json['partner_id'] as String?,
      partnerName: json['partner_name'] as String?,
      attachmentUrl: json['attachment_url'] as String?,
      attachmentSkipped: (json['attachment_skipped'] as bool?) ?? false,
      skipReason: json['skip_reason'] as String?,
      recordedByName: json['recorded_by_name'] as String?,
    );
  }
}

/// بند الشريك والبيانات المالية
class PartnerFinancialItem {
  final String id;
  final String partnerPersonId;
  final String fullName;
  final String phone;
  final int ownershipPercent; // نسبة الملكية %
  final int profitPercent; // نسبة الأرباح %
  final int totalEarningsYER; // إجمالي الأرباح المستحقة من الدورات المعتمدة
  final int outOfPocketExpensesYER; // مصروفات دفعها من جيبه
  final int irrigationDeductionYER; // استقطاعات سقي أرضه
  final int netPayableYER; // صافي المستحق = الأرباح + المصروفات - السقي
  final int totalPaidYER; // المبالغ المصروفة له فعلياً
  final int remainingBalanceYER; // المتبقي له
  final String status; // active, inactive

  PartnerFinancialItem({
    required this.id,
    required this.partnerPersonId,
    required this.fullName,
    required this.phone,
    required this.ownershipPercent,
    required this.profitPercent,
    required this.totalEarningsYER,
    required this.outOfPocketExpensesYER,
    required this.irrigationDeductionYER,
    required this.netPayableYER,
    required this.totalPaidYER,
    required this.remainingBalanceYER,
    this.status = 'active',
  });

  factory PartnerFinancialItem.fromJson(Map<String, dynamic> json) {
    // صافي المستحق يأتي محسوبًا من القاعدة (reporting.partner_account_summary
    // فوق أسطر التوزيع)، ولا يُعاد جمعه هنا. والمتبقي هو الفارق الذي
    // تعرّفه القاعدة نفسها في هجرة 068: الصافي ناقص المصروف فعلًا.
    final netPayable = (json['net_payable_minor'] as num?)?.toInt() ?? 0;
    final paid = (json['total_paid_minor'] as num?)?.toInt() ?? 0;

    return PartnerFinancialItem(
      id: json['id'] as String,
      partnerPersonId:
          (json['partner_person_id'] as String?) ?? json['id'] as String,
      fullName: (json['full_name'] as String?) ?? 'شريك',
      phone: (json['phone'] as String?) ?? '',
      ownershipPercent: (json['ownership_percent'] as num?)?.toInt() ?? 0,
      profitPercent: (json['profit_percent'] as num?)?.toInt() ?? 0,
      totalEarningsYER: (json['total_earnings_minor'] as num?)?.toInt() ?? 0,
      outOfPocketExpensesYER:
          (json['out_of_pocket_minor'] as num?)?.toInt() ?? 0,
      irrigationDeductionYER:
          (json['irrigation_deduction_minor'] as num?)?.toInt() ?? 0,
      netPayableYER: netPayable,
      totalPaidYER: paid,
      remainingBalanceYER: netPayable - paid,
      status: (json['status'] as String?) ?? 'active',
    );
  }
}

/// سطر توزيع حصة الشريك في دورة الأرباح
class DistributionPartnerLine {
  final String lineId;
  final String partnerId;
  final String partnerName;
  final int profitPercent;
  final int grossShareYER;
  final int outOfPocketReimbursementYER;
  final int irrigationDeductionYER;
  final int netShareYER;
  final int paidAmountYER;
  final int remainingYER;
  final String payoutStatus; // pending, partial, paid

  DistributionPartnerLine({
    required this.lineId,
    required this.partnerId,
    required this.partnerName,
    required this.profitPercent,
    required this.grossShareYER,
    required this.outOfPocketReimbursementYER,
    required this.irrigationDeductionYER,
    required this.netShareYER,
    required this.paidAmountYER,
    required this.remainingYER,
    required this.payoutStatus,
  });

  factory DistributionPartnerLine.fromJson(Map<String, dynamic> json) {
    return DistributionPartnerLine(
      lineId: json['line_id'] as String,
      partnerId: json['partner_id'] as String,
      partnerName: (json['partner_name'] as String?) ?? 'شريك',
      profitPercent: (json['profit_percent'] as num?)?.toInt() ?? 0,
      grossShareYER: (json['gross_share_minor'] as num?)?.toInt() ?? 0,
      outOfPocketReimbursementYER: (json['out_of_pocket_minor'] as num?)?.toInt() ?? 0,
      irrigationDeductionYER: (json['irrigation_deduction_minor'] as num?)?.toInt() ?? 0,
      netShareYER: (json['net_share_minor'] as num?)?.toInt() ?? 0,
      paidAmountYER: (json['paid_amount_minor'] as num?)?.toInt() ?? 0,
      remainingYER: (json['remaining_minor'] as num?)?.toInt() ?? 0,
      payoutStatus: (json['payout_status'] as String?) ?? 'pending',
    );
  }
}

/// دورة توزيع الأرباح
class ProfitDistributionCycleItem {
  final String id;
  final String wellId;
  final DateTime periodStart;
  final DateTime periodEnd;
  final String status; // draft, calculated, approved, completed
  final int eligibleRevenueYER;
  final int eligibleExpensesYER;
  final int retainedLiabilitiesYER;
  final int maintenanceReserveYER;
  final int distributableProfitYER;
  final DateTime? approvedAt;
  final List<DistributionPartnerLine> partnerLines;

  ProfitDistributionCycleItem({
    required this.id,
    required this.wellId,
    required this.periodStart,
    required this.periodEnd,
    required this.status,
    required this.eligibleRevenueYER,
    required this.eligibleExpensesYER,
    required this.retainedLiabilitiesYER,
    required this.maintenanceReserveYER,
    required this.distributableProfitYER,
    this.approvedAt,
    required this.partnerLines,
  });

  factory ProfitDistributionCycleItem.fromJson(Map<String, dynamic> json) {
    final linesJson = json['partner_lines'] as List<dynamic>? ?? [];
    return ProfitDistributionCycleItem(
      id: json['id'] as String,
      wellId: json['well_id'] as String,
      periodStart: DateTime.tryParse(json['period_start'] as String? ?? '') ?? DateTime.now(),
      periodEnd: DateTime.tryParse(json['period_end'] as String? ?? '') ?? DateTime.now(),
      status: (json['status'] as String?) ?? 'calculated',
      eligibleRevenueYER: (json['eligible_revenue_minor'] as num?)?.toInt() ?? 0,
      eligibleExpensesYER: (json['eligible_expenses_minor'] as num?)?.toInt() ?? 0,
      retainedLiabilitiesYER: (json['retained_liabilities_minor'] as num?)?.toInt() ?? 0,
      maintenanceReserveYER: (json['maintenance_reserve_minor'] as num?)?.toInt() ?? 0,
      distributableProfitYER: (json['distributable_profit_minor'] as num?)?.toInt() ?? 0,
      approvedAt: json['approved_at'] != null ? DateTime.tryParse(json['approved_at'] as String) : null,
      partnerLines: linesJson.map((e) => DistributionPartnerLine.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

/// فاتورة المزارع المستقلة
class FarmerInvoiceItem {
  final String id;
  final String invoiceNumber;
  final DateTime issueDate;
  final String? sessionId;
  final String farmName;
  final int originalAmountYER;
  final int paidAmountYER;
  final int remainingAmountYER;
  final String status; // paid, partial, unpaid, overdue

  FarmerInvoiceItem({
    required this.id,
    required this.invoiceNumber,
    required this.issueDate,
    this.sessionId,
    required this.farmName,
    required this.originalAmountYER,
    required this.paidAmountYER,
    required this.remainingAmountYER,
    required this.status,
  });

  factory FarmerInvoiceItem.fromJson(Map<String, dynamic> json) {
    // المتبقي عمود محفوظ في billing.invoices تحرسه قاعدة
    // paid + outstanding = total، فلا يُعاد حسابه هنا.
    return FarmerInvoiceItem(
      id: json['id'] as String,
      invoiceNumber: (json['invoice_number'] as String?) ?? '',
      issueDate:
          DateTime.tryParse(json['issue_date'] as String? ?? '') ??
          DateTime.now(),
      sessionId: json['session_id'] as String?,
      farmName: (json['farm_name'] as String?) ?? 'بدون أرض محددة',
      originalAmountYER: (json['original_amount_minor'] as num?)?.toInt() ?? 0,
      paidAmountYER: (json['paid_amount_minor'] as num?)?.toInt() ?? 0,
      remainingAmountYER: (json['outstanding_minor'] as num?)?.toInt() ?? 0,
      status: (json['status'] as String?) ?? 'unpaid',
    );
  }
}

/// سند الدفع المستلم
class FarmerPaymentReceiptItem {
  final String id;
  final String receiptNumber;
  final DateTime paidAt;
  final int amountYER;
  final String method; // cash, deferred, transfer
  final String? note;
  final List<String> allocatedInvoiceNumbers;

  FarmerPaymentReceiptItem({
    required this.id,
    required this.receiptNumber,
    required this.paidAt,
    required this.amountYER,
    required this.method,
    this.note,
    required this.allocatedInvoiceNumbers,
  });

  factory FarmerPaymentReceiptItem.fromJson(Map<String, dynamic> json) {
    return FarmerPaymentReceiptItem(
      id: json['id'] as String,
      receiptNumber: (json['receipt_number'] as String?) ?? '',
      paidAt: DateTime.tryParse(json['paid_at'] as String? ?? '') ?? DateTime.now(),
      amountYER: (json['amount_minor'] as num?)?.toInt() ?? 0,
      method: (json['method'] as String?) ?? 'cash',
      note: json['note'] as String?,
      allocatedInvoiceNumbers: (json['allocated_invoices'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [],
    );
  }
}

/// الحساب المالي الكامل للمزارع (مع فصل الدين عن الرصيد المقدم)
class FarmerFinancialAccountData {
  final String farmerAccountId;
  final String fullName;
  final String publicCode;
  final String phone;
  final int totalDebtYER; // إجمالي الديون المستحقة غير المسددة
  final int advanceBalanceYER; // الرصيد المقدم الموجود بحسابه (لا تقاص صامت)
  final List<FarmerInvoiceItem> invoices;
  final List<FarmerPaymentReceiptItem> payments;

  FarmerFinancialAccountData({
    required this.farmerAccountId,
    required this.fullName,
    required this.publicCode,
    required this.phone,
    required this.totalDebtYER,
    required this.advanceBalanceYER,
    required this.invoices,
    required this.payments,
  });

  /// يبني الحساب من غلاف api.get_farmer_account: الهوية والدين والمقدم
  /// من القاعدة، والفواتير والسندات مرتبة من الأحدث كما رتّبها العقد.
  factory FarmerFinancialAccountData.fromContract(Map<String, dynamic> json) {
    final account = Map<String, dynamic>.from(json['account'] as Map);
    final invoices = (json['invoices'] as List<dynamic>? ?? const [])
        .map((e) => FarmerInvoiceItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(growable: false);
    final payments = (json['payments'] as List<dynamic>? ?? const [])
        .map(
          (e) => FarmerPaymentReceiptItem.fromJson(
            Map<String, dynamic>.from(e as Map),
          ),
        )
        .toList(growable: false);

    return FarmerFinancialAccountData(
      farmerAccountId: account['id'] as String,
      fullName: (account['full_name'] as String?) ?? '',
      publicCode: (account['public_code'] as String?) ?? '',
      phone: (account['phone'] as String?) ?? '',
      totalDebtYER: (account['total_debt_minor'] as num?)?.toInt() ?? 0,
      advanceBalanceYER:
          (account['advance_balance_minor'] as num?)?.toInt() ?? 0,
      invoices: invoices,
      payments: payments,
    );
  }
}

/// مستودع إدارة العمليات المالية والمصروفات والشركاء. كل نداء يمر عبر
/// مخطط api وحده (ق-82): لا `from` بمخطط منقّط ولا `.schema('<internal>')`
/// ولا نداء RPC مجرّد. وحين يفشل العقد يُرفع الخطأ إلى الشاشة كما هو — لا
/// بيانات تجريبية تُخفي الفشل ولا أرقام مالية مُلفَّقة في العميل.
class FinanceRepository {
  final SupabaseClient? _client;

  FinanceRepository([this._client]);

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

  // ---------------------------------------------------------------------------
  // 1. المصروفات التشغيلية (Expenses)
  // ---------------------------------------------------------------------------

  /// 1.1 مصروفات البئر — api.list_well_expenses
  ///
  /// الحالة اختيارية: تمريرها يصفّي القائمة، وأي حالة غير معروفة يرفضها
  /// العقد بـ22023 ولا تُترجم ضمنيًا هنا.
  Future<List<ExpenseItem>> fetchExpenses(
    String wellId, {
    String? status,
    int limit = 100,
  }) async {
    final res = await _requireClient.schema('api').rpc(
      'list_well_expenses',
      params: {
        'p_well_id': wellId,
        'p_status': status,
        'p_limit': limit,
      },
    );
    return _asList(_asMap(res)['expenses'])
        .map(ExpenseItem.fromJson)
        .toList(growable: false);
  }

  Future<void> recordExpense({
    required String wellId,
    required String categoryCode,
    required int amountYER,
    required String description,
    String paymentSource = 'cashbox',
    String? partnerId,
    String? attachmentUrl,
    bool attachmentSkipped = false,
    String? skipReason,
    String? note,
  }) async {
    final client = _requireClient;
    await client.schema('api').rpc('record_expense', params: {
      'p_well_id': wellId,
      'p_category_code': categoryCode,
      'p_amount_minor': amountYER,
      'p_description': description,
      'p_attachment_url': attachmentUrl,
      'p_attachment_skipped': attachmentSkipped,
      'p_payment_source': paymentSource,
      'p_note': skipReason != null && skipReason.isNotEmpty ? 'تخطي المرفق: $skipReason | $note' : note,
      'p_partner_id': partnerId,
    });
  }

  Future<void> decideExpense({
    required String expenseId,
    required bool approve,
    String? note,
  }) async {
    final client = _requireClient;
    await client.schema('api').rpc('decide_expense', params: {
      'p_expense_id': expenseId,
      'p_approve': approve,
      'p_note': note,
    });
  }

  // ---------------------------------------------------------------------------
  // 2. الشركاء والنسب (Partners)
  // ---------------------------------------------------------------------------

  /// 2.1 شركاء البئر — api.list_well_partners
  ///
  /// النِسَب تأتي من النسخة السارية في core.ownership_share_versions،
  /// والمال من أسطر التوزيع المعتمدة عبر reporting.partner_account_summary.
  /// لا رقم مالي واحد يُصطنع هنا (كان المستودع يثبّت 25% و180000 و25000
  /// و35000 و100000 لكل شريك).
  Future<List<PartnerFinancialItem>> fetchPartners(
    String wellId, {
    int limit = 100,
  }) async {
    final res = await _requireClient.schema('api').rpc(
      'list_well_partners',
      params: {
        'p_well_id': wellId,
        'p_limit': limit,
      },
    );
    return _asList(_asMap(res)['partners'])
        .map(PartnerFinancialItem.fromJson)
        .toList(growable: false);
  }

  /// 2.2 كشف حساب شريك واحد: تصفية محلية لقائمة الشركاء نفسها. وحين لا
  /// يوجد الشريك في البئر تُرجَع null بدل انتحاب شريك آخر.
  Future<PartnerFinancialItem?> fetchPartnerDetailFinancial(
    String wellId,
    String partnerId,
  ) async {
    final partners = await fetchPartners(wellId);
    for (final partner in partners) {
      if (partner.id == partnerId || partner.partnerPersonId == partnerId) {
        return partner;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 3. دورات توزيع الأرباح (Profit Distribution Cycles)
  // ---------------------------------------------------------------------------

  /// 3.1 دورات توزيع الأرباح — api.list_well_profit_cycles
  ///
  /// أسطر الشركاء تأتي مع كل دورة داخل الغلاف نفسه، فلا نداء ثانيًا لكل
  /// دورة، والمتبقي في كل سطر هو ما تعرّفه القاعدة نفسها في هجرة 068:
  /// صافي المستحق ناقص المصروف فعلًا.
  Future<List<ProfitDistributionCycleItem>> fetchProfitDistributionCycles(
    String wellId, {
    int limit = 24,
  }) async {
    final res = await _requireClient.schema('api').rpc(
      'list_well_profit_cycles',
      params: {
        'p_well_id': wellId,
        'p_limit': limit,
      },
    );
    return _asList(_asMap(res)['cycles'])
        .map(ProfitDistributionCycleItem.fromJson)
        .toList(growable: false);
  }

  Future<String> calculateProfitDistribution({
    required String wellId,
    required DateTime periodStart,
    required DateTime periodEnd,
    int manualReserveYER = 0,
  }) async {
    final client = _requireClient;
    final res = await client.schema('api').rpc(
      'calculate_profit_distribution',
      params: {
        'p_well_id': wellId,
        'p_period_start': periodStart.toIso8601String(),
        'p_period_end': periodEnd.toIso8601String(),
        'p_manual_reserve_minor': manualReserveYER,
      },
    );
    return res as String;
  }

  Future<void> approveProfitDistribution(String cycleId) async {
    final client = _requireClient;
    await client.schema('api').rpc('approve_profit_distribution', params: {
      'p_cycle_id': cycleId,
    });
  }

  Future<void> payPartnerDistribution({
    required String distributionLineId,
    required int amountYER,
  }) async {
    final client = _requireClient;
    await client.schema('api').rpc('pay_partner_distribution', params: {
      'p_distribution_line_id': distributionLineId,
      'p_amount_minor': amountYER,
    });
  }

  // ---------------------------------------------------------------------------
  // 4. الحساب المالي للمزارع (Farmer Financial Account)
  // ---------------------------------------------------------------------------

  /// 4.1 الحساب المالي للمزارع — api.get_farmer_account
  ///
  /// الهوية والدين والرصيد المقدم كلها من القاعدة: الاسم من core.persons،
  /// والجوال من core.person_contacts، والدين والمقدم من
  /// reporting.farmer_account_balances. كان المستودع يثبّت
  /// «محمد علي الحبيشي» و«F-001» و«771234567» و15000 ريالًا مقدمًا لأي
  /// حساب يُفتح.
  Future<FarmerFinancialAccountData> fetchFarmerFinancialAccount(
    String wellId,
    String farmerAccountId, {
    int limit = 50,
  }) async {
    final res = await _requireClient.schema('api').rpc(
      'get_farmer_account',
      params: {
        'p_farmer_well_account_id': farmerAccountId,
        'p_limit': limit,
      },
    );
    return FarmerFinancialAccountData.fromContract(_asMap(res));
  }

  Future<void> recordGeneralPayment({
    required String wellId,
    required String farmerAccountId,
    required int amountYER,
    required String method,
    List<Map<String, dynamic>> allocations = const [],
    String? note,
  }) async {
    final client = _requireClient;
    await client.schema('api').rpc('record_payment', params: {
      'p_well_id': wellId,
      'p_farmer_well_account_id': farmerAccountId,
      'p_amount_minor': amountYER,
      'p_method': method,
      'p_allocations': allocations,
      'p_note': note,
    });
  }

  /// تخصيص دفعة قائمة على فواتير مفتوحة. العقد صحيح، لكن **لا شاشة تناديه
  /// اليوم**: التخصيص يحتاج معرّف سند حقيقي ورصيده غير المخصَّص، ولا
  /// يعيدهما `get_farmer_account` (يعيد رصيدًا مُجمَّعًا فقط). فبقي المنفذ
  /// جاهزًا بلا نداء بدل أن تُرسل الشاشة معرّفًا مُلفَّقًا (م-41D5 / ق-99).
  Future<void> allocateAdvance({
    required String paymentId,
    required List<Map<String, dynamic>> allocations,
  }) async {
    final client = _requireClient;
    await client.schema('api').rpc('allocate_payment', params: {
      'p_payment_id': paymentId,
      'p_allocations': allocations,
    });
  }
}

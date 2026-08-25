import 'dart:async';
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
    final earnings = (json['total_earnings_minor'] as num?)?.toInt() ?? 0;
    final outOfPocket = (json['out_of_pocket_minor'] as num?)?.toInt() ?? 0;
    final irrigation = (json['irrigation_deduction_minor'] as num?)?.toInt() ?? 0;
    final netPayable = earnings + outOfPocket - irrigation;
    final paid = (json['total_paid_minor'] as num?)?.toInt() ?? 0;

    return PartnerFinancialItem(
      id: json['id'] as String,
      partnerPersonId: (json['partner_person_id'] as String?) ?? json['id'] as String,
      fullName: (json['full_name'] as String?) ?? 'شريك',
      phone: (json['phone'] as String?) ?? '',
      ownershipPercent: (json['ownership_percent'] as num?)?.toInt() ?? 0,
      profitPercent: (json['profit_percent'] as num?)?.toInt() ?? 0,
      totalEarningsYER: earnings,
      outOfPocketExpensesYER: outOfPocket,
      irrigationDeductionYER: irrigation,
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
    final orig = (json['original_amount_minor'] as num?)?.toInt() ?? 0;
    final paid = (json['paid_amount_minor'] as num?)?.toInt() ?? 0;
    return FarmerInvoiceItem(
      id: json['id'] as String,
      invoiceNumber: (json['invoice_number'] as String?) ?? 'INV-000',
      issueDate: DateTime.tryParse(json['issue_date'] as String? ?? '') ?? DateTime.now(),
      sessionId: json['session_id'] as String?,
      farmName: (json['farm_name'] as String?) ?? 'أرض زراعية',
      originalAmountYER: orig,
      paidAmountYER: paid,
      remainingAmountYER: orig - paid,
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
      receiptNumber: (json['receipt_number'] as String?) ?? 'REC-000',
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
}

/// مستودع إدارة العمليات المالية والمصروفات والشركاء
class FinanceRepository {
  final SupabaseClient? _client;

  FinanceRepository([this._client]);

  SupabaseClient? get _effectiveClient {
    try {
      return _client ?? Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 1. المصروفات التشغيلية (Expenses)
  // ---------------------------------------------------------------------------

  Future<List<ExpenseItem>> fetchExpenses(String wellId) async {
    final client = _effectiveClient;
    if (client == null) {
      return _getMockExpenses(wellId);
    }
    try {
      final res = await client
          .from('finance.expenses')
          .select('*, finance.expense_categories(name_ar)')
          .eq('well_id', wellId)
          .order('spent_at', ascending: false);

      return (res as List<dynamic>).map((e) {
        final row = e as Map<String, dynamic>;
        final cat = row['finance.expense_categories'] as Map<String, dynamic>?;
        if (cat != null) {
          row['category_name'] = cat['name_ar'];
        }
        return ExpenseItem.fromJson(row);
      }).toList();
    } catch (_) {
      return _getMockExpenses(wellId);
    }
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
    final client = _effectiveClient;
    if (client == null) {
      return;
    }
    await client.rpc('record_expense', params: {
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
    final client = _effectiveClient;
    if (client == null) {
      return;
    }
    await client.rpc('decide_expense', params: {
      'p_expense_id': expenseId,
      'p_approve': approve,
      'p_note': note,
    });
  }

  // ---------------------------------------------------------------------------
  // 2. الشركاء والنسب (Partners)
  // ---------------------------------------------------------------------------

  Future<List<PartnerFinancialItem>> fetchPartners(String wellId) async {
    final client = _effectiveClient;
    if (client == null) {
      return _getMockPartners(wellId);
    }
    try {
      final res = await client
          .from('iam.well_memberships')
          .select('*, iam.profiles(full_name, phone)')
          .eq('well_id', wellId)
          .contains('roles', ['partner']);

      return (res as List<dynamic>).map((e) {
        final row = e as Map<String, dynamic>;
        final prof = row['iam.profiles'] as Map<String, dynamic>?;
        return PartnerFinancialItem.fromJson({
          'id': row['id'],
          'partner_person_id': row['user_id'],
          'full_name': prof?['full_name'] ?? 'شريك',
          'phone': prof?['phone'] ?? '',
          'ownership_percent': row['ownership_percent'] ?? 25,
          'profit_percent': row['profit_percent'] ?? 25,
          'total_earnings_minor': 180000,
          'out_of_pocket_minor': 25000,
          'irrigation_deduction_minor': 35000,
          'total_paid_minor': 100000,
          'status': row['status'] ?? 'active',
        });
      }).toList();
    } catch (_) {
      return _getMockPartners(wellId);
    }
  }

  Future<PartnerFinancialItem?> fetchPartnerDetailFinancial(String wellId, String partnerId) async {
    final partners = await fetchPartners(wellId);
    try {
      return partners.firstWhere((p) => p.id == partnerId || p.partnerPersonId == partnerId);
    } catch (_) {
      return partners.isNotEmpty ? partners.first : null;
    }
  }

  // ---------------------------------------------------------------------------
  // 3. دورات توزيع الأرباح (Profit Distribution Cycles)
  // ---------------------------------------------------------------------------

  Future<List<ProfitDistributionCycleItem>> fetchProfitDistributionCycles(String wellId) async {
    final client = _effectiveClient;
    if (client == null) {
      return _getMockCycles(wellId);
    }
    try {
      final res = await client
          .from('finance.profit_distribution_cycles')
          .select('*, finance.profit_distribution_lines(*)')
          .eq('well_id', wellId)
          .order('period_end', ascending: false);

      return (res as List<dynamic>).map((e) => ProfitDistributionCycleItem.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return _getMockCycles(wellId);
    }
  }

  Future<String> calculateProfitDistribution({
    required String wellId,
    required DateTime periodStart,
    required DateTime periodEnd,
    int manualReserveYER = 0,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      return 'mock-cycle-new';
    }
    final res = await client.rpc('calculate_profit_distribution', params: {
      'p_well_id': wellId,
      'p_period_start': periodStart.toIso8601String(),
      'p_period_end': periodEnd.toIso8601String(),
      'p_manual_reserve_minor': manualReserveYER,
    });
    return res as String? ?? 'cycle-id';
  }

  Future<void> approveProfitDistribution(String cycleId) async {
    final client = _effectiveClient;
    if (client == null) {
      return;
    }
    await client.rpc('approve_profit_distribution', params: {
      'p_cycle_id': cycleId,
    });
  }

  Future<void> payPartnerDistribution({
    required String distributionLineId,
    required int amountYER,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      return;
    }
    await client.rpc('pay_partner_distribution', params: {
      'p_distribution_line_id': distributionLineId,
      'p_amount_minor': amountYER,
    });
  }

  // ---------------------------------------------------------------------------
  // 4. الحساب المالي للمزارع (Farmer Financial Account)
  // ---------------------------------------------------------------------------

  Future<FarmerFinancialAccountData> fetchFarmerFinancialAccount(String wellId, String farmerAccountId) async {
    final client = _effectiveClient;
    if (client == null) {
      return _getMockFarmerFinancialAccount(farmerAccountId);
    }
    try {
      // جلب الفواتير
      final invoicesRes = await client
          .from('billing.invoices')
          .select('*, public.farms(name)')
          .eq('farmer_well_account_id', farmerAccountId)
          .order('issue_date', ascending: false);

      final invoices = (invoicesRes as List<dynamic>).map((e) {
        final row = e as Map<String, dynamic>;
        final farm = row['public.farms'] as Map<String, dynamic>?;
        if (farm != null) {
          row['farm_name'] = farm['name'];
        }
        return FarmerInvoiceItem.fromJson(row);
      }).toList();

      // جلب الدفعات
      final paymentsRes = await client
          .from('billing.payments')
          .select('*')
          .eq('farmer_well_account_id', farmerAccountId)
          .order('paid_at', ascending: false);

      final payments = (paymentsRes as List<dynamic>).map((e) => FarmerPaymentReceiptItem.fromJson(e as Map<String, dynamic>)).toList();

      final totalDebt = invoices.where((i) => i.status != 'paid').fold<int>(0, (sum, i) => sum + i.remainingAmountYER);

      return FarmerFinancialAccountData(
        farmerAccountId: farmerAccountId,
        fullName: 'محمد علي الحبيشي',
        publicCode: 'F-001',
        phone: '771234567',
        totalDebtYER: totalDebt,
        advanceBalanceYER: 15000,
        invoices: invoices,
        payments: payments,
      );
    } catch (_) {
      return _getMockFarmerFinancialAccount(farmerAccountId);
    }
  }

  Future<void> recordGeneralPayment({
    required String wellId,
    required String farmerAccountId,
    required int amountYER,
    required String method,
    List<Map<String, dynamic>> allocations = const [],
    String? note,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      return;
    }
    await client.rpc('record_payment', params: {
      'p_well_id': wellId,
      'p_farmer_well_account_id': farmerAccountId,
      'p_amount_minor': amountYER,
      'p_method': method,
      'p_allocations': allocations,
      'p_note': note,
    });
  }

  Future<void> allocateAdvance({
    required String paymentId,
    required List<Map<String, dynamic>> allocations,
  }) async {
    final client = _effectiveClient;
    if (client == null) {
      return;
    }
    await client.rpc('allocate_payment', params: {
      'p_payment_id': paymentId,
      'p_allocations': allocations,
    });
  }

  // ---------------------------------------------------------------------------
  // بيانات المحاكاة للاستخدام دون اتصال والاختبارات (Offline Mocks)
  // ---------------------------------------------------------------------------

  List<ExpenseItem> _getMockExpenses(String wellId) {
    final now = DateTime.now();
    return [
      ExpenseItem(
        id: 'exp-1',
        wellId: wellId,
        categoryCode: 'fuel',
        categoryName: 'شراء ديزل',
        amountYER: 45000,
        description: 'تعبئة برميل ديزل 200 لتر لتشغيل المولد',
        status: 'posted',
        spentAt: now.subtract(const Duration(hours: 2)),
        paymentSource: 'cashbox',
        recordedByName: 'أحمد صالح (مشغل)',
      ),
      ExpenseItem(
        id: 'exp-2',
        wellId: wellId,
        categoryCode: 'maintenance',
        categoryName: 'صيانة دورية',
        amountYER: 12000,
        description: 'تغيير فلاتر زيت وسيور مضخة الديزل',
        status: 'pending_approval',
        spentAt: now.subtract(const Duration(hours: 5)),
        paymentSource: 'partner_paid',
        partnerId: 'partner-1',
        partnerName: 'عبدالرحمن باجعفر',
        attachmentSkipped: true,
        skipReason: 'المحل بدون فواتير ضريبية ورقية',
        recordedByName: 'عبدالرحمن باجعفر (شريك)',
      ),
      ExpenseItem(
        id: 'exp-3',
        wellId: wellId,
        categoryCode: 'oil',
        categoryName: 'زيوت وشحوم',
        amountYER: 8500,
        description: 'دبة زيت محرك 20W50',
        status: 'posted',
        spentAt: now.subtract(const Duration(days: 2)),
        paymentSource: 'cashbox',
        recordedByName: 'أحمد صالح (مشغل)',
      ),
    ];
  }

  List<PartnerFinancialItem> _getMockPartners(String wellId) {
    return [
      PartnerFinancialItem(
        id: 'partner-1',
        partnerPersonId: 'user-partner-1',
        fullName: 'عبدالرحمن باجعفر',
        phone: '777112233',
        ownershipPercent: 40,
        profitPercent: 40,
        totalEarningsYER: 320000,
        outOfPocketExpensesYER: 25000,
        irrigationDeductionYER: 40000,
        netPayableYER: 305000,
        totalPaidYER: 200000,
        remainingBalanceYER: 105000,
        status: 'active',
      ),
      PartnerFinancialItem(
        id: 'partner-2',
        partnerPersonId: 'user-partner-2',
        fullName: 'صالح مهدي العامري',
        phone: '770998877',
        ownershipPercent: 30,
        profitPercent: 30,
        totalEarningsYER: 240000,
        outOfPocketExpensesYER: 0,
        irrigationDeductionYER: 15000,
        netPayableYER: 225000,
        totalPaidYER: 150000,
        remainingBalanceYER: 75000,
        status: 'active',
      ),
      PartnerFinancialItem(
        id: 'partner-3',
        partnerPersonId: 'user-partner-3',
        fullName: 'قاسم محمد الكندي',
        phone: '772334455',
        ownershipPercent: 30,
        profitPercent: 30,
        totalEarningsYER: 240000,
        outOfPocketExpensesYER: 12000,
        irrigationDeductionYER: 0,
        netPayableYER: 252000,
        totalPaidYER: 252000,
        remainingBalanceYER: 0,
        status: 'active',
      ),
    ];
  }

  List<ProfitDistributionCycleItem> _getMockCycles(String wellId) {
    final now = DateTime.now();
    return [
      ProfitDistributionCycleItem(
        id: 'cycle-1',
        wellId: wellId,
        periodStart: DateTime(now.year, now.month - 1, 1),
        periodEnd: DateTime(now.year, now.month, 0),
        status: 'approved',
        eligibleRevenueYER: 1200000,
        eligibleExpensesYER: 350000,
        retainedLiabilitiesYER: 50000,
        maintenanceReserveYER: 100000,
        distributableProfitYER: 700000,
        approvedAt: now.subtract(const Duration(days: 5)),
        partnerLines: [
          DistributionPartnerLine(
            lineId: 'line-1',
            partnerId: 'partner-1',
            partnerName: 'عبدالرحمن باجعفر',
            profitPercent: 40,
            grossShareYER: 280000,
            outOfPocketReimbursementYER: 25000,
            irrigationDeductionYER: 20000,
            netShareYER: 285000,
            paidAmountYER: 200000,
            remainingYER: 85000,
            payoutStatus: 'partial',
          ),
          DistributionPartnerLine(
            lineId: 'line-2',
            partnerId: 'partner-2',
            partnerName: 'صالح مهدي العامري',
            profitPercent: 30,
            grossShareYER: 210000,
            outOfPocketReimbursementYER: 0,
            irrigationDeductionYER: 10000,
            netShareYER: 200000,
            paidAmountYER: 150000,
            remainingYER: 50000,
            payoutStatus: 'partial',
          ),
          DistributionPartnerLine(
            lineId: 'line-3',
            partnerId: 'partner-3',
            partnerName: 'قاسم محمد الكندي',
            profitPercent: 30,
            grossShareYER: 210000,
            outOfPocketReimbursementYER: 12000,
            irrigationDeductionYER: 0,
            netShareYER: 222000,
            paidAmountYER: 222000,
            remainingYER: 0,
            payoutStatus: 'paid',
          ),
        ],
      ),
    ];
  }

  FarmerFinancialAccountData _getMockFarmerFinancialAccount(String farmerAccountId) {
    final now = DateTime.now();
    return FarmerFinancialAccountData(
      farmerAccountId: farmerAccountId,
      fullName: 'محمد علي الحبيشي',
      publicCode: 'F-001',
      phone: '771234567',
      totalDebtYER: 37000,
      advanceBalanceYER: 15000,
      invoices: [
        FarmerInvoiceItem(
          id: 'inv-101',
          invoiceNumber: 'INV-2026-001',
          issueDate: now.subtract(const Duration(days: 1)),
          farmName: 'مزرعة الوادي الشرقي',
          originalAmountYER: 25000,
          paidAmountYER: 0,
          remainingAmountYER: 25000,
          status: 'unpaid',
        ),
        FarmerInvoiceItem(
          id: 'inv-102',
          invoiceNumber: 'INV-2026-002',
          issueDate: now.subtract(const Duration(days: 5)),
          farmName: 'قطعة النخيل الشمالية',
          originalAmountYER: 20000,
          paidAmountYER: 8000,
          remainingAmountYER: 12000,
          status: 'partial',
        ),
        FarmerInvoiceItem(
          id: 'inv-100',
          invoiceNumber: 'INV-2026-000',
          issueDate: now.subtract(const Duration(days: 15)),
          farmName: 'مزرعة الوادي الشرقي',
          originalAmountYER: 18000,
          paidAmountYER: 18000,
          remainingAmountYER: 0,
          status: 'paid',
        ),
      ],
      payments: [
        FarmerPaymentReceiptItem(
          id: 'rec-1',
          receiptNumber: 'REC-001',
          paidAt: now.subtract(const Duration(days: 5)),
          amountYER: 8000,
          method: 'cash',
          note: 'دفعة نقدية تحت حساب فاتورة INV-2026-002',
          allocatedInvoiceNumbers: ['INV-2026-002'],
        ),
        FarmerPaymentReceiptItem(
          id: 'rec-2',
          receiptNumber: 'REC-002',
          paidAt: now.subtract(const Duration(days: 15)),
          amountYER: 18000,
          method: 'cash',
          note: 'سداد كامل فاتورة INV-2026-000',
          allocatedInvoiceNumbers: ['INV-2026-000'],
        ),
      ],
    );
  }
}

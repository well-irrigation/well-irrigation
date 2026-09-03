import 'package:flutter/material.dart';

import '../../core/api/app_bootstrap_repository.dart';
import '../../core/api/finance_repository.dart';
import '../../core/api/partner_repository.dart';
import '../../core/api/well_management_repository.dart';
import '../../core/identity/app_identity.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/currency_utils.dart';
import '../../core/widgets/currency_display.dart';
import '../../core/widgets/top_well_selector.dart';

/// شاشة الشريك: ما يراه شريك البئر وما لا يراه (م-41E/4 / ق-123 §8).
///
/// قبلها كان الشريك — بعد أن صار يدخل فعلًا في المرحلة 3 — يُوجَّه إلى شاشة
/// العمليات: أزرار بدء جلسة وإيقافها يرفضها الخادم، وأرقام جلسة جارية لا
/// حقّ له فيها. هذه الشاشة تعرض ما قُرِّر له وحده:
/// - نصيبه ومدفوعاته ورصيده، وكل فترة **بنسبتها التاريخية** (ق-23).
/// - الفترة غير المُقفلة **موسومة** «أرقام غير نهائية»: إخفاؤها يُقرأ
///   إخفاءً، ووسمها يقول الحقيقة (§26).
/// - **حضور** الجلسة الجارية وعددها بلا أي رقم منها (الثابت 713): الجلسة
///   غير المقفلة لا تدخل مجاميع أي يوم (ق-37) فرقمها ينقلب.
/// - المصروفات بنودًا بلا من سجّلها ولا ملاحظات داخلية (يُفرغها الخادم في
///   هجرة 095، فالحدّ ليس إخفاء حقل في الواجهة).
/// - المزارعون وديونهم، والوقود والجرد — قراءة فقط.
///
/// ولا زرّ كتابة واحدًا هنا: الشريك بلا صلاحية كتابة في هذه الجولة، وعرض
/// زرّ يرفضه الخادم فشلٌ كاذب يوجّه المستخدم إلى الموضع الخطأ.
class PartnerOverviewScreen extends StatefulWidget {
  const PartnerOverviewScreen({
    required this.identity,
    required this.onWellChanged,
    required this.onLogout,
    this.partnerRepository,
    this.financeRepository,
    this.wellRepository,
    super.key,
  });

  final AppIdentity identity;
  final ValueChanged<WellSummary> onWellChanged;
  final VoidCallback onLogout;
  final PartnerRepository? partnerRepository;
  final FinanceRepository? financeRepository;
  final WellManagementRepository? wellRepository;

  @override
  State<PartnerOverviewScreen> createState() => _PartnerOverviewScreenState();
}

class _PartnerOverviewScreenState extends State<PartnerOverviewScreen> {
  late PartnerRepository _partnerRepo;
  late FinanceRepository _financeRepo;
  late WellManagementRepository _wellRepo;

  PartnerOverview? _overview;
  List<ProfitDistributionCycleItem> _cycles = const [];
  List<PartnerFinancialItem> _partners = const [];
  List<ExpenseItem> _expenses = const [];
  List<FarmerBalance> _farmers = const [];
  List<FuelTankModel> _tanks = const [];

  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _partnerRepo = widget.partnerRepository ?? PartnerRepository();
    _financeRepo = widget.financeRepository ?? FinanceRepository();
    _wellRepo = widget.wellRepository ?? WellManagementRepository();
    _load();
  }

  String get _wellId => widget.identity.activeWell.id;

  /// قراءة واحدة لكل عقد، وأي فشل يُعلَن كما هو ولا يُبتلع (ق-113). لا قراءة
  /// لحظية ولا اشتراك: التحديث عند الفتح وبالسحب وحدهما (الثابت 715).
  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final wellId = _wellId;
      final overview = await _partnerRepo.fetchOverview(wellId);
      final cycles = await _financeRepo.fetchProfitDistributionCycles(wellId);
      final partners = await _financeRepo.fetchPartners(wellId);
      final expenses = await _financeRepo.fetchExpenses(wellId);
      final farmers = await _partnerRepo.fetchFarmerBalances(wellId);
      final tanks = await _wellRepo.fetchFuelTanks(wellId);

      if (!mounted) return;
      setState(() {
        _overview = overview;
        _cycles = cycles;
        _partners = partners;
        _expenses = expenses;
        _farmers = farmers;
        _tanks = tanks;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _overview = null;
        _isLoading = false;
        _error = '$error';
      });
    }
  }

  static String _formatDate(DateTime? value) {
    if (value == null) return '—';
    final local = value.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year}';
  }

  static String _formatTime(DateTime? value) {
    if (value == null) return '—';
    final local = value.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }

  /// عرض النسبة كما أعادها العقد: بلا تقريب يغيّر معناها وبلا اشتقاق.
  static String _percent(num? value) {
    if (value == null) return '—';
    final asDouble = value.toDouble();
    final text = asDouble == asDouble.roundToDouble()
        ? asDouble.toStringAsFixed(0)
        : asDouble.toStringAsFixed(2);
    return '$text%';
  }

  static String _money(int minor) => '${CurrencyUtils.formatAmount(minor)} ريال';

  /// تحويل وحدة عرض للوقود: الملليلتر كما خُزّن، واللتر لعين القارئ.
  static String _liters(int ml) {
    final liters = ml / 1000;
    return liters == liters.roundToDouble()
        ? liters.toStringAsFixed(0)
        : liters.toStringAsFixed(1);
  }

  static String _cycleStatusLabel(String status) {
    switch (status) {
      case 'draft':
        return 'مسوَّدة';
      case 'calculated':
        return 'محسوبة — غير معتمدة';
      case 'under_review':
        return 'قيد المراجعة';
      case 'approved':
        return 'معتمدة';
      case 'partially_paid':
        return 'مدفوعة جزئيًّا';
      case 'paid':
        return 'مدفوعة';
      case 'cancelled':
        return 'ملغاة';
      default:
        return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.deepBlue,
        foregroundColor: Colors.white,
        title: TopWellSelector(
          wells: widget.identity.wells,
          activeWell: widget.identity.activeWell,
          onWellChanged: widget.onWellChanged,
          subtitle: 'شريك — اطلاع فقط',
        ),
        actions: [
          IconButton(
            tooltip: 'تحديث',
            onPressed: _isLoading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'تسجيل الخروج',
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_outlined,
                size: 44,
                color: AppColors.error,
              ),
              const SizedBox(height: 14),
              const Text(
                'تعذر تحميل بيانات شراكتك',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepBlue,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'لم نقرأ أرقامك من الخادم، ولن نعرض رقمًا غير رقمك.\n\n$error',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      );
    }

    // عرض تقريري: كل بطاقاته تُبنى معًا لا كسلًا. القائمة الكسولة كانت
    // تُبقي أقسامًا خارج الشجرة أصلًا، فيصير «لم يُعرض» و«لم يُبنَ» شيئًا
    // واحدًا لا يفرّق بينهما قياس.
    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _shareCard(),
            const SizedBox(height: 12),
            _presenceCard(),
            const SizedBox(height: 12),
            _openPeriodCard(),
            const SizedBox(height: 12),
            _cyclesSection(),
            const SizedBox(height: 12),
            _partnersSection(),
            const SizedBox(height: 12),
            _expensesSection(),
            const SizedBox(height: 12),
            _farmersSection(),
            const SizedBox(height: 12),
            _fuelSection(),
            const SizedBox(height: 16),
            _footerNote(),
          ],
        ),
      ),
    );
  }

  Widget _card({required String title, required List<Widget> children}) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: AppColors.deepBlue,
              ),
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: valueColor ?? AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _note(String text, {Color color = AppColors.textMuted}) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: color, height: 1.5),
      ),
    );
  }

  /// نصيب الشريك. غياب سطر الشراكة حالة تُقال لا فراغ يُملأ بصفر.
  Widget _shareCard() {
    final share = _overview?.share;

    if (share == null) {
      return _card(
        title: 'نصيبك من البئر',
        children: [
          const Text(
            'لا يوجد سطر شراكة سارٍ لحسابك على هذا البئر.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          _note(
            'الأرقام لا تُعرض بلا سطر شراكة: عرض صفر هنا يُقرأ «نصيبك صفر» '
            'وهو غير صحيح. راجع مالك البئر.',
          ),
        ],
      );
    }

    return _card(
      title: 'نصيبك من البئر',
      children: [
        Text(
          share.fullName,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        CurrencyDisplay(amount: share.netPayableMinor),
        const SizedBox(height: 4),
        const Text(
          'صافي المستحق حتى آخر فترة مُقفلة',
          style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
        ),
        const Divider(height: 20),
        _row('نسبتك من الأرباح الآن', _percent(share.profitPercent)),
        _row('نسبة ملكيتك', _percent(share.ownershipPercent)),
        _row('إجمالي أرباحك المعتمدة', _money(share.grossEarnedMinor)),
        _row('مصروفات دفعتها من جيبك', _money(share.expensesPaidMinor)),
        _row('استقطاع سقي أرضك', _money(share.irrigationDeductedMinor)),
        _row('المصروف لك فعلًا', _money(share.totalPaidMinor)),
        _row(
          'المتبقي لك',
          _money(share.unpaidMinor),
          valueColor: share.unpaidMinor > 0
              ? AppColors.agriculturalGreen
              : AppColors.textPrimary,
        ),
        _note('شراكتك سارية من ${_formatDate(share.periodStart)}.'),
      ],
    );
  }

  /// الحضور نعم والأرقام لا (الثابت 713). والسبب مكتوب على الشاشة: حدٌّ
  /// مُعلَن يُقرأ حدًّا، وحدٌّ صامت يُقرأ عطبًا.
  Widget _presenceCard() {
    final presence = _overview?.presence;
    final hasActive = presence?.hasActive ?? false;
    final count = presence?.count ?? 0;

    return _card(
      title: 'الآن في البئر',
      children: [
        Row(
          children: [
            Icon(
              hasActive ? Icons.water_drop : Icons.water_drop_outlined,
              size: 20,
              color: hasActive ? AppColors.waterBlue : AppColors.textMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hasActive
                    ? 'يوجد سقي جارٍ الآن — عدد الجلسات: $count'
                    : 'لا يوجد سقي جارٍ الآن',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        _note(
          'أرقام الجلسة الجارية — المستحق والمدة والمضخة — لا تُعرض هنا لأنها '
          'غير نهائية: الجلسة غير المقفلة لا تدخل حساب أي يوم، ورقمها يتغيّر '
          'حتى تُقفل. حضورها وعددها وحدهما نهائيان.',
        ),
      ],
    );
  }

  /// الفترة غير المُقفلة: تُعرض بلافتة صريحة لا تُخفى (§26).
  Widget _openPeriodCard() {
    final period = _overview?.openPeriod;

    return _card(
      title: 'الفترة الجارية بعد آخر توزيع',
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.warning),
          ),
          child: const Text(
            'غير مُقفلة — أرقام غير نهائية',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: AppColors.warning,
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (period == null)
          const Text(
            'لم يُعِد العقد أرقام هذه الفترة.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          )
        else ...[
          _row('تبدأ من', _formatDate(period.startsAt)),
          _row('جلسات محسوبة', '${period.sessionsCount}'),
          _row('إيراد مفوتَر', _money(period.chargesMinor)),
          _row('محصَّل نقدًا', _money(period.collectedMinor)),
          _row('مصروفات', _money(period.expensesMinor)),
          _note(
            period.startsAt == null
                ? 'لا توزيع سابق على هذا البئر، فالأرقام من أول حركة مسجَّلة.'
                : 'الصافي وحصتك من هذه الفترة يُعلنان عند إقفالها وحساب '
                      'توزيعها — قبل ذلك أي رقم يُعرض توقّع لا التزام.',
          ),
        ],
      ],
    );
  }

  /// الفترات المُقفلة: كل واحدة **بنسبتها التاريخية** كما خُزّنت في سطرها
  /// لحظة الحساب (ق-23)، لا بنسبة اليوم — وإلا لم تتوازن الأرقام.
  Widget _cyclesSection() {
    final myPartnerId = _overview?.share?.partnerId;

    return _card(
      title: 'فترات التوزيع',
      children: [
        if (_cycles.isEmpty)
          const Text(
            'لا توجد فترة توزيع محسوبة على هذا البئر بعد.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          )
        else
          ..._cycles.map((cycle) {
            DistributionPartnerLine? mine;
            for (final line in cycle.partnerLines) {
              if (myPartnerId != null && line.partnerId == myPartnerId) {
                mine = line;
                break;
              }
            }

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surfaceSubtle,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'من ${_formatDate(cycle.periodStart)} '
                    'إلى ${_formatDate(cycle.periodEnd)}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: AppColors.deepBlue,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _row('حالة الفترة', _cycleStatusLabel(cycle.status)),
                  _row('إيراد الفترة', _money(cycle.eligibleRevenueYER)),
                  _row('مصروفات الفترة', _money(cycle.eligibleExpensesYER)),
                  _row('صافي قابل للتوزيع',
                      _money(cycle.distributableProfitYER)),
                  if (mine == null)
                    _note('لا سطر لك في هذه الفترة.')
                  else ...[
                    const Divider(height: 16),
                    _row('نسبتك في هذه الفترة', '${mine.profitPercent}%'),
                    _row('حصتك', _money(mine.grossShareYER)),
                    _row('المصروف لك', _money(mine.paidAmountYER)),
                    _row('المتبقي لك', _money(mine.remainingYER)),
                  ],
                ],
              ),
            );
          }),
      ],
    );
  }

  /// أسماء الشركاء ونِسبهم — §26 يعطيها للشريك. ولا تُعرض أرقام غيره
  /// المالية: ليست في نطاقه المُقرَّر، وعدم عرضها ليس إخفاء عطب.
  Widget _partnersSection() {
    final myPartnerId = _overview?.share?.partnerId;

    return _card(
      title: 'شركاء البئر ونِسبهم',
      children: [
        if (_partners.isEmpty)
          const Text(
            'لم يُعِد العقد أي شريك.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          )
        else
          ..._partners.map(
            (partner) => _row(
              partner.id == myPartnerId
                  ? '${partner.fullName} (أنت)'
                  : partner.fullName,
              '${partner.profitPercent}%',
            ),
          ),
      ],
    );
  }

  Widget _expensesSection() {
    return _card(
      title: 'مصروفات البئر',
      children: [
        if (_expenses.isEmpty)
          const Text(
            'لا مصروفات مسجَّلة.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          )
        else
          ..._expenses.map(
            (expense) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _row(
                    '${_formatDate(expense.spentAt)} — ${expense.categoryName}',
                    _money(expense.amountYER),
                  ),
                  if (expense.description.isNotEmpty)
                    Text(
                      expense.description,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                      ),
                    ),
                ],
              ),
            ),
          ),
        _note(
          'من سجّل المصروف وملاحظاته الداخلية خارج نطاق اطلاع الشريك، '
          'والخادم لا يعيدهما لك أصلًا.',
        ),
      ],
    );
  }

  Widget _farmersSection() {
    return _card(
      title: 'المزارعون وديونهم',
      children: [
        if (_farmers.isEmpty)
          const Text(
            'لا حسابات مزارعين على هذا البئر.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          )
        else
          ..._farmers.map(
            (farmer) => _row(
              '${farmer.fullName} (${farmer.publicCode})',
              _money(farmer.debtMinor),
              valueColor: farmer.debtMinor > 0
                  ? AppColors.error
                  : AppColors.textPrimary,
            ),
          ),
        _note('الدين = ما فُوتِر عليه ناقص ما خُصِّص من دفعاته.'),
      ],
    );
  }

  Widget _fuelSection() {
    return _card(
      title: 'الوقود والجرد',
      children: [
        if (_tanks.isEmpty)
          const Text(
            'لا خزانات وقود مسجَّلة.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          )
        else
          ..._tanks.map(
            (tank) => _row(
              tank.name,
              '${_liters(tank.currentBalanceMl)} من '
              '${_liters(tank.capacityMl)} لتر',
            ),
          ),
      ],
    );
  }

  Widget _footerNote() {
    final serverTime = _overview?.serverTime;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'آخر قراءة من الخادم: ${_formatTime(serverTime)}',
          style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
        ),
        const SizedBox(height: 4),
        const Text(
          'هذه الشاشة اطلاع فقط: لا يملك الشريك تعديلًا ولا إقرارًا في هذا '
          'الإصدار. والتحديث يجري عند فتح الشاشة وبالسحب — لا تحديث لحظيًّا.',
          style: TextStyle(
            fontSize: 11,
            color: AppColors.textSecondary,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

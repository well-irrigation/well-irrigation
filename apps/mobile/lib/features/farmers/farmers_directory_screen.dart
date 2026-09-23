import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/app_bootstrap_repository.dart';
import '../../core/identity/app_identity.dart';
import '../../core/api/operations_repository.dart';
import '../../core/session/offline_session_coordinator.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/currency_utils.dart';
import '../../core/utils/digit_utils.dart';
import '../../core/widgets/top_well_selector.dart';
import '../../core/widgets/well_loading_indicator.dart';
import 'farmer_detail_screen.dart';

/// شاشة دليل المزارعين والأراضي (UX-13 / 380 / ق-80 / ق-84 / ق-98)
class FarmersDirectoryScreen extends StatefulWidget {
  const FarmersDirectoryScreen({
    required this.identity,
    this.repository,
    this.coordinator,
    this.onWellChanged,
    this.onLogout,
    super.key,
  });

  final AppIdentity identity;
  final OperationsRepository? repository;
  final OfflineSessionCoordinator? coordinator;
  final ValueChanged<WellSummary>? onWellChanged;
  final VoidCallback? onLogout;

  @override
  State<FarmersDirectoryScreen> createState() => _FarmersDirectoryScreenState();
}

class _FarmersDirectoryScreenState extends State<FarmersDirectoryScreen> {
  late OperationsRepository _repo;

  late WellSummary _activeWell;

  String get _activeWellId => _activeWell.id;
  String get _activeWellName => _activeWell.name;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  String? _loadError;
  List<FarmerDirectoryEntry> _entries = [];
  late DateTime _currentWellDay;

  /// الفلتر المطبَّق على القائمة. كل خيار مبنيّ على حقل **يرسله الخادم** في
  /// عقد 099 — لا على رقم يشتقّه العميل (ق-99).
  _DirectoryFilter _filter = _DirectoryFilter.all;

  @override
  void initState() {
    super.initState();
    _activeWell = widget.identity.activeWell;

    _repo = widget.repository ?? const OperationsRepository();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<List<FarmerDirectoryEntry>> _getDurablePendingEntries(
    String wellId,
  ) async {
    final coordinator =
        widget.coordinator ?? OfflineSessionCoordinator.instance;
    try {
      final pendingList = await coordinator.pendingFarmers(
        accountId: widget.identity.accountId,
        wellId: wellId,
      );
      return pendingList
          .map(
            (f) => FarmerDirectoryEntry(
              id: '',
              fullName: f.fullName,
              publicCode: '',
              status: 'pending',
              farmsCount: 0,
              debtYER: 0,
              advanceYER: 0,
              sessionsCount: 0,
              hasOpenSession: false,
              phone: f.phone,
            ),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  List<FarmerDirectoryEntry> _mergeWithDurablePending(
    List<FarmerDirectoryEntry> serverEntries,
    List<FarmerDirectoryEntry> pendingEntries,
  ) {
    if (pendingEntries.isEmpty) return serverEntries;
    return [...pendingEntries, ...serverEntries];
  }

  Future<void> _loadData() async {
    final requestedWellId = _activeWellId;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    final pending = await _getDurablePendingEntries(requestedWellId);

    try {
      // قراءة واحدة تحمل الهوية والأراضي والمال وآخر سقي، **مرتَّبة من
      // الخادم** بآخر سقي (099). كانت قراءتين تُجمعان في العميل: قائمة
      // المزارعين ثم قائمة الأراضي، وعدّ الأراضي يُحسب هنا — فتقادم العدّاد
      // بمجرد إضافة أرض من شاشة أخرى.
      final data = await _repo.fetchFarmerDirectory(requestedWellId);

      if (mounted && requestedWellId == _activeWellId) {
        setState(() {
          _entries = _mergeWithDurablePending(data.entries, pending);
          _currentWellDay = data.currentDay;
          _isLoading = false;
        });
      }
    } catch (_) {
      // ق-99 / م-41C1: لا بيانات بديلة — الفشل يظهر للمستخدم صريحًا.
      if (mounted && requestedWellId == _activeWellId) {
        if (pending.isNotEmpty) {
          setState(() {
            _entries = pending;
            _currentWellDay = DateTime.now();
            _isLoading = false;
            _loadError = null;
          });
        } else {
          setState(() {
            _entries = [];
            _isLoading = false;
            _loadError = 'تعذّر تحميل المزارعين والأراضي. تحقق من الاتصال ثم أعد المحاولة.';
          });
        }
      }
    }
  }

  Future<void> _refreshDataQuietly() async {
    final requestedWellId = _activeWellId;
    final pending = await _getDurablePendingEntries(requestedWellId);
    try {
      final data = await _repo.fetchFarmerDirectory(requestedWellId);
      if (mounted && requestedWellId == _activeWellId) {
        setState(() {
          _entries = _mergeWithDurablePending(data.entries, pending);
          _currentWellDay = data.currentDay;
        });
      }
    } catch (_) {
      // وضع غير متصل: الحفاظ على البيانات المعروضة دون قلب الشاشة إلى خطأ
    }
  }

  /// البحث والفلترة محليًّا على ما جاء من الخادم.
  ///
  /// **ولا إعادة ترتيب هنا:** الخادم يرتّب بآخر سقي ويُعلن أساسه في الحمولة،
  /// وإعادة الترتيب في العميل تجعل شاشتين تعرضان الترتيب نفسه بأساسين
  /// مختلفين. الفلترة تُخفي عناصر ولا تُبدّل تسلسلها.
  List<FarmerDirectoryEntry> get _visibleEntries {
    final q = normalizeArabicDigits(_searchQuery.trim().toLowerCase());

    return _entries
        .where((e) {
          if (q.isNotEmpty) {
            final matchName = e.fullName.toLowerCase().contains(q);
            final matchCode = e.publicCode.toLowerCase().contains(q);
            final matchPhone = e.phone != null && e.phone!.contains(q);
            if (!matchName && !matchCode && !matchPhone) return false;
          }

          return switch (_filter) {
            _DirectoryFilter.all => true,
            _DirectoryFilter.withDebt => e.hasDebt,
            _DirectoryFilter.withAdvance => e.advanceYER > 0,
            _DirectoryFilter.irrigatingNow => e.hasOpenSession,
            _DirectoryFilter.neverIrrigated => e.hasNeverIrrigated,
            _DirectoryFilter.withoutFarms => e.farmsCount == 0,
          };
        })
        .toList(growable: false);
  }

  /// عدد المطابقين لكل فلتر — يُحسب على القائمة الكاملة لا على المعروضة،
  /// فالرقم على الشريحة يقول «كم يوجد» لا «كم بقي بعد فلتر آخر».
  int _countFor(_DirectoryFilter filter) {
    return switch (filter) {
      _DirectoryFilter.all => _entries.length,
      _DirectoryFilter.withDebt => _entries.where((e) => e.hasDebt).length,
      _DirectoryFilter.withAdvance =>
        _entries.where((e) => e.advanceYER > 0).length,
      _DirectoryFilter.irrigatingNow =>
        _entries.where((e) => e.hasOpenSession).length,
      _DirectoryFilter.neverIrrigated =>
        _entries.where((e) => e.hasNeverIrrigated).length,
      _DirectoryFilter.withoutFarms =>
        _entries.where((e) => e.farmsCount == 0).length,
    };
  }

  void _showAddFarmerDialog() {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final notesController = TextEditingController();
    bool isSubmitting = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: const [
              Icon(Icons.person_add_outlined, color: AppColors.deepBlue),
              SizedBox(width: 8),
              Text(
                'إضافة مزارع جديد',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  // تلميح عام لا اسم شخص: «مثال: محمد عبدالله الشامي» اسمٌ
                  // كامل يظنّه المستعجل قيمةً مكتوبة فيضغط حفظ، أو يظنّه اسمًا
                  // مسجَّلًا سلفًا. والتلميح يوصِف الشكل المطلوب لا يعطي قيمة.
                  decoration: const InputDecoration(
                    labelText: 'الاسم الكامل للمزارع *',
                    hintText: 'الاسم الثلاثي',
                    prefixIcon: Icon(Icons.person_outline, size: 20),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  // الرقم يُكتب ويُقرأ من اليسار دائمًا: في سياق عربي يقع
                  // المفتاح `+967` بصريًّا في غير موضعه، فيُقرأ الرقم معكوسًا
                  // ومن يقرؤه ليتّصل يخطئ. عزلُ الحقل بـ`ltr` يمنع ذلك.
                  textDirection: TextDirection.ltr,
                  textAlign: TextAlign.left,
                  inputFormatters: [
                    ArabicToEnglishDigitsFormatter(),
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(9),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'رقم الهاتف (9 أرقام)',
                    hintText: '7XXXXXXXX',
                    prefixText: '+967 ',
                    prefixIcon: Icon(Icons.phone_outlined, size: 20),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: notesController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'ملاحظات إضافية (اختياري)',
                    hintText: 'موقع الأرض أو تفاصيل إضافية...',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSubmitting
                  ? null
                  : () => Navigator.of(dialogCtx).pop(),
              child: const Text(
                'إلغاء',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.deepBlue,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: isSubmitting
                  ? null
                  : () async {
                      final name = nameController.text.trim();
                      if (name.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('يرجى إدخال اسم المزارع'),
                          ),
                        );
                        return;
                      }

                      setDialogState(() => isSubmitting = true);
                      try {
                        final coordinator =
                            widget.coordinator ??
                            OfflineSessionCoordinator.instance;
                        await coordinator.enqueueFarmer(
                          accountId: widget.identity.accountId,
                          wellId: _activeWellId,
                          fullName: name,
                          phone: phoneController.text.trim().isNotEmpty
                              ? phoneController.text.trim()
                              : null,
                          notes: notesController.text.trim().isNotEmpty
                              ? notesController.text.trim()
                              : null,
                        );

                        if (dialogCtx.mounted) {
                          Navigator.of(dialogCtx).pop();
                        }

                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'تم حفظ المزارع محلياً وقيد المزامنة ⏳',
                              ),
                            ),
                          );
                          _refreshDataQuietly();
                        }
                      } catch (e) {
                        setDialogState(() => isSubmitting = false);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('حدث خطأ أثناء الإضافة: $e'),
                            ),
                          );
                        }
                      }
                    },
              child: isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text('حفظ المزارع'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _visibleEntries;

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: TopWellSelector(
          wells: widget.identity.wells,
          activeWell: _activeWell,
          subtitle: 'دليل المزارعين والأراضي',
          onWellChanged: (newWell) {
            setState(() {
              _activeWell = newWell;
            });
            _loadData();
            if (widget.onWellChanged != null) {
              widget.onWellChanged!(newWell);
            }
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.textSecondary),
            tooltip: 'تحديث',
            onPressed: _loadData,
          ),
          if (widget.onLogout != null)
            IconButton(
              icon: const Icon(Icons.logout, color: AppColors.textSecondary),
              tooltip: 'تسجيل الخروج',
              onPressed: widget.onLogout,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.deepBlue,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add),
        label: const Text(
          'مزارع جديد',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        onPressed: _showAddFarmerDialog,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 1. حقل البحث الفوري
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'ابحث باسم المزارع، رقم الهاتف، أو الكود...',
                  hintStyle: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13,
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    color: AppColors.waterBlue,
                    size: 20,
                  ),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: AppColors.surface,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (val) => setState(() => _searchQuery = val),
              ),
            ),

            // 2. شريط الفلترة — كل شريحة سؤالٌ يسأله المالك فعلًا
            _FilterBar(
              active: _filter,
              countFor: _countFor,
              onChanged: (f) => setState(() => _filter = f),
            ),

            // 3. شريط الإحصائيات
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(
                  bottom: BorderSide(color: AppColors.border, width: 0.5),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.people_outline,
                        size: 16,
                        color: AppColors.deepBlue,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        // «معروض» لا «مسجل»: الرقم يتبع الفلتر والبحث، فوصفه
                        // بـ«مسجل» يجعله يكذب بمجرد تصفية القائمة.
                        _filter == _DirectoryFilter.all && _searchQuery.isEmpty
                            ? '${entries.length} مزارع مسجل'
                            : '${entries.length} معروض من ${_entries.length}',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: AppColors.deepBlue,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    // مجموع الأراضي من حقل الخادم لكل مزارع، لا من قراءة
                    // ثانية تُجمع في العميل — فلا يتقادم بإضافة أرض.
                    '${_entries.fold<int>(0, (sum, e) => sum + e.farmsCount)} أرض زراعية',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),

            // 4. قائمة المزارعين
            Expanded(
              child: _isLoading
                  ? const Center(child: WellLoadingIndicator(size: 72))
                  : _loadError != null
                  ? _buildErrorState()
                  : entries.isEmpty
                  ? _buildEmptyState()
                  : RefreshIndicator(
                      onRefresh: _loadData,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          return _buildFarmerCard(entries[index]);
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 56,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              _loadError!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _loadData,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.person_off_outlined,
                size: 36,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'لا يوجد مزارعون',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.deepBlue,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'لم يتم العثور على مزارعين يطابقون شروط البحث، أو لم يتم تسجيل مزارعين في هذا البئر بعد.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFarmerCard(FarmerDirectoryEntry entry) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () async {
          if (entry.status == 'pending' || entry.id.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('المزارع محفوظ محلياً وبانتظار اكتمال المزامنة'),
              ),
            );
            return;
          }
          // انتظار الرجوع ثم إعادة القراءة: أضاف المالك أرضًا من شاشة
          // التفاصيل في 2026-09-04 فبقي العدّاد يقول «0 أرض زراعية» — الرقم
          // كان صحيحًا لحظة قراءته، والخطأ أنه لم يُقرأ ثانيةً. غياب كاذب:
          // العين ترى صفرًا والبيانات موجودة (ق-113).
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => FarmerDetailScreen(
                wellId: _activeWellId,
                farmerAccountId: entry.id,
                wellName: _activeWellName,
                accountId: widget.identity.accountId,
                canCreateFarm: _activeWell.isOwner,
                repository: _repo,
                coordinator: widget.coordinator,
              ),
            ),
          );
          if (mounted) {
            await _refreshDataQuietly();
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: entry.hasOpenSession
                    ? AppColors.agriculturalGreen.withValues(alpha: 0.16)
                    : AppColors.waterBlue.withValues(alpha: 0.12),
                child: entry.hasOpenSession
                    // جلسة جارية = حقيقة تشغيلية تسبق الحرف الأول في الأهمية.
                    ? const Icon(
                        Icons.water_drop,
                        color: AppColors.agriculturalGreen,
                        size: 22,
                      )
                    : Text(
                        entry.fullName.isNotEmpty
                            ? entry.fullName.substring(0, 1)
                            : 'م',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.deepBlue,
                        ),
                      ),
              ),
              const SizedBox(width: 14),

              // الاسم والهاتف وعدد الأراضي وآخر سقي.
              //
              // **والكود `FWA-…` لا يُعرض هنا:** معرّف داخلي بأحرف لاتينية في
              // تطبيق عربي، ولا يقرؤه مستخدم عادي ولا يفعل به شيئًا. أُبقي في
              // نافذة سند القبض وحدها — هناك ورقة تُطبع وتُطابَق فيخدم غرضًا.
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.fullName,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (entry.status == 'pending')
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.waterBlue.withValues(
                                alpha: 0.10,
                              ),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'محفوظ محلياً ⏳',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: AppColors.waterBlue,
                              ),
                            ),
                          ),
                        if (entry.hasDebt)
                          // الدَين رقمٌ يقرؤه المالك ليقرّر، فيظهر في القائمة
                          // لا داخل الشاشة التالية وحدها.
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.error.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'عليه ${CurrencyUtils.formatAmount(entry.debtYER)}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: AppColors.error,
                              ),
                            ),
                          )
                        else if (entry.advanceYER > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.waterBlue.withValues(
                                alpha: 0.10,
                              ),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'له ${CurrencyUtils.formatAmount(entry.advanceYER)}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: AppColors.waterBlue,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (entry.phone != null && entry.phone!.isNotEmpty)
                          _PhoneChip(phone: entry.phone!)
                        else
                          const Text(
                            'بدون هاتف',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textMuted,
                            ),
                          ),
                        const SizedBox(width: 12),
                        Icon(
                          Icons.landscape_outlined,
                          size: 13,
                          // الأخضر لون نجاح في الهوية، فصفرٌ أخضر يقول «تمّ»
                          // ولا شيء تمّ. الصفر يبقى محايدًا.
                          color: entry.farmsCount > 0
                              ? AppColors.agriculturalGreen
                              : AppColors.textMuted,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${entry.farmsCount} ${entry.farmsCount == 1 ? "أرض" : "أراضي"}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: entry.farmsCount > 0
                                ? AppColors.agriculturalGreen
                                : AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // آخر سقي: الأساس الذي يرتّب به الخادم، فيُعرض ليُفهم
                    // الترتيب. واليوم من الخادم بمنطقة الجهة لا مشتقًّا هنا.
                    _LastIrrigationLine(
                      entry: entry,
                      currentWellDay: _currentWellDay,
                    ),
                  ],
                ),
              ),

              const Icon(Icons.chevron_left, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// رقم هاتف يُعرض بالاتجاه الصحيح، والضغط عليه ينسخه.
///
/// **الاتجاه:** الرقم مع مفتاح الدولة وحدةٌ لاتينية داخل نصّ عربي. وبلا عزل
/// صريح يقع `+967` بصريًّا في غير موضعه فيُقرأ الرقم معكوسًا — ومن يقرؤه
/// ليتّصل يخطئ. مقيس على الجهاز في 2026-09-04.
///
/// **والنسخ لا الاتصال:** فتح تطبيق الهاتف مباشرةً يحتاج حزمة `url_launcher`،
/// وتثبيتها يحتاج شبكة لا تصل من بيئة المساعد. فالنسخ خطوة صادقة متاحة الآن،
/// ولا نُظهر زرّ اتصال لا يعمل: زرٌّ يُعلن ما لا يفعله أسوأ من غيابه.
class _PhoneChip extends StatelessWidget {
  const _PhoneChip({required this.phone});

  final String phone;

  @override
  Widget build(BuildContext context) {
    final full = '+967$phone';
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: full));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('نُسخ الرقم: $full'),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Row(
          children: [
            const Icon(
              Icons.phone_outlined,
              size: 13,
              color: AppColors.waterBlue,
            ),
            const SizedBox(width: 4),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text(
                full,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.waterBlue,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// خيارات فلترة الدليل — كل خيار سؤالٌ يسأله المالك في يومه.
///
/// وكل واحد مبنيّ على حقل **يرسله الخادم** في عقد 099: الدَين والرصيد المقدَّم
/// من عرض الأرصدة، وآخر جلسة منتهية، وحضور جلسة جارية، وعدد الأراضي. فلا فلتر
/// على رقم يشتقّه العميل (ق-99).
enum _DirectoryFilter {
  all('الكل', Icons.people_outline),
  irrigatingNow('يسقي الآن', Icons.water_drop),
  withDebt('عليه مستحقات', Icons.receipt_long),
  withAdvance('له رصيد', Icons.account_balance_wallet_outlined),
  withoutFarms('بلا أراضٍ', Icons.landscape_outlined),
  neverIrrigated('لم يسقِ بعد', Icons.history_toggle_off);

  const _DirectoryFilter(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// شريط شرائح الفلترة، كل شريحة باسمها وعددها.
///
/// العدد على الشريحة يُحسب على القائمة **الكاملة**: فالرقم يقول «كم يوجد» لا
/// «كم بقي بعد فلتر آخر» — ورقمٌ يتغيّر بتغيّر فلتر غيره يُقرأ خطأً.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.active,
    required this.countFor,
    required this.onChanged,
  });

  final _DirectoryFilter active;
  final int Function(_DirectoryFilter) countFor;
  final ValueChanged<_DirectoryFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.only(bottom: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            for (final filter in _DirectoryFilter.values) ...[
              if (filter != _DirectoryFilter.values.first)
                const SizedBox(width: 8),
              _FilterChip(
                filter: filter,
                count: countFor(filter),
                isActive: filter == active,
                onTap: () => onChanged(filter),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.filter,
    required this.count,
    required this.isActive,
    required this.onTap,
  });

  final _DirectoryFilter filter;
  final int count;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // شريحة بصفر مطابق تبقى قابلة للضغط ولا تُخفى: إخفاؤها يجعل الشريط
    // يتبدّل شكله مع البيانات، فيفقد المالك موضع ما يبحث عنه.
    final isEmpty = count == 0;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? AppColors.deepBlue : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive ? AppColors.deepBlue : AppColors.border,
          ),
        ),
        child: Row(
          children: [
            Icon(
              filter.icon,
              size: 14,
              color: isActive
                  ? Colors.white
                  : (isEmpty ? AppColors.textMuted : AppColors.deepBlue),
            ),
            const SizedBox(width: 6),
            Text(
              filter.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: isActive
                    ? Colors.white
                    : (isEmpty ? AppColors.textMuted : AppColors.textPrimary),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: isActive ? Colors.white70 : AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// سطر «آخر سقي» — الأساس الذي يرتّب به الخادم، فيُعرض ليُفهم الترتيب.
///
/// **واليوم من الخادم لا مشتقًّا هنا:** العقد يعيد `last_session_day` محسوبًا
/// بمنطقة الجهة (098)، فلا يختلف «أمس» باختلاف منطقة الجهاز. وحساب الفارق
/// بالأيام يجري على ذلك اليوم لا على اللحظة الخام.
class _LastIrrigationLine extends StatelessWidget {
  const _LastIrrigationLine({
    required this.entry,
    required this.currentWellDay,
  });

  final FarmerDirectoryEntry entry;
  final DateTime currentWellDay;

  @override
  Widget build(BuildContext context) {
    if (entry.hasOpenSession) {
      return const Row(
        children: [
          Icon(
            Icons.play_circle_fill,
            size: 13,
            color: AppColors.agriculturalGreen,
          ),
          SizedBox(width: 4),
          Text(
            'جلسة سقي جارية الآن',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: AppColors.agriculturalGreen,
            ),
          ),
        ],
      );
    }

    final day = entry.lastSessionDay;
    if (day == null) {
      // «لم يسقِ بعد» حقيقة صريحة، لا تاريخٌ مُلفَّق ولا شرطة صامتة.
      return const Row(
        children: [
          Icon(Icons.history_toggle_off, size: 13, color: AppColors.textMuted),
          SizedBox(width: 4),
          Text(
            'لم يسقِ بعد',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
      );
    }

    return Row(
      children: [
        const Icon(Icons.schedule, size: 13, color: AppColors.textSecondary),
        const SizedBox(width: 4),
        Text(
          'آخر سقي: ${_relativeLabel(day, currentWellDay)}',
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    );
  }

  /// وصف الفارق بالأيام. والتاريخ الكامل يظهر بعد أسبوع: «قبل 40 يومًا» أصعب
  /// قراءةً من تاريخ صريح.
  static String _relativeLabel(DateTime day, DateTime currentWellDay) {
    final normalizedToday = DateTime(
      currentWellDay.year,
      currentWellDay.month,
      currentWellDay.day,
    );
    final normalizedDay = DateTime(day.year, day.month, day.day);
    final diff = normalizedToday.difference(normalizedDay).inDays;

    if (diff <= 0) return 'اليوم';
    if (diff == 1) return 'أمس';
    if (diff < 7) return 'قبل $diff أيام';
    return '${normalizedDay.year}-'
        '${normalizedDay.month.toString().padLeft(2, '0')}-'
        '${normalizedDay.day.toString().padLeft(2, '0')}';
  }
}

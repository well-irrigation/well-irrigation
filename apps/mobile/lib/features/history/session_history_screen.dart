import 'package:flutter/material.dart';

import '../../core/api/app_bootstrap_repository.dart';
import '../../core/api/operations_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/digit_utils.dart';
import '../../core/widgets/currency_display.dart';
import '../../core/widgets/top_well_selector.dart';
import 'session_detail_screen.dart';

/// شاشة سجل جلسات السقي (UX-13 / ق-98 / 373–376)
class SessionHistoryScreen extends StatefulWidget {
  const SessionHistoryScreen({
    required this.wellName,
    this.wellId,
    this.wells = const [],
    this.onWellChanged,
    this.onLogout,
    this.repository,
    super.key,
  });

  final String wellName;
  final String? wellId;
  final List<WellSummary> wells;
  final ValueChanged<WellSummary>? onWellChanged;
  final VoidCallback? onLogout;
  final OperationsRepository? repository;

  @override
  State<SessionHistoryScreen> createState() => _SessionHistoryScreenState();
}

class _SessionHistoryScreenState extends State<SessionHistoryScreen> {
  late OperationsRepository _repo;

  String? _activeWellId;
  String _activeWellName = '';
  String _selectedFilter = 'all'; // 'all', 'today', 'week', 'month', 'unpaid'
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = true;
  String? _loadError;
  List<SessionHistoryItem> _allSessions = [];

  @override
  void initState() {
    super.initState();
    _activeWellName = widget.wellName;
    _activeWellId = widget.wellId ?? (widget.wells.isNotEmpty ? widget.wells.first.id : null);

    _repo = widget.repository ?? const OperationsRepository();
    _loadSessions();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadSessions() async {
    if (_activeWellId == null) return;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final sessions = await _repo.fetchSessionHistory(
        wellId: _activeWellId!,
        filter: _selectedFilter,
      );
      if (mounted) {
        setState(() {
          _allSessions = sessions;
          _isLoading = false;
        });
      }
    } catch (_) {
      // م-41C2 / ق-99: لا سجل تجريبي — الفشل يظهر صريحًا مع إعادة المحاولة.
      if (mounted) {
        setState(() {
          _allSessions = [];
          _isLoading = false;
          _loadError = 'تعذّر تحميل سجل الجلسات. تحقق من الاتصال ثم أعد المحاولة.';
        });
      }
    }
  }

  List<SessionHistoryItem> get _filteredSessions {
    if (_searchQuery.trim().isEmpty) {
      return _allSessions;
    }
    final q = normalizeArabicDigits(_searchQuery.trim().toLowerCase());
    return _allSessions.where((s) {
      final matchFarmer = s.farmerName.toLowerCase().contains(q);
      final matchCode = s.farmerCode.toLowerCase().contains(q);
      final matchFarm = s.farmName.toLowerCase().contains(q);
      final matchEnergy = s.energySource.toLowerCase().contains(q);
      return matchFarmer || matchCode || matchFarm || matchEnergy;
    }).toList();
  }

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0 && minutes > 0) {
      return '$hours س و $minutes د';
    } else if (hours > 0) {
      return '$hours ساعة';
    } else {
      return '$minutes دقيقة';
    }
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final isYesterday = dt.year == now.year && dt.month == now.month && dt.day == now.day - 1;

    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final period = dt.hour >= 12 ? 'م' : 'ص';
    final minute = dt.minute.toString().padLeft(2, '0');
    final timeStr = '$hour:$minute $period';

    if (isToday) return 'اليوم $timeStr';
    if (isYesterday) return 'أمس $timeStr';
    return '${dt.year}/${dt.month}/${dt.day} • $timeStr';
  }

  @override
  Widget build(BuildContext context) {
    final activeWellSummary = widget.wells.firstWhere(
      (w) => w.id == _activeWellId,
      orElse: () => WellSummary(
        id: _activeWellId ?? 'well-1',
        tenantId: 'tenant-1',
        name: _activeWellName,
        status: 'active',
        roles: const ['owner', 'operator'],
      ),
    );

    final displayedSessions = _filteredSessions;
    final totalSecs = displayedSessions.fold<int>(0, (sum, s) => sum + s.billableSeconds);
    final totalAmount = displayedSessions.fold<int>(0, (sum, s) => sum + s.totalAmountYER);

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: TopWellSelector(
          wells: widget.wells.isNotEmpty ? widget.wells : [activeWellSummary],
          activeWell: activeWellSummary,
          subtitle: 'سجل جلسات السقي والتاريخ',
          onWellChanged: (newWell) {
            setState(() {
              _activeWellId = newWell.id;
              _activeWellName = newWell.name;
            });
            _loadSessions();
            if (widget.onWellChanged != null) {
              widget.onWellChanged!(newWell);
            }
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.textSecondary),
            tooltip: 'تحديث السجل',
            onPressed: _loadSessions,
          ),
          if (widget.onLogout != null)
            IconButton(
              icon: const Icon(Icons.logout, color: AppColors.textSecondary),
              tooltip: 'تسجيل الخروج',
              onPressed: widget.onLogout,
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // 1. شريط البحث والفلاتر
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                children: [
                  TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'ابحث باسم المزارع، الكود، أو الأرض...',
                      hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                      prefixIcon: const Icon(Icons.search, color: AppColors.waterBlue, size: 20),
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
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (val) => setState(() => _searchQuery = val),
                  ),
                  const SizedBox(height: 10),

                  // أزرار التصفية السريعة
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildFilterChip('الكل', 'all'),
                        _buildFilterChip('اليوم', 'today'),
                        _buildFilterChip('هذا الأسبوع', 'week'),
                        _buildFilterChip('هذا الشهر', 'month'),
                        _buildFilterChip('غير مسددة', 'unpaid', isAlert: true),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // 2. شريط الإحصائيات المختصر
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.history, size: 16, color: AppColors.deepBlue),
                      const SizedBox(width: 6),
                      Text(
                        '${displayedSessions.length} جلسة',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.deepBlue),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '• ${_formatDuration(totalSecs)}',
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text(
                        'الإجمالي: ',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                      CurrencyDisplay(
                        amount: totalAmount,
                        showTafqeet: false,
                        amountStyle: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppColors.deepBlue,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // 3. قائمة الجلسات
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _loadError != null
                      ? _buildErrorState()
                      : displayedSessions.isEmpty
                      ? _buildEmptyState()
                      : RefreshIndicator(
                          onRefresh: _loadSessions,
                          child: ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: displayedSessions.length,
                            itemBuilder: (context, index) {
                              final session = displayedSessions[index];
                              return _buildSessionCard(session);
                            },
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label, String value, {bool isAlert = false}) {
    final isSelected = _selectedFilter == value;
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: FilterChip(
        selected: isSelected,
        label: Text(label),
        labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected
              ? Colors.white
              : (isAlert ? AppColors.error : AppColors.textPrimary),
        ),
        backgroundColor: isAlert ? AppColors.error.withValues(alpha: 0.08) : AppColors.surface,
        selectedColor: isAlert ? AppColors.error : AppColors.waterBlue,
        checkmarkColor: Colors.white,
        side: BorderSide(
          color: isSelected
              ? (isAlert ? AppColors.error : AppColors.waterBlue)
              : (isAlert ? AppColors.error.withValues(alpha: 0.3) : AppColors.border),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        onSelected: (selected) {
          if (selected) {
            setState(() => _selectedFilter = value);
            _loadSessions();
          }
        },
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
              onPressed: _loadSessions,
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
              child: const Icon(Icons.history_toggle_off, size: 36, color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            const Text(
              'لا توجد جلسات مطابقة',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
            ),
            const SizedBox(height: 6),
            const Text(
              'لم يتم العثور على أي جلسات سقي تطابق خيارات التصفية والبحث المحددة.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionCard(SessionHistoryItem session) {
    Color badgeColor;
    String badgeText;
    // ق-99: الجلسة غير المفوترة ليست «غير مدفوعة» — حالة مستقلة بلا مبلغ.
    if (!session.hasCharge) {
      badgeColor = AppColors.textMuted;
      badgeText = 'غير مفوترة بعد';
    } else if (session.isFullySettled) {
      badgeColor = AppColors.agriculturalGreen;
      badgeText = 'خالص بالكامل ✅';
    } else if (session.paymentStatus == 'partial') {
      badgeColor = AppColors.warning;
      badgeText = 'دفعة جزئية (متبقي ${session.remainingAmountYER} ريال)';
    } else {
      badgeColor = AppColors.error;
      badgeText = 'آجل / غير مدفوع 🔴';
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border, width: 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SessionDetailScreen(
                sessionId: session.id,
                wellName: _activeWellName,
                repository: _repo,
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ترويسة البطاقة: المزارع وكوده + مصدر الطاقة
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppColors.waterBlue.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.person, color: AppColors.waterBlue, size: 18),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                session.farmerName,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              Text(
                                '${session.farmName} • كود: ${session.farmerCode}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // شارة مصدر الطاقة
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          session.energySourceCode == 'solar' ? '☀️' : '⛽',
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          session.energySource,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.deepBlue,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),
              const Divider(height: 1, color: AppColors.surfaceSubtle),
              const SizedBox(height: 12),

              // بيانات المدة والمستحق المالي
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'مدة السقي الفعلية',
                        style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(Icons.timer_outlined, size: 14, color: AppColors.waterBlue),
                          const SizedBox(width: 4),
                          Text(
                            _formatDuration(session.billableSeconds),
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppColors.deepBlue,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text(
                        'إجمالي الفاتورة',
                        style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                      ),
                      const SizedBox(height: 2),
                      CurrencyDisplay(
                        amount: session.totalAmountYER,
                        amountStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppColors.deepBlue,
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // التذييل: حالة السداد والتاريخ
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: badgeColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: badgeColor.withValues(alpha: 0.3), width: 0.5),
                    ),
                    child: Text(
                      badgeText,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: badgeColor,
                      ),
                    ),
                  ),
                  Text(
                    _formatDate(session.startedAt),
                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

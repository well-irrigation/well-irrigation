import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/app_bootstrap_repository.dart';
import '../../core/identity/app_identity.dart';
import '../../core/theme/app_colors.dart';
import 'widgets/announcement_banner_slider.dart';
import 'widgets/home_bottom_nav_bar.dart';

/// الشاشة الرئيسية المحدثة للمالك وحسابات الأدوار المتعددة (UX-05 / UX-06 / UX-15 / ق-87 / ق-127)
///
/// صُممت وفق الهيكل المعياري لتطبيق "جيب" المصرفي والتشغيلي (1:1):
/// 1. الرأس: تحية ترحيبية باسم المالك + زران مربّعان ناعما الحواف (Squircle) للإعدادات والخروج.
/// 2. بطاقة البئر المصرفية الذكية (Card Carousel) بنسب بطاقة الدفع مع مؤشرات نقطية تحتها.
/// 3. شريط المستجدات والتنبيهات العريض (Banner Slider) مباشرة أسفل البطاقة.
/// 4. شبكة الخدمات المتكاملة 3×3 (9 بلاطات ناعمة تملأ الثلث السفلي بارتياح تام).
/// 5. شريط تنقل سفلي مقوس مع زر عائم وسطي بارز للتشغيل السريع.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.identity,
    this.onWellChanged,
    this.onNavigateToOperations,
    this.onNavigateToHistory,
    this.onNavigateToFarmers,
    this.onNavigateToExpenses,
    this.onNavigateToFuelInventory,
    this.onNavigateToPartners,
    this.onNavigateToWellManagement,
    this.onNavigateToReports,
    this.onNavigateToMoreSettings,
    this.onLogout,
    super.key,
  });

  final AppIdentity identity;
  final ValueChanged<WellSummary>? onWellChanged;
  final VoidCallback? onNavigateToOperations;
  final VoidCallback? onNavigateToHistory;
  final VoidCallback? onNavigateToFarmers;
  final VoidCallback? onNavigateToExpenses;
  final VoidCallback? onNavigateToFuelInventory;
  final VoidCallback? onNavigateToPartners;
  final VoidCallback? onNavigateToWellManagement;
  final VoidCallback? onNavigateToReports;
  final VoidCallback? onNavigateToMoreSettings;
  final VoidCallback? onLogout;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final PageController _cardPageController;
  late int _activeCardIndex;

  int _activeWellIndex(AppIdentity identity) {
    final index = identity.wells.indexWhere(
      (well) => well.id == identity.activeWell.id,
    );
    return index < 0 ? 0 : index;
  }

  @override
  void initState() {
    super.initState();
    _activeCardIndex = _activeWellIndex(widget.identity);
    _cardPageController = PageController(
      initialPage: _activeCardIndex,
      viewportFraction: 0.94,
    );
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextIndex = _activeWellIndex(widget.identity);
    if (nextIndex == _activeCardIndex) return;
    _activeCardIndex = nextIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _cardPageController.hasClients) {
        _cardPageController.jumpToPage(nextIndex);
      }
    });
  }

  @override
  void dispose() {
    _cardPageController.dispose();
    super.dispose();
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour >= 4 && hour < 12) {
      return 'صباح الخير';
    } else {
      return 'مساء الخير';
    }
  }

  @override
  Widget build(BuildContext context) {
    final wells = widget.identity.wells.isNotEmpty
        ? widget.identity.wells
        : [widget.identity.activeWell];

    final displayName = widget.identity.displayName.isNotEmpty
        ? widget.identity.displayName
        : 'المالك';

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await Future.delayed(const Duration(milliseconds: 350));
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. الرأس والتحية بنمط Squircle المرجعي
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _getGreeting(),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.deepBlue,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          displayName,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        _SquircleHeaderButton(
                          icon: Icons.settings_outlined,
                          tooltip: 'الإعدادات',
                          onTap: widget.onNavigateToMoreSettings,
                        ),
                        const SizedBox(width: 8),
                        _SquircleHeaderButton(
                          icon: Icons.logout_rounded,
                          tooltip: 'تسجيل الخروج',
                          onTap: widget.onLogout,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // 2. بطاقة البئر المصرفية الذكية (Card Carousel)
                SizedBox(
                  height: 170,
                  child: PageView.builder(
                    controller: _cardPageController,
                    itemCount: wells.length,
                    onPageChanged: (index) {
                      setState(() => _activeCardIndex = index);
                      if (widget.onWellChanged != null &&
                          index < wells.length) {
                        widget.onWellChanged!(wells[index]);
                      }
                    },
                    itemBuilder: (context, index) {
                      final well = wells[index];
                      return _WellCreditCard(well: well);
                    },
                  ),
                ),
                const SizedBox(height: 4),

                // نقاط التحديد للبطاقات (Dots Indicator)
                if (wells.length > 1)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(wells.length, (index) {
                      final isSelected = _activeCardIndex == index;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: isSelected ? 16 : 6,
                        height: 5,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppColors.waterBlue
                              : AppColors.border.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      );
                    }),
                  )
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 16,
                        height: 5,
                        decoration: BoxDecoration(
                          color: AppColors.waterBlue,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        width: 6,
                        height: 5,
                        decoration: BoxDecoration(
                          color: AppColors.border.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        width: 6,
                        height: 5,
                        decoration: BoxDecoration(
                          color: AppColors.border.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 8),

                // 3. شريط المستجدات والتنبيهات العريض (Banner Slider)
                if (widget.identity.isOwner) ...[
                  AnnouncementBannerSlider(
                    onStartOperations: widget.onNavigateToOperations,
                    onViewFarmers: widget.onNavigateToFarmers,
                    onViewHistory: widget.onNavigateToHistory,
                    onViewReports: widget.onNavigateToReports,
                  ),
                  const SizedBox(height: 10),
                ],

                // 4. شبكة الخدمات المتكاملة 3×3 (9 بلاطات متراصة بأرضيات ناعمة)
                _ServicesGrid3x3(
                  isOwner: widget.identity.isOwner,
                  onNavigateToOperations: widget.onNavigateToOperations,
                  onNavigateToHistory: widget.onNavigateToHistory,
                  onNavigateToFarmers: widget.onNavigateToFarmers,
                  onNavigateToExpenses: widget.onNavigateToExpenses,
                  onNavigateToFuelInventory: widget.onNavigateToFuelInventory,
                  onNavigateToPartners: widget.onNavigateToPartners,
                  onNavigateToWellManagement: widget.onNavigateToWellManagement,
                  onNavigateToReports: widget.onNavigateToReports,
                  onNavigateToMoreSettings: widget.onNavigateToMoreSettings,
                ),

                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: HomeBottomNavBar(
        selectedIndex: 0,
        isOperatorMode: widget.identity.isOperator && !widget.identity.isOwner,
        onNavigateToOperations: widget.onNavigateToOperations,
        onNavigateToHistory: widget.onNavigateToHistory,
        onNavigateToReports: widget.onNavigateToReports,
        onNavigateToMoreSettings: widget.onNavigateToMoreSettings,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: SizedBox(
        height: 58,
        width: 58,
        child: FloatingActionButton(
          onPressed: () {
            if (widget.onNavigateToOperations != null) {
              HapticFeedback.lightImpact();
              widget.onNavigateToOperations!();
            }
          },
          backgroundColor: AppColors.waterBlue,
          foregroundColor: Colors.white,
          elevation: 6,
          tooltip: 'بدء تشغيل سقي سريع',
          shape: const CircleBorder(),
          child: const Icon(
            Icons.water_drop_rounded,
            color: Colors.white,
            size: 30,
          ),
        ),
      ),
    );
  }
}

/// زر الرأس المستدير الحواف (Squircle)
class _SquircleHeaderButton extends StatelessWidget {
  const _SquircleHeaderButton({
    required this.icon,
    required this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.6)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            if (onTap != null) {
              HapticFeedback.lightImpact();
              onTap!();
            }
          },
          child: Tooltip(
            message: tooltip,
            child: Icon(icon, color: AppColors.deepBlue, size: 20),
          ),
        ),
      ),
    );
  }
}

/// بطاقة البئر المصرفية الذكية (Smart Well Card)
class _WellCreditCard extends StatelessWidget {
  const _WellCreditCard({required this.well});

  final WellSummary well;

  String get _roleLabel {
    if (well.isOwner) return 'مالك البئر';
    if (well.isOperator) return 'مشغّل معتمد';
    if (well.isManager) return 'مدير البئر';
    if (well.isPartner) return 'شريك';
    return 'عضو';
  }

  @override
  Widget build(BuildContext context) {
    final isActive = well.status == 'active';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF0B2545), // Deep Midnight
            Color(0xFF133E68),
            Color(0xFF1A538C), // Rich Ocean Blue
          ],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0B2545).withValues(alpha: 0.35),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // السطر الأول: هوية البئر وشارة الجاهزية
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.water_drop_rounded,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        well.name.isNotEmpty ? well.name : 'البئر النشط الحالي',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: isActive
                      ? AppColors.agriculturalGreen.withValues(alpha: 0.9)
                      : Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      isActive ? 'جاهز للتشغيل' : 'غير متاح للتشغيل',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // السطر الثاني: المؤشرات التشغيلية الحية
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _StatMini(
                    label: 'الحالة الحالية',
                    value: isActive ? 'نشط ومتاح للعمليات' : 'غير نشط',
                    valueColor: isActive
                        ? const Color(0xFF68D391)
                        : Colors.white70,
                  ),
                ),
                Container(
                  width: 1,
                  height: 22,
                  color: Colors.white.withValues(alpha: 0.15),
                ),
                Expanded(
                  child: _StatMini(
                    label: 'الدور والنطاق',
                    value: _roleLabel,
                    valueColor: Colors.white,
                  ),
                ),
                Container(
                  width: 1,
                  height: 22,
                  color: Colors.white.withValues(alpha: 0.15),
                ),
                const Expanded(
                  child: _StatMini(
                    label: 'المضخة والطاقة',
                    value: 'جاهزة للضخ',
                    valueColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatMini extends StatelessWidget {
  const _StatMini({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: Colors.white.withValues(alpha: 0.75),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}

/// شبكة الخدمات المتكاملة 3×3 (9 بلاطات متراصة بأرضيات ناعمة)
class _ServicesGrid3x3 extends StatelessWidget {
  const _ServicesGrid3x3({
    required this.isOwner,
    this.onNavigateToOperations,
    this.onNavigateToHistory,
    this.onNavigateToFarmers,
    this.onNavigateToExpenses,
    this.onNavigateToFuelInventory,
    this.onNavigateToPartners,
    this.onNavigateToWellManagement,
    this.onNavigateToReports,
    this.onNavigateToMoreSettings,
  });

  final bool isOwner;
  final VoidCallback? onNavigateToOperations;
  final VoidCallback? onNavigateToHistory;
  final VoidCallback? onNavigateToFarmers;
  final VoidCallback? onNavigateToExpenses;
  final VoidCallback? onNavigateToFuelInventory;
  final VoidCallback? onNavigateToPartners;
  final VoidCallback? onNavigateToWellManagement;
  final VoidCallback? onNavigateToReports;
  final VoidCallback? onNavigateToMoreSettings;

  @override
  Widget build(BuildContext context) {
    if (!isOwner) {
      return Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _ServiceCardTile(
                  icon: Icons.water_drop_outlined,
                  title: 'العمليات',
                  color: AppColors.waterBlue,
                  onTap: onNavigateToOperations,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ServiceCardTile(
                  icon: Icons.history_rounded,
                  title: 'سجل الجلسات',
                  color: AppColors.deepBlueLight,
                  onTap: onNavigateToHistory,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ServiceCardTile(
                  icon: Icons.people_alt_rounded,
                  title: 'المزارعون والأراضي',
                  color: AppColors.agriculturalGreen,
                  onTap: onNavigateToFarmers,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _ServiceCardTile(
                  icon: Icons.receipt_long_rounded,
                  title: 'المصروفات',
                  color: AppColors.deepBlue,
                  onTap: onNavigateToExpenses,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ServiceCardTile(
                  icon: Icons.local_gas_station_outlined,
                  title: 'مخزون الوقود',
                  color: Colors.deepOrange,
                  onTap: onNavigateToFuelInventory,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ServiceCardTile(
                  icon: Icons.apps_rounded,
                  title: 'الإعدادات والمزيد',
                  color: AppColors.textSecondary,
                  onTap: onNavigateToMoreSettings,
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Column(
      children: [
        // الصف الأول
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _ServiceCardTile(
                icon: Icons.history_rounded,
                title: 'سجل الجلسات',
                color: AppColors.deepBlueLight,
                onTap: onNavigateToHistory,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ServiceCardTile(
                icon: Icons.people_alt_rounded,
                title: 'المزارعون والأراضي',
                color: AppColors.agriculturalGreen,
                onTap: onNavigateToFarmers,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ServiceCardTile(
                icon: Icons.account_balance_wallet_rounded,
                title: 'كشوفات الحساب',
                color: AppColors.waterBlueDark,
                onTap: onNavigateToFarmers,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // الصف الثاني
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _ServiceCardTile(
                icon: Icons.receipt_long_rounded,
                title: 'المصروفات',
                color: AppColors.deepBlue,
                onTap: onNavigateToExpenses,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ServiceCardTile(
                icon: Icons.handshake_rounded,
                title: 'الشركاء والأرباح',
                color: AppColors.greenDeep,
                onTap: onNavigateToPartners,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ServiceCardTile(
                icon: Icons.settings_suggest_rounded,
                title: 'البئر والمعدات',
                color: AppColors.waterBlue,
                onTap: onNavigateToWellManagement,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // الصف الثالث
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _ServiceCardTile(
                icon: Icons.analytics_outlined,
                title: 'التقارير والمؤشرات',
                color: AppColors.deepBlueLight,
                onTap: onNavigateToReports,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ServiceCardTile(
                icon: Icons.price_change_outlined,
                title: 'أسعار التعرفة',
                color: AppColors.agriculturalGreen,
                onTap: onNavigateToWellManagement,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ServiceCardTile(
                icon: Icons.apps_rounded,
                title: 'الإعدادات والمزيد',
                color: AppColors.textSecondary,
                onTap: onNavigateToMoreSettings,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// بلاطة خدمة ناعمة مطابقة لبلاطات تطبيق جيب
class _ServiceCardTile extends StatelessWidget {
  const _ServiceCardTile({
    required this.icon,
    required this.title,
    required this.color,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 86,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            if (onTap != null) {
              HapticFeedback.lightImpact();
              onTap!();
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                // دائرة خلفية ملوّنة شفافة خلف الأيقونة — مطابقة للمرجع
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: color, size: 22),
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: AppColors.deepBlue,
                      height: 1.15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';

/// بطاقة إعلان أو مستجد في الشريط المتحرك
class BannerItemData {
  const BannerItemData({
    required this.tag,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.icon,
    required this.gradientColors,
    this.onTap,
  });

  final String tag;
  final String title;
  final String subtitle;
  final String actionLabel;
  final IconData icon;
  final List<Color> gradientColors;
  final VoidCallback? onTap;
}

/// شريط التنبيهات والمستجدات المتحرك (UX-15 / ق-127)
///
/// يعرض بطاقات تفاعلية بتدرجات لونية مميزة تدور تلقائيًا كل 6 ثوانٍ،
/// وتتوقف فور لمس المستخدم وتستأنف عند تركه.
class AnnouncementBannerSlider extends StatefulWidget {
  const AnnouncementBannerSlider({
    required this.showReports,
    this.onStartOperations,
    this.onViewFarmers,
    this.onViewHistory,
    this.onViewReports,
    super.key,
  });

  final bool showReports;
  final VoidCallback? onStartOperations;
  final VoidCallback? onViewFarmers;
  final VoidCallback? onViewHistory;
  final VoidCallback? onViewReports;

  @override
  State<AnnouncementBannerSlider> createState() =>
      _AnnouncementBannerSliderState();
}

class _AnnouncementBannerSliderState extends State<AnnouncementBannerSlider> {
  late final PageController _pageController;
  Timer? _autoSlideTimer;
  int _currentPage = 0;
  bool _isInteracting = false;

  List<BannerItemData> _buildItems() {
    return [
      BannerItemData(
        tag: 'كشوفات وحسابات',
        title: 'متابعة كشوفات وأرصدة المزارعين',
        subtitle: 'عرض المديونيات والدفعات وساعات السقي السابقة',
        actionLabel: 'فتح الدليل',
        icon: Icons.people_alt_rounded,
        gradientColors: const [
          Color(0xFF0F766E), // Emerald Teal
          Color(0xFF0D9488),
        ],
        onTap: widget.onViewFarmers,
      ),
      BannerItemData(
        tag: 'فواتير وسندات',
        title: 'طباعة فورية عبر طابعة البلوتوث',
        subtitle: 'إصدار وتوثيق سندات القبض لجميع الجلسات المكتملة',
        actionLabel: 'سجل العمليات',
        icon: Icons.receipt_long_rounded,
        gradientColors: const [
          Color(0xFF1E3A8A), // Indigo Deep
          Color(0xFF2563EB),
        ],
        onTap: widget.onViewHistory,
      ),
      if (widget.showReports)
        BannerItemData(
          tag: 'مؤشرات وإنتاجية',
          title: 'تقارير الاستهلاك وتوزيع الأرباح',
          subtitle: 'تحليلات ساعات الضخ وكفاءة الوقود وحصص الشركاء',
          actionLabel: 'عرض التقارير',
          icon: Icons.insights_rounded,
          gradientColors: const [
            Color(0xFF065F46), // Forest Green
            Color(0xFF059669),
          ],
          onTap: widget.onViewReports,
        ),
      BannerItemData(
        tag: 'تشغيل ميداني',
        title: 'تسجيل عداد البدء وإطلاق المضخة',
        subtitle: 'ضبط مصدر الطاقة والمزارع المستفيد بضغطة زر',
        actionLabel: 'بدء السقي',
        icon: Icons.play_circle_filled_rounded,
        gradientColors: const [
          Color(0xFF0369A1), // Sky Blue
          Color(0xFF0284C7),
        ],
        onTap: widget.onStartOperations,
      ),
    ];
  }

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _startTimer();
  }

  void _startTimer() {
    _autoSlideTimer?.cancel();
    _autoSlideTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || _isInteracting) return;
      final itemsCount = _buildItems().length;
      if (itemsCount <= 1) return;

      final nextPage = (_currentPage + 1) % itemsCount;
      _pageController.animateToPage(
        nextPage,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  void _onPointerDown() {
    _isInteracting = true;
    _autoSlideTimer?.cancel();
  }

  void _onPointerUp() {
    _isInteracting = false;
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && !_isInteracting) {
        _startTimer();
      }
    });
  }

  @override
  void dispose() {
    _autoSlideTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = _buildItems();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 100,
          child: Listener(
            onPointerDown: (_) => _onPointerDown(),
            onPointerUp: (_) => _onPointerUp(),
            onPointerCancel: (_) => _onPointerUp(),
            child: PageView.builder(
              controller: _pageController,
              itemCount: items.length,
              onPageChanged: (index) {
                setState(() {
                  _currentPage = index;
                });
              },
              itemBuilder: (context, index) {
                final item = items[index];
                return _BannerCard(item: item);
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        // مؤشرات الصفحات (Dots)
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(items.length, (index) {
            final isSelected = _currentPage == index;
            return GestureDetector(
              onTap: () {
                _pageController.animateToPage(
                  index,
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeInOut,
                );
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: isSelected ? 20 : 6,
                height: 5,
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppColors.waterBlue
                      : AppColors.border.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({required this.item});

  final BannerItemData item;

  @override
  Widget build(BuildContext context) {
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    return InkWell(
      onTap: () {
        if (item.onTap != null) {
          HapticFeedback.lightImpact();
          item.onTap!();
        }
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: item.gradientColors,
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: item.gradientColors.first.withValues(alpha: 0.22),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // السطر العلوي: الشارة + الأيقونة
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    item.tag,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                Icon(
                  item.icon,
                  color: Colors.white.withValues(alpha: 0.35),
                  size: 20,
                ),
              ],
            ),
            // العنوان الرئيسي والفرعي
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  item.subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.9),
                    height: 1.15,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            // زر الإجراء الصريح (CTA)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.actionLabel,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: item.gradientColors.first,
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(
                        isRtl
                            ? Icons.arrow_back_rounded
                            : Icons.arrow_forward_rounded,
                        size: 12,
                        color: item.gradientColors.first,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../core/api/app_bootstrap_repository.dart';
import '../../core/identity/app_identity.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/top_well_selector.dart';

/// الشاشة الرئيسية الموحدة للمالك وحسابات الأدوار المتعددة (UX-05 / UX-06 / UX-15 / ق-87)
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    required this.identity,
    this.onWellChanged,
    this.onNavigateToOperations,
    this.onNavigateToHistory,
    this.onNavigateToFarmers,
    this.onNavigateToExpenses,
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
  final VoidCallback? onNavigateToPartners;
  final VoidCallback? onNavigateToWellManagement;
  final VoidCallback? onNavigateToReports;
  final VoidCallback? onNavigateToMoreSettings;
  final VoidCallback? onLogout;

  @override
  Widget build(BuildContext context) {
    final activeWell = identity.activeWell;

    // الاسم كما سجّله الخادم. غيابه يُترك فراغًا ولا يُملأ بلقب عام يُقرأ
    // كأنه اسم المستخدم (ق-113).
    final subtitle = identity.displayName.isEmpty
        ? 'الرئيسية'
        : 'الرئيسية • ${identity.displayName}';

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        centerTitle: false,
        title: TopWellSelector(
          wells: identity.wells,
          activeWell: activeWell,
          subtitle: subtitle,
          onWellChanged: (newWell) {
            if (onWellChanged != null) {
              onWellChanged!(newWell);
            }
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.settings_outlined,
              color: AppColors.textSecondary,
            ),
            tooltip: 'الإعدادات والمزيد',
            onPressed: onNavigateToMoreSettings,
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: AppColors.textSecondary),
            tooltip: 'تسجيل الخروج',
            onPressed: onLogout,
          ),
        ],
      ),
      body: SafeArea(
        // لا تمرير في الرئيسية: كل المداخل تُعرض معًا. والتمرير في شاشة
        // المداخل يُخفي أبوابًا لا يعرف المستخدم أنها موجودة، ومَن يعمل عند
        // رأس البئر بيد واحدة لا يمرّر ليجد بابًا. فالمساحة تُقسَّم على ما
        // هو موجود: `Expanded` يُوزّع ما بقي بعد بطاقة البئر على الصفوف
        // الثلاثة، فتنضبط الشاشة على أي حجم جهاز بلا تمرير وبلا فيض.
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // بطاقة البئر: الحالة وحدها بلا تكرار الاسم.
              //
              // اسم البئر يظهر في الرأس (القرار 212) وهو **عنصر تبديل البئر**
              // نفسه، فتكراره هنا يأخذ مساحة بلا معلومة جديدة. والقرار 213
              // يعدّ اسم البئر واحدًا من محتويات **ممكنة** لا واجبة.
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.deepBlue, AppColors.waterBlue],
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.deepBlue.withValues(alpha: 0.2),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact =
                        MediaQuery.textScalerOf(context).scale(12) > 18;

                    final statusText = Text(
                      activeWell.status == 'active'
                          ? 'نشط ومتاح للعمليات'
                          : 'غير نشط',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    );
                    final readiness = _ReadinessBadge(
                      isActive: activeWell.status == 'active',
                    );

                    if (compact || constraints.maxWidth < 300) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'البئر النشط الحالي',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          statusText,
                          const SizedBox(height: 8),
                          readiness,
                        ],
                      );
                    }

                    return Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'البئر النشط الحالي',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              statusText,
                            ],
                          ),
                        ),
                        readiness,
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),

              const Text(
                'الخدمات والأقسام الرئيسية',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepBlue,
                ),
              ),
              const SizedBox(height: 12),

              // شبكة المداخل التسعة: ثلاثة في ثلاثة — فلا مدخل وحيد في صفّ
              // يبدو أهمّ من أخواته، ولا صفٌّ ناقص. و«التشغيل والسقي» أول
              // مدخل في أول صفّ: أبرز موضع بصريًّا (قرار المالك).
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _ServiceRow(
                        children: [
                          _ServiceCard(
                            icon: Icons.play_circle_filled,
                            title: 'التشغيل والسقي',
                            color: AppColors.waterBlue,
                            onTap: onNavigateToOperations,
                          ),
                          _ServiceCard(
                            icon: Icons.history,
                            title: 'سجل الجلسات',
                            color: AppColors.deepBlueLight,
                            onTap: onNavigateToHistory,
                          ),
                          _ServiceCard(
                            icon: Icons.people_alt,
                            title: 'المزارعون والأراضي',
                            color: AppColors.agriculturalGreen,
                            onTap: onNavigateToFarmers,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _ServiceRow(
                        children: [
                          _ServiceCard(
                            icon: Icons.account_balance_wallet,
                            title: 'الحسابات',
                            color: AppColors.waterBlueDark,
                            // مدخل «الحسابات» (القرار 223) يقود إلى دليل
                            // المزارعين اليوم، لأن كشف الحساب هناك: لكل مزارع
                            // حسابه ورصيده. وشاشةٌ تجمع أرصدة البئر كلها تحتاج
                            // عقد قراءة لا وجود له بعد — فالمدخل يقود إلى ما
                            // يوجد فعلًا ولا يُفتح باب على شاشة تُلفِّق أرقامًا.
                            onTap: onNavigateToFarmers,
                          ),
                          _ServiceCard(
                            icon: Icons.receipt_long,
                            title: 'المصروفات',
                            color: AppColors.deepBlue,
                            onTap: onNavigateToExpenses,
                          ),
                          _ServiceCard(
                            icon: Icons.handshake,
                            title: 'الشركاء والأرباح',
                            color: AppColors.greenDeep,
                            onTap: onNavigateToPartners,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _ServiceRow(
                        children: [
                          _ServiceCard(
                            icon: Icons.settings_suggest,
                            title: 'البئر والمعدات',
                            color: AppColors.deepBlueLight,
                            onTap: onNavigateToWellManagement,
                          ),
                          _ServiceCard(
                            icon: Icons.analytics_outlined,
                            title: 'التقارير',
                            color: AppColors.greenLight,
                            onTap: onNavigateToReports,
                          ),
                          _ServiceCard(
                            icon: Icons.more_horiz_rounded,
                            title: 'المزيد',
                            color: AppColors.waterBlue,
                            onTap: onNavigateToMoreSettings,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadinessBadge extends StatelessWidget {
  const _ReadinessBadge({required this.isActive});

  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isActive ? AppColors.agriculturalGreen : AppColors.textSecondary,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isActive ? 'جاهز للتشغيل' : 'غير متاح للتشغيل',
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// صفّ من ثلاثة مداخل متساوية العرض بمسافة 8dp بينها.
///
/// يُستعمل داخل `Expanded` فارتفاعه محدود، فـ`stretch` آمن هنا. وبلا حدّ
/// أعلى للارتفاع كان `stretch` يطلب ارتفاعًا لا نهائيًّا فتسقط الشاشة بيضاء —
/// وهو ما جرى في 2026-09-04 حين كان الصفّ داخل قائمة تمرير.
class _ServiceRow extends StatelessWidget {
  const _ServiceRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: children[i]),
        ],
      ],
    );
  }
}

/// بطاقة مدخل قسم: أيقونة واسم قصير ومساحة لمس كبيرة — بلا وصف.
///
/// **لماذا حُذف الوصف:** القرار 220 ينصّ «لا نضع وصفًا طويلًا داخل كل بطاقة».
/// وأثره مقيس لا جماليّ: السطر الوصفي كان يُطيل البطاقة فيُخرج مدخلين من
/// الشاشة الأولى، والمستخدم اليومي يقرأ الاسم ولا يقرأ الوصف بعد المرة
/// الثالثة — فيبقى ضجيجًا يزاحم ما يُقرأ فعلًا.
class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        // المحتوى في الوسط لا موزَّعًا بين الطرفين: التوزيع كان يحشر الأيقونة
        // في الزاوية العليا ويترك فراغًا في وسط البطاقة.
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                // 0.14 لا 0.10: الألوان الداكنة (الأزرق الداكن ودرجاته) بعد
                // التخفيف إلى 10% تُقرأ رماديًّا باهتًا فتفقد تمييزها — مقيس
                // على الجهاز في 2026-09-04.
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(height: 8),
            // الاسم قد يطول («المزارعون والأراضي») فيُلفّ على سطرين ويُوسَّط.
            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: AppColors.deepBlue,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

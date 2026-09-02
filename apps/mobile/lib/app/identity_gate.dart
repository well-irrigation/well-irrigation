import 'package:flutter/material.dart';

import '../core/api/app_bootstrap_repository.dart';
import '../core/identity/app_identity.dart';
import '../core/theme/app_colors.dart';

/// بوابة الهوية: تقرأ عقد الحساب مرة واحدة وتُعلن نتيجته الثلاثية (ق-113).
///
/// قبل هذه البوابة كان فشل القراءة يُبتلع، فيدخل المستخدم إلى شاشات ممتلئة
/// باسم وبئر ودور جاهزين ليست له. الآن لا يُبنى أي محتوى إلا من هوية
/// حقيقية، والحالات الأخرى تُقال كما هي: تحميل، أو تعذُّر مع إعادة محاولة،
/// أو حساب بلا بئر مرتبط.
///
/// لا تخزين محلي للهوية للعمل دون اتصال: ذلك عمل مؤجَّل بقرار بوابة
/// التثبيت (ق-120)، وافتراضه هنا يفتح بابًا ممنوعًا.
class IdentityGate extends StatefulWidget {
  const IdentityGate({
    required this.loadBootstrap,
    required this.builder,
    this.onCreateWellRequested,
    this.onSignOutRequested,
    super.key,
  });

  /// قراءة العقد. تُمرَّر من الأعلى ليبقى مصدر الهوية واحدًا ومقيسًا.
  final Future<BootstrapData> Function() loadBootstrap;

  /// يُبنى المحتوى بهوية حقيقية فقط — لا يُنادى في أي حالة أخرى.
  final Widget Function(
    BuildContext context,
    AppIdentity identity,
    ValueChanged<WellSummary> onWellChanged,
  ) builder;

  final VoidCallback? onCreateWellRequested;
  final VoidCallback? onSignOutRequested;

  @override
  State<IdentityGate> createState() => IdentityGateState();
}

class IdentityGateState extends State<IdentityGate> {
  IdentityResolution? _resolution;

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// إعادة القراءة: من زر إعادة المحاولة، ومن الأعلى بعد إنشاء بئر جديد.
  Future<void> reload() async {
    setState(() => _resolution = null);

    IdentityResolution next;
    try {
      next = resolveIdentity(await widget.loadBootstrap());
    } catch (error) {
      next = IdentityUnavailable('$error');
    }

    if (!mounted) return;
    setState(() => _resolution = next);
  }

  void _selectWell(WellSummary well) {
    final current = _resolution;
    if (current is! IdentityReady) return;

    setState(() {
      _resolution = IdentityReady(current.identity.withActiveWell(well));
    });
  }

  @override
  Widget build(BuildContext context) {
    final resolution = _resolution;

    return switch (resolution) {
      null => const _IdentityLoadingView(),
      IdentityReady(:final identity) => widget.builder(
        context,
        identity,
        _selectWell,
      ),
      IdentityWithoutWell() => AppNoticeView(
        icon: Icons.water_drop_outlined,
        title: 'لا يوجد بئر مرتبط بحسابك',
        message:
            'حسابك مصدَّق، لكن لم يُربط به أي بئر بعد. أنشئ بئرك الأول، أو '
            'اطلب من مالك البئر إضافتك إلى فريقه ثم أعد المحاولة.',
        primaryLabel: 'إنشاء بئر جديد',
        onPrimary: widget.onCreateWellRequested,
        onRetry: reload,
        onSignOut: widget.onSignOutRequested,
      ),
      IdentityUnavailable(:final reason) => AppNoticeView(
        icon: Icons.cloud_off_outlined,
        title: 'تعذر تحميل بيانات حسابك',
        message:
            'لم نتمكن من قراءة حسابك وآبارك من الخادم، ولن نعرض بيانات غير '
            'بياناتك. تحقق من الاتصال ثم أعد المحاولة.\n\n$reason',
        onRetry: reload,
        onSignOut: widget.onSignOutRequested,
      ),
    };
  }
}

class _IdentityLoadingView extends StatelessWidget {
  const _IdentityLoadingView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.splashBackground,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(
              'جاري تحميل بيانات حسابك',
              style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class AppNoticeView extends StatelessWidget {
  const AppNoticeView({
    required this.icon,
    required this.title,
    required this.message,
    required this.onRetry,
    this.primaryLabel,
    this.onPrimary,
    this.onSignOut,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final VoidCallback onRetry;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 48, color: AppColors.deepBlue),
                const SizedBox(height: 20),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.deepBlue,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 24),
                if (primaryLabel != null)
                  FilledButton.icon(
                    onPressed: onPrimary,
                    icon: const Icon(Icons.add),
                    label: Text(primaryLabel!),
                  ),
                if (primaryLabel != null) const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('إعادة المحاولة'),
                ),
                if (onSignOut != null)
                  TextButton(
                    onPressed: onSignOut,
                    child: const Text('تسجيل الخروج'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

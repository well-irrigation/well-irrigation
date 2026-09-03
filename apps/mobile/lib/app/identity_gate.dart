import 'package:flutter/material.dart';

import '../core/api/app_bootstrap_repository.dart';
import '../core/api/team_repository.dart';
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
    this.teamRepository,
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

  /// مستودع الفريق. يُمرَّر في الاختبار، وفي التشغيل يُبنى افتراضيًا.
  final TeamRepository? teamRepository;

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

  /// حساب مصدَّق بلا بئر قد يكون عضوًا مدعوًّا أنشأ حسابه قبل أن يُطالِب
  /// بدعوته. لا يُسأل عن رقمه ولا كلمة مروره من جديد: هو داخل بالفعل،
  /// والرمز وحده هو ما ينقص (ق-123).
  Future<void> _promptClaimInvitation(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);

    final code = await showDialog<String>(
      context: context,
      builder: (_) => const _ClaimCodeDialog(),
    );
    if (code == null || !mounted) return;

    ClaimResult? result;
    try {
      result = await (widget.teamRepository ?? TeamRepository())
          .claimInvitation(code);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('تعذر التحقق من الرمز — لم يُمنح أي وصول'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    if (!mounted) return;

    if (result.isSuccess) {
      await reload();
      return;
    }

    final left = result.attemptsLeft;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.isWrongCode
              ? (left == null
                  ? 'رمز التنشيط غير صحيح'
                  : 'رمز التنشيط غير صحيح — بقيت $left محاولات')
              : 'لا توجد دعوة سارية لرقمك',
        ),
        backgroundColor: AppColors.error,
      ),
    );
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
        secondaryLabel: 'لديك رمز تنشيط؟',
        onSecondary: () => _promptClaimInvitation(context),
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
    this.secondaryLabel,
    this.onSecondary,
    this.onSignOut,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final VoidCallback onRetry;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
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
                if (secondaryLabel != null)
                  OutlinedButton.icon(
                    onPressed: onSecondary,
                    icon: const Icon(Icons.key_outlined),
                    label: Text(secondaryLabel!),
                  ),
                if (secondaryLabel != null) const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('إعادة المحاولة'),
                ),
                if (onSignOut != null)
                  TextButton(
                    onPressed: onSignOut,
                    child: const Text('تسجيل الخروج'),
                  ),              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// نافذة رمز التنشيط لحساب مصدَّق بلا بئر. تجمع الرمز ولا تنفّذ شيئًا:
/// التنفيذ في البوابة، فلا مسار كتابة من نافذة عرض.
class _ClaimCodeDialog extends StatefulWidget {
  const _ClaimCodeDialog();

  @override
  State<_ClaimCodeDialog> createState() => _ClaimCodeDialogState();
}

class _ClaimCodeDialogState extends State<_ClaimCodeDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'رمز التنشيط',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'أدخل الرمز الذي أعطاك مالك البئر. حسابك مصدَّق بالفعل، والرمز '
            'وحده هو ما ينقص.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _controller,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 8,
            ),
            decoration: const InputDecoration(
              hintText: '------',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.agriculturalGreen,
            foregroundColor: Colors.white,
          ),
          onPressed: () {
            final code = _controller.text.trim();
            if (code.isEmpty) return;
            Navigator.of(context).pop(code);
          },
          child: const Text('تنشيط'),
        ),
      ],
    );
  }
}

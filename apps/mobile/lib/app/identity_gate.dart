import 'dart:async';

import 'package:flutter/material.dart';

import '../core/api/app_bootstrap_repository.dart';
import '../core/api/team_repository.dart';
import '../core/diagnostics/q129_recovery_diagnostic.dart';
import '../core/identity/app_identity.dart';
import '../core/network/bootstrap_connectivity_failure.dart';
import '../core/session/active_session_record.dart';
import '../core/session/offline_session_coordinator.dart';
import '../core/theme/app_colors.dart';
import '../core/widgets/well_loading_indicator.dart';
import '../features/operations/offline_session_recovery_screen.dart';

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
    this.recoveryCoordinator,
    this.localAuthAccount,
    this.authChanges,
    super.key,
  });

  /// قراءة العقد. تُمرَّر من الأعلى ليبقى مصدر الهوية واحدًا ومقيسًا.
  final Future<BootstrapData> Function() loadBootstrap;

  /// يُبنى المحتوى بهوية حقيقية فقط — لا يُنادى في أي حالة أخرى.
  final Widget Function(
    BuildContext context,
    AppIdentity identity,
    ValueChanged<WellSummary> onWellChanged,
  )
  builder;

  final VoidCallback? onCreateWellRequested;
  final VoidCallback? onSignOutRequested;

  /// مستودع الفريق. يُمرَّر في الاختبار، وفي التشغيل يُبنى افتراضيًا.
  final TeamRepository? teamRepository;

  final OfflineSessionCoordinator? recoveryCoordinator;
  final LocalAuthAccount? Function()? localAuthAccount;
  final Stream<void>? authChanges;

  @override
  State<IdentityGate> createState() => IdentityGateState();
}

class IdentityGateState extends State<IdentityGate> {
  IdentityResolution? _resolution;
  List<ActiveSessionRecord>? _recoverySessions;
  String? _recoveryAccountId;
  bool _connectivityUnavailable = false;
  int _reloadGeneration = 0;
  StreamSubscription<void>? _authSubscription;

  @override
  void initState() {
    super.initState();
    _authSubscription = widget.authChanges?.listen(
      (_) => _checkRecoveryAccount(),
      onError: (Object _, StackTrace _) => _checkRecoveryAccount(),
    );
    reload();
  }

  @override
  void dispose() {
    _reloadGeneration++;
    _authSubscription?.cancel();
    super.dispose();
  }

  void _checkRecoveryAccount() {
    if (!mounted || _recoveryAccountId == null) return;
    final current = widget.localAuthAccount?.call();
    if (current?.id != _recoveryAccountId) {
      setState(() {
        _recoverySessions = null;
        _recoveryAccountId = null;
        _resolution = const IdentityUnavailable('');
      });
      return;
    }
    // قد يكون الحدث انتهاء الرمز أو تجديده: تعيد الشاشة حساب صلاحية الأفعال.
    setState(() {});
  }

  /// إعادة القراءة: من زر إعادة المحاولة، ومن الأعلى بعد إنشاء بئر جديد.
  Future<void> reload() async {
    final generation = ++_reloadGeneration;
    setState(() {
      _resolution = null;
      _recoverySessions = null;
      _recoveryAccountId = null;
      _connectivityUnavailable = false;
    });

    IdentityResolution next;
    List<ActiveSessionRecord>? recovered;
    String? recoveryAccountId;
    var connectivityUnavailable = false;
    try {
      next = resolveIdentity(await widget.loadBootstrap());
    } catch (error) {
      connectivityUnavailable = isBootstrapConnectivityFailure(error);
      logQ129Diagnostic(
        q129BootstrapFailureFields(
          error,
          connectivityClassified: connectivityUnavailable,
          auth: Q129AuthSnapshot.capture(),
        ),
      );
      next = const IdentityUnavailable('');
      if (connectivityUnavailable &&
          widget.recoveryCoordinator != null &&
          widget.localAuthAccount != null) {
        try {
          final auth = widget.localAuthAccount!();
          if (auth != null && auth.id.isNotEmpty) {
            final sessions = await widget.recoveryCoordinator!
                .unresolvedSessions(auth.id);
            logQ129Diagnostic(
              q129RecoveryQueryFields(
                candidateCount: sessions.length,
                expiredReadOnly: auth.isExpired,
              ),
            );
            if (sessions.isNotEmpty &&
                widget.localAuthAccount!()?.id == auth.id &&
                sessions.every((session) => session.accountId == auth.id)) {
              recovered = sessions;
              recoveryAccountId = auth.id;
            }
          }
        } catch (queryError) {
          logQ129Diagnostic(q129RecoveryQueryFailureFields(queryError));
          // فشل قراءة الطابور لا يفتح وصولًا محليًا ولا يغيّر خطأ الشبكة.
        }
      }
    }

    if (!mounted || generation != _reloadGeneration) return;
    setState(() {
      _resolution = next;
      _recoverySessions = recovered;
      _recoveryAccountId = recoveryAccountId;
      _connectivityUnavailable = connectivityUnavailable;
    });
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
    final recoverySessions = _recoverySessions;
    final recoveryAccountId = _recoveryAccountId;
    if (recoverySessions != null &&
        recoveryAccountId != null &&
        widget.localAuthAccount?.call()?.id == recoveryAccountId) {
      return OfflineSessionRecoveryScreen(
        accountId: recoveryAccountId,
        sessions: recoverySessions,
        coordinator: widget.recoveryCoordinator!,
        localAuthAccount: widget.localAuthAccount!,
        onRetry: reload,
      );
    }

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
      IdentityUnavailable() => AppNoticeView(
        icon: Icons.cloud_off_outlined,
        title: 'تعذر تحميل بيانات حسابك',
        message: _connectivityUnavailable
            ? 'تعذر الاتصال بالخادم. تحقق من اتصال الإنترنت ثم أعد المحاولة.'
            : 'تعذر التحقق من بيانات حسابك. أعد المحاولة.',
        onRetry: reload,
        onSignOut: widget.onSignOutRequested,
      ),
    };
  }
}

/// انتظار حلّ الهوية: القطرة وحدها بلا نصّ ولا بطاقة.
///
/// **لماذا لا شاشة كاملة بنصّ:** كانت شاشة مستقلة تُعرض ثوانٍ ثم تختفي —
/// فيبدو الانتظار انتقالًا إلى مكان آخر لا لحظةً في مكانه. والنصّ «جاري
/// تحميل بيانات حسابك» لا يضيف شيئًا للحركة، ويُقرأ في كل فتح فيصير ضجيجًا.
///
/// وهذه أول شاشة في التطبيق فلا شيء خلفها ليُعتَّم، فتُعرض القطرة على خلفية
/// الإقلاع بالأزرق. أمّا `WellLoadingOverlay` فلما له خلفية فعلًا: التنقل
/// بين الأقسام وانتظار العقود.
class _IdentityLoadingView extends StatelessWidget {
  const _IdentityLoadingView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.splashBackground,
      body: Center(child: WellLoadingIndicator(size: 112)),
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
                  ),
              ],
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

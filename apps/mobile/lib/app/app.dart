import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/api/app_bootstrap_repository.dart';
import '../core/api/auth_repository.dart';
import '../core/config/app_config.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/member_activation_screen.dart';
import '../features/auth/password_reset_screen.dart';
import '../features/splash/splash_screen.dart';
import '../features/well_setup/create_well_wizard_screen.dart';
import 'authenticated_shell.dart';
import 'identity_gate.dart';

class WellIrrigationApp extends StatefulWidget {
  const WellIrrigationApp({required this.config, super.key});

  final AppConfig config;

  @override
  State<WellIrrigationApp> createState() => _WellIrrigationAppState();
}

class _WellIrrigationAppState extends State<WellIrrigationApp> {
  bool _splashCompleted = false;
  bool _isLoggedIn = false;

  /// يُزاد بعد إنشاء بئر جديد، فتُعاد تركيب بوابة الهوية وتقرأ العقد ثانية.
  int _identityEpoch = 0;

  /// سبب فشل تسجيل الخروج. وجوده يمنع إعلان خروج لم يحدث.
  String? _signOutFailure;

  @override
  void initState() {
    super.initState();
    _checkInitialAuth();
  }

  void _checkInitialAuth() {
    // لا مسار بيانات هنا: إن لم تكن حزمة Supabase مهيّأة فالتطبيق كله معروض
    // بشاشة فشل الإعداد من `main.dart`، وما يبقى أمام المستخدم شاشة الدخول.
    try {
      _isLoggedIn = Supabase.instance.client.auth.currentSession != null;
    } catch (_) {
      _isLoggedIn = false;
    }
  }

  Future<BootstrapData> _loadBootstrap() {
    return AppBootstrapRepository(Supabase.instance.client).fetchBootstrap();
  }

  /// الخروج لا يُعلن إلا إن نجح فعلًا: فشل إبطال الجلسة يُعرض للمستخدم بدل
  /// إعادته إلى شاشة الدخول وجلسته ما زالت قائمة على الجهاز.
  Future<void> _handleLogout() async {
    try {
      await AuthRepository(Supabase.instance.client).signOut();
    } catch (error) {
      if (mounted) {
        setState(() => _signOutFailure = '$error');
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isLoggedIn = false;
        _signOutFailure = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'إدارة البئر والسقي',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Roboto',
        colorSchemeSeed: const Color(0xFF0265BA),
      ),
      home: Builder(builder: _buildHome),
    );
  }

  Widget _buildHome(BuildContext context) {
    if (!_splashCompleted) {
      return SplashScreen(
        onInitialized: () => setState(() => _splashCompleted = true),
      );
    }

    final signOutFailure = _signOutFailure;
    if (signOutFailure != null) {
      return AppNoticeView(
        icon: Icons.logout,
        title: 'تعذر تسجيل الخروج',
        message:
            'ما زالت جلستك مفتوحة على هذا الجهاز، فلن نعيدك إلى شاشة الدخول '
            'ونحن لم ننهها. أعد المحاولة.\n\n$signOutFailure',
        onRetry: _handleLogout,
      );
    }

    if (!_isLoggedIn) {
      return LoginScreen(
        onLoginSuccess: () => setState(() => _isLoggedIn = true),
        onCreateWellPressed: () => _openCreateWellWizard(context),
        onActivateMemberPressed: () => _openMemberActivation(context),
        onForgotPasswordPressed: () => _openPasswordReset(context),
      );
    }

    return IdentityGate(
      key: ValueKey(_identityEpoch),
      loadBootstrap: _loadBootstrap,
      onSignOutRequested: _handleLogout,
      onCreateWellRequested: () => _openCreateWellWizard(context),
      builder: (context, identity, onWellChanged) => AuthenticatedShell(
        identity: identity,
        onWellChanged: onWellChanged,
        onLogout: _handleLogout,
      ),
    );
  }

  /// تنشيط عضو مدعو: لا يُعلن الدخول إلا بعد **تعيين نافذ** على بئر،
  /// فإنشاء الحساب وحده ليس وصولًا (ق-123).
  void _openMemberActivation(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (routeContext) => MemberActivationScreen(
          onActivated: () {
            Navigator.of(routeContext).pop();
            setState(() {
              _isLoggedIn = true;
              _identityEpoch++;
            });
          },
        ),
      ),
    );
  }

  /// إعادة تعيين كلمة المرور برمز من المالك (م-41F). لا تُعلن دخولًا:
  /// صاحب الحساب يعود إلى شاشة الدخول ويدخل بكلمته الجديدة.
  void _openPasswordReset(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (routeContext) => PasswordResetScreen(
          onDone: () => Navigator.of(routeContext).pop(),
        ),
      ),
    );
  }

  void _openCreateWellWizard(BuildContext context) {
    Navigator.of(context).push(      MaterialPageRoute(
        builder: (_) => CreateWellWizardScreen(
          onCompleted: () {
            setState(() {
              _isLoggedIn = true;
              // البئر الجديد يأتي من العقد لا من الشاشة: إعادة القراءة هي
              // ما يجعله بئرًا نشطًا، فلا يُبنى منه ملخّص محلي.
              _identityEpoch++;
            });
          },
        ),
      ),
    );
  }
}

class ConfigurationFailureApp extends StatelessWidget {
  const ConfigurationFailureApp({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.settings_outlined, size: 48),
                  const SizedBox(height: 20),
                  const Text(
                    'إعداد التطبيق غير مكتمل',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    message,
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.ltr,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

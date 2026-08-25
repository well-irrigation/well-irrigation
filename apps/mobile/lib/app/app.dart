import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/api/app_bootstrap_repository.dart';
import '../core/api/auth_repository.dart';
import '../core/config/app_config.dart';
import '../features/auth/login_screen.dart';
import '../features/farmers/farmers_directory_screen.dart';
import '../features/finance/expenses_screen.dart';
import '../features/finance/partners_screen.dart';
import '../features/history/session_history_screen.dart';
import '../features/home/home_screen.dart';
import '../features/operations/operations_screen.dart';
import '../features/splash/splash_screen.dart';
import '../features/well_management/reports_analytics_screen.dart';
import '../features/well_management/well_management_hub_screen.dart';
import '../features/well_setup/create_well_wizard_screen.dart';

class WellIrrigationApp extends StatefulWidget {
  const WellIrrigationApp({required this.config, super.key});

  final AppConfig config;

  @override
  State<WellIrrigationApp> createState() => _WellIrrigationAppState();
}

class _WellIrrigationAppState extends State<WellIrrigationApp> {
  bool _splashCompleted = false;
  bool _isLoggedIn = false;
  String _userRole = 'owner'; // 'owner' or 'operator'
  String _userName = 'محمد عبدالله الشامي';
  String _wellName = 'بئر الخير الرئيسي';
  List<WellSummary> _wells = [];
  WellSummary? _activeWell;

  @override
  void initState() {
    super.initState();
    _checkInitialAuth();
  }

  void _checkInitialAuth() {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        _isLoggedIn = true;
        _refreshBootstrap();
      }
    } catch (_) {}
  }

  Future<void> _refreshBootstrap() async {
    try {
      final client = Supabase.instance.client;
      if (client.auth.currentSession != null) {
        final repo = AppBootstrapRepository(client);
        final data = await repo.fetchBootstrap();
        if (mounted) {
          setState(() {
            if (data.profile.fullName.isNotEmpty) {
              _userName = data.profile.fullName;
            }
            _wells = data.wells;
            if (data.primaryWell != null && data.primaryWell!.name.isNotEmpty) {
              _activeWell = data.primaryWell;
              _wellName = data.primaryWell!.name;
              _userRole = data.primaryWell!.isOwner ? 'owner' : 'operator';
            }
          });
        }
      }
    } catch (_) {
      // الحفاظ على البيانات الافتراضية محلياً عند غياب الشبكة
    }
  }

  Future<void> _handleLogout() async {
    try {
      await AuthRepository(Supabase.instance.client).signOut();
    } catch (_) {}

    if (mounted) {
      setState(() {
        _isLoggedIn = false;
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
      home: Builder(
        builder: (innerContext) {
          if (!_splashCompleted) {
            return SplashScreen(
              onInitialized: () {
                setState(() {
                  _splashCompleted = true;
                });
              },
            );
          }

          if (!_isLoggedIn) {
            return LoginScreen(
              onLoginSuccess: () {
                setState(() {
                  _isLoggedIn = true;
                });
                _refreshBootstrap();
              },
              onCreateWellPressed: () {
                Navigator.of(innerContext).push(
                  MaterialPageRoute(
                    builder: (_) => CreateWellWizardScreen(
                      onCompleted: () {
                        setState(() {
                          _isLoggedIn = true;
                          _userRole = 'owner';
                        });
                        _refreshBootstrap();
                      },
                    ),
                  ),
                );
              },
            );
          }

          // التوجيه الذكي المعتمد حسب الدور (UX-05 / UX-13 / ق-87 / ق-98)
          if (_userRole == 'owner') {
            return HomeScreen(
              ownerName: _userName,
              wellName: _wellName,
              wells: _wells,
              activeWell: _activeWell,
              onWellChanged: (well) {
                setState(() {
                  _activeWell = well;
                  _wellName = well.name;
                  _userRole = well.isOwner ? 'owner' : 'operator';
                });
              },
              onNavigateToOperations: () {
                Navigator.of(innerContext).push(
                  MaterialPageRoute(
                    builder: (_) => OperationsScreen(
                      wellName: _wellName,
                      wellId: _activeWell?.id,
                      wells: _wells,
                      onWellChanged: (well) {
                        setState(() {
                          _activeWell = well;
                          _wellName = well.name;
                          _userRole = well.isOwner ? 'owner' : 'operator';
                        });
                      },
                      onLogout: _handleLogout,
                    ),
                  ),
                );
              },
              onNavigateToHistory: () {
                Navigator.of(innerContext).push(
                  MaterialPageRoute(
                    builder: (_) => SessionHistoryScreen(
                      wellName: _wellName,
                      wellId: _activeWell?.id,
                      wells: _wells,
                      onWellChanged: (well) {
                        setState(() {
                          _activeWell = well;
                          _wellName = well.name;
                          _userRole = well.isOwner ? 'owner' : 'operator';
                        });
                      },
                      onLogout: _handleLogout,
                    ),
                  ),
                );
              },
              onNavigateToFarmers: () {
                Navigator.of(innerContext).push(
                  MaterialPageRoute(
                    builder: (_) => FarmersDirectoryScreen(
                      wellName: _wellName,
                      wellId: _activeWell?.id,
                      wells: _wells,
                      onWellChanged: (well) {
                        setState(() {
                          _activeWell = well;
                          _wellName = well.name;
                          _userRole = well.isOwner ? 'owner' : 'operator';
                        });
                      },
                      onLogout: _handleLogout,
                    ),
                  ),
                );
              },
              onNavigateToExpenses: () {
                Navigator.of(innerContext).push(
                  MaterialPageRoute(
                    builder: (_) => ExpensesScreen(
                      wellName: _wellName,
                      wellId: _activeWell?.id ?? 'well-1',
                      wells: _wells,
                      onWellChanged: (newWell) {
                        setState(() {
                          _activeWell = newWell;
                          _wellName = newWell.name;
                          _userRole = newWell.isOwner ? 'owner' : 'operator';
                        });
                      },
                    ),
                  ),
                );
              },
              onNavigateToPartners: () {
                Navigator.of(innerContext).push(
                  MaterialPageRoute(
                    builder: (_) => PartnersScreen(
                      wellName: _wellName,
                      wellId: _activeWell?.id ?? 'well-1',
                      wells: _wells,
                      onWellChanged: (newWell) {
                        setState(() {
                          _activeWell = newWell;
                          _wellName = newWell.name;
                          _userRole = newWell.isOwner ? 'owner' : 'operator';
                        });
                      },
                    ),
                  ),
                );
              },
              onNavigateToWellManagement: () {
                Navigator.of(innerContext).push(
                  MaterialPageRoute(
                    builder: (_) => WellManagementHubScreen(
                      wellName: _wellName,
                      wellId: _activeWell?.id ?? 'well-1',
                      wells: _wells,
                      onWellChanged: (newWell) {
                        setState(() {
                          _activeWell = newWell;
                          _wellName = newWell.name;
                          _userRole = newWell.isOwner ? 'owner' : 'operator';
                        });
                      },
                    ),
                  ),
                );
              },
              onNavigateToReports: () {
                Navigator.of(innerContext).push(
                  MaterialPageRoute(
                    builder: (_) => ReportsAnalyticsScreen(
                      wellName: _wellName,
                      wellId: _activeWell?.id ?? 'well-1',
                      wells: _wells,
                      onWellChanged: (newWell) {
                        setState(() {
                          _activeWell = newWell;
                          _wellName = newWell.name;
                          _userRole = newWell.isOwner ? 'owner' : 'operator';
                        });
                      },
                    ),
                  ),
                );
              },
              onLogout: _handleLogout,
            );
          } else {
            return OperationsScreen(
              wellName: _wellName,
              wellId: _activeWell?.id,
              wells: _wells,
              onWellChanged: (well) {
                setState(() {
                  _activeWell = well;
                  _wellName = well.name;
                  _userRole = well.isOwner ? 'owner' : 'operator';
                });
              },
              onLogout: _handleLogout,
            );
          }
        },
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

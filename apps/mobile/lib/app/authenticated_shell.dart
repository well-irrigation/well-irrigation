import 'package:flutter/material.dart';

import '../core/api/app_bootstrap_repository.dart';
import '../core/identity/app_identity.dart';
import '../features/farmers/farmers_directory_screen.dart';
import '../features/finance/expenses_screen.dart';
import '../features/finance/partner_overview_screen.dart';
import '../features/finance/partners_screen.dart';
import '../features/history/session_history_screen.dart';
import '../features/home/home_screen.dart';
import '../features/operations/operations_screen.dart';
import '../features/settings/more_settings_screen.dart';
import '../features/well_management/reports_analytics_screen.dart';
import '../features/well_management/well_management_hub_screen.dart';

/// واجهة المستخدم المصدَّق: التوجيه بحسب دوره على بئره النشط، والتنقل بينها.
///
/// لا يُبنى إلا بهوية حقيقية جاءت من [IdentityGate]، فلا مكان هنا لبئر
/// افتراضي ولا لدور افتراضي: الدور من `identity.isOwner` وحده (UX-05 /
/// UX-13 / ق-87 / ق-98)، ويتبدّل مع البئر النشط.
class AuthenticatedShell extends StatelessWidget {
  const AuthenticatedShell({
    required this.identity,
    required this.onWellChanged,
    required this.onLogout,
    super.key,
  });

  final AppIdentity identity;
  final ValueChanged<WellSummary> onWellChanged;
  final VoidCallback onLogout;

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    // شريكٌ بلا دور تشغيلي: شاشته اطلاع فقط. توجيهه إلى شاشة العمليات كان
    // يعرض عليه أزرار بدء جلسة يرفضها الخادم، وأرقام جلسة جارية خارج نطاقه
    // المُقرَّر (ق-123 §8 / الثابت 713).
    if (identity.isPartnerOnly) {
      return PartnerOverviewScreen(
        identity: identity,
        onWellChanged: onWellChanged,
        onLogout: onLogout,
      );
    }

    if (!identity.isOwner) {
      return OperationsScreen(
        identity: identity,
        onWellChanged: onWellChanged,
        onLogout: onLogout,
      );
    }

    return HomeScreen(
      identity: identity,
      onWellChanged: onWellChanged,
      onLogout: onLogout,
      onNavigateToOperations: () => _push(
        context,
        OperationsScreen(
          identity: identity,
          onWellChanged: onWellChanged,
          onLogout: onLogout,
        ),
      ),
      onNavigateToHistory: () => _push(
        context,
        SessionHistoryScreen(
          identity: identity,
          onWellChanged: onWellChanged,
          onLogout: onLogout,
        ),
      ),
      onNavigateToFarmers: () => _push(
        context,
        FarmersDirectoryScreen(
          identity: identity,
          onWellChanged: onWellChanged,
          onLogout: onLogout,
        ),
      ),
      onNavigateToExpenses: () => _push(
        context,
        ExpensesScreen(identity: identity, onWellChanged: onWellChanged),
      ),
      onNavigateToPartners: () => _push(
        context,
        PartnersScreen(identity: identity, onWellChanged: onWellChanged),
      ),
      onNavigateToWellManagement: () => _push(
        context,
        WellManagementHubScreen(
          identity: identity,
          onWellChanged: onWellChanged,
        ),
      ),
      onNavigateToReports: () => _push(
        context,
        ReportsAnalyticsScreen(
          identity: identity,
          onWellChanged: onWellChanged,
        ),
      ),
      onNavigateToMoreSettings: () => _push(
        context,
        MoreSettingsScreen(
          identity: identity,
          onWellChanged: onWellChanged,
          onLogout: onLogout,
        ),
      ),
    );
  }
}

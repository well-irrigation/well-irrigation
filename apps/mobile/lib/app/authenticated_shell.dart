import 'package:flutter/material.dart';

import '../core/api/app_bootstrap_repository.dart';
import '../core/identity/app_identity.dart';
import '../features/bookings/bookings_screen.dart';
import '../features/farmers/farmers_directory_screen.dart';
import '../features/finance/expenses_screen.dart';
import '../features/finance/operator_cash_custody_screen.dart';
import '../features/finance/partner_overview_screen.dart';
import '../features/finance/partners_screen.dart';
import '../features/history/session_history_screen.dart';
import '../features/home/home_screen.dart';
import '../features/operations/operations_screen.dart';
import '../features/settings/more_settings_screen.dart';
import '../features/well_management/reports_analytics_screen.dart';
import '../features/well_management/fuel_inventory_screen.dart';
import '../features/well_management/well_management_hub_screen.dart';

/// واجهة المستخدم المصدَّق: التوجيه بحسب دوره على بئره النشط، والتنقل بينها.
///
/// لا يُبنى إلا بهوية حقيقية جاءت من [IdentityGate]، فلا مكان هنا لبئر
/// افتراضي ولا لدور افتراضي: الدور من البئر النشط وحده (UX-05 / UX-13 /
/// ق-87 / ق-98)، ويتبدّل مع البئر النشط.
class AuthenticatedShell extends StatelessWidget {
  const AuthenticatedShell({
    required this.identity,
    required this.onWellChanged,
    required this.onLogout,
    this.isTrustedOfflineBootstrap = false,
    super.key,
  });

  final AppIdentity identity;
  final ValueChanged<WellSummary> onWellChanged;
  final VoidCallback onLogout;

  /// دُخِل هذا الغلاف عبر لقطة bootstrap موثوقة مخبّأة لتعذّر القراءة الحيّة
  /// عند الإقلاع. لا يصف اتصالًا حيًّا ولا يعطّل العمليات الميدانية المصرَّح
  /// بها دون اتصال؛ يحجب فقط الوجهات التي تتطلب سلطة/حالة خادم حيّة.
  final bool isTrustedOfflineBootstrap;

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  /// وجهة تحتاج الخادم ولا تُفتح أثناء البدء البارد الموثوق دون اتصال: لا
  /// يُدفع المسار، وتُعرض رسالة واضحة بدل كشف فعل خادمي يفشل.
  void _blockedOffline(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'هذا القسم يحتاج اتصالًا بالخادم. أعد المحاولة بعد عودة الإنترنت.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shell = _buildRoleShell(context);
    if (!isTrustedOfflineBootstrap) return shell;
    // إشعار مستمر غير حاجب: التطبيق يعرض بيانات محفوظة قد لا تكون حديثة،
    // والعمليات الميدانية المدعومة دون اتصال ستُحفظ للمزامنة. ليس حوارًا
    // حاجبًا ولا الغلاف المصغّر المرفوض؛ أصغر آلية عرض متاحة في هذا الملف.
    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.cloud_off_outlined, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'دون اتصال — تعرض بيانات محفوظة. العمليات المدعومة دون '
                      'اتصال ستُحفظ للمزامنة.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(child: shell),
      ],
    );
  }

  Widget _buildRoleShell(BuildContext context) {
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

    if (!identity.isOwner && !identity.isOperator) {
      return OperationsScreen(
        identity: identity,
        onWellChanged: onWellChanged,
        onLogout: onLogout,
        isTrustedOfflineBootstrap: isTrustedOfflineBootstrap,
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
          isTrustedOfflineBootstrap: isTrustedOfflineBootstrap,
        ),
      ),
      onNavigateToBookings: () => _push(
        context,
        BookingsScreen(
          identity: identity,
          onlineOverride: !isTrustedOfflineBootstrap,
          onOpenOperations: () => _push(
            context,
            OperationsScreen(
              identity: identity,
              onWellChanged: onWellChanged,
              onLogout: onLogout,
              isTrustedOfflineBootstrap: isTrustedOfflineBootstrap,
            ),
          ),
        ),
      ),
      onNavigateToHistory: () => isTrustedOfflineBootstrap
          ? _blockedOffline(context)
          : _push(
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
      onNavigateToExpenses: () => isTrustedOfflineBootstrap
          ? _blockedOffline(context)
          : _push(
              context,
              ExpensesScreen(identity: identity, onWellChanged: onWellChanged),
            ),
      onNavigateToFuelInventory: () => isTrustedOfflineBootstrap
          ? _blockedOffline(context)
          : _push(
              context,
              FuelInventoryScreen(
                identity: identity,
                onWellChanged: onWellChanged,
              ),
            ),
      onNavigateToCashCustody: () => isTrustedOfflineBootstrap
          ? _blockedOffline(context)
          : _push(context, OperatorCashCustodyScreen(identity: identity)),
      onNavigateToPartners: () => isTrustedOfflineBootstrap
          ? _blockedOffline(context)
          : _push(
              context,
              PartnersScreen(identity: identity, onWellChanged: onWellChanged),
            ),
      onNavigateToWellManagement: () => isTrustedOfflineBootstrap
          ? _blockedOffline(context)
          : _push(
              context,
              WellManagementHubScreen(
                identity: identity,
                onWellChanged: onWellChanged,
              ),
            ),
      onNavigateToReports: () => isTrustedOfflineBootstrap
          ? _blockedOffline(context)
          : _push(
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
          isTrustedOfflineBootstrap: isTrustedOfflineBootstrap,
        ),
      ),
    );
  }
}

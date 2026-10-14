import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/app/authenticated_shell.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/features/home/home_screen.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';
import 'package:well_irrigation_mobile/features/settings/more_settings_screen.dart';
import 'package:well_irrigation_mobile/features/settings/profile_security_screen.dart';
import 'package:well_irrigation_mobile/features/finance/expenses_screen.dart';
import 'package:well_irrigation_mobile/features/finance/partners_screen.dart';
import 'package:well_irrigation_mobile/features/finance/operator_cash_custody_screen.dart';
import 'package:well_irrigation_mobile/features/well_management/fuel_inventory_screen.dart';
import 'package:well_irrigation_mobile/features/well_management/reports_analytics_screen.dart';
import 'package:well_irrigation_mobile/features/well_management/well_management_hub_screen.dart';
import 'package:well_irrigation_mobile/features/history/session_history_screen.dart';
import 'package:well_irrigation_mobile/features/farmers/farmers_directory_screen.dart';

import '../support/identity_fixture.dart';

const _ownerWell = WellSummary(
  id: 'well-1',
  tenantId: 'tenant-1',
  name: 'بئر الخير الرئيسي',
  status: 'active',
  roles: ['owner', 'operator'],
);

const _blockMessage =
    'هذا القسم يحتاج اتصالًا بالخادم. أعد المحاولة بعد عودة الإنترنت.';

Widget _shell({required bool offline}) => MaterialApp(
  locale: const Locale('ar'),
  home: AuthenticatedShell(
    identity: testIdentity(),
    onWellChanged: (_) {},
    onLogout: () {},
    isTrustedOfflineBootstrap: offline,
  ),
);

class _FlagHarness extends StatefulWidget {
  const _FlagHarness({super.key});
  @override
  State<_FlagHarness> createState() => _FlagHarnessState();
}

class _FlagHarnessState extends State<_FlagHarness> {
  bool offline = true;
  void setOffline(bool value) => setState(() => offline = value);
  @override
  Widget build(BuildContext context) => AuthenticatedShell(
    identity: testIdentity(),
    onWellChanged: (_) {},
    onLogout: () {},
    isTrustedOfflineBootstrap: offline,
  );
}

void main() {
  testWidgets('trusted offline shell shows the real home + offline notice', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_shell(offline: true));
    await tester.pump();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.textContaining('تعرض بيانات محفوظة'), findsOneWidget);
  });

  testWidgets('server-only destinations are blocked and do not push', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_shell(offline: true));
    await tester.pump();
    final home = tester.widget<HomeScreen>(find.byType(HomeScreen));

    home.onNavigateToExpenses!();
    await tester.pump();
    expect(find.text(_blockMessage), findsWidgets);
    expect(find.byType(ExpensesScreen), findsNothing);

    home.onNavigateToFuelInventory!();
    await tester.pump();
    expect(find.byType(FuelInventoryScreen), findsNothing);

    home.onNavigateToCashCustody!();
    await tester.pump();
    expect(find.byType(OperatorCashCustodyScreen), findsNothing);

    home.onNavigateToPartners!();
    await tester.pump();
    expect(find.byType(PartnersScreen), findsNothing);

    home.onNavigateToWellManagement!();
    await tester.pump();
    expect(find.byType(WellManagementHubScreen), findsNothing);

    home.onNavigateToReports!();
    await tester.pump();
    expect(find.byType(ReportsAnalyticsScreen), findsNothing);

    home.onNavigateToHistory!();
    await tester.pump();
    expect(find.byType(SessionHistoryScreen), findsNothing);
  });
  group('offline-capable areas (direct build, injected coordinator)', () {
    late OfflineSessionCoordinator coordinator;
    setUp(() async {
      coordinator = OfflineSessionCoordinator(store: InMemoryOutboxStore());
      await coordinator.initialize();
    });
    tearDown(() => coordinator.dispose());

    testWidgets('farmers directory opens offline (not a server-only area)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: FarmersDirectoryScreen(
            identity: testIdentity(wells: const [_ownerWell]),
            coordinator: coordinator,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FarmersDirectoryScreen), findsOneWidget);
      expect(find.text(_blockMessage), findsNothing);
    });

    testWidgets(
      'operations honours the offline flag without disabling session start',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: OperationsScreen(
              identity: testIdentity(wells: const [_ownerWell]),
              coordinator: coordinator,
              isTrustedOfflineBootstrap: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final ops = tester.widget<OperationsScreen>(
          find.byType(OperationsScreen),
        );
        expect(ops.isTrustedOfflineBootstrap, isTrue);
        // أفعال الجلسة المصرَّح بها دون اتصال تبقى متاحة: زر البدء حاضر.
        expect(find.text('بدء جلسة سقي جديدة'), findsOneWidget);
      },
    );
  });

  testWidgets('more/settings receives the offline flag through the shell', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_shell(offline: true));
    await tester.pump();
    final home = tester.widget<HomeScreen>(find.byType(HomeScreen));
    home.onNavigateToMoreSettings!();
    await tester.pumpAndSettle();
    final more = tester.widget<MoreSettingsScreen>(
      find.byType(MoreSettingsScreen),
    );
    expect(more.isTrustedOfflineBootstrap, isTrue);
  });
  testWidgets('more/settings keeps sign-out but blocks account & security', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        home: MoreSettingsScreen(
          identity: testIdentity(),
          isTrustedOfflineBootstrap: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // الشاشة نفسها متاحة، وتسجيل الخروج يبقى في المتناول.
    expect(find.textContaining('تسجيل الخروج'), findsWidgets);

    // الدخول إلى الحساب والأمان محجوب بإشعار صريح، ولا تُفتح الشاشة.
    await tester.tap(find.text('حسابي والملف الشخصي'));
    await tester.pump();
    expect(
      find.text('إعدادات الحساب والأمان تحتاج اتصالًا بالخادم.'),
      findsOneWidget,
    );
    expect(find.byType(ProfileSecurityScreen), findsNothing);
  });

  testWidgets('reconnect rebuilds the same shell without the offline flag', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey<_FlagHarnessState>();
    await tester.pumpWidget(
      MaterialApp(locale: const Locale('ar'), home: _FlagHarness(key: key)),
    );
    await tester.pump();
    expect(find.textContaining('تعرض بيانات محفوظة'), findsOneWidget);
    expect(find.byType(HomeScreen), findsOneWidget);

    // عودة الاتصال تعيد بناء الغلاف نفسه بعلم false بلا إعادة تشغيل.
    key.currentState!.setOffline(false);
    await tester.pump();
    expect(find.textContaining('تعرض بيانات محفوظة'), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });
}

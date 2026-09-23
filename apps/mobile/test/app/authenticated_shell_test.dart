import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/app/authenticated_shell.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/identity/app_identity.dart';
import 'package:well_irrigation_mobile/features/finance/partner_overview_screen.dart';
import 'package:well_irrigation_mobile/features/home/home_screen.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';

import '../support/identity_fixture.dart';

class _ShellHarness extends StatefulWidget {
  const _ShellHarness({required this.identity});

  final AppIdentity identity;

  @override
  State<_ShellHarness> createState() => _ShellHarnessState();
}

class _ShellHarnessState extends State<_ShellHarness> {
  late AppIdentity _identity = widget.identity;

  @override
  Widget build(BuildContext context) {
    return AuthenticatedShell(
      identity: _identity,
      onWellChanged: (well) {
        setState(() => _identity = _identity.withActiveWell(well));
      },
      onLogout: () {},
    );
  }
}

void main() {
  Widget wrap(AppIdentity identity) {
    return MaterialApp(
      locale: const Locale('ar'),
      home: _ShellHarness(identity: identity),
    );
  }

  testWidgets('المشغّل يبدأ من الرئيسية لا من شاشة العمليات', (tester) async {
    await tester.pumpWidget(
      wrap(
        testIdentity(
          wells: [
            testWell(roles: const ['operator']),
          ],
        ),
      ),
    );

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(OperationsScreen), findsNothing);
  });

  testWidgets('المالك يبدأ من الرئيسية', (tester) async {
    await tester.pumpWidget(wrap(testIdentity()));

    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('الشريك وحده يبقى في ملخص الشريك', (tester) async {
    await tester.pumpWidget(
      wrap(
        testIdentity(
          wells: [
            testWell(roles: const ['partner']),
          ],
        ),
      ),
    );

    expect(find.byType(PartnerOverviewScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('السحب إلى بئر المشغّل يبقي المستخدم في الرئيسية', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const operatorWell = WellSummary(
      id: 'well-2',
      tenantId: 'tenant-2',
      name: 'بئر التشغيل',
      status: 'active',
      roles: ['operator'],
    );
    await tester.pumpWidget(
      wrap(testIdentity(wells: [testWell(), operatorWell])),
    );

    await tester.drag(find.text('بئر الخير الرئيسي'), const Offset(-700, 0));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(OperationsScreen), findsNothing);
    expect(find.text('سجل الجلسات'), findsWidgets);
    expect(find.text('التقارير والمؤشرات'), findsNothing);
  });
}

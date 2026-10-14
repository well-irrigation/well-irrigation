import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/app/authenticated_shell.dart';
import 'package:well_irrigation_mobile/features/bookings/bookings_screen.dart';
import 'package:well_irrigation_mobile/features/home/home_screen.dart';

import '../../support/identity_fixture.dart';

void main() {
  testWidgets('الرئيسية تفتح قسم الحجوزات المستقل لا شاشة العمليات', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        home: AuthenticatedShell(
          identity: testIdentity(),
          onWellChanged: (_) {},
          onLogout: () {},
        ),
      ),
    );
    await tester.pump();
    final home = tester.widget<HomeScreen>(find.byType(HomeScreen));

    // قسم مستقل: الحجوزات ليست شاشة العمليات.
    home.onNavigateToBookings!();
    await tester.pumpAndSettle();
    expect(find.byType(BookingsScreen), findsOneWidget);
  });

  testWidgets('بطاقة الحجوزات بحجم بطاقة نظيرة لا بطاقة مهيمنة بعرض كامل', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        home: AuthenticatedShell(
          identity: testIdentity(),
          onWellChanged: (_) {},
          onLogout: () {},
        ),
      ),
    );
    await tester.pump();

    Size tileSize(String title) => tester.getSize(
      find.ancestor(of: find.text(title), matching: find.byType(InkWell)).first,
    );

    final booking = tileSize('الحجوزات');
    final peer = tileSize('سجل الجلسات');
    // نفس فئة الحجم كبطاقة نظيرة، وليست بعرض الشاشة (3 أعمدة ≈ الثلث).
    expect((booking.width - peer.width).abs() < 1.0, isTrue);
    expect(booking.width < 1200 * 0.45, isTrue);
  });
}

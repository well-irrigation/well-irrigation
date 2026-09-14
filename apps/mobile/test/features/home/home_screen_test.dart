import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/home/home_screen.dart';
import 'package:well_irrigation_mobile/features/home/widgets/announcement_banner_slider.dart';
import 'package:well_irrigation_mobile/features/home/widgets/home_bottom_nav_bar.dart';

import '../../support/identity_fixture.dart';

/// حرس تخطيط وتفاعل الشاشة الرئيسية المعيارية 1:1 (UX-15 / ق-127).
void main() {
  Widget wrap({
    VoidCallback? onNavigateToOperations,
    VoidCallback? onNavigateToHistory,
    VoidCallback? onNavigateToFarmers,
    VoidCallback? onNavigateToExpenses,
    VoidCallback? onNavigateToPartners,
    VoidCallback? onNavigateToWellManagement,
    VoidCallback? onNavigateToReports,
    VoidCallback? onNavigateToMoreSettings,
  }) {
    return MaterialApp(
      locale: const Locale('ar'),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: HomeScreen(
          identity: testIdentity(),
          onNavigateToOperations: onNavigateToOperations,
          onNavigateToHistory: onNavigateToHistory,
          onNavigateToFarmers: onNavigateToFarmers,
          onNavigateToExpenses: onNavigateToExpenses,
          onNavigateToPartners: onNavigateToPartners,
          onNavigateToWellManagement: onNavigateToWellManagement,
          onNavigateToReports: onNavigateToReports,
          onNavigateToMoreSettings: onNavigateToMoreSettings,
        ),
      ),
    );
  }

  testWidgets('الرئيسية تُرسم بلا استثناء وتعرض مكوناتها وشبكة 3x3 كاملة', (
    tester,
  ) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    // التحقق من وجود شريط التنقل السفلي والزر العائم والمستجدات
    expect(find.byType(HomeBottomNavBar), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.byType(AnnouncementBannerSlider), findsOneWidget);

    // وجهات شريط التنقل السفلي
    for (final navTitle in const [
      'الرئيسية',
      'العمليات',
      'التقارير',
      'المزيد',
    ]) {
      expect(find.text(navTitle), findsOneWidget, reason: 'وجهة مفقودة: $navTitle');
    }

    // شبكة الخدمات المعيارية 3×3 (9 بلاطات)
    for (final serviceTitle in const [
      'سجل الجلسات',
      'المزارعون والأراضي',
      'كشوفات الحساب',
      'المصروفات',
      'الشركاء والأرباح',
      'البئر والمعدات',
      'التقارير والمؤشرات',
      'أسعار التعرفة',
      'الإعدادات والمزيد',
    ]) {
      expect(
        find.text(serviceTitle),
        findsOneWidget,
        reason: 'خدمة مفقودة: $serviceTitle',
      );
    }
  });

  testWidgets('النقر على الزر العائم يفعّل بدء التشغيل الميداني', (
    tester,
  ) async {
    var operationsClicked = false;
    await tester.pumpWidget(
      wrap(onNavigateToOperations: () => operationsClicked = true),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(operationsClicked, isTrue);
  });

  testWidgets('النقر على عناصر شبكة الخدمات يفعّل المسارات الحقيقية', (
    tester,
  ) async {
    var historyClicked = false;
    var farmersClicked = false;
    var expensesClicked = false;

    await tester.pumpWidget(
      wrap(
        onNavigateToHistory: () => historyClicked = true,
        onNavigateToFarmers: () => farmersClicked = true,
        onNavigateToExpenses: () => expensesClicked = true,
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('سجل الجلسات'));
    await tester.tap(find.text('سجل الجلسات'));
    await tester.pumpAndSettle();
    expect(historyClicked, isTrue);

    await tester.ensureVisible(find.text('المزارعون والأراضي'));
    await tester.tap(find.text('المزارعون والأراضي'));
    await tester.pumpAndSettle();
    expect(farmersClicked, isTrue);

    await tester.ensureVisible(find.text('المصروفات'));
    await tester.tap(find.text('المصروفات'));
    await tester.pumpAndSettle();
    expect(expensesClicked, isTrue);
  });

  testWidgets('البئر غير النشط لا يُعلن جاهزًا للتشغيل', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: HomeScreen(
            identity: testIdentity(wells: [testWell(status: 'inactive')]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('غير نشط'), findsOneWidget);
    expect(find.text('غير متاح للتشغيل'), findsOneWidget);
    expect(find.text('جاهز للتشغيل'), findsNothing);
  });

  testWidgets('الرئيسية تدعم التمرير السلس وتتحمل أحجام الشاشات المختلفة', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(Scrollable), findsWidgets);
  });
}

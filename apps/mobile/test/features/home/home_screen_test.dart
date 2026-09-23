import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/home/home_screen.dart';
import 'package:well_irrigation_mobile/features/home/widgets/announcement_banner_slider.dart';
import 'package:well_irrigation_mobile/features/home/widgets/home_bottom_nav_bar.dart';
import 'package:well_irrigation_mobile/core/identity/app_identity.dart';

import '../../support/identity_fixture.dart';

/// حرس تخطيط وتفاعل الشاشة الرئيسية المعيارية 1:1 (UX-15 / ق-127).
void main() {
  Widget wrap({
    AppIdentity? identity,
    VoidCallback? onNavigateToOperations,
    VoidCallback? onNavigateToHistory,
    VoidCallback? onNavigateToFarmers,
    VoidCallback? onNavigateToExpenses,
    VoidCallback? onNavigateToPartners,
    VoidCallback? onNavigateToWellManagement,
    VoidCallback? onNavigateToReports,
    VoidCallback? onNavigateToMoreSettings,
    VoidCallback? onNavigateToFuelInventory,
  }) {
    return MaterialApp(
      locale: const Locale('ar'),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: HomeScreen(
          identity: identity ?? testIdentity(),
          onNavigateToOperations: onNavigateToOperations,
          onNavigateToHistory: onNavigateToHistory,
          onNavigateToFarmers: onNavigateToFarmers,
          onNavigateToExpenses: onNavigateToExpenses,
          onNavigateToPartners: onNavigateToPartners,
          onNavigateToWellManagement: onNavigateToWellManagement,
          onNavigateToReports: onNavigateToReports,
          onNavigateToMoreSettings: onNavigateToMoreSettings,
          onNavigateToFuelInventory: onNavigateToFuelInventory,
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
      expect(
        find.text(navTitle),
        findsOneWidget,
        reason: 'وجهة مفقودة: $navTitle',
      );
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

  testWidgets('كل بطاقة تعرض دور البئر الذي تمثله', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final ownerWell = testWell(name: 'بئر المالك');
    final operatorWell = testWell(
      id: 'well-2',
      name: 'بئر المشغّل',
      roles: const ['operator'],
    );
    await tester.pumpWidget(
      wrap(identity: testIdentity(wells: [ownerWell, operatorWell])),
    );
    await tester.pumpAndSettle();

    expect(find.text('مالك البئر'), findsOneWidget);
    expect(find.text('مشغّل معتمد'), findsOneWidget);
  });

  testWidgets('رئيسية المشغّل تعرض خدماته وتحجب خدمات المالك', (tester) async {
    await tester.pumpWidget(
      wrap(
        identity: testIdentity(
          wells: [
            testWell(roles: const ['operator']),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final title in const [
      'العمليات',
      'سجل الجلسات',
      'المزارعون والأراضي',
      'المصروفات',
      'مخزون الوقود',
      'الإعدادات والمزيد',
    ]) {
      expect(find.text(title), findsWidgets, reason: 'خدمة مفقودة: $title');
    }
    for (final title in const [
      'الشركاء والأرباح',
      'البئر والمعدات',
      'التقارير والمؤشرات',
      'أسعار التعرفة',
    ]) {
      expect(find.text(title), findsNothing, reason: 'خدمة مالك ظاهرة: $title');
    }

    expect(find.text('سجل الجلسات'), findsNWidgets(2));
    expect(find.text('التقارير'), findsNothing);
    expect(find.byType(AnnouncementBannerSlider), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
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

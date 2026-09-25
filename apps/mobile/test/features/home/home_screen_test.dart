import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/identity/app_identity.dart';
import 'package:well_irrigation_mobile/features/home/home_screen.dart';
import 'package:well_irrigation_mobile/features/home/widgets/announcement_banner_slider.dart';
import 'package:well_irrigation_mobile/features/home/widgets/home_bottom_nav_bar.dart';

import '../../support/identity_fixture.dart';

class _RoleSwitchingHomeHarness extends StatefulWidget {
  const _RoleSwitchingHomeHarness({
    required this.ownerWell,
    required this.operatorWell,
  });

  final WellSummary ownerWell;
  final WellSummary operatorWell;

  @override
  State<_RoleSwitchingHomeHarness> createState() =>
      _RoleSwitchingHomeHarnessState();
}

class _RoleSwitchingHomeHarnessState extends State<_RoleSwitchingHomeHarness> {
  late AppIdentity _identity = testIdentity(
    wells: [widget.ownerWell, widget.operatorWell],
  );

  @override
  Widget build(BuildContext context) {
    return HomeScreen(
      identity: _identity,
      onWellChanged: (well) {
        setState(() => _identity = _identity.withActiveWell(well));
      },
    );
  }
}

/// حرس تخطيط وتفاعل الشاشة الرئيسية المعيارية 1:1 (UX-15 / ق-127).
void main() {
  Finder bannerPageView() => find.descendant(
    of: find.byType(AnnouncementBannerSlider),
    matching: find.byType(PageView),
  );

  int configuredBannerCount(WidgetTester tester) {
    return tester
        .widget<PageView>(bannerPageView())
        .childrenDelegate
        .estimatedChildCount!;
  }

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
    expect(
      tester
          .widget<AnnouncementBannerSlider>(
            find.byType(AnnouncementBannerSlider),
          )
          .showReports,
      isTrue,
    );
    expect(configuredBannerCount(tester), 4);

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
    expect(find.byType(AnnouncementBannerSlider), findsOneWidget);
    expect(
      tester
          .widget<AnnouncementBannerSlider>(
            find.byType(AnnouncementBannerSlider),
          )
          .showReports,
      isFalse,
    );
    expect(configuredBannerCount(tester), 3);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('شريط المشغّل يحتفظ بالإجراءات الثلاثة ويحجب التقارير', (
    tester,
  ) async {
    var farmersClicked = false;
    var historyClicked = false;
    var operationsClicked = false;
    await tester.pumpWidget(
      wrap(
        identity: testIdentity(
          wells: [
            testWell(roles: const ['operator']),
          ],
        ),
        onNavigateToFarmers: () => farmersClicked = true,
        onNavigateToHistory: () => historyClicked = true,
        onNavigateToOperations: () => operationsClicked = true,
        onNavigateToReports: () => fail('تقارير المالك غير متاحة للمشغّل'),
      ),
    );
    await tester.pumpAndSettle();

    final controller = tester.widget<PageView>(bannerPageView()).controller!;

    expect(find.text('كشوفات وحسابات'), findsOneWidget);
    expect(find.text('متابعة كشوفات وأرصدة المزارعين'), findsOneWidget);
    await tester.tap(find.text('فتح الدليل'));
    expect(farmersClicked, isTrue);

    controller.jumpToPage(1);
    await tester.pump();
    expect(find.text('فواتير وسندات'), findsOneWidget);
    expect(find.text('طباعة فورية عبر طابعة البلوتوث'), findsOneWidget);
    await tester.tap(find.text('سجل العمليات'));
    expect(historyClicked, isTrue);

    controller.jumpToPage(2);
    await tester.pump();
    expect(find.text('تشغيل ميداني'), findsOneWidget);
    expect(find.text('تسجيل عداد البدء وإطلاق المضخة'), findsOneWidget);
    await tester.tap(find.text('بدء السقي'));
    expect(operationsClicked, isTrue);

    expect(find.text('مؤشرات وإنتاجية'), findsNothing);
    expect(find.text('تقارير الاستهلاك وتوزيع الأرباح'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('تبديل دور البئر يحدّث إعداد الشريط دون حالة صفحة قديمة', (
    tester,
  ) async {
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
      MaterialApp(
        locale: const Locale('ar'),
        home: _RoleSwitchingHomeHarness(
          ownerWell: ownerWell,
          operatorWell: operatorWell,
        ),
      ),
    );
    await tester.pumpAndSettle();

    var slider = tester.widget<AnnouncementBannerSlider>(
      find.byType(AnnouncementBannerSlider),
    );
    expect(slider.showReports, isTrue);
    expect(configuredBannerCount(tester), 4);
    tester.widget<PageView>(bannerPageView()).controller!.jumpToPage(3);
    await tester.pump();

    await tester.drag(find.text('بئر المالك'), const Offset(-700, 0));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(AnnouncementBannerSlider), findsOneWidget);
    slider = tester.widget<AnnouncementBannerSlider>(
      find.byType(AnnouncementBannerSlider),
    );
    expect(slider.showReports, isFalse);
    expect(configuredBannerCount(tester), 3);
    expect(find.text('مؤشرات وإنتاجية'), findsNothing);

    await tester.drag(find.text('بئر المشغّل'), const Offset(700, 0));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    slider = tester.widget<AnnouncementBannerSlider>(
      find.byType(AnnouncementBannerSlider),
    );
    expect(slider.showReports, isTrue);
    expect(configuredBannerCount(tester), 4);
    final ownerController = tester
        .widget<PageView>(bannerPageView())
        .controller!;
    ownerController.jumpToPage(2);
    await tester.pump();
    expect(find.text('مؤشرات وإنتاجية'), findsOneWidget);
    expect(find.text('تقارير الاستهلاك وتوزيع الأرباح'), findsOneWidget);
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

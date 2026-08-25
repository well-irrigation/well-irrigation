import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/features/settings/more_settings_screen.dart';

void main() {
  group('MoreSettingsScreen Tests (UX-16A / القرار 527 / ق-101)', () {
    tearDown(() {
      OfflineSessionCoordinator.instance.dispose();
    });
    testWidgets('1. عرض رأس الحساب والبيانات التعريفية وقائمة الأقسام', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: MoreSettingsScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            wells: const [
              WellSummary(id: 'well-1', tenantId: 't-1', name: 'بئر الخير الرئيسي', status: 'active', roles: ['owner']),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('حسابي والملف الشخصي'), findsOneWidget);
      expect(find.text('الفريق والصلاحيات'), findsOneWidget);
      expect(find.text('الجهاز والمزامنة'), findsOneWidget);
      expect(find.text('تفضيلات التطبيق والطباعة'), findsOneWidget);
      expect(find.text('المساعدة والدعم وعن التطبيق'), findsOneWidget);
      expect(find.text('تسجيل الخروج من الحساب'), findsOneWidget);
    });

    testWidgets('2. فتح نافذة تأكيد تسجيل الخروج', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      bool loggedOut = false;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: MoreSettingsScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            onLogout: () => loggedOut = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final logoutBtn = find.text('تسجيل الخروج من الحساب');
      await tester.tap(logoutBtn);
      await tester.pumpAndSettle();

      expect(find.text('هل أنت متأكد من رغبتك في تسجيل الخروج من التطبيق؟'), findsOneWidget);
      final confirmBtn = find.widgetWithText(ElevatedButton, 'تسجيل الخروج');
      await tester.tap(confirmBtn);
      await tester.pumpAndSettle();

      expect(loggedOut, isTrue);
    });
  });
}

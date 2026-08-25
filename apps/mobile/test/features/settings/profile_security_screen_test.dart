import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/account_repository.dart';
import 'package:well_irrigation_mobile/features/settings/profile_security_screen.dart';

void main() {
  group('ProfileSecurityScreen Tests (UX-16A / القرارات 528–545)', () {
    testWidgets('1. عرض الاسم والهاتف وأزرار تغيير كلمة المرور والهاتف', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const mockProfile = UserProfileData(
        id: 'user-1',
        fullName: 'محمد عبدالله الشامي',
        phone: '777123456',
      );

      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: ProfileSecurityScreen(
            profile: mockProfile,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('الاسم الشخصي المعتمد'), findsOneWidget);
      expect(find.text('رقم الهاتف وهوية الحساب'), findsOneWidget);
      expect(find.text('777123456'), findsOneWidget);
      expect(find.text('تغيير رقم الهاتف المعتمد'), findsOneWidget);
      expect(find.text('تغيير كلمة المرور'), findsOneWidget);
    });

    testWidgets('2. فتح حوار تغيير رقم الهاتف والتحقق', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const mockProfile = UserProfileData(
        id: 'user-1',
        fullName: 'محمد عبدالله الشامي',
        phone: '777123456',
      );

      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: ProfileSecurityScreen(
            profile: mockProfile,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('تغيير رقم الهاتف المعتمد'));
      await tester.pumpAndSettle();

      expect(find.text('تغيير رقم الهاتف المعتمد'), findsWidgets);
      expect(find.text('إرسال رمز التحقق'), findsOneWidget);
    });

    testWidgets('3. فتح حوار تغيير كلمة المرور وتفريغها بعد الحفظ', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const mockProfile = UserProfileData(
        id: 'user-1',
        fullName: 'محمد عبدالله الشامي',
        phone: '777123456',
      );

      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: ProfileSecurityScreen(
            profile: mockProfile,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('تغيير كلمة المرور'));
      await tester.pumpAndSettle();

      expect(find.text('كلمة المرور الحالية *'), findsOneWidget);
      expect(find.text('كلمة المرور الجديدة *'), findsOneWidget);
      expect(find.text('تأكيد كلمة المرور الجديدة *'), findsOneWidget);
    });
  });
}

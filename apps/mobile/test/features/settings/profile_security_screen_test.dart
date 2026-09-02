import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/account_repository.dart';
import 'package:well_irrigation_mobile/features/settings/profile_security_screen.dart';

class _ProfileNameRepository extends AccountRepository {
  _ProfileNameRepository({
    this.fail = false,
  });

  final bool fail;
  String? savedName;

  @override
  Future<void> updateUserName(String newName) async {
    if (fail) {
      throw Exception('backend unavailable');
    }
    savedName = newName;
  }
}

/// مستودع كلمة المرور: يفصل «نجح الخادم» عن «عُرضت رسالة نجاح».
class _PasswordRepository extends AccountRepository {
  _PasswordRepository({this.fail = false});

  final bool fail;
  String? savedPassword;

  @override
  Future<void> updatePassword(String newPassword) async {
    if (fail) {
      throw StateError('Authenticated session is required');
    }
    savedPassword = newPassword;
  }
}

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
    testWidgets(
      '4. نجاح الخادم هو وحده الذي يعرض نجاح حفظ الاسم',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repository = _ProfileNameRepository();

        const profile = UserProfileData(
          id: 'user-1',
          fullName: 'الاسم القديم',
          phone: '777123456',
        );

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: ProfileSecurityScreen(
              profile: profile,
              repository: repository,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final nameField = find.byType(TextFormField).first;
        await tester.enterText(nameField, 'الاسم الجديد');
        await tester.tap(find.text('حفظ الاسم'));
        await tester.pumpAndSettle();

        expect(repository.savedName, 'الاسم الجديد');
        expect(
          find.text('تم تحديث الاسم المعتمد بنجاح ✅'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '5. فشل الخادم لا يتحول إلى نجاح وهمي عند حفظ الاسم',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repository = _ProfileNameRepository(
          fail: true,
        );

        const profile = UserProfileData(
          id: 'user-1',
          fullName: 'الاسم القديم',
          phone: '777123456',
        );

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: ProfileSecurityScreen(
              profile: profile,
              repository: repository,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final nameField = find.byType(TextFormField).first;
        await tester.enterText(nameField, 'اسم لن يحفظ');
        await tester.tap(find.text('حفظ الاسم'));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'تعذر تحديث الاسم. تحقق من الاتصال وأعد المحاولة.',
          ),
          findsOneWidget,
        );

        expect(
          find.text('تم تحديث الاسم المعتمد بنجاح ✅'),
          findsNothing,
        );

        expect(find.text('حفظ الاسم'), findsOneWidget);
      },
    );

    testWidgets(
      '6. فشل تغيير كلمة المرور لا يتحول إلى نجاح وهمي',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repository = _PasswordRepository(fail: true);

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: ProfileSecurityScreen(
              profile: const UserProfileData(
                id: 'user-1',
                fullName: 'محمد عبدالله الشامي',
                phone: '777123456',
              ),
              repository: repository,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('تغيير كلمة المرور'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'كلمة المرور الجديدة *'),
          'كلمة-جديدة-1',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'تأكيد كلمة المرور الجديدة *'),
          'كلمة-جديدة-1',
        );
        await tester.tap(find.text('حفظ كلمة المرور'));
        await tester.pumpAndSettle();

        expect(repository.savedPassword, isNull);
        expect(
          find.text(
            'تعذر تغيير كلمة المرور — لم يتغيّر شيء، وكلمتك الحالية ما زالت صالحة',
          ),
          findsOneWidget,
        );
        expect(find.text('تم تغيير كلمة المرور بنجاح ✅'), findsNothing);
        // الحوار يبقى مفتوحًا لإعادة المحاولة بعد تفريغ الحقول (ق-118).
        expect(find.text('حفظ كلمة المرور'), findsOneWidget);
      },
    );

    testWidgets(
      '7. نجاح الخادم وحده يعرض نجاح تغيير كلمة المرور ويغلق الحوار',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repository = _PasswordRepository();

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: ProfileSecurityScreen(
              profile: const UserProfileData(
                id: 'user-1',
                fullName: 'محمد عبدالله الشامي',
                phone: '777123456',
              ),
              repository: repository,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('تغيير كلمة المرور'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'كلمة المرور الجديدة *'),
          'كلمة-جديدة-1',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'تأكيد كلمة المرور الجديدة *'),
          'كلمة-جديدة-1',
        );
        await tester.tap(find.text('حفظ كلمة المرور'));
        await tester.pumpAndSettle();

        expect(repository.savedPassword, 'كلمة-جديدة-1');
        expect(find.text('تم تغيير كلمة المرور بنجاح ✅'), findsOneWidget);
        expect(find.text('كلمة المرور الحالية *'), findsNothing);
      },
    );

  });
}

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
///
/// [wrongCurrent] يحاكي رفض إعادة المصادقة، وهو ما يفصل «كلمتك الحالية
/// خطأ» عن «تعذر الاتصال» على الشاشة (ق-105 / م-41E المرحلة 1).
class _PasswordRepository extends AccountRepository {
  _PasswordRepository({this.fail = false, this.wrongCurrent = false});

  final bool fail;
  final bool wrongCurrent;
  String? savedPassword;

  /// كلمة المرور الحالية كما وصلت المستودع. `null` يعني أنها لم تُقرأ.
  String? receivedCurrentPassword;

  @override
  Future<void> updatePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    receivedCurrentPassword = currentPassword;
    if (wrongCurrent) {
      throw const WrongCurrentPasswordException();
    }
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
      expect(find.text('تغيير رقم الهاتف (غير متاح)'), findsOneWidget);
      expect(find.text('تغيير كلمة المرور'), findsOneWidget);
      // الشارة لا تدّعي تحقّقًا لا وجود له في المنظومة (ق-124).
      expect(find.text('رقم الدخول'), findsOneWidget);
      expect(find.text('معتمد وموثق ✅'), findsNothing);
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

        // الخانة صارت تُقرأ فعلًا، فلا يمضي المسار بدونها (ق-105).
        await tester.enterText(
          find.widgetWithText(TextFormField, 'كلمة المرور الحالية *'),
          'كلمة-قديمة-1',
        );
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

        // الخانة صارت تُقرأ فعلًا، فلا يمضي المسار بدونها (ق-105).
        await tester.enterText(
          find.widgetWithText(TextFormField, 'كلمة المرور الحالية *'),
          'كلمة-قديمة-1',
        );
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

    testWidgets(
      '8. هاتف غائب في العقد يُعلن غيابه ولا يُعرض رقم مكتوب في الشاشة',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          const MaterialApp(
            locale: Locale('ar'),
            home: ProfileSecurityScreen(
              profile: UserProfileData(
                id: 'user-1',
                fullName: 'مستخدم بلا هاتف',
                phone: '',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('لا رقم هاتف في بيانات الحساب'),
          findsOneWidget,
        );
        expect(find.text('غير مقروء من العقد'), findsOneWidget);
        // الشاشة كانت تعرض رقمًا مكتوبًا فيها عند الغياب، ويظنه المستخدم
        // رقمه المعتمد (ق-113 / ق-122).
        expect(find.text('777123456'), findsNothing);
        expect(find.text('معتمد وموثق ✅'), findsNothing);
      },
    );

    testWidgets(
      '9. تغيير رقم الهاتف يُعلن عدم توفره ولا يمثّل إرسال رمز',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          const MaterialApp(
            locale: Locale('ar'),
            home: ProfileSecurityScreen(
              profile: UserProfileData(
                id: 'user-1',
                fullName: 'محمد عبدالله الشامي',
                phone: '777123456',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('تغيير رقم الهاتف (غير متاح)'));
        await tester.pumpAndSettle();

        expect(
          find.text('تغيير رقم الهاتف غير متاح في هذا الإصدار'),
          findsOneWidget,
        );
        // ادعاءات الإصدار السابق: رسالة لم تُرسل، ورمز لا يُقرأ، ونجاح
        // لتغيير لم يحدث في أي مكان (ق-113 / ق-123).
        expect(find.text('إرسال رمز التحقق'), findsNothing);
        expect(find.textContaining('تم إرسال رمز التحقق'), findsNothing);
        expect(
          find.textContaining('تم تأكيد وتحديث رقم الهاتف'),
          findsNothing,
        );
        // لا حقل رقم جديد في النافذة: لا مدخل يُوهم بأن التغيير ممكن.
        expect(
          find.widgetWithText(TextFormField, 'رقم الهاتف الجديد (7xxxxxxxx) *'),
          findsNothing,
        );
      },
    );

    testWidgets(
      '10. كلمة المرور الحالية تُقرأ وتُرسل، ورفضها يُعرض رسالة خاصة',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repository = _PasswordRepository(wrongCurrent: true);

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
          find.widgetWithText(TextFormField, 'كلمة المرور الحالية *'),
          'كلمة-خاطئة',
        );
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

        // الخانة كانت تُعرض ولا تُقرأ: هذا يُثبت وصولها إلى المستودع.
        expect(repository.receivedCurrentPassword, 'كلمة-خاطئة');
        expect(repository.savedPassword, isNull);
        expect(
          find.text('كلمة المرور الحالية غير صحيحة — لم يتغيّر شيء'),
          findsOneWidget,
        );
        expect(find.text('تم تغيير كلمة المرور بنجاح ✅'), findsNothing);
      },
    );

    testWidgets(
      '11. كلمة مرور حالية فارغة تُمنع قبل أي نداء للمستودع',
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

        // بلا كلمة مرور حالية عن قصد: المسار يجب أن يتوقف قبل المستودع.
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

        expect(find.text('أدخل كلمة المرور الحالية أولًا'), findsOneWidget);
        expect(repository.receivedCurrentPassword, isNull);
        expect(repository.savedPassword, isNull);
      },
    );

  });
}

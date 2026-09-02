import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/account_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/features/settings/more_settings_screen.dart';
import '../../support/identity_fixture.dart';

class _FakeAccountRepository extends AccountRepository {
  _FakeAccountRepository({
    this.failProfile = false,
    this.failPending = false,
  });

  final bool failProfile;
  final bool failPending;

  @override
  Future<UserProfileData> fetchUserProfile() async {
    if (failProfile) {
      throw Exception('backend unavailable');
    }

    return const UserProfileData(
      id: 'user-real-1',
      fullName: 'مستخدم الاختبار الحقيقي',
      phone: '777000111',
      rolesSummary: ['بئر الاختبار — مالك'],
    );
  }

  /// مفاتيح الحساب التي طُلب بها فحص المعلَّق. مفتاح ثابت هنا يعني فحص
  /// طابور شخص آخر قبل الخروج (ق-113).
  final List<String> pendingChecks = [];

  @override
  Future<int> checkPendingOperationsBeforeLogout(String accountId) async {
    pendingChecks.add(accountId);
    if (failPending) {
      throw StateError('outbox unreadable');
    }
    return 0;
  }
}

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
            identity: testIdentity(),
            repository: _FakeAccountRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('مستخدم الاختبار الحقيقي'), findsOneWidget);
      expect(find.text('777000111'), findsOneWidget);
      expect(find.text('محمد عبدالله الشامي'), findsNothing);
      expect(find.text('777123456'), findsNothing);

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
            identity: testIdentity(),
            repository: _FakeAccountRepository(),
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
    testWidgets(
      '3. فشل تحميل الحساب لا يعرض بيانات وهمية',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: MoreSettingsScreen(
              identity: testIdentity(
                wells: [testWell(name: 'بئر الاختبار')],
              ),
              repository: _FakeAccountRepository(
                failProfile: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('تعذر تحميل بيانات الحساب'),
          findsOneWidget,
        );
        expect(find.text('إعادة المحاولة'), findsOneWidget);
        expect(find.text('محمد عبدالله الشامي'), findsNothing);
        expect(find.text('777123456'), findsNothing);

        expect(
          find.text('تفضيلات التطبيق والطباعة'),
          findsOneWidget,
        );

        await tester.tap(find.text('حسابي والملف الشخصي'));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'تعذر تحميل بيانات الحساب. أعد المحاولة أولاً.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '4. تعذر قراءة المعلَّق قبل الخروج يفشل مغلقًا لا يمرّ نظيفًا',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        bool loggedOut = false;
        final repository = _FakeAccountRepository(failPending: true);
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: MoreSettingsScreen(
              identity: testIdentity(accountId: 'owner-77'),
              repository: repository,
              onLogout: () => loggedOut = true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('تسجيل الخروج من الحساب'));
        await tester.pumpAndSettle();

        expect(find.text('تعذر التحقق قبل الخروج'), findsOneWidget);
        // الفحص جرى بمفتاح صاحب الحساب المُمرَّر، لا بمفتاح ثابت.
        expect(repository.pendingChecks, ['owner-77']);
        expect(
          find.text('هل أنت متأكد من رغبتك في تسجيل الخروج من التطبيق؟'),
          findsNothing,
        );
        expect(loggedOut, isFalse);

        await tester.tap(find.text('تأكيد الخروج على مسؤوليتي'));
        await tester.pumpAndSettle();

        expect(loggedOut, isTrue);
      },
    );

  });
}

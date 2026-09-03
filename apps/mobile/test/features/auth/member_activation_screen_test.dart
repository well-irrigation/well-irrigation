import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/api/auth_repository.dart';
import 'package:well_irrigation_mobile/core/api/team_repository.dart';
import 'package:well_irrigation_mobile/features/auth/member_activation_screen.dart';

/// مصادقة مُتحكَّم بها: تفصل «أُنشئ حساب» عن «مُنح وصول».
class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository({
    this.existingPassword,
    this.sessionAfterSignUp = true,
  }) : super(_unusedClient);

  /// كلمة مرور حساب قائم بهذا الرقم. `null` = لا حساب.
  final String? existingPassword;
  final bool sessionAfterSignUp;

  bool _session = false;
  int signUpCalls = 0;
  int signInCalls = 0;
  String? signedUpName;

  @override
  bool get isAuthenticated => _session;

  @override
  Future<AuthResponse> signIn({
    required String phoneOrEmail,
    required String password,
  }) async {
    signInCalls++;
    if (existingPassword != null && existingPassword == password) {
      _session = true;
      return AuthResponse();
    }
    throw const AuthException('Invalid login credentials');
  }

  @override
  Future<AuthResponse> signUpMember({
    required String phone,
    required String password,
    required String fullName,
  }) async {
    signUpCalls++;
    if (existingPassword != null) {
      throw const AuthException('User already registered');
    }
    signedUpName = fullName;
    _session = sessionAfterSignUp;
    return AuthResponse();
  }
}

class _FakeTeamRepository extends TeamRepository {
  _FakeTeamRepository({this.results = const []});

  final List<ClaimResult> results;

  final List<String> codes = [];

  @override
  Future<ClaimResult> claimInvitation(String code) async {
    codes.add(code);
    final index = codes.length - 1;
    return index < results.length
        ? results[index]
        : const ClaimResult(outcome: 'no_invitation');
  }
}

final SupabaseClient _unusedClient = _NoClient();

class _NoClient implements SupabaseClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('لا يُستدعى عميل حقيقي في الاختبار');
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeAuthRepository auth,
  required _FakeTeamRepository team,
  VoidCallback? onActivated,
}) async {
  tester.view.physicalSize = const Size(900, 1900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      home: MemberActivationScreen(
        authRepository: auth,
        teamRepository: team,
        onActivated: onActivated,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _fill(
  WidgetTester tester, {
  String name = 'صالح أحمد',
  String phone = '771234567',
  String code = '482915',
  String password = 'كلمة-قوية-1',
}) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'اسمك كما يظهر على السندات *'),
    name,
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'رقم هاتفك (7xxxxxxxx) *'),
    phone,
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'رمز التنشيط *'),
    code,
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'كلمة المرور الجديدة *'),
    password,
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'تأكيد كلمة المرور *'),
    password,
  );
}

void main() {
  group('MemberActivationScreen (ق-123 / م-41E المرحلة 3)', () {
    testWidgets(
      '1. حساب جديد + رمز صحيح = تعيين نافذ، والاسم يُرسل كما كتبه صاحبه',
      (tester) async {
        final auth = _FakeAuthRepository();
        final team = _FakeTeamRepository(
          results: const [
            ClaimResult(
              outcome: 'claimed',
              wellId: 'w-1',
              wellName: 'بئر الفريق',
              role: 'operator',
            ),
          ],
        );
        var activated = false;

        await _pump(
          tester,
          auth: auth,
          team: team,
          onActivated: () => activated = true,
        );
        await _fill(tester);
        await tester.tap(find.text('تنشيط الحساب'));
        await tester.pumpAndSettle();

        expect(auth.signInCalls, 1);
        expect(auth.signUpCalls, 1);
        expect(auth.signedUpName, 'صالح أحمد');
        expect(team.codes, ['482915']);
        expect(activated, isTrue);
      },
    );

    testWidgets(
      '2. رمز خاطئ يعرض المتبقّي ولا يُعلن تنشيطًا',
      (tester) async {
        final auth = _FakeAuthRepository();
        final team = _FakeTeamRepository(
          results: const [
            ClaimResult(outcome: 'wrong_code', attemptsLeft: 4),
          ],
        );
        var activated = false;

        await _pump(
          tester,
          auth: auth,
          team: team,
          onActivated: () => activated = true,
        );
        await _fill(tester, code: '000000');
        await tester.tap(find.text('تنشيط الحساب'));
        await tester.pumpAndSettle();

        expect(activated, isFalse);
        expect(
          find.text('رمز التنشيط غير صحيح — بقيت 4 محاولات.'),
          findsOneWidget,
        );
        expect(
          find.text('حسابك جاهز؛ يكفي إدخال الرمز الصحيح.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '3. إعادة المحاولة بعد رمز خاطئ لا تُنشئ حسابًا ثانيًا',
      (tester) async {
        final auth = _FakeAuthRepository();
        final team = _FakeTeamRepository(
          results: const [
            ClaimResult(outcome: 'wrong_code', attemptsLeft: 4),
            ClaimResult(
              outcome: 'claimed',
              wellId: 'w-1',
              wellName: 'بئر الفريق',
              role: 'operator',
            ),
          ],
        );
        var activated = false;

        await _pump(
          tester,
          auth: auth,
          team: team,
          onActivated: () => activated = true,
        );
        await _fill(tester, code: '000000');
        await tester.tap(find.text('تنشيط الحساب'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'رمز التنشيط *'),
          '482915',
        );
        await tester.tap(find.text('تنشيط الحساب'));
        await tester.pumpAndSettle();

        expect(auth.signUpCalls, 1);
        expect(auth.signInCalls, 1);
        expect(team.codes, ['000000', '482915']);
        expect(activated, isTrue);
      },
    );

    testWidgets(
      '4. حساب قائم بكلمة مرور مختلفة يُقال صريحًا لا «تعذر» عامة',
      (tester) async {
        final auth = _FakeAuthRepository(existingPassword: 'كلمة-أخرى');
        final team = _FakeTeamRepository();

        await _pump(tester, auth: auth, team: team);
        await _fill(tester);
        await tester.tap(find.text('تنشيط الحساب'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('يوجد حساب بهذا الرقم وكلمة المرور غير مطابقة'),
          findsOneWidget,
        );
        expect(team.codes, isEmpty);
      },
    );

    testWidgets(
      '5. لا دعوة سارية: حالة معلنة بلا تنشيط',
      (tester) async {
        final auth = _FakeAuthRepository();
        final team = _FakeTeamRepository(
          results: const [ClaimResult(outcome: 'no_invitation')],
        );
        var activated = false;

        await _pump(
          tester,
          auth: auth,
          team: team,
          onActivated: () => activated = true,
        );
        await _fill(tester);
        await tester.tap(find.text('تنشيط الحساب'));
        await tester.pumpAndSettle();

        expect(activated, isFalse);
        expect(find.text('لا توجد دعوة سارية لرقمك.'), findsOneWidget);
      },
    );

    testWidgets(
      '6. نجاح النداء بلا جلسة ليس تنشيطًا',
      (tester) async {
        final auth = _FakeAuthRepository(sessionAfterSignUp: false);
        final team = _FakeTeamRepository();
        var activated = false;

        await _pump(
          tester,
          auth: auth,
          team: team,
          onActivated: () => activated = true,
        );
        await _fill(tester);
        await tester.tap(find.text('تنشيط الحساب'));
        await tester.pumpAndSettle();

        expect(activated, isFalse);
        expect(team.codes, isEmpty);
        expect(find.text('لم تُنشأ جلسة دخول — أعد المحاولة.'), findsOneWidget);
      },
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/api/auth_repository.dart';
import 'package:well_irrigation_mobile/core/api/team_repository.dart';
import 'package:well_irrigation_mobile/core/utils/contact_picker.dart';
import 'package:well_irrigation_mobile/features/auth/member_activation_screen.dart';

final SupabaseClient _unusedClient = _NoClient();

class _NoClient implements SupabaseClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('لا يُستدعى عميل حقيقي في الاختبار');
}

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository({
    this.validations = const [],
    this.finalizations = const [],
  }) : super(_unusedClient);

  final List<MemberValidationOutcome> validations;
  final List<MemberFinalizationOutcome> finalizations;

  int validateCalls = 0;
  int finalizeCalls = 0;
  int signInCalls = 0;
  int signUpCalls = 0;
  bool _session = false;

  @override
  bool get isAuthenticated => _session;

  @override
  Future<MemberValidationOutcome> validateMemberFinalization({
    required String phone,
    required String code,
  }) async {
    final index = validateCalls++;
    return validations[index < validations.length
        ? index
        : validations.length - 1];
  }

  @override
  Future<MemberFinalizationOutcome> finalizeMember({
    required String continuationToken,
    required String password,
  }) async {
    final index = finalizeCalls++;
    return finalizations[index < finalizations.length
        ? index
        : finalizations.length - 1];
  }

  @override
  Future<AuthResponse> signIn({
    required String phoneOrEmail,
    required String password,
  }) async {
    signInCalls++;
    _session = true;
    return AuthResponse();
  }

  @override
  Future<AuthResponse> signUpMember({
    required String phone,
    required String password,
    required String fullName,
  }) async {
    signUpCalls++;
    throw StateError('مسار Q-130 لا يستدعي signUpMember');
  }
}

class _FakeTeamRepository extends TeamRepository {
  _FakeTeamRepository({
    this.invitations = const [],
    this.acceptResult = const InvitationActionResult(
      outcome: 'accepted_pending_owner',
    ),
  });

  final List<MyWellInvitation> invitations;
  final InvitationActionResult acceptResult;
  int listCalls = 0;
  final List<String> acceptedIds = [];

  @override
  Future<List<MyWellInvitation>> listMyInvitations() async {
    listCalls++;
    return invitations;
  }

  @override
  Future<InvitationActionResult> acceptInvitation(String invitationId) async {
    acceptedIds.add(invitationId);
    return acceptResult;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required _FakeAuthRepository auth,
  _FakeTeamRepository? team,
  Future<ContactPickResult> Function()? contactPicker,
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
        teamRepository: team ?? _FakeTeamRepository(),
        contactPicker: contactPicker,
        onActivated: onActivated,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _validate(WidgetTester tester) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'رقم هاتفك *'),
    '771234567',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'رمز الدعوة *'),
    '482915',
  );
  await tester.tap(find.text('التحقق من الدعوة'));
  await tester.pumpAndSettle();
}

Future<void> _enterPassword(WidgetTester tester) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'كلمة المرور *'),
    'secret6',
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'تأكيد كلمة المرور *'),
    'secret6',
  );
}

void main() {
  group('MemberActivationScreen Q-130', () {
    testWidgets('البداية تعرض الهاتف والرمز فقط', (tester) async {
      final auth = _FakeAuthRepository(
        validations: const [MemberValidationOutcome(outcome: 'no_invitation')],
      );

      await _pump(tester, auth: auth);

      expect(find.text('رقم هاتفك *'), findsOneWidget);
      expect(find.text('رمز الدعوة *'), findsOneWidget);
      expect(find.text('كلمة المرور *'), findsNothing);
      expect(find.textContaining('اسمك'), findsNothing);
    });

    testWidgets('القبول ينتظر المالك بلا مصادقة ثم ينعش الحالة', (
      tester,
    ) async {
      final auth = _FakeAuthRepository(
        validations: const [
          MemberValidationOutcome(
            outcome: 'accepted_pending_owner',
            continuationToken: 'token-1',
          ),
          MemberValidationOutcome(
            outcome: 'owner_confirmed_pending_account',
            continuationToken: 'token-2',
          ),
        ],
      );

      await _pump(tester, auth: auth);
      await _validate(tester);

      expect(find.text('بانتظار تأكيد مالك البئر'), findsOneWidget);
      expect(find.text('كلمة المرور *'), findsNothing);
      expect(auth.signInCalls, 0);
      expect(auth.signUpCalls, 0);

      await tester.tap(find.text('تحقق من موافقة المالك'));
      await tester.pumpAndSettle();

      expect(find.text('تم تأكيد الهوية'), findsOneWidget);
      expect(find.text('كلمة المرور *'), findsOneWidget);
      expect(auth.validateCalls, 2);
    });

    for (final entry in const [
      ('wrong_code', 'رمز الدعوة غير صحيح — بقيت 4 محاولات.'),
      ('expired', 'انتهت الدعوة.'),
      ('revoked', 'أُلغيت الدعوة.'),
      ('no_invitation', 'لا توجد دعوة مطابقة.'),
    ]) {
      testWidgets('يعرض حالة ${entry.$1} صراحة', (tester) async {
        final auth = _FakeAuthRepository(
          validations: [
            MemberValidationOutcome(
              outcome: entry.$1,
              attemptsLeft: entry.$1 == 'wrong_code' ? 4 : null,
            ),
          ],
        );

        await _pump(tester, auth: auth);
        await _validate(tester);

        expect(find.text(entry.$2), findsOneWidget);
        expect(auth.signInCalls, 0);
        expect(auth.signUpCalls, 0);
      });
    }

    testWidgets('التأكيد يكشف كلمة المرور فقط', (tester) async {
      final auth = _FakeAuthRepository(
        validations: const [
          MemberValidationOutcome(
            outcome: 'owner_confirmed_pending_account',
            continuationToken: 'token-final',
          ),
        ],
      );

      await _pump(tester, auth: auth);
      await _validate(tester);

      expect(find.text('تم تأكيد الهوية'), findsOneWidget);
      expect(find.text('كلمة المرور *'), findsOneWidget);
      expect(find.text('تأكيد كلمة المرور *'), findsOneWidget);
    });

    testWidgets('الإكمال المؤكد يسجل الدخول ثم ينشط مرة واحدة', (tester) async {
      final auth = _FakeAuthRepository(
        validations: const [
          MemberValidationOutcome(
            outcome: 'owner_confirmed_pending_account',
            continuationToken: 'token-final',
          ),
        ],
        finalizations: const [MemberFinalizationOutcome(outcome: 'confirmed')],
      );
      var activations = 0;

      await _pump(tester, auth: auth, onActivated: () => activations++);
      await _validate(tester);
      await _enterPassword(tester);
      await tester.tap(find.text('إكمال إنشاء الحساب'));
      await tester.pumpAndSettle();

      expect(auth.finalizeCalls, 1);
      expect(auth.signInCalls, 1);
      expect(auth.signUpCalls, 0);
      expect(activations, 1);
    });

    testWidgets('الإكمال الملتبس لا ينشط ولا ينشئ حسابًا محليًا', (
      tester,
    ) async {
      final auth = _FakeAuthRepository(
        validations: const [
          MemberValidationOutcome(
            outcome: 'owner_confirmed_pending_account',
            continuationToken: 'token-final',
          ),
        ],
        finalizations: const [
          MemberFinalizationOutcome(outcome: 'completion_ambiguous'),
        ],
      );
      var activations = 0;

      await _pump(tester, auth: auth, onActivated: () => activations++);
      await _validate(tester);
      await _enterPassword(tester);
      await tester.tap(find.text('إكمال إنشاء الحساب'));
      await tester.pumpAndSettle();

      expect(find.textContaining('لا تنشئ حسابًا آخر'), findsOneWidget);
      expect(auth.signInCalls, 0);
      expect(auth.signUpCalls, 0);
      expect(activations, 0);
    });

    testWidgets('الحساب القائم يسجل الدخول ثم يعرض دعواته المميزة', (
      tester,
    ) async {
      final auth = _FakeAuthRepository(
        validations: const [
          MemberValidationOutcome(outcome: 'existing_account'),
        ],
      );
      final team = _FakeTeamRepository(
        invitations: const [
          MyWellInvitation(
            invitationId: 'i-1',
            wellId: 'w-1',
            wellName: 'بئر الوادي',
            role: 'operator',
            status: 'invited',
          ),
          MyWellInvitation(
            invitationId: 'i-2',
            wellId: 'w-2',
            wellName: 'بئر المزرعة',
            role: 'partner',
            status: 'invited',
          ),
        ],
      );

      await _pump(tester, auth: auth, team: team);
      await _validate(tester);
      expect(auth.signUpCalls, 0);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'كلمة مرور الحساب *'),
        'secret6',
      );
      await tester.tap(find.text('تسجيل الدخول وعرض الدعوات'));
      await tester.pumpAndSettle();

      expect(auth.signInCalls, 1);
      expect(team.listCalls, 1);
      expect(find.text('بئر الوادي'), findsOneWidget);
      expect(find.text('بئر المزرعة'), findsOneWidget);
      expect(find.text('مشغّل'), findsOneWidget);
      expect(find.text('شريك'), findsOneWidget);
    });

    testWidgets('القبول الصريح ينتظر المالك ولا ينشط', (tester) async {
      final auth = _FakeAuthRepository(
        validations: const [
          MemberValidationOutcome(outcome: 'existing_account'),
        ],
      );
      final team = _FakeTeamRepository(
        invitations: const [
          MyWellInvitation(
            invitationId: 'i-1',
            wellId: 'w-1',
            wellName: 'بئر الوادي',
            role: 'operator',
            status: 'invited',
          ),
        ],
      );
      var activations = 0;

      await _pump(
        tester,
        auth: auth,
        team: team,
        onActivated: () => activations++,
      );
      await _validate(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'كلمة مرور الحساب *'),
        'secret6',
      );
      await tester.tap(find.text('تسجيل الدخول وعرض الدعوات'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('قبول الدعوة'));
      await tester.pumpAndSettle();

      expect(team.acceptedIds, ['i-1']);
      expect(
        find.text('تم قبول الدعوة — بانتظار تأكيد المالك'),
        findsOneWidget,
      );
      expect(activations, 0);
    });

    testWidgets('already_confirmed يسمح بالتنشيط دون claim أو signup', (
      tester,
    ) async {
      final auth = _FakeAuthRepository(
        validations: const [
          MemberValidationOutcome(outcome: 'existing_account'),
        ],
      );
      final team = _FakeTeamRepository(
        invitations: const [
          MyWellInvitation(
            invitationId: 'i-1',
            wellId: 'w-1',
            wellName: 'بئر الوادي',
            role: 'operator',
            status: 'invited',
          ),
        ],
        acceptResult: const InvitationActionResult(
          outcome: 'already_confirmed',
        ),
      );
      var activations = 0;

      await _pump(
        tester,
        auth: auth,
        team: team,
        onActivated: () => activations++,
      );
      await _validate(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'كلمة مرور الحساب *'),
        'secret6',
      );
      await tester.tap(find.text('تسجيل الدخول وعرض الدعوات'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('قبول الدعوة'));
      await tester.pumpAndSettle();

      expect(auth.signUpCalls, 0);
      expect(activations, 1);
    });
  });

  group('اختيار جهة اتصال لحقل رقم العضو (Q130)', () {
    testWidgets('اختيار جهة يملأ الحقل والإدخال اليدوي يبقى متاحًا', (
      tester,
    ) async {
      await _pump(
        tester,
        auth: _FakeAuthRepository(),
        contactPicker: () async => const ContactPickResult(
          ContactPickStatus.picked,
          phone: '712345678',
        ),
      );

      await tester.tap(find.byTooltip('اختيار رقم من جهات الاتصال'));
      await tester.pumpAndSettle();

      final field = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'رقم هاتفك *'),
      );
      expect(field.controller!.text, '712345678');

      await tester.enterText(
        find.widgetWithText(TextFormField, 'رقم هاتفك *'),
        '779999999',
      );
      expect(field.controller!.text, '779999999');
    });

    testWidgets('رفض الصلاحية يُعلن صراحة ولا يملأ الحقل', (tester) async {
      await _pump(
        tester,
        auth: _FakeAuthRepository(),
        contactPicker: () async =>
            const ContactPickResult(ContactPickStatus.permissionDenied),
      );

      await tester.tap(find.byTooltip('اختيار رقم من جهات الاتصال'));
      await tester.pumpAndSettle();

      expect(
        find.text('لم يُمنح الوصول لجهات الاتصال — أكمل الإدخال اليدوي'),
        findsOneWidget,
      );
      final field = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'رقم هاتفك *'),
      );
      expect(field.controller!.text, isEmpty);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/api/auth_repository.dart';
import 'package:well_irrigation_mobile/features/auth/password_reset_screen.dart';

/// مستودع مصادقة مُتحكَّم به: يفصل «ما أعلنه الطرف الخادمي» عن «ما عُرض».
class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository({this.result, this.failCall = false})
    : super(_unusedClient);

  final PasswordResetOutcome? result;
  final bool failCall;

  final List<Map<String, String>> calls = [];

  @override
  Future<PasswordResetOutcome> resetPasswordWithCode({
    required String phone,
    required String code,
    required String newPassword,
  }) async {
    calls.add({'phone': phone, 'code': code, 'password': newPassword});
    if (failCall) {
      throw StateError('functions transport unavailable');
    }
    return result ?? const PasswordResetOutcome(outcome: 'ok');
  }
}

final SupabaseClient _unusedClient = _NoClient();

class _NoClient implements SupabaseClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('لا يُنادى عميل حقيقي في هذا الاختبار');
}

Widget _host(_FakeAuthRepository auth, {VoidCallback? onDone}) {
  return MaterialApp(
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: PasswordResetScreen(authRepository: auth, onDone: onDone),
    ),
  );
}

Future<void> _fill(WidgetTester tester, {String code = '654321'}) async {
  await tester.enterText(find.byType(TextFormField).at(0), '771000096');
  await tester.enterText(find.byType(TextFormField).at(1), code);
  await tester.enterText(find.byType(TextFormField).at(2), 'newpass123');
  await tester.enterText(find.byType(TextFormField).at(3), 'newpass123');
}

void main() {
  testWidgets('الشاشة تقول إن الرمز يُسلَّم باليد ولا رسائل في هذا الإصدار', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_FakeAuthRepository()));

    expect(
      find.textContaining('الرمز يعطيك إياه مالك البئر'),
      findsOneWidget,
    );
    expect(
      find.textContaining('لا تُرسل رسائل نصية في هذا الإصدار'),
      findsOneWidget,
    );
  });

  testWidgets('النجاح يُعلن بعد نتيجة الخادم وحدها', (tester) async {
    var done = 0;
    final auth = _FakeAuthRepository();

    await tester.pumpWidget(_host(auth, onDone: () => done++));
    await _fill(tester);
    await tester.tap(find.text('تعيين كلمة المرور'));
    await tester.pumpAndSettle();

    expect(auth.calls.single['code'], '654321');
    expect(find.text('تغيّرت كلمة مرورك'), findsOneWidget);

    await tester.tap(find.text('العودة إلى الدخول'));
    await tester.pumpAndSettle();
    expect(done, 1);
  });

  testWidgets('رمز خاطئ يعرض المتبقّي ولا يُعلن تغييرًا', (tester) async {
    final auth = _FakeAuthRepository(
      result: const PasswordResetOutcome(outcome: 'wrong_code', attemptsLeft: 3),
    );

    await tester.pumpWidget(_host(auth));
    await _fill(tester, code: '000000');
    await tester.tap(find.text('تعيين كلمة المرور'));
    await tester.pumpAndSettle();

    expect(find.textContaining('بقيت 3 محاولات'), findsOneWidget);
    expect(find.text('تغيّرت كلمة مرورك'), findsNothing);
  });

  testWidgets('لا تذكرة سارية = حالة تُقال مع ما يفعله المستخدم', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _FakeAuthRepository(
          result: const PasswordResetOutcome(outcome: 'no_ticket'),
        ),
      ),
    );
    await _fill(tester);
    await tester.tap(find.text('تعيين كلمة المرور'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('اطلب من مالك البئر إصدار رمز جديد'),
      findsOneWidget,
    );
  });

  testWidgets('استُهلك الرمز ولم تُطبَّق: يُقال إن القديمة لم تتغيّر', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _FakeAuthRepository(
          result: const PasswordResetOutcome(
            outcome: 'ticket_spent_not_applied',
          ),
        ),
      ),
    );
    await _fill(tester);
    await tester.tap(find.text('تعيين كلمة المرور'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('كلمة مرورك القديمة لم تتغيّر'),
      findsOneWidget,
    );
  });

  testWidgets('فشل النقل يُعلَن بسببه ولا يُعلن نجاحًا', (tester) async {
    await tester.pumpWidget(_host(_FakeAuthRepository(failCall: true)));
    await _fill(tester);
    await tester.tap(find.text('تعيين كلمة المرور'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('لم تتغيّر كلمة المرور'),
      findsOneWidget,
    );
    expect(
      find.textContaining('functions transport unavailable'),
      findsOneWidget,
    );
  });

  testWidgets('المدخلات تُفحص قبل أي نداء', (tester) async {
    final auth = _FakeAuthRepository();

    await tester.pumpWidget(_host(auth));
    await tester.enterText(find.byType(TextFormField).at(0), '771000096');
    await tester.enterText(find.byType(TextFormField).at(1), '12');
    await tester.tap(find.text('تعيين كلمة المرور'));
    await tester.pumpAndSettle();

    expect(find.textContaining('الرمز ستة أرقام'), findsOneWidget);
    expect(auth.calls, isEmpty);
  });
}

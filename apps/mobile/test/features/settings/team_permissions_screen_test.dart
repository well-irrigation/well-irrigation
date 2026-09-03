import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/team_repository.dart';
import 'package:well_irrigation_mobile/features/settings/team_permissions_screen.dart';
import '../../support/identity_fixture.dart';

/// مستودع فريق مُتحكَّم به: يفصل «ما أعاده العقد» عن «ما عُرض على الشاشة».
class _FakeTeamRepository extends TeamRepository {
  _FakeTeamRepository({
    this.team,
    this.failRead = false,
    this.inviteResult,
    this.failInvite = false,
  });

  final WellTeam? team;
  final bool failRead;
  final InviteResult? inviteResult;
  final bool failInvite;

  int reads = 0;
  final List<Map<String, String>> invites = [];
  final List<Map<String, String>> revokes = [];

  @override
  Future<WellTeam> fetchWellTeam(String wellId) async {
    reads++;
    if (failRead) {
      throw StateError('team contract unavailable');
    }
    return team ?? const WellTeam(members: [], invitations: []);
  }

  @override
  Future<InviteResult> inviteMember({
    required String wellId,
    required String role,
    required String fullName,
    required String phone,
  }) async {
    invites.add({
      'wellId': wellId,
      'role': role,
      'fullName': fullName,
      'phone': phone,
    });
    if (failInvite) {
      throw StateError('invite rejected');
    }
    return inviteResult ??
        const InviteResult(outcome: 'invited', code: '123456');
  }

  @override
  Future<void> revokeMember({
    required String wellId,
    required String role,
    required String phone,
  }) async {
    revokes.add({'wellId': wellId, 'role': role, 'phone': phone});
  }
}

Future<void> _pump(
  WidgetTester tester,
  TeamRepository repository,
) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      home: TeamPermissionsScreen(
        well: testWell(id: 'well-9', name: 'بئر الفريق'),
        repository: repository,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('TeamPermissionsScreen (ق-123 / هجرة 094 / م-41E المرحلة 3)', () {
    testWidgets('1. يعرض ما أعاده العقد: أعضاء ودعوات معلَّقة', (tester) async {
      final repository = _FakeTeamRepository(
        team: WellTeam(
          members: const [
            TeamMember(
              profileId: 'p-1',
              fullName: 'صاحب البئر',
              phone: '770000001',
              role: 'owner',
              status: 'active',
            ),
            TeamMember(
              profileId: 'p-2',
              fullName: 'صالح المشغّل',
              phone: '770000002',
              role: 'operator',
              status: 'active',
            ),
          ],
          invitations: [
            TeamInvitation(
              invitationId: 'i-1',
              fullName: 'شريك مدعو',
              phone: '770000003',
              role: 'partner',
              status: 'invited',
              attemptsLeft: 5,
              expiresAt: DateTime(2026, 9, 17),
            ),
          ],
        ),
      );

      await _pump(tester, repository);

      expect(repository.reads, 1);
      expect(find.text('بئر الفريق'), findsOneWidget);
      expect(find.text('الأعضاء (2)'), findsOneWidget);
      expect(find.text('صالح المشغّل'), findsOneWidget);
      expect(find.text('بانتظار التنشيط (1)'), findsOneWidget);
      expect(find.text('شريك مدعو'), findsOneWidget);
      expect(
        find.text('تنتهي 17/09/2026 · المحاولات المتبقية 5'),
        findsOneWidget,
      );
      // ادعاء الإصدار السابق زال: العقد موجود فلا «غير متاحة».
      expect(find.text('إدارة الفريق غير متاحة في هذه النسخة'), findsNothing);
    });

    testWidgets('2. فشل العقد يُعلن ولا يعرض أعضاء بديلين', (tester) async {
      final repository = _FakeTeamRepository(failRead: true);

      await _pump(tester, repository);

      expect(find.text('تعذر قراءة فريق البئر'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsOneWidget);
      expect(find.text('الأعضاء (0)'), findsNothing);
      // لا زرّ إضافة فوق شاشة فشل: لا إجراء على حالة غير مقروءة.
      expect(find.text('إضافة عضو'), findsNothing);

      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();
      expect(repository.reads, 2);
    });

    testWidgets(
      '3. الدعوة تمرّ بخطوة تأكيد الرقم ثم تعرض الرمز مرة واحدة',
      (tester) async {
        final repository = _FakeTeamRepository(
          inviteResult: InviteResult(
            outcome: 'invited',
            code: '482915',
            expiresAt: DateTime(2026, 9, 17),
          ),
        );

        await _pump(tester, repository);

        await tester.tap(find.text('إضافة عضو'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(TextFormField, 'اسم العضو *'),
          'صالح أحمد',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'رقم الهاتف (7xxxxxxxx) *'),
          '771234567',
        );
        await tester.tap(find.text('متابعة'));
        await tester.pumpAndSettle();

        // خطوة التأكيد تعرض الرقم ليقرأه المالك بعينه قبل منح الوصول.
        expect(find.text('تأكيد بيانات العضو'), findsOneWidget);
        expect(find.text('771234567'), findsOneWidget);
        expect(repository.invites, isEmpty);

        await tester.tap(find.text('تأكيد الدعوة'));
        await tester.pumpAndSettle();

        expect(repository.invites.single, {
          'wellId': 'well-9',
          'role': 'operator',
          'fullName': 'صالح أحمد',
          'phone': '771234567',
        });

        expect(find.text('رمز تنشيط العضو'), findsOneWidget);
        expect(find.text('482915'), findsOneWidget);
        expect(
          find.textContaining('إرسال الرمز برسالة نصية غير متاح'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '4. رقم له حساب قائم يُربط بلا رمز ولا تُعرض نافذة رمز',
      (tester) async {
        final repository = _FakeTeamRepository(
          inviteResult: const InviteResult(outcome: 'linked'),
        );

        await _pump(tester, repository);

        await tester.tap(find.text('إضافة عضو'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'اسم العضو *'),
          'مشغّل قائم',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'رقم الهاتف (7xxxxxxxx) *'),
          '772222222',
        );
        await tester.tap(find.text('متابعة'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('تأكيد الدعوة'));
        await tester.pumpAndSettle();

        expect(find.text('رمز تنشيط العضو'), findsNothing);
        expect(
          find.text('للرقم حساب قائم — رُبط بالبئر الآن بلا رمز ✅'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '5. فشل الدعوة يُعلن ولا يُعرض رمز ولا نجاح',
      (tester) async {
        final repository = _FakeTeamRepository(failInvite: true);

        await _pump(tester, repository);

        await tester.tap(find.text('إضافة عضو'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'اسم العضو *'),
          'دعوة فاشلة',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'رقم الهاتف (7xxxxxxxx) *'),
          '773333333',
        );
        await tester.tap(find.text('متابعة'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('تأكيد الدعوة'));
        await tester.pumpAndSettle();

        expect(
          find.text('تعذر إصدار الدعوة — لم يُضف أحد. تحقق من الاتصال.'),
          findsOneWidget,
        );
        expect(find.text('رمز تنشيط العضو'), findsNothing);
      },
    );

    testWidgets(
      '6. إلغاء وصول عضو يُرسل مفتاحه الحقيقي ولا يُحذف شيء',
      (tester) async {
        final repository = _FakeTeamRepository(
          team: const WellTeam(
            members: [
              TeamMember(
                profileId: 'p-2',
                fullName: 'صالح المشغّل',
                phone: '770000002',
                role: 'operator',
                status: 'active',
              ),
            ],
            invitations: [],
          ),
        );

        await _pump(tester, repository);

        await tester.tap(find.text('إلغاء الوصول'));
        await tester.pumpAndSettle();

        expect(find.text('تأكيد الإلغاء'), findsOneWidget);
        expect(repository.revokes, isEmpty);

        await tester.tap(find.widgetWithText(ElevatedButton, 'إلغاء الوصول'));
        await tester.pumpAndSettle();

        expect(repository.revokes.single, {
          'wellId': 'well-9',
          'role': 'operator',
          'phone': '770000002',
        });
        expect(
          find.textContaining('ولم يُحذف أي سجل'),
          findsOneWidget,
        );
      },
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/team_repository.dart';
import 'package:well_irrigation_mobile/features/settings/team_permissions_screen.dart';

import '../../support/identity_fixture.dart';

/// مستودع فريق مُتحكَّم به: يفصل «ما أعاده العقد» عن «ما عُرض على الشاشة».
class _FakeTeamRepository extends TeamRepository {
  _FakeTeamRepository({
    this.team,
    this.teamResponses = const [],
    this.failRead = false,
    this.inviteResult,
    this.failInvite = false,
    this.resetTickets = const [],
    this.resetIssue,
    this.failReset = false,
    this.confirmResult = const InvitationActionResult(outcome: 'confirmed'),
  });

  final WellTeam? team;
  final List<WellTeam> teamResponses;
  final bool failRead;
  final InviteResult? inviteResult;
  final bool failInvite;
  final List<ResetTicket> resetTickets;
  final ResetIssueResult? resetIssue;
  final bool failReset;
  final InvitationActionResult confirmResult;

  int reads = 0;
  final List<Map<String, String>> invites = [];
  final List<Map<String, String>> revokes = [];
  final List<Map<String, String>> resetRequests = [];
  final List<String> confirmations = [];
  final List<String> rejections = [];

  @override
  Future<List<ResetTicket>> fetchResetRequests(String wellId) async {
    if (failRead) {
      throw StateError('reset contract unavailable');
    }
    return resetTickets;
  }

  @override
  Future<ResetIssueResult> requestMemberPasswordReset({
    required String wellId,
    required String phone,
  }) async {
    resetRequests.add({'wellId': wellId, 'phone': phone});
    if (failReset) {
      throw StateError('reset rejected');
    }
    return resetIssue ??
        const ResetIssueResult(outcome: 'issued', code: '654321');
  }

  @override
  Future<WellTeam> fetchWellTeam(String wellId) async {
    reads++;
    if (failRead) {
      throw StateError('team contract unavailable');
    }
    if (teamResponses.isNotEmpty) {
      final index = reads - 1;
      return teamResponses[index < teamResponses.length
          ? index
          : teamResponses.length - 1];
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

  @override
  Future<InvitationActionResult> confirmInvitation(String invitationId) async {
    confirmations.add(invitationId);
    return confirmResult;
  }

  @override
  Future<InvitationActionResult> rejectInvitation(String invitationId) async {
    rejections.add(invitationId);
    return const InvitationActionResult(outcome: 'rejected');
  }
}

Future<void> _pump(WidgetTester tester, TeamRepository repository) async {
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
  group('TeamPermissionsScreen Q-130', () {
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

    testWidgets('3. الدعوة تمرّ بخطوة تأكيد الرقم ثم تعرض الرمز مرة واحدة', (
      tester,
    ) async {
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
    });

    testWidgets('4. الدعوة المقبولة مسبقًا لا تُعرض كعضو نشط', (tester) async {
      final repository = _FakeTeamRepository(
        inviteResult: const InviteResult(outcome: 'accepted_pending_owner'),
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
        find.text('الدعوة مقبولة — بانتظار تأكيدك أو رفضك'),
        findsOneWidget,
      );
    });

    testWidgets('5. فشل الدعوة يُعلن ولا يُعرض رمز ولا نجاح', (tester) async {
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
    });

    testWidgets('6. إلغاء وصول عضو يُرسل مفتاحه الحقيقي ولا يُحذف شيء', (
      tester,
    ) async {
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
      expect(find.textContaining('ولم يُحذف أي سجل'), findsOneWidget);
    });

    testWidgets('7. تأكيد new_no_auth يبقى بانتظار كلمة المرور', (
      tester,
    ) async {
      final repository = _FakeTeamRepository(
        team: const WellTeam(
          members: [],
          invitations: [
            TeamInvitation(
              invitationId: 'i-new',
              fullName: 'عضو جديد',
              phone: '771111111',
              role: 'operator',
              status: 'accepted_pending_owner',
              attemptsLeft: 4,
            ),
          ],
        ),
        confirmResult: const InvitationActionResult(
          outcome: 'owner_confirmed_pending_account',
        ),
      );

      await _pump(tester, repository);
      await tester.tap(find.text('تأكيد'));
      await tester.pumpAndSettle();

      expect(repository.confirmations, ['i-new']);
      expect(repository.reads, 2);
      expect(
        find.text('تم تأكيد العضو — بانتظار أن يختار كلمة المرور'),
        findsOneWidget,
      );
      expect(find.text('نشط'), findsNothing);
    });

    testWidgets('8. تأكيد existing_auth ينعش العضو النشط', (tester) async {
      final repository = _FakeTeamRepository(
        teamResponses: const [
          WellTeam(
            members: [],
            invitations: [
              TeamInvitation(
                invitationId: 'i-existing',
                fullName: 'مشغّل قائم',
                phone: '772222222',
                role: 'operator',
                status: 'accepted_pending_owner',
                attemptsLeft: 5,
              ),
            ],
          ),
          WellTeam(
            members: [
              TeamMember(
                profileId: 'p-existing',
                fullName: 'مشغّل قائم',
                phone: '772222222',
                role: 'operator',
                status: 'active',
              ),
            ],
            invitations: [],
          ),
        ],
      );

      await _pump(tester, repository);
      await tester.tap(find.text('تأكيد'));
      await tester.pumpAndSettle();

      expect(repository.confirmations, ['i-existing']);
      expect(repository.reads, 2);
      expect(find.text('مشغّل قائم'), findsOneWidget);
      expect(find.text('نشط'), findsOneWidget);
    });

    testWidgets('9. الرفض ينعش الدعوة المرفوضة بلا نجاح ملفق', (tester) async {
      final repository = _FakeTeamRepository(
        teamResponses: const [
          WellTeam(
            members: [],
            invitations: [
              TeamInvitation(
                invitationId: 'i-reject',
                fullName: 'عضو مرفوض',
                phone: '773333333',
                role: 'partner',
                status: 'accepted_pending_owner',
                attemptsLeft: 5,
              ),
            ],
          ),
          WellTeam(
            members: [],
            invitations: [
              TeamInvitation(
                invitationId: 'i-reject',
                fullName: 'عضو مرفوض',
                phone: '773333333',
                role: 'partner',
                status: 'rejected',
                attemptsLeft: 5,
              ),
            ],
          ),
        ],
      );

      await _pump(tester, repository);
      await tester.tap(find.text('رفض'));
      await tester.pumpAndSettle();

      expect(repository.rejections, ['i-reject']);
      expect(repository.reads, 2);
      expect(find.textContaining('مرفوض'), findsWidgets);
      expect(find.text('نشط'), findsNothing);
    });
  });

  group('إعادة تعيين كلمة المرور بإثبات بشري (م-41F / هجرة 096)', () {
    WellTeam teamWithOperator() => const WellTeam(
      members: [
        TeamMember(
          profileId: 'p-2',
          fullName: 'صالح المشغّل',
          phone: '771000096',
          role: 'operator',
          status: 'active',
        ),
      ],
      invitations: [],
    );

    testWidgets('التأكيد يعرض الرقم، والرمز يُعرض مرة واحدة بلا رسالة', (
      tester,
    ) async {
      final repository = _FakeTeamRepository(
        team: teamWithOperator(),
        resetIssue: const ResetIssueResult(
          outcome: 'issued',
          code: '135790',
          fullName: 'صالح المشغّل',
        ),
      );

      await _pump(tester, repository);
      await tester.tap(find.text('إعادة تعيين كلمة المرور'));
      await tester.pumpAndSettle();

      // الرقم يُقرأ بالعين قبل الإصدار: رمزٌ لغير صاحبه يفتح حسابه لغيره.
      expect(find.text('771000096'), findsWidgets);
      expect(find.textContaining('اقرأ الرقم حرفًا حرفًا'), findsOneWidget);

      await tester.tap(find.text('أصدر الرمز'));
      await tester.pumpAndSettle();

      expect(repository.resetRequests.single['phone'], '771000096');
      expect(find.text('135790'), findsOneWidget);
      expect(find.textContaining('يُعرض مرة واحدة فقط'), findsOneWidget);
      expect(find.textContaining('لم تُرسل أي رسالة الآن'), findsOneWidget);
    });

    testWidgets('«لا عضو بهذا الرقم» يُقال ولا يُعرض رمز', (tester) async {
      final repository = _FakeTeamRepository(
        team: teamWithOperator(),
        resetIssue: const ResetIssueResult(outcome: 'no_member'),
      );

      await _pump(tester, repository);
      await tester.tap(find.text('إعادة تعيين كلمة المرور'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('أصدر الرمز'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('لا عضو بهذا الرقم على هذا البئر'),
        findsOneWidget,
      );
      expect(find.textContaining('يُعرض مرة واحدة فقط'), findsNothing);
    });

    testWidgets('فشل الإصدار يُعلَن ولا يُعرض رمز مُلفَّق', (tester) async {
      final repository = _FakeTeamRepository(
        team: teamWithOperator(),
        failReset: true,
      );

      await _pump(tester, repository);
      await tester.tap(find.text('إعادة تعيين كلمة المرور'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('أصدر الرمز'));
      await tester.pumpAndSettle();

      expect(find.textContaining('لم يُصدر أي رمز'), findsOneWidget);
    });

    testWidgets('الرموز السارية تُعرض بحالتها ومحاولاتها', (tester) async {
      final repository = _FakeTeamRepository(
        team: teamWithOperator(),
        resetTickets: [
          ResetTicket(
            ticketId: 't-1',
            fullName: 'صالح المشغّل',
            phone: '771000096',
            status: 'pending',
            attemptsLeft: 4,
            expiresAt: DateTime.utc(2026, 9, 4, 10),
          ),
          const ResetTicket(
            ticketId: 't-0',
            fullName: 'صالح المشغّل',
            phone: '771000096',
            status: 'consumed',
            attemptsLeft: 5,
          ),
        ],
      );

      await _pump(tester, repository);

      // السارية وحدها تُعرض، والمستهلكة ليست حالة انتظار.
      expect(find.text('رموز إعادة تعيين سارية (1)'), findsOneWidget);
      expect(find.text('بانتظار الاستخدام'), findsOneWidget);
      expect(find.textContaining('بقيت 4 محاولات'), findsOneWidget);
      expect(
        find.textContaining('الرمز عُرض مرة واحدة ولا يمكن قراءته من جديد'),
        findsOneWidget,
      );
    });
  });
}

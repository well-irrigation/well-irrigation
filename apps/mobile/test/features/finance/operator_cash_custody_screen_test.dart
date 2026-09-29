import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/finance_repository.dart';
import 'package:well_irrigation_mobile/core/widgets/currency_text_form_field.dart';
import 'package:well_irrigation_mobile/features/finance/operator_cash_custody_screen.dart';

import '../../support/identity_fixture.dart';

/// مستودع مزيَّف يعيد ما تعيده عقود هجرتي 109–110 بأسماء مفاتيح القاعدة
/// نفسها (balance_minor وdeclared_amount_minor وfrom_profile_name) ويمر
/// عبر المحلّلات الحقيقيّة — فلا يُختبر الشكل وحده بل تحويل العقد.
/// عدادات الاستدعاءات تثبت أن التأكيد يمر عبر api.confirm_handover
/// وحدها وأن الرصيد لا يُعدَّل إلا بإعادة تحميل من الخادم.
class _FakeCustodyRepository extends FinanceRepository {
  _FakeCustodyRepository({
    this.declareError,
    this.confirmResult = 'confirmed',
  });

  final Object? declareError;
  final String confirmResult;
  int declareCalls = 0;
  int confirmCalls = 0;
  int custodyFetchCalls = 0;
  int remittancesFetchCalls = 0;
  String? declaredAmountText;
  String? lastConfirmHandoverId;
  int? lastConfirmAmount;
  String? lastConfirmReason;

  @override
  Future<OperatorCashCustody> fetchMyOperatorCashCustody(String wellId) async {
    custodyFetchCalls += 1;
    return OperatorCashCustody.fromContract({
      'well_id': wellId,
      'profile_id': 'user-test-1',
      'cashbox_id': 'cbx-1',
      'cashbox_public_code': 'CBX-1',
      'cashbox_name': 'حيازة نقد المشغل مشغل الاختبار',
      'balance_minor': 350000,
      'is_well_money_in_operator_custody': true,
      'semantics': 'مال البئر/العمل في حيازة المشغل — ليس محفظة شخصية',
    });
  }

  @override
  Future<List<OperatorCashRemittance>> fetchOperatorCashRemittances(
    String wellId, {
    int limit = 50,
  }) async {
    remittancesFetchCalls += 1;
    final now = DateTime.now();
    return [
      // إقرار معلق: هدف تأكيد المالك.
      OperatorCashRemittance.fromJson({
        'id': 'rem-pending',
        'well_id': wellId,
        'from_profile_id': 'user-op-x',
        'from_profile_name': 'مشغل البئر',
        'declared_amount_minor': 600,
        'confirmed_amount_minor': null,
        'difference_minor': null,
        'difference_reason': null,
        'status': 'declared',
        'declared_at': now.toIso8601String(),
        'confirmed_at': null,
        'note': 'ترحيل دوري',
        'journal_entry_id': null,
      }),
      // مؤكد: الوحيد الذي يعلن أن النقد رُحِّل محاسبيًا.
      OperatorCashRemittance.fromJson({
        'id': 'rem-confirmed',
        'well_id': wellId,
        'from_profile_id': 'user-op-x',
        'from_profile_name': 'مشغل البئر',
        'declared_amount_minor': 120000,
        'confirmed_amount_minor': 120000,
        'difference_minor': 0,
        'difference_reason': null,
        'status': 'confirmed',
        'declared_at': now.subtract(const Duration(days: 1)).toIso8601String(),
        'confirmed_at': now.toIso8601String(),
        'note': 'ترحيل سابق',
        'journal_entry_id': 'je-1',
      }),
      // فرق معلق بسببه.
      OperatorCashRemittance.fromJson({
        'id': 'rem-diff',
        'well_id': wellId,
        'from_profile_id': 'user-op-x',
        'from_profile_name': 'مشغل البئر',
        'declared_amount_minor': 50000,
        'confirmed_amount_minor': 40000,
        'difference_minor': -10000,
        'difference_reason': 'عجز موثق',
        'status': 'difference_pending',
        'declared_at': now.toIso8601String(),
        'confirmed_at': now.toIso8601String(),
        'note': null,
        'journal_entry_id': null,
      }),
    ];
  }

  @override
  Future<String> declareMyOperatorCashRemittance({
    required String wellId,
    required int amountYER,
    String? note,
  }) async {
    declareCalls += 1;
    declaredAmountText = '$amountYER';
    final error = declareError;
    if (error != null) throw error;
    return 'rem-new-1';
  }

  @override
  Future<String> confirmOperatorCashRemittance({
    required String handoverId,
    required int confirmedAmountYER,
    String? differenceReason,
  }) async {
    confirmCalls += 1;
    lastConfirmHandoverId = handoverId;
    lastConfirmAmount = confirmedAmountYER;
    lastConfirmReason = differenceReason;
    return confirmResult;
  }
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required FinanceRepository repository,
  List<String> roles = const ['operator'],
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      home: OperatorCashCustodyScreen(
        identity: testIdentity(activeWell: testWell(roles: roles)),
        repository: repository,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('OperatorCashCustodyScreen Tests (ق-131 بند 18 / UX-14)', () {
    testWidgets(
      '1. operator-only: قسم الحيازة «نقد البئر في حيازتك» وزر الإقرار',
      (tester) async {
        await _pumpScreen(tester, repository: _FakeCustodyRepository());

        expect(find.text('نقد البئر في حيازتك'), findsOneWidget);
        expect(find.text('350,000'), findsWidgets);
        expect(find.textContaining('ليس محفظة شخصية'), findsOneWidget);
        expect(find.text('إقرار ترحيل إلى صندوق البئر'), findsOneWidget);
        // المقطع المالح للمالك غير موجود لمشغل غير مالك.
        expect(
          find.text('ترحيلات النقد بانتظار التأكيد'),
          findsNothing,
        );
      },
    );

    testWidgets(
      '2. الحالات نصًّا: بانتظار تأكيد المالك / تم الترحيل / فرق معلق',
      (tester) async {
        await _pumpScreen(tester, repository: _FakeCustodyRepository());

        expect(find.text('بانتظار تأكيد المالك'), findsOneWidget);
        expect(find.text('تم الترحيل'), findsOneWidget);
        expect(find.text('فرق معلق'), findsOneWidget);
        expect(find.textContaining('الفرق: -10000'), findsOneWidget);
        expect(find.textContaining('السبب: عجز موثق'), findsOneWidget);
        // المؤكد وحده يعلن النقل المحاسبي (نمط 423).
        expect(find.textContaining('رُحِّل محاسبيًا'), findsOneWidget);
      },
    );

    testWidgets(
      '3. الإقرار الصريح: مبلغ وملاحظة ثم «لم يُرحَّل محاسبيًا بعد»',
      (tester) async {
        final repo = _FakeCustodyRepository();
        await _pumpScreen(tester, repository: repo);

        await tester.tap(find.text('إقرار ترحيل إلى صندوق البئر'));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.widgetWithText(CurrencyTextFormField, 'مبلغ الترحيل'),
          '50000',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'ملاحظة (اختياري)'),
          'ترحيل شهرية',
        );
        await tester.tap(find.text('إقرار وتقديم للمالك'));
        await tester.pumpAndSettle();

        expect(repo.declareCalls, 1);
        expect(repo.declaredAmountText, '50000');
        expect(
          find.textContaining('لم يُرحَّل محاسبيًا بعد'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '4. رفض الخادم للإقرار يُعرض كما هو بلا نجاح كاذب',
      (tester) async {
        final repo = _FakeCustodyRepository(
          declareError: Exception('مبلغ الترحيل يتجاوز حيازة المشغل الحالية'),
        );
        await _pumpScreen(tester, repository: repo);

        await tester.tap(find.text('إقرار ترحيل إلى صندوق البئر'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(CurrencyTextFormField, 'مبلغ الترحيل'),
          '99999',
        );
        await tester.tap(find.text('إقرار وتقديم للمالك'));
        await tester.pumpAndSettle();

        expect(repo.declareCalls, 1);
        expect(find.textContaining('رفض الخادم الإقرار'), findsOneWidget);
        expect(
          find.textContaining('لم يُرحَّل محاسبيًا بعد'),
          findsNothing,
        );
      },
    );

    testWidgets(
      '5. owner-only: لا حيازة شخصية، وله قسم تأكيد التراخيم المعلقة',
      (tester) async {
        await _pumpScreen(
          tester,
          repository: _FakeCustodyRepository(),
          roles: const ['owner'],
        );

        expect(find.text('نقد البئر في حيازتك'), findsNothing);
        expect(find.text('إقرار ترحيل إلى صندوق البئر'), findsNothing);
        expect(
          find.text('ترحيلات النقد بانتظار التأكيد'),
          findsOneWidget,
        );
        // الترخيص المعلق باسم المشغل مع زر التأكيد.
        expect(find.text('مشغل البئر'), findsWidgets);
        expect(find.text('تأكيد الاستلام'), findsOneWidget);
      },
    );

    testWidgets(
      '6. سجل فارغ للمشغل يحمل دعوة صريحة لا فراغًا صامتًا',
      (tester) async {
        final repo = _EmptyCustodyRepository();
        await _pumpScreen(tester, repository: repo);

        expect(
          find.textContaining('لا توجد تراخيم بعد'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      '7. تأكيد مطابق: يستدعي api.confirm_handover بالمبلغ المقر وسبب null'
      ' ويعلن ترحيل النقد ويُعيد التحميل من الخادم',
      (tester) async {
        final repo = _FakeCustodyRepository();
        await _pumpScreen(
          tester,
          repository: repo,
          roles: const ['owner'],
        );

        await tester.tap(find.text('تأكيد الاستلام'));
        await tester.pumpAndSettle();

        // المبلغ الابتدائي في الحوار = المبلغ المقر.
        expect(
          find.widgetWithText(CurrencyTextFormField, 'المبلغ المستلم فعليًا'),
          findsOneWidget,
        );
        await tester.tap(find.text('تأكيد الاستلام').last);
        // ضخّات حتمية: خروج الحوار ثم دخول التنبيه — pumpAndSettle قد
        // يتوقف في الفجوة الخالية من الإطارات قبل ظهور الـsnackbar.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));

        expect(repo.confirmCalls, 1);
        expect(repo.lastConfirmHandoverId, 'rem-pending');
        expect(repo.lastConfirmAmount, 600);
        expect(repo.lastConfirmReason, isNull);
        expect(
          find.textContaining('تم تأكيد الاستلام وترحيل النقد'),
          findsOneWidget,
        );
        // إعادة التحميل من الخادم لا تحسين متفائل على الرصيد: المالك
        // وحده لا يجلب حيازة، وقائمة التراخيم تُعاد قراءتها.
        expect(repo.remittancesFetchCalls, 2);
      },
    );

    testWidgets(
      '8. تغيير المبلغ يجعل سبب الفرق إلزاميًا: بلا سبب لا يُرسل شيء',
      (tester) async {
        final repo = _FakeCustodyRepository();
        await _pumpScreen(
          tester,
          repository: repo,
          roles: const ['owner'],
        );

        await tester.tap(find.text('تأكيد الاستلام'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(CurrencyTextFormField, 'المبلغ المستلم فعليًا'),
          '400',
        );
        await tester.pumpAndSettle();

        expect(find.text('سبب الفرق (إلزامي)'), findsOneWidget);

        await tester.tap(find.text('تأكيد الاستلام').last);
        await tester.pumpAndSettle();

        expect(repo.confirmCalls, 0);
        expect(find.textContaining('إلزامي عند تغيير المبلغ'), findsOneWidget);
      },
    );

    testWidgets(
      '9. الفرق بالسبب: يُرسل difference_reason ويعلن «لم يُرحّل النقد»'
      ' ويظهر السجل «فرق معلق»',
      (tester) async {
        final repo = _FakeCustodyRepository(confirmResult: 'difference_pending');
        await _pumpScreen(
          tester,
          repository: repo,
          roles: const ['owner'],
        );

        await tester.tap(find.text('تأكيد الاستلام'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(CurrencyTextFormField, 'المبلغ المستلم فعليًا'),
          '400',
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'سبب الفرق (إلزامي)'),
          'عجز موثق بانتظار الحسم',
        );
        await tester.tap(find.text('تأكيد الاستلام').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));

        expect(repo.confirmCalls, 1);
        expect(repo.lastConfirmAmount, 400);
        expect(repo.lastConfirmReason, 'عجز موثق بانتظار الحسم');
        expect(
          find.textContaining('لم يُرحّل النقد محاسبيًا'),
          findsOneWidget,
        );
        expect(
          find.textContaining('تم تأكيد الاستلام وترحيل النقد'),
          findsNothing,
        );
        expect(find.text('فرق معلق'), findsWidgets);
      },
    );

    testWidgets(
      '10. لا زر حسم/تسوية للفرق في أي حال (م109 يمنعه عمدًا)',
      (tester) async {
        await _pumpScreen(tester, repository: _FakeCustodyRepository());

        expect(find.textContaining('حسم الفرق'), findsNothing);
        expect(find.textContaining('settle_handover'), findsNothing);
        expect(find.byIcon(Icons.gavel), findsNothing);
      },
    );

    testWidgets(
      '11. owner+operator: قسم الحيازة وقسم تأكيد التراخيم معًا',
      (tester) async {
        await _pumpScreen(
          tester,
          repository: _FakeCustodyRepository(),
          roles: const ['owner', 'operator'],
        );

        expect(find.text('نقد البئر في حيازتك'), findsOneWidget);
        expect(find.text('إقرار ترحيل إلى صندوق البئر'), findsOneWidget);
        expect(
          find.text('ترحيلات النقد بانتظار التأكيد'),
          findsOneWidget,
        );
        expect(find.text('تأكيد الاستلام'), findsOneWidget);
      },
    );

    testWidgets(
      '12. بلا تحسين متفائل: التأكيد لا يلمس الرصيد إلا بإعادة تحميل الخادم',
      (tester) async {
        final repo = _FakeCustodyRepository();
        await _pumpScreen(
          tester,
          repository: repo,
          roles: const ['owner', 'operator'],
        );
        final fetchesAfterLoad = repo.custodyFetchCalls;

        await tester.tap(find.text('تأكيد الاستلام'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('تأكيد الاستلام').last);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));

        // الرصيد المعروض بقيمته الخادمية نفسها قبل وبعد التأكيد،
        // ولم يُطرح منه مبلغ الترحيل محليًا.
        expect(find.text('350,000'), findsWidgets);
        expect(repo.custodyFetchCalls, fetchesAfterLoad + 1);
      },
    );
  });
}

class _EmptyCustodyRepository extends _FakeCustodyRepository {
  @override
  Future<List<OperatorCashRemittance>> fetchOperatorCashRemittances(
    String wellId, {
    int limit = 50,
  }) async {
    return const [];
  }
}

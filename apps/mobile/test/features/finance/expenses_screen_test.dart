import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/finance_repository.dart';
import 'package:well_irrigation_mobile/features/finance/expenses_screen.dart';
import '../../support/identity_fixture.dart';

/// مستودع مزيَّف يعيد ما يعيده عقد api.list_well_expenses بأسماء مفاتيح
/// القاعدة نفسها (amount_minor وspent_at وcategory_name) ويمر عبر المحلّل
/// الحقيقي. صف بانتظار الاعتماد وصف معتمد ليكون للتبويبين محتوى.
class _FakeFinanceRepository extends FinanceRepository {
  @override
  Future<List<ExpenseItem>> fetchExpenses(
    String wellId, {
    String? status,
    int limit = 100,
  }) async {
    final today = DateTime.now();
    final rows = <Map<String, dynamic>>[
      {
        'id': 'expense-1',
        'well_id': wellId,
        'public_code': 'EXP-001',
        'category_code': 'fuel',
        'category_name': 'ديزل ووقود',
        'amount_minor': 120000,
        'description': 'تعبئة خزان الديزل',
        'status': 'posted',
        'spent_at': today.toIso8601String(),
        'payment_source': 'cashbox',
        'partner_id': null,
        'partner_name': null,
        'attachment_url': null,
        'attachment_skipped': false,
        'skip_reason': null,
        'recorded_by_name': 'مشغل البئر',
      },
      {
        'id': 'expense-2',
        'well_id': wellId,
        'public_code': 'EXP-002',
        'category_code': 'maintenance',
        'category_name': 'صيانة ومعدات',
        'amount_minor': 45000,
        'description': 'إصلاح لوحة التحكم',
        'status': 'pending_approval',
        'spent_at': today.toIso8601String(),
        'payment_source': 'partner_paid',
        'partner_id': 'partner-1',
        'partner_name': 'عبدالرحمن باجعفر',
        'attachment_url': null,
        'attachment_skipped': true,
        'skip_reason': 'الفاتورة ورقية ولم تُصوَّر',
        'recorded_by_name': 'مشغل البئر',
      },
    ];
    if (status != null) {
      return rows
          .where((row) => row['status'] == status)
          .map(ExpenseItem.fromJson)
          .toList(growable: false);
    }
    return rows.map(ExpenseItem.fromJson).toList(growable: false);
  }
}

void main() {
  group('ExpensesScreen Tests (UX-14 / 425–431)', () {
    testWidgets('1. عرض عناصر شاشة المصروفات والتبويبات والملخص المالي', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: ExpensesScreen(
            identity: testIdentity(),
            repository: _FakeFinanceRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.textContaining('المصروفات'), findsWidgets);
      expect(find.textContaining('اليوم'), findsWidgets);
      expect(find.textContaining('بانتظار الاعتماد'), findsWidgets);
      expect(find.textContaining('السجل'), findsWidgets);
      expect(find.text('إجمالي المصروفات المعتمدة'), findsOneWidget);
      expect(find.text('تسجيل مصروف'), findsOneWidget);
    });

    testWidgets('2. فتح حوار تسجيل مصروف جديد والتحقق من الحقول وخيار تخطي المرفق', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: ExpensesScreen(
            identity: testIdentity(),
            repository: _FakeFinanceRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // الضغط على زر تسجيل مصروف
      await tester.tap(find.text('تسجيل مصروف'));
      await tester.pumpAndSettle();

      expect(find.text('تسجيل مصروف جديد'), findsOneWidget);
      expect(find.text('فئة المصروف *'), findsOneWidget);
      expect(find.text('المبلغ (ريال يمني) *'), findsOneWidget);
      expect(find.text('مصدر سداد المصروف *'), findsOneWidget);
      expect(find.text('بيان وتفاصيل المصروف *'), findsOneWidget);
      expect(find.text('تخطي إرفاق صورة السند / الفاتورة'), findsOneWidget);
      expect(find.text('حفظ المصروف'), findsOneWidget);

      // تفعيل تخطي المرفق
      await tester.tap(find.text('تخطي إرفاق صورة السند / الفاتورة'));
      await tester.pumpAndSettle();

      expect(find.text('سبب عدم توفر المرفق *'), findsOneWidget);
    });

    testWidgets('3. التبديل إلى تبويب بانتظار الاعتماد وفتح نافذة القرار للمالك', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: ExpensesScreen(
            identity: testIdentity(),
            repository: _FakeFinanceRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // التبديل لتبويب بانتظار الاعتماد (Tab index 1)
      await tester.tap(find.byType(Tab).at(1));
      await tester.pumpAndSettle();

      expect(find.text('مراجعة وقرار الاعتماد'), findsOneWidget);

      // فتح نافذة القرار
      await tester.tap(find.text('مراجعة وقرار الاعتماد'));
      await tester.pumpAndSettle();

      expect(find.text('مراجعة المصروف والاعتماد'), findsOneWidget);
      expect(find.text('اعتماد المصروف'), findsOneWidget);
      expect(find.text('رفض'), findsOneWidget);
    });
  });
}

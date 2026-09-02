import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/finance_repository.dart';
import 'package:well_irrigation_mobile/features/finance/partner_detail_financial_screen.dart';
import 'package:well_irrigation_mobile/features/finance/partners_screen.dart';

/// مستودع مزيَّف يعيد ما يعيده عقد api.list_well_partners بأسماء مفاتيح
/// القاعدة نفسها، ويمر عبر المحلّل الحقيقي. النسب من نسخة الملكية السارية،
/// والمال من أسطر التوزيع: الصافي والمدفوع مُرجَعان، والمتبقي فارقهما.
class _FakeFinanceRepository extends FinanceRepository {
  static const List<Map<String, dynamic>> contractPartners = [
    {
      'id': 'partner-1',
      'partner_person_id': 'person-1',
      'full_name': 'عبدالرحمن باجعفر',
      'phone': '770112233',
      'ownership_percent': 40,
      'profit_percent': 40,
      'total_earnings_minor': 180000,
      'out_of_pocket_minor': 25000,
      'irrigation_deduction_minor': 35000,
      'net_payable_minor': 170000,
      'unpaid_minor': 70000,
      'total_paid_minor': 100000,
      'status': 'active',
    },
    {
      'id': 'partner-2',
      'partner_person_id': 'person-2',
      'full_name': 'صالح مهدي العامري',
      'phone': '771445566',
      'ownership_percent': 35,
      'profit_percent': 35,
      'total_earnings_minor': 157500,
      'out_of_pocket_minor': 0,
      'irrigation_deduction_minor': 12000,
      'net_payable_minor': 145500,
      'unpaid_minor': 145500,
      'total_paid_minor': 0,
      'status': 'active',
    },
    {
      'id': 'partner-3',
      'partner_person_id': 'person-3',
      'full_name': 'قاسم محمد الكندي',
      'phone': '',
      'ownership_percent': 25,
      'profit_percent': 25,
      'total_earnings_minor': 112500,
      'out_of_pocket_minor': 8000,
      'irrigation_deduction_minor': 0,
      'net_payable_minor': 120500,
      'unpaid_minor': 20500,
      'total_paid_minor': 100000,
      'status': 'active',
    },
  ];

  @override
  Future<List<PartnerFinancialItem>> fetchPartners(
    String wellId, {
    int limit = 100,
  }) async {
    return contractPartners
        .map(PartnerFinancialItem.fromJson)
        .toList(growable: false);
  }
}

void main() {
  group('Partners & Financial Statement Tests (UX-14 / 432–438)', () {
    testWidgets('1. عرض هيكل الشركاء ونسب الملكية والأرباح ومجموع 100%', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: PartnersScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: 'well-1',
            repository: _FakeFinanceRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('هيكل الشركاء والأرباح'), findsOneWidget);
      expect(find.text('مجموع النسب: 100%'), findsOneWidget);
      expect(find.text('عبدالرحمن باجعفر'), findsOneWidget);
      expect(find.text('صالح مهدي العامري'), findsOneWidget);
      expect(find.text('قاسم محمد الكندي'), findsOneWidget);
      expect(find.text('دورات وتوزيع الأرباح'), findsOneWidget);
    });

    testWidgets('2. فتح كشف حساب الشريك وتفكيك معادلة المستحق الصافي', (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: PartnerDetailFinancialScreen(
            wellId: 'well-1',
            partnerId: 'partner-1',
            wellName: 'بئر الخير الرئيسي',
            repository: _FakeFinanceRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('عبدالرحمن باجعفر'), findsWidgets);
      expect(find.text('المتبقي المستحق للشريك حالياً'), findsOneWidget);
      expect(find.text('تفكيك المستحقات المالية (المعادلة المعتمدة):'), findsOneWidget);
      expect(find.text('الحصة الإجمالية من الأرباح المعتمدة (+):'), findsOneWidget);
      expect(find.text('تعويض مصروفات دفعها من جيبه (+):'), findsOneWidget);
      expect(find.text('استقطاع سقي أرضه الزراعية (-):'), findsOneWidget);
      expect(find.text('صرف أرباح للشريك'), findsOneWidget);

      // فتح حوار صرف الأرباح
      await tester.tap(find.text('صرف أرباح للشريك'));
      await tester.pumpAndSettle();

      expect(find.text('صرف مستحقات الشريك'), findsOneWidget);
      expect(find.text('مبلغ الصرف (ريال يمني) *'), findsOneWidget);
      expect(find.text('تأكيد الصرف'), findsOneWidget);
    });

    testWidgets('3. شريك غير موجود في البئر لا ينتحب بيانات شريك آخر', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: PartnerDetailFinancialScreen(
            wellId: 'well-1',
            partnerId: 'partner-lost',
            wellName: 'بئر الخير الرئيسي',
            repository: _FakeFinanceRepository(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('لم يتم العثور على بيانات الشريك'), findsOneWidget);
      expect(find.text('عبدالرحمن باجعفر'), findsNothing);
    });
  });
}

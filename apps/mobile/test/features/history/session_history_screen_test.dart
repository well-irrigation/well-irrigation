import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/features/history/session_history_screen.dart';

/// مستودع اختبار يحاكي عقد `api.list_well_sessions` (م-41C2).
/// الشاشة لم تعد تملك بيانات تجريبية: إمّا عقد حقيقي أو فشل صريح.
class _FakeOperationsRepository extends OperationsRepository {
  const _FakeOperationsRepository({this.shouldFail = false});

  final bool shouldFail;

  @override
  Future<List<SessionHistoryItem>> fetchSessionHistory({
    required String wellId,
    String? farmerAccountId,
    String? filter,
  }) async {
    if (shouldFail) {
      throw StateError('backend unavailable');
    }

    final started = DateTime.now().subtract(const Duration(hours: 3));

    return [
      SessionHistoryItem(
        id: 'ses-1',
        wellId: wellId,
        farmerName: 'محمد علي الحبيشي',
        farmerCode: 'F-001',
        farmerAccountId: 'acc-1',
        farmName: 'مزرعة الوادي الشرقية',
        pumpName: 'المضخة الرئيسية',
        operatorName: 'المشغل',
        startedAt: started,
        endedAt: started.add(const Duration(hours: 1)),
        energySourceCode: 'solar',
        billableSeconds: 3600,
        totalAmountYER: 3500,
        paidAmountYER: 3500,
        paymentStatus: 'settled',
        hasCharge: true,
        hasInvoice: true,
      ),
      SessionHistoryItem(
        id: 'ses-2',
        wellId: wellId,
        farmerName: 'صالح أحمد الشامي',
        farmerCode: 'F-002',
        farmerAccountId: 'acc-2',
        farmName: 'أرض الشامي',
        pumpName: 'المضخة الثانية',
        operatorName: 'المشغل',
        startedAt: started.subtract(const Duration(hours: 4)),
        endedAt: started.subtract(const Duration(hours: 2)),
        energySourceCode: 'well_diesel',
        billableSeconds: 7200,
        totalAmountYER: 7000,
        paidAmountYER: 3000,
        paymentStatus: 'partial',
        hasCharge: true,
        hasInvoice: true,
      ),
      SessionHistoryItem(
        id: 'ses-3',
        wellId: wellId,
        farmerName: 'عبدالله مسعد القادري',
        farmerCode: 'F-003',
        farmerAccountId: 'acc-3',
        farmName: 'أرض القادري',
        pumpName: 'المضخة الثانية',
        operatorName: 'المشغل',
        startedAt: started.subtract(const Duration(days: 9)),
        endedAt: started.subtract(const Duration(days: 9, hours: -1)),
        energySourceCode: 'farmer_diesel',
      ),
    ];
  }
}

Widget _wrap({bool shouldFail = false}) {
  return MaterialApp(
    locale: const Locale('ar'),
    home: SessionHistoryScreen(
      wellName: 'بئر الخير الرئيسي',
      wellId: 'well-1',
      wells: const [
        WellSummary(
          id: 'well-1',
          tenantId: 'tenant-1',
          name: 'بئر الخير الرئيسي',
          status: 'active',
          roles: ['owner', 'operator'],
        ),
      ],
      repository: _FakeOperationsRepository(shouldFail: shouldFail),
    ),
  );
}

void main() {
  group('SessionHistoryScreen Tests (UX-13 / 373–376)', () {
    testWidgets('1. عرض عناصر شاشة سجل الجلسات وشريط البحث والفلاتر', (tester) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      expect(find.text('بئر الخير الرئيسي'), findsWidgets);
      expect(find.text('سجل جلسات السقي والتاريخ'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('الكل'), findsOneWidget);
      expect(find.text('اليوم'), findsOneWidget);
      expect(find.text('هذا الأسبوع'), findsOneWidget);
      expect(find.text('هذا الشهر'), findsOneWidget);
      expect(find.text('غير مسددة'), findsOneWidget);
    });

    testWidgets('2. عرض بطاقات الجلسات ومؤشرات السداد والمدة والمبالغ', (tester) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      expect(find.text('محمد علي الحبيشي'), findsWidgets);
      expect(find.text('صالح أحمد الشامي'), findsOneWidget);
      expect(find.text('خالص بالكامل ✅'), findsWidgets);
      expect(find.textContaining('دفعة جزئية'), findsOneWidget);
      expect(find.text('طاقة شمسية'), findsWidgets);
      expect(find.text('ديزل البئر'), findsWidgets);
    });

    testWidgets('3. الجلسة غير المفوترة تظهر بحالتها لا كغير مدفوعة (ق-99)', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      expect(find.text('عبدالله مسعد القادري'), findsOneWidget);
      expect(find.text('غير مفوترة بعد'), findsOneWidget);
      expect(find.text('آجل / غير مدفوع 🔴'), findsNothing);
    });

    testWidgets('4. البحث الفوري بالاسم يقلص القائمة', (tester) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'صالح');
      await tester.pumpAndSettle();

      expect(find.text('صالح أحمد الشامي'), findsOneWidget);
      expect(find.text('عبدالله مسعد القادري'), findsNothing);
    });

    testWidgets('5. فشل العقد يظهر خطأً صريحًا مع إعادة المحاولة', (tester) async {
      await tester.pumpWidget(_wrap(shouldFail: true));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('تعذّر تحميل سجل الجلسات'),
        findsOneWidget,
      );
      expect(find.text('إعادة المحاولة'), findsOneWidget);
      expect(find.text('محمد علي الحبيشي'), findsNothing);
    });
  });
}

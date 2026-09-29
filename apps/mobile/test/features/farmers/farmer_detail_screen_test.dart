import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/features/farmers/farmer_detail_screen.dart';

/// مستودع اختبار يحاكي عقد `api` بدل الاعتماد على بيانات وهمية داخل الإنتاج
/// (م-41C1 — الشاشة صارت تعتمد على العقد الحقيقي أو تُظهر الفشل صريحًا).
class _FakeOperationsRepository extends OperationsRepository {
  const _FakeOperationsRepository({this.shouldFail = false, this.customFarms});

  final bool shouldFail;
  final List<Farm>? customFarms;

  @override
  Future<FarmerDetailData> fetchFarmerDetail({
    required String wellId,
    required String farmerAccountId,
  }) async {
    if (shouldFail) {
      throw StateError('backend unavailable');
    }

    return FarmerDetailData(
      account: const FarmerAccount(
        id: 'acc-1',
        fullName: 'محمد علي الحبيشي',
        publicCode: 'F-001',
        phone: '771234567',
      ),
      farms:
          customFarms ??
          const [
            Farm(
              id: 'farm-1',
              wellId: 'well-1',
              name: 'مزرعة الوادي الشرقية',
              farmerAccountId: 'acc-1',
            ),
          ],
      totalSessionsCount: 2,
      totalBilledYER: 12000,
      totalPaidYER: 5000,
      netBalanceYER: 7000,
      recentSessions: const [],
    );
  }
}

Widget _wrap({bool shouldFail = false, bool canCreateFarm = true}) {
  return MaterialApp(
    locale: const Locale('ar'),
    home: FarmerDetailScreen(
      wellId: 'well-1',
      farmerAccountId: 'acc-1',
      wellName: 'بئر الخير الرئيسي',
      canCreateFarm: canCreateFarm,
      repository: _FakeOperationsRepository(shouldFail: shouldFail),
    ),
  );
}

void main() {
  group('FarmerDetailScreen Tests (UX-13 / 380)', () {
    testWidgets('1. عرض الملف الشخصي للمزارع والتبويبات الثلاث', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      expect(find.text('محمد علي الحبيشي'), findsWidgets);
      // الكود الداخلي (`F-001` هنا، و`FWA-…` في الإنتاج) **لا يُعرض** في
      // الملف الشخصي: معرّف بأحرف لاتينية لا يقرؤه مستخدم عادي ولا يفعل به
      // شيئًا. موضعه الوحيد نافذة سند القبض، حيث ورقةٌ تُطبع وتُطابَق.
      expect(find.text('F-001'), findsNothing);
      expect(find.textContaining('الأراضي'), findsOneWidget);
      expect(find.textContaining('الجلسات'), findsOneWidget);
      expect(find.text('كشف الحساب'), findsOneWidget);
      expect(find.text('إضافة أرض'), findsOneWidget);
    });

    testWidgets('2. فتح حوار إضافة أرض جديدة للمزارع', (tester) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('إضافة أرض'));
      await tester.pumpAndSettle();

      expect(find.text('إضافة أرض زراعية جديدة'), findsOneWidget);
      expect(find.text('اسم الأرض أو القطعة الزراعية *'), findsOneWidget);
      expect(find.text('حفظ الأرض'), findsOneWidget);
    });

    testWidgets('المشغّل لا يرى إضافة أرض', (tester) async {
      await tester.pumpWidget(_wrap(canCreateFarm: false));
      await tester.pumpAndSettle();

      expect(find.text('إضافة أرض'), findsNothing);
    });

    testWidgets('3. التبديل إلى تبويب كشف الحساب والمالية', (tester) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('كشف الحساب'));
      await tester.pumpAndSettle();

      expect(find.text('إجمالي فواتير السقي:'), findsOneWidget);
      expect(find.text('إجمالي المدفوعات المسددة:'), findsOneWidget);
      expect(find.text('صافي الرصيد المتبقي:'), findsOneWidget);
    });

    testWidgets('4. فشل العقد يظهر صريحًا بلا بيانات مصطنعة', (tester) async {
      await tester.pumpWidget(_wrap(shouldFail: true));
      await tester.pumpAndSettle();

      expect(find.textContaining('تعذّر تحميل ملف المزارع'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsOneWidget);
      expect(find.text('محمد علي الحبيشي'), findsNothing);
    });

    testWidgets(
      '5. FarmerDetail shows distinguishing label through displayName (Finding 6 / 11.J)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            home: const FarmerDetailScreen(
              wellId: 'well-1',
              farmerAccountId: 'acc-1',
              wellName: 'بئر الخير الرئيسي',
              canCreateFarm: true,
              repository: _FakeOperationsRepository(
                customFarms: [
                  Farm(
                    id: 'farm-1',
                    wellId: 'well-1',
                    name: 'الكوثة',
                    distinguishingLabel: 'الشرقية',
                    farmerAccountId: 'acc-1',
                  ),
                  Farm(
                    id: 'farm-2',
                    wellId: 'well-1',
                    name: 'الكوثة',
                    distinguishingLabel: 'الغربية',
                    farmerAccountId: 'acc-1',
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('الكوثة — الشرقية'), findsOneWidget);
        expect(find.text('الكوثة — الغربية'), findsOneWidget);
      },
    );
  });
}

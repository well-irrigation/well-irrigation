import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/features/farmers/farmers_directory_screen.dart';

import '../../support/identity_fixture.dart';

/// مستودع اختبار يعيد ما يعيده عقد 099 بالضبط: أربعة مزارعين بحالات مختلفة،
/// **مرتَّبين من «الخادم»** بآخر سقي — فيُقاس أن الشاشة تعرض ترتيبه ولا تعيد
/// ترتيبه بنفسها.
class _FakeOperationsRepository extends OperationsRepository {
  const _FakeOperationsRepository();

  @override
  Future<FarmerDirectoryData> fetchFarmerDirectory(
    String wellId, {
    String? query,
  }) async {
    final currentWellDay = DateTime(2100, 1, 10);
    return FarmerDirectoryData(
      currentDay: currentWellDay,
      entries: [
        // جلسة جارية: لا تاريخ نهاية، وحضورها معلَن (ق-37).
        FarmerDirectoryEntry(
          id: 'acc-open',
          fullName: 'جميل الجاري',
          publicCode: 'FWA-OPEN',
          status: 'active',
          phone: '771000001',
          farmsCount: 1,
          debtYER: 0,
          advanceYER: 0,
          sessionsCount: 0,
          hasOpenSession: true,
        ),
        // سقى أمس، وله رصيد مقدَّم.
        FarmerDirectoryEntry(
          id: 'acc-recent',
          fullName: 'بشير الحديث',
          publicCode: 'FWA-NEW',
          status: 'active',
          phone: '771000002',
          farmsCount: 2,
          debtYER: 0,
          advanceYER: 25000,
          sessionsCount: 3,
          hasOpenSession: false,
          lastSessionAt: currentWellDay.subtract(const Duration(days: 1)),
          lastSessionDay: currentWellDay.subtract(const Duration(days: 1)),
        ),
        // سقى قبل أسبوع، وعليه دَين.
        FarmerDirectoryEntry(
          id: 'acc-older',
          fullName: 'أحمد القديم',
          publicCode: 'FWA-OLD',
          status: 'active',
          farmsCount: 1,
          debtYER: 90000,
          advanceYER: 0,
          sessionsCount: 1,
          hasOpenSession: false,
          lastSessionAt: currentWellDay.subtract(const Duration(days: 7)),
          lastSessionDay: currentWellDay.subtract(const Duration(days: 7)),
        ),
        // لم يسقِ قطّ ولا أرض له.
        const FarmerDirectoryEntry(
          id: 'acc-never',
          fullName: 'خالد بلا سقي',
          publicCode: 'FWA-NONE',
          status: 'active',
          farmsCount: 0,
          debtYER: 0,
          advanceYER: 0,
          sessionsCount: 0,
          hasOpenSession: false,
        ),
      ],
    );
  }
}

class _SwitchingRepository extends OperationsRepository {
  final wellOne = Completer<FarmerDirectoryData>();
  final wellTwo = Completer<FarmerDirectoryData>();

  @override
  Future<FarmerDirectoryData> fetchFarmerDirectory(
    String wellId, {
    String? query,
  }) {
    return wellId == 'well-1' ? wellOne.future : wellTwo.future;
  }
}

void main() {
  const well = WellSummary(
    id: 'well-1',
    tenantId: 'tenant-1',
    name: 'بئر الخير الرئيسي',
    status: 'active',
    roles: ['owner', 'operator'],
  );

  Widget wrap() {
    return MaterialApp(
      locale: const Locale('ar'),
      home: FarmersDirectoryScreen(
        identity: testIdentity(wells: const [well]),
        repository: const _FakeOperationsRepository(),
      ),
    );
  }

  group('FarmersDirectoryScreen Tests (UX-13 / 380)', () {
    testWidgets('1. عرض عناصر دليل المزارعين وشريط البحث وزر الإضافة', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('دليل المزارعين والأراضي'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('مزارع جديد'), findsOneWidget);
    });

    testWidgets('2. فتح حوار إضافة مزارع جديد عند الضغط على الزر العائم', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('مزارع جديد'));
      await tester.pumpAndSettle();

      expect(find.text('إضافة مزارع جديد'), findsOneWidget);
      expect(find.text('الاسم الكامل للمزارع *'), findsOneWidget);
      expect(find.text('حفظ المزارع'), findsOneWidget);
      // تلميح عام لا اسم شخص: اسمٌ كامل في الحقل يظنّه المستعجل قيمة مكتوبة.
      expect(find.text('الاسم الثلاثي'), findsOneWidget);
      expect(find.textContaining('محمد عبدالله الشامي'), findsNothing);
    });
  });
  group('ترتيب الدليل وفلترته — هجرة 099', () {
    testWidgets('3. القائمة تعرض ترتيب الخادم ولا تعيد ترتيبه', (tester) async {
      // ترتيب «الخادم» في المستودع الوهمي: الجاري، ثم الحديث، ثم القديم، ثم
      // من لم يسقِ. والأسماء أبجديًّا عكسه — فلو أعادت الشاشة الترتيب بنفسها
      // لظهر «أحمد» أولًا. وشاشتان ترتّبان بأساسين مختلفين تعرضان حقيقتين.
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final names = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .where(
            (s) =>
                s.contains('الجاري') ||
                s.contains('الحديث') ||
                s.contains('القديم') ||
                s.contains('بلا سقي'),
          )
          .toList();

      expect(names.first, contains('الجاري'));
      expect(names.last, contains('بلا سقي'));
    });

    testWidgets('4. وصف آخر سقي يتبع يوم البئر لا تاريخ الجهاز', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('جلسة سقي جارية الآن'), findsOneWidget);
      expect(find.text('آخر سقي: أمس'), findsOneWidget);
      // «لم يسقِ بعد» حقيقة صريحة لا شرطة صامتة ولا تاريخ مُلفَّق. ويظهر
      // مرتين: وسمًا على شريحة الفلترة، وسطرًا في بطاقة من لم يسقِ.
      expect(find.text('لم يسقِ بعد'), findsNWidgets(2));
    });

    testWidgets('5. الدين والرصيد يظهران في القائمة بوسم مقروء', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // «عليه 90,000» في البطاقة، و«عليه مستحقات» وسمًا على الشريحة.
      expect(find.textContaining('عليه 90,000'), findsOneWidget);
      expect(find.textContaining('له 25,000'), findsOneWidget);
    });

    testWidgets('6. الفلترة تُخفي غير المطابق وتُبقي العدّ على الكل', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // شريحة «عليه مستحقات»: واحد من أربعة.
      await tester.tap(find.text('عليه مستحقات'));
      await tester.pumpAndSettle();

      expect(find.text('أحمد القديم'), findsOneWidget);
      expect(find.text('بشير الحديث'), findsNothing);
      // العدّاد يقول «معروض من» لا «مسجل»: الرقم يتبع الفلتر فوصفه بـ«مسجل»
      // يجعله يكذب.
      expect(find.textContaining('معروض من 4'), findsOneWidget);
    });

    testWidgets('7. شريحة «يسقي الآن» تعزل صاحب الجلسة الجارية', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('يسقي الآن'));
      await tester.pumpAndSettle();

      expect(find.text('جميل الجاري'), findsOneWidget);
      expect(find.text('خالد بلا سقي'), findsNothing);
    });

    testWidgets('8. استجابة البئر السابق لا تستبدل بيانات البئر النشط', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final repository = _SwitchingRepository();
      final secondWell = testWell(id: 'well-2', name: 'بئر ثانٍ');
      final identity = testIdentity(wells: [testWell(), secondWell]);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: FarmersDirectoryScreen(
            identity: identity,
            repository: repository,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('بئر الخير الرئيسي'));
      await tester.pump(const Duration(milliseconds: 500));
      final secondWellTile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'بئر ثانٍ'),
      );
      secondWellTile.onTap!();
      await tester.pump(const Duration(milliseconds: 500));

      repository.wellTwo.complete(
        FarmerDirectoryData(
          currentDay: DateTime(2100, 1, 10),
          entries: const [
            FarmerDirectoryEntry(
              id: 'second-account',
              fullName: 'مزارع البئر الثاني',
              publicCode: 'FWA-2',
              status: 'active',
              farmsCount: 0,
              debtYER: 0,
              advanceYER: 0,
              sessionsCount: 0,
              hasOpenSession: false,
            ),
          ],
        ),
      );
      await tester.pump();

      repository.wellOne.complete(
        FarmerDirectoryData(
          currentDay: DateTime(2100, 1, 10),
          entries: const [
            FarmerDirectoryEntry(
              id: 'first-account',
              fullName: 'مزارع البئر الأول',
              publicCode: 'FWA-1',
              status: 'active',
              farmsCount: 0,
              debtYER: 0,
              advanceYER: 0,
              sessionsCount: 0,
              hasOpenSession: false,
            ),
          ],
        ),
      );
      await tester.pump();

      expect(find.text('مزارع البئر الثاني'), findsOneWidget);
      expect(find.text('مزارع البئر الأول'), findsNothing);
    });
  });
}

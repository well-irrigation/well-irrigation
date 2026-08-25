import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/widgets/top_well_selector.dart';

void main() {
  group('TopWellSelector Tests (UX-05 / ق-87)', () {
    final wells = [
      const WellSummary(
        id: 'well-1',
        tenantId: 'tenant-1',
        name: 'بئر الخير الرئيسي',
        status: 'active',
        roles: ['owner', 'operator'],
      ),
      const WellSummary(
        id: 'well-2',
        tenantId: 'tenant-1',
        name: 'بئر الوادي الشرقي',
        status: 'active',
        roles: ['owner'],
      ),
    ];

    testWidgets('يعرض اسم البئر والوصف الفرعي', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: TopWellSelector(
                wells: wells,
                activeWell: wells.first,
                subtitle: 'لوحة التشغيل',
                onWellChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('بئر الخير الرئيسي'), findsOneWidget);
      expect(find.text('لوحة التشغيل'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    });

    testWidgets('فتح قائمة الآبار والتبديل إلى بئر آخر', (tester) async {
      WellSummary? selectedWell;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: StatefulBuilder(
                builder: (context, setState) {
                  return TopWellSelector(
                    wells: wells,
                    activeWell: selectedWell ?? wells.first,
                    subtitle: 'الرئيسية',
                    onWellChanged: (well) => setState(() => selectedWell = well),
                  );
                },
              ),
            ),
          ),
        ),
      );

      // النقر لفتح قائمة التبديل
      await tester.tap(find.text('بئر الخير الرئيسي'));
      await tester.pumpAndSettle();

      expect(find.text('التبديل بين الآبار المتاحة'), findsOneWidget);
      expect(find.text('بئر الوادي الشرقي'), findsOneWidget);

      // اختيار البئر الثاني
      await tester.tap(find.text('بئر الوادي الشرقي'));
      await tester.pumpAndSettle();

      expect(find.text('بئر الوادي الشرقي'), findsOneWidget);
    });
  });
}

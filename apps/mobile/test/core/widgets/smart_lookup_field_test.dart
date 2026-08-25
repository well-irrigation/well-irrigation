import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/widgets/smart_lookup_field.dart';

class TestItem {
  const TestItem({required this.id, required this.name, this.phone});
  final String id;
  final String name;
  final String? phone;
}

void main() {
  group('SmartLookupField Widget Tests (ق-88 / ق-119)', () {
    final testItems = [
      const TestItem(id: '1', name: 'محمد علي النجحي', phone: '771234567'),
      const TestItem(id: '2', name: 'أحمد صالح الشامي', phone: '772345678'),
      const TestItem(id: '3', name: 'خالد عبدالله القاسمي', phone: '773456789'),
    ];

    testWidgets('يعرض اسم الحقل والنص التلميحي عند عدم الاختيار', (tester) async {
      TestItem? selected;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SmartLookupField<TestItem>(
              label: 'المزارع',
              hintText: 'اختر مزارعاً...',
              selectedItem: selected,
              itemLabel: (item) => item.name,
              itemSecondaryLabel: (item) => item.phone,
              searchFunction: (q) async => testItems,
              onChanged: (item) => selected = item,
            ),
          ),
        ),
      );

      expect(find.text('المزارع'), findsOneWidget);
      expect(find.text('اختر مزارعاً...'), findsOneWidget);
    });

    testWidgets('يعرض الاسم المختار والبيان التمييزي الثانوي عند وجود اختيار', (tester) async {
      final selected = testItems.first;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SmartLookupField<TestItem>(
              label: 'المزارع',
              hintText: 'اختر مزارعاً...',
              selectedItem: selected,
              itemLabel: (item) => item.name,
              itemSecondaryLabel: (item) => item.phone,
              searchFunction: (q) async => testItems,
              onChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('محمد علي النجحي'), findsOneWidget);
      expect(find.text('771234567'), findsOneWidget);
    });

    testWidgets('فتح نافذة البحث واختيار عنصر بنجاح', (tester) async {
      TestItem? selected;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return SmartLookupField<TestItem>(
                  label: 'المزارع',
                  hintText: 'اختر مزارعاً...',
                  selectedItem: selected,
                  itemLabel: (item) => item.name,
                  itemSecondaryLabel: (item) => item.phone,
                  searchFunction: (q) async {
                    if (q.isEmpty) return testItems;
                    return testItems.where((i) => i.name.contains(q)).toList();
                  },
                  onChanged: (item) => setState(() => selected = item),
                );
              },
            ),
          ),
        ),
      );

      // فتح قائمة البحث بالنقر على الحقل
      await tester.tap(find.text('اختر مزارعاً...'));
      await tester.pumpAndSettle();


      expect(find.text('اختيار المزارع'), findsOneWidget);
      expect(find.text('أحمد صالح الشامي'), findsOneWidget);

      // اختيار العنصر الثاني
      await tester.tap(find.text('أحمد صالح الشامي'));
      await tester.pumpAndSettle();

      // التأكد من إغلاق النافذة وظهور العنصر المختار في الحقل
      expect(find.text('أحمد صالح الشامي'), findsOneWidget);
      expect(find.text('772345678'), findsOneWidget);
    });
  });
}

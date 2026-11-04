import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/widgets/farm_create_dialog.dart';

void main() {
  testWidgets(
    'empty validation, one durable save, simple success and returned farm',
    (tester) async {
      final committed = Completer<Farm>();
      var saves = 0;
      Farm? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selected = await showFarmCreateDialog(
                    context: context,
                    farmerName: 'أحمد',
                    save: (name, label) {
                      saves++;
                      expect(name, 'الوادي');
                      expect(label, 'الشرقية');
                      return committed.future;
                    },
                  );
                },
                child: const Text('فتح'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('فتح'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('حفظ'));
      await tester.pump();
      expect(saves, 0);
      expect(find.text('اسم الأرض مطلوب'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).at(0), 'الوادي');
      await tester.enterText(find.byType(TextFormField).at(1), 'الشرقية');
      await tester.tap(find.text('حفظ'));
      await tester.pump();
      await tester.tap(find.text('حفظ'));
      await tester.pump();
      expect(saves, 1);
      expect(selected, isNull);
      committed.complete(
        const Farm(
          id: 'farm',
          wellId: 'well',
          name: 'الوادي',
          farmerAccountId: 'farmer',
        ),
      );
      await tester.pumpAndSettle();
      expect(selected!.id, 'farm');
      expect(find.text('تم حفظ الأرض'), findsOneWidget);
      expect(find.textContaining('مزامنة'), findsNothing);
    },
  );
}

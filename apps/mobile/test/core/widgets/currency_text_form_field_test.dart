import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/widgets/currency_text_form_field.dart';

void main() {
  testWidgets(
    'optional tafqeet formatter changes display only; default sibling is unchanged',
    (t) async {
      final defaultController = TextEditingController(text: '86');
      final customController = TextEditingController(text: '86');
      addTearDown(defaultController.dispose);
      addTearDown(customController.dispose);
      int? changed;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                CurrencyTextFormField(controller: defaultController),
                CurrencyTextFormField(
                  controller: customController,
                  tafqeetFormatter: (amount) =>
                      amount == 86 ? 'ستة وثمانون ريالًا' : 'صياغة $amount',
                  onChanged: (amount) => changed = amount,
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('ستة وثمانون ريال'), findsOneWidget);
      expect(find.text('ستة وثمانون ريالًا'), findsOneWidget);
      expect(defaultController.text, '86');
      expect(customController.text, '86');
      await t.enterText(find.byType(TextFormField).last, '125');
      await t.pumpAndSettle();
      expect(changed, 125);
      expect(customController.text, '125');
      expect(defaultController.text, '86');
      expect(find.text('صياغة 125'), findsOneWidget);
      expect(find.text('ستة وثمانون ريال'), findsOneWidget);
    },
  );
}

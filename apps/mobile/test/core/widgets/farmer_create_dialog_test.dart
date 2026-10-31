import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/utils/contact_picker.dart';
import 'package:well_irrigation_mobile/core/widgets/farmer_create_dialog.dart';

void main() {
  Future<void> open(
    WidgetTester tester, {
    required Future<FarmerAccount> Function(String, String?) save,
    Future<ContactPickResult> Function()? picker,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showFarmerCreateDialog(
                context: context,
                save: save,
                contactPicker: picker,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'empty name stays open; manual Persian phone is normalized before save',
    (tester) async {
      String? savedName, savedPhone;
      await open(
        tester,
        save: (name, phone) async {
          savedName = name;
          savedPhone = phone;
          return const FarmerAccount(id: 'f', fullName: 'علي', publicCode: 'F');
        },
      );
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();
      expect(find.text('اسم المزارع مطلوب'), findsOneWidget);
      expect(savedName, isNull);
      await tester.enterText(find.byKey(const Key('farmer_name')), '  علي  ');
      await tester.enterText(
        find.byKey(const Key('farmer_phone')),
        '+۹۶۷ ۷۷۱۲۳۴۵۶۷',
      );
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();
      expect(savedName, 'علي');
      expect(savedPhone, '771234567');
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
  for (final status in [
    ContactPickStatus.picked,
    ContactPickStatus.permissionDenied,
    ContactPickStatus.cancelled,
    ContactPickStatus.failed,
  ]) {
    testWidgets(
      'contact $status is opt in and preserves manual input except picked',
      (tester) async {
        var calls = 0;
        String? saved;
        await open(
          tester,
          picker: () async {
            calls++;
            return ContactPickResult(status, phone: '779999999');
          },
          save: (name, phone) async {
            saved = phone;
            return const FarmerAccount(
              id: 'f',
              fullName: 'علي',
              publicCode: 'F',
            );
          },
        );
        expect(calls, 0);
        await tester.enterText(find.byKey(const Key('farmer_name')), 'علي');
        await tester.enterText(
          find.byKey(const Key('farmer_phone')),
          '771111111',
        );
        await tester.tap(find.byTooltip('اختيار من جهات الاتصال'));
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text('حفظ'));
        await tester.pumpAndSettle();
        expect(
          saved,
          status == ContactPickStatus.picked ? '779999999' : '771111111',
        );
      },
    );
  }
  testWidgets('phone optional and raw save failures never appear', (
    tester,
  ) async {
    await open(
      tester,
      save: (name, phone) async {
        expect(phone, isNull);
        throw StateError('SECRET_RPC_UUID');
      },
    );
    await tester.enterText(find.byKey(const Key('farmer_name')), 'علي');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(find.textContaining('SECRET_RPC_UUID'), findsNothing);
    expect(find.text('تعذر حفظ المزارع. حاول مرة أخرى.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });
}

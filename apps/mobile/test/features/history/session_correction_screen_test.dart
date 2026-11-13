import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/history/session_correction_screen.dart';

const _startKey = ValueKey('session_correction_start');
const _endKey = ValueKey('session_correction_end');
const _reasonKey = ValueKey('session_correction_reason');
const _requiredReason = 'سبب التصحيح مطلوب';
const _orderError = 'يجب أن تكون البداية قبل النهاية';
const _futureError = 'لا يمكن أن تكون نهاية الجلسة في المستقبل';

void main() {
  Future<void> open(
    WidgetTester tester, {
    DateTime? start,
    DateTime? end,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: SessionCorrectionScreen(
          sessionId: 'session-snapshot',
          effectiveStartedAt: start ?? DateTime(2025, 11, 6, 9),
          effectiveEndedAt: end ?? DateTime(2025, 11, 6, 11),
          operationalRevision: 3,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String text(WidgetTester tester, Key key) => tester
      .widget<EditableText>(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(EditableText),
        ),
      )
      .controller
      .text;

  void snapshotUnchanged(WidgetTester tester) {
    final screen = tester.widget<SessionCorrectionScreen>(
      find.byType(SessionCorrectionScreen),
    );
    expect(screen.sessionId, 'session-snapshot');
    expect(screen.operationalRevision, 3);
    // No revision/session selector is exposed to the user.
    expect(find.text('session-snapshot'), findsNothing);
    expect(find.text('3'), findsNothing);
  }

  Future<void> reason(WidgetTester tester, String value) async {
    await tester.enterText(find.byKey(_reasonKey), value);
    await tester.tap(find.byType(AppBar));
    await tester.pumpAndSettle();
  }

  Future<void> choose(
    WidgetTester tester,
    Key key, {
    required int day,
    required String hour,
    required String minute,
  }) async {
    final before = text(tester, key);
    final field = tester.widget<EditableText>(
      find.descendant(of: find.byKey(key), matching: find.byType(EditableText)),
    );
    expect(
      field.readOnly,
      isTrue,
      reason: 'dates are selected, never free text',
    );
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
    expect(
      find.byType(DatePickerDialog),
      findsOneWidget,
      reason: 'Expected date picker after tapping correction time',
    );
    // Standard calendar selection, not text entry for a date.
    await tester.tap(
      find
          .descendant(
            of: find.byType(DatePickerDialog),
            matching: find.text('$day'),
          )
          .last,
    );
    await tester.tap(find.widgetWithText(TextButton, 'OK').last);
    await tester.pumpAndSettle();
    expect(
      find.byType(TimePickerDialog),
      findsOneWidget,
      reason: 'Expected time picker after selecting correction date',
    );
    // Standard time picker input mode also supports precise minutes.
    final input = find.byIcon(Icons.keyboard_outlined);
    if (input.evaluate().isNotEmpty) {
      await tester.tap(input);
      await tester.pumpAndSettle();
    }
    final fields = find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.byType(TextField),
    );
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), hour);
    await tester.enterText(fields.at(1), minute);
    await tester.tap(find.widgetWithText(TextButton, 'OK').last);
    await tester.pumpAndSettle();
    expect(text(tester, key), isNot(before));
    expect(text(tester, key), contains('$hour:$minute'));
    snapshotUnchanged(tester);
  }

  testWidgets(
    'initial effective snapshot has empty reason and fixed identity/revision',
    (tester) async {
      await open(tester);
      expect(text(tester, _startKey), contains('09:00'));
      expect(text(tester, _endKey), contains('11:00'));
      expect(text(tester, _reasonKey), isEmpty);
      snapshotUnchanged(tester);
    },
  );

  testWidgets(
    'start date and time editable with standard pickers; snapshot stays fixed',
    (tester) async {
      await open(tester);
      final endBefore = text(tester, _endKey);
      await choose(tester, _startKey, day: 5, hour: '08', minute: '30');
      expect(text(tester, _startKey), contains('2025/11/05'));
      expect(text(tester, _endKey), endBefore);
      await reason(tester, 'تصحيح وقت التشغيل الفعلي');
      snapshotUnchanged(tester);
    },
  );

  testWidgets('end date and time editable independently on another day', (
    tester,
  ) async {
    await open(tester);
    final startBefore = text(tester, _startKey);
    await choose(tester, _endKey, day: 7, hour: '10', minute: '45');
    expect(text(tester, _endKey), contains('2025/11/07'));
    expect(text(tester, _startKey), startBefore);
    snapshotUnchanged(tester);
  });

  for (final value in ['', '   ', '\n\t']) {
    testWidgets('reason ${value.codeUnits} is invalid after interaction', (
      tester,
    ) async {
      await open(tester);
      await reason(tester, value);
      expect(find.text(_requiredReason), findsOneWidget);
      snapshotUnchanged(tester);
    });
  }

  for (final start in [DateTime(2025, 11, 6, 11), DateTime(2025, 11, 6, 12)]) {
    testWidgets(
      'invalid temporal order $start is visible without swapping times',
      (tester) async {
        await open(tester, start: start);
        final startBefore = text(tester, _startKey);
        final endBefore = text(tester, _endKey);
        await reason(tester, 'تصحيح وقت التشغيل الفعلي');
        expect(find.text(_orderError), findsOneWidget);
        expect(text(tester, _startKey), startBefore);
        expect(text(tester, _endKey), endBefore);
      },
    );
  }

  testWidgets(
    'future end is invalid, independently of today and picker limits',
    (tester) async {
      // Fixed far-future fixture avoids dependence on the current day/minute.
      await open(tester, end: DateTime(9999, 11, 6, 11));
      await reason(tester, 'تصحيح وقت التشغيل الفعلي');
      expect(
        find.text(_futureError),
        findsOneWidget,
        reason: 'a future end must never become a valid draft',
      );
    },
  );

  testWidgets('reason error clears once trimmed content is nonempty', (
    tester,
  ) async {
    await open(tester);
    await reason(tester, '   ');
    expect(find.text(_requiredReason), findsOneWidget);
    await reason(tester, '  تصحيح وقت التشغيل الفعلي  ');
    expect(find.text(_requiredReason), findsNothing);
    expect(text(tester, _reasonKey), '  تصحيح وقت التشغيل الفعلي  ');
    // Later write canonicalization = reason.trim(); no payload tested here.
    snapshotUnchanged(tester);
  });

  testWidgets(
    'valid edited draft has no validation errors and preserves opening revision',
    (tester) async {
      await open(tester);
      await choose(tester, _startKey, day: 6, hour: '08', minute: '30');
      await choose(tester, _endKey, day: 6, hour: '10', minute: '45');
      await reason(tester, 'تصحيح وقت التشغيل الفعلي');
      for (final message in [_requiredReason, _orderError, _futureError]) {
        expect(find.text(message), findsNothing);
      }
      snapshotUnchanged(tester);
      // No Supabase/repository/coordinator is supplied: editing is local only.
    },
  );
}

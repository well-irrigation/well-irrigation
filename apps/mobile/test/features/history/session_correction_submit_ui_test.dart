import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/features/history/session_detail_screen.dart';

const _startKey = ValueKey('session_correction_start');
const _endKey = ValueKey('session_correction_end');
const _reasonKey = ValueKey('session_correction_reason');
const _submitKey = ValueKey('session_correction_submit');
const _reason = 'تصحيح وقت التشغيل الفعلي';
const _pendingMessage =
    'تم حفظ طلب التصحيح، وسيتم التحقق من النتيجة عند المزامنة.';
const _reviewMessage = 'هذا التصحيح يحتاج إلى مراجعة قبل المتابعة.';
const _conflictMessage = 'يوجد تصحيح سابق غير محسوم لهذه الجلسة.';
const _failureMessage = 'تعذر حفظ التصحيح. حاول مرة أخرى.';
final _effectiveStart = DateTime.utc(2026, 11, 8, 2, 30);
final _effectiveEnd = DateTime.utc(2026, 11, 8, 4, 45);

class _DetailRepository extends OperationsRepository {
  int reads = 0;
  int revision = 3;
  DateTime effectiveStart = _effectiveStart;
  DateTime effectiveEnd = _effectiveEnd;

  @override
  Future<SessionDetailData> fetchSessionDetail(String sessionId) async {
    reads++;
    return SessionDetailData(
      canCorrectSession: true,
      canReadSessionCorrections: false,
      session: SessionHistoryItem(
        id: sessionId,
        wellId: 'well-1',
        farmerName: 'مزارع',
        farmerCode: 'F1',
        farmerAccountId: 'farmer-1',
        farmName: 'أرض',
        pumpName: 'مضخة',
        operatorName: 'مشغل',
        startedAt: DateTime.utc(2026, 11, 8, 1),
        endedAt: DateTime.utc(2026, 11, 8, 6),
        originalStartedAt: DateTime.utc(2026, 11, 8, 1, 30),
        originalEndedAt: DateTime.utc(2026, 11, 8, 5),
        effectiveStartedAt: effectiveStart,
        effectiveEndedAt: effectiveEnd,
        operationalRevision: revision,
        financialStatus: 'pending',
        financialAppliedRevision: 0,
      ),
      segments: const [],
    );
  }
}

class _ControlledCoordinator extends OfflineSessionCoordinator {
  _ControlledCoordinator(InMemoryOutboxStore store) : super(store: store);
  // اختبار واجهة فقط؛ لا نفعّل مؤقت التشغيل الحقيقي في المنسق الوهمي.
  @override
  Future<void> initialize() async {}

  final calls = <Map<String, Object>>[];
  Completer<CommandEnvelope> result = Completer<CommandEnvelope>();

  @override
  Future<CommandEnvelope> submitSessionCorrection({
    required String accountId,
    required String wellId,
    required String sessionId,
    required int baseRevision,
    required String reason,
    required DateTime desiredStartedAt,
    required DateTime desiredEndedAt,
  }) {
    calls.add({
      'accountId': accountId,
      'wellId': wellId,
      'sessionId': sessionId,
      'baseRevision': baseRevision,
      'reason': reason,
      'desiredStartedAt': desiredStartedAt,
      'desiredEndedAt': desiredEndedAt,
    });
    return result.future;
  }
}

CommandEnvelope _envelope(CommandStatus status) => CommandEnvelope(
  localId: 'local-correction-1',
  commandId: 'correction-command-1',
  accountId: 'account-a',
  wellId: 'well-1',
  sequence: 1,
  type: CommandType.correctIrrigationSession,
  status: status,
  occurredAt: DateTime.utc(2026, 11, 9, 9),
  createdLocalAt: DateTime.utc(2026, 11, 9, 9),
  payload: {
    'p_session_id': 'server-session-1',
    'p_base_revision': 3,
    'p_reason': _reason,
    'p_desired_started_at': _effectiveStart.toIso8601String(),
    'p_desired_ended_at': _effectiveEnd.toIso8601String(),
  },
);

String _formatted(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}/${two(local.month)}/${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

void main() {
  late InMemoryOutboxStore store;
  late _ControlledCoordinator coordinator;
  late _DetailRepository repository;
  setUp(() {
    store = InMemoryOutboxStore();
    coordinator = _ControlledCoordinator(store);
    repository = _DetailRepository();
  });
  tearDown(() async {
    coordinator.dispose();
    await store.close();
  });

  String fieldText(WidgetTester tester, Key key) => tester
      .widget<EditableText>(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(EditableText),
        ),
      )
      .controller
      .text;

  void formOpen() {
    for (final key in [_startKey, _endKey, _reasonKey]) {
      expect(find.byKey(key), findsOneWidget);
    }
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('تصحيح السجل'),
      ),
      findsOneWidget,
    );
  }

  void noServerSuccess() {
    for (final message in [
      'تم التصحيح',
      'تم تعديل الجلسة بنجاح',
      'تم قبول التصحيح',
    ]) {
      expect(find.text(message), findsNothing);
    }
  }

  ButtonStyleButton submitButton(WidgetTester tester) {
    final finder = find.byKey(_submitKey);
    expect(
      finder,
      findsOneWidget,
      reason: 'Expected correction submit control: حفظ التصحيح',
    );
    expect(
      find.descendant(of: finder, matching: find.text('حفظ التصحيح')),
      findsOneWidget,
    );
    return tester.widget<ButtonStyleButton>(finder);
  }

  Future<void> open(WidgetTester tester) async {
    // ربط أخطاء Future بنطاق testWidgets نفسه، لا بنطاق setUp الخارجي.
    coordinator.result = Completer<CommandEnvelope>();
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: SessionDetailScreen(
          sessionId: 'server-session-1',
          wellName: 'بئر',
          accountId: 'account-a',
          wellId: 'well-1',
          repository: repository,
          coordinator: coordinator,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final action = find.text('تصحيح السجل');
    expect(action, findsOneWidget);
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();
    formOpen();
    expect(fieldText(tester, _startKey), _formatted(_effectiveStart));
    expect(fieldText(tester, _endKey), _formatted(_effectiveEnd));
    expect(repository.reads, 1);
    await tester.enterText(find.byKey(_reasonKey), '   $_reason   ');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    addTearDown(() async {
      if (coordinator.calls.isNotEmpty && !coordinator.result.isCompleted) {
        coordinator.result.complete(_envelope(CommandStatus.pending));
        await tester.pump();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  Future<void> submit(WidgetTester tester) async {
    expect(submitButton(tester).onPressed, isNotNull);
    await tester.ensureVisible(find.byKey(_submitKey));
    await tester.tap(find.byKey(_submitKey));
    await tester.pump(); // لا pumpAndSettle أثناء مؤشر تقدم متحرك.
    expect(coordinator.calls, hasLength(1));
  }

  Future<void> assertLocked(WidgetTester tester) async {
    expect(submitButton(tester).onPressed, isNull);
    await tester.tap(find.byKey(_submitKey));
    await tester.pump();
    expect(coordinator.calls, hasLength(1));
    formOpen();
    noServerSuccess();
    expect(repository.reads, 1);
  }

  testWidgets(
    'A submits exact immutable opening snapshot and canonical reason',
    (tester) async {
      await open(tester);
      // أي قراءة جديدة ستعيد حقائق مختلفة؛ الطلب يجب أن يحتفظ بلقطة الفتح.
      repository.revision = 99;
      repository.effectiveStart = DateTime.utc(2026, 11, 7, 1);
      repository.effectiveEnd = DateTime.utc(2026, 11, 7, 2);
      await submit(tester);
      expect(coordinator.calls.single, {
        'accountId': 'account-a',
        'wellId': 'well-1',
        'sessionId': 'server-session-1',
        'baseRevision': 3,
        'reason': _reason,
        'desiredStartedAt': _effectiveStart,
        'desiredEndedAt': _effectiveEnd,
      });
      expect(repository.reads, 1);
      formOpen();
      noServerSuccess();
    },
  );

  testWidgets(
    'B in-flight submission disables double tap and keeps form open',
    (tester) async {
      await open(tester);
      await submit(tester);
      expect(coordinator.result.isCompleted, isFalse);
      await assertLocked(tester);
      expect(find.text(_pendingMessage), findsNothing);
    },
  );

  for (final status in [CommandStatus.pending, CommandStatus.dispatching]) {
    testWidgets(
      'durable $status shows honest local message and prevents resubmit',
      (tester) async {
        await open(tester);
        await submit(tester);
        coordinator.result.complete(_envelope(status));
        await tester.pump();
        await tester.pump();
        expect(find.text(_pendingMessage), findsOneWidget);
        await assertLocked(tester);
      },
    );
  }

  testWidgets(
    'E review duplicate stays open with review message and no resubmit',
    (tester) async {
      await open(tester);
      await submit(tester);
      coordinator.result.complete(_envelope(CommandStatus.review));
      await tester.pump();
      await tester.pump();
      expect(find.text(_reviewMessage), findsOneWidget);
      expect(find.text(_pendingMessage), findsNothing);
      await assertLocked(tester);
    },
  );

  testWidgets('F typed conflict is specific and never invites blind resubmit', (
    tester,
  ) async {
    await open(tester);
    await submit(tester);
    coordinator.result.completeError(
      SessionCorrectionConflict(_envelope(CommandStatus.pending)),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text(_conflictMessage), findsOneWidget);
    expect(find.text(_failureMessage), findsNothing);
    await assertLocked(tester);
  });

  testWidgets(
    'G unexpected pre-save failure allows retry without success claim',
    (tester) async {
      await open(tester);
      await submit(tester);
      coordinator.result.completeError(StateError('save_unavailable'));
      await tester.pump();
      await tester.pump();
      expect(find.text(_failureMessage), findsOneWidget);
      formOpen();
      noServerSuccess();
      expect(submitButton(tester).onPressed, isNotNull);
      coordinator.result = Completer<CommandEnvelope>();
      await tester.tap(find.byKey(_submitKey));
      await tester.pump();
      expect(coordinator.calls, hasLength(2));
      expect(coordinator.calls[1], coordinator.calls[0]);
      expect(repository.reads, 1);
    },
  );
}

import 'dart:async';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/session/session_segment.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/session_correction_receipt.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/features/history/session_detail_screen.dart';

const _session = 'server-session-1';
const _reason = 'تصحيح وقت التشغيل الفعلي';
const _submitKey = ValueKey('session_correction_submit');
const _refreshKey = ValueKey('session_correction_refresh');
const _reasonKey = ValueKey('session_correction_reason');
const _startKey = ValueKey('session_correction_start');
const _endKey = ValueKey('session_correction_end');
const _pending = 'تم حفظ طلب التصحيح، وسيتم التحقق من النتيجة عند المزامنة.';
const _review = 'هذا التصحيح يحتاج إلى مراجعة قبل المتابعة.';
const _observeError = 'تعذر التحقق من حالة التصحيح. حاول مرة أخرى.';
const _proofError =
    'تم اعتماد طلب التصحيح، لكن تعذر التحقق من أحدث بيانات الجلسة.';
const _loadError = 'تم اعتماد طلب التصحيح، لكن تعذر تحميل أحدث بيانات الجلسة.';
const _financialPending = 'تم اعتماد التصحيح، والأثر المالي قيد المعالجة.';
const _financialReview = 'تم اعتماد التصحيح، لكن المبلغ يحتاج إلى مراجعة.';
const _applied = 'تم اعتماد التصحيح.';
const _newer = 'تم اعتماد هذا التصحيح، وتوجد تعديلات أحدث على السجل.';
final _openingStart = DateTime.utc(2026, 11, 8, 2, 30);
final _openingEnd = DateTime.utc(2026, 11, 8, 4, 45);
final _desiredStart = DateTime.utc(2026, 11, 8, 2, 40);
final _desiredEnd = DateTime.utc(2026, 11, 8, 4, 55);
final _latestStart = DateTime.utc(2026, 11, 8, 3, 10);
final _latestEnd = DateTime.utc(2026, 11, 8, 5, 25);

CommandEnvelope _command(CommandStatus status) => CommandEnvelope(
  localId: 'correction-local-1',
  commandId: 'correction-command-1',
  accountId: 'account-a',
  wellId: 'well-1',
  sequence: 1,
  type: CommandType.correctIrrigationSession,
  status: status,
  occurredAt: DateTime.utc(2026, 11, 9, 9),
  createdLocalAt: DateTime.utc(2026, 11, 9, 9),
  payload: {
    'p_session_id': _session,
    'p_base_revision': 3,
    'p_reason': _reason,
    'p_desired_started_at': _desiredStart.toIso8601String(),
    'p_desired_ended_at': _desiredEnd.toIso8601String(),
  },
);

SessionCorrectionCommandObservation _observation(CommandStatus status) {
  final command = _command(status);
  final request = SessionCorrectionReceiptRequest.fromCommand(command)!;
  SessionCorrectionReceiptResponse? accepted;
  if (status == CommandStatus.confirmed) {
    final parsed = parseSessionCorrectionReceipt(request, {
      'contract': 'get_session_correction_receipt',
      'version': 1,
      'session_id': _session,
      'command_id': command.commandId,
      'command_type': 'correct_irrigation_session',
      'retry_authorized': false,
      'status': 'accepted',
      'receipt': {
        'contract': 'session_correction',
        'version': 1,
        'status': 'accepted',
        'tenant_id': 'tenant-a',
        'well_id': 'well-1',
        'session_id': _session,
        'command_id': command.commandId,
        'correction_id': 'correction-server-1',
        'previous_revision': 3,
        'operational_revision': 4,
        'actual_started_at': _desiredStart.toIso8601String(),
        'actual_ended_at': _desiredEnd.toIso8601String(),
        'accepted_at': '2026-11-09T09:01:00.000Z',
        'financial_status': 'pending',
      },
    });
    expect(parsed, isA<SessionCorrectionReceiptResponse>());
    accepted = parsed as SessionCorrectionReceiptResponse;
    expect(accepted.state, SessionCorrectionReceiptState.accepted);
    expect(accepted.receipt, isNotNull);
  }
  return SessionCorrectionCommandObservation(
    command: command,
    request: request,
    accepted: accepted,
  );
}

class _Coordinator extends OfflineSessionCoordinator {
  _Coordinator(InMemoryOutboxStore store) : super(store: store);
  @override
  Future<void> initialize() async {} // No operational ticker in a UI double.
  final completions = StreamController<ActiveSessionRecord>.broadcast();
  @override
  Stream<ActiveSessionRecord> watchCompletionResult({required String accountId,
    required String wellId, required String serverSessionId}) => completions.stream;
  final submits = <Map<String, Object>>[];
  final reads = <Map<String, String>>[];
  Future<SessionCorrectionCommandObservation?> Function()? readResult;

  @override
  Future<CommandEnvelope> submitSessionCorrection({
    required String accountId,
    required String wellId,
    required String sessionId,
    required int baseRevision,
    required String reason,
    required DateTime desiredStartedAt,
    required DateTime desiredEndedAt,
  }) async {
    submits.add({
      'accountId': accountId,
      'wellId': wellId,
      'sessionId': sessionId,
      'baseRevision': baseRevision,
      'reason': reason,
      'desiredStartedAt': desiredStartedAt.toUtc(),
      'desiredEndedAt': desiredEndedAt.toUtc(),
    });
    return _command(CommandStatus.pending);
  }

  @override
  Future<SessionCorrectionCommandObservation?> readSessionCorrectionCommand({
    required String accountId,
    required String wellId,
    required String sessionId,
    required String localId,
    required String commandId,
  }) {
    reads.add({
      'accountId': accountId,
      'wellId': wellId,
      'sessionId': sessionId,
      'localId': localId,
      'commandId': commandId,
    });
    return readResult!();
  }
}

SessionDetailData _detail({
  int revision = 3,
  DateTime? start,
  DateTime? end,
  String financial = 'applied',
  int amount = 1234,
  int appliedRevision = 3,
}) => SessionDetailData(
  canCorrectSession: true,
  canReadSessionCorrections: true,
  session: SessionHistoryItem(
    id: _session,
    wellId: 'well-1',
    farmerName: 'مزارع',
    farmerCode: 'F1',
    farmerAccountId: 'farmer-1',
    farmName: 'أرض',
    pumpName: 'مضخة',
    operatorName: 'مشغل',
    startedAt: start ?? _openingStart,
    endedAt: end ?? _openingEnd,
    originalStartedAt: DateTime.utc(2026, 11, 8, 1),
    originalEndedAt: DateTime.utc(2026, 11, 8, 6),
    effectiveStartedAt: start ?? _openingStart,
    effectiveEndedAt: end ?? _openingEnd,
    operationalRevision: revision,
    financialStatus: financial,
    financialAppliedRevision: appliedRevision,
    hasCharge: true,
    hasInvoice: true,
    totalAmountYER: amount,
    paidAmountYER: 0,
    paymentStatus: 'unpaid',
    actualSeconds: 8100,
    billableSeconds: 8100,
  ),
  segments: const [],
);

Map<String, Object?> _historyItem({
  String id = 'correction-server-1',
  int previous = 3,
  int next = 4,
  DateTime? start,
  DateTime? end,
  String financial = 'pending',
}) => {
  'correction_id': id,
  'session_id': _session,
  'previous_revision': previous,
  'new_revision': next,
  'operational_revision': next,
  'before_started_at': _openingStart.toIso8601String(),
  'before_ended_at': _openingEnd.toIso8601String(),
  'after_started_at': (start ?? _desiredStart).toIso8601String(),
  'after_ended_at': (end ?? _desiredEnd).toIso8601String(),
  'reason': _reason,
  'requested_at': '2026-11-09T09:00:00.000Z',
  'accepted_at': '2026-11-09T09:01:00.000Z',
  'financial_status': financial,
  'financial_review_required': financial == 'financial_review_required',
  'financial_review_reason': financial == 'financial_review_required'
      ? 'مراجعة المبلغ'
      : null,
};
SessionCorrectionHistory _history(List<Map<String, Object?>> items) =>
    SessionCorrectionHistory.fromContract({
      'contract': 'get_session_corrections',
      'version': 1,
      'session_id': _session,
      'items': items,
    }, sessionId: _session);
SessionCorrectionStatus _status({
  String id = 'correction-server-1',
  int revision = 4,
  String financial = 'pending',
}) => SessionCorrectionStatus.fromContract({
  'contract': 'get_session_correction_status',
  'version': 1,
  'session_id': _session,
  'correction_id': id,
  'operational_revision': revision,
  'status': financial,
  'financial_status': financial,
  'financial_review_required': financial == 'financial_review_required',
  'financial_review_reason': financial == 'financial_review_required'
      ? 'مراجعة المبلغ'
      : null,
}, sessionId: _session);

class _Repository extends OperationsRepository {
  int detailReads = 0, historyReads = 0, statusReads = 0;
  String? fail;
  SessionDetailData detail = _detail();
  SessionCorrectionHistory history = _history([_historyItem()]);
  SessionCorrectionStatus correctionStatus = _status();
  @override
  Future<SessionDetailData> fetchSessionDetail(String id) async {
    expect(id, _session);
    detailReads++;
    if (fail == 'detail' && detailReads > 1) {
      throw StateError('detail_unavailable');
    }
    return detail;
  }

  @override
  Future<SessionCorrectionHistory> fetchSessionCorrections(String id) async {
    expect(id, _session);
    historyReads++;
    if (fail == 'history') throw StateError('history_unavailable');
    return history;
  }

  @override
  Future<SessionCorrectionStatus> fetchSessionCorrectionStatus(
    String id,
  ) async {
    expect(id, _session);
    statusReads++;
    if (fail == 'status') throw StateError('status_unavailable');
    return correctionStatus;
  }
}

String _clockText(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}

void main() {
  late InMemoryOutboxStore store;
  late _Coordinator coordinator;
  late _Repository repository;
  setUp(() {
    store = InMemoryOutboxStore();
    coordinator = _Coordinator(store);
    repository = _Repository();
  });
  tearDown(() async {
    await coordinator.completions.close();
    coordinator.dispose();
    await store.close();
  });

  void formOpen() => expect(find.byKey(_reasonKey), findsOneWidget);
  void noCurrentSuccess() {
    for (final text in [_applied, _financialPending, _financialReview]) {
      expect(find.text(text), findsNothing);
    }
  }

  void submitLocked(WidgetTester tester) => expect(
    tester.widget<ButtonStyleButton>(find.byKey(_submitKey)).onPressed,
    isNull,
  );
  void readIdentity() {
    expect(coordinator.reads, isNotEmpty);
    for (final call in coordinator.reads) {
      expect(call, {
        'accountId': 'account-a',
        'wellId': 'well-1',
        'sessionId': _session,
        'localId': 'correction-local-1',
        'commandId': 'correction-command-1',
      });
    }
    expect(coordinator.submits, hasLength(1));
  }

  void noCanonicalReads() {
    expect(repository.detailReads, 1); // Only the opening read.
    expect(repository.historyReads, 0);
    expect(repository.statusReads, 0);
  }

  ButtonStyleButton refreshButton(WidgetTester tester) {
    expect(
      find.byKey(_refreshKey),
      findsOneWidget,
      reason: 'Expected explicit refresh control: تحديث حالة التصحيح',
    );
    expect(
      find.descendant(
        of: find.byKey(_refreshKey),
        matching: find.text('تحديث حالة التصحيح'),
      ),
      findsOneWidget,
    );
    return tester.widget<ButtonStyleButton>(find.byKey(_refreshKey));
  }

  Future<void> refresh(WidgetTester tester) async {
    expect(refreshButton(tester).onPressed, isNotNull);
    await tester.ensureVisible(find.byKey(_refreshKey));
    await tester.tap(find.byKey(_refreshKey));
    await tester.pump();
  }

  Future<void> selectTime(
    WidgetTester tester,
    Key key,
    DateTime desired,
  ) async {
    final local = desired.toLocal();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'OK').last);
    await tester.pumpAndSettle();
    final keyboard = find.byIcon(Icons.keyboard_outlined);
    if (keyboard.evaluate().isNotEmpty) {
      await tester.tap(keyboard);
      await tester.pumpAndSettle();
    }
    final fields = find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.byType(TextField),
    );
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '${local.hour}'.padLeft(2, '0'));
    await tester.enterText(fields.at(1), '${local.minute}'.padLeft(2, '0'));
    await tester.tap(find.widgetWithText(TextButton, 'OK').last);
    await tester.pumpAndSettle();
  }

  Future<void> openAndSubmit(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
        home: SessionDetailScreen(
          sessionId: _session,
          wellName: 'بئر',
          accountId: 'account-a',
          wellId: 'well-1',
          coordinator: coordinator,
          repository: repository,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('تصحيح السجل'));
    await tester.tap(find.text('تصحيح السجل'));
    await tester.pumpAndSettle();
    formOpen();
    await selectTime(tester, _startKey, _desiredStart);
    await selectTime(tester, _endKey, _desiredEnd);
    await tester.enterText(find.byKey(_reasonKey), _reason);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(_submitKey));
    await tester.tap(find.byKey(_submitKey));
    await tester.pumpAndSettle();
    expect(coordinator.submits.single, {
      'accountId': 'account-a',
      'wellId': 'well-1',
      'sessionId': _session,
      'baseRevision': 3,
      'reason': _reason,
      'desiredStartedAt': _desiredStart,
      'desiredEndedAt': _desiredEnd,
    });
    expect(find.text(_pending), findsOneWidget);
    submitLocked(tester);
    noCanonicalReads();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  void currentCanonical({String financial = 'pending', int amount = 1234}) {
    repository.detail = _detail(
      revision: 4,
      start: _desiredStart,
      end: _desiredEnd,
      financial: financial,
      amount: amount,
      appliedRevision: financial == 'applied' ? 4 : 3,
    );
    repository.history = _history([_historyItem(financial: financial)]);
    repository.correctionStatus = _status(financial: financial);
    coordinator.readResult = () async => _observation(CommandStatus.confirmed);
  }

  void parentVisible() {
    expect(find.byKey(_reasonKey), findsNothing);
    expect(find.byType(SessionDetailScreen), findsOneWidget);
    readIdentity();
    expect(repository.detailReads, greaterThan(1));
    expect(repository.historyReads, greaterThan(0));
    expect(repository.statusReads, greaterThan(0));
  }

  void currentTimes(DateTime start, DateTime end) {
    expect(find.textContaining(_clockText(start)), findsWidgets);
    expect(find.textContaining(_clockText(end)), findsWidgets);
  }

  for (final status in [CommandStatus.pending, CommandStatus.dispatching]) {
    testWidgets(
      '$status refresh reads same identity only and never resubmits',
      (tester) async {
        await openAndSubmit(tester);
        coordinator.readResult = () async => _observation(status);
        await refresh(tester);
        await tester.pumpAndSettle();
        formOpen();
        submitLocked(tester);
        noCurrentSuccess();
        noCanonicalReads();
        readIdentity();
        expect(find.text(_pending), findsOneWidget);
        expect(refreshButton(tester).onPressed, isNotNull);
        await refresh(tester);
        await tester.pumpAndSettle();
        expect(coordinator.reads, hasLength(2));
        readIdentity();
        noCanonicalReads();
      },
    );
  }
  testWidgets('review observation stays on form without canonical reads', (
    tester,
  ) async {
    await openAndSubmit(tester);
    coordinator.readResult = () async => _observation(CommandStatus.review);
    await refresh(tester);
    await tester.pumpAndSettle();
    formOpen();
    submitLocked(tester);
    noCanonicalReads();
    noCurrentSuccess();
    readIdentity();
    expect(find.text(_review), findsOneWidget);
  });
  testWidgets(
    'refresh in-flight disables double tap until one-shot read completes',
    (tester) async {
      await openAndSubmit(tester);
      final gate = Completer<SessionCorrectionCommandObservation?>();
      coordinator.readResult = () => gate.future;
      await refresh(tester);
      expect(coordinator.reads, hasLength(1));
      expect(refreshButton(tester).onPressed, isNull);
      await tester.tap(find.byKey(_refreshKey));
      await tester.pump();
      expect(coordinator.reads, hasLength(1));
      gate.complete(_observation(CommandStatus.pending));
      await tester.pumpAndSettle();
      expect(refreshButton(tester).onPressed, isNotNull);
      formOpen();
      submitLocked(tester);
      readIdentity();
      noCanonicalReads();
    },
  );
  for (final failure in ['exception', 'null']) {
    testWidgets(
      'observation $failure keeps form locked and refresh retryable',
      (tester) async {
        await openAndSubmit(tester);
        coordinator.readResult = () async {
          if (failure == 'exception') {
            throw StateError('observation_unavailable');
          }
          return null;
        };
        await refresh(tester);
        await tester.pumpAndSettle();
        expect(find.text(_observeError), findsOneWidget);
        formOpen();
        submitLocked(tester);
        noCanonicalReads();
        noCurrentSuccess();
        expect(refreshButton(tester).onPressed, isNotNull);
        coordinator.readResult = () async =>
            _observation(CommandStatus.pending);
        await refresh(tester);
        await tester.pumpAndSettle();
        expect(coordinator.reads, hasLength(2));
        readIdentity();
      },
    );
  }
  for (final financial in ['pending', 'financial_review_required', 'applied']) {
    testWidgets(
      'current command-bound canonical proof displays $financial server truth',
      (tester) async {
        await openAndSubmit(tester);
        currentCanonical(
          financial: financial,
          amount: financial == 'applied' ? 8765 : 1234,
        );
        await refresh(tester);
        await tester.pumpAndSettle();
        parentVisible();
        currentTimes(_desiredStart, _desiredEnd);
        expect(find.textContaining(_clockText(_openingStart)), findsNothing);
        expect(find.textContaining(_clockText(_openingEnd)), findsNothing);
        expect(
          find.text(switch (financial) {
            'pending' => _financialPending,
            'financial_review_required' => _financialReview,
            _ => _applied,
          }),
          findsOneWidget,
        );
        // مبلغ خادمي مستقل عن المدة؛ لا تسعير ولا مقاطع محلية في fixture.
        expect(
          find.textContaining(financial == 'applied' ? '8,765' : '1,234'),
          findsWidgets,
        );
      },
    );
  }
  for (final mismatch in [
    'history id',
    'history revision',
    'history start',
    'history end',
    'detail revision',
    'detail start',
    'detail end',
    'status id',
    'status revision',
  ]) {
    testWidgets(
      'canonical $mismatch mismatch cannot overwrite previous detail',
      (tester) async {
        await openAndSubmit(tester);
        currentCanonical();
        if (mismatch.startsWith('history')) {
          repository.history = _history([
            _historyItem(
              id: mismatch == 'history id'
                  ? 'another-correction'
                  : 'correction-server-1',
              previous: mismatch == 'history revision' ? 2 : 3,
              next: mismatch == 'history revision' ? 3 : 4,
              start: mismatch == 'history start' ? _latestStart : null,
              end: mismatch == 'history end' ? _latestEnd : null,
            ),
          ]);
        } else if (mismatch.startsWith('detail')) {
          repository.detail = _detail(
            revision: mismatch == 'detail revision' ? 3 : 4,
            start: mismatch == 'detail start' ? _latestStart : _desiredStart,
            end: mismatch == 'detail end' ? _latestEnd : _desiredEnd,
            financial: 'pending',
          );
        } else {
          repository.correctionStatus = _status(
            id: mismatch == 'status id'
                ? 'another-correction'
                : 'correction-server-1',
            revision: mismatch == 'status revision' ? 5 : 4,
          );
        }
        await refresh(tester);
        await tester.pumpAndSettle();
        expect(find.byKey(_reasonKey), findsNothing);
        currentTimes(_openingStart, _openingEnd);
        expect(find.text(_proofError), findsOneWidget);
        noCurrentSuccess();
        readIdentity();
        expect(find.textContaining('1,234'), findsWidgets);
      },
    );
  }
  for (final failingRead in ['detail', 'history', 'status']) {
    testWidgets(
      'canonical $failingRead failure preserves old detail without synthetic facts',
      (tester) async {
        await openAndSubmit(tester);
        currentCanonical();
        repository.fail = failingRead;
        await refresh(tester);
        await tester.pumpAndSettle();
        expect(find.byKey(_reasonKey), findsNothing);
        currentTimes(_openingStart, _openingEnd);
        expect(find.textContaining(_clockText(_desiredStart)), findsNothing);
        expect(find.textContaining(_clockText(_desiredEnd)), findsNothing);
        expect(find.text(_loadError), findsOneWidget);
        noCurrentSuccess();
        readIdentity();
      },
    );
  }
  testWidgets(
    'newer canonical correction is displayed without attributing it to our command',
    (tester) async {
      await openAndSubmit(tester);
      currentCanonical();
      repository.detail = _detail(
        revision: 5,
        start: _latestStart,
        end: _latestEnd,
        financial: 'applied',
        appliedRevision: 5,
        amount: 9753,
      );
      repository.history = _history([
        _historyItem(financial: 'financial_review_required'),
        _historyItem(
          id: 'newer-correction-2',
          previous: 4,
          next: 5,
          start: _latestStart,
          end: _latestEnd,
          financial: 'applied',
        ),
      ]);
      repository.correctionStatus = _status(
        id: 'newer-correction-2',
        revision: 5,
        financial: 'applied',
      );
      await refresh(tester);
      await tester.pumpAndSettle();
      parentVisible();
      currentTimes(_latestStart, _latestEnd);
      expect(find.textContaining(_clockText(_desiredStart)), findsNothing);
      expect(find.textContaining(_clockText(_desiredEnd)), findsNothing);
      expect(find.text(_newer), findsOneWidget);
      expect(
        find.text('الأثر المالي لهذا التصحيح يحتاج إلى مراجعة.'),
        findsOneWidget,
      );
      expect(find.text(_applied), findsNothing);
      expect(find.textContaining('9,753'), findsWidgets);
    },
  );
  for (final change in ['financial', 'revision', 'historical', 'same']) {
    testWidgets('independent finance refresh $change respects outcome snapshot', (tester) async {
      await openAndSubmit(tester);
      currentCanonical();
      if (change == 'historical') {
        repository.detail = _detail(revision: 5, start: _latestStart,
          end: _latestEnd, financial: 'applied', appliedRevision: 5);
        repository.history = _history([_historyItem(financial: 'financial_review_required')]);
      }
      await refresh(tester);
      await tester.pumpAndSettle();
      parentVisible();
      expect(find.text(change == 'historical' ? _newer : _financialPending), findsOneWidget);
      if (change == 'historical') {
        expect(find.text('الأثر المالي لهذا التصحيح يحتاج إلى مراجعة.'), findsOneWidget);
      }
      final before = repository.detailReads;
      repository.detail = change == 'same'
          ? _detail(revision: 4, start: _desiredStart, end: _desiredEnd, financial: 'pending')
          : _detail(revision: change == 'financial' ? 4 : 5,
              start: change == 'financial' ? _desiredStart : _latestStart,
              end: change == 'financial' ? _desiredEnd : _latestEnd,
              financial: 'applied', appliedRevision: change == 'financial' ? 4 : 5,
              amount: 8765);
      coordinator.completions.add(ActiveSessionRecord(
        localId: 'completed-local', accountId: 'account-a', wellId: 'well-1',
        serverSessionId: _session, startedAt: _openingStart,
        businessState: SessionBusinessState.completed,
        syncState: SessionSyncState.synced, segments: const [], payments: const [],
        timeIntegrityFlags: const {}, pendingCommandCount: 0,
        totals: const SessionTotals(billableSeconds: 8100, wallClockSeconds: 8100,
          totalPausedSeconds: 0, currentPauseSeconds: 0, accruedMinor: null,
          pricingPending: false),
      ));
      await tester.pumpAndSettle();
      expect(repository.detailReads, before + 1);
      expect(repository.historyReads, 1);
      expect(repository.statusReads, 1);
      expect(coordinator.submits, hasLength(1));
      if (change == 'same') {
        expect(find.text(_financialPending), findsOneWidget);
      } else {
        expect(find.textContaining('8,765'), findsWidgets);
        expect(find.text(_financialPending), findsNothing);
        expect(find.text(_newer), findsNothing);
        expect(find.text('الأثر المالي لهذا التصحيح يحتاج إلى مراجعة.'), findsNothing);
        expect(find.text(_applied), findsNothing);
        currentTimes(change == 'financial' ? _desiredStart : _latestStart,
          change == 'financial' ? _desiredEnd : _latestEnd);
      }
    });
  }

}

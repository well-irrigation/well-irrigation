import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/session/session_segment.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/session_correction_receipt.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/features/history/session_detail_screen.dart';

const _sessionId = 'server-session-1';
const _toggleKey = ValueKey('session_correction_history_toggle');
final _start = DateTime.utc(2026, 11, 8, 2, 30);
final _end = DateTime.utc(2026, 11, 8, 4, 45);
final _afterStart = DateTime.utc(2026, 11, 8, 2, 40);
final _afterEnd = DateTime.utc(2026, 11, 8, 4, 55);
final _acceptedAt = DateTime.utc(2026, 11, 9, 9, 1);

Map<String, Object?> _item({
  required String id,
  required int previous,
  required int next,
  required DateTime beforeStart,
  required DateTime beforeEnd,
  required DateTime afterStart,
  required DateTime afterEnd,
  required String reason,
  String financial = 'pending',
}) => {
  'correction_id': id,
  'session_id': _sessionId,
  'previous_revision': previous,
  'new_revision': next,
  'operational_revision': next,
  'before_started_at': beforeStart.toIso8601String(),
  'before_ended_at': beforeEnd.toIso8601String(),
  'after_started_at': afterStart.toIso8601String(),
  'after_ended_at': afterEnd.toIso8601String(),
  'reason': reason,
  'requested_at': '2026-11-09T08:55:00.000Z',
  'accepted_at': '2026-11-09T09:01:00.000Z',
  'financial_status': financial,
  'financial_review_required': financial == 'financial_review_required',
  'financial_review_reason': financial == 'financial_review_required'
      ? 'يحتاج الأثر المالي إلى مراجعة'
      : null,
};

final _firstItem = _item(
  id: 'correction-1',
  previous: 3,
  next: 4,
  beforeStart: _start,
  beforeEnd: _end,
  afterStart: _afterStart,
  afterEnd: _afterEnd,
  reason: 'تعديل وقت التشغيل الفعلي',
);
final _secondItem = _item(
  id: 'correction-2',
  previous: 4,
  next: 5,
  beforeStart: _afterStart,
  beforeEnd: _afterEnd,
  afterStart: DateTime.utc(2026, 11, 8, 3, 10),
  afterEnd: DateTime.utc(2026, 11, 8, 5, 25),
  reason: 'تصحيح نهاية التشغيل',
  financial: 'applied',
);

SessionCorrectionHistory _history(List<Map<String, Object?>> items) =>
    SessionCorrectionHistory.fromContract({
      'contract': 'get_session_corrections',
      'version': 1,
      'session_id': _sessionId,
      'items': items,
    }, sessionId: _sessionId);

SessionDetailData _detail({
  String sessionId = _sessionId,
  bool canRead = true,
  int revision = 5,
  DateTime? startedAt,
  DateTime? endedAt,
}) {
  final start = startedAt ?? _start;
  final end = endedAt ?? _end;
  return SessionDetailData(
  canReadSessionCorrections: canRead,
  canCorrectSession: true,
  session: SessionHistoryItem(
    id: sessionId,
    wellId: 'well-1',
    farmerName: 'مزارع',
    farmerCode: 'F1',
    farmerAccountId: 'farmer-1',
    farmName: 'أرض',
    pumpName: 'مضخة',
    operatorName: 'مشغل',
    startedAt: start,
    endedAt: end,
    originalStartedAt: DateTime.utc(2026, 11, 8, 1),
    originalEndedAt: DateTime.utc(2026, 11, 8, 6),
    effectiveStartedAt: start,
    effectiveEndedAt: end,
    operationalRevision: revision,
    financialStatus: 'pending',
    financialAppliedRevision: 0,
  ),
  segments: const [],
  );
}

class _Repository extends OperationsRepository {
  int detailReads = 0;
  int historyReads = 0;
  final detailIds = <String>[];
  final historyIds = <String>[];
  SessionDetailData detail = _detail();
  List<Map<String, Object?>> historyItems = [_firstItem, _secondItem];
  Completer<SessionCorrectionHistory>? historyGate;
  bool failHistory = false;
  final historyResponses = <List<Map<String, Object?>>>[];

  @override
  Future<SessionDetailData> fetchSessionDetail(String sessionId) async {
    detailReads++;
    detailIds.add(sessionId);
    return detail;
  }

  @override
  Future<SessionCorrectionHistory> fetchSessionCorrections(
    String sessionId,
  ) {
    historyReads++;
    historyIds.add(sessionId);
    if (failHistory) throw StateError('history_unavailable');
    final gate = historyGate;
    if (gate != null) return gate.future;
    if (historyResponses.isNotEmpty) {
      return Future.value(_history(historyResponses.removeAt(0)));
    }
    return Future.value(_history(historyItems));
  }

  @override
  Future<SessionCorrectionStatus> fetchSessionCorrectionStatus(
    String sessionId,
  ) async => SessionCorrectionStatus.fromContract({
    'contract': 'get_session_correction_status',
    'version': 1,
    'session_id': sessionId,
    'correction_id': 'correction-new',
    'operational_revision': 6,
    'status': 'pending',
    'financial_status': 'pending',
    'financial_review_required': false,
    'financial_review_reason': null,
  }, sessionId: sessionId);
}

class _Coordinator extends OfflineSessionCoordinator {
  _Coordinator(InMemoryOutboxStore store) : super(store: store);

  final completions = StreamController<ActiveSessionRecord>.broadcast();
  CommandEnvelope? _command;
  bool confirmOnRead = false;

  @override
  Future<void> initialize() async {}

  @override
  Stream<ActiveSessionRecord> watchCompletionResult({
    required String accountId,
    required String wellId,
    required String serverSessionId,
  }) => completions.stream;

  @override
  Future<CompletedSessionPaymentState?> restoreCompletedSession({
    required String accountId,
    required String wellId,
    required String serverSessionId,
  }) async => null;

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
    _command = CommandEnvelope(
      localId: 'correction-local',
      commandId: 'correction-command',
      type: CommandType.correctIrrigationSession,
      accountId: accountId,
      wellId: wellId,
      sequence: 1,
      occurredAt: DateTime.utc(2026, 11, 9, 9),
      createdLocalAt: DateTime.utc(2026, 11, 9, 9),
      payload: {
        'p_session_id': sessionId,
        'p_base_revision': baseRevision,
        'p_reason': reason,
        'p_desired_started_at': desiredStartedAt.toUtc().toIso8601String(),
        'p_desired_ended_at': desiredEndedAt.toUtc().toIso8601String(),
      },
    );
    return _command!;
  }

  @override
  Future<SessionCorrectionCommandObservation?> readSessionCorrectionCommand({
    required String accountId,
    required String wellId,
    required String sessionId,
    required String localId,
    required String commandId,
  }) async {
    final command = _command!;
    final request = SessionCorrectionReceiptRequest.fromCommand(command)!;
    final status = confirmOnRead ? CommandStatus.confirmed : CommandStatus.pending;
    final currentCommand = CommandEnvelope(
      localId: command.localId,
      commandId: command.commandId,
      type: command.type,
      accountId: command.accountId,
      wellId: command.wellId,
      sequence: command.sequence,
      occurredAt: command.occurredAt,
      createdLocalAt: command.createdLocalAt,
      payload: command.payload,
      status: status,
    );
    SessionCorrectionReceiptResponse? accepted;
    if (confirmOnRead) {
      accepted = parseSessionCorrectionReceipt(request, {
        'contract': 'get_session_correction_receipt',
        'version': 1,
        'session_id': sessionId,
        'command_id': commandId,
        'command_type': 'correct_irrigation_session',
        'retry_authorized': false,
        'status': 'accepted',
        'receipt': {
          'contract': 'session_correction',
          'version': 1,
          'status': 'accepted',
          'tenant_id': 'tenant-internal',
          'well_id': wellId,
          'session_id': sessionId,
          'command_id': commandId,
          'correction_id': 'correction-new',
          'previous_revision': request.baseRevision,
          'operational_revision': request.baseRevision + 1,
          'actual_started_at': request.desiredStartedAt.toIso8601String(),
          'actual_ended_at': request.desiredEndedAt.toIso8601String(),
          'accepted_at': '2026-11-09T09:01:00.000Z',
          'financial_status': 'pending',
        },
      }) as SessionCorrectionReceiptResponse;
    }
    return SessionCorrectionCommandObservation(
      command: currentCommand,
      request: request,
      accepted: accepted,
    );
  }
}

String _time(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour > 12 ? local.hour - 12 : (local.hour == 0 ? 12 : local.hour);
  return '$hour:${local.minute.toString().padLeft(2, '0')}:00';
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

  Future<void> openDetails(
    WidgetTester tester, {
    bool accountScope = false,
    String sessionId = _sessionId,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: SessionDetailScreen(
        sessionId: sessionId,
        wellName: 'بئر',
        accountId: accountScope ? 'account-a' : null,
        wellId: accountScope ? 'well-1' : null,
        coordinator: coordinator,
        repository: repository,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> toggleHistory(WidgetTester tester) async {
    final button = find.byKey(_toggleKey);
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
  }

  Future<void> changeTime(
    WidgetTester tester,
    Key key,
    DateTime desired,
  ) async {
    await tester.ensureVisible(find.byKey(key));
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
    final local = desired.toLocal();
    await tester.enterText(fields.at(0), local.hour.toString().padLeft(2, '0'));
    await tester.enterText(fields.at(1), local.minute.toString().padLeft(2, '0'));
    await tester.tap(find.widgetWithText(TextButton, 'OK').last);
    await tester.pumpAndSettle();
  }

  Future<void> submitCorrection(WidgetTester tester) async {
    await tester.tap(find.text('تصحيح السجل'));
    await tester.pumpAndSettle();
    await changeTime(tester, const Key('session_correction_start'), _afterStart);
    await changeTime(tester, const Key('session_correction_end'), _afterEnd);
    await tester.enterText(find.byKey(const Key('session_correction_reason')), 'تصحيح جديد');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('session_correction_submit')));
    await tester.tap(find.byKey(const Key('session_correction_submit')));
    await tester.pumpAndSettle();
    coordinator.confirmOnRead = true;
    repository.detail = _detail(
      revision: 6,
      startedAt: _afterStart,
      endedAt: _afterEnd,
    );
    final refreshedHistory = [_firstItem, _secondItem, _item(
      id: 'correction-new', previous: 5, next: 6,
      beforeStart: _start, beforeEnd: _end,
      afterStart: _afterStart, afterEnd: _afterEnd,
      reason: 'تصحيح جديد',
    )];
    repository.historyResponses.add(refreshedHistory);
    repository.historyItems = refreshedHistory;
  }

  testWidgets('permission shows control without fetching history on detail open', (tester) async {
    await openDetails(tester);
    expect(find.text('سجل التصحيحات'), findsOneWidget);
    expect(find.byKey(_toggleKey), findsOneWidget);
    expect(find.text('عرض سجل التصحيحات'), findsOneWidget);
    expect(repository.detailReads, 1);
    expect(repository.historyReads, 0);
  });

  testWidgets('detail header never renders a technical session id prefix', (tester) async {
    const sensitiveSessionId = 'server-session-sensitive-123456';
    repository.detail = _detail(sessionId: sensitiveSessionId);
    await openDetails(tester, sessionId: sensitiveSessionId);

    expect(find.text('تفاصيل جلسة'), findsOneWidget);
    expect(find.text(sensitiveSessionId), findsNothing);
    expect(find.text('#server'), findsNothing);
  });

  testWidgets('verified correction outcome never renders operational revision', (tester) async {
    await openDetails(tester, accountScope: true);
    await submitCorrection(tester);
    await tester.tap(find.byKey(const Key('session_correction_refresh')));
    await tester.pumpAndSettle();

    expect(
      find.text('تم اعتماد التصحيح، والأثر المالي قيد المعالجة.'),
      findsOneWidget,
    );
    expect(find.textContaining('مراجعة التشغيل'), findsNothing);
    expect(find.text('مراجعة التشغيل: 6'), findsNothing);
    expect(find.textContaining('operationalRevision'), findsNothing);
  });

  testWidgets('without read capability hides history and does not fetch', (tester) async {
    repository.detail = _detail(canRead: false);
    await openDetails(tester);
    expect(find.text('سجل التصحيحات'), findsNothing);
    expect(find.byKey(_toggleKey), findsNothing);
    expect(repository.historyReads, 0);
  });

  testWidgets('first expand reads exactly once and exposes a loading state', (tester) async {
    await openDetails(tester);
    repository.historyGate = Completer<SessionCorrectionHistory>();
    await toggleHistory(tester);
    expect(repository.historyReads, 1);
    expect(repository.historyIds, [_sessionId]);
    expect(find.text('جارٍ تحميل سجل التصحيحات...'), findsOneWidget);
    expect(find.text('لا توجد تصحيحات مسجلة لهذه الجلسة.'), findsNothing);
    await tester.tap(find.byKey(_toggleKey));
    await tester.pump();
    expect(repository.historyReads, 1);
    repository.historyGate!.complete(_history([]));
    await tester.pumpAndSettle();
    expect(find.text('لا توجد تصحيحات مسجلة لهذه الجلسة.'), findsOneWidget);
  });

  testWidgets('revoked capability discards a pending history read', (tester) async {
    await openDetails(tester, accountScope: true);
    repository.historyGate = Completer<SessionCorrectionHistory>();
    await toggleHistory(tester);
    expect(repository.historyReads, 1);

    repository.detail = _detail(canRead: false);
    coordinator.completions.add(_completionRecord());
    await tester.pumpAndSettle();

    expect(repository.detailReads, 2);
    expect(find.text('سجل التصحيحات'), findsNothing);
    expect(find.byKey(_toggleKey), findsNothing);

    repository.historyGate!.complete(
      _history([
        _item(
          id: 'revoked-correction',
          previous: 5,
          next: 6,
          beforeStart: _start,
          beforeEnd: _end,
          afterStart: _afterStart,
          afterEnd: _afterEnd,
          reason: 'سجل من صلاحية مسحوبة',
        ),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('سجل من صلاحية مسحوبة'), findsNothing);
    expect(find.text('غير مصرح'), findsNothing);
    expect(find.text('مزارع'), findsOneWidget);
    expect(repository.historyReads, 1);
  });

  testWidgets('empty history is a normal empty state', (tester) async {
    await openDetails(tester);
    repository.historyItems = [];
    await toggleHistory(tester);
    await tester.pumpAndSettle();
    expect(find.text('لا توجد تصحيحات مسجلة لهذه الجلسة.'), findsOneWidget);
    expect(repository.historyIds, [_sessionId]);
  });

  testWidgets('one correction shows user facts without internal identifiers', (tester) async {
    await openDetails(tester);
    repository.historyItems = [_firstItem];
    await toggleHistory(tester);
    await tester.pumpAndSettle();
    expect(find.text('قبل التصحيح'), findsOneWidget);
    expect(find.text('بعد التصحيح'), findsOneWidget);
    for (final time in [_start, _end, _afterStart, _afterEnd]) {
      expect(find.textContaining(_time(time)), findsWidgets);
    }
    expect(find.text('سبب التصحيح'), findsOneWidget);
    expect(find.text('تعديل وقت التشغيل الفعلي'), findsOneWidget);
    expect(find.textContaining('تم الاعتماد'), findsOneWidget);
    expect(find.textContaining(_time(_acceptedAt)), findsWidgets);
    expect(find.textContaining('الأثر المالي قيد المعالجة'), findsOneWidget);
    for (final internal in ['correction-1', 'correction-command', 'tenant-internal', '3 → 4', 'Revision']) {
      expect(find.textContaining(internal), findsNothing);
    }
    for (final stamp in [_start, _end, _afterStart, _afterEnd]) {
      expect(find.textContaining(stamp.toIso8601String()), findsNothing);
    }
  });

  testWidgets('financial applied and review are presented from history state', (tester) async {
    await openDetails(tester);
    repository.historyItems = [
      _item(id: 'applied-id', previous: 4, next: 5,
        beforeStart: _afterStart, beforeEnd: _afterEnd,
        afterStart: DateTime.utc(2026, 11, 8, 3, 10),
        afterEnd: DateTime.utc(2026, 11, 8, 5, 25),
        reason: 'تطبيق نهائي', financial: 'applied'),
      _item(id: 'review-id', previous: 2, next: 3,
        beforeStart: DateTime.utc(2026, 11, 8, 2), beforeEnd: _end,
        afterStart: _start, afterEnd: _afterEnd,
        reason: 'يتطلب تحققًا', financial: 'financial_review_required'),
    ];
    await toggleHistory(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('تم تطبيق الأثر المالي'), findsOneWidget);
    expect(find.textContaining('الأثر المالي يحتاج إلى مراجعة'), findsOneWidget);
    expect(find.text('يحتاج الأثر المالي إلى مراجعة'), findsOneWidget);
    expect(find.textContaining('Revision'), findsNothing);
  });

  testWidgets('two corrections retain the server oldest-first contract and their own facts', (tester) async {
    await openDetails(tester);
    repository.historyItems = [_firstItem, _secondItem];
    await toggleHistory(tester);
    await tester.pumpAndSettle();
    expect(find.text('تعديل وقت التشغيل الفعلي'), findsOneWidget);
    expect(find.text('تصحيح نهاية التشغيل'), findsOneWidget);
    final first = tester.getCenter(find.text('تعديل وقت التشغيل الفعلي'));
    final second = tester.getCenter(find.text('تصحيح نهاية التشغيل'));
    expect(first.dy, lessThan(second.dy));
    expect(find.textContaining('الأثر المالي قيد المعالجة'), findsOneWidget);
    expect(find.textContaining('تم تطبيق الأثر المالي'), findsOneWidget);
  });

  testWidgets('collapse and re-expand reuses loaded history', (tester) async {
    await openDetails(tester);
    await toggleHistory(tester);
    await tester.pumpAndSettle();
    expect(repository.historyReads, 1);
    await toggleHistory(tester);
    await tester.pumpAndSettle();
    await toggleHistory(tester);
    await tester.pumpAndSettle();
    expect(repository.historyReads, 1);
  });

  testWidgets('history failure keeps detail and retry loads rows', (tester) async {
    await openDetails(tester);
    repository.failHistory = true;
    await toggleHistory(tester);
    await tester.pumpAndSettle();
    expect(find.text('تعذر تحميل سجل التصحيحات. حاول مرة أخرى.'), findsOneWidget);
    expect(find.text('تفاصيل جلسة'), findsOneWidget);
    expect(find.text('مزارع'), findsOneWidget);
    expect(find.byKey(_toggleKey), findsOneWidget);
    repository.failHistory = false;
    repository.historyItems = [_firstItem];
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(repository.historyReads, 2);
    expect(find.text('تعذر تحميل سجل التصحيحات. حاول مرة أخرى.'), findsNothing);
    expect(find.text('تعديل وقت التشغيل الفعلي'), findsOneWidget);
  });

  testWidgets('history cache is invalidated after verified correction', (tester) async {
    await openDetails(tester, accountScope: true);
    repository.historyItems = [_firstItem];
    await toggleHistory(tester);
    await tester.pumpAndSettle();
    expect(repository.historyReads, 1);
    await toggleHistory(tester);
    await tester.pumpAndSettle();
    await submitCorrection(tester);
    await tester.tap(find.byKey(const Key('session_correction_refresh')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('session_correction_reason')), findsNothing);
    expect(repository.historyReads, 2); // Parent canonical verification.
    expect(find.text('تصحيح جديد'), findsNothing); // Not appended from receipt.
    await toggleHistory(tester);
    await tester.pumpAndSettle();
    expect(repository.historyReads, 3);
    expect(find.text('تصحيح جديد'), findsOneWidget);
  });

  testWidgets('capability true to false hides cached history after detail event', (tester) async {
    await openDetails(tester, accountScope: true);
    await toggleHistory(tester);
    await tester.pumpAndSettle();
    expect(repository.historyReads, 1);
    repository.detail = _detail(canRead: false);
    coordinator.completions.add(_completionRecord());
    await tester.pumpAndSettle();
    expect(repository.detailReads, 2);
    expect(find.byKey(_toggleKey), findsNothing);
    expect(repository.historyReads, 1);
  });

  testWidgets('capability false to true shows control without auto-fetch', (tester) async {
    repository.detail = _detail(canRead: false);
    await openDetails(tester, accountScope: true);
    expect(find.byKey(_toggleKey), findsNothing);
    repository.detail = _detail(canRead: true);
    coordinator.completions.add(_completionRecord());
    await tester.pumpAndSettle();
    expect(find.byKey(_toggleKey), findsOneWidget);
    expect(repository.historyReads, 0);
  });
}

ActiveSessionRecord _completionRecord() => ActiveSessionRecord(
  localId: 'completed-local',
  accountId: 'account-a',
  wellId: 'well-1',
  serverSessionId: _sessionId,
  startedAt: _start,
  businessState: SessionBusinessState.completed,
  syncState: SessionSyncState.synced,
  segments: const [],
  payments: const [],
  timeIntegrityFlags: const {},
  pendingCommandCount: 0,
  totals: const SessionTotals(
    billableSeconds: 0,
    wallClockSeconds: 0,
    totalPausedSeconds: 0,
    currentPauseSeconds: 0,
    accruedMinor: null,
    pricingPending: false,
  ),
);

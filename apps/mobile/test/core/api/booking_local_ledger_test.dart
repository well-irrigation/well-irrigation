@TestOn('vm')
library;

import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/time_integrity.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

/// جسر زمن مزيّف بقراءة حتمية: bootId وmonotonic ثابتان، وساعة الحائط
/// مشتقة من monotonic فوق anchorWall — بلا sleep حقيقي وبلا منصة.
class FakeTimeIntegritySource implements TimeIntegritySource {
  FakeTimeIntegritySource({
    required this.bootId,
    required this.monotonic,
    this.throwOnRead = false,
    DateTime? wallOverride,
  }) : wallOverride =
           wallOverride ??
           DateTime.utc(
             2026,
             10,
             8,
             5,
             30,
           ).add(monotonic - const Duration(hours: 5));

  String bootId;
  Duration monotonic;
  bool throwOnRead;
  void Function()? onRead;

  /// ساعة الحائط المُعلَنة للقراءة: الافتراضي متوافق مع العدّاد،
  /// والاختبارات الموجّهة لتغيّر الساعة تمرر قيمة واعية.
  DateTime wallOverride;

  @override
  Future<TimeReading> read() async {
    onRead?.call();
    if (throwOnRead) {
      throw StateError('جسر الزمن غير متاح');
    }
    return TimeReading(
      wallClock: wallOverride,
      monotonic: monotonic,
      bootId: bootId,
    );
  }
}

class AnchorBookingRepository extends BookingRepository {
  AnchorBookingRepository(
    this.response,
    BookingLocalLedger ledger,
    TimeIntegritySource source,
  ) : super(null, null, ledger, source);
  final Object response;
  @override
  Future<WellDaySchedule> fetchTodaySchedule(String wellId) async =>
      WellDaySchedule.fromContract(response);
}

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late SqliteOutboxStore store;
  late BookingLocalLedger ledger;

  Future<void> reopen() async {
    await store.close();
    store = SqliteOutboxStore(
      databasePath: p.join(dir.path, 'outbox.db'),
      sqfliteFactory: databaseFactoryFfi,
    );
    ledger = BookingLocalLedger(store);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('booking_ledger');
    store = SqliteOutboxStore(
      databasePath: p.join(dir.path, 'outbox.db'),
      sqfliteFactory: databaseFactoryFfi,
    );
    ledger = BookingLocalLedger(store);
  });

  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  Map<String, Object?> schedule(String well, String day) => {
    'status': 'ok',
    'server_time': '2026-10-08T09:00:00Z',
    'well_id': well,
    'requested_day': day,
    'timezone': 'Asia/Aden',
    'well_timezone': 'Asia/Aden',
    'day_start': '${day}T00:00:00Z',
    'day_end': '${day}T23:59:59Z',
    'current_session': null,
    'bookings': <Object?>[],
  };

  Future<
    ({
      OfflineSessionCoordinator coordinator,
      CachedBookingSchedule cached,
      BookingAutomationState automation,
    })
  >
  eligibleOfflineTransition({
    bool automationEnabled = true,
    String nextStatus = 'confirmed',
  }) async {
    const wellId = 'well-local';
    await ledger.importServerSession(
      accountId: 'account',
      wellId: wellId,
      sessionId: 'server-session-current',
      bookingId: 'booking-current',
      startedAt: DateTime.utc(2026, 10, 8, 5),
    );
    final cached = CachedBookingSchedule(
      WellDaySchedule(
        serverTime: DateTime.utc(2026, 10, 8, 5, 30),
        wellId: wellId,
        requestedDay: DateTime.utc(2026, 10, 8),
        timezone: 'Asia/Aden',
        wellTimezone: 'Asia/Aden',
        dayStart: DateTime.utc(2026, 10, 7, 21),
        dayEnd: DateTime.utc(2026, 10, 8, 21),
        currentSession: CurrentBookingSession(
          sessionId: 'server-session-current',
          status: 'open',
          startedAt: DateTime.utc(2026, 10, 8, 5),
          wellId: wellId,
          bookingId: 'booking-current',
        ),
        bookings: [
          BookingDayItem(
            id: 'booking-current',
            publicCode: 'CURRENT',
            wellId: wellId,
            farmerWellAccountId: 'farmer-a',
            scheduledStart: DateTime.utc(2026, 10, 8, 5),
            scheduledEnd: DateTime.utc(2026, 10, 8, 6),
            scheduledDay: '2026-10-08',
            expectedDurationMinutes: 60,
            status: 'confirmed',
            priority: 0,
            statusGroup: 'active',
            farmId: 'farm-a',
            expectedEnergySource: 'solar',
          ),
          BookingDayItem(
            id: 'booking-next',
            publicCode: 'NEXT',
            wellId: wellId,
            farmerWellAccountId: 'farmer-b',
            scheduledStart: DateTime.utc(2026, 10, 8, 6),
            scheduledEnd: DateTime.utc(2026, 10, 8, 7),
            scheduledDay: '2026-10-08',
            expectedDurationMinutes: 60,
            status: nextStatus,
            priority: 0,
            statusGroup: 'active',
            farmId: 'farm-b',
            expectedEnergySource: 'well_diesel',
          ),
        ],
      ),
      DateTime.utc(2026, 10, 8, 5, 30),
    );
    // المرساة: خادم 05:30 = حائط 05:30 = عدّاد 5h، والإقلاع 7. الجسر
    // الافتراضي يقرأ عدّاد 5h+30m فيحسم «الآن» الخادمي 06:00 = الموعد.
    final timeAnchor = SessionTimeAnchor(
      serverTime: DateTime.utc(2026, 10, 8, 5, 30),
      wallClock: DateTime.utc(2026, 10, 8, 5, 30),
      monotonic: const Duration(hours: 5),
      bootId: '7',
    );
    final automation = BookingAutomationState(
      wellId: wellId,
      enabled: automationEnabled,
      revision: 4,
      settingsRowExists: true,
      firstSession: 'manual',
      activeChainId: 'chain-local',
      activeChainStatus: 'active',
      activeChainNextBookingId: 'booking-next',
      activeChainDecisionRevision: 3,
    );
    return (
      coordinator: OfflineSessionCoordinator(
        store: store,
        bookingLedger: ledger,
        timeIntegritySource: FakeTimeIntegritySource(
          bootId: '7',
          monotonic: const Duration(hours: 5, minutes: 30),
        ),
      ),
      cached: CachedBookingSchedule(
        cached.schedule,
        DateTime.utc(2026, 10, 8, 5, 30),
        timeAnchor: timeAnchor,
      ),
      automation: automation,
    );
  }

  test(
    'persists server day and timezone across restart with well/day isolation',
    () async {
      await ledger.saveSchedule(
        accountId: 'account-a',
        wellId: 'well-a',
        response: schedule('well-a', '2026-10-08'),
        fetchedAt: DateTime.utc(2026, 10, 8, 9),
      );
      await reopen();
      final cached = await ledger.loadSchedule(
        'account-a',
        'well-a',
        '2026-10-08',
      );
      expect(cached?.schedule.wellTimezone, 'Asia/Aden');
      expect(cached?.fetchedAt, DateTime.utc(2026, 10, 8, 9));
      expect(cached?.isCanonicalBusinessReceipt, isFalse);
      expect(
        await ledger.loadSchedule('account-a', 'well-b', '2026-10-08'),
        isNull,
      );
      expect(
        await ledger.loadSchedule('account-a', 'well-a', '2026-10-09'),
        isNull,
      );
      expect(
        await ledger.loadSchedule('account-b', 'well-a', '2026-10-08'),
        isNull,
      );
    },
  );

  test('corrupt cached payload fails closed', () async {
    await ledger.saveSchedule(
      accountId: 'a',
      wellId: 'w',
      response: schedule('w', '2026-10-08'),
      fetchedAt: DateTime.utc(2026, 10, 8),
    );
    await store.writeLocalValue('a', 'booking.schedule.w.2026-10-08', '{bad');
    expect(await ledger.loadSchedule('a', 'w', '2026-10-08'), isNull);
  });

  test(
    'fresh fetch captures server time without guessing network latency',
    () async {
      final source = FakeTimeIntegritySource(
        bootId: '42',
        monotonic: const Duration(hours: 12),
        wallOverride: DateTime.utc(2026, 10, 8, 15),
      );
      final repo = AnchorBookingRepository(
        schedule('w', '2026-10-08'),
        ledger,
        source,
      );
      final view = await repo.fetchScheduleView(accountId: 'a', wellId: 'w');
      expect(view.isCached, isFalse);
      expect(view.timeAnchor?.serverTime, DateTime.utc(2026, 10, 8, 9));
      expect(view.timeAnchor?.wallClock, DateTime.utc(2026, 10, 8, 15));
      await reopen();
      expect(
        (await ledger.loadLatestSchedule('a', 'w'))?.timeAnchor?.bootId,
        '42',
      );
    },
  );

  test('time anchor persists atomically with the schedule payload', () async {
    await ledger.saveSchedule(
      accountId: 'a',
      wellId: 'w',
      response: schedule('w', '2026-10-08'),
      fetchedAt: DateTime.utc(2026, 10, 8, 9),
      timeAnchor: SessionTimeAnchor(
        serverTime: DateTime.utc(2026, 10, 8, 9),
        wallClock: DateTime.utc(2026, 10, 8, 9),
        monotonic: const Duration(hours: 12),
        bootId: '7',
      ),
    );
    await reopen();
    final cached = await ledger.loadSchedule('a', 'w', '2026-10-08');
    expect(cached?.timeAnchor?.serverTime, DateTime.utc(2026, 10, 8, 9));
    expect(cached?.timeAnchor?.bootId, '7');
    expect(cached?.timeAnchor?.monotonic, const Duration(hours: 12));
  });

  test('legacy payload without time_anchor reads with a null anchor', () async {
    // payload بصيغة PR #60: fetched_at + response فقط بلا time_anchor.
    await store.writeLocalValue(
      'a',
      'booking.schedule.w.2026-10-08',
      jsonEncode({
        'fetched_at': '2026-10-08T09:00:00.000Z',
        'response': schedule('w', '2026-10-08'),
      }),
    );
    await store.writeLocalValue('a', 'booking.latest.w', '2026-10-08');
    final cached = await ledger.loadSchedule('a', 'w', '2026-10-08');
    expect(cached, isNotNull, reason: 'الكاش القديم يُقرأ ولا يتحطم');
    expect(cached?.timeAnchor, isNull);
  });

  test('corrupt time_anchor degrades to null, not a crash', () async {
    await ledger.saveSchedule(
      accountId: 'a',
      wellId: 'w',
      response: schedule('w', '2026-10-08'),
      fetchedAt: DateTime.utc(2026, 10, 8, 9),
      timeAnchor: SessionTimeAnchor(
        serverTime: DateTime.utc(2026, 10, 8, 9),
        wallClock: DateTime.utc(2026, 10, 8, 9),
        monotonic: const Duration(hours: 5),
        bootId: '7',
      ),
    );
    await store.writeLocalValue(
      'a',
      'booking.schedule.w.2026-10-08',
      jsonEncode({
        'fetched_at': '2026-10-08T09:00:00.000Z',
        'response': schedule('w', '2026-10-08'),
        'time_anchor': {'wall_clock': 'not-a-date', 'monotonic_ms': 'x'},
      }),
    );
    final cached = await ledger.loadSchedule('a', 'w', '2026-10-08');
    expect(cached?.schedule.wellId, 'w');
    expect(cached?.timeAnchor, isNull, reason: 'مرساة فاسدة = غياب، لا crash');
  });

  test(
    'rejects a current session from another well before persisting',
    () async {
      final response = schedule('well-a', '2026-10-08');
      response['current_session'] = {
        'session_id': 'session-x',
        'status': 'open',
        'started_at': '2026-10-08T05:00:00Z',
        'well_id': 'well-b',
        'booking_id': 'booking-x',
      };
      expect(
        () => ledger.saveSchedule(
          accountId: 'a',
          wellId: 'well-a',
          response: response,
          fetchedAt: DateTime.utc(2026, 10, 8),
        ),
        throwsStateError,
      );
      expect(await ledger.loadLatestSchedule('a', 'well-a'), isNull);
    },
  );

  test(
    'one intent keeps its command id and never becomes a business receipt',
    () async {
      final first = await ledger.recordIntent(
        accountId: 'a',
        wellId: 'w',
        transitionKey: 'chain:7:next',
        commandId: 'command-1',
        chainId: 'chain-7',
        currentSessionId: 'current',
        nextBookingId: 'next',
        decisionRevision: 7,
        automationRevision: 1,
      );
      await reopen();
      final second = await ledger.recordIntent(
        accountId: 'a',
        wellId: 'w',
        transitionKey: 'chain:7:next',
        commandId: 'command-2',
        chainId: 'chain-7',
        currentSessionId: 'current',
        nextBookingId: 'next',
        decisionRevision: 7,
        automationRevision: 1,
      );
      expect(second.commandId, first.commandId);
      expect(second.state, BookingIntentState.awaitingReconciliation);
      expect(second.hasCanonicalReceipt, isFalse);
    },
  );

  test(
    'server session imports once and restores original start after restart',
    () async {
      final started = DateTime.utc(2026, 10, 8, 5);
      final first = await ledger.importServerSession(
        accountId: 'a',
        wellId: 'w',
        sessionId: 'session-1',
        bookingId: 'booking-1',
        startedAt: started,
      );
      await reopen();
      final again = await ledger.importServerSession(
        accountId: 'a',
        wellId: 'w',
        sessionId: 'session-1',
        bookingId: 'booking-1',
        startedAt: started,
      );
      expect(again.sessionId, first.sessionId);
      expect(again.startedAt, started);
      expect(
        (await ledger.loadServerSession('a', 'w'))?.sessionId,
        'session-1',
      );
      expect(await ledger.loadServerSession('a', 'other'), isNull);
    },
  );

  test('different server session or booking requires review', () async {
    await ledger.importServerSession(
      accountId: 'a',
      wellId: 'w',
      sessionId: 'session-1',
      bookingId: 'booking-1',
      startedAt: DateTime.utc(2026, 10, 8, 5),
    );
    expect(
      () => ledger.importServerSession(
        accountId: 'a',
        wellId: 'w',
        sessionId: 'session-2',
        bookingId: 'booking-2',
        startedAt: DateTime.utc(2026, 10, 8, 6),
      ),
      throwsStateError,
    );
    expect((await ledger.loadServerSession('a', 'w'))?.sessionId, 'session-1');
  });

  test(
    'missing server session keeps prior local evidence for review',
    () async {
      await ledger.importServerSession(
        accountId: 'a',
        wellId: 'w',
        sessionId: 'session-1',
        bookingId: 'booking-1',
        startedAt: DateTime.utc(2026, 10, 8, 5),
      );
      final coordinator = OfflineSessionCoordinator(
        store: store,
        bookingLedger: ledger,
      );
      await expectLater(
        coordinator.reconcileServerBookingSession(
          accountId: 'a',
          wellId: 'w',
          current: null,
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        (await ledger.loadServerSession('a', 'w'))?.sessionId,
        'session-1',
      );
    },
  );

  test('incomplete legacy evidence cannot reconcile an intent', () async {
    final intent = await ledger.recordIntent(
      accountId: 'a',
      wellId: 'w',
      transitionKey: 'chain:1:next',
      commandId: 'same-command',
      chainId: 'chain-1',
      currentSessionId: 'current',
      nextBookingId: 'next',
      decisionRevision: 1,
      automationRevision: 1,
    );
    final pending = await ledger.reconcileIntent(
      'a',
      intent,
      const BookingServerOutcome.pending(),
    );
    expect(pending.state, BookingIntentState.awaitingReconciliation);
    final accepted = await ledger.reconcileIntent(
      'a',
      intent,
      const BookingServerOutcome.accepted(
        commandId: 'same-command',
        bookingId: 'next',
        sessionId: 'session-2',
      ),
    );
    expect(accepted.state, BookingIntentState.rejectedRequiresReview);
    expect(accepted.hasCanonicalReceipt, isFalse);
    await reopen();
    final restoredAccepted = await ledger.loadIntent('a', 'w', 'chain:1:next');
    expect(restoredAccepted?.hasCanonicalReceipt, isFalse);
    final replayed = await ledger.reconcileIntent(
      'a',
      intent,
      const BookingServerOutcome.accepted(
        commandId: 'same-command',
        bookingId: 'next',
        sessionId: 'session-2',
      ),
    );
    expect(replayed.state, BookingIntentState.rejectedRequiresReview);
    for (final reason in [
      'stale_decision_revision',
      'revoked_delegation',
      'operator_changed_pending_confirmation',
      'booking_auto_transition_disabled',
      'next_booking_changed',
    ]) {
      final other = await ledger.recordIntent(
        accountId: 'a',
        wellId: 'w',
        transitionKey: reason,
        commandId: reason,
        chainId: 'chain-1',
        currentSessionId: 'current',
        nextBookingId: 'next',
        decisionRevision: 1,
        automationRevision: 1,
      );
      final rejected = await ledger.reconcileIntent(
        'a',
        other,
        BookingServerOutcome.rejected(reason),
      );
      expect(rejected.state, BookingIntentState.rejectedRequiresReview);
      expect(rejected.commandId, other.commandId);
      expect(rejected.reviewReason, reason);
      final noRetry = await ledger.reconcileIntent(
        'a',
        other,
        const BookingServerOutcome.pending(),
      );
      expect(noRetry.state, BookingIntentState.rejectedRequiresReview);
      expect(noRetry.commandId, other.commandId);
    }
  });

  test('mismatched canonical command evidence requires review', () async {
    final intent = await ledger.recordIntent(
      accountId: 'a',
      wellId: 'w',
      transitionKey: 'chain:1:next',
      commandId: 'stable-command',
      chainId: 'chain-1',
      currentSessionId: 'current',
      nextBookingId: 'next',
      decisionRevision: 1,
      automationRevision: 1,
    );
    final result = await ledger.reconcileIntent(
      'a',
      intent,
      const BookingServerOutcome.accepted(
        commandId: 'different-command',
        bookingId: 'next',
        sessionId: 'session-2',
      ),
    );
    expect(result.state, BookingIntentState.rejectedRequiresReview);
    expect(result.reviewReason, 'incomplete_canonical_evidence');
    expect(
      (await ledger.loadIntent('a', 'w', 'chain:1:next'))?.commandId,
      'stable-command',
    );
  });

  test(
    'read-only canonical receipt reconciles exact and logical matches',
    () async {
      Future<BookingTransitionIntent> intent(
        String key,
        String command, {
        String wellId = 'w',
      }) {
        return ledger.recordIntent(
          accountId: 'a',
          wellId: wellId,
          transitionKey: key,
          commandId: command,
          chainId: 'chain',
          currentSessionId: 'current-session',
          nextBookingId: 'next-booking',
          decisionRevision: 3,
          automationRevision: 4,
        );
      }

      BookingTransitionReconciliation result({
        required String requested,
        required String canonical,
        required String kind,
        String status = 'found',
        String? wellId,
        String? reviewReason,
      }) => BookingTransitionReconciliation(
        status: status,
        requestedCommandId: requested,
        canonicalCommandId: canonical,
        wellId: wellId ?? 'w',
        chainId: 'chain',
        currentSessionId: 'current-session',
        nextBookingId: 'next-booking',
        decisionRevision: 3,
        automationRevision: 4,
        matchKind: kind,
        canonicalResult: status == 'found' ? 'accepted' : null,
        receipt: status == 'found'
            ? BookingReconciliationReceipt(
                closedSessionId: 'current-session',
                closedAt: DateTime.utc(2026, 10, 8, 6),
                startedSessionId: 'server-session',
                startedBookingId: 'next-booking',
                startedAt: DateTime.utc(2026, 10, 8, 6),
              )
            : null,
        reviewReason: reviewReason,
      );

      final exactIntent = await intent('exact', 'phone-a');
      await ledger.recordProvisionalSession(
        accountId: 'a',
        intent: exactIntent,
        localSessionId: 'local-provisional-exact',
        occurredAt: DateTime.utc(2026, 10, 8, 6),
      );
      final exact = await ledger.reconcileReadResult(
        'a',
        exactIntent,
        result(
          requested: 'phone-a',
          canonical: 'phone-a',
          kind: 'exact_command',
        ),
      );
      expect(exact.state, BookingIntentState.reconciled);
      expect(exact.commandId, 'phone-a');
      expect(exact.canonicalCommandId, 'phone-a');
      expect(exact.canonicalMatchKind, 'exact_command');
      expect(exact.hasCanonicalReceipt, isTrue);
      expect(
        (await ledger.loadProvisionalSession(
          'a',
          'w',
          'exact',
        ))?.reconciliationState,
        'reconciled',
      );

      final logicalIntent = await intent(
        'logical',
        'phone-b',
        wellId: 'w-logical',
      );
      final logical = await ledger.reconcileReadResult(
        'a',
        logicalIntent,
        result(
          requested: 'phone-b',
          canonical: 'server-b',
          kind: 'logical_intent',
          wellId: 'w-logical',
        ),
      );
      expect(logical.state, BookingIntentState.reconciled);
      expect(logical.commandId, 'phone-b');
      expect(logical.canonicalCommandId, 'server-b');
      expect(logical.canonicalMatchKind, 'logical_intent');
      await reopen();
      expect(
        (await ledger.loadIntent(
          'a',
          'w-logical',
          'logical',
        ))?.canonicalCommandId,
        'server-b',
      );
      final repeated = await ledger.reconcileReadResult(
        'a',
        logical,
        result(
          requested: 'phone-b',
          canonical: 'server-b',
          kind: 'logical_intent',
          wellId: 'w-logical',
        ),
      );
      expect(repeated.state, BookingIntentState.reconciled);
    },
  );

  test(
    'read reconciliation rejects mismatch, ambiguity, rejection and not-found',
    () async {
      Future<BookingTransitionIntent> intent(String key) => ledger.recordIntent(
        accountId: 'a',
        wellId: 'w',
        transitionKey: key,
        commandId: 'phone-$key',
        chainId: 'chain',
        currentSessionId: 'current-session',
        nextBookingId: 'next-booking',
        decisionRevision: 3,
        automationRevision: 4,
      );
      for (final entry in <(String, String, String)>[
        ('wrong-well', 'found', 'intent_mismatch'),
        ('ambiguous', 'conflict', 'ambiguous_canonical_intent'),
        ('rejected', 'rejected', 'canonical_rejected'),
        ('missing', 'not_found', 'not_found'),
      ]) {
        final local = await intent(entry.$1);
        final outcome = BookingTransitionReconciliation(
          status: entry.$2,
          requestedCommandId: local.commandId,
          canonicalCommandId: null,
          wellId: entry.$1 == 'wrong-well' ? 'other-well' : 'w',
          chainId: 'chain',
          currentSessionId: 'current-session',
          nextBookingId: 'next-booking',
          decisionRevision: 3,
          automationRevision: 4,
          matchKind: null,
          canonicalResult: null,
          receipt: null,
          reviewReason: entry.$3,
        );
        final reviewed = await ledger.reconcileReadResult('a', local, outcome);
        expect(reviewed.state, BookingIntentState.rejectedRequiresReview);
        expect(reviewed.reviewReason, entry.$3);
        expect(reviewed.commandId, local.commandId);
      }
    },
  );

  test(
    'first booking is not an automatic intent and missed start cannot backdate',
    () async {
      expect(
        () => ledger.recordIntent(
          accountId: 'a',
          wellId: 'w',
          transitionKey: 'first',
          commandId: 'c',
          chainId: 'chain-first',
          currentSessionId: '',
          nextBookingId: 'first',
          decisionRevision: 1,
          automationRevision: 1,
        ),
        throwsStateError,
      );
      final intent = await ledger.recordIntent(
        accountId: 'a',
        wellId: 'w',
        transitionKey: 'second',
        commandId: 'c2',
        chainId: 'chain-second',
        currentSessionId: 'first',
        nextBookingId: 'second',
        decisionRevision: 1,
        automationRevision: 1,
      );
      await ledger.markMissedStart('a', intent);
      await reopen();
      final restored = await ledger.loadIntent('a', 'w', 'second');
      expect(restored?.state, BookingIntentState.missedStartRequiresReview);
      expect(restored?.commandId, 'c2');
      expect(restored?.toJson().containsKey('started_at'), isFalse);
    },
  );

  test('due cached transition records one provisional session without an outbox command', () async {
    const wellId = 'well-local';
    const currentBookingId = 'booking-current';
    const nextBookingId = 'booking-next';
    await ledger.importServerSession(
      accountId: 'account',
      wellId: wellId,
      sessionId: 'server-session-current',
      bookingId: currentBookingId,
      startedAt: DateTime.utc(2026, 10, 8, 5),
    );
    final cached = CachedBookingSchedule(
      WellDaySchedule(
        serverTime: DateTime.utc(2026, 10, 8, 5, 30),
        wellId: wellId,
        requestedDay: DateTime.utc(2026, 10, 8),
        timezone: 'Asia/Aden',
        wellTimezone: 'Asia/Aden',
        dayStart: DateTime.utc(2026, 10, 7, 21),
        dayEnd: DateTime.utc(2026, 10, 8, 21),
        currentSession: CurrentBookingSession(
          sessionId: 'server-session-current',
          status: 'open',
          startedAt: DateTime.utc(2026, 10, 8, 5),
          wellId: wellId,
          bookingId: currentBookingId,
        ),
        bookings: [
          BookingDayItem(
            id: currentBookingId,
            publicCode: 'CURRENT',
            wellId: wellId,
            farmerWellAccountId: 'farmer-a',
            scheduledStart: DateTime.utc(2026, 10, 8, 5),
            scheduledEnd: DateTime.utc(2026, 10, 8, 6),
            scheduledDay: '2026-10-08',
            expectedDurationMinutes: 60,
            status: 'confirmed',
            priority: 0,
            statusGroup: 'active',
            farmId: 'farm-a',
            expectedEnergySource: 'solar',
          ),
          BookingDayItem(
            id: nextBookingId,
            publicCode: 'NEXT',
            wellId: wellId,
            farmerWellAccountId: 'farmer-b',
            scheduledStart: DateTime.utc(2026, 10, 8, 6),
            scheduledEnd: DateTime.utc(2026, 10, 8, 7),
            scheduledDay: '2026-10-08',
            expectedDurationMinutes: 60,
            status: 'confirmed',
            priority: 0,
            statusGroup: 'active',
            farmId: 'farm-b',
            expectedEnergySource: 'well_diesel',
          ),
        ],
      ),
      DateTime.utc(2026, 10, 8, 5, 30),
    );
    const automation = BookingAutomationState(
      wellId: wellId,
      enabled: true,
      revision: 4,
      settingsRowExists: true,
      firstSession: 'manual',
      activeChainId: 'chain-local',
      activeChainStatus: 'active',
      activeChainNextBookingId: nextBookingId,
      activeChainDecisionRevision: 3,
    );
    // المرساة: خادم 05:30 = حائط 05:30 = عدّاد 5h، والإقلاع 7،
    // والجسر يقرأ 06:00 — لحظة الموعد نفسها.
    final anchored = CachedBookingSchedule(
      cached.schedule,
      cached.fetchedAt,
      timeAnchor: SessionTimeAnchor(
        serverTime: DateTime.utc(2026, 10, 8, 5, 30),
        wallClock: DateTime.utc(2026, 10, 8, 5, 30),
        monotonic: const Duration(hours: 5),
        bootId: '7',
      ),
    );
    final dynamic coordinator = OfflineSessionCoordinator(
      store: store,
      bookingLedger: ledger,
      timeIntegritySource: FakeTimeIntegritySource(
        bootId: '7',
        monotonic: const Duration(hours: 5, minutes: 30),
      ),
    );

    final first = await coordinator.runCachedDueBookingTransition(
      accountId: 'account',
      wellId: wellId,
      cachedSchedule: anchored,
      automation: automation,
      commandId: 'stable-local-command',
      localSessionId: 'local-provisional-next',
      scheduledCallback: true,
    );
    final repeated = await coordinator.runCachedDueBookingTransition(
      accountId: 'account',
      wellId: wellId,
      cachedSchedule: anchored,
      automation: automation,
      commandId: 'different-command-must-not-win',
      localSessionId: 'different-local-id-must-not-win',
      scheduledCallback: true,
    );

    expect(first.intent.commandId, 'stable-local-command');
    expect(first.intent.state, BookingIntentState.awaitingReconciliation);
    expect(first.session.localSessionId, 'local-provisional-next');
    expect(first.session.serverSessionId, 'server-session-current');
    expect(first.session.provenance, 'local_offline_provisional');
    expect(repeated.intent.commandId, 'stable-local-command');
    expect(repeated.session.localSessionId, 'local-provisional-next');
    expect(await store.pendingCommands('account'), isEmpty);
  });

  test(
    'provisional transition survives restart with its original command id',
    () async {
      final fixture = await eligibleOfflineTransition();
      final first = await fixture.coordinator.runCachedDueBookingTransition(
        accountId: 'account',
        wellId: 'well-local',
        cachedSchedule: fixture.cached,
        automation: fixture.automation,
        commandId: 'stable-command',
        localSessionId: 'local-session',
        scheduledCallback: true,
      );
      await reopen();
      final restoredCoordinator = OfflineSessionCoordinator(
        store: store,
        bookingLedger: ledger,
        timeIntegritySource: FakeTimeIntegritySource(
          bootId: '7',
          monotonic: const Duration(hours: 5, minutes: 30),
        ),
      );
      final repeated = await restoredCoordinator.runCachedDueBookingTransition(
        accountId: 'account',
        wellId: 'well-local',
        cachedSchedule: fixture.cached,
        automation: fixture.automation,
        commandId: 'new-command-must-not-replace',
        localSessionId: 'new-local-session-must-not-replace',
        scheduledCallback: true,
      );
      final restored = await restoredCoordinator
          .restoreProvisionalBookingSession(
            accountId: 'account',
            wellId: 'well-local',
          );
      expect(first.intent?.commandId, 'stable-command');
      expect(repeated.outcome, LocalBookingTransitionOutcome.alreadyRecorded);
      expect(repeated.intent?.commandId, 'stable-command');
      expect(restored?.localSessionId, 'local-session');
      expect(restored?.reconciliationState, 'awaiting_reconciliation');
    },
  );

  test(
    'simultaneous due callbacks commit one durable provisional transition',
    () async {
      final fixture = await eligibleOfflineTransition();
      final results = await Future.wait([
        fixture.coordinator.runCachedDueBookingTransition(
          accountId: 'account',
          wellId: 'well-local',
          cachedSchedule: fixture.cached,
          automation: fixture.automation,
          commandId: 'timer-command',
          localSessionId: 'timer-local',
          scheduledCallback: true,
        ),
        fixture.coordinator.runCachedDueBookingTransition(
          accountId: 'account',
          wellId: 'well-local',
          cachedSchedule: fixture.cached,
          automation: fixture.automation,
          commandId: 'resume-command',
          localSessionId: 'resume-local',
          scheduledCallback: true,
        ),
      ]);
      expect(results.map((result) => result.intent?.commandId).toSet(), {
        'timer-command',
      });
      expect(results.map((result) => result.session?.localSessionId).toSet(), {
        'timer-local',
      });
      expect(
        await ledger.loadProvisionalSessions('account', 'well-local'),
        hasLength(1),
      );
    },
  );

  test('canonical receipt advances the server link without erasing provisional history', () async {
    final fixture = await eligibleOfflineTransition();
    final local = await fixture.coordinator.runCachedDueBookingTransition(
      accountId: 'account',
      wellId: 'well-local',
      cachedSchedule: fixture.cached,
      automation: fixture.automation,
      commandId: 'phone-command',
      localSessionId: 'local-provisional',
      scheduledCallback: true,
    );
    final intent = await ledger.reconcileReadResult(
      'account',
      local.intent!,
      BookingTransitionReconciliation(
        status: 'found',
        requestedCommandId: 'phone-command',
        canonicalCommandId: 'server-command',
        wellId: 'well-local',
        chainId: 'chain-local',
        currentSessionId: 'server-session-current',
        nextBookingId: 'booking-next',
        decisionRevision: 3,
        automationRevision: 4,
        matchKind: 'logical_intent',
        canonicalResult: 'accepted',
        receipt: BookingReconciliationReceipt(
          closedSessionId: 'server-session-current',
          closedAt: DateTime.utc(2026, 10, 8, 6),
          startedSessionId: 'server-session-next',
          startedBookingId: 'booking-next',
          startedAt: DateTime.utc(2026, 10, 8, 6, 1),
        ),
        reviewReason: null,
      ),
    );
    final provisional = await ledger.loadProvisionalSession(
      'account',
      'well-local',
      local.intent!.transitionKey,
    );
    final link = await ledger.loadServerSession('account', 'well-local');
    expect(intent.state, BookingIntentState.reconciled);
    expect(intent.commandId, 'phone-command');
    expect(intent.canonicalCommandId, 'server-command');
    expect(provisional?.serverSessionId, 'server-session-current');
    expect(provisional?.reconciliationState, 'reconciled');
    expect(link?.sessionId, 'server-session-next');
    expect(link?.startedAt, DateTime.utc(2026, 10, 8, 6, 1));
  });

  test('cached transition rejects unsafe inputs and marks a missed wake for review', () async {
    final off = await eligibleOfflineTransition(automationEnabled: false);
    final offResult = await off.coordinator.runCachedDueBookingTransition(
      accountId: 'account',
      wellId: 'well-local',
      cachedSchedule: off.cached,
      automation: off.automation,
      commandId: 'off',
      localSessionId: 'local-off',
      scheduledCallback: true,
    );
    expect(offResult.reason, 'automation_not_eligible');

    final unsafe = await eligibleOfflineTransition(nextStatus: 'draft');
    final draftResult = await unsafe.coordinator.runCachedDueBookingTransition(
      accountId: 'account',
      wellId: 'well-local',
      cachedSchedule: unsafe.cached,
      automation: unsafe.automation,
      commandId: 'draft',
      localSessionId: 'local-draft',
      scheduledCallback: true,
    );
    expect(draftResult.reason, 'next_booking_not_executable');

    // «الآن» الخادمي من مرساة خارج نافذة اليوم (10:00 صباح اليوم التالي
    // بتوقيت الخادم) — قراءة زمنية موثوقة والرفض بنيوي (wrong_well_day).
    final wrongDayCached = CachedBookingSchedule(
      unsafe.cached.schedule,
      unsafe.cached.fetchedAt,
      timeAnchor: SessionTimeAnchor(
        serverTime: DateTime.utc(2026, 10, 8, 5, 30),
        wallClock: DateTime.utc(2026, 10, 8, 5, 30),
        monotonic: const Duration(hours: 5),
        bootId: '7',
      ),
    );
    final wrongDay =
        await OfflineSessionCoordinator(
          store: store,
          bookingLedger: ledger,
          timeIntegritySource: FakeTimeIntegritySource(
            bootId: '7',
            monotonic: const Duration(hours: 29, minutes: 30),
          ),
        ).runCachedDueBookingTransition(
          accountId: 'account',
          wellId: 'well-local',
          cachedSchedule: wrongDayCached,
          automation: unsafe.automation,
          commandId: 'wrong-day',
          localSessionId: 'local-wrong-day',
          scheduledCallback: true,
        );
    expect(wrongDay.reason, 'wrong_well_day');

    final wrongWell = await unsafe.coordinator.runCachedDueBookingTransition(
      accountId: 'account',
      wellId: 'other-well',
      cachedSchedule: unsafe.cached,
      automation: unsafe.automation,
      commandId: 'wrong-well',
      localSessionId: 'local-wrong-well',
      scheduledCallback: true,
    );
    expect(wrongWell.reason, 'invalid_cached_schedule');

    final firstBookingTarget = BookingAutomationState(
      wellId: 'well-local',
      enabled: true,
      revision: 4,
      settingsRowExists: true,
      firstSession: 'manual',
      activeChainId: 'chain-local',
      activeChainStatus: 'active',
      activeChainNextBookingId: 'booking-current',
      activeChainDecisionRevision: 3,
    );
    final firstBooking = await unsafe.coordinator.runCachedDueBookingTransition(
      accountId: 'account',
      wellId: 'well-local',
      cachedSchedule: unsafe.cached,
      automation: firstBookingTarget,
      commandId: 'first',
      localSessionId: 'local-first',
      scheduledCallback: true,
    );
    expect(firstBooking.reason, 'ambiguous_booking_chain');

    final missedFixture = await eligibleOfflineTransition();
    final missed = await missedFixture.coordinator
        .runCachedDueBookingTransition(
          accountId: 'account',
          wellId: 'well-local',
          cachedSchedule: missedFixture.cached,
          automation: missedFixture.automation,
          commandId: 'missed-command',
          localSessionId: 'must-not-exist',
          scheduledCallback: false,
        );
    expect(missed.outcome, LocalBookingTransitionOutcome.missedRequiresReview);
    expect(missed.intent?.state, BookingIntentState.missedStartRequiresReview);
    expect(
      await ledger.loadProvisionalSession(
        'account',
        'well-local',
        'chain-local:server-session-current:booking-next:3:4',
      ),
      isNull,
    );

    final conflict = await eligibleOfflineTransition();
    final competingIntent = await ledger.recordIntent(
      accountId: 'account',
      wellId: 'well-local',
      transitionKey: 'other-chain:server-session-current:other-booking:3:4',
      commandId: 'other-command',
      chainId: 'other-chain',
      currentSessionId: 'server-session-current',
      nextBookingId: 'other-booking',
      decisionRevision: 3,
      automationRevision: 4,
    );
    await ledger.recordProvisionalSession(
      accountId: 'account',
      intent: competingIntent,
      localSessionId: 'other-local-session',
      occurredAt: DateTime.utc(2026, 10, 8, 6),
    );
    final conflictResult = await conflict.coordinator
        .runCachedDueBookingTransition(
          accountId: 'account',
          wellId: 'well-local',
          cachedSchedule: conflict.cached,
          automation: conflict.automation,
          commandId: 'conflict-command',
          localSessionId: 'conflict-local',
          scheduledCallback: true,
        );
    expect(conflictResult.reason, 'local_conflict');
  });

  test('callback rechecks boot and generation before durable write', () async {
    final fixture = await eligibleOfflineTransition();
    final source = FakeTimeIntegritySource(
      bootId: '7',
      monotonic: const Duration(hours: 5, minutes: 30),
    );
    var reads = 0;
    source.onRead = () {
      if (++reads == 2) source.bootId = '8';
    };
    final coordinator = OfflineSessionCoordinator(
      store: store,
      bookingLedger: ledger,
      timeIntegritySource: source,
    );
    final result = await coordinator.runCachedDueBookingTransition(
      accountId: 'account',
      wellId: 'well-local',
      cachedSchedule: fixture.cached,
      automation: fixture.automation,
      commandId: 'rechecked',
      localSessionId: 'no-session',
      scheduledCallback: true,
    );
    expect(
      result.outcome,
      LocalBookingTransitionOutcome.timeIntegrityRequiresReview,
    );
    expect(await ledger.loadAwaitingIntents('account', 'well-local'), isEmpty);
    source.bootId = '7';
    var current = true;
    reads = 0;
    source.onRead = () {
      if (++reads == 2) current = false;
    };
    final stale = await coordinator.runCachedDueBookingTransition(
      accountId: 'account',
      wellId: 'well-local',
      cachedSchedule: fixture.cached,
      automation: fixture.automation,
      commandId: 'stale',
      localSessionId: 'no-session',
      scheduledCallback: true,
      isCurrent: () => current,
    );
    expect(stale.reason, 'stale_runtime');
    expect(
      await ledger.loadProvisionalSessions('account', 'well-local'),
      isEmpty,
    );
  });

  test('restart restores schedule anchor: same boot eligible, different boot closed', () async {
    final fixture = await eligibleOfflineTransition();
    final model = fixture.cached.schedule;
    final response = <String, Object?>{
      ...schedule('well-local', '2026-10-08'),
      'server_time': fixture.cached.timeAnchor!.serverTime!.toIso8601String(),
      'day_start': model.dayStart.toIso8601String(),
      'day_end': model.dayEnd.toIso8601String(),
      'current_session': {
        'session_id': 'server-session-current',
        'status': 'open',
        'started_at': model.currentSession!.startedAt.toIso8601String(),
        'well_id': 'well-local',
        'booking_id': 'booking-current',
      },
      'bookings': model.bookings
          .map(
            (b) => {
              'id': b.id,
              'public_code': b.publicCode,
              'well_id': b.wellId,
              'farmer_well_account_id': b.farmerWellAccountId,
              'farm_id': b.farmId,
              'scheduled_start': b.scheduledStart.toIso8601String(),
              'scheduled_end': b.scheduledEnd.toIso8601String(),
              'scheduled_day': b.scheduledDay,
              'expected_duration_minutes': b.expectedDurationMinutes,
              'expected_energy_source': b.expectedEnergySource,
              'status': b.status,
              'priority': b.priority,
              'status_group': b.statusGroup,
            },
          )
          .toList(),
    };
    await ledger.saveSchedule(
      accountId: 'account',
      wellId: 'well-local',
      response: response,
      fetchedAt: fixture.cached.fetchedAt,
      timeAnchor: fixture.cached.timeAnchor,
    );
    await reopen();
    final cached = await ledger.loadLatestSchedule('account', 'well-local');
    final source = FakeTimeIntegritySource(
      bootId: '8',
      monotonic: const Duration(hours: 5, minutes: 20),
    );
    final coordinator = OfflineSessionCoordinator(
      store: store,
      bookingLedger: ledger,
      timeIntegritySource: source,
    );
    Future<LocalBookingTransitionResult> run() =>
        coordinator.runCachedDueBookingTransition(
          accountId: 'account',
          wellId: 'well-local',
          cachedSchedule: cached,
          automation: fixture.automation,
          commandId: 'restart-stable',
          localSessionId: 'restart-local',
          scheduledCallback: true,
        );
    expect(
      (await run()).outcome,
      LocalBookingTransitionOutcome.timeIntegrityRequiresReview,
    );
    source.bootId = '7';
    expect((await run()).reason, 'not_due');
    expect(await ledger.loadAwaitingIntents('account', 'well-local'), isEmpty);
    source.monotonic = const Duration(hours: 5, minutes: 30);
    expect(
      (await run()).session?.startedLocallyAt,
      DateTime.utc(2026, 10, 8, 6),
    );
    expect((await run()).intent?.commandId, 'restart-stable');
    expect(
      await ledger.loadProvisionalSessions('account', 'well-local'),
      hasLength(1),
    );
  });

  test(
    'corrupted anchor matching a different server snapshot cannot govern time',
    () async {
      await ledger.saveSchedule(
        accountId: 'a',
        wellId: 'w',
        response: schedule('w', '2026-10-08'),
        fetchedAt: DateTime.utc(2026, 10, 8, 9),
      );
      final raw = jsonDecode(
        (await store.readLocalValue('a', 'booking.schedule.w.2026-10-08'))!,
      ) as Map<String, dynamic>;
      raw['time_anchor'] = {
        'server_time': '2026-10-08T15:00:00Z',
        'wall_clock': '2026-10-08T09:00:00Z',
        'monotonic_ms': 100,
        'boot_id': '7',
      };
      await store.writeLocalValue(
        'a',
        'booking.schedule.w.2026-10-08',
        jsonEncode(raw),
      );
      final restored = await ledger.loadLatestSchedule('a', 'w');
      expect(restored, isNotNull);
      expect(restored!.timeAnchor, isNull);
    },
  );

  group('سلامة الزمن في الانتقال الآلي المحلي (§17)', () {
    test('trusted anchor records with server-aligned executedAt', () async {
      final fixture = await eligibleOfflineTransition();
      final result = await fixture.coordinator.runCachedDueBookingTransition(
        accountId: 'account',
        wellId: 'well-local',
        cachedSchedule: fixture.cached,
        automation: fixture.automation,
        commandId: 'aligned-command',
        localSessionId: 'aligned-local',
        scheduledCallback: true,
      );
      expect(result.outcome, LocalBookingTransitionOutcome.transitioned);
      // executedAt = «الآن» الخادمي (05:30 + 30 دقيقة عدّادًا) لا DateTime.now.
      expect(result.session?.startedLocallyAt, DateTime.utc(2026, 10, 8, 6));
    });

    test('legacy cache without anchor never arms: requires review', () async {
      final fixture = await eligibleOfflineTransition();
      final legacy = CachedBookingSchedule(
        fixture.cached.schedule,
        fixture.cached.fetchedAt,
      );
      final coordinator = OfflineSessionCoordinator(
        store: store,
        bookingLedger: ledger,
        timeIntegritySource: FakeTimeIntegritySource(
          bootId: '7',
          monotonic: const Duration(hours: 5, minutes: 30),
        ),
      );
      final result = await coordinator.runCachedDueBookingTransition(
        accountId: 'account',
        wellId: 'well-local',
        cachedSchedule: legacy,
        automation: fixture.automation,
        commandId: 'legacy',
        localSessionId: 'legacy-local',
        scheduledCallback: true,
      );
      expect(
        result.outcome,
        LocalBookingTransitionOutcome.timeIntegrityRequiresReview,
      );
      expect(
        await ledger.loadProvisionalSessions('account', 'well-local'),
        isEmpty,
        reason: 'بلا مرساة لا جلسة مؤقتة ولا كتابة متينة',
      );
    });

    test('bridge error does not arm and does not write', () async {
      final fixture = await eligibleOfflineTransition();
      final coordinator = OfflineSessionCoordinator(
        store: store,
        bookingLedger: ledger,
        timeIntegritySource: FakeTimeIntegritySource(
          bootId: '7',
          monotonic: const Duration(hours: 5, minutes: 30),
          throwOnRead: true,
        ),
      );
      final result = await coordinator.runCachedDueBookingTransition(
        accountId: 'account',
        wellId: 'well-local',
        cachedSchedule: fixture.cached,
        automation: fixture.automation,
        commandId: 'bridge-fail',
        localSessionId: 'must-not-exist',
        scheduledCallback: true,
      );
      expect(
        result.outcome,
        LocalBookingTransitionOutcome.timeIntegrityRequiresReview,
      );
      expect(
        await ledger.loadProvisionalSessions('account', 'well-local'),
        isEmpty,
      );
    });

    test(
      'reboot (different boot id) never arms an automatic transition',
      () async {
        final fixture = await eligibleOfflineTransition();
        final coordinator = OfflineSessionCoordinator(
          store: store,
          bookingLedger: ledger,
          timeIntegritySource: FakeTimeIntegritySource(
            bootId: '8',
            monotonic: const Duration(hours: 5, minutes: 30),
          ),
        );
        final result = await coordinator.runCachedDueBookingTransition(
          accountId: 'account',
          wellId: 'well-local',
          cachedSchedule: fixture.cached,
          automation: fixture.automation,
          commandId: 'reboot-command',
          localSessionId: 'must-not-exist-reboot',
          scheduledCallback: true,
        );
        expect(
          result.outcome,
          LocalBookingTransitionOutcome.timeIntegrityRequiresReview,
        );
        expect(
          await ledger.loadProvisionalSessions('account', 'well-local'),
          isEmpty,
        );
      },
    );

    test('monotonic regression inside the same boot is untrusted', () async {
      final fixture = await eligibleOfflineTransition();
      final coordinator = OfflineSessionCoordinator(
        store: store,
        bookingLedger: ledger,
        timeIntegritySource: FakeTimeIntegritySource(
          bootId: '7',
          // رجوع العدّاد داخل نفس الإقلاع مستحيل فيزيائيًّا => غير موثوق.
          monotonic: const Duration(hours: 4),
        ),
      );
      final result = await coordinator.runCachedDueBookingTransition(
        accountId: 'account',
        wellId: 'well-local',
        cachedSchedule: fixture.cached,
        automation: fixture.automation,
        commandId: 'regression',
        localSessionId: 'must-not-exist',
        scheduledCallback: true,
      );
      expect(
        result.outcome,
        LocalBookingTransitionOutcome.timeIntegrityRequiresReview,
      );
      expect(
        await ledger.loadProvisionalSessions('account', 'well-local'),
        isEmpty,
      );
    });

    test('wall forward does not trigger early; monotonic governs', () async {
      final fixture = await eligibleOfflineTransition();
      // العدّاد يقول 05:40 (قبل الموعد 06:00) وساعة الحائط قُدِّمت إلى
      // الظهر: لا انتقال مبكر بسبب ساعة الحائط.
      final beforeDue =
          await OfflineSessionCoordinator(
            store: store,
            bookingLedger: ledger,
            timeIntegritySource: FakeTimeIntegritySource(
              bootId: '7',
              monotonic: const Duration(hours: 5, minutes: 10),
              wallOverride: DateTime.utc(2026, 10, 8, 12),
            ),
          ).runCachedDueBookingTransition(
            accountId: 'account',
            wellId: 'well-local',
            cachedSchedule: fixture.cached,
            automation: fixture.automation,
            commandId: 'early',
            localSessionId: 'early-local',
            scheduledCallback: true,
          );
      expect(beforeDue.reason, 'not_due');
      expect(
        await ledger.loadProvisionalSessions('account', 'well-local'),
        isEmpty,
      );
    });

    test('wall backward does not delay the monotonic decision', () async {
      final fixture = await eligibleOfflineTransition();
      // العدّاد يقول 06:05 (بعد الموعد) وساعة الحائط أُخِّرت 3 ساعات:
      // القرار من العدّاد — انتقال يتم.
      final coordinator = OfflineSessionCoordinator(
        store: store,
        bookingLedger: ledger,
        timeIntegritySource: FakeTimeIntegritySource(
          bootId: '7',
          monotonic: const Duration(hours: 5, minutes: 35),
          wallOverride: DateTime.utc(2026, 10, 8, 2),
        ),
      );
      final result = await coordinator.runCachedDueBookingTransition(
        accountId: 'account',
        wellId: 'well-local',
        cachedSchedule: fixture.cached,
        automation: fixture.automation,
        commandId: 'backwards-wall',
        localSessionId: 'backwards-local',
        scheduledCallback: true,
      );
      expect(result.outcome, LocalBookingTransitionOutcome.transitioned);
      expect(result.session?.startedLocallyAt, DateTime.utc(2026, 10, 8, 6, 5));
    });

    test(
      'no backdating: recorded started_at equals server-aligned now',
      () async {
        final fixture = await eligibleOfflineTransition();
        // جسر يقرأ بعد الموعد بخمس وثلاثين دقيقة: started_at = 06:35.
        final coordinator = OfflineSessionCoordinator(
          store: store,
          bookingLedger: ledger,
          timeIntegritySource: FakeTimeIntegritySource(
            bootId: '7',
            monotonic: const Duration(hours: 5, minutes: 35),
          ),
        );
        final result = await coordinator.runCachedDueBookingTransition(
          accountId: 'account',
          wellId: 'well-local',
          cachedSchedule: fixture.cached,
          automation: fixture.automation,
          commandId: 'late-command',
          localSessionId: 'late-local',
          scheduledCallback: true,
        );
        expect(result.outcome, LocalBookingTransitionOutcome.transitioned);
        expect(
          result.session?.startedLocallyAt,
          DateTime.utc(2026, 10, 8, 6, 5),
        );
      },
    );
  });
}

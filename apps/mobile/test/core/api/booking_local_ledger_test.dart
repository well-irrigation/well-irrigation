@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

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
    'well_id': well,
    'requested_day': day,
    'timezone': 'Asia/Aden',
    'well_timezone': 'Asia/Aden',
    'day_start': '${day}T00:00:00Z',
    'day_end': '${day}T23:59:59Z',
    'current_session': null,
    'bookings': <Object?>[],
  };

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

  test('read-only canonical receipt reconciles exact and logical matches', () async {
    Future<BookingTransitionIntent> intent(String key, String command) {
      return ledger.recordIntent(
        accountId: 'a',
        wellId: 'w',
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
    final exact = await ledger.reconcileReadResult(
      'a',
      exactIntent,
      result(requested: 'phone-a', canonical: 'phone-a', kind: 'exact_command'),
    );
    expect(exact.state, BookingIntentState.reconciled);
    expect(exact.commandId, 'phone-a');
    expect(exact.canonicalCommandId, 'phone-a');
    expect(exact.canonicalMatchKind, 'exact_command');
    expect(exact.hasCanonicalReceipt, isTrue);

    final logicalIntent = await intent('logical', 'phone-b');
    final logical = await ledger.reconcileReadResult(
      'a',
      logicalIntent,
      result(
        requested: 'phone-b',
        canonical: 'server-b',
        kind: 'logical_intent',
      ),
    );
    expect(logical.state, BookingIntentState.reconciled);
    expect(logical.commandId, 'phone-b');
    expect(logical.canonicalCommandId, 'server-b');
    expect(logical.canonicalMatchKind, 'logical_intent');
    await reopen();
    expect(
      (await ledger.loadIntent('a', 'w', 'logical'))?.canonicalCommandId,
      'server-b',
    );
    final repeated = await ledger.reconcileReadResult(
      'a',
      logical,
      result(
        requested: 'phone-b',
        canonical: 'server-b',
        kind: 'logical_intent',
      ),
    );
    expect(repeated.state, BookingIntentState.reconciled);
  });

  test('read reconciliation rejects mismatch, ambiguity, rejection and not-found', () async {
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
  });

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
}

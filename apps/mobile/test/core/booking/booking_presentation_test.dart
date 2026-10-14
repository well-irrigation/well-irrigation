import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/booking/booking_presentation.dart';
import 'package:well_irrigation_mobile/core/booking/booking_reactivity.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/session/session_segment.dart';

ActiveSessionRecord localBooking(
  String id, {
  bool closed = false,
  SessionSyncState sync = SessionSyncState.localOnly,
}) => ActiveSessionRecord(
  localId: 'local-$id',
  accountId: 'account',
  wellId: 'well',
  phoneOwned: true,
  bookingId: id,
  startedAt: DateTime.utc(2026, 10, 14, 0, id == 'A' ? 13 : 16),
  completedAt: closed
      ? DateTime.utc(2026, 10, 14, 0, id == 'A' ? 15 : 18, id == 'A' ? 4 : 0)
      : null,
  businessState: closed
      ? SessionBusinessState.completed
      : SessionBusinessState.running,
  syncState: sync,
  segments: const [],
  totals: summarize([], DateTime.utc(2026)),
  payments: const [],
  timeIntegrityFlags: const {},
  pendingCommandCount: sync == SessionSyncState.synced ? 0 : 1,
);

void main() {
  for (final entry in {
    'confirmed': 'مؤكد',
    'completed': 'منفذ',
    'cancelled': 'ملغى',
    'no_show': 'لم يُنفذ',
    'postponed': 'مؤجل',
    'pending': 'بانتظار التأكيد',
    'waiting': 'بانتظار الموعد',
    'ready': 'جاهز',
    'draft': 'مسودة غير مكتملة',
  }.entries) {
    test(
      'canonical ${entry.key}',
      () =>
          expect(presentBooking(id: 'A', status: entry.key).label, entry.value),
    );
  }
  for (final status in ['open', 'closed']) {
    test('actual $status is stronger than confirmed booking', () {
      final p = presentBooking(
        id: 'A',
        status: 'confirmed',
        session: BookingSessionSummary(
          sessionId: 's',
          status: status,
          startedAt: DateTime.utc(2026),
          endedAt: status == 'closed' ? DateTime.utc(2026, 1, 1, 1) : null,
        ),
      );
      expect(p.label, status == 'open' ? 'جاري' : 'منفذ');
      expect(p.canStart, false);
    });
  }
  test('field sequence A -> gap -> B -> completed; ACK and old snapshot cannot revert', () {
    final scope = BookingScope();
    BookingPresentation a() => presentBooking(
      id: 'A',
      status: 'confirmed',
      scope: scope,
      currentBookingId: 'A',
    );
    BookingPresentation b() =>
        presentBooking(id: 'B', status: 'confirmed', scope: scope);
    scope.project([localBooking('A')], next: 'B', localChain: true);
    expect(a().label, 'جاري');
    expect(a().canStart, false);
    expect(b().label, 'التالي');
    scope.project(
      [localBooking('A', closed: true)],
      next: 'B',
      localChain: true,
    );
    expect(a().label, 'منفذ');
    expect(a().syncLabel, 'بانتظار المزامنة');
    expect(a().isTerminal, true);
    expect(b().label, 'التالي');
    scope.project([localBooking('B')], localChain: true);
    expect(a().label, 'منفذ');
    expect(b().label, 'جاري');
    scope.project([localBooking('B', closed: true)], localChain: true);
    expect(b().label, 'منفذ');
    scope.project([localBooking('A')], localChain: true);
    expect(a().label, 'منفذ');
    scope.project([
      localBooking('A', closed: true, sync: SessionSyncState.synced),
    ], localChain: true);
    expect(a().label, 'منفذ');
    expect(a().syncLabel, isNull);
    expect(
      presentBooking(
        id: 'untouched',
        status: 'confirmed',
        scope: scope,
      ).canStart,
      true,
    );
  });
  test('comparator current, next, time, priority DESC, public code ASC independent of input', () {
    final scope = BookingScope();
    scope.project([localBooking('current')], next: 'next', localChain: true);
    final starts = {
      'current': 9,
      'next': 8,
      'late': 7,
      'low': 6,
      'B': 6,
      'A': 6,
    };
    final priorities = {'A': 2, 'B': 2, 'low': 1};
    List<String> sorted(List<String> ids) => ids
      ..sort(
        (a, b) => compareBookingPresentation(
          a: presentBooking(id: a, status: 'confirmed', scope: scope),
          b: presentBooking(id: b, status: 'confirmed', scope: scope),
          aStart: DateTime.utc(2026, 1, 1, starts[a]!),
          bStart: DateTime.utc(2026, 1, 1, starts[b]!),
          aPriority: priorities[a] ?? 0,
          bPriority: priorities[b] ?? 0,
          aCode: a,
          bCode: b,
        ),
      );
    const expected = ['current', 'next', 'A', 'B', 'low', 'late'];
    expect(sorted(starts.keys.toList()), expected);
    expect(sorted(starts.keys.toList().reversed.toList()), expected);
  });
  test('one scoped invalidation shares a fresh request and ignores an older inflight result', () async {
    final scope = BookingScope();
    final old = Completer<int>();
    var calls = 0;
    final first = scope.read('schedule', () {
      calls++;
      return old.future;
    });
    scope.mutation(days: {'2026-10-14'});
    final second = scope.read('schedule', () async {
      calls++;
      return 2;
    });
    final third = scope.read('schedule', () async {
      calls++;
      return 3;
    });
    old.complete(1);
    expect(await first, 2);
    expect(await second, 2);
    expect(await third, 2);
    expect(calls, 2);
    expect(scope.affects(DateTime(2026, 10, 13)), false);
  });
  test(
    'local projection scopes affected days and ignores unchanged ticker facts',
    () {
      final scope = BookingScope();
      var events = 0;
      scope.addListener(() => events++);
      scope.project([localBooking('A')]);
      expect(scope.affects(DateTime(2026, 10, 14)), true);
      expect(scope.affects(DateTime(2026, 10, 13)), false);
      scope.project([localBooking('A')]);
      expect(events, 1);
    },
  );
  test('another well and another account receive no event', () {
    final hub = BookingReactivity.instance;
    var same = 0;
    var other = 0;
    hub.scope('scope-test', 'well').addListener(() => same++);
    hub.scope('scope-test', 'other').addListener(() => other++);
    hub.scope('other', 'well').addListener(() => other++);
    hub.scope('scope-test', 'well').mutation(days: {'2026-10-14'});
    expect(same, 1);
    expect(other, 0);
  });
}

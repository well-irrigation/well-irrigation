import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/background_sync_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/background_sync_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import 'fake_background_sync_scheduler.dart';

final epoch = DateTime.utc(2027, 1, 1);
CommandEnvelope booking(int i, {String account = 'a', String? well, CommandType type = CommandType.createBooking}) => CommandEnvelope(
  localId: '$account-local-$i', commandId: '$account-command-$i', type: type,
  accountId: account, sequence: i, occurredAt: epoch, createdLocalAt: epoch,
  wellId: well ?? 'well-$i', payload: type == CommandType.createBooking ? {
    'p_well_id': well ?? 'well-$i', 'p_farmer_well_account_id': 'farmer', 'p_farm_id': 'farm',
    'p_scheduled_start': '2027-01-01T07:00:00.000Z', 'p_scheduled_end': '2027-01-01T08:00:00.000Z',
    'p_expected_energy_source': 'well_diesel', 'p_alternative_energy_source': null,
    'p_priority': 0, 'p_notes': 'الأصل',
  } : {'p_well_id': well ?? 'well-$i', 'p_full_name': 'أحمد'},
);
DispatchResult accepted(DispatchRequest r) => normalizeAcceptedResponse(r.type, {
  'status': 'confirmed', 'booking_id': 'booking-${r.commandId}', 'public_code': 'B-${r.commandId}',
  'well_id': r.arguments['p_well_id'], 'scheduled_start': r.arguments['p_scheduled_start'],
  'scheduled_end': r.arguments['p_scheduled_end'],
});
class Transport implements CommandTransport {
  Transport(this.send);
  final Future<DispatchResult> Function(DispatchRequest) send;
  final requests = <DispatchRequest>[];
  @override
  Future<DispatchResult> dispatch(DispatchRequest r) { requests.add(r); return send(r); }
}
Future<void> flush() async { for (var i = 0; i < 30; i++) { await Future<void>.delayed(Duration.zero); } }

void main() {
  test('booking create has its own transport command family', () {
    expect(CommandType.values.map((type) => type.rpcName), contains('create_booking'));
  });
  test('deterministic jitter adds 0..25 percent and distributes command/attempt inputs', () {
    const policy = BackgroundSyncPolicy();
    final offsets = <int>{};
    for (var attempt = 1; attempt <= 12; attempt++) {
      final base = policy.delayForAttempt(attempt).inMicroseconds;
      for (var i = 0; i < 20; i++) {
        final delay = policy.bookingCreateDelay('command-$i', attempt).inMicroseconds;
        expect(delay, inInclusiveRange(base, base + base ~/ 4));
        expect(delay, policy.bookingCreateDelay('command-$i', attempt).inMicroseconds);
        offsets.add(delay - base);
      }
    }
    expect(offsets.length, greaterThan(30));
    expect(policy.delayForAttempt(1), const Duration(seconds: 30));
    expect(policy.delayForAttempt(2), const Duration(seconds: 60));
    expect(policy.delayForAttempt(3), const Duration(seconds: 120));
    expect(policy.delayForAttempt(20), const Duration(hours: 1));
  });
  test('bounded fetch is account/type/state/due scoped and clamps at twenty', () async {
    final store = InMemoryOutboxStore();
    for (var i = 0; i < 35; i++) { await store.insert(booking(i)); }
    await store.insert(booking(100, account: 'b'));
    await store.insert(booking(101, type: CommandType.createFarmer));
    await store.markNeedsReview('a', 'a-local-0', error: 'rule', attemptedAt: epoch);
    final rows = await store.bookingCreatesReady('a', now: epoch);
    expect(rows, hasLength(20));
    expect(rows.first.sequence, 1);
    expect(rows.every((c) => c.accountId == 'a' && c.type == CommandType.createBooking), isTrue);
    await expectLater(store.bookingCreatesReady('a', now: epoch, limit: 21), throwsArgumentError);
    expect((await store.pendingLegacyCommands('a')).map((c) => c.type), [CommandType.createFarmer]);
  });
  test('one engine pass attempts at most twenty and keeps exact payload/command IDs', () async {
    final store = InMemoryOutboxStore();
    for (var i = 0; i < 45; i++) { await store.insert(booking(i, well: 'well-${i % 5}')); }
    final transport = Transport((r) async => accepted(r));
    final engine = SyncEngine(store: store, transport: transport, clock: () => epoch);
    final report = await engine.runBookingCreates('a');
    expect(report.attempted, 20);
    expect(transport.requests, hasLength(20));
    expect(transport.requests.first.commandId, 'a-command-0');
    expect(transport.requests.first.arguments, {
      ...booking(0, well: 'well-0').payload, 'p_command_id': 'a-command-0',
    });
    expect(report.bookingNextWake, isNotNull);
    expect((await store.bookingCreatesReady('a', now: epoch)), hasLength(20));
  });
  test('same well is sequential; at most three independent well lanes are active', () async {
    final store = InMemoryOutboxStore();
    for (var i = 0; i < 20; i++) { await store.insert(booking(i, well: 'well-${i % 5}')); }
    var active = 0;
    var maxActive = 0;
    final activeWells = <String>{};
    final perWell = <String, List<String>>{};
    final transport = Transport((r) async {
      final well = r.arguments['p_well_id'] as String;
      expect(activeWells.add(well), isTrue);
      active++;
      if (active > maxActive) maxActive = active;
      perWell.putIfAbsent(well, () => []).add(r.commandId);
      await Future<void>.delayed(Duration.zero);
      active--;
      activeWells.remove(well);
      return accepted(r);
    });
    await SyncEngine(store: store, transport: transport, clock: () => epoch).runBookingCreates('a');
    expect(maxActive, 3);
    expect(perWell['well-0'], ['a-command-0', 'a-command-5', 'a-command-10', 'a-command-15']);
  });
  test('slow well cannot prevent another well completing', () async {
    final store = InMemoryOutboxStore();
    await store.insert(booking(0, well: 'slow'));
    await store.insert(booking(1, well: 'fast'));
    final gate = Completer<DispatchResult>();
    final transport = Transport((r) => r.arguments['p_well_id'] == 'slow' ? gate.future : Future.value(accepted(r)));
    final run = SyncEngine(store: store, transport: transport, clock: () => epoch).runBookingCreates('a');
    await flush();
    expect((await store.commandByLocalId('a', 'a-local-1'))!.status, CommandStatus.confirmed);
    expect((await store.commandByLocalId('a', 'a-local-0'))!.status, CommandStatus.dispatching);
    gate.complete(accepted(transport.requests.first));
    await run;
  });
  test('timeout is transient; late HTTP completion cannot fabricate local confirmation', () {
    fakeAsync((time) {
      final store = InMemoryOutboxStore();
      final gate = Completer<DispatchResult>();
      final transport = Transport((r) => gate.future);
      final engine = SyncEngine(store: store, transport: transport, clock: () => epoch.add(time.elapsed));
      SyncRunReport? report;
      CommandEnvelope? row;
      store.insert(booking(0));
      time.flushMicrotasks();
      engine.runBookingCreates('a').then((r) => report = r);
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 59));
      expect(report, isNull);
      time.elapse(const Duration(seconds: 1));
      time.flushMicrotasks();
      expect(report!.retryScheduled, 1);
      expect(report!.confirmed, 0);
      expect(report!.needsReview, 0);
      store.commandByLocalId('a', 'a-local-0').then((r) => row = r);
      time.flushMicrotasks();
      expect(row!.status, CommandStatus.pending);
      expect(row!.commandId, 'a-command-0');
      expect(row!.nextAttemptAt, isNotNull);
      // Future.timeout does NOT cancel HTTP. Completing it later has no persistence callback.
      gate.complete(accepted(transport.requests.single));
      time.flushMicrotasks();
      store.commandByLocalId('a', 'a-local-0').then((r) => row = r);
      time.flushMicrotasks();
      expect(row!.status, CommandStatus.pending);
      expect(row!.serverResponse, isNull);
    });
  });
  test('retry is gated by durable due time and uses identical command/payload', () async {
    var now = epoch;
    final store = InMemoryOutboxStore();
    await store.insert(booking(0));
    final transport = Transport((r) async => const DispatchFailed(disposition: FailureDisposition.retry, message: 'network'));
    final engine = SyncEngine(store: store, transport: transport, clock: () => now);
    await engine.runBookingCreates('a');
    final row = (await store.commandByLocalId('a', 'a-local-0'))!;
    await engine.runBookingCreates('a');
    expect(transport.requests, hasLength(1));
    now = row.nextAttemptAt!;
    await engine.runBookingCreates('a');
    expect(transport.requests, hasLength(2));
    expect(transport.requests[0].arguments, transport.requests[1].arguments);
    expect(transport.requests[0].commandId, transport.requests[1].commandId);
  });
  test('unknown/malformed responses retry; structured business results require review', () async {
    for (final raw in [null, 'unknown', {'status': 'confirmed', 'booking_id': 'x'}, {'status': 'unknown'}]) {
      final result = normalizeAcceptedResponse(CommandType.createBooking, raw) as DispatchFailed;
      expect(result.isRetryable, isTrue);
    }
    for (final status in ['conflict', 'rejected']) {
      final result = normalizeAcceptedResponse(CommandType.createBooking, {'status': status, 'reason_code': 'rule'}) as DispatchFailed;
      expect(result.disposition, FailureDisposition.review);
      expect(result.serverResponse!['status'], status);
    }
    final store = InMemoryOutboxStore();
    await store.insert(booking(0));
    final transport = Transport((r) async => const DispatchAccepted(response: {'status': 'confirmed', 'booking_id': 'fake'}, entityId: 'fake'));
    final report = await SyncEngine(store: store, transport: transport, clock: () => epoch).runBookingCreates('a');
    expect(report.confirmed, 0);
    expect(report.retryScheduled, 1);
  });
  test('foreground/background race claims a row once, including same well with multiple rows', () async {
    final store = InMemoryOutboxStore();
    await store.insert(booking(0, well: 'well'));
    await store.insert(booking(1, well: 'well'));
    final gate = Completer<DispatchResult>();
    final transport = Transport((r) => gate.future);
    final a = SyncEngine(store: store, transport: transport, clock: () => epoch);
    final b = SyncEngine(store: store, transport: transport, clock: () => epoch);
    final first = a.runBookingCreates('a');
    await flush();
    await b.runBookingCreates('a');
    expect(transport.requests, hasLength(1));
    gate.complete(const DispatchFailed(disposition: FailureDisposition.retry, message: 'network'));
    await first;
    expect((await store.commandByLocalId('a', 'a-local-1'))!.status, CommandStatus.pending);
  });
  test('worker coordinator runs booking batch only once, not five draining passes', () async {
    final store = InMemoryOutboxStore();
    for (var i = 0; i < 60; i++) { await store.insert(booking(i)); }
    final transport = Transport((r) async => accepted(r));
    final coordinator = BackgroundSyncCoordinator(engine: SyncEngine(store: store, transport: transport, clock: () => epoch), scheduler: FakeBackgroundSyncScheduler());
    final decision = await coordinator.runFromWorker('a');
    expect(transport.requests, hasLength(20));
    expect(decision.shouldRetry, isTrue);
    expect(coordinator.passesInLastRun, 1);
  });
  test('booking-only path does not dispatch another account or legacy family', () async {
    final store = InMemoryOutboxStore();
    await store.insert(booking(0));
    await store.insert(booking(1, account: 'b'));
    await store.insert(booking(2, type: CommandType.createFarmer));
    final transport = Transport((r) async => accepted(r));
    await SyncEngine(store: store, transport: transport, clock: () => epoch).runBookingCreates('a');
    expect(transport.requests.map((r) => r.commandId), ['a-command-0']);
    expect((await store.commandByLocalId('b', 'b-local-1'))!.status, CommandStatus.pending);
    expect((await store.commandByLocalId('a', 'a-local-2'))!.status, CommandStatus.pending);
  });
  test('terminal result and a newer claim cannot be overwritten by a stale completion', () async {
    final store = InMemoryOutboxStore();
    await store.insert(booking(0));
    await store.claimBookingCreate('a', 'a-local-0', attemptedAt: epoch);
    await store.finishBookingCreate('a', 'a-local-0', claimedAt: epoch, status: CommandStatus.pending, nextAttemptAt: epoch);
    final newer = epoch.add(const Duration(minutes: 3));
    await store.claimBookingCreate('a', 'a-local-0', attemptedAt: newer);
    await store.finishBookingCreate('a', 'a-local-0', claimedAt: newer, status: CommandStatus.review, response: {'status': 'rejected'});
    expect(await store.finishBookingCreate('a', 'a-local-0', claimedAt: epoch, status: CommandStatus.confirmed, response: {'status': 'confirmed'}, entityId: 'fake'), isFalse);
    expect((await store.commandByLocalId('a', 'a-local-0'))!.status, CommandStatus.review);
  });
}

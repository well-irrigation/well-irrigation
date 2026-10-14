@TestOn('vm')
library;

import 'dart:io';

import 'package:well_irrigation_mobile/core/api/operations_repository.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/time_integrity.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

import 'local_booking_transition_regression_test.dart' as f;
import '../sync/package_a_outbox_test.dart' as sync_fixture;

import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';

class LifecycleClock implements TimeIntegritySource {
  DateTime base = f.at(43);
  Duration elapsed = Duration.zero;
  Duration wallJump = Duration.zero;
  String boot = '42';
  @override
  Future<TimeReading> read() async => TimeReading(
    wallClock: base.add(elapsed + wallJump),
    monotonic: const Duration(seconds: 100) + elapsed,
    bootId: boot,
  );
}

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqliteOutboxStore store;
  late OfflineSessionCoordinator coordinator;
  late LifecycleClock clock;
  late CachedBookingSchedule cached;
  late BookingAutomationState automation;
  Future<void> open() async {
    store = SqliteOutboxStore(
      databasePath: '${dir.path}/outbox.db',
      sqfliteFactory: databaseFactoryFfi,
    );
    await store.initialize();
    coordinator = OfflineSessionCoordinator(
      store: store,
      bookingLedger: BookingLocalLedger(store),
      timeIntegritySource: clock,
    );
  }

  Future<void> start() async {
    clock.elapsed = const Duration(seconds: 23);
    await coordinator.startBookedSession(
      accountId: 'account',
      wellId: 'well',
      bookingId: 'A',
      cachedSchedule: cached,
      automation: automation,
    );
  }

  Future<BookedSessionAction?> action() =>
      coordinator.prepareBookedSessionAction(
        accountId: 'account',
        wellId: 'well',
        cachedSchedule: cached,
        automation: automation,
      );
  Future<LocalBookingTransitionResult> run({bool callback = true}) async =>
      coordinator.runBookedSessionAction(
        accountId: 'account',
        wellId: 'well',
        cachedSchedule: cached,
        automation: automation,
        action: (await action())!,
        scheduledCallback: callback,
      );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('booked-lifecycle-');
    clock = LifecycleClock();
    automation = f.automation();
    final base = f.fieldSchedule();
    cached = f.cached(
      WellDaySchedule(
        wellId: 'well',
        requestedDay: base.requestedDay,
        serverTime: base.serverTime,
        timezone: base.timezone,
        wellTimezone: base.wellTimezone,
        dayStart: base.dayStart,
        dayEnd: base.dayEnd,
        bookings: [
          f.booking('A', 43, duration: 4),
          f.booking('B', 48, duration: 3),
        ],
      ),
    );
    await open();
  });
  tearDown(() async {
    coordinator.dispose();
    await store.close();
    await dir.delete(recursive: true);
  });
  test(
    'manual start is durable locally before ACK with exact RPC-only args',
    () async {
      await start();
      final first = (await store.allCommands('account')).single;
      expect(first.type, CommandType.startBookingSession);
      expect(first.payload, {'p_booking_id': 'A', 'p_crops': <String>[]});
      expect(first.localContext['expected_duration_minutes'], 4);
      expect(coordinator.currentActiveSession?.phoneOwned, isTrue);
      expect(
        coordinator.currentActiveSession?.startedAt,
        f.at(43).add(const Duration(seconds: 23)),
      );
      expect(coordinator.currentActiveSession?.serverSessionId, isNull);
      expect(coordinator.currentActiveSession?.totals.billableSeconds, 0);
      await start();
      expect(await store.allCommands('account'), hasLength(1));
      coordinator.dispose();
      await store.close();
      await open();
      final restored = await coordinator.projectActiveSession(
        accountId: 'account',
        wellId: 'well',
      );
      expect(restored?.localId, first.localId);
      expect(restored?.startedAt, first.occurredAt);
    },
  );
  test(
    'pump identity survives gap automatic start SQLite restart and ACK',
    () async {
      await coordinator.cacheBookingPumps('account', 'well', const [
        Pump(
          id: 'pump',
          wellId: 'well',
          name: 'المضخة الشرقية',
          publicCode: 'P',
        ),
      ]);
      await start();
      expect(coordinator.currentActiveSession?.pumpId, 'pump');
      expect(coordinator.currentActiveSession?.pumpName, 'المضخة الشرقية');
      clock.elapsed = const Duration(minutes: 4, seconds: 23);
      await run();
      coordinator.dispose();
      await store.close();
      await open();
      clock.elapsed = const Duration(minutes: 5);
      await run();
      final b = coordinator.currentActiveSession!;
      expect(b.bookingId, 'B');
      expect(b.pumpId, 'pump');
      expect(b.pumpName, 'المضخة الشرقية');
      final command = (await store.allCommands('account'))
          .singleWhere((c) => c.localId == b.localId);
      expect(command.payload, {'p_booking_id': 'B', 'p_crops': <String>[]});
      await store.markConfirmed(
        'account',
        command.localId,
        serverResponse: {'session_id': 'server-B'},
        attemptedAt: clock.base.add(clock.elapsed),
      );
      coordinator.dispose();
      await store.close();
      await open();
      final restored = await coordinator.freshProjectActiveSession(
        accountId: 'account',
        wellId: 'well',
      );
      expect(restored?.pumpId, 'pump');
      expect(restored?.pumpName, 'المضخة الشرقية');
    },
  );
  test('real field: actual+4m closes A, idle gap, trusted B start, final+3m closes B', () async {
    await start();
    expect((await action())?.dueAt, f.at(47).add(const Duration(seconds: 23)));
    clock.elapsed = const Duration(minutes: 4, seconds: 23);
    await run();
    expect(coordinator.currentActiveSession, isNull);
    var rows = await store.allCommands('account');
    expect(rows.map((r) => r.type), [
      CommandType.startBookingSession,
      CommandType.completeIrrigationSession,
    ]);
    expect(rows.last.occurredAt, f.at(47).add(const Duration(seconds: 23)));
    expect((await action())?.dueAt, f.at(48));
    expect((await run()).outcome, LocalBookingTransitionOutcome.notDue);
    coordinator.dispose();
    await store.close();
    await open();
    expect((await action())?.dueAt, f.at(48));
    clock.elapsed = const Duration(minutes: 5);
    final armed = (await action())!;
    await run();
    await coordinator.runBookedSessionAction(
      accountId: 'account',
      wellId: 'well',
      cachedSchedule: cached,
      automation: automation,
      action: armed,
      scheduledCallback: true,
    );
    rows = await store.allCommands('account');
    expect(rows, hasLength(3));
    expect(rows.last.prerequisites, [rows[1].localId]);
    expect(coordinator.currentActiveSession?.bookingId, 'B');
    expect((await action())?.dueAt, f.at(51));
    clock.elapsed = const Duration(minutes: 8);
    final finalAction = (await action())!;
    await run();
    await coordinator.runBookedSessionAction(
      accountId: 'account',
      wellId: 'well',
      cachedSchedule: cached,
      automation: automation,
      action: finalAction,
      scheduledCallback: true,
    );
    expect(coordinator.currentActiveSession, isNull);
    rows = await store.allCommands('account');
    expect(rows, hasLength(5));
    expect(rows[3].type, CommandType.completeIrrigationSession);
    expect(rows[4].type, CommandType.endBookingTransitionChain);
    expect(rows[4].prerequisites, [rows[3].localId]);
    expect(rows.last.occurredAt, f.at(51));
    coordinator.dispose();
    await store.close();
    await open();
    expect(await action(), isNull);
    expect(await store.allCommands('account'), hasLength(5));
  });
  test(
    'due next booking starts atomically at same actual completion instant',
    () async {
      final base = cached.schedule;
      cached = f.cached(
        WellDaySchedule(
          wellId: 'well',
          requestedDay: base.requestedDay,
          serverTime: base.serverTime,
          timezone: base.timezone,
          wellTimezone: base.wellTimezone,
          dayStart: base.dayStart,
          dayEnd: base.dayEnd,
          bookings: [f.booking('A', 43), f.booking('B', 44, duration: 3)],
        ),
      );
      await start();
      clock.elapsed = const Duration(minutes: 4, seconds: 23);
      await run();
      final rows = await store.allCommands('account');
      expect(rows, hasLength(3));
      expect(rows[1].occurredAt, rows[2].occurredAt);
      expect(rows[2].prerequisites, [rows[1].localId]);
    },
  );
  test('OFF allows explicit manual start and leaves it live without automatic actions', () async {
    automation = const BookingAutomationState(
      wellId: 'well',
      enabled: false,
      revision: 1,
      settingsRowExists: true,
      firstSession: 'manual',
    );
    await start();
    clock.elapsed = const Duration(minutes: 10);
    expect(await action(), isNull);
    expect(coordinator.currentActiveSession?.bookingId, 'A');
    expect(await store.allCommands('account'), hasLength(1));
  });
  test('OFF after timer arm invalidates close', () async {
    await start();
    final armed = (await action())!;
    automation = const BookingAutomationState(
      wellId: 'well',
      enabled: false,
      revision: 2,
      settingsRowExists: true,
      firstSession: 'manual',
    );
    clock.elapsed = const Duration(minutes: 4, seconds: 23);
    expect(
      (await coordinator.runBookedSessionAction(
        accountId: 'account',
        wellId: 'well',
        cachedSchedule: cached,
        automation: automation,
        action: armed,
        scheduledCallback: true,
      )).transitioned,
      isFalse,
    );
    expect(await store.allCommands('account'), hasLength(1));
    expect(coordinator.currentActiveSession, isNotNull);
  });
  for (final stage in ['close', 'gap']) {
    test(
      'restart after missed $stage requires review with no backdated command',
      () async {
        await start();
        if (stage == 'gap') {
          clock.elapsed = const Duration(minutes: 4, seconds: 23);
          await run();
        }
        coordinator.dispose();
        await store.close();
        await open();
        clock.elapsed = const Duration(minutes: 6);
        final before = (await store.allCommands('account')).length;
        expect(
          (await run(callback: false)).outcome,
          LocalBookingTransitionOutcome.missedRequiresReview,
        );
        expect(await store.allCommands('account'), hasLength(before));
      },
    );
  }
  test(
    'known review or missing completion fails closed before gap start',
    () async {
      await start();
      clock.elapsed = const Duration(minutes: 4, seconds: 23);
      await run();
      final complete = (await store.allCommands('account')).last;
      await store.markNeedsReview(
        'account',
        complete.localId,
        error: 'conflict',
        attemptedAt: f.at(47),
      );
      clock.elapsed = const Duration(minutes: 5);
      await expectLater(action(), throwsStateError);
      expect(await store.allCommands('account'), hasLength(2));
      expect(coordinator.currentActiveSession, isNull);
    },
  );
  test('invalid anchor/boot cannot authorize automatic writes', () async {
    await start();
    final armed = (await action())!;
    clock.boot = 'reboot';
    clock.elapsed = const Duration(minutes: 5);
    final result = await coordinator.runBookedSessionAction(
      accountId: 'account',
      wellId: 'well',
      cachedSchedule: cached,
      automation: automation,
      action: armed,
      scheduledCallback: true,
    );
    expect(
      result.outcome,
      LocalBookingTransitionOutcome.timeIntegrityRequiresReview,
    );
    expect(await store.allCommands('account'), hasLength(1));
  });
  test('wall clock jump cannot move operational end', () async {
    await start();
    clock.wallJump = const Duration(days: 4);
    clock.elapsed = const Duration(minutes: 4, seconds: 23);
    await run();
    expect(
      (await store.allCommands('account')).last.occurredAt,
      f.at(47).add(const Duration(seconds: 23)),
    );
  });
  test('idle well never gets an automatic first booking action', () async {
    expect(await action(), isNull);
    expect(await store.allCommands('account'), isEmpty);
  });
  test(
    'manual booked timer and normal pricing use the stored monotonic anchor',
    () async {
      coordinator.updatePricing([
        PricingSnapshot(
          hourlyRateMinor: 3600,
          effectiveFrom: f.at(40),
          energySource: 'well_diesel',
        ),
      ]);
      await start();
      clock.elapsed = const Duration(minutes: 1, seconds: 23);
      clock.wallJump = const Duration(days: 10);
      final active = await coordinator.projectActiveSession(
        accountId: 'account',
        wellId: 'well',
      );
      expect(active?.totals.billableSeconds, 60);
      expect(active?.totals.accruedMinor, 60);
      expect(active?.currentEnergySource, 'well_diesel');
    },
  );
  for (final mode in ['missing', 'corrupt']) {
    test(
      '$mode gap completion prerequisite cannot authorize another local start',
      () async {
        await start();
        clock.elapsed = const Duration(minutes: 4, seconds: 23);
        await run();
        final complete = (await store.allCommands('account')).last;
        final db = await databaseFactoryFfi.openDatabase(
          '${dir.path}/outbox.db',
        );
        if (mode == 'missing') {
          await db.delete(
            'outbox_commands',
            where: 'local_id=?',
            whereArgs: [complete.localId],
          );
        } else {
          await db.update(
            'outbox_commands',
            {'command_id': 'corrupt'},
            where: 'local_id=?',
            whereArgs: [complete.localId],
          );
        }
        clock.elapsed = const Duration(minutes: 5);
        await expectLater(action(), throwsStateError);
        expect(coordinator.currentActiveSession, isNull);
      },
    );
  }
  test(
    'offline gap B operates locally while retry blocks its server dispatch',
    () async {
      await start();
      clock.elapsed = const Duration(minutes: 4, seconds: 23);
      await run();
      clock.elapsed = const Duration(minutes: 5);
      await run();
      final commands = await store.allCommands('account');
      final transport = sync_fixture.PackageTransport();
      transport.completionResult = const DispatchFailed(
        disposition: FailureDisposition.retry,
        message: 'offline',
      );
      final engine = SyncEngine(store: store, transport: transport);
      await engine.run('account');
      expect(
        transport.requests.any((r) => r.commandId == commands[2].commandId),
        isFalse,
      );
      expect(coordinator.currentActiveSession?.bookingId, 'B');
      transport.completionResult = null;
      // The retry deadline is advanced by the engine's injected clock.
      await SyncEngine(
        store: store,
        transport: transport,
        clock: () => DateTime.utc(2030),
      ).run('account');
      expect(
        transport.requests.any((r) => r.commandId == commands[2].commandId),
        isTrue,
      );
      final before = transport.requests.length;
      await engine.run('account');
      expect(transport.requests, hasLength(before));
      expect(
        (await store.mapping(
          'account',
          commands[2].localId,
          EntityKind.session,
        ))?.serverId,
        'server-B',
      );
      final restored = await coordinator.projectActiveSession(
        accountId: 'account',
        wellId: 'well',
      );
      expect(restored?.localId, commands[2].localId);
      expect(restored?.startedAt, f.at(48));
    },
  );
  test('transaction invalidation rolls back commands and lifecycle pointer together', () async {
    await start();
    clock.elapsed = const Duration(minutes: 4, seconds: 23);
    final before = await store.readLocalValue(
      'account',
      BookingLocalLedger.bookedLifecycleKey('well'),
    );
    final command = sync_fixture.command(
      'atomic-complete',
      CommandType.completeIrrigationSession,
      99,
    );
    var calls = 0;
    await expectLater(
      store.insertBundle(
        accountId: 'account',
        key: 'atomic-close',
        value: 'event',
        commands: [command],
        localValues: {BookingLocalLedger.bookedLifecycleKey('well'): 'changed'},
        isCurrent: () => ++calls == 1,
      ),
      throwsStateError,
    );
    expect(await store.readBundle('account', 'atomic-close'), isNull);
    expect(
      await store.readLocalValue(
        'account',
        BookingLocalLedger.bookedLifecycleKey('well'),
      ),
      before,
    );
    expect(await store.allCommands('account'), hasLength(1));
  });
  test(
    'field regression in Aden: 00:00:23 -> 00:04:23, gap, 00:05 -> 00:08',
    () async {
      clock.base = DateTime.utc(2026, 10, 13, 21);
      BookingDayItem item(String id, int minute, int duration) =>
          BookingDayItem(
            id: id,
            publicCode: id,
            wellId: 'well',
            farmerWellAccountId: 'farmer',
            farmId: 'farm',
            expectedEnergySource: 'well_diesel',
            scheduledStart: clock.base.add(Duration(minutes: minute)),
            scheduledEnd: clock.base.add(Duration(minutes: minute + duration)),
            scheduledDay: '2026-10-14',
            expectedDurationMinutes: duration,
            status: 'confirmed',
            priority: 0,
            statusGroup: 'active',
          );
      cached = CachedBookingSchedule(
        WellDaySchedule(
          wellId: 'well',
          requestedDay: DateTime.utc(2026, 10, 14),
          serverTime: clock.base,
          timezone: 'Asia/Aden',
          wellTimezone: 'Asia/Aden',
          dayStart: clock.base,
          dayEnd: clock.base.add(const Duration(days: 1)),
          bookings: [item('A', 0, 4), item('B', 5, 3)],
        ),
        clock.base,
        timeAnchor: SessionTimeAnchor(
          serverTime: clock.base,
          wallClock: clock.base,
          monotonic: const Duration(seconds: 100),
          bootId: '42',
        ),
      );
      await start();
      expect(
        coordinator.currentActiveSession?.startedAt,
        DateTime.utc(2026, 10, 13, 21, 0, 23),
      );
      expect((await action())?.dueAt, DateTime.utc(2026, 10, 13, 21, 4, 23));
      clock.elapsed = const Duration(minutes: 4, seconds: 23);
      await run();
      expect(coordinator.currentActiveSession, isNull);
      expect(
        (await store.allCommands('account')).last.occurredAt,
        DateTime.utc(2026, 10, 13, 21, 4, 23),
      );
      clock.elapsed = const Duration(minutes: 5);
      await run();
      expect(
        coordinator.currentActiveSession?.startedAt,
        DateTime.utc(2026, 10, 13, 21, 5),
      );
      expect((await action())?.dueAt, DateTime.utc(2026, 10, 13, 21, 8));
      clock.elapsed = const Duration(minutes: 8);
      await run();
      final commands = await store.allCommands('account');
      expect(commands, hasLength(5));
      expect(commands.last.occurredAt, DateTime.utc(2026, 10, 13, 21, 8));
      expect(coordinator.currentActiveSession, isNull);
    },
  );
  test(
    'ACK mapping arriving during the gap preserves its predecessor identity',
    () async {
      await start();
      final root = (await store.allCommands('account')).single;
      clock.elapsed = const Duration(minutes: 4, seconds: 23);
      await run();
      await store.putMapping(
        'account',
        IdMapping(
          localId: root.localId,
          kind: EntityKind.session,
          serverId: 'server-A',
          resolvedAt: f.at(47),
        ),
      );
      final old = cached.schedule;
      cached = f.cached(
        WellDaySchedule(
          wellId: old.wellId,
          requestedDay: old.requestedDay,
          serverTime: old.serverTime,
          timezone: old.timezone,
          wellTimezone: old.wellTimezone,
          dayStart: old.dayStart,
          dayEnd: old.dayEnd,
          bookings: old.bookings,
          currentSession: CurrentBookingSession(
            sessionId: 'server-A',
            status: 'open',
            startedAt: root.occurredAt,
            wellId: 'well',
            bookingId: 'A',
          ),
        ),
      );
      clock.elapsed = const Duration(minutes: 5);
      await run();
      expect(coordinator.currentActiveSession?.bookingId, 'B');
      expect((await action())?.dueAt, f.at(51));
      expect(await store.allCommands('account'), hasLength(3));
    },
  );
  test('final end-chain rejection retains closed facts and durable review across restart', () async {
    await start();
    clock.elapsed = const Duration(minutes: 4, seconds: 23);
    await run();
    expect(
      (await store.allCommands('account'))
          .where((c) => c.type == CommandType.endBookingTransitionChain),
      isEmpty,
    );
    clock.elapsed = const Duration(minutes: 5);
    await run();
    clock.elapsed = const Duration(minutes: 8);
    await run();
    final commands = await store.allCommands('account');
    final end = commands.last;
    final complete = commands[commands.length - 2];
    expect(end.type, CommandType.endBookingTransitionChain);
    expect(end.prerequisites, [complete.localId]);
    expect(end.payload, complete.payload);
    expect(coordinator.currentActiveSession, isNull);
    final before = await BookingLocalLedger.loadBookedLifecycle(
      store,
      'account',
      'well',
    );
    expect(before?['server_chain_state'], 'pending');
    await store.markNeedsReview(
      'account',
      end.localId,
      error: 'next_booking_exists',
      attemptedAt: f.at(51),
      serverResponse: {
        'contract': 'end_booking_transition_chain',
        'version': 1,
        'status': 'rejected',
        'reason_code': 'next_booking_exists',
      },
    );
    coordinator.dispose();
    await store.close();
    await open();
    final restored = await BookingLocalLedger.loadBookedLifecycle(
      store,
      'account',
      'well',
    );
    expect(restored?['state'], 'requires_review');
    expect(restored?['review_reason'], 'next_booking_exists');
    expect(
      await coordinator.projectActiveSession(
        accountId: 'account',
        wellId: 'well',
      ),
      isNull,
    );
    expect(
      (await store.allCommands('account')).map((c) => c.commandId),
      commands.map((c) => c.commandId),
    );
    automation = const BookingAutomationState(
      wellId: 'well',
      enabled: false,
      revision: 2,
      settingsRowExists: true,
      firstSession: 'manual',
    );
    await expectLater(action(), throwsStateError);
  });
  test(
    'ordinary manual completion never creates an end-chain command',
    () async {
      await start();
      await coordinator.completeSession(
        accountId: 'account',
        sessionLocalId: coordinator.currentActiveSession!.localId,
        completedAt: f.at(44),
      );
      expect((await store.allCommands('account')).map((c) => c.type), [
        CommandType.startBookingSession,
        CommandType.completeIrrigationSession,
      ]);
    },
  );

  test('final-close transaction rollback leaves neither completion nor end-chain visible', () async {
    await start();
    clock.elapsed = const Duration(minutes: 4, seconds: 23);
    await run();
    clock.elapsed = const Duration(minutes: 5);
    await run();
    final before = await store.allCommands('account');
    final pointer = await store.readLocalValue(
      'account',
      BookingLocalLedger.bookedLifecycleKey('well'),
    );
    clock.elapsed = const Duration(minutes: 8);
    final armed = (await action())!;
    var checks = 0;
    await expectLater(
      coordinator.runBookedSessionAction(
        accountId: 'account',
        wellId: 'well',
        cachedSchedule: cached,
        automation: automation,
        action: armed,
        scheduledCallback: true,
        isCurrent: () => ++checks < 4,
      ),
      throwsStateError,
    );
    expect(
      (await store.allCommands('account')).map((c) => c.commandId),
      before.map((c) => c.commandId),
    );
    expect(
      await store.readLocalValue(
        'account',
        BookingLocalLedger.bookedLifecycleKey('well'),
      ),
      pointer,
    );
    expect(coordinator.currentActiveSession?.bookingId, 'B');
    await run();
    expect((await store.allCommands('account')).map((c) => c.type), [
      CommandType.startBookingSession,
      CommandType.completeIrrigationSession,
      CommandType.startBookingSession,
      CommandType.completeIrrigationSession,
      CommandType.endBookingTransitionChain,
    ]);
  });
  test('known later confirmed booking with incomplete context is not treated as final', () async {
    final old = cached.schedule;
    cached = f.cached(
      WellDaySchedule(
        wellId: old.wellId,
        requestedDay: old.requestedDay,
        serverTime: old.serverTime,
        timezone: old.timezone,
        wellTimezone: old.wellTimezone,
        dayStart: old.dayStart,
        dayEnd: old.dayEnd,
        bookings: [
          f.booking('A', 43),
          BookingDayItem(
            id: 'B',
            publicCode: 'B',
            wellId: 'well',
            farmerWellAccountId: 'farmer',
            scheduledStart: f.at(48),
            scheduledEnd: f.at(51),
            scheduledDay: '2026-10-08',
            expectedDurationMinutes: 3,
            expectedEnergySource: 'well_diesel',
            status: 'confirmed',
            priority: 0,
            statusGroup: 'active',
          ),
        ],
      ),
    );
    await start();
    clock.elapsed = const Duration(minutes: 4, seconds: 23);
    await run();
    expect((await store.allCommands('account')).map((c) => c.type), [
      CommandType.startBookingSession,
      CommandType.completeIrrigationSession,
    ]);
    expect(coordinator.currentActiveSession, isNull);
    final state = await BookingLocalLedger.loadBookedLifecycle(
      store,
      'account',
      'well',
    );
    expect(state?['state'], 'requires_review');
    expect(state?['review_reason'], 'next_booking_not_executable');
  });
}

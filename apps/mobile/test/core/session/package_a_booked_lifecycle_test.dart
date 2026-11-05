@TestOn('vm')
library;

import 'dart:io';
import 'dart:convert';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';

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
    // Historical serialized lifecycle fixture: current production no longer creates it.
    final key = 'booking.manual_start.v1.well.A';
    if (await store.readBundle('account',key) == null) {
      final booking = cached.schedule.bookings.firstWhere((b)=>b.id=='A');
      final at = clock.base.add(clock.elapsed);
      final pumps = await store.readBundle('account','booking.pumps.v1.well');
      final pump = pumps == null ? null : (jsonDecode(pumps) as List).singleOrNull as Map?;
      final anchor = cached.timeAnchor!;
      final command = CommandEnvelope(localId:'historical-start',commandId:'historical-command',accountId:'account',wellId:'well',type:CommandType.startBookingSession,sequence:await store.nextSequence('account'),occurredAt:at,createdLocalAt:at,
        payload:{'p_booking_id':'A','p_crops':<String>[]},localContext:{
          'booking_id':'A','manual_start':true,'chain_id':automation.activeChainId,
          'decision_revision':automation.activeChainDecisionRevision,'automation_revision':automation.revision,
          'p_farm_id':booking.farmId,'p_farmer_well_account_id':booking.farmerWellAccountId,
          'p_energy_source':booking.expectedEnergySource,'alternative_energy_source':booking.alternativeEnergySource,
          'farmer_name':booking.farmerName,'farm_name':booking.farmName,'public_code':booking.publicCode,
          'expected_duration_minutes':booking.expectedDurationMinutes,
          'scheduled_start':booking.scheduledStart.toUtc().toIso8601String(),
          'scheduled_end':booking.scheduledEnd.toUtc().toIso8601String(),
          'consumed_booking_ids':<String>[],
          if(pump!=null) 'p_pump_id':pump['id'], if(pump!=null) 'pump_name':pump['name'],
          'trusted_time_anchor':{'server_time':anchor.serverTime!.toUtc().toIso8601String(),
          'wall_clock':anchor.wallClock.toUtc().toIso8601String(),'monotonic_us':anchor.monotonic.inMicroseconds,'boot_id':anchor.bootId}});
      await store.insertBundle(accountId:'account',key:key,value:jsonEncode({'start_local_id':command.localId,'start_command_id':command.commandId}),commands:[command],localValues:{BookingLocalLedger.bookedLifecycleKey('well'):jsonEncode({'version':1,'provenance':'phone_owned_booked_lifecycle','well_id':'well','state':'running','start_local_id':command.localId,'start_command_id':command.commandId,'automation_revision':automation.revision,'chain_id':automation.activeChainId,'decision_revision':automation.activeChainDecisionRevision})});
    }
    await coordinator.projectActiveSession(accountId:'account',wellId:'well');
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
  Future<void> expectPendingStop({bool reopen = false}) async {
    final original = coordinator.currentActiveSession!;
    clock.elapsed = const Duration(minutes: 4, seconds: 23);
    await run();
    final commands = await store.allCommands('account');
    expect(commands.map((c) => c.type), [
      CommandType.startBookingSession,
      CommandType.completeIrrigationSession,
    ]);
    expect(commands.last.aggregateLocalId, original.localId);
    expect(commands.last.payload['p_session_id'], {
      r'$ref': original.localId,
      r'$kind': 'session',
    });
    if (reopen) {
      coordinator.dispose();
      await store.close();
      await open();
    }
    final active = await coordinator.freshProjectActiveSession(
      accountId: 'account',
      wellId: 'well',
    );
    expect(active?.localId, original.localId);
    expect(active?.completedAt, isNull);
    expect(active?.approvedAmountMinor, isNull);
    clock.elapsed = const Duration(minutes: 5);
    await expectLater(action(), throwsStateError);
    expect(
      (await store.allCommands('account')).map((c) => c.commandId),
      commands.map((c) => c.commandId),
    );
  }

  test(
    'pending stop keeps original occupied and emits no accepted completion',
    () async {
      final results = <Object>[];
      final subscription = coordinator.completionResultStream.listen(
        results.add,
      );
      await start();
      await expectPendingStop();
      await Future<void>.delayed(Duration.zero);
      expect(results, isEmpty);
      await subscription.cancel();
    },
  );

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
  test('pump identity survives pending stop and SQLite restart', () async {
    await coordinator.cacheBookingPumps('account', 'well', const [
      Pump(id: 'pump', wellId: 'well', name: 'المضخة الشرقية', publicCode: 'P'),
    ]);
    await start();
    await expectPendingStop(reopen: true);
    expect(coordinator.currentActiveSession?.pumpId, 'pump');
    expect(coordinator.currentActiveSession?.pumpName, 'المضخة الشرقية');
  });
  test(
    'scheduled boundary cannot declare completion or start a successor',
    () async {
      await start();
      expect(
        (await action())?.dueAt,
        f.at(47).add(const Duration(seconds: 23)),
      );
      await expectPendingStop(reopen: true);
      expect(coordinator.currentActiveSession?.bookingId, 'A');
    },
  );
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
          stage == 'gap'
              ? await action().then((_) => false, onError: (_) => true)
              : (await run(callback: false)).outcome,
          stage == 'gap'
              ? true
              : LocalBookingTransitionOutcome.missedRequiresReview,
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
      final original = coordinator.currentActiveSession!;
      final complete = await coordinator.completeSession(
        accountId: 'account',
        sessionLocalId: original.localId,
        completedAt: clock.base.add(clock.elapsed),
      );
      await store.markNeedsReview(
        'account',
        complete.localId,
        error: 'conflict',
        attemptedAt: f.at(47),
      );
      clock.elapsed = const Duration(minutes: 5);
      final before = await store.allCommands('account');
      await expectLater(
        coordinator.startBookedSession(
          accountId: 'account',
          wellId: 'well',
          bookingId: 'B',
          cachedSchedule: cached,
          automation: automation,
        ),
        throwsStateError,
      );
      final active = coordinator.currentActiveSession!;
      expect(active.localId, original.localId);
      expect(active.businessState.isActive, isTrue);
      expect(active.completedAt, isNull);
      expect(active.approvedAmountMinor, isNull);
      expect(await store.allCommands('account'), hasLength(2));
      expect(
        (await store.allCommands('account')).map(dispatchCommandFingerprint),
        before.map(dispatchCommandFingerprint),
      );
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
        final original = coordinator.currentActiveSession!;
        final complete = await coordinator.completeSession(
          accountId: 'account',
          sessionLocalId: original.localId,
          completedAt: clock.base.add(clock.elapsed),
        );
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
        final before = await store.allCommands('account');
        await expectLater(
          coordinator.startBookedSession(
            accountId: 'account',
            wellId: 'well',
            bookingId: 'B',
            cachedSchedule: cached,
            automation: automation,
          ),
          throwsStateError,
        );
        final active = coordinator.currentActiveSession!;
        expect(active.localId, original.localId);
        expect(active.businessState.isActive, isTrue);
        expect(active.completedAt, isNull);
        expect(active.approvedAmountMinor, isNull);
        expect(
          (await store.allCommands('account')).map(dispatchCommandFingerprint),
          before.map(dispatchCommandFingerprint),
        );
      },
    );
  }
  test(
    'legacy callback stop has no human authority to dispatch or free the well',
    () async {
      await start();
      await expectPendingStop();
      final transport = sync_fixture.PackageTransport();
      final engine = SyncEngine(store: store, transport: transport);
      await engine.run('account');
      await engine.run('account');
      expect(
        transport.requests.where(
          (r) => r.type == CommandType.completeIrrigationSession,
        ),
        isEmpty,
      );
      expect(
        (await coordinator.freshProjectActiveSession(
          accountId: 'account',
          wellId: 'well',
        ))?.completedAt,
        isNull,
      );
      expect(await store.allCommands('account'), hasLength(2));
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
      expect(coordinator.currentActiveSession?.bookingId, 'A');
      expect(coordinator.currentActiveSession?.completedAt, isNull);
      expect(
        (await store.allCommands('account')).last.occurredAt,
        DateTime.utc(2026, 10, 13, 21, 4, 23),
      );
      clock.elapsed = const Duration(minutes: 5);
      await expectLater(action(), throwsStateError);
      expect(await store.allCommands('account'), hasLength(2));
    },
  );
  test(
    'start ACK during pending stop does not fabricate completion or start B',
    () async {
      await start();
      final root = (await store.allCommands('account')).single;
      await expectPendingStop();
      await store.putMapping(
        'account',
        IdMapping(
          localId: root.localId,
          kind: EntityKind.session,
          serverId: 'server-A',
          resolvedAt: f.at(47),
        ),
      );
      final restored = await coordinator.freshProjectActiveSession(
        accountId: 'account',
        wellId: 'well',
      );
      expect(restored?.localId, root.localId);
      expect(restored?.serverSessionId, 'server-A');
      expect(restored?.completedAt, isNull);
      await expectLater(action(), throwsStateError);
    },
  );
  test('pending closure never manufactures final end-chain evidence across restart', () async {
    await start();
    await expectPendingStop(reopen: true);
    expect(
      (await store.allCommands('account'))
          .where((c) => c.type == CommandType.endBookingTransitionChain),
      isEmpty,
    );
    expect(coordinator.currentActiveSession?.bookingId, 'A');
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

  test(
    'invalidated callback preserves commands and lifecycle pointer',
    () async {
      await start();
      clock.elapsed = const Duration(minutes: 4, seconds: 23);
      final before = await store.allCommands('account');
      final pointer = await store.readLocalValue(
        'account',
        BookingLocalLedger.bookedLifecycleKey('well'),
      );
      final result = await coordinator.runBookedSessionAction(
        accountId: 'account',
        wellId: 'well',
        cachedSchedule: cached,
        automation: automation,
        action: (await action())!,
        scheduledCallback: true,
        isCurrent: () => false,
      );
      expect(result.outcome, LocalBookingTransitionOutcome.blocked);
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
      expect(coordinator.currentActiveSession?.bookingId, 'A');
    },
  );
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
    expect(coordinator.currentActiveSession?.bookingId, 'A');
    expect(coordinator.currentActiveSession?.completedAt, isNull);
    final state = await BookingLocalLedger.loadBookedLifecycle(
      store,
      'account',
      'well',
    );
    expect(state?['state'], 'requires_review');
    expect(state?['review_reason'], 'next_booking_not_executable');
  });
}

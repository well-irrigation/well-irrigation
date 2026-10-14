@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

import 'local_booking_transition_regression_test.dart' as f;

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late SqliteOutboxStore store;
  late BookingLocalLedger ledger;
  late OfflineSessionCoordinator coordinator;
  late f.FieldClock clock;
  Future<void> open() async {
    store = SqliteOutboxStore(
      databasePath: '${dir.path}/outbox.db',
      sqfliteFactory: databaseFactoryFfi,
    );
    await store.initialize();
    ledger = BookingLocalLedger(store);
    coordinator = OfflineSessionCoordinator(
      store: store,
      bookingLedger: ledger,
      timeIntegritySource: clock,
    );
  }

  Future<void> seedLink({
    String accountId = 'account',
    String wellId = 'well',
  }) async {
    await ledger.importServerSession(
      accountId: accountId,
      wellId: wellId,
      sessionId: 'server-A',
      bookingId: 'A',
      startedAt: f.at(43),
    );
  }

  Future<void> clearFromFreshRead() async {
    expect(
      await coordinator.reconcileServerBookingSession(
        accountId: 'account',
        wellId: 'well',
        current: null,
      ),
      isNull,
    );
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('stale-booking-link-');
    clock = f.FieldClock();
    await open();
  });
  tearDown(() async {
    coordinator.dispose();
    await store.close();
    await dir.delete(recursive: true);
  });
  test(
    'fresh null deletes stale link and clears memory and later restoration',
    () async {
      await seedLink();
      expect(
        await coordinator.restoreServerBookingSession(
          accountId: 'account',
          wellId: 'well',
        ),
        isNotNull,
      );
      await clearFromFreshRead();
      expect(coordinator.serverBookingSession, isNull);
      expect(
        await store.readLocalValue('account', 'booking.server_session.well'),
        isNull,
      );
      expect(
        await coordinator.restoreServerBookingSession(
          accountId: 'account',
          wellId: 'well',
        ),
        isNull,
      );
    },
  );
  test(
    'fresh null without a prior link remains clean and is repeatable',
    () async {
      await clearFromFreshRead();
      await clearFromFreshRead();
      expect(await ledger.loadServerSession('account', 'well'), isNull);
      expect(
        await store.readLocalValuesByPrefix('account', 'booking.'),
        isEmpty,
      );
    },
  );
  test(
    'valid open server booking import and replay remain unchanged',
    () async {
      final current = f.fieldSchedule().currentSession!;
      for (var i = 0; i < 2; i++) {
        final link = await coordinator.reconcileServerBookingSession(
          accountId: 'account',
          wellId: 'well',
          current: current,
        );
        expect(link?.sessionId, current.sessionId);
        expect(link?.bookingId, current.bookingId);
        expect(link?.startedAt, current.startedAt);
      }
      expect(
        (await ledger.loadServerSession('account', 'well'))?.sessionId,
        'server-A',
      );
    },
  );
  test('different real server session still rejects a different active local session', () async {
    await coordinator.startSession(
      accountId: 'account',
      wellId: 'well',
      pumpId: 'pump',
      farmId: 'farm',
      farmerAccountId: 'farmer',
      energySource: 'well_diesel',
      startedAt: f.at(43),
    );
    final active = coordinator.currentActiveSession;
    await expectLater(
      coordinator.reconcileServerBookingSession(
        accountId: 'account',
        wellId: 'well',
        current: f.fieldSchedule().currentSession,
      ),
      throwsStateError,
    );
    expect(coordinator.currentActiveSession, same(active));
    expect(await ledger.loadServerSession('account', 'well'), isNull);
  });
  test('deletion is scoped to exact account and well key', () async {
    await seedLink();
    await seedLink(accountId: 'other-account');
    await seedLink(wellId: 'other-well');
    await store.writeLocalValue(
      'account',
      'booking.server_session.well.extra',
      'keep',
    );
    await clearFromFreshRead();
    expect(await ledger.loadServerSession('account', 'well'), isNull);
    expect(await ledger.loadServerSession('other-account', 'well'), isNotNull);
    expect(await ledger.loadServerSession('account', 'other-well'), isNotNull);
    expect(
      await store.readLocalValue(
        'account',
        'booking.server_session.well.extra',
      ),
      'keep',
    );
  });
  test('phone-owned session and every v2 row except stale key survive clearing and restart', () async {
    await seedLink();
    clock.now = f.at(47);
    final result = await coordinator.runPhoneOwnedDueBookingTransition(
      accountId: 'account',
      wellId: 'well',
      cachedSchedule: f.cached(f.fieldSchedule()),
      automation: f.automation(),
      commandId: 'caller-command',
      localSessionId: 'caller-local',
      scheduledCallback: true,
    );
    expect(result.transitioned, isTrue);
    final active = coordinator.currentActiveSession!;
    expect(active.phoneOwned, isTrue);
    final commands = await store.allCommands('account');
    expect(commands, hasLength(2));
    expect(commands.last.prerequisites, [commands.first.localId]);
    final transition = await coordinator.restorePhoneOwnedTransition(
      accountId: 'account',
      wellId: 'well',
      transitionKey: 'chain:server-A:B:0:1',
    );
    expect(transition, isNotNull);
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/outbox.db');
    await db.insert(SqliteOutboxStore.mappingsTable, {
      'account_id': 'account',
      'local_id': 'older-completion',
      'entity_kind': 'sessionCharge',
      'server_id': 'older-charge',
      'resolved_at': f.at(43).toIso8601String(),
    });
    for (final key in [
      'booking.schedule.well.day',
      'booking.automation.well',
      'booking.provisional_session.well.old',
      'pricing.well',
      'farmer.local',
      'farm.local',
      'auth.local',
    ]) {
      await store.writeLocalValue('account', key, 'preserved:$key');
    }
    Future<List<Map<String, Object?>>> rows(String table) =>
        db.query(table, orderBy: 'rowid');
    final beforeCommands = await rows(SqliteOutboxStore.commandsTable);
    final beforeMappings = await rows(SqliteOutboxStore.mappingsTable);
    final expectedMeta = (await rows(SqliteOutboxStore.metaTable))
        .where(
          (row) =>
              !(row['account_id'] == 'account' &&
                  row['key'] == 'booking.server_session.well'),
        )
        .toList();
    await clearFromFreshRead();
    expect(coordinator.currentActiveSession, same(active));
    expect(await rows(SqliteOutboxStore.commandsTable), beforeCommands);
    expect(await rows(SqliteOutboxStore.mappingsTable), beforeMappings);
    expect(await rows(SqliteOutboxStore.metaTable), expectedMeta);
    expect(await db.getVersion(), 3);
    coordinator.dispose();
    await store.close();
    await open();
    expect(
      await coordinator.restoreServerBookingSession(
        accountId: 'account',
        wellId: 'well',
      ),
      isNull,
    );
    final restored = await coordinator.projectActiveSession(
      accountId: 'account',
      wellId: 'well',
    );
    expect(restored?.localId, active.localId);
    expect(restored?.phoneOwned, isTrue);
    expect(restored?.startedAt, active.startedAt);
    expect(
      (await coordinator.restorePhoneOwnedTransition(
        accountId: 'account',
        wellId: 'well',
        transitionKey: 'chain:server-A:B:0:1',
      ))?.toJson(),
      transition!.toJson(),
    );
    final reopened = await databaseFactoryFfi.openDatabase(
      '${dir.path}/outbox.db',
    );
    expect(await reopened.getVersion(), 3);
    expect(
      await reopened.query(SqliteOutboxStore.commandsTable, orderBy: 'rowid'),
      beforeCommands,
    );
    expect(
      await reopened.query(SqliteOutboxStore.mappingsTable, orderBy: 'rowid'),
      beforeMappings,
    );
    expect(
      await reopened.query(SqliteOutboxStore.metaTable, orderBy: 'rowid'),
      expectedMeta,
    );
  });
}

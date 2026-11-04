import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/entity_reference.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

class BoundedStore extends SqliteOutboxStore {
  BoundedStore(String path)
    : super(
        databasePath: path,
        sqfliteFactory: databaseFactoryFfi,
        singleInstance: false,
      );
  @override
  Future<List<CommandEnvelope>> pendingCommands(String a) =>
      throw StateError('global scan');
  @override
  Future<IdMapping?> mapping(String a, String id, EntityKind kind) =>
      throw StateError('N+1');
}

void main() {
  setUpAll(sqfliteFfiInit);
  test('current v11 reopen preserves rows and uses scoped selection index without N+1', () async {
    final dir = await Directory.systemTemp.createTemp('farm_v8');
    final path = '${dir.path}/db';
    var store = BoundedStore(path);
    await store.initialize();
    var coordinator = OfflineSessionCoordinator(store: store);
    final farm = await coordinator.enqueueFarm(
      accountId: 'a',
      wellId: 'w',
      name: 'القطعة',
      farmerReference: const ServerEntityReference('f'),
    );
    final repo = BookingRepository(null, null, BookingLocalLedger(store));
    final first = await repo.saveLocalBooking(
      accountId: 'a',
      wellId: 'w',
      requestId: 'one',
      farmer: const FarmerAccount(id: 'f', fullName: 'أحمد', publicCode: 'F'),
      farm: farm,
      scheduledStart: DateTime.utc(2027, 1, 1, 7),
      scheduledEnd: DateTime.utc(2027, 1, 1, 8),
      expectedEnergySource: 'well_diesel',
    );
    final attemptedAt = first.createdLocalAt;
    await store.claimBookingCreate('a', first.commandId, attemptedAt: attemptedAt);
    await store.finishBookingCreate('a', first.commandId, claimedAt: attemptedAt,
      status: CommandStatus.review, response: {
        'status': 'rejected', 'reason_code': 'farm_selection_required',
      });
    final previous = (await store.bookingRequest('a', 'w', 'one'))!;
    await repo.saveLocalBooking(
      accountId: 'a',
      wellId: 'w',
      requestId: 'two',
      farmer: const FarmerAccount(id: 'f', fullName: 'أحمد', publicCode: 'F'),
      farm: farm,
      scheduledStart: DateTime.utc(2027, 1, 1, 7),
      scheduledEnd: DateTime.utc(2027, 1, 1, 8),
      expectedEnergySource: 'well_diesel',
      replaces: previous,
    );
    final ref = farm.entityReference.localReference!;
    await store.putMapping(
      'a',
      IdMapping(
        localId: ref.localId,
        kind: EntityKind.farm,
        serverId: 'canonical',
        resolvedAt: DateTime.utc(2026),
      ),
    );
    final time = DateTime.utc(2026);
    await store.insert(
      CommandEnvelope(
        localId: 'session',
        commandId: 'session-command',
        type: CommandType.startIrrigationSession,
        accountId: 'a',
        wellId: 'w',
        sequence: 100,
        occurredAt: time,
        createdLocalAt: time,
        payload: {
          'p_well_id': 'w',
          'p_farm_id': farm.entityReference.toPayload(),
          'p_farmer_well_account_id': 'f',
        },
      ),
    );
    await store.releaseForRetry(
      'a',
      'session',
      error: 'network',
      attemptedAt: time,
    );
    await store.writeLocalValue(
      'a',
      'booking.choices.w.farms.f',
      '[{"id":"cached"}]',
    );
    coordinator.dispose();
    await store.close();
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    const tables = [
      'outbox_commands',
      'id_mappings',
      'sync_meta',
      'local_booking_requests',
    ];
    final before = {
      for (final table in tables)
        table: jsonEncode(
          await db.rawQuery('select * from $table order by rowid'),
        ),
    };
    await db.close();
    store = BoundedStore(path);
    await store.initialize();
    coordinator = OfflineSessionCoordinator(store: store);
    final choices = await coordinator.farmChoices(
      accountId: 'a',
      wellId: 'w',
      farmerReference: const ServerEntityReference('f'),
    );
    expect(choices.single.id, 'canonical');
    expect(
      await coordinator.farmChoices(
        accountId: 'other',
        wellId: 'w',
        farmerReference: const ServerEntityReference('f'),
      ),
      isEmpty,
    );
    expect(
      await coordinator.farmChoices(
        accountId: 'a',
        wellId: 'other',
        farmerReference: const ServerEntityReference('f'),
      ),
      isEmpty,
    );
    expect(
      await coordinator.farmChoices(
        accountId: 'a',
        wellId: 'w',
        farmerReference: const ServerEntityReference('other'),
      ),
      isEmpty,
    );
    final check = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    for (final table in tables) {
      expect(
        jsonEncode(await check.rawQuery('select * from $table order by rowid')),
        before[table],
      );
    }
    final plan = await check.rawQuery(
      'explain query plan ${SqliteOutboxStore.farmSelectionSql}',
      ['server', 'f', 'a', 'f', 'server', 'a', 'w', '', '', '', 50],
    );
    expect(
      plan.map((r) => r['detail']).join(),
      contains('outbox_farm_selection_idx'),
    );
    expect(plan.map((r) => r['detail']).join(), isNot(contains('SCAN c')));
    await expectLater(
      store.farmCommands(accountId: 'a', wellId: 'w', farmer: 'f', limit: 101),
      throwsArgumentError,
    );
    expect(
      (await check.rawQuery('pragma user_version')).single.values.single,
      SqliteOutboxStore.schemaVersion,
    );
    await check.close();
    coordinator.dispose();
    await store.close();
    await dir.delete(recursive: true);
  });
  test('one scoped page is bounded at 50/100 even with other accounts wells and farmers', () async {
    final dir = await Directory.systemTemp.createTemp('farm_bound');
    final store = BoundedStore('${dir.path}/db');
    await store.initialize();
    final time = DateTime.utc(2026);
    final commands = <CommandEnvelope>[];
    for (var i = 0; i < 135; i++) {
      commands.add(
        CommandEnvelope(
          localId: 'land-$i',
          commandId: 'command-$i',
          type: CommandType.createFarm,
          accountId: i < 120 ? 'a' : 'other',
          wellId: i < 125 ? 'w' : 'elsewhere',
          sequence: i,
          occurredAt: time,
          createdLocalAt: time,
          payload: {
            'p_well_id': i < 125 ? 'w' : 'elsewhere',
            'p_farmer_well_account_id': i < 130 ? 'f' : 'other-farmer',
            'p_name': 'قطعة $i',
          },
        ),
      );
    }
      for(final command in commands){await store.insert(command); }
    expect(
      await store.farmCommands(accountId: 'a', wellId: 'w', farmer: 'f'),
      hasLength(50),
    );
    final rows = await store.farmCommands(
      accountId: 'a',
      wellId: 'w',
      farmer: 'f',
      limit: 100,
    );
    expect(rows, hasLength(100));
    expect(rows.first.command.localId, 'land-119');
    expect(
      rows.every(
        (r) =>
            r.command.accountId == 'a' &&
            r.command.wellId == 'w' &&
            r.farmerId == 'f',
      ),
      true,
    );
    expect(
      await store.farmCommands(
        accountId: 'a',
        wellId: 'w',
        farmer: 'other-farmer',
      ),
      isEmpty,
    );
    await store.close();
    await dir.delete(recursive: true);
  });
}

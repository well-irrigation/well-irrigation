import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/sync/command_reference.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late SqliteOutboxStore store;
  BookingRepository repo() =>
      BookingRepository(null, null, BookingLocalLedger(store));
  SqliteOutboxStore open() => SqliteOutboxStore(
    databasePath: '${temp.path}/c1.db',
    sqfliteFactory: databaseFactoryFfi,
    singleInstance: false,
  );
  const farmer = FarmerAccount(
    id: 'farmer',
    fullName: 'أحمد',
    publicCode: 'F-1',
  );
  const farm = Farm(
    id: 'farm',
    wellId: 'well',
    name: 'الأرض',
    farmerAccountId: 'farmer',
  );
  Future<dynamic> save({
    String account = 'account',
    String well = 'well',
    String request = 'request',
    FarmerAccount selectedFarmer = farmer,
    Farm? selectedFarm,
    String notes = 'الأصل',
  }) => repo().saveLocalBooking(
    accountId: account,
    wellId: well,
    requestId: request,
    farmer: selectedFarmer,
    farm:
        selectedFarm ??
        Farm(
          id: farm.id,
          wellId: well,
          name: farm.name,
          farmerAccountId: 'farmer',
        ),
    scheduledStart: DateTime.utc(2027, 1, 15, 7),
    scheduledEnd: DateTime.utc(2027, 1, 15, 8),
    expectedEnergySource: 'well_diesel',
    notes: notes,
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('booking_c1');
    store = open();
    await store.initialize();
  });
  tearDown(() async {
    await store.close();
    await temp.delete(recursive: true);
  });

  test('durable save reopens with identical intent and command, no invented booking identity', () async {
    final saved = await save();
    expect(saved.bookingId, isNull);
    expect(saved.publicCode, isNull);
    expect(saved.canStart, isFalse);
    expect(saved.payload['p_notes'], 'الأصل');
    expect(saved.payload['p_scheduled_start'], '2027-01-15T07:00:00.000Z');
    final id = saved.commandId;
    final payload = saved.payloadJson;
    await store.close();
    store = open();
    final restored = await repo().localBooking(
      accountId: 'account',
      wellId: 'well',
      requestId: 'request',
    );
    expect(restored!.commandId, id);
    expect(restored.payloadJson, payload);
    final duplicate = await save();
    expect(duplicate.commandId, id);
    expect(
      (await store.bookingRequestsForDay(
        'account',
        'well',
        '2027-01-15',
      )).length,
      1,
    );
    final commands = await store.pendingCommands('account');
    expect(commands, hasLength(1));
    expect(commands.single.type, CommandType.createBooking);
    expect(commands.single.commandId, id);
    expect(commands.single.payload, restored.payload);
  });

  test('two independent connections save one logical request once', () async {
    final other = open();
    await other.initialize();
    try {
      final a = save();
      final b = BookingRepository(null, null, BookingLocalLedger(other))
          .saveLocalBooking(
            accountId: 'account',
            wellId: 'well',
            requestId: 'request',
            farmer: farmer,
            farm: farm,
            scheduledStart: DateTime.utc(2027, 1, 15, 7),
            scheduledEnd: DateTime.utc(2027, 1, 15, 8),
            expectedEnergySource: 'well_diesel',
            notes: 'الأصل',
          );
      final results = await Future.wait([a, b]);
      expect(results[0].commandId, results[1].commandId);
      expect(
        (await store.bookingRequestsForDay(
          'account',
          'well',
          '2027-01-15',
        )).length,
        1,
      );
    } finally {
      await other.close();
    }
  });

  test('same logical request cannot replace its original payload', () async {
    final original = await save();
    await expectLater(save(notes: 'تغيير'), throwsStateError);
    final read = await repo().localBooking(
      accountId: 'account',
      wellId: 'well',
      requestId: 'request',
    );
    expect(read!.payloadJson, original.payloadJson);
    expect(() => read.payload['p_notes'] = 'تغيير', throwsUnsupportedError);
  });

  test('account and well are part of request identity; independent requests remain independent', () async {
    await Future.wait([
      save(),
      save(account: 'other'),
      save(well: 'other'),
      save(request: 'second'),
    ]);
    expect(
      await repo().localBooking(
        accountId: 'unknown',
        wellId: 'well',
        requestId: 'request',
      ),
      isNull,
    );
    expect(
      await repo().localBooking(
        accountId: 'account',
        wellId: 'unknown',
        requestId: 'request',
      ),
      isNull,
    );
    expect(
      (await store.bookingRequestsForDay(
        'account',
        'well',
        '2027-01-15',
      )).length,
      2,
    );
    expect(
      (await store.bookingRequestsForDay('other', 'well', '2027-01-15')).length,
      1,
    );
    expect(
      (await store.bookingRequestsForDay(
        'account',
        'other',
        '2027-01-15',
      )).length,
      1,
    );
  });

  test('pending farmer, pending farm, wrong well and wrong farmer are refused without persistence', () async {
    final pendingFarmer = FarmerAccount.pending(
      reference: const CommandReference(
        localId: 'f',
        kind: EntityKind.farmerWellAccount,
      ),
      fullName: 'محلي',
    );
    final pendingFarm = Farm.pending(
      reference: const CommandReference(localId: 'land', kind: EntityKind.farm),
      wellId: 'well',
      name: 'محلية',
      farmerReference: farmer.entityReference,
    );
    for (final action in [
      () => save(selectedFarmer: pendingFarmer),
      () => save(selectedFarm: pendingFarm),
      () => save(
        selectedFarm: const Farm(
          id: 'x',
          wellId: 'other',
          name: 'x',
          farmerAccountId: 'farmer',
        ),
      ),
      () => save(
        selectedFarm: const Farm(
          id: 'x',
          wellId: 'well',
          name: 'x',
          farmerAccountId: 'other',
        ),
      ),
      () => save(
        selectedFarmer: const FarmerAccount(
          id: 'f',
          fullName: 'معطل',
          publicCode: 'F',
          status: 'inactive',
        ),
      ),
    ]) {
      await expectLater(action(), throwsArgumentError);
    }
    expect(
      await store.bookingRequestsForDay('account', 'well', '2027-01-15'),
      isEmpty,
    );
  });

  test(
    'page is bounded, scoped to day, and keyset continuation has no duplicates',
    () async {
      for (var i = 0; i < 7; i++) {
        await save(request: 'r$i');
      }
      final first = await store.bookingRequestsForDay(
        'account',
        'well',
        '2027-01-15',
        limit: 3,
      );
      final second = await store.bookingRequestsForDay(
        'account',
        'well',
        '2027-01-15',
        limit: 3,
        afterRequestId: first.last.requestId,
      );
      expect(first.map((r) => r.requestId), ['r0', 'r1', 'r2']);
      expect(second.map((r) => r.requestId), ['r3', 'r4', 'r5']);
      expect(
        await store.bookingRequestsForDay('account', 'well', '2027-01-16'),
        isEmpty,
      );
      await expectLater(
        store.bookingRequestsForDay(
          'account',
          'well',
          '2027-01-15',
          limit: 101,
        ),
        throwsArgumentError,
      );
      final db = await databaseFactoryFfi.openDatabase(
        '${temp.path}/c1.db',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      try {
        final plan = await db.rawQuery(
          'EXPLAIN QUERY PLAN SELECT * FROM local_booking_requests WHERE account_id = ? AND well_id = ? AND scheduled_day = ? AND request_id > ? ORDER BY request_id LIMIT ?',
          ['account', 'well', '2027-01-15', '', 3],
        );
        expect(
          plan.map((r) => r['detail']).join(' '),
          contains('booking_requests_day_idx'),
        );
      } finally {
        await db.close();
      }
    },
  );

  test(
    'v3 database upgrade retains preexisting command IDs and local metadata',
    () async {
      await store.close();
      final db = await databaseFactoryFfi.openDatabase(
        '${temp.path}/old.db',
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, version) async {
            // تعريف schema-v3 من SqliteOutboxStore قبل إضافة next_attempt_at.
            await db.execute('''
              CREATE TABLE outbox_commands (
                local_id           TEXT PRIMARY KEY,
                command_id         TEXT NOT NULL UNIQUE,
                command_type       TEXT NOT NULL,
                account_id         TEXT NOT NULL,
                well_id            TEXT,
                aggregate_local_id TEXT,
                sequence           INTEGER NOT NULL,
                occurred_at        TEXT NOT NULL,
                created_local_at   TEXT NOT NULL,
                payload            TEXT NOT NULL,
                prerequisites      TEXT NOT NULL DEFAULT '[]',
                local_context      TEXT NOT NULL DEFAULT '{}',
                status             TEXT NOT NULL,
                retry_count        INTEGER NOT NULL DEFAULT 0,
                last_error         TEXT,
                last_attempt_at    TEXT,
                server_response    TEXT
              )
            ''');
            // جدول الربط موجود منذ مخطط الطابور الأول، بما فيه الإصدار الثالث.
            await db.execute('CREATE TABLE id_mappings(account_id TEXT NOT NULL, local_id TEXT NOT NULL, entity_kind TEXT NOT NULL, server_id TEXT NOT NULL, resolved_at TEXT NOT NULL, matched_existing INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(account_id,local_id,entity_kind))');
            await db.insert('outbox_commands', {
              'local_id': 'old',
              'command_id': 'stable-old',
              'command_type': 'createFarmer',
              'account_id': 'account',
              'well_id': 'well',
              'sequence': 1,
              'occurred_at': '2027-01-01T07:00:00.000Z',
              'created_local_at': '2027-01-01T07:00:00.000Z',
              'payload': '{"p_well_id":"well","p_full_name":"أحمد"}',
              'status': 'pending',
            });
            await db.execute(
              'CREATE TABLE sync_meta(account_id TEXT, key TEXT, value TEXT, PRIMARY KEY(account_id,key))',
            );
            await db.execute(
              "INSERT INTO sync_meta VALUES('account','existing','retained')",
            );
          },
        ),
      );
      await db.close();
      final upgraded = SqliteOutboxStore(
        databasePath: '${temp.path}/old.db',
        sqfliteFactory: databaseFactoryFfi,
        singleInstance: false,
      );
      try {
        await upgraded.initialize();
        expect(
          await upgraded.readLocalValue('account', 'existing'),
          'retained',
        );
        final inspect = await databaseFactoryFfi.openDatabase(
          '${temp.path}/old.db',
          options: OpenDatabaseOptions(singleInstance: false),
        );
        expect(
          (await inspect.rawQuery('SELECT command_id FROM outbox_commands'))
              .single['command_id'],
          'stable-old',
        );
        await inspect.close();
      } finally {
        await upgraded.close();
      }
    },
  );
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import '../sync/booking_dispatch_c2a_test.dart' show Transport, accepted;

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late SqliteOutboxStore store;
  SqliteOutboxStore open() => SqliteOutboxStore(
    databasePath: '${dir.path}/booking.db',
    sqfliteFactory: databaseFactoryFfi,
    singleInstance: false,
  );
  BookingRepository repository() =>
      BookingRepository(null, null, BookingLocalLedger(store));
  Future<dynamic> save() => repository().saveLocalBooking(
    accountId: 'a', wellId: 'w', requestId: 'request',
    farmer: const FarmerAccount(id: 'farmer', fullName: 'أحمد', publicCode: 'F'),
    farm: const Farm(id: 'farm', wellId: 'w', name: 'الأرض', farmerAccountId: 'farmer'),
    scheduledStart: DateTime.utc(2027, 1, 1, 7),
    scheduledEnd: DateTime.utc(2027, 1, 1, 8),
    expectedEnergySource: 'well_diesel', notes: 'الأصل',
  );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('booking_c2b');
    store = open();
    await store.initialize();
  });
  tearDown(() async { await store.close(); await dir.delete(recursive: true); });

  test('save atomically registers the exact immutable request once and survives reopen', () async {
    final request = await save();
    await save();
    await store.close();
    store = open();
    await store.initialize();
    final commands = await store.pendingCommands('a');
    expect(commands, hasLength(1));
    expect(commands.single.type, CommandType.createBooking);
    expect(commands.single.commandId, request.commandId);
    expect(commands.single.payload, request.payload);
    final restored = await store.bookingRequest('a', 'w', 'request');
    expect(restored!.payloadJson, request.payloadJson);
    expect(restored.canStart, isFalse);
  });

  test('accepted result and local response commit together and survive reopen', () async {
    final request = await save();
    final transport = Transport((r) async => accepted(r));
    await SyncEngine(store: store, transport: transport).runBookingCreates('a');
    expect(transport.requests.single.commandId, request.commandId);
    await store.close();
    store = open();
    final restored = await store.bookingRequest('a', 'w', 'request');
    expect(restored!.isConfirmed, isTrue);
    expect(restored.bookingId, 'booking-${request.commandId}');
    expect(restored.canStart, isFalse);
  });

  test('failure while inserting command rolls back both durable rows', () async {
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/booking.db',
      options: OpenDatabaseOptions(singleInstance: false));
    await db.execute("create trigger reject_booking_insert before insert on outbox_commands begin select raise(abort, 'disk write failed'); end");
    await expectLater(save(), throwsA(anything));
    expect(await store.bookingRequest('a', 'w', 'request'), isNull);
    expect(await store.pendingCommands('a'), isEmpty);
    await db.close();
  });

  for (final status in ['conflict', 'rejected']) {
    test('$status is persisted with original request and restored after reopen', () async {
      final original = await save();
      await SyncEngine(store: store, transport: Transport((r) async =>
        normalizeAcceptedResponse(r.type, {'status': status, 'reason_code': 'RAW_CODE'})))
          .runBookingCreates('a');
      await store.close();
      store = open();
      final restored = await store.bookingRequest('a', 'w', 'request');
      expect(restored!.response!['status'], status);
      expect(restored.payloadJson, original.payloadJson);
      expect(restored.commandId, original.commandId);
      expect(restored.bookingId, isNull);
      expect((await store.commandByLocalId('a', original.commandId))!.status, CommandStatus.review);
    });
  }

  test('interruption during terminal persistence rolls back ACK; replay after reopen recovers both', () async {
    final original = await save();
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/booking.db',
      options: OpenDatabaseOptions(singleInstance: false));
    await db.execute("create trigger interrupt_booking_response before update of response on local_booking_requests begin select raise(abort, 'process interrupted'); end");
    final transport = Transport((r) async => accepted(r));
    await expectLater(SyncEngine(store: store, transport: transport).runBookingCreates('a'), throwsA(anything));
    expect((await store.bookingRequest('a', 'w', 'request'))!.response, isNull);
    expect((await store.commandByLocalId('a', original.commandId))!.status, CommandStatus.dispatching);
    await db.execute('drop trigger interrupt_booking_response');
    await db.close();
    await store.close();
    store = open();
    await store.initialize();
    var now = DateTime.now().toUtc().add(const Duration(days: 1));
    final engine = SyncEngine(store: store, transport: transport, clock: () => now);
    expect((await engine.runBookingCreates('a')).recoveredClaims, 1);
    now = now.add(const Duration(hours: 2));
    await engine.runBookingCreates('a');
    expect(transport.requests, hasLength(2));
    expect(transport.requests.map((r) => r.commandId).toSet(), {original.commandId});
    expect(transport.requests[0].arguments, transport.requests[1].arguments);
    expect((await store.bookingRequest('a', 'w', 'request'))!.isConfirmed, isTrue);
    expect((await store.commandByLocalId('a', original.commandId))!.status, CommandStatus.confirmed);
  });

  test('v5 orphan recovery is bounded, indexed and preserves retry rows and metadata', () async {
    final original = await save();
    await store.writeLocalValue('a', 'retained', 'value');
    await store.close();
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/booking.db',
      options: OpenDatabaseOptions(singleInstance: false));
    await db.delete('outbox_commands');
    await db.execute('drop index booking_requests_current_day_idx');
    await db.execute('alter table local_booking_requests drop column replaces_request_id');
    await db.execute('alter table local_booking_requests drop column superseded_by_request_id');
    await db.execute('drop index booking_requests_registration_idx');
    await db.execute('alter table local_booking_requests drop column dispatch_registered');
    await db.execute('drop table notification_events');
    await db.setVersion(5);
    await db.close();
    store = open();
    await store.initialize();
    final ready = await store.bookingCreatesReady('a', now: DateTime.now().toUtc());
    expect(ready, hasLength(1));
    expect(ready.single.commandId, original.commandId);
    expect(ready.single.payload, original.payload);
    expect(await store.readLocalValue('a', 'retained'), 'value');
    final inspect = await databaseFactoryFfi.openDatabase('${dir.path}/booking.db',
      options: OpenDatabaseOptions(singleInstance: false));
    final plan = await inspect.rawQuery('explain query plan select * from local_booking_requests where account_id = ? and dispatch_registered = 0 order by created_local_at, request_id limit 20', ['a']);
    expect(plan.toString(), contains('booking_requests_registration_idx'));
    final dayPlan = await inspect.rawQuery('explain query plan select * from local_booking_requests where account_id = ? and well_id = ? and scheduled_day = ? and request_id > ? order by request_id limit 100', ['a', 'w', '2027-01-01', '']);
    expect(dayPlan.toString(), contains('booking_requests_day_idx'));
    await inspect.close();
  });

  test('narrow canonical choice search merges with retained entries and respects fifty', () async {
    final repo = repository();
    await repo.cacheBookingChoices('a', 'w', 'farmers', [
      for (var i = 0; i < 50; i++) {'id': '$i', 'full_name': 'old-$i'},
    ]);
    await repo.cacheBookingChoices('a', 'w', 'farmers', [
      {'id': '1', 'full_name': 'updated'}, {'id': 'new', 'full_name': 'new'},
    ]);
    final choices = await repo.cachedBookingChoices('a', 'w', 'farmers');
    expect(choices, hasLength(50));
    expect(choices.first['full_name'], 'updated');
    expect(choices[1]['id'], 'new');
    expect(choices.any((c) => c['id'] == '0'), isTrue);
    expect(choices.any((c) => c['id'] == '49'), isFalse);
    expect(await repo.cachedBookingChoices('other', 'w', 'farmers'), isEmpty);
    expect(await repo.cachedBookingChoices('a', 'other', 'farmers'), isEmpty);
    expect(await repo.cachedBookingChoices('a', 'w', 'farms.other'), isEmpty);
  });
}

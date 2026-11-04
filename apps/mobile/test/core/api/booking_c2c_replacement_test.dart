import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/booking/local_booking_request.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';
import 'package:well_irrigation_mobile/core/booking/booking_request_projection.dart';
import '../sync/booking_dispatch_c2a_test.dart' show Transport, accepted;

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late SqliteOutboxStore store;
  SqliteOutboxStore open() => SqliteOutboxStore(databasePath: '${dir.path}/c2c.db',
      sqfliteFactory: databaseFactoryFfi, singleInstance: false);
  BookingRepository repo([SqliteOutboxStore? other]) => BookingRepository(null, null, BookingLocalLedger(other ?? store));
  Future<LocalBookingRequest> save(String id, {LocalBookingRequest? replaces, int hour = 7,
      int day = 15, String account = 'a', String well = 'w', String notes = 'الأصل', SqliteOutboxStore? other}) => repo(other).saveLocalBooking(
    accountId: account, wellId: well, requestId: id,
    farmer: const FarmerAccount(id: 'f', fullName: 'أحمد', publicCode: 'F'),
    farm: Farm(id: 'farm', wellId: well, name: 'الأرض', farmerAccountId: 'f'),
    scheduledStart: DateTime.utc(2027, 1, day, hour), scheduledEnd: DateTime.utc(2027, 1, day, hour + 1),
    expectedEnergySource: 'well_diesel', notes: notes, replaces: replaces,
  );
  Future<LocalBookingRequest> decide(LocalBookingRequest request, [String status = 'conflict']) async {
    final at = DateTime.now().toUtc();
    expect(await store.claimBookingCreate(request.accountId, request.commandId, attemptedAt: at), isTrue);
    expect(await store.finishBookingCreate(request.accountId, request.commandId, claimedAt: at,
      status: CommandStatus.review, response: {'status': status, 'reason_code': 'preserved-reason'}), isTrue);
    return (await store.bookingRequest(request.accountId, request.wellId, request.requestId))!;
  }
  setUp(() async { dir = await Directory.systemTemp.createTemp('c2c'); store = open(); await store.initialize(); });
  tearDown(() async { await store.close(); await dir.delete(recursive: true); });

  test('replacement commits new identities and command, preserves original bytes, and restores current row', () async {
    final a = await decide(await save('A'));
    final b = await save('B', replaces: a, hour: 9, notes: 'موعد اختاره المستخدم');
    expect(b.requestId, isNot(a.requestId));
    expect(b.commandId, isNot(a.commandId));
    expect(b.replacesRequestId, a.requestId);
    expect(b.payload['p_scheduled_start'], '2027-01-15T09:00:00.000Z');
    final old = (await store.bookingRequest('a', 'w', 'A'))!;
    expect(old.payloadJson, a.payloadJson);
    expect(old.commandId, a.commandId);
    expect(old.responseJson, a.responseJson);
    expect(old.supersededByRequestId, 'B');
    final command = (await store.commandByLocalId('a', b.commandId))!;
    expect(command.commandId, b.commandId);
    expect(command.payload, b.payload);
    await store.close(); store = open();
    final current = await store.bookingRequestsForDay('a', 'w', '2027-01-15');
    expect(current.map((r) => r.requestId), ['B']);
    expect(current.single.commandId, b.commandId);
    expect(current.single.canStart, isFalse);
  });

  test('unavailable time must change manually; unchanged slot never creates a replacement', () async {
    final a = await decide(await save('A'));
    await expectLater(save('B', replaces: a, notes: 'ملاحظات فقط'), throwsArgumentError);
    expect(await store.bookingRequest('a', 'w', 'B'), isNull);
    expect((await store.bookingRequestsForDay('a', 'w', '2027-01-15')).single.requestId, 'A');
  });

  test('other rejection permits correction without automatically changing time', () async {
    final a = await decide(await save('A'), 'rejected');
    final b = await save('B', replaces: a, notes: 'بيانات مصححة');
    expect(b.payload['p_scheduled_start'], a.payload['p_scheduled_start']);
    expect(b.payload['p_scheduled_end'], a.payload['p_scheduled_end']);
    expect(b.payload['p_notes'], 'بيانات مصححة');
  });

  for (final target in ['outbox_commands', 'local_booking_requests']) {
    test('failure in $target rolls back supersession, replacement and registration', () async {
      final a = await decide(await save('A'));
      final db = await databaseFactoryFfi.openDatabase('${dir.path}/c2c.db', options: OpenDatabaseOptions(singleInstance: false));
      await db.execute(target == 'outbox_commands'
        ? "create trigger interrupt_replacement before insert on outbox_commands begin select raise(abort, 'disk full'); end"
        : "create trigger interrupt_replacement before update of superseded_by_request_id on local_booking_requests begin select raise(abort, 'interrupted'); end");
      await expectLater(save('B', replaces: a, hour: 9), throwsA(anything));
      expect(await store.bookingRequest('a', 'w', 'B'), isNull);
      final old = (await store.bookingRequest('a', 'w', 'A'))!;
      expect(old.supersededByRequestId, isNull);
      expect(old.responseJson, a.responseJson);
      expect(await store.commandsForWell('a', 'w'), hasLength(1));
      await db.close();
      await store.close(); store = open();
      expect((await store.bookingRequestsForDay('a', 'w', '2027-01-15')).single.requestId, 'A');
    });
  }

  test('same logical replacement retries once; competing replacement cannot fork the chain', () async {
    final a = await decide(await save('A'));
    final b = await save('B', replaces: a, hour: 9);
    final duplicate = await save('B', replaces: a, hour: 9);
    expect(duplicate.commandId, b.commandId);
    expect(await store.commandsForWell('a', 'w'), hasLength(2));
    await expectLater(save('C', replaces: a, hour: 10), throwsStateError);
    expect(await store.bookingRequest('a', 'w', 'C'), isNull);
  });

  test('two SQLite connections cannot create competing current replacements', () async {
    final a = await decide(await save('A'));
    final other = open(); await other.initialize();
    try {
      Future<Object> attempt(String id, SqliteOutboxStore target) async {
        try { return await save(id, replaces: a, hour: 9, other: target); } catch (error) { return error; }
      }
      final results = await Future.wait([attempt('B', store), attempt('C', other)]);
      expect(results.whereType<LocalBookingRequest>(), hasLength(1));
      expect(results.whereType<StateError>(), hasLength(1));
      expect(await store.bookingRequestsForDay('a', 'w', '2027-01-15'), hasLength(1));
      expect(await store.commandsForWell('a', 'w'), hasLength(2));
    } finally { await other.close(); }
  });

  test('A to B to C preserves both original attempts and returns only C without chain traversal', () async {
    final a = await decide(await save('A'));
    final b = await decide(await save('B', replaces: a, hour: 9), 'rejected');
    final c = await save('C', replaces: b, hour: 10);
    expect((await store.bookingRequest('a', 'w', 'A'))!.responseJson, a.responseJson);
    expect((await store.bookingRequest('a', 'w', 'B'))!.responseJson, b.responseJson);
    expect(c.replacesRequestId, 'B');
    expect((await store.bookingRequestsForDay('a', 'w', '2027-01-15')).map((r) => r.requestId), ['C']);
  });

  test('replacement is account and well scoped; changing day hides only its original day', () async {
    final a = await decide(await save('A'));
    await expectLater(save('wrong-account', account: 'other', replaces: a, hour: 9), throwsArgumentError);
    await expectLater(save('wrong-well', well: 'other', replaces: a, hour: 9), throwsArgumentError);
    final independent = await save('independent', well: 'other');
    final b = await save('B', replaces: a, day: 16, hour: 9);
    expect(await store.bookingRequestsForDay('a', 'w', '2027-01-15'), isEmpty);
    expect((await store.bookingRequestsForDay('a', 'w', '2027-01-16')).single.requestId, b.requestId);
    expect((await store.bookingRequestsForDay('a', 'other', '2027-01-15')).single.commandId, independent.commandId);
    expect(await store.bookingRequestsForDay('other', 'w', '2027-01-16'), isEmpty);
  });

  test('current day query is bounded and uses the current-row index', () async {
    await save('A');
    await expectLater(store.bookingRequestsForDay('a', 'w', '2027-01-15', limit: 101), throwsArgumentError);
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/c2c.db', options: OpenDatabaseOptions(singleInstance: false));
    final plan = await db.rawQuery('explain query plan select * from local_booking_requests where account_id = ? and well_id = ? and scheduled_day = ? and superseded_by_request_id is null and request_id > ? order by request_id limit 100', ['a', 'w', '2027-01-15', '']);
    expect(plan.toString(), contains('booking_requests_current_day_idx'));
    await db.close();
  });

  test('pending and accepted requests cannot be superseded', () async {
    final a = await save('A');
    await expectLater(save('B', replaces: a, hour: 9), throwsArgumentError);
    final at = DateTime.now().toUtc();
    await store.claimBookingCreate('a', a.commandId, attemptedAt: at);
    await store.finishBookingCreate('a', a.commandId, claimedAt: at, status: CommandStatus.confirmed,
      entityId: 'real', response: {'status': 'confirmed', 'booking_id': 'real', 'public_code': 'B-1',
        'well_id': 'w', 'scheduled_start': a.payload['p_scheduled_start'], 'scheduled_end': a.payload['p_scheduled_end']});
    final confirmed = (await store.bookingRequest('a', 'w', 'A'))!;
    await expectLater(save('B', replaces: confirmed, hour: 9), throwsArgumentError);
    expect(await store.bookingRequestsForDay('a', 'w', '2027-01-15'), hasLength(1));
  });

  test('replacement retry uses its own immutable command and canonical arrival collapses the current card', () async {
    final a = await decide(await save('A'));
    final b = await save('B', replaces: a, hour: 9);
    var now = DateTime.now().toUtc();
    var retry = true;
    final transport = Transport((r) async => retry
      ? const DispatchFailed(disposition: FailureDisposition.retry, message: 'network') : accepted(r));
    final engine = SyncEngine(store: store, transport: transport, clock: () => now);
    await engine.runBookingCreates('a');
    expect((await store.bookingRequestsForDay('a', 'w', '2027-01-15')).single.response, isNull);
    retry = false; now = now.add(const Duration(hours: 2));
    await engine.runBookingCreates('a');
    expect(transport.requests, hasLength(2));
    expect(transport.requests.map((r) => r.commandId).toSet(), {b.commandId});
    expect(transport.requests.first.arguments, transport.requests.last.arguments);
    expect(transport.requests.first.commandId, isNot(a.commandId));
    final current = await store.bookingRequestsForDay('a', 'w', '2027-01-15');
    final placeholder = mergeBookingRequests([], current).single;
    final canonical = WellBookingListItem(id: current.single.bookingId!, publicCode: placeholder.publicCode,
      farmerWellAccountId: 'f', farmerName: 'أحمد', farmId: 'farm', farmName: 'الأرض',
      scheduledStart: placeholder.scheduledStart, scheduledEnd: placeholder.scheduledEnd,
      scheduledDay: current.single.scheduledDay, expectedDurationMinutes: 60, status: 'confirmed', priority: 0);
    expect(mergeBookingRequests([canonical], current), [canonical]);
    expect((await store.bookingRequest('a', 'w', 'A'))!.responseJson, a.responseJson);
  });

  test('real v6 upgrade preserves responses, retry state, IDs, metadata and cached choices', () async {
    final a = await decide(await save('A'));
    final pending = await save('pending');
    final at = DateTime.now().toUtc();
    final due = at.add(const Duration(hours: 1));
    await store.claimBookingCreate('a', pending.commandId, attemptedAt: at);
    await store.finishBookingCreate('a', pending.commandId, claimedAt: at,
      status: CommandStatus.pending, nextAttemptAt: due, error: 'retained retry');
    await store.writeLocalValue('a', 'metadata', 'retained');
    await repo().cacheBookingChoices('a', 'w', 'farmers', [{'id': 'f', 'full_name': 'أحمد'}]);
    await store.close();
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/c2c.db', options: OpenDatabaseOptions(singleInstance: false));
    await db.execute('drop index booking_requests_current_day_idx');
    await db.execute('alter table local_booking_requests drop column replaces_request_id');
    await db.execute('alter table local_booking_requests drop column superseded_by_request_id');
    await db.execute('drop table notification_events');
    await db.setVersion(6); await db.close();
    store = open(); await store.initialize();
    final restored = (await store.bookingRequest('a', 'w', 'A'))!;
    expect(restored.payloadJson, a.payloadJson); expect(restored.commandId, a.commandId);
    expect(restored.responseJson, a.responseJson); expect(restored.supersededByRequestId, isNull);
    final command = (await store.commandByLocalId('a', pending.commandId))!;
    expect(command.nextAttemptAt, due); expect(command.retryCount, 1); expect(command.lastError, 'retained retry');
    expect(command.payload, pending.payload);
    expect(await store.readLocalValue('a', 'metadata'), 'retained');
    expect((await repo().cachedBookingChoices('a', 'w', 'farmers')).single['id'], 'f');
    expect(await store.bookingRequestsForDay('a', 'w', '2027-01-15'), hasLength(2));
  });
}

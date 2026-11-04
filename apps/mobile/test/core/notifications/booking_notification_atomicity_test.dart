import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/booking/local_booking_request.dart';
import 'package:well_irrigation_mobile/core/notifications/app_notification_event.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_event_store.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

final at = DateTime.utc(2027, 1, 1);
LocalBookingRequest request(String id, {String? replaces}) => LocalBookingRequest(
  accountId: 'a', wellId: 'w', requestId: id, commandId: 'cmd-$id',
  createdLocalAt: at, scheduledDay: '2027-01-01',
  payloadJson: '{"p_well_id":"w","p_farmer_well_account_id":"f","p_farm_id":"farm",'
    '"p_scheduled_start":"2027-01-01T07:00:00.000Z","p_scheduled_end":"2027-01-01T08:00:00.000Z"}',
  contextJson: '{}', replacesRequestId: replaces,
);
const accepted = <String, Object?>{
  'status': 'confirmed', 'booking_id': 'booking-A', 'public_code': 'B-A',
  'well_id': 'w', 'scheduled_start': '2027-01-01T07:00:00.000Z',
  'scheduled_end': '2027-01-01T08:00:00.000Z',
};
AppNotificationEvent event(String key, {String category = 'booking_results'}) => AppNotificationEvent(
  eventKey: key, accountId: 'a', wellId: 'w', category: category,
  eventType: 'booking.confirmed', entityType: 'booking_request', entityId: 'A',
  routeType: 'bookings', routePayload: const {'day': '2027-01-01'}, createdAt: at,
);

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late SqliteOutboxStore store;
  late Database db;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('c04p_atomic_');
    store = SqliteOutboxStore(databasePath: '${dir.path}/db', sqfliteFactory: databaseFactoryFfi,
      singleInstance: false);
    await store.initialize();
    db = store.notificationEvents.db;
  });
  tearDown(() async { await store.close(); await dir.delete(recursive: true); });
  Future<void> rejectedOriginal() async {
    await store.saveBookingRequest(request('A'));
    expect(await store.claimBookingCreate('a', 'cmd-A', attemptedAt: at), isTrue);
    await store.finishBookingCreate('a', 'cmd-A', claimedAt: at,
      status: CommandStatus.review, response: {'status': 'rejected', 'reason_code': 'farm_selection_required'});
  }
  Future<Map<String, Object?>> snapshot() async => {
    for (final table in ['outbox_commands','local_booking_requests','id_mappings','notification_events','sync_meta'])
      table: await db.query(table, orderBy: 'rowid'),
  };

  test('actual request acceptance rolls back command, response, mapping and event on event failure', () async {
    final original = await store.saveBookingRequest(request('A'));
    await store.claimBookingCreate('a', 'cmd-A', attemptedAt: at);
    final before = await snapshot();
    await db.execute("create trigger reject_event before insert on notification_events begin select raise(abort,'event unavailable'); end");
    await expectLater(store.finishBookingCreate('a','cmd-A',claimedAt: at,
      status: CommandStatus.confirmed,response: accepted,entityId: 'booking-A'), throwsA(isA<DatabaseException>()));
    expect(await snapshot(), before);
    expect((await store.bookingRequest('a','w','A'))!.responseJson, isNull);
    expect(await store.mapping('a','cmd-A',EntityKind.booking), isNull);
    expect((await store.commandByLocalId('a','cmd-A'))!.status,CommandStatus.dispatching);
    expect((await store.bookingRequest('a','w','A'))!.payloadJson, original.payloadJson);
    await db.execute('drop trigger reject_event');
    expect(await store.finishBookingCreate('a','cmd-A',claimedAt: at,
      status: CommandStatus.confirmed,response: accepted,entityId: 'booking-A'),isTrue);
    expect((await store.bookingRequest('a','w','A'))!.isConfirmed,isTrue);
    expect((await store.bookingRequest('a','w','A'))!.canStart,isFalse);
  });
  test('replacement registration failure rolls back lineage, replacement and event suppression', () async {
    await rejectedOriginal();
    final before = await snapshot();
    await db.execute("create trigger reject_replacement before insert on outbox_commands when new.command_id='cmd-B' begin select raise(abort,'registration unavailable'); end");
    await expectLater(store.saveBookingRequest(request('B',replaces:'A')), throwsA(isA<DatabaseException>()));
    expect(await snapshot(),before);
    expect((await store.bookingRequest('a','w','A'))!.supersededByRequestId,isNull);
    expect(await store.bookingRequest('a','w','B'),isNull);
    expect(await store.commandByLocalId('a','cmd-B'),isNull);
    expect((await db.query('notification_events')).single['state'],'pending');
  });
  test('successful replacement suppresses original event and preserves immutable request bytes', () async {
    await rejectedOriginal();
    final before=(await store.bookingRequest('a','w','A'))!;
    await store.saveBookingRequest(request('B',replaces:'A'));
    final after=(await store.bookingRequest('a','w','A'))!;
    expect(after.payloadJson,before.payloadJson);
    expect(after.responseJson,before.responseJson);
    expect(after.commandId,before.commandId);
    expect(after.supersededByRequestId,'B');
    final row=(await db.query('notification_events')).single;
    expect(row['state'],'suppressed');
    expect(row['suppressed_reason'],'superseded');
    expect((await store.bookingRequestsForDay('a','w','2027-01-01')).single.requestId,'B');
  });
  test('late accepted superseded request emits review event without corrupting replacement lineage', () async {
    await rejectedOriginal();
    await store.saveBookingRequest(request('B',replaces:'A'));
    final original=(await store.bookingRequest('a','w','A'))!;
    // Historical/in-flight state fixture exercises the conditional persistence seam.
    // It does not authorize a runtime retry of a rejected or superseded request.
    await db.update('outbox_commands',{'status':'dispatching','last_attempt_at':at.toIso8601String()},
      where:'account_id=? and command_id=?',whereArgs:['a','cmd-A']);
    expect(await store.finishBookingCreate('a','cmd-A',claimedAt:at,
      status:CommandStatus.confirmed,response:accepted,entityId:'booking-A'),isTrue);
    final after=(await store.bookingRequest('a','w','A'))!;
    expect(after.responseJson,original.responseJson);
    expect(after.supersededByRequestId,'B');
    expect((await store.bookingRequest('a','w','B'))!.replacesRequestId,'A');
    final late=(await db.query('notification_events',where:'event_key=?',whereArgs:['booking-result/cmd-A/confirmed'])).single;
    expect(late['event_type'],'booking.review_required');
    expect((jsonDecode(late['route_payload_json'] as String) as Map)['previous_confirmed'],true);
    expect(late['state'],'pending');
    expect((await store.bookingRequestsForDay('a','w','2027-01-01')).single.requestId,'B');
  });
  test('event identity replay is stable but unrelated unique constraint failure aborts', () async {
    await SqliteNotificationEventStore.insertEventTx(db,event('first'));
    await SqliteNotificationEventStore.insertEventTx(db,event('first'));
    expect(await db.query('notification_events'),hasLength(1));
    await db.execute('create unique index fixture_unique_entity on notification_events(entity_id)');
    await expectLater(SqliteNotificationEventStore.insertEventTx(db,event('different')),
      throwsA(isA<DatabaseException>()));
    expect(await db.query('notification_events'),hasLength(1));
  });
  test('invalid replay row is not swallowed even when its event identity already exists', () async {
    await SqliteNotificationEventStore.insertEventTx(db,event('same'));
    await db.execute("create trigger invalid_category before insert on notification_events when new.category='invalid' begin select raise(abort,'CHECK constraint failed: category'); end");
    await expectLater(SqliteNotificationEventStore.insertEventTx(db,event('same',category:'invalid')),
      throwsA(isA<DatabaseException>()));
    expect((await db.query('notification_events')).single['category'],'booking_results');
  });
}

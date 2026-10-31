import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

import '../../support/no_json_sqlite_factory.dart';

const time = '2027-01-01T00:00:00.000Z';
const payload = '{"p_well_id":"w","p_farmer_well_account_id":"f","p_farm_id":"farm",'
    '"p_scheduled_start":"2027-01-01T07:00:00.000Z","p_scheduled_end":"2027-01-01T08:00:00.000Z"}';
const rejection = '{"status":"rejected","reason_code":"retained"}';

// Explicit old DDL reconstructed from the retained upgrade contracts, not a
// v11 database with a changed user_version. Optional legacy JSON expression
// indexes are absent, as on the failed-index/no-JSON devices covered by SOURCE.
// This fixture proves that supported shape, not every historical DB artifact.
Future<void> legacyFile(DatabaseFactory factory, String path, int version,
    {bool badPayload = false, bool badRoute = false}) async {
  final db = await factory.openDatabase(path, options: OpenDatabaseOptions(
    singleInstance:false, version:version, onCreate:(db, _) async {
    await db.execute('''create table outbox_commands (
      local_id text primary key, command_id text not null unique,
      command_type text not null, account_id text not null, well_id text,
      aggregate_local_id text, sequence integer not null, occurred_at text not null,
      created_local_at text not null, payload text not null,
      prerequisites text not null default '[]', local_context text not null default '{}',
      status text not null, retry_count integer not null default 0,
      last_error text, last_attempt_at text, server_response text
      ${version >= 5 ? ', next_attempt_at text' : ''})''');
    await db.execute('''create table id_mappings (
      account_id text not null, local_id text not null, entity_kind text not null,
      server_id text not null, resolved_at text not null,
      matched_existing integer not null default 0,
      primary key(account_id,local_id,entity_kind))''');
    await db.execute('''create table sync_meta (account_id text not null,
      key text not null,value text not null,primary key(account_id,key))''');
    await db.execute('''create table local_booking_requests (
      account_id text not null,well_id text not null,request_id text not null,
      command_id text not null unique,created_local_at text not null,
      scheduled_day text not null,payload text not null,display_context text not null,response text
      ${version >= 6 ? ', dispatch_registered integer not null default 0' : ''}
      ${version >= 7 ? ', replaces_request_id text, superseded_by_request_id text' : ''},
      primary key(account_id,well_id,request_id))''');
    for (final sql in [
      'create index outbox_commands_dispatch_idx on outbox_commands(account_id,status,sequence)',
      'create index outbox_commands_well_idx on outbox_commands(account_id,well_id,sequence)',
      'create index outbox_commands_session_idx on outbox_commands(account_id,aggregate_local_id,sequence)',
      'create index id_mappings_server_idx on id_mappings(account_id,entity_kind,server_id)',
      'create index booking_requests_day_idx on local_booking_requests(account_id,well_id,scheduled_day,request_id)',
      if(version>=5) ...[
        "create index outbox_booking_dispatch_idx on outbox_commands(account_id,status,sequence,local_id) where command_type='createBooking'",
        "create index outbox_booking_well_idx on outbox_commands(account_id,well_id,status,sequence) where command_type='createBooking'",
        "create index outbox_booking_due_idx on outbox_commands(account_id,status,next_attempt_at) where command_type='createBooking'",
        "create index outbox_booking_stale_idx on outbox_commands(account_id,status,last_attempt_at) where command_type='createBooking'",
      ],
      if(version>=6) 'create index booking_requests_registration_idx on local_booking_requests(account_id,dispatch_registered,created_local_at,request_id)',
      if(version>=7) 'create index booking_requests_current_day_idx on local_booking_requests(account_id,well_id,scheduled_day,request_id) where superseded_by_request_id is null',
      if(version>=8) "create index farm_parent_mapping_idx on id_mappings(account_id,server_id,local_id) where entity_kind='farmerWellAccount'",
    ]) { await db.execute(sql); }
    if(version>=9) {
      await db.execute('''create table notification_events (
        local_id integer primary key autoincrement,account_id text not null,well_id text,
        event_key text not null,category text not null,event_type text not null,
        entity_type text not null,entity_id text,route_type text not null,
        route_payload_json text not null,privacy_class text not null,presentation_policy text not null,
        state text not null default 'pending' check(state in ('pending','presenting','delivered','suppressed')),
        attempt_count integer not null default 0,lease_until text,delivered_at text,
        suppressed_at text,suppressed_reason text,created_at text not null
        ${version>=10 ? ", due_at integer, schedule_state text not null default 'none' check(schedule_state in ('none','arm_pending','arming','armed','cancel_pending','cancelling','cancelled','elapsed')) check((due_at is null and schedule_state='none') or (due_at is not null and schedule_state!='none')), schedule_attempt_count integer not null default 0 check(schedule_attempt_count between 0 and 3)" : ''},
        unique(account_id,event_key))''');
      await db.execute("create index notification_pending_idx on notification_events(account_id,local_id) where ${version>=10 ? 'due_at is null and ' : ''}state in ('pending','presenting')");
      if(version>=10) {
        await db.execute('create index notification_schedule_due_idx on notification_events(account_id,schedule_state,due_at,local_id) where due_at is not null');
        await db.execute("create index notification_schedule_lease_idx on notification_events(account_id,schedule_state,lease_until,local_id) where due_at is not null and schedule_state in ('arming','cancel_pending','cancelling')");
        await db.execute("create index notification_schedule_entity_idx on notification_events(account_id,well_id,entity_type,entity_id,local_id) where due_at is not null and schedule_state in ('arm_pending','arming','armed','cancel_pending','cancelling')");
      }
      await db.insert('notification_events',{
        'local_id':7,'account_id':'a','well_id':'w','event_key':'retained','category':'booking_results',
        'event_type':'booking.rejected','entity_type':'booking_request','entity_id':'A',
        'route_type':'bookings','route_payload_json':badRoute?'broken':'{"day":"2027-01-01","request_id":"A"}',
        'privacy_class':'private','presentation_policy':'always_alert','state':'delivered',
        'attempt_count':2,'delivered_at':time,'created_at':time,
        if(version>=10) ...{'due_at':1798761600000000,'schedule_state':'armed','schedule_attempt_count':2},
      });
    }
    final base=<String,Object?>{'account_id':'a','well_id':'w','created_local_at':time,
      'scheduled_day':'2027-01-01','payload':payload,'display_context':'{"farm_name":"retained"}'};
    await db.insert('local_booking_requests',{...base,'request_id':'A','command_id':'cmd-A','response':rejection,
      if(version>=6) 'dispatch_registered':1,
      if(version>=7) 'superseded_by_request_id':'B'});
    await db.insert('local_booking_requests',{...base,'request_id':'B','command_id':'cmd-B',
      if(version>=6) 'dispatch_registered':0,
      if(version>=7) 'replaces_request_id':'A'});
    Map<String,Object?> row(String id,String type,String data,int sequence) => {
      'local_id':id,'command_id':'command-$id','command_type':type,'account_id':'a','well_id':null,
      'sequence':sequence,'occurred_at':time,'created_local_at':time,'payload':data,'status':'pending',
      'retry_count':2,'last_attempt_at':time,'last_error':'retained retry',
      if(version>=5) 'next_attempt_at':'2027-01-02T00:00:00.000Z',
    };
    await db.insert('outbox_commands',row('retry','createBooking',payload,1));
    await db.insert('outbox_commands',row('farm','createFarm',badPayload?'broken':
      '{"p_well_id":"w","p_farmer_well_account_id":"f","p_name":"land","p_distinguishing_label":"east"}',2));
    await db.insert('outbox_commands',row('pending-booking','createBooking',
      jsonEncode({...jsonDecode(payload) as Map<String,dynamic>,'p_farm_id':{r'$ref':'farm',r'$kind':'farm'}}),3));
    await db.insert('outbox_commands',row('session','startAdhocSession','{"p_well_id":"w"}',4));
    await db.insert('id_mappings',{'account_id':'a','local_id':'historic','entity_kind':'farm','server_id':'canonical','resolved_at':time});
    await db.insert('sync_meta',{'account_id':'a','key':'sequence_counter','value':'4'});
  }));
  await db.close();
}

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late DatabaseFactory factory;
  setUp(() async {
    dir=await Directory.systemTemp.createTemp('booking_v11_');
    factory=noJsonSqliteFactory(databaseFactoryFfi);
  });
  tearDown(() async {await dir.delete(recursive:true);});
  for(final version in [4,5,6,7,8,9,10]) {
    test('explicit v$version file upgrades preserving identities, lineage, result, retry and projections without JSON1',() async {
      final path='${dir.path}/v$version';
      await legacyFile(factory,path,version);
      final beforeDb=await factory.openDatabase(path,options:OpenDatabaseOptions(singleInstance:false));
      final beforeRequests=await beforeDb.query('local_booking_requests',orderBy:'request_id');
      final beforeEvents=version>=9 ? await beforeDb.query('notification_events') : <Map<String,Object?>>[];
      await beforeDb.close();
      final store=SqliteOutboxStore(databasePath:path,sqfliteFactory:factory,singleInstance:false);
      try {
        await store.initialize();
        final db=store.notificationEvents.db;
        expect(await db.getVersion(),11);
        final after=await db.query('local_booking_requests',orderBy:'request_id');
        for(var i=0;i<beforeRequests.length;i++) {
          for(final key in beforeRequests[i].keys) { expect(after[i][key],beforeRequests[i][key],reason:'v$version $key'); }
        }
        expect(after.first['response'],rejection);
        expect(after.first['dispatch_registered'],1);
        expect(after.last['dispatch_registered'],0);
        if(version>=7) {
          expect(after.first['superseded_by_request_id'],'B');
          expect(after.last['replaces_request_id'],'A');
        }
        final retry=(await store.commandByLocalId('a','retry'))!;
        expect(retry.commandId,'command-retry');
        expect(retry.retryCount,2);
        expect(retry.lastError,'retained retry');
        expect(retry.nextAttemptAt,version>=5?DateTime.utc(2027,1,2):null);
        final farm=(await db.query('outbox_commands',where:'local_id=?',whereArgs:['farm'])).single;
        expect(farm['farmer_ref_kind'],'server'); expect(farm['farmer_ref_id'],'f');
        expect(farm['farm_name'],'land'); expect(farm['farm_distinguishing_label'],'east');
        expect(farm['well_id'],'w');
        final pending=(await db.query('outbox_commands',where:'local_id=?',whereArgs:['pending-booking'])).single;
        expect(pending['booking_farm_local_id'],'farm');
        expect(await store.sessionSnapshot(accountId:'a',wellId:'w',localSessionId:'session'),isNotNull);
        final indexes=(await db.rawQuery("select name from sqlite_master where type='index'")).map((r)=>r['name']).toSet();
        expect(indexes,containsAll(['booking_requests_day_idx','booking_requests_registration_idx','booking_requests_current_day_idx',
          'outbox_booking_dispatch_idx','outbox_booking_well_idx','outbox_booking_due_idx','outbox_booking_stale_idx',
          'outbox_farm_selection_idx','farm_parent_mapping_idx','notification_pending_idx',
          'notification_schedule_due_idx','notification_schedule_lease_idx','notification_schedule_entity_idx','notification_schedule_scope_idx']));
        expect(indexes,isNot(contains('outbox_projection_backfill_idx')));
        expect(await db.query('notification_reconcile_keys'),isEmpty);
        final events=await db.query('notification_events');
        if(version>=9) {
          for(final key in beforeEvents.single.keys) {expect(events.single[key],beforeEvents.single[key]);}
          expect(events.single['route_day'],'2027-01-01');
        } else {expect(events,isEmpty);}
        // Registration recovery creates one immutable command, with no resend of A.
        await store.bookingCreatesReady('a',now:DateTime.utc(2027));
        await store.bookingCreatesReady('a',now:DateTime.utc(2027));
        expect(await db.query('outbox_commands',where:'command_id=?',whereArgs:['cmd-B']),hasLength(1));
        expect(await db.query('outbox_commands',where:'command_id=?',whereArgs:['cmd-A']),isEmpty);
        expect((await store.bookingRequest('a','w','B'))!.payloadJson,payload);
        await store.close(); await store.initialize();
        expect((await store.bookingRequest('a','w','A'))!.responseJson,rejection);
      } finally {await store.close();}
    });
  }
  for(final kind in ['payload','route']) {
    test('malformed legacy $kind rolls back version, rows and complete schema',() async {
      final path='${dir.path}/bad';
      await legacyFile(factory,path,10,badPayload:kind=='payload',badRoute:kind=='route');
      var db=await factory.openDatabase(path,options:OpenDatabaseOptions(singleInstance:false));
      Future<Map<String,Object?>> snapshot(Database db) async => {
        'schema':await db.rawQuery("select type,name,sql from sqlite_master where name not like 'sqlite_%' order by name"),
        for(final table in ['outbox_commands','local_booking_requests','id_mappings','notification_events','sync_meta']) table:await db.query(table,orderBy:'rowid'),
      };
      final before=await snapshot(db); await db.close();
      final store=SqliteOutboxStore(databasePath:path,sqfliteFactory:factory,singleInstance:false);
      await expectLater(store.initialize(),throwsFormatException);
      await store.close();
      db=await factory.openDatabase(path,options:OpenDatabaseOptions(singleInstance:false));
      expect(await db.getVersion(),10);
      expect(await snapshot(db),before);
      await db.close();
    });
  }
}

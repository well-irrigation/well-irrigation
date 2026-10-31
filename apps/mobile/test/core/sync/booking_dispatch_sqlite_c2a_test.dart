import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/booking/local_booking_request.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import 'booking_dispatch_c2a_test.dart' show booking, epoch, Transport, accepted;

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late SqliteOutboxStore store;
  SqliteOutboxStore open() => SqliteOutboxStore(databasePath: '${dir.path}/outbox.db', sqfliteFactory: databaseFactoryFfi, singleInstance: false);
  setUp(() async { dir = await Directory.systemTemp.createTemp('c2a_dispatch'); store = open(); await store.initialize(); });
  tearDown(() async { await store.close(); await dir.delete(recursive: true); });

  test('SQLite query is bounded, deterministic, account/type/state scoped, and indexed', () async {
    for (var i = 0; i < 45; i++) { await store.insert(booking(i)); }
    await store.insert(booking(100, account: 'b'));
    await store.insert(booking(101, type: CommandType.createFarmer));
    await store.markConfirmed('a', 'a-local-0', serverResponse: {'status': 'confirmed'}, attemptedAt: epoch);
    await store.markNeedsReview('a', 'a-local-1', error: 'rule', attemptedAt: epoch);
    final rows = await store.bookingCreatesReady('a', now: epoch);
    expect(rows, hasLength(20));
    expect(rows.map((r) => r.sequence), List.generate(20, (i) => i + 2));
    expect(rows.every((r) => r.type == CommandType.createBooking && r.accountId == 'a'), isTrue);
    expect((await store.bookingCreatesReady('b', now: epoch)).map((r) => r.commandId), ['b-command-100']);
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/outbox.db', options: OpenDatabaseOptions(singleInstance: false));
    try {
      final plan = await db.rawQuery('EXPLAIN QUERY PLAN ${SqliteOutboxStore.bookingReadySql}', ['a', epoch.toIso8601String(), epoch.toIso8601String(), 20]);
      final details = plan.map((r) => r['detail']).join('\n');
      expect(details, contains('outbox_booking_dispatch_idx'));
      expect(details, contains('outbox_booking_well_idx'));
      expect(details, isNot(contains('SCAN c')));
    } finally { await db.close(); }
  });

  test('two SQLite connections enforce one active command per well and three lanes per account', () async {
    for (var i = 0; i < 5; i++) { await store.insert(booking(i, well: i == 1 ? 'well-0' : 'well-$i')); }
    await store.insert(booking(6, account: 'b'));
    final other = open();
    await other.initialize();
    try {
      final claims = await Future.wait([
        store.claimBookingCreate('a', 'a-local-0', attemptedAt: epoch),
        other.claimBookingCreate('a', 'a-local-0', attemptedAt: epoch),
      ]);
      expect(claims.where((c) => c), hasLength(1));
      expect(await other.claimBookingCreate('a', 'a-local-1', attemptedAt: epoch), isFalse);
      expect(await other.claimBookingCreate('a', 'a-local-2', attemptedAt: epoch), isTrue);
      expect(await store.claimBookingCreate('a', 'a-local-3', attemptedAt: epoch), isTrue);
      expect(await other.claimBookingCreate('a', 'a-local-4', attemptedAt: epoch), isFalse);
      expect(await other.claimBookingCreate('b', 'b-local-6', attemptedAt: epoch), isTrue);
    } finally { await other.close(); }
  });

  test('retry state survives reopen, remains gated, and stale completion cannot replace a newer result', () async {
    await store.insert(booking(0));
    expect(await store.claimBookingCreate('a', 'a-local-0', attemptedAt: epoch), isTrue);
    final due = epoch.add(const Duration(seconds: 37));
    expect(await store.finishBookingCreate('a', 'a-local-0', claimedAt: epoch, status: CommandStatus.pending, nextAttemptAt: due, error: 'timeout'), isTrue);
    await store.close();
    store = open();
    await store.initialize();
    var row = (await store.commandByLocalId('a', 'a-local-0'))!;
    expect(row.commandId, 'a-command-0');
    expect(row.retryCount, 1);
    expect(row.nextAttemptAt, due);
    expect(row.payload, booking(0).payload);
    expect(await store.bookingCreatesReady('a', now: epoch), isEmpty);
    expect(await store.claimBookingCreate('b', 'a-local-0', attemptedAt: due), isFalse);
    expect(await store.claimBookingCreate('a', 'a-local-0', attemptedAt: due), isTrue);
    expect(await store.finishBookingCreate('a', 'a-local-0', claimedAt: due, status: CommandStatus.review, response: {'status': 'rejected'}), isTrue);
    expect(await store.finishBookingCreate('a', 'a-local-0', claimedAt: epoch, status: CommandStatus.confirmed, response: {'status': 'confirmed'}, entityId: 'fake'), isFalse);
    row = (await store.commandByLocalId('a', 'a-local-0'))!;
    expect(row.status, CommandStatus.review);
    expect(row.serverResponse!['status'], 'rejected');
    expect(await store.mapping('a', row.localId, EntityKind.booking), isNull);
  });

  test('same-well blocked predecessors do not crowd out a different eligible well', () async {
    await store.insert(booking(0, well: 'blocked'));
    await store.claimBookingCreate('a', 'a-local-0', attemptedAt: epoch);
    await store.finishBookingCreate('a', 'a-local-0', claimedAt: epoch, status: CommandStatus.pending, nextAttemptAt: epoch.add(const Duration(hours: 1)));
    for (var i = 1; i < 35; i++) { await store.insert(booking(i, well: 'blocked')); }
    await store.insert(booking(40, well: 'free'));
    expect((await store.bookingCreatesReady('a', now: epoch)).map((c) => c.localId), ['a-local-40']);
  });

  test('foreground/background race on a real file sends one command once and persists its mapping', () async {
    await store.insert(booking(0));
    final other = open();
    await other.initialize();
    final gate = Completer<DispatchResult>();
    final transport = Transport((r) => gate.future);
    try {
      final first = SyncEngine(store: store, transport: transport, clock: () => epoch).runBookingCreates('a');
      // Wait for the observable dispatch, not an arbitrary time or a fake completion.
      for (var i = 0; i < 100 && transport.requests.isEmpty; i++) { await Future<void>.delayed(const Duration(milliseconds: 5)); }
      expect(transport.requests, hasLength(1));
      await SyncEngine(store: other, transport: transport, clock: () => epoch).runBookingCreates('a');
      expect(transport.requests, hasLength(1));
      gate.complete(accepted(transport.requests.single));
      await first;
      expect((await store.commandByLocalId('a', 'a-local-0'))!.status, CommandStatus.confirmed);
      expect((await other.mapping('a', 'a-local-0', EntityKind.booking))!.serverId, 'booking-a-command-0');
    } finally { await other.close(); }
  });

  test('upgrade from accepted C1 v4 preserves request bytes, IDs, and old outbox rows', () async {
    final request = LocalBookingRequest(accountId: 'a', wellId: 'well', requestId: 'request', commandId: 'c1-command', createdLocalAt: epoch,
      scheduledDay: '2027-01-01', payloadJson: jsonEncode(booking(0, well: 'well').payload), contextJson: '{"farmer_name":"أحمد"}');
    await store.saveBookingRequest(request);
    await store.insert(booking(10, type: CommandType.createFarmer));
    await store.close();
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/outbox.db', options: OpenDatabaseOptions(singleInstance: false));
    final beforeCommands = await db.query('outbox_commands');
    await db.execute('drop index booking_requests_current_day_idx');
    await db.execute('alter table local_booking_requests drop column replaces_request_id');
    await db.execute('alter table local_booking_requests drop column superseded_by_request_id');
    await db.execute('DROP INDEX booking_requests_registration_idx');
    await db.execute('ALTER TABLE local_booking_requests DROP COLUMN dispatch_registered');
    await db.execute('DROP INDEX outbox_booking_dispatch_idx');
    await db.execute('DROP INDEX outbox_booking_well_idx');
    await db.execute('DROP INDEX outbox_booking_due_idx');
    await db.execute('DROP INDEX outbox_booking_stale_idx');
    await db.execute('ALTER TABLE outbox_commands DROP COLUMN next_attempt_at');
    await db.execute('drop table notification_events');
    await db.setVersion(4);
    await db.close();
    store = open();
    await store.initialize();
    final restored = (await store.bookingRequest('a', 'well', 'request'))!;
    expect(restored.payloadJson, request.payloadJson);
    expect(restored.contextJson, request.contextJson);
    expect(restored.commandId, 'c1-command');
    final legacy = (await store.commandByLocalId('a', 'a-local-10'))!;
    expect(legacy.commandId, beforeCommands.singleWhere((row) => row['command_type'] == 'createFarmer')['command_id']);
    expect(legacy.payload, booking(10, type: CommandType.createFarmer).payload);
    expect(legacy.nextAttemptAt, isNull);
    final inspect = await databaseFactoryFfi.openDatabase('${dir.path}/outbox.db', options: OpenDatabaseOptions(singleInstance: false));
    expect(await inspect.getVersion(), SqliteOutboxStore.schemaVersion);
    await inspect.close();
  });

  test('process death after claim is recovered boundedly without changing command ID', () async {
    await store.insert(booking(0));
    await store.claimBookingCreate('a', 'a-local-0', attemptedAt: epoch);
    await store.close();
    store = open();
    await store.initialize();
    var now = epoch.add(const Duration(minutes: 3));
    final transport = Transport((r) async => accepted(r));
    final engine = SyncEngine(store: store, transport: transport, clock: () => now);
    final recovered = await engine.runBookingCreates('a');
    expect(recovered.recoveredClaims, 1);
    expect(transport.requests, isEmpty);
    final row = (await store.commandByLocalId('a', 'a-local-0'))!;
    now = row.nextAttemptAt!;
    await engine.runBookingCreates('a');
    expect(transport.requests.single.commandId, 'a-command-0');
    expect((await store.commandByLocalId('a', 'a-local-0'))!.status, CommandStatus.confirmed);
  });
}

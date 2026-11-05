import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import '../../support/accepted_completion_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';

import 'local_booking_transition_regression_test.dart' as f;

void main() {
  WellDaySchedule schedule(String status) {
    final base = f.fieldSchedule();
    return WellDaySchedule(
      wellId: 'well',
      requestedDay: base.requestedDay,
      serverTime: base.serverTime,
      timezone: base.timezone,
      wellTimezone: base.wellTimezone,
      dayStart: base.dayStart,
      dayEnd: base.dayEnd,
      bookings: [f.booking('A', 43, status: status)],
    );
  }

  test(
    'cancelled out-of-window booking is only source of actual start facts',
    () async {
      final store = InMemoryOutboxStore();
      final c = OfflineSessionCoordinator(store: store);
      final actual = f.at(20);
      final start = await c.startBookedSession(
        accountId: 'account',
        wellId: 'well',
        bookingId: 'A',
        displayPump: const Pump(
          id: 'pump',
          wellId: 'well',
          name: 'مضخة',
          publicCode: 'P',
        ),
        cachedSchedule: f.cached(schedule('cancelled')),
        automation: null,
        startedAt: actual,
      );
      expect(start.type, CommandType.startOperationalSession);
      expect(start.payload['p_source_booking_id'], 'A');
      expect(start.payload.containsKey('p_booking_id'), isFalse);
      expect(start.payload.containsKey('p_planned_duration_minutes'), isFalse);
      expect(start.payload.containsKey('p_scheduled_end'), isFalse);
      expect(start.occurredAt, actual);
      final active = await c.freshProjectActiveSession(
        accountId: 'account',
        wellId: 'well',
      );
      expect(active, isNotNull);
      expect(active!.phoneOwned, isFalse);
      expect(active.bookedOperationalEnd, isNull);
      final again = await c.freshProjectActiveSession(
        accountId: 'account',
        wellId: 'well',
      );
      expect(again!.localId, active.localId);
      expect(
        (await store.allCommands('account'))
            .where((x) => x.type == CommandType.startOperationalSession),
        hasLength(1),
      );
      c.dispose();
    },
  );
  test('booking source reuses unresolved occurrence across reopen but creates new occurrence after closure', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('r6ab-booking-reuse-');
    SqliteOutboxStore open() => SqliteOutboxStore(databasePath:'${dir.path}/db',sqfliteFactory:databaseFactoryFfi,singleInstance:false);
    var store = open(); var c = OfflineSessionCoordinator(store:store);
    Future<dynamic> start() => c.startBookedSession(accountId:'account',wellId:'well',bookingId:'A',displayPump:const Pump(id:'pump',wellId:'well',name:'مضخة',publicCode:'P'),cachedSchedule:f.cached(schedule('confirmed')),automation:null,startedAt:f.at(20));
    try {
      final first = await start(); final duplicate = await start();
      expect(duplicate.commandId,first.commandId);
      c.dispose(); await store.close(); store = open(); c = OfflineSessionCoordinator(store:store);
      final resumed = await start(); expect(resumed.commandId,first.commandId);
      await store.markConfirmed('account',first.localId,serverResponse:{'id':'server'},attemptedAt:f.at(20));
      await c.completeSession(accountId:'account',sessionLocalId:first.localId,completedAt:f.at(21));
      await acceptTestCompletion(store:store,coordinator:c,accountId:'account',wellId:'well');
      final second = await start(); expect(second.commandId,isNot(first.commandId));
      expect(second.payload['p_source_booking_id'],'A');
      expect((await store.allCommands('account')).where((x)=>x.type==CommandType.startOperationalSession),hasLength(2));
    } finally { c.dispose(); await store.close(); await dir.delete(recursive:true); }
  });
  test('missing pump does not enqueue', () async {
    final store = InMemoryOutboxStore();
    final c = OfflineSessionCoordinator(store: store);
    await expectLater(
      c.startBookedSession(
        accountId: 'account',
        wellId: 'well',
        bookingId: 'A',
        cachedSchedule: f.cached(schedule('confirmed')),
        automation: null,
      ),
      throwsStateError,
    );
    expect(await store.allCommands('account'), isEmpty);
    c.dispose();
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

Map<String, Object?> day(String value) => {
  'status': 'ok',
  'well_id': 'w',
  'requested_day': value,
  'timezone': 'Asia/Aden',
  'well_timezone': 'Asia/Aden',
  'day_start': '${value}T00:00:00Z',
  'day_end': '${value}T23:59:59Z',
  'bookings': <Object>[],
};
void main() {
  setUpAll(sqfliteFfiInit);
  test('future cache does not overwrite today pointer; bulk load is scoped and bounded', () async {
    final dir = await Directory.systemTemp.createTemp('notification_days');
    addTearDown(() => dir.delete(recursive: true));
    final store = SqliteOutboxStore(
      databasePath: '${dir.path}/db',
      sqfliteFactory: databaseFactoryFfi,
    );
    await store.initialize();
    addTearDown(store.close);
    final ledger = BookingLocalLedger(store);
    await ledger.saveSchedule(
      accountId: 'a',
      wellId: 'w',
      response: day('2027-01-01'),
      fetchedAt: DateTime.utc(2027),
    );
    await ledger.saveSchedule(
      accountId: 'a',
      wellId: 'w',
      response: day('2027-01-02'),
      fetchedAt: DateTime.utc(2027),
      updateLatest: false,
    );
    expect(
      (await ledger.loadLatestSchedule('a', 'w'))!.schedule.requestedDay,
      DateTime(2027),
    );
    expect(
      (await ledger.loadSchedules('a', 'w', {
        '2027-01-01',
        '2027-01-02',
      })).length,
      2,
    );
    expect(await ledger.loadSchedules('b', 'w', {'2027-01-01'}), isEmpty);
    expect(await ledger.loadSchedules('a', 'other', {'2027-01-01'}), isEmpty);
    await expectLater(
      ledger.loadSchedules('a', 'w', {
        for (var i = 1; i <= 21; i++) '2027-01-${i.toString().padLeft(2, '0')}',
      }),
      throwsArgumentError,
    );
  });
}

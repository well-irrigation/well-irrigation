import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/entity_reference.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';

import '../sync/fake_command_transport.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  for (final result in [
    'created',
    'matched_existing',
    'requires_disambiguation',
    'requires_resolution',
  ]) {
    test(
      'farm $result emits nothing by itself; only dependent booking result creates event',
      () async {
        final dir = await Directory.systemTemp.createTemp('c3_farm');
        final path = '${dir.path}/db';
        final store = SqliteOutboxStore(
          databasePath: path,
          sqfliteFactory: databaseFactoryFfi,
          singleInstance: false,
        );
        await store.initialize();
        final db = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        final coordinator = OfflineSessionCoordinator(store: store);
        try {
          final farm = await coordinator.enqueueFarm(
            accountId: 'a',
            wellId: 'w',
            name: 'الوادي',
            farmerReference: const ServerEntityReference('f'),
          );
          final repo = BookingRepository(null, null, BookingLocalLedger(store));
          await repo.saveLocalBooking(
            accountId: 'a',
            wellId: 'w',
            requestId: 'r',
            farmer: const FarmerAccount(
              id: 'f',
              fullName: 'أحمد',
              publicCode: 'F',
            ),
            farm: farm,
            scheduledStart: DateTime.utc(2027, 1, 1, 7),
            scheduledEnd: DateTime.utc(2027, 1, 1, 8),
            expectedEnergySource: 'well_diesel',
          );
          final transport = FakeCommandTransport();
          final engine = SyncEngine(store: store, transport: transport);
          await engine.runBookingCreates('a');
          expect(transport.requests, isEmpty);
          expect(await db.query('notification_events'), isEmpty);
          transport.scheduleRawResponse(CommandType.createFarm, {
            'status': result,
            'farm_id': 'existing',
            'candidate_farm_ids': ['existing'],
            'existing_labels': ['الشرقية'],
          });
          await engine.run('a');
          expect(await db.query('notification_events'), isEmpty);
          transport.scheduleRawResponse(CommandType.createBooking, {
            'status': 'confirmed',
            'booking_id': 'b',
            'public_code': 'B',
            'well_id': 'w',
            'scheduled_start': '2027-01-01T07:00:00.000Z',
            'scheduled_end': '2027-01-01T08:00:00.000Z',
          });
          await engine.runBookingCreates('a');
          final rows = await db.query('notification_events');
          expect(rows, hasLength(1));
          expect(
            rows.single['event_type'],
            result == 'created' || result == 'matched_existing'
                ? 'booking.confirmed'
                : 'booking.rejected',
          );
          expect(rows.single['entity_type'], 'booking_request');
        } finally {
          coordinator.dispose();
          await db.close();
          await store.close();
          await dir.delete(recursive: true);
        }
      },
    );
  }
}

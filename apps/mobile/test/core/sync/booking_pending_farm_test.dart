import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/background_sync_coordinator.dart';

import 'fake_background_sync_scheduler.dart';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/sync/entity_reference.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';

import 'fake_command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_reference.dart';


// Test-local durable farm fixture; no farm-creation UI or session runtime.
Future<Farm> pendingFarm(SqliteOutboxStore store) async {
  final at = DateTime.utc(2027);
  await store.insert(CommandEnvelope(localId: 'farm-local', commandId: 'farm-command',
    type: CommandType.createFarm, accountId: 'a', wellId: 'w',
    sequence: await store.nextSequence('a'), occurredAt: at, createdLocalAt: at,
    payload: {'p_well_id': 'w', 'p_farmer_well_account_id': 'f', 'p_name': 'أرض',
      'p_distinguishing_label': null}));
  return Farm.pending(reference: const CommandReference(localId: 'farm-local',kind: EntityKind.farm),
    wellId: 'w', name: 'أرض', farmerReference: const ServerEntityReference('f'));
}

void main() {
  setUpAll(sqfliteFfiInit);
  test('booking envelope accepts only direct farm reference and rejects all other reference shapes', () {
    final time = DateTime.utc(2027);
    CommandEnvelope envelope(Map<String, Object?> extra) => CommandEnvelope(
      localId: 'b',
      commandId: 'b',
      type: CommandType.createBooking,
      accountId: 'a',
      wellId: 'w',
      sequence: 2,
      occurredAt: time,
      createdLocalAt: time,
      payload: {
        'p_well_id': 'w',
        'p_farmer_well_account_id': 'f',
        'p_farm_id': 'farm',
        ...extra,
      },
    );
    expect(
      envelope({
        'p_farm_id': {r'$ref': 'land', r'$kind': 'farm'},
      }).references,
      hasLength(1),
    );
    for (final bad in [
      {
        'p_farm_id': {r'$ref': 'land', r'$kind': 'session'},
      },
      {
        'p_farm_id': {r'$ref': '', r'$kind': 'farm'},
      },
      {
        'p_farm_id': {r'$ref': 'land', r'$kind': 'farm', 'extra': 1},
      },
      {
        'p_farmer_well_account_id': {
          r'$ref': 'farmer',
          r'$kind': 'farmerWellAccount',
        },
      },
      {
        'p_notes': {r'$ref': 'other', r'$kind': 'farm'},
      },
      {
        'p_farm_id': {
          'nested': {r'$ref': 'land', r'$kind': 'farm'},
        },
      },
    ]) {
      expect(() => envelope(bad), throwsArgumentError);
    }
  });
  test('one bounded worker opportunity runs after farm mapping, without busy drain', () async {
    final dir = await Directory.systemTemp.createTemp('farm_wake');
    final store = SqliteOutboxStore(
      databasePath: '${dir.path}/db',
      sqfliteFactory: databaseFactoryFfi,
    );
    await store.initialize();
    final farm = await pendingFarm(store);
    final repo = BookingRepository(null, null, BookingLocalLedger(store));
    await repo.saveLocalBooking(
      accountId: 'a',
      wellId: 'w',
      requestId: 'r',
      farmer: const FarmerAccount(id: 'f', fullName: 'أحمد', publicCode: 'F'),
      farm: farm,
      scheduledStart: DateTime.utc(2027, 1, 1, 7),
      scheduledEnd: DateTime.utc(2027, 1, 1, 8),
      expectedEnergySource: 'well_diesel',
    );
    final transport = FakeCommandTransport();
    transport.scheduleRawResponse(CommandType.createFarm, {
      'status': 'matched_existing',
      'farm_id': 'existing',
    });
    transport.scheduleRawResponse(CommandType.createBooking, {
      'status': 'confirmed',
      'booking_id': 'b',
      'public_code': 'B',
      'well_id': 'w',
      'scheduled_start': '2027-01-01T07:00:00.000Z',
      'scheduled_end': '2027-01-01T08:00:00.000Z',
    });
    final scheduler = FakeBackgroundSyncScheduler();
    final background = BackgroundSyncCoordinator(
      engine: SyncEngine(store: store, transport: transport),
      scheduler: scheduler,
    );
    await background.runFromApp('a');
      if(transport.requestsFor(CommandType.createBooking).isEmpty){
        expect(scheduler.scheduled,hasLength(1));
        await background.runFromWorker('a');
      }
    expect(transport.requests.map((r) => r.type), [
      CommandType.createFarm,
      CommandType.createBooking,
    ]);
    expect(transport.requests.last.arguments['p_farm_id'], 'existing');
    expect(scheduler.scheduled.length,lessThanOrEqualTo(1));
    await store.close();
    await dir.delete(recursive: true);
  });
  for (final result in [
    'created',
    'matched_existing',
    'requires_disambiguation',
    'requires_resolution',
  ]) {
    test(
      'pending farm $result: durable immutable booking waits then resolves or needs correction',
      () async {
        final dir = await Directory.systemTemp.createTemp('farm_booking');
        SqliteOutboxStore open() => SqliteOutboxStore(
          databasePath: '${dir.path}/data.db',
          sqfliteFactory: databaseFactoryFfi,
          singleInstance: false,
        );
        var store = open();
        await store.initialize();
        final farm = await pendingFarm(store);
        final repo = BookingRepository(null, null, BookingLocalLedger(store));
        final request = await repo.saveLocalBooking(
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
        final bytes = request.payloadJson;
        expect(request.payload['p_farm_id'], {
          '\$ref': farm.entityReference.localReference!.localId,
          '\$kind': 'farm',
        });
        expect(request.canStart, false);
            await store.close();
        store = open();
        await store.initialize();
        final transport = FakeCommandTransport();
        final engine = SyncEngine(store: store, transport: transport);
        final wait = await engine.runBookingCreates('a');
        expect(wait.attempted, 0);
        expect(wait.bookingNextWake, isNull);
        expect(transport.requests, isEmpty);
        transport.scheduleRawResponse(CommandType.createFarm, {
          'status': result,
          'farm_id': 'existing-farm',
          'candidate_farm_ids': ['existing-farm'],
          'existing_labels': ['الشرقية'],
        });
        await engine.run('a');
        transport.scheduleRawResponse(CommandType.createBooking, {
          'status': 'confirmed',
          'booking_id': 'b',
          'public_code': 'B',
          'well_id': 'w',
          'scheduled_start': '2027-01-01T07:00:00.000Z',
          'scheduled_end': '2027-01-01T08:00:00.000Z',
        });
        await engine.runBookingCreates('a');
        final saved = await store.bookingRequest('a', 'w', 'r');
        expect(saved!.payloadJson, bytes);
        expect(saved.commandId, request.commandId);
        final sent = transport.requestsFor(CommandType.createBooking);
        if (result == 'created' || result == 'matched_existing') {
          expect(sent, hasLength(1));
          expect(sent.single.arguments['p_farm_id'], 'existing-farm');
          expect(sent.single.commandId, request.commandId);
        } else {
          expect(sent, isEmpty);
          expect(saved.needsCorrection, true);
          expect(saved.correctionAction, 'تعديل الحجز');
          final replacement =
              await BookingRepository(
                null,
                null,
                BookingLocalLedger(store),
              ).saveLocalBooking(
                accountId: 'a',
                wellId: 'w',
                requestId: 'replacement',
                farmer: const FarmerAccount(
                  id: 'f',
                  fullName: 'أحمد',
                  publicCode: 'F',
                ),
                farm: const Farm(
                  id: 'chosen',
                  wellId: 'w',
                  name: 'أرض مختارة',
                  farmerAccountId: 'f',
                ),
                scheduledStart: DateTime.utc(2027, 1, 1, 7),
                scheduledEnd: DateTime.utc(2027, 1, 1, 8),
                expectedEnergySource: 'well_diesel',
                replaces: saved,
              );
          expect(replacement.replacesRequestId, 'r');
          expect(replacement.commandId, isNot(request.commandId));
          expect(
            (await store.bookingRequest('a', 'w', 'r'))!.payloadJson,
            bytes,
          );
        }
        await store.close();
        await dir.delete(recursive: true);
      },
    );
  }
}

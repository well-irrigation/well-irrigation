import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/entity_reference.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import '../sync/fake_command_transport.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  group('M21 Farm Deduplication & Coordinator Sync Tests (Finding 11)', () {
    const accountId = 'acc-test';
    const wellId = 'well-01';

    late InMemoryOutboxStore store;
    late FakeCommandTransport transport;
    late SyncEngine syncEngine;
    late OfflineSessionCoordinator coordinator;

    setUp(() async {
      store = InMemoryOutboxStore();
      await store.initialize();
      transport = FakeCommandTransport();
      syncEngine = SyncEngine(store: store, transport: transport);
      coordinator = OfflineSessionCoordinator(store: store);
      await coordinator.initialize();
    });

    tearDown(() {
      coordinator.dispose();
    });

    test('A. enqueueFarmer -> enqueueFarm -> startSession produces reference chain', () async {
      final farmer = await coordinator.enqueueFarmer(
        accountId: accountId,
        wellId: wellId,
        fullName: 'علي عبد الله الحبيشي',
        phone: '771122334',
      );
      expect(farmer.isPending, isTrue);
      expect(farmer.entityReference, isA<PendingLocalEntityReference>());

      final farm = await coordinator.enqueueFarm(
        accountId: accountId,
        wellId: wellId,
        name: 'الكوثة',
        distinguishingLabel: 'الشرقية',
        farmerReference: farmer.entityReference,
      );
      expect(farm.isPending, isTrue);
      expect(farm.displayName, 'الكوثة — الشرقية');
      expect(farm.entityReference, isA<PendingLocalEntityReference>());

      final localFarmerId =
          farmer.entityReference.localReference?.localId ?? '';
      final localFarmId = farm.entityReference.localReference?.localId ?? '';

      await coordinator.startSession(
        accountId: accountId,
        wellId: wellId,
        pumpId: 'pump-01',
        farmId: localFarmId,
        farmerAccountId: localFarmerId,
        farmReference: farm.entityReference,
        farmerReference: farmer.entityReference,
        energySource: 'طاقة شمسية',
      );

      final commands = await store.allCommands(accountId);
      expect(commands.length, 3);

      final farmerCmd = commands[0];
      final farmCmd = commands[1];
      final sessionCmd = commands[2];

      expect(farmerCmd.type, CommandType.createFarmer);
      expect(farmCmd.type, CommandType.createFarm);
      expect(sessionCmd.type, CommandType.startIrrigationSession);

      // Verify reference chain
      final farmFarmerRef = farmCmd.payload['p_farmer_well_account_id'] as Map;
      expect(farmFarmerRef[r'$ref'], farmerCmd.localId);

      final sessionFarmerRef =
          sessionCmd.payload['p_farmer_well_account_id'] as Map;
      final sessionFarmRef = sessionCmd.payload['p_farm_id'] as Map;
      expect(sessionFarmerRef[r'$ref'], farmerCmd.localId);
      expect(sessionFarmRef[r'$ref'], farmCmd.localId);
    });

    test('B. unresolved parent prevents child dispatch', () async {
      // Schedule network failure for createFarmer so it cannot be confirmed
      transport.scheduleNetworkFailure(CommandType.createFarmer, times: 1);

      final farmer = await coordinator.enqueueFarmer(
        accountId: accountId,
        wellId: wellId,
        fullName: 'أحمد صالح',
      );
      await coordinator.enqueueFarm(
        accountId: accountId,
        wellId: wellId,
        name: 'مزرعة الشمال',
        farmerReference: farmer.entityReference,
      );

      final report = await syncEngine.run(accountId);
      // createFarmer attempted and scheduled for retry
      expect(report.retryScheduled, 1);
      // child createFarm was skipped because parent is not resolved/confirmed
      expect(report.skipped, greaterThanOrEqualTo(1));

      // Confirm child createFarm was NEVER dispatched to transport
      expect(transport.requestsFor(CommandType.createFarm), isEmpty);
    });

    test('C. real SqliteOutboxStore reopen: enqueue -> close -> reopen same DB -> reconstruct pending farmer/farm without displaying local IDs', () async {
      final tempDir = await Directory.systemTemp.createTemp('m21_sqlite_reopen_');
      final dbPath = '${tempDir.path}/outbox.db';

      try {
        final store1 = SqliteOutboxStore(
          databasePath: dbPath,
          sqfliteFactory: databaseFactoryFfi,
        );
        await store1.initialize();
        final coordinator1 = OfflineSessionCoordinator(store: store1);
        await coordinator1.initialize();

        final farmer = await coordinator1.enqueueFarmer(
          accountId: accountId,
          wellId: wellId,
          fullName: 'يحيى أحمد الشامي',
        );
        final farm = await coordinator1.enqueueFarm(
          accountId: accountId,
          wellId: wellId,
          name: 'الكوثة',
          distinguishingLabel: 'الغربية',
          farmerReference: farmer.entityReference,
        );

        final farmerLocalId =
            farmer.entityReference.localReference?.localId ?? 'local-unknown';
        final farmLocalId =
            farm.entityReference.localReference?.localId ?? 'local-unknown';

        // Close store and coordinator (simulate process death / app close)
        coordinator1.dispose();
        await store1.close();

        // Reopen same DB in fresh store / coordinator
        final store2 = SqliteOutboxStore(
          databasePath: dbPath,
          sqfliteFactory: databaseFactoryFfi,
        );
        await store2.initialize();
        final coordinator2 = OfflineSessionCoordinator(store: store2);
        await coordinator2.initialize();

        final pendingFarmers = await coordinator2.pendingFarmers(
          accountId: accountId,
          wellId: wellId,
        );
        expect(pendingFarmers.length, 1);
        final reconstructedFarmer = pendingFarmers.first;
        expect(reconstructedFarmer.fullName, 'يحيى أحمد الشامي');
        expect(reconstructedFarmer.isPending, isTrue);
        // local ID must never appear in user-facing name
        expect(reconstructedFarmer.fullName.contains('local-'), isFalse);
        expect(reconstructedFarmer.fullName.contains(farmerLocalId), isFalse);

        final pendingFarms = await coordinator2.pendingFarms(
          accountId: accountId,
          wellId: wellId,
        );
        expect(pendingFarms.length, 1);
        final reconstructedFarm = pendingFarms.first;
        expect(reconstructedFarm.name, 'الكوثة');
        expect(reconstructedFarm.distinguishingLabel, 'الغربية');
        expect(reconstructedFarm.displayName, 'الكوثة — الغربية');
        expect(reconstructedFarm.displayName.contains('local-'), isFalse);
        expect(reconstructedFarm.displayName.contains(farmLocalId), isFalse);

        coordinator2.dispose();
        await store2.close();
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('D. conflict: requires_resolution through real JSON -> review, structured serverResponse persisted, dependent child becomes blockedByReview', () async {
      const conflictResponse = {
        'status': 'requires_resolution',
        'conflict_type': 'duplicate_candidate',
        'message': 'يوجد مزارع مشابه يتطلب المطابقة',
        'candidate_farmer_id': '00000000-0000-0000-0000-000000000001',
      };

      // Pass real conflict JSON through production normalization path
      transport.scheduleRawResponse(
        CommandType.createFarmer,
        conflictResponse,
      );

      final farmer = await coordinator.enqueueFarmer(
        accountId: accountId,
        wellId: wellId,
        fullName: 'نزاع مزارع',
      );
      await coordinator.enqueueFarm(
        accountId: accountId,
        wellId: wellId,
        name: 'أرض تابعة لمزارع النزاع',
        farmerReference: farmer.entityReference,
      );

      final report = await syncEngine.run(accountId);
      expect(report.needsReview, 1);
      expect(report.blockedByReview, 1);

      final farmerCmd = (await store.allCommands(accountId)).first;
      expect(farmerCmd.status, CommandStatus.review);
      expect(farmerCmd.serverResponse, equals(conflictResponse));

      // Child command is blocked from dispatch
      expect(transport.requestsFor(CommandType.createFarm), isEmpty);
    });

    test('CommandStatus.review MUST NOT be returned as ordinary selectable pending entity', () async {
      final farmer = await coordinator.enqueueFarmer(
        accountId: accountId,
        wellId: wellId,
        fullName: 'مزارع نزاع للمراجعة',
      );

      var pending = await coordinator.pendingFarmers(
        accountId: accountId,
        wellId: wellId,
      );
      expect(pending.length, 1);

      // Transition the command to review (e.g. business conflict)
      await store.markNeedsReview(
        accountId,
        farmer.entityReference.localReference!.localId,
        error: 'نزاع تنظيمي',
        attemptedAt: DateTime.now(),
        serverResponse: {'status': 'requires_resolution'},
      );

      pending = await coordinator.pendingFarmers(
        accountId: accountId,
        wellId: wellId,
      );
      // Command in review status must NOT be selectable
      expect(pending, isEmpty);
    });

    test('G. rapid double submit farmer with actionToken -> one enqueue', () async {
      const actionToken = 'action-token-submit-999';
      final results = await Future.wait([
        coordinator.enqueueFarmer(
          accountId: accountId,
          wellId: wellId,
          fullName: 'سعيد صالح الحبيشي',
          phone: '770000000',
          actionToken: actionToken,
        ),
        coordinator.enqueueFarmer(
          accountId: accountId,
          wellId: wellId,
          fullName: 'سعيد صالح الحبيشي',
          phone: '770000000',
          actionToken: actionToken,
        ),
      ]);

      expect(results[0].reference, equals(results[1].reference));
      final commands = (await store.allCommands(accountId))
          .where((c) => c.type == CommandType.createFarmer)
          .toList();
      expect(commands.length, 1);
    });

    test('two distinct farmers with same name without actionToken are not merged by name alone', () async {
      final f1 = await coordinator.enqueueFarmer(
        accountId: accountId,
        wellId: wellId,
        fullName: 'سعيد صالح الحبيشي',
        phone: '771111111',
      );
      final f2 = await coordinator.enqueueFarmer(
        accountId: accountId,
        wellId: wellId,
        fullName: 'سعيد صالح الحبيشي',
        phone: '772222222',
      );

      expect(f1.reference, isNot(equals(f2.reference)));
      final commands = (await store.allCommands(accountId))
          .where((c) => c.type == CommandType.createFarmer)
          .toList();
      expect(commands.length, 2);
    });

    test('H. rapid double submit farm -> one enqueue', () async {
      final farmerRef = ServerEntityReference('server-farmer-99');

      final results = await Future.wait([
        coordinator.enqueueFarm(
          accountId: accountId,
          wellId: wellId,
          name: 'مزرعة الوادي',
          distinguishingLabel: 'القبلية',
          farmerReference: farmerRef,
        ),
        coordinator.enqueueFarm(
          accountId: accountId,
          wellId: wellId,
          name: 'مزرعة الوادي',
          distinguishingLabel: 'القبلية',
          farmerReference: farmerRef,
        ),
      ]);

      expect(results[0].reference, equals(results[1].reference));
      final commands = (await store.allCommands(accountId))
          .where((c) => c.type == CommandType.createFarm)
          .toList();
      expect(commands.length, 1);
    });
  });
}

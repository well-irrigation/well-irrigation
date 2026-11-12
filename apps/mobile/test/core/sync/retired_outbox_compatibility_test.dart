@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/api/account_repository.dart';
import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/supabase_command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import 'fake_command_transport.dart';

// persisted command_type storage ABI — قائمة حرفية مستقلة عن enum.
// بعد إصدار نسخة تخزن اسمًا، تصبح القائمة append-only. حذف الاسم أو إعادة
// تسميته يتطلب compatibility path؛ لا يجوز مجرد حذفه من enum أو هذه القائمة.
// القيمة تحدد تقاعد النوع صراحةً؛ false لا تمنح بحد ذاتها صلاحية إرسال.
const _persistedCommandTypeStorageAbi = <String, bool>{
  'cancelBooking': true,
  'rescheduleBooking': true,
  'recordHistoricalSession': false,
  'adoptExternalSession': false,
  'createBooking': false,
  'createFarmer': false,
  'createFarm': false,
  'startOperationalSession': false,
  'startIrrigationSession': false,
  'startAdhocSession': false,
  'startBookingSession': false,
  'pauseIrrigationSession': false,
  'resumeIrrigationSession': false,
  'changeSessionEnergySource': false,
  'recordPayment': false,
  'completeIrrigationSession': false,
  'recordBookingTransitionDecision': false,
  'executePendingBookingStart': false,
  'endBookingTransitionChain': false,
  'resolveFarmerIdentity': false,
  'correctIrrigationSession': false,
  'adjustSessionFinancialAmount': false,
};

// ccba538 (2026-10-28): CommandType.cancelBooking.storageValue == name.
// Its coordinator persisted p_booking_id/p_reason, and schemaVersion was 11.
void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late String dbPath;
  SqliteOutboxStore? store;
  final at = DateTime.utc(2026, 10, 29);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('retired-outbox-');
    dbPath = '${dir.path}/outbox.db';
  });
  tearDown(() async {
    await store?.close();
    await dir.delete(recursive: true);
  });

  Future<void> seed(
    String type, {
    String status = 'pending',
    String? well,
  }) async {
    final schema = SqliteOutboxStore(
      databasePath: dbPath,
      sqfliteFactory: databaseFactoryFfi,
    );
    await schema.initialize();
    await schema.close();
    final db = await databaseFactoryFfi.openDatabase(dbPath);
    try {
      await db.insert('outbox_commands', {
        'local_id': 'historical-row',
        'command_id': 'original-command',
        'command_type': type,
        'account_id': 'account-a',
        'well_id': well,
        'sequence': 1,
        'occurred_at': at.toIso8601String(),
        'created_local_at': at.toIso8601String(),
        'payload': type == 'recordPayment'
            ? '{"p_well_id":"well-a","p_farmer_well_account_id":"farmer-a","p_amount_minor":100,"p_method":"cash"}'
            : type == 'rescheduleBooking'
            ? '{"p_booking_id":"booking-a","p_scheduled_start":"2026-10-30T08:00:00Z","p_scheduled_end":"2026-10-30T09:00:00Z","p_reason":"سبب محفوظ"}'
            : '{"p_booking_id":"booking-a","p_reason":"سبب محفوظ"}',
        'status': status,
        'retry_count': 2,
        if (status == 'dispatching') 'last_attempt_at': at.toIso8601String(),
        if (status == 'confirmed')
          'server_response': '{"status":"accepted","booking_id":"booking-a"}',
      });
      expect(await db.getVersion(), 11);
    } finally {
      await db.close();
    }
    store = SqliteOutboxStore(
      databasePath: dbPath,
      sqfliteFactory: databaseFactoryFfi,
    );
    await store!.initialize();
  }

  for (final legacy in const {
    'cancelBooking': 'cancel_booking',
    'rescheduleBooking': 'reschedule_booking',
  }.entries) {
    final legacyType = legacy.key;
    group(legacyType, () {
      for (final status in ['pending', 'dispatching', 'confirmed', 'review']) {
        for (final well in [null, 'well-a']) {
          test(
            'raw $legacyType $status well=$well survives reopen without dispatch',
            () async {
              await seed(legacyType, status: status, well: well);
              // Before the fix this real query throws StateError: No element from
              // commandsForWell -> _fromRow -> CommandType.fromStorage.firstWhere.
              final row = (await store!.commandsForWell(
                'account-a',
                'well-a',
              )).single;
              expect(row.type.storageValue, legacyType);
              expect(row.type.isRetired, isTrue);
              expect(row.type.rpcName, legacy.value);
              expect(row.type.scope, CommandScope.well);
              expect(row.type.scopeArgument, 'p_booking_id');
              expect(row.type.returnsJson, isTrue);
              expect(row.type.resultKey, 'booking_id');
              expect(row.type.eventTimeArgument, isNull);
              expect(row.type.produces, isNull);
              expect(row.commandId, 'original-command');
              expect(row.occurredAt, at);
              expect(row.wellId, well);
              expect(row.status.storageValue, status);
              expect(row.payload, {
                'p_booking_id': 'booking-a',
                'p_reason': 'سبب محفوظ',
                if (legacyType == 'rescheduleBooking') ...{
                  'p_scheduled_start': '2026-10-30T08:00:00Z',
                  'p_scheduled_end': '2026-10-30T09:00:00Z',
                },
              });
              expect(
                (await store!.allCommands('account-a')).single.type,
                row.type,
              );
              expect(
                await store!.commandsForWell('account-b', 'well-a'),
                isEmpty,
              );
              expect(await store!.allCommands('account-b'), isEmpty);
              if (well != null) {
                expect(
                  await store!.commandsForWell('account-a', 'well-b'),
                  isEmpty,
                );
              }

              final transport = FakeCommandTransport();
              final engine = SyncEngine(
                store: store!,
                transport: transport,
                clock: () => DateTime.utc(2026, 11, 11),
              );
              await engine.run('account-a');
              await engine.run('account-a');
              expect(transport.requests, isEmpty);
              expect(
                await ActiveSessionProjector(store: store!)
                    .activeSessions('account-a', now: at),
                isEmpty,
              );
              await store!.close();
              store = SqliteOutboxStore(
                databasePath: dbPath,
                sqfliteFactory: databaseFactoryFfi,
              );
              await store!.initialize();
              final restored = (await store!.allCommands('account-a')).single;
              expect(restored.type, row.type);
              expect(restored.status, row.status);
              expect(restored.payload, row.payload);
              expect(restored.commandId, row.commandId);
              expect(restored.occurredAt, row.occurredAt);
              expect(restored.createdLocalAt, row.createdLocalAt);
              expect(restored.serverResponse, row.serverResponse);
              expect(restored.lastAttemptAt, row.lastAttemptAt);
              expect(restored.retryCount, row.retryCount);
            },
          );
        }
      }

      for (final status in ['pending', 'dispatching', 'review', 'confirmed']) {
        test(
          'retired $status is historical, not actionable device/logout/review work',
          () async {
            await seed(legacyType, status: status, well: 'well-a');
            final original = (await store!.allCommands('account-a')).single;
            final outbox = OutboxRepository(store: store!);
            final coordinator = OfflineSessionCoordinator(
              store: store!,
              commandTransport: FakeCommandTransport(),
            );
            addTearDown(coordinator.dispose);
            final account = AccountRepository(null, coordinator);
            expect(await outbox.pendingCount('account-a'), 0);
            expect(await outbox.pending('account-a'), isEmpty);
            expect(await outbox.needingReview('account-a'), isEmpty);
            expect(
              (await account.fetchDeviceSyncStatus('account-a'))
                  .pendingOperationsCount,
              0,
            );
            expect(
              await account.checkPendingOperationsBeforeLogout('account-a'),
              0,
            );
            final historical = (await outbox.all('account-a')).single;
            expect(historical.status, original.status);
            expect(historical.payload, original.payload);
            expect(historical.serverResponse, original.serverResponse);
            expect(
              (await outbox.byLocalId(
                'account-a',
                original.localId,
              ))!.commandId,
              original.commandId,
            );
            expect(
              await store!.pendingCommands('account-a'),
              status == 'confirmed' ? isEmpty : hasLength(1),
            );
          },
        );

        test(
          'manual sync with only retired $status reports nothing pending, never incomplete',
          () async {
            await seed(legacyType, status: status, well: 'well-a');
            final transport = FakeCommandTransport();
            final coordinator = OfflineSessionCoordinator(
              store: store!,
              commandTransport: transport,
            );
            addTearDown(coordinator.dispose);
            await expectLater(
              AccountRepository(
                null,
                coordinator,
              ).triggerManualSync('account-a'),
              throwsA(isA<ManualSyncNothingPendingException>()),
            );
            await coordinator.syncNow('account-a');
            expect(transport.requests, isEmpty);
            expect(
              (await store!.allCommands('account-a'))
                  .single
                  .status
                  .storageValue,
              status,
            );
          },
        );
      }

      test('general actionable review keeps current review and excludes retired review', () async {
        await seed(legacyType, status: 'review', well: 'well-a');
        await store!.nextSequence('account-a');
        final outbox = OutboxRepository(store: store!);
        final current = await outbox.enqueue(
          accountId: 'account-a',
          wellId: 'well-a',
          type: CommandType.createFarmer,
          occurredAt: at,
          payload: {'p_well_id': 'well-a', 'p_full_name': 'مزارع اختبار'},
        );
        await store!.markNeedsReview(
          'account-a',
          current.localId,
          error: 'requires_review',
          attemptedAt: at,
        );
        expect(
          (await outbox.needingReview('account-a')).map((c) => c.localId),
          [current.localId],
        );
        expect(await outbox.pendingCount('account-a'), 1);
        expect(await outbox.all('account-a'), hasLength(2));
      });

      test('mixed retired/current pending counts one and syncs only current intent', () async {
        await seed(legacyType, well: 'well-a');
        await store!.nextSequence('account-a');
        final outbox = OutboxRepository(store: store!);
        final current = await outbox.enqueue(
          accountId: 'account-a',
          wellId: 'well-a',
          type: CommandType.createFarmer,
          occurredAt: at,
          payload: {'p_well_id': 'well-a', 'p_full_name': 'مزارع اختبار'},
        );
        final transport = FakeCommandTransport();
        final coordinator = OfflineSessionCoordinator(
          store: store!,
          commandTransport: transport,
        );
        addTearDown(coordinator.dispose);
        final account = AccountRepository(null, coordinator);
        expect(await outbox.pendingCount('account-a'), 1);
        expect((await outbox.pending('account-a')).map((c) => c.localId), [
          current.localId,
        ]);
        expect(
          (await account.fetchDeviceSyncStatus('account-a'))
              .pendingOperationsCount,
          1,
        );
        expect(
          await account.checkPendingOperationsBeforeLogout('account-a'),
          1,
        );
        await account.triggerManualSync('account-a');
        expect(transport.requests.map((r) => r.commandId), [current.commandId]);
        expect(await outbox.pendingCount('account-a'), 0);
        expect(
          await account.checkPendingOperationsBeforeLogout('account-a'),
          0,
        );
        expect(
          (await outbox.byLocalId('account-a', current.localId))!.status,
          CommandStatus.confirmed,
        );
        expect(
          (await outbox.byLocalId('account-a', 'historical-row'))!.status,
          CommandStatus.pending,
        );
        expect(await outbox.all('account-a'), hasLength(2));
      });

      for (final status in ['pending', 'dispatching', 'review']) {
        test(
          'retired unresolved $status prerequisite never authorizes dependent write',
          () async {
            await seed(legacyType, status: status, well: 'well-a');
            await store!.nextSequence('account-a');
            final outbox = OutboxRepository(store: store!);
            final current = await outbox.prepare(
              accountId: 'account-a',
              wellId: 'well-a',
              type: CommandType.createFarmer,
              occurredAt: at,
              payload: {'p_well_id': 'well-a', 'p_full_name': 'مزارع اختبار'},
              prerequisites: ['historical-row'],
            );
            await store!.insert(current);
            final transport = FakeCommandTransport();
            await SyncEngine(
              store: store!,
              transport: transport,
            ).run('account-a');
            expect(transport.requests, isEmpty);
            expect(
              (await outbox.byLocalId('account-a', current.localId))!.status,
              status == 'review' ? CommandStatus.review : CommandStatus.pending,
            );
            expect(await outbox.pendingCount('account-a'), 1);
            expect(
              (await outbox.byLocalId(
                'account-a',
                'historical-row',
              ))!.status.storageValue,
              status,
            );
          },
        );
      }

      test('retired row cannot build an RPC or bypass sync through direct transport', () async {
        await seed(legacyType, well: 'well-a');
        final c = (await store!.allCommands('account-a')).single;
        expect(
          () => buildRpcArguments(
            type: c.type,
            commandId: c.commandId,
            occurredAt: c.occurredAt,
            resolvedPayload: c.payload,
          ),
          throwsStateError,
        );
        var calls = 0;
        final client = SupabaseClient(
          'https://retired.invalid',
          'key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((_) async {
            calls++;
            return http.Response('{}', 200);
          }),
        );
        addTearDown(client.dispose);
        await client.auth.recoverSession(
          jsonEncode({
            'access_token': 'test-token',
            'token_type': 'bearer',
            'refresh_token': 'test-refresh',
            'user': {
              'id': 'account-a',
              'aud': 'authenticated',
              'created_at': '',
            },
          }),
        );
        final result = await SupabaseCommandTransport(client).dispatch(
          DispatchRequest(
            accountId: c.accountId,
            type: c.type,
            commandId: c.commandId,
            arguments: c.payload,
          ),
        );
        expect(result, isA<DispatchFailed>());
        expect(
          (result as DispatchFailed).disposition,
          FailureDisposition.review,
        );
        expect(result.executionNotStarted, isFalse);
        expect(calls, 0);
      });
    });
  }

  test('persisted command_type ABI retains every released name and retirement classification', () {
    expect(_persistedCommandTypeStorageAbi['cancelBooking'], isTrue);
    expect(_persistedCommandTypeStorageAbi['rescheduleBooking'], isTrue);
    for (final entry in _persistedCommandTypeStorageAbi.entries) {
      final decoded = CommandType.fromStorage(entry.key);
      expect(decoded.storageValue, entry.key, reason: entry.key);
      expect(decoded.isRetired, entry.value, reason: entry.key);
    }
    expect(
      CommandType.values.map((type) => type.storageValue),
      unorderedEquals(_persistedCommandTypeStorageAbi.keys),
    );
  });

  test('current stored command names keep exact identities', () async {
    await seed('recordPayment', well: 'well-a', status: 'confirmed');
    expect(
      (await store!.allCommands('account-a')).single.type,
      CommandType.recordPayment,
    );
    expect(
      (await store!.commandsForWell('account-a', 'well-a')).single.type,
      CommandType.recordPayment,
    );
  });

  for (final value in [
    'futureUnknownCommand',
    'cancel_booking',
    ' cancelBooking',
  ]) {
    test('unknown storage diagnostic preserves literal value: $value', () {
      expect(
        () => CommandType.fromStorage(value),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'unknown_command_type_storage_value:$value',
          ),
        ),
      );
    });
    test(
      'unknown/corrupt $value remains fail closed without dropping row',
      () async {
        await seed(value, well: 'well-a');
        await expectLater(
          store!.commandsForWell('account-a', 'well-a'),
          throwsStateError,
        );
        await expectLater(store!.allCommands('account-a'), throwsStateError);
        await store!.close();
        final db = await databaseFactoryFfi.openDatabase(dbPath);
        try {
          final raw = (await db.query('outbox_commands')).single;
          expect(raw['command_type'], value);
          expect(raw['command_id'], 'original-command');
        } finally {
          await db.close();
        }
      },
    );
  }
}

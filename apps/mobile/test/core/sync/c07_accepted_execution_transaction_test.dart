import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/notifications/operational_notification_event_factory.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import 'c07_start_receipt_store_test.dart' show ReceiptStoreFixture, startReceipt;

final _at = DateTime.utc(2027, 1, 1, 1);
final _response = <String, Object?>{
  'session_id': 'server-session',
  'session_charge_id': 'charge',
  'status': 'closed',
  'ended_at': '2027-01-01T01:00:00.000Z',
  'actual_seconds': 3600,
  'billable_seconds': 3500,
  'weighted_price_per_hour_minor': 12345,
  'amount_minor': 11987,
  'segments': <Object?>[],
};

Future<void> _seed(OutboxStore store) async {
  await store.insert(
    CommandEnvelope(
      localId: 'root',
      commandId: 'original-start',
      accountId: 'a',
      wellId: 'w',
      type: CommandType.startIrrigationSession,
      sequence: 1,
      occurredAt: _at.subtract(const Duration(hours: 1)),
      createdLocalAt: _at,
      payload: const {'p_well_id': 'w'},
      status: CommandStatus.confirmed,
      serverResponse: const {'id': 'server-session'},
    ),
  );
  await store.putMapping(
    'a',
    IdMapping(
      localId: 'root',
      kind: EntityKind.session,
      serverId: 'server-session',
      resolvedAt: _at,
    ),
  );
  final completion = CommandEnvelope(
    localId: 'end',
    commandId: 'original-completion',
    accountId: 'a',
    wellId: 'w',
    aggregateLocalId: 'root',
    type: CommandType.completeIrrigationSession,
    sequence: 2,
    occurredAt: _at,
    createdLocalAt: _at,
    prerequisites: const ['root'],
    payload: const {
      'p_session_id': {r'$ref': 'root', r'$kind': 'session'},
    },
  );
  await store.insertBundle(
    accountId: 'a',
    key: humanCommandIntentBundleKey('end'),
    value: humanCommandIntentRecord(completion),
    commands: [completion],
  );
}

Future<DispatchAttempt> _claim(OutboxStore store) async {
  final result = await (store as AtomicCommandDispatchStore).claimDispatch(
    accountId: 'a',
    wellId: 'w',
    localId: 'end',
    commandId: 'original-completion',
    attemptedAt: _at,
    policy: (context) =>
        context.intent.origin == CommandIntentOrigin.provenHuman
        ? DispatchClaimDecision.allow
        : DispatchClaimDecision.originUnresolved,
  );
  expect(result.isClaimed, isTrue);
  return result.attempt!;
}

Future<Map<String, Object?>> _snapshot(OutboxStore store) async => {
  'commands': [
    for (final c in await store.allCommands('a'))
      {
        'local': c.localId,
        'command': c.commandId,
        'type': c.type,
        'payload': c.payload,
        'context': c.localContext,
        'status': c.status,
        'response': c.serverResponse,
        'error': c.lastError,
        'attempted': c.lastAttemptAt,
        'retry': c.retryCount,
      },
  ],
  'mappings': [
    for (final m in await store.mappings('a'))
      [m.localId, m.kind, m.serverId, m.resolvedAt, m.matchedExisting],
  ],
  'current': await store.readBundle('a', dispatchAttemptCurrentKey('end')),
  if (store is SqliteOutboxStore)
    'tables': {
      for (final table in [
        'outbox_commands',
        'id_mappings',
        'sync_meta',
        'notification_events',
      ])
        table: await store.notificationEvents.db.query(
          table,
          orderBy: table == 'notification_events' ? 'local_id' : 'rowid',
        ),
    },
};

DispatchAttempt _changed(DispatchAttempt a, String field) => DispatchAttempt(
  accountId: field == 'account' ? 'other' : a.accountId,
  wellId: field == 'well' ? 'other' : a.wellId,
  localId: field == 'local' ? 'other' : a.localId,
  commandId: field == 'command' ? 'other' : a.commandId,
  commandType: field == 'type'
      ? CommandType.startIrrigationSession
      : a.commandType,
  attemptId: field == 'token' ? 'other' : a.attemptId,
  startedAt: field == 'time'
      ? a.startedAt.add(const Duration(microseconds: 1))
      : a.startedAt,
);

void main() {
  setUpAll(sqfliteFfiInit);
  for (final fault in ['none', 'event', 'cancellation']) {
    test('direct booking start atomic effects rollback=$fault', () async {
      final f = ReceiptStoreFixture(true);
      await f.open();
      try {
        await f.seedStart();
        final owner = DispatchAttempt.parse(await f.store.readBundle('a', dispatchAttemptCurrentKey('start')))!;
        final reminder = bookingReminderEvents(accountId: 'a', wellId: 'w', bookingId: 'booking',
          scheduledStart: owner.startedAt, createdAt: owner.startedAt).first;
        await f.sql.notificationEvents.saveSchedule(reminder.event, reminder.due, owner.startedAt.subtract(const Duration(hours: 1)));
        if (fault != 'none') {
          await f.sql.notificationEvents.db.execute(fault == 'event'
            ? "create trigger start_fault before insert on notification_events when new.event_type='session.started' begin select raise(abort,'injected'); end"
            : "create trigger start_fault before update of schedule_state on notification_events when new.schedule_state='cancel_pending' begin select raise(abort,'injected'); end");
          final before = await f.snapshot();
          await expectLater(f.atomic.finishDispatchAttempt(owner, status: CommandStatus.confirmed,
            serverResponse: startReceipt(), entityId: 'session'), throwsA(anything));
          expect(await f.snapshot(), before);
          await f.sql.notificationEvents.db.execute('drop trigger start_fault');
        }
        expect(await f.atomic.finishDispatchAttempt(owner, status: CommandStatus.confirmed,
          serverResponse: startReceipt(), entityId: 'session'), isTrue);
        final events = await f.sql.notificationEvents.db.query('notification_events', where: "event_type='session.started'");
        expect(events, hasLength(1));
        expect((await f.sql.notificationEvents.db.query('notification_events', where: 'due_at is not null')).single['schedule_state'], 'cancel_pending');
        expect((await f.store.mapping('a', 'start', EntityKind.session))!.serverId, 'session');
        expect(events.single['event_key'], 'session.started/original-start');
        final before = await f.snapshot();
        expect(await f.atomic.finishDispatchAttempt(owner, status: CommandStatus.confirmed,
          serverResponse: startReceipt(), entityId: 'session'), isFalse);
        expect(await f.snapshot(), before);
      } finally { await f.close(); }
    });
  }

  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite ownership' : 'memory ownership', () {
      late OutboxStore store;
      Directory? dir;
      setUp(() async {
        dir = null;
        if (sqlite) {
          dir = await Directory.systemTemp.createTemp('c07a_owner_');
          store = SqliteOutboxStore(
            databasePath: '${dir!.path}/db',
            sqfliteFactory: databaseFactoryFfi,
            singleInstance: false,
          );
        } else {
          store = InMemoryOutboxStore();
        }
        await store.initialize();
        await _seed(store);
      });
      tearDown(() async {
        await store.close();
        await dir?.delete(recursive: true);
      });

      test(
        'current owner commits response, mapping and matching terminal history',
        () async {
          final owner = await _claim(store);
          final response =
              jsonDecode(jsonEncode(_response)) as Map<String, dynamic>;
          expect(
            await (store as AtomicCommandDispatchStore).finishDispatchAttempt(
              owner,
              status: CommandStatus.confirmed,
              serverResponse: response,
              entityId: 'charge',
            ),
            isTrue,
          );
          response['segments'] = ['mutated caller value'];
          final command = (await store.commandByLocalId('a', 'end'))!;
          expect(command.status, CommandStatus.confirmed);
          expect(command.commandId, 'original-completion');
          expect(command.occurredAt, _at);
          expect(command.serverResponse, _response);
          expect(
            (await store.mapping(
              'a',
              'end',
              EntityKind.sessionCharge,
            ))!.serverId,
            'charge',
          );
          final current = await store.readBundle(
            'a',
            dispatchAttemptCurrentKey('end'),
          );
          expect(
            DispatchAttempt.parse(current)!.state,
            DispatchAttemptState.confirmed,
          );
          expect(
            await store.readBundle(
              'a',
              dispatchAttemptHistoryKey('end', owner.attemptId),
            ),
            current,
          );
          final before = await _snapshot(store);
          expect(
            await (store as AtomicCommandDispatchStore).finishDispatchAttempt(
              owner,
              status: CommandStatus.confirmed,
              serverResponse: const {'replacement': true},
              entityId: 'other-charge',
            ),
            isFalse,
          );
          expect(await _snapshot(store), before);
        },
      );

      for (final field in [
        'account',
        'well',
        'local',
        'command',
        'type',
        'token',
        'time',
      ]) {
        test('wrong $field cannot change a claimed completion', () async {
          final owner = await _claim(store);
          final before = await _snapshot(store);
          expect(
            await (store as AtomicCommandDispatchStore).finishDispatchAttempt(
              _changed(owner, field),
              status: CommandStatus.confirmed,
              serverResponse: _response,
              entityId: 'charge',
            ),
            isFalse,
          );
          expect(await _snapshot(store), before);
          expect(
            await store.readBundle(
              'a',
              dispatchAttemptHistoryKey('end', owner.attemptId),
            ),
            await store.readBundle('a', dispatchAttemptCurrentKey('end')),
          );
        });
      }

      for (final inactiveCurrent in [false, true]) {
        test(
          'inactive history rejects finish; inactive current=$inactiveCurrent',
          () async {
            final owner = await _claim(store);
            final inactive = jsonEncode(
              owner.toJson(state: DispatchAttemptState.review),
            );
            await store.insertBundle(
              accountId: 'a',
              key: 'tamper',
              value: 'test',
              commands: const [],
              localValues: {
                dispatchAttemptHistoryKey('end', owner.attemptId): inactive,
                if (inactiveCurrent) dispatchAttemptCurrentKey('end'): inactive,
              },
            );
            final before = await _snapshot(store);
            expect(
              await (store as AtomicCommandDispatchStore).finishDispatchAttempt(
                owner,
                status: CommandStatus.confirmed,
                serverResponse: _response,
                entityId: 'charge',
              ),
              isFalse,
            );
            expect(await _snapshot(store), before);
          },
        );
      }

      test(
        'released older owner cannot overwrite a newer same-time owner',
        () async {
          final api = store as AtomicCommandDispatchStore;
          final old = await _claim(store);
          expect(
            await api.releaseDispatchAttempt(old, reason: 'explicit_retry'),
            isTrue,
          );
          expect(
            DispatchAttempt.parse(
              await store.readBundle(
                'a',
                dispatchAttemptHistoryKey('end', old.attemptId),
              ),
            )!.state,
            DispatchAttemptState.retryRequested,
          );
          final fresh = await _claim(store);
          expect(fresh.startedAt, old.startedAt);
          expect(fresh.attemptId, isNot(old.attemptId));
          final before = await _snapshot(store);
          expect(
            await api.finishDispatchAttempt(
              old,
              status: CommandStatus.confirmed,
              serverResponse: _response,
              entityId: 'charge',
            ),
            isFalse,
          );
          expect(await _snapshot(store), before);
          expect(
            await api.finishDispatchAttempt(
              fresh,
              status: CommandStatus.confirmed,
              serverResponse: _response,
              entityId: 'charge',
            ),
            isTrue,
          );
        },
      );

      for (final status in [CommandStatus.pending, CommandStatus.dispatching]) {
        test(
          'invalid terminal status ${status.name} leaves all state intact',
          () async {
            final owner = await _claim(store);
            final before = await _snapshot(store);
            await expectLater(
              Future.sync(
                () =>
                    (store as AtomicCommandDispatchStore).finishDispatchAttempt(
                      owner,
                      status: status,
                      serverResponse: _response,
                    ),
              ),
              throwsArgumentError,
            );
            expect(await _snapshot(store), before);
          },
        );
      }

      test(
        'confirmation without response leaves ownership and mapping intact',
        () async {
          final owner = await _claim(store);
          final before = await _snapshot(store);
          await expectLater(
            Future.sync(
              () => (store as AtomicCommandDispatchStore).finishDispatchAttempt(
                owner,
                status: CommandStatus.confirmed,
                entityId: 'charge',
              ),
            ),
            throwsArgumentError,
          );
          expect(await _snapshot(store), before);
        },
      );

      test('business review finalizes only current owner without confirmed mapping or completion event', () async {
        final owner = await _claim(store);
        expect(
          await (store as AtomicCommandDispatchStore).finishDispatchAttempt(
            owner,
            status: CommandStatus.review,
            error: 'business_rejected',
            serverResponse: const {'status': 'rejected'},
            entityId: 'not-accepted',
          ),
          isTrue,
        );
        final command = (await store.commandByLocalId('a', 'end'))!;
        expect(command.status, CommandStatus.review);
        expect(command.lastError, 'business_rejected');
        expect(command.serverResponse, {'status': 'rejected'});
        expect(
          await store.mapping('a', 'end', EntityKind.sessionCharge),
          isNull,
        );
        final current = await store.readBundle(
          'a',
          dispatchAttemptCurrentKey('end'),
        );
        expect(
          DispatchAttempt.parse(current)!.state,
          DispatchAttemptState.review,
        );
        expect(
          await store.readBundle(
            'a',
            dispatchAttemptHistoryKey('end', owner.attemptId),
          ),
          current,
        );
        if (store is SqliteOutboxStore) {
          expect(
            await (store as SqliteOutboxStore).notificationEvents.db.query(
              'notification_events',
            ),
            isEmpty,
          );
        }
      });
    });
  }

  group('SQLite accepted completion transaction', () {
    late Directory dir;
    late SqliteOutboxStore store;
    SqliteOutboxStore open() => SqliteOutboxStore(
      databasePath: '${dir.path}/db',
      sqfliteFactory: databaseFactoryFfi,
      singleInstance: false,
    );
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('c07a_transaction_');
      store = open();
      await store.initialize();
      await _seed(store);
      for (final account in ['a', 'other']) {
        final reminder = sessionNearEndEvent(
          accountId: account,
          wellId: 'w',
          sessionId: 'root',
          trustedEnd: _at.add(const Duration(hours: 2)),
          createdAt: _at,
        )!;
        await store.notificationEvents.saveSchedule(
          reminder.event,
          reminder.due,
          _at,
        );
      }
    });
    tearDown(() async {
      await store.close();
      await dir.delete(recursive: true);
    });

    Future<void> accepted(DispatchAttempt owner) async {
      expect(
        await store.finishDispatchAttempt(
          owner,
          status: CommandStatus.confirmed,
          serverResponse: _response,
          entityId: 'charge',
        ),
        isTrue,
      );
      final command = (await store.commandByLocalId('a', 'end'))!;
      expect(command.status, CommandStatus.confirmed);
      expect(command.serverResponse, _response);
      expect(
        (await store.mapping('a', 'end', EntityKind.sessionCharge))!.serverId,
        'charge',
      );
      final rows = await store.notificationEvents.db.query(
        'notification_events',
      );
      final event = rows.singleWhere(
        (r) => r['event_type'] == 'session.completed',
      );
      expect(event['event_key'], 'session.completed/original-completion');
      expect(event['account_id'], 'a');
      expect(event['well_id'], 'w');
      expect(event['entity_id'], 'root');
      expect(event['route_type'], 'operations');
      expect(event['route_payload_json'], '{}');
      expect(event['state'], 'pending');
      final reminder = rows.singleWhere(
        (r) => r['account_id'] == 'a' && r['due_at'] != null,
      );
      expect(reminder['schedule_state'], 'cancel_pending');
      expect(reminder['suppressed_reason'], 'session_completed');
      expect(
        rows.singleWhere((r) => r['account_id'] == 'other')['schedule_state'],
        'arm_pending',
      );
      final current = await store.readBundle(
        'a',
        dispatchAttemptCurrentKey('end'),
      );
      expect(
        DispatchAttempt.parse(current)!.state,
        DispatchAttemptState.confirmed,
      );
      expect(
        await store.readBundle(
          'a',
          dispatchAttemptHistoryKey('end', owner.attemptId),
        ),
        current,
      );
    }

    test(
      'all accepted writes survive reopen; a repeated finish changes nothing',
      () async {
        final owner = await _claim(store);
        await accepted(owner);
        final before = await _snapshot(store);
        await store.close();
        store = open();
        await store.initialize();
        expect(await _snapshot(store), before);
        expect(
          await store.finishDispatchAttempt(
            owner,
            status: CommandStatus.confirmed,
            serverResponse: _response,
            entityId: 'charge',
          ),
          isFalse,
        );
        expect(await _snapshot(store), before);
      },
    );

    for (final failure in ['event insert', 'reminder cancellation']) {
      test(
        '$failure fault rolls back every accepted write and permits same-owner retry after reopen',
        () async {
          final owner = await _claim(store);
          final db = store.notificationEvents.db;
          if (failure == 'event insert') {
            await db.execute(
              "create trigger c07_fault before insert on notification_events when new.event_type='session.completed' begin select raise(abort,'injected'); end",
            );
          } else {
            await db.execute(
              "create trigger c07_fault before update of schedule_state on notification_events when new.schedule_state='cancel_pending' begin select raise(abort,'injected'); end",
            );
          }
          final before = await _snapshot(store);
          await expectLater(
            store.finishDispatchAttempt(
              owner,
              status: CommandStatus.confirmed,
              serverResponse: _response,
              entityId: 'charge',
            ),
            throwsA(isA<DatabaseException>()),
          );
          expect(await _snapshot(store), before);
          expect(
            (await store.commandByLocalId('a', 'end'))!.status,
            CommandStatus.dispatching,
          );
          expect(
            (await store.commandByLocalId('a', 'end'))!.serverResponse,
            isNull,
          );
          expect(
            await store.mapping('a', 'end', EntityKind.sessionCharge),
            isNull,
          );
          await store.close();
          store = open();
          await store.initialize();
          expect(await _snapshot(store), before);
          await store.notificationEvents.db.execute('drop trigger c07_fault');
          await accepted(owner);
        },
      );
    }
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/notifications/operational_notification_event_factory.dart';
import 'package:well_irrigation_mobile/core/sync/booking_start_receipt.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

final receiptAt = DateTime.utc(2027, 1, 1, 7, 0, 0, 0, 123);
CommandEnvelope receiptStart({
  String account = 'a',
  String well = 'w',
  String command = 'original-start',
}) => CommandEnvelope(
  accountId: account,
  wellId: well,
  localId: 'start',
  commandId: command,
  type: CommandType.startBookingSession,
  sequence: 1,
  occurredAt: receiptAt,
  createdLocalAt: receiptAt,
  payload: const {
    'p_booking_id': 'booking',
    'p_crops': ['crop'],
  },
  localContext: const {'manual_start': true, 'booking_id': 'booking'},
);
Map<String, Object?> startReceipt() => {
  'session_id': 'session',
  'booking_id': 'booking',
  'well_id': 'w',
  'session_status': 'open',
  'booking_status': 'confirmed',
  'started_at': receiptAt.toIso8601String(),
  'operational_end_at': receiptAt
      .add(const Duration(minutes: 60))
      .toIso8601String(),
  'booked_duration_minutes': 60,
};

// Real stores; only temporary paths and platform scheduling are test-owned.
class ReceiptStoreFixture {
  ReceiptStoreFixture(this.sqlite);
  final bool sqlite;
  late OutboxStore store;
  Directory? dir;
  Future<void> open() async {
    if (sqlite) {
      dir ??= await Directory.systemTemp.createTemp('c07b_receipt_');
      store = SqliteOutboxStore(
        databasePath: '${dir!.path}/db',
        sqfliteFactory: databaseFactoryFfi,
        singleInstance: false,
      );
    } else {
      store = InMemoryOutboxStore();
    }
    await store.initialize();
  }

  Future<void> close() async {
    await store.close();
    await dir?.delete(recursive: true);
  }

  Future<void> reopen() async {
    await store.close();
    await open();
  }

  AtomicCommandDispatchStore get atomic => store as AtomicCommandDispatchStore;
  SqliteOutboxStore get sql => store as SqliteOutboxStore;
  Future<CommandEnvelope> seedStart() async {
    final command = receiptStart();
    await store.insertBundle(
      accountId: 'a',
      key: 'booking.manual_start.v1.w.booking',
      value: jsonEncode({
        'start_local_id': 'start',
        'start_command_id': 'original-start',
      }),
      commands: [command],
    );
    final claim = await atomic.claimDispatch(
      accountId: 'a',
      wellId: 'w',
      localId: 'start',
      commandId: 'original-start',
      attemptedAt: receiptAt,
      policy: (_) => DispatchClaimDecision.allow,
    );
    expect(claim.isClaimed, isTrue);
    return claim.command!;
  }

  Future<Map<String, Object?>> snapshot() async => {
    'commands': [
      for (final c in await store.allCommands('a'))
        {
          'id': c.localId,
          'command': c.commandId,
          'account': c.accountId,
          'well': c.wellId,
          'type': c.type,
          'payload': c.payload,
          'context': c.localContext,
          'at': c.occurredAt,
          'status': c.status,
          'response': c.serverResponse,
          'last': c.lastAttemptAt,
          'retry': c.retryCount,
          'error': c.lastError,
        },
    ],
    'mappings': [
      for (final m in await store.mappings('a'))
        [m.localId, m.kind, m.serverId, m.resolvedAt, m.matchedExisting],
    ],
    'metadata': await store.readLocalValuesByPrefix('a', ''),
    if (sqlite)
      'tables': {
        for (final table in [
          'outbox_commands',
          'id_mappings',
          'sync_meta',
          'notification_events',
        ])
          table: await sql.notificationEvents.db.query(table, orderBy: 'rowid'),
      },
  };
}

void main() {
  setUpAll(sqfliteFfiInit);
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite start' : 'memory start', () {
      late ReceiptStoreFixture f;
      late CommandEnvelope observed;
      setUp(() async {
        f = ReceiptStoreFixture(sqlite);
        await f.open();
        observed = await f.seedStart();
      });
      tearDown(() => f.close());
      Future<bool> adopt([Map<String, Object?>? receipt]) => f.atomic
          .reconcileBookingStartReceipt(observed, receipt ?? startReceipt());

      test('accepted original receipt adopts exact command and keeps attempt ownership records', () async {
        final metadata = await f.store.readLocalValuesByPrefix(
          'a',
          'command.dispatch.',
        );
        expect(await adopt(), isTrue);
        final row = (await f.store.commandByLocalId('a', 'start'))!;
        expect(row.status, CommandStatus.confirmed);
        expect(row.serverResponse, startReceipt());
        expect(row.commandId, 'original-start');
        expect(row.occurredAt, receiptAt);
        expect(
          (await f.store.mapping('a', 'start', EntityKind.session))!.serverId,
          'session',
        );
        expect(
          await f.store.readLocalValuesByPrefix('a', 'command.dispatch.'),
          metadata,
        );
        expect(await f.store.allCommands('a'), hasLength(1));
        final before = await f.snapshot();
        expect(await adopt(), isFalse);
        expect(await f.snapshot(), before);
      });
      test(
        'changed row cannot be overwritten by an older observed fingerprint',
        () async {
          await f.store.markNeedsReview(
            'a',
            'start',
            error: 'newer',
            attemptedAt: receiptAt,
            serverResponse: const {'status': 'rejected'},
          );
          final before = await f.snapshot();
          expect(await adopt(), isFalse);
          expect(await f.snapshot(), before);
        },
      );
      test('known business rejection cannot be reclassified even using the latest row', () async {
        await f.store.markNeedsReview(
          'a',
          'start',
          error: 'business',
          attemptedAt: receiptAt,
          serverResponse: const {'status': 'rejected'},
        );
        observed = (await f.store.commandByLocalId('a', 'start'))!;
        final before = await f.snapshot();
        expect(await adopt(), isFalse);
        expect(await f.snapshot(), before);
      });
      test('changed original human evidence rejects adoption', () async {
        await f.store.insertBundle(
          accountId: 'a',
          key: 'tamper',
          value: 'test',
          commands: const [],
          localValues: {
            'booking.manual_start.v1.w.booking': jsonEncode({
              'start_local_id': 'start',
              'start_command_id': 'other-command',
            }),
          },
        );
        final before = await f.snapshot();
        expect(await adopt(), isFalse);
        expect(await f.snapshot(), before);
      });
      test('conflicting session mapping is preserved', () async {
        await f.store.putMapping(
          'a',
          IdMapping(
            localId: 'start',
            kind: EntityKind.session,
            serverId: 'other-session',
            resolvedAt: receiptAt,
          ),
        );
        final before = await f.snapshot();
        expect(await adopt(), isFalse);
        expect(await f.snapshot(), before);
      });
      for (final (key, value) in <(String, Object?)>[
        ('booking_id', 'other'),
        ('well_id', 'other'),
        ('session_id', ''),
        (
          'started_at',
          receiptAt.add(const Duration(microseconds: 1)).toIso8601String(),
        ),
        ('booked_duration_minutes', 0),
        ('operational_end_at', 'invalid'),
        ('command_id', 'other'),
        ('session_status', 'closed'),
      ]) {
        test(
          'invalid receipt $key cannot confirm or change identity',
          () async {
            final before = await f.snapshot();
            expect(await adopt(startReceipt()..[key] = value), isFalse);
            expect(await f.snapshot(), before);
          },
        );
      }
      for (final command in [
        receiptStart(account: 'other'),
        receiptStart(well: 'other'),
        receiptStart(command: 'other'),
      ]) {
        test(
          'foreign observed scope ${command.accountId}/${command.wellId}/${command.commandId} is rejected',
          () async {
            final before = await f.snapshot();
            expect(
              await f.atomic.reconcileBookingStartReceipt(
                command,
                startReceipt(),
              ),
              isFalse,
            );
            expect(await f.snapshot(), before);
          },
        );
      }
      for (final state in ['processing', 'not_found', 'unresolved']) {
        test(
          '$state read leaves command and attempt unchanged without retry permission',
          () async {
            final before = await f.snapshot();
            final request = BookingStartReceiptRequest.fromCommand(observed)!;
            final read = parseBookingStartReceipt(request, {
              'contract': 'get_booking_start_receipt',
              'version': 1,
              'well_id': 'w',
              'booking_id': 'booking',
              'command_id': 'original-start',
              'command_type': 'start_irrigation_session_from_booking',
              'started_at': receiptAt.toIso8601String(),
              'crops': ['crop'],
              'retry_authorized': false,
              'status': state,
              'receipt': null,
            }) as BookingStartReceiptResponse;
            expect(read.state, isNot(BookingStartReceiptState.accepted));
            expect(read.receipt, isNull);
            expect(await f.snapshot(), before);
          },
        );
      }
      test(
        'concurrent adoption readers do not create a second identity',
        () async {
          final results = await Future.wait([adopt(), adopt()]);
          expect(results.where((v) => v), hasLength(1));
          expect(await f.store.allCommands('a'), hasLength(1));
        },
      );
      if (sqlite) {
        for (final fault in ['none', 'event', 'cancellation']) {
          test('start effects and reopen are atomic, fault=$fault', () async {
            final reminder = bookingReminderEvents(
              accountId: 'a',
              wellId: 'w',
              bookingId: 'booking',
              scheduledStart: receiptAt,
              createdAt: receiptAt.subtract(const Duration(hours: 1)),
            ).first;
            await f.sql.notificationEvents.saveSchedule(
              reminder.event,
              reminder.due,
              receiptAt.subtract(const Duration(hours: 1)),
            );
            final db = f.sql.notificationEvents.db;
            expect(await db.query('notification_events'), hasLength(1));
            if (fault == 'event') {
              await db.execute(
                "create trigger receipt_fault before insert on notification_events when new.event_type='session.started' begin select raise(abort,'injected'); end",
              );
            } else if (fault == 'cancellation') {
              await db.execute(
                "create trigger receipt_fault before update of schedule_state on notification_events when new.schedule_state='cancel_pending' begin select raise(abort,'injected'); end",
              );
            }
            final before = await f.snapshot();
            if (fault != 'none') {
              await expectLater(adopt(), throwsA(isA<DatabaseException>()));
              expect(await f.snapshot(), before);
              await f.reopen();
              expect(await f.snapshot(), before);
              await f.sql.notificationEvents.db.execute(
                'drop trigger receipt_fault',
              );
            }
            expect(await adopt(), isTrue);
            final rows = await f.sql.notificationEvents.db.query(
              'notification_events',
            );
            final event = rows.singleWhere(
              (r) => r['event_type'] == 'session.started',
            );
            expect(event['event_key'], 'session.started/original-start');
            expect(event['entity_id'], 'start');
            expect(
              rows.singleWhere((r) => r['due_at'] != null)['schedule_state'],
              'cancel_pending',
            );
            final saved = await f.snapshot();
            await f.reopen();
            expect(await f.snapshot(), saved);
            expect(await f.store.allCommands('a'), hasLength(1));
          });
        }
      }
    });
  }
}

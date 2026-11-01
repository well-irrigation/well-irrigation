import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/notifications/operational_notification_event_factory.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import 'c07_start_receipt_store_test.dart' show ReceiptStoreFixture, receiptAt;

CommandEnvelope receiptCompletion({
  String account = 'a',
  String well = 'w',
  String command = 'original-completion',
  String root = 'start',
  Object? session = const {r'$ref': 'start', r'$kind': 'session'},
}) => CommandEnvelope(
  accountId: account,
  wellId: well,
  localId: 'completion',
  commandId: command,
  type: CommandType.completeIrrigationSession,
  aggregateLocalId: root,
  sequence: 2,
  occurredAt: receiptAt.add(const Duration(hours: 1)),
  createdLocalAt: receiptAt,
  payload: {'p_session_id': session},
);
Map<String, Object?> completionReceipt() => {
  'session_id': 'session',
  'status': 'closed',
  'session_charge_id': 'charge',
  'ended_at': receiptAt.add(const Duration(hours: 1)).toIso8601String(),
  'segments': <Object?>[],
  'actual_seconds': 3600,
  'billable_seconds': 3600,
  'weighted_price_per_hour_minor': 123,
  'amount_minor': 123,
};

void main() {
  setUpAll(sqfliteFfiInit);
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite completion' : 'memory completion', () {
      late ReceiptStoreFixture f;
      late CommandEnvelope observed;
      setUp(() async {
        f = ReceiptStoreFixture(sqlite);
        await f.open();
        final start = await f.seedStart();
        await f.store.markConfirmed(
          'a',
          'start',
          serverResponse: const {'session_id': 'session'},
          attemptedAt: receiptAt,
        );
        await f.store.putMapping(
          'a',
          IdMapping(
            localId: 'start',
            kind: EntityKind.session,
            serverId: 'session',
            resolvedAt: receiptAt,
          ),
        );
        expect(start.commandId, 'original-start');
        await f.store.insert(receiptCompletion());
        final claim = await f.atomic.claimDispatch(
          accountId: 'a',
          wellId: 'w',
          localId: 'completion',
          commandId: 'original-completion',
          attemptedAt: receiptAt,
          policy: (_) => DispatchClaimDecision.allow,
        );
        expect(claim.isClaimed, isTrue);
        observed = claim.command!;
      });
      tearDown(() => f.close());
      Future<bool> adopt([Map<String, Object?>? receipt]) =>
          f.atomic.reconcileCompletionReceipt(
            observed,
            'session',
            receipt ?? completionReceipt(),
          );
      test('accepted receipt confirms original command and charge without replacement or attempt rewriting', () async {
        final attempts = await f.store.readLocalValuesByPrefix(
          'a',
          'command.dispatch.',
        );
        expect(await adopt(), isTrue);
        final saved = (await f.store.commandByLocalId('a', 'completion'))!;
        expect(saved.status, CommandStatus.confirmed);
        expect(saved.commandId, 'original-completion');
        expect(saved.occurredAt, observed.occurredAt);
        expect(saved.serverResponse, completionReceipt());
        expect(
          (await f.store.mapping(
            'a',
            'completion',
            EntityKind.sessionCharge,
          ))!.serverId,
          'charge',
        );
        expect(await f.store.allCommands('a'), hasLength(2));
        expect(
          await f.store.readLocalValuesByPrefix('a', 'command.dispatch.'),
          attempts,
        );
        final before = await f.snapshot();
        expect(await adopt(), isFalse);
        expect(await f.snapshot(), before);
      });
      test('conflicting charge mapping is never replaced', () async {
        await f.store.putMapping(
          'a',
          IdMapping(
            localId: 'completion',
            kind: EntityKind.sessionCharge,
            serverId: 'other-charge',
            resolvedAt: receiptAt,
          ),
        );
        final before = await f.snapshot();
        expect(await adopt(), isFalse);
        expect(await f.snapshot(), before);
      });
      test(
        'matching charge mapping is reused without changing its resolution',
        () async {
          final map = IdMapping(
            localId: 'completion',
            kind: EntityKind.sessionCharge,
            serverId: 'charge',
            resolvedAt: receiptAt,
            matchedExisting: true,
          );
          await f.store.putMapping('a', map);
          expect(await adopt(), isTrue);
          final saved = (await f.store.mapping(
            'a',
            'completion',
            EntityKind.sessionCharge,
          ))!;
          expect(saved.resolvedAt, map.resolvedAt);
          expect(saved.matchedExisting, isTrue);
        },
      );
      test('changed row fingerprint rejects stale receipt', () async {
        await f.store.markNeedsReview(
          'a',
          'completion',
          error: 'new outcome',
          attemptedAt: receiptAt,
          serverResponse: const {'status': 'rejected'},
        );
        final before = await f.snapshot();
        expect(await adopt(), isFalse);
        expect(await f.snapshot(), before);
      });
      test(
        'known rejection cannot be replaced even from latest snapshot',
        () async {
          await f.store.markNeedsReview(
            'a',
            'completion',
            error: 'rejected',
            attemptedAt: receiptAt,
            serverResponse: const {'status': 'rejected'},
          );
          observed = (await f.store.commandByLocalId('a', 'completion'))!;
          final before = await f.snapshot();
          expect(await adopt(), isFalse);
          expect(await f.snapshot(), before);
        },
      );
      for (final (key, value) in <(String, Object?)>[
        ('session_id', 'other'),
        ('status', 'open'),
        ('session_charge_id', ''),
        ('ended_at', 'invalid'),
        ('segments', 'invalid'),
        ('actual_seconds', -1),
        ('billable_seconds', 3601),
        ('amount_minor', -1),
        ('weighted_price_per_hour_minor', -1),
        ('actual_seconds', 3600.0),
        ('command_id', 'other'),
        ('well_id', 'other'),
        ('command_type', 'other'),
      ]) {
        test('invalid accepted receipt $key=$value cannot confirm', () async {
          final before = await f.snapshot();
          expect(await adopt(completionReceipt()..[key] = value), isFalse);
          expect(await f.snapshot(), before);
        });
      }
      test('non-accepted receipt cannot confirm', () async {
        final before = await f.snapshot();
        expect(await adopt({'status': 'processing', 'receipt': null}), isFalse);
        expect(await f.snapshot(), before);
      });
      for (final command in [
        receiptCompletion(account: 'other'),
        receiptCompletion(well: 'other'),
        receiptCompletion(command: 'other'),
        receiptCompletion(root: 'other'),
        receiptCompletion(session: 'other'),
      ]) {
        test(
          'foreign completion ${command.accountId}/${command.wellId}/${command.commandId}/${command.aggregateLocalId}/${command.payload} rejected',
          () async {
            final before = await f.snapshot();
            expect(
              await f.atomic.reconcileCompletionReceipt(
                command,
                'session',
                completionReceipt(),
              ),
              isFalse,
            );
            expect(await f.snapshot(), before);
          },
        );
      }
      test('session root mapping must match', () async {
        await f.store.putMapping(
          'a',
          IdMapping(
            localId: 'start',
            kind: EntityKind.session,
            serverId: 'other',
            resolvedAt: receiptAt,
          ),
        );
        final before = await f.snapshot();
        expect(await adopt(), isFalse);
        expect(await f.snapshot(), before);
      });
      test('receipt cannot name a different intended session', () async {
        final before = await f.snapshot();
        expect(
          await f.atomic.reconcileCompletionReceipt(
            observed,
            'other',
            completionReceipt()..['session_id'] = 'other',
          ),
          isFalse,
        );
        expect(await f.snapshot(), before);
      });
      test('racing readers adopt once under original command', () async {
        expect(
          (await Future.wait([adopt(), adopt()])).where((v) => v),
          hasLength(1),
        );
        expect(await f.store.allCommands('a'), hasLength(2));
      });
      if (sqlite) {
        for (final fault in ['none', 'event', 'cancellation']) {
          test(
            'completion atomic effects survive reopen, fault=$fault',
            () async {
              final reminder = sessionNearEndEvent(
                accountId: 'a',
                wellId: 'w',
                sessionId: 'start',
                trustedEnd: receiptAt.add(const Duration(hours: 1)),
                createdAt: receiptAt,
              )!;
              await f.sql.notificationEvents.saveSchedule(
                reminder.event,
                reminder.due,
                receiptAt,
              );
              final db = f.sql.notificationEvents.db;
              if (fault == 'event') {
                await db.execute(
                  "create trigger receipt_fault before insert on notification_events when new.event_type='session.completed' begin select raise(abort,'injected'); end",
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
                (r) => r['event_type'] == 'session.completed',
              );
              expect(
                event['event_key'],
                'session.completed/original-completion',
              );
              expect(event['entity_id'], 'start');
              expect(
                rows.singleWhere((r) => r['due_at'] != null)['schedule_state'],
                'cancel_pending',
              );
              final saved = await f.snapshot();
              await f.reopen();
              expect(await f.snapshot(), saved);
              expect(await adopt(), isFalse);
              expect(await f.store.allCommands('a'), hasLength(2));
            },
          );
        }
      }
    });
  }
}

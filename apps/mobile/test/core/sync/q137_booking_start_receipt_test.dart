import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/booking_start_receipt.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import 'c07_start_receipt_store_test.dart'
    show ReceiptStoreFixture, receiptStart, startReceipt, receiptAt;

class StartProbe implements CommandTransport, BookingStartReceiptTransport {
  final writes = <DispatchRequest>[];
  final reads = <BookingStartReceiptRequest>[];
  BookingStartReceiptRead answer = const BookingStartReceiptFailure(
    BookingStartReceiptFailureKind.network,
  );
  @override
  Future<DispatchResult> dispatch(DispatchRequest request) async {
    writes.add(request);
    return const DispatchFailed(
      disposition: FailureDisposition.retry,
      message: 'response lost',
    );
  }

  @override
  Future<BookingStartReceiptRead> readBookingStartReceipt(
    BookingStartReceiptRequest request,
  ) async {
    reads.add(request);
    return answer;
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  for (final sqlite in [false, true]) {
    group('original booking receipt sqlite=$sqlite', () {
      late ReceiptStoreFixture f;
      late StartProbe transport;
      setUp(() async {
        f = ReceiptStoreFixture(sqlite);
        await f.open();
        final start = receiptStart();
        await f.store.insertBundle(
          accountId: 'a',
          key: 'booking.manual_start.v1.w.booking',
          value: jsonEncode({
            'start_local_id': start.localId,
            'start_command_id': start.commandId,
          }),
          commands: [start],
        );
        transport = StartProbe();
        await SyncEngine(store: f.store, transport: transport).run('a');
        expect(transport.writes, hasLength(1));
      });
      tearDown(() => f.close());
      for (final state in BookingStartReceiptState.values) {
        test('$state never authorizes a second send', () async {
          transport.answer = BookingStartReceiptResponse(
            state,
            state == BookingStartReceiptState.accepted ? startReceipt() : null,
          );
          await SyncEngine(store: f.store, transport: transport).run('a');
          await SyncEngine(store: f.store, transport: transport).run('a');
          expect(transport.writes, hasLength(1));
          final saved = (await f.store.commandByLocalId('a', 'start'))!;
          expect(saved.commandId, 'original-start');
          expect(saved.occurredAt, receiptAt);
          expect(saved.payload, receiptStart().payload);
          expect((await f.store.allCommands('a')), hasLength(1));
          expect(
            saved.status,
            state == BookingStartReceiptState.accepted
                ? CommandStatus.confirmed
                : CommandStatus.dispatching,
          );
          expect(
            transport.reads.first.arguments,
            BookingStartReceiptRequest.fromCommand(receiptStart())!.arguments,
          );
          if (state == BookingStartReceiptState.accepted) {
            expect(
              (await f.store.mapping(
                'a',
                'start',
                EntityKind.session,
              ))!.serverId,
              'session',
            );
            if (sqlite) {
              expect(
                await f.sql.notificationEvents.db.query(
                  'notification_events',
                  where: "event_type='session.started'",
                ),
                hasLength(1),
              );
            }
          }
        });
      }

      test('owned terminal rejection without response cannot be overwritten by recovery', () async {
        final owner = DispatchAttempt.parse(await f.store.readBundle('a', dispatchAttemptCurrentKey('start')))!;
        expect(await f.atomic.finishDispatchAttempt(owner, status: CommandStatus.review, error: 'business rejected'), isTrue);
        transport.answer = BookingStartReceiptResponse(BookingStartReceiptState.accepted, startReceipt());
        await SyncEngine(store: f.store, transport: transport).run('a');
        expect((await f.store.commandByLocalId('a', 'start'))!.status, CommandStatus.review);
        expect(transport.reads, isEmpty);
        expect(transport.writes, hasLength(1));
      });
      for (final field in [
        'well_id',
        'booking_id',
        'command_id',
        'started_at',
        'session_status',
      ]) {
        test('mismatching receipt $field remains held', () async {
          transport.answer = BookingStartReceiptResponse(
            BookingStartReceiptState.accepted,
            {...startReceipt(), field: 'wrong'},
          );
          await SyncEngine(store: f.store, transport: transport).run('a');
          expect(
            (await f.store.commandByLocalId('a', 'start'))!.status,
            CommandStatus.dispatching,
          );
          expect(transport.writes, hasLength(1));
          expect(
            await f.store.mapping('a', 'start', EntityKind.session),
            isNull,
          );
        });
      }
      for (final failure in BookingStartReceiptFailureKind.values) {
        test('$failure remains held', () async {
          transport.answer = BookingStartReceiptFailure(failure);
          await SyncEngine(store: f.store, transport: transport).run('a');
          expect(transport.writes, hasLength(1));
          expect(
            (await f.store.commandByLocalId('a', 'start'))!.status,
            CommandStatus.dispatching,
          );
        });
      }
      test('wrong account performs no read; existing mapping conflict never changes identity', () async {
        transport.answer = BookingStartReceiptResponse(
          BookingStartReceiptState.accepted,
          startReceipt(),
        );
        await SyncEngine(store: f.store, transport: transport).run('other');
        expect(transport.reads, isEmpty);
        await f.store.putMapping(
          'a',
          IdMapping(
            localId: 'start',
            kind: EntityKind.session,
            serverId: 'different',
            resolvedAt: receiptAt,
          ),
        );
        await SyncEngine(store: f.store, transport: transport).run('a');
        expect(
          (await f.store.mapping('a', 'start', EntityKind.session))!.serverId,
          'different',
        );
        expect(
          (await f.store.commandByLocalId('a', 'start'))!.status,
          CommandStatus.dispatching,
        );
        expect(transport.writes, hasLength(1));
      });
    });
  }
}

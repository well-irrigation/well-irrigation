import 'dart:io';

import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/background_sync_coordinator.dart';

import '../sync/fake_command_transport.dart';
import '../sync/fake_background_sync_scheduler.dart';

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/booking/local_booking_request.dart';
import 'package:well_irrigation_mobile/core/booking/booking_presentation.dart';
import 'package:well_irrigation_mobile/core/notifications/booking_notification_event_factory.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_delivery_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import '../sync/booking_dispatch_c2a_test.dart'
    show booking, epoch, Transport, accepted;
import 'notification_delivery_test.dart' show RecordingPresenter;

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late SqliteOutboxStore store;
  late Database db;
  late DateTime now;
  SqliteOutboxStore open() => SqliteOutboxStore(
    databasePath: '${dir.path}/db',
    sqfliteFactory: databaseFactoryFfi,
    singleInstance: false,
  );
  LocalBookingRequest request(String id, {String? replaces}) =>
      LocalBookingRequest(
        accountId: 'a',
        wellId: 'well-0',
        requestId: id,
        commandId: 'cmd-$id',
        createdLocalAt: epoch,
        scheduledDay: '2027-01-01',
        payloadJson: jsonEncode({
          ...booking(0).payload,
          'p_scheduled_start': DateTime.utc(
            2027,
            1,
            1,
            id == 'A' ? 7 : 9,
          ).toIso8601String(),
          'p_scheduled_end': DateTime.utc(
            2027,
            1,
            1,
            id == 'A' ? 8 : 10,
          ).toIso8601String(),
        }),
        contextJson: '{}',
        replacesRequestId: replaces,
      );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('c3_booking');
    store = open();
    await store.initialize();
    db = await databaseFactoryFfi.openDatabase(
      '${dir.path}/db',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    now = epoch;
  });
  tearDown(() async {
    await db.close();
    await store.close();
    await dir.delete(recursive: true);
  });
  Future<void> finish(
    LocalBookingRequest r, {
    String? result,
    CommandStatus status = CommandStatus.review,
  }) async {
    await store.claimBookingCreate('a', r.commandId, attemptedAt: now);
    await store.finishBookingCreate(
      'a',
      r.commandId,
      claimedAt: now,
      status: status,
      response: result == null ? null : {'status': result},
    );
  }

  NotificationDeliveryCoordinator delivery(RecordingPresenter p) =>
      NotificationDeliveryCoordinator(
        store: store.notificationEvents,
        presenter: p,
        clock: () => now,
        policies: bookingNotificationPolicies,
      );

  test('insert fault rolls back actual request response and mapping; same command survives reopen', () async {
    final r = await store.saveBookingRequest(request('A'));
    await db.execute(
      "create trigger event_fault before insert on notification_events begin select raise(abort,'fault'); end",
    );
    await expectLater(
      finish(r, result: 'confirmed', status: CommandStatus.confirmed),
      throwsA(isA<DatabaseException>()),
    );
    expect((await store.bookingRequest('a', 'well-0', 'A'))!.response, isNull);
    expect(await db.query('notification_events'), isEmpty);
    await store.close();
    store = open();
    await store.initialize();
    expect(
      (await store.commandByLocalId('a', r.commandId))!.commandId,
      r.commandId,
    );
    expect(
      (await store.commandByLocalId('a', r.commandId))!.status,
      CommandStatus.dispatching,
    );
    expect(
      (await store.bookingRequest('a', 'well-0', 'A'))!.payloadJson,
      r.payloadJson,
    );
  });
  test('post-commit presentation failure never retries booking transport or changes request', () async {
    final r = await store.saveBookingRequest(request('A'));
    final t = Transport((r) async => accepted(r));
    final engine = SyncEngine(store: store, transport: t, clock: () => now);
    await engine.runBookingCreates('a');
    final before = (await store.bookingRequest('a', 'well-0', 'A'))!;
    final presenter = RecordingPresenter()..throwsOnShow = true;
    await delivery(presenter).deliver('a');
    await engine.runBookingCreates('a');
    expect(t.requests, hasLength(1));
    expect(
      (await store.commandByLocalId('a', r.commandId))!.status,
      CommandStatus.confirmed,
    );
    final after = (await store.bookingRequest('a', 'well-0', 'A'))!;
    expect(after.responseJson, before.responseJson);
    expect(after.payloadJson, r.payloadJson);
    expect(
      (await store.notificationEvents.pending('a', now)).single.attempts,
      1,
    );
  });
  test('successful OS show followed by delivered-state fault recovers same ID after reopen, no transport', () async {
    final r = await store.saveBookingRequest(request('A'));
    final t = Transport((r) async => accepted(r));
    final engine = SyncEngine(store: store, transport: t, clock: () => now);
    await engine.runBookingCreates('a');
    await db.execute(
      "create trigger delivered_fault before update of state on notification_events when new.state='delivered' begin select raise(abort,'fault'); end",
    );
    final presenter = RecordingPresenter();
    expect(await delivery(presenter).deliver('a'), isTrue);
    expect(presenter.ids, [1]);
    expect(
      (await store.commandByLocalId('a', r.commandId))!.status,
      CommandStatus.confirmed,
    );
    await store.close();
    store = open();
    await store.initialize();
    expect(await delivery(presenter).deliver('a'), isTrue);
    expect(presenter.ids, [1]);
    await db.execute('drop trigger delivered_fault');
    now = now.add(const Duration(minutes: 2));
    await delivery(presenter).deliver('a');
    expect(presenter.ids, [1, 1]);
    await SyncEngine(
      store: store,
      transport: t,
      clock: () => now,
    ).runBookingCreates('a');
    expect(t.requests, hasLength(1));
    expect(await store.notificationEvents.hasOutstanding('a'), isFalse);
  });
  test(
    'unknown review has honest label, no response, no correction or start',
    () async {
      final r = await store.saveBookingRequest(request('A'));
      await finish(r);
      final loaded = (await store.bookingRequest('a', 'well-0', 'A'))!;
      expect(loaded.response, isNull);
      expect(loaded.reviewRequired, isTrue);
      expect(loaded.needsCorrection, isFalse);
      expect(loaded.canStart, isFalse);
      expect(
        presentBooking(
          id: 'x',
          status: 'local_request',
          localRequest: loaded,
        ).label,
        'راجع الحجز',
      );
      expect(
        (await store.bookingRequestsForDay(
          'a',
          'well-0',
          r.scheduledDay,
        )).single.reviewRequired,
        isTrue,
      );
    },
  );
  test('pending and transient timeout create no event', () async {
    await store.saveBookingRequest(request('A'));
    expect(await db.query('notification_events'), isEmpty);
    await SyncEngine(
      store: store,
      transport: Transport(
        (r) async => const DispatchFailed(
          disposition: FailureDisposition.retry,
          message: 'timeout',
        ),
      ),
      clock: () => now,
    ).runBookingCreates('a');
    expect(await db.query('notification_events'), isEmpty);
  });
  for (final result in ['conflict', 'rejected', null, 'confirmed']) {
    test(
      'late superseded $result uses direct lineage without changing replacement',
      () async {
        final a = await store.saveBookingRequest(request('A'));
        await finish(a, result: 'rejected');
        final b = await store.saveBookingRequest(request('B', replaces: 'A'));
        // Defensive delayed response: normally terminal commands cannot return again.
        await db.delete('notification_events');
        await db.rawUpdate(
          "update outbox_commands set status='dispatching' where command_id='cmd-A'",
        );
        await store.finishBookingCreate(
          'a',
          a.commandId,
          claimedAt: now,
          status: result == 'confirmed'
              ? CommandStatus.confirmed
              : CommandStatus.review,
          response: result == null ? null : {'status': result},
        );
        final rows = await db.query('notification_events');
        expect(rows, hasLength(1));
        expect(
          rows.single['state'],
          result == 'confirmed' ? 'pending' : 'suppressed',
        );
        expect(
          rows.single['event_type'],
          result == 'confirmed' || result == null
              ? 'booking.review_required'
              : result == 'conflict'
              ? 'booking.time_unavailable'
              : 'booking.rejected',
        );
        final presenter = RecordingPresenter();
        await delivery(presenter).deliver('a');
        expect(presenter.ids, hasLength(result == 'confirmed' ? 1 : 0));
        expect(
          (await store.bookingRequest('a', 'well-0', 'B'))!.payloadJson,
          b.payloadJson,
        );
        expect(
          (await store.bookingRequest(
            'a',
            'well-0',
            'A',
          ))!.supersededByRequestId,
          'B',
        );
      },
    );
  }
  test('replacement suppresses already pending old negative event', () async {
    final a = await store.saveBookingRequest(request('A'));
    await finish(a, result: 'rejected');
    await store.saveBookingRequest(request('B', replaces: 'A'));
    final presenter = RecordingPresenter();
    await delivery(presenter).deliver('a');
    expect(presenter.ids, isEmpty);
  });
  test('precommit failure recovers through existing sync and server replay with same command ID', () async {
    final r = await store.saveBookingRequest(request('A'));
    final t = FakeCommandTransport()
      ..scheduleRawResponse(CommandType.createBooking, {
        'status': 'confirmed',
        'booking_id': 'b',
        'public_code': 'B',
        'well_id': r.wellId,
        'scheduled_start': r.payload['p_scheduled_start'],
        'scheduled_end': r.payload['p_scheduled_end'],
      });
    SyncEngine engine() =>
        SyncEngine(store: store, transport: t, clock: () => now);
    await db.execute(
      "create trigger before_commit_fault before insert on notification_events begin select raise(abort,'fault'); end",
    );
    await expectLater(
      engine().runBookingCreates('a'),
      throwsA(isA<DatabaseException>()),
    );
    expect(
      (await store.bookingRequest('a', r.wellId, r.requestId))!.response,
      isNull,
    );
    expect(await db.query('notification_events'), isEmpty);
    await db.execute('drop trigger before_commit_fault');
    await store.close();
    store = open();
    await store.initialize();
    now = now.add(const Duration(minutes: 3));
    await engine().runBookingCreates('a');
    now = (await store.commandByLocalId('a', r.commandId))!.nextAttemptAt!;
    await engine().runBookingCreates('a');
    expect(t.requests.map((r) => r.commandId), [r.commandId, r.commandId]);
    expect(t.executionCount, 1);
    expect(
      (await store.bookingRequest('a', r.wellId, r.requestId))!.isConfirmed,
      isTrue,
    );
    expect(await db.query('notification_events'), hasLength(1));
    expect(await db.query('outbox_commands'), hasLength(1));
  });
  test('existing worker opportunity retries notification only and never resends terminal booking', () async {
    final r = await store.saveBookingRequest(request('A'));
    final t = Transport((r) async => accepted(r));
    final p = RecordingPresenter()..throwsOnShow = true;
    final scheduler = FakeBackgroundSyncScheduler();
    final coordinator = BackgroundSyncCoordinator(
      engine: SyncEngine(store: store, transport: t, clock: () => now),
      scheduler: scheduler,
      notifications: delivery(p),
    );
    final first = await coordinator.runFromApp('a');
    expect(first.shouldRetry, isTrue);
    expect(scheduler.scheduled, hasLength(1));
    await coordinator.runFromWorker('a');
    await coordinator.runFromWorker('a');
    expect(t.requests, hasLength(1));
    expect(p.ids, [1, 1, 1]);
    expect(
      (await store.commandByLocalId('a', r.commandId))!.status,
      CommandStatus.confirmed,
    );
  });
  test('process boundary after commit before claim restores pending event without booking transport', () async {
    final r = await store.saveBookingRequest(request('A'));
    final t = Transport((r) async => accepted(r));
    await SyncEngine(
      store: store,
      transport: t,
      clock: () => now,
    ).runBookingCreates('a');
    expect(
      (await store.notificationEvents.pending('a', now)).single.attempts,
      0,
    );
    await store.close();
    store = open();
    await store.initialize();
    expect(
      (await store.bookingRequest('a', r.wellId, r.requestId))!.isConfirmed,
      isTrue,
    );
    await SyncEngine(
      store: store,
      transport: t,
      clock: () => now,
    ).runBookingCreates('a');
    final presenter = RecordingPresenter();
    await delivery(presenter).deliver('a');
    expect(t.requests, hasLength(1));
    expect(presenter.ids, [1]);
    expect(await store.notificationEvents.hasOutstanding('a'), isFalse);
  });
  test('A to B to C late confirmed A keeps current intent and carries canonical tap target', () async {
    final a = await store.saveBookingRequest(request('A'));
    await finish(a, result: 'rejected');
    final b = await store.saveBookingRequest(request('B', replaces: 'A'));
    await finish(b, result: 'rejected');
    final c = await store.saveBookingRequest(request('C', replaces: 'B'));
    await db.delete('notification_events');
    await db.rawUpdate(
      "update outbox_commands set status='dispatching' where command_id='cmd-A'",
    );
    await store.finishBookingCreate(
      'a',
      a.commandId,
      claimedAt: now,
      status: CommandStatus.confirmed,
      entityId: 'late-booking',
      response: {'status': 'confirmed', 'booking_id': 'late-booking'},
    );
    final event = (await store.notificationEvents.pending(
      'a',
      now,
    )).single.event;
    expect(event.eventType, 'booking.review_required');
    expect(event.routePayload['booking_id'], 'late-booking');
    final presentation = bookingNotificationPolicies.presentation(event)!;
    expect(presentation.title, 'راجع الحجز');
    expect(presentation.body, 'تم تثبيت طلب سابق. افتح الحجوزات للمراجعة.');
    expect(
      (await store.bookingRequest('a', a.wellId, 'A'))!.supersededByRequestId,
      'B',
    );
    expect(
      (await store.bookingRequest('a', b.wellId, 'B'))!.supersededByRequestId,
      'C',
    );
    expect(
      (await store.bookingRequest('a', c.wellId, 'C'))!.payloadJson,
      c.payloadJson,
    );
    expect((await store.bookingRequest('a', c.wellId, 'C'))!.response, isNull);
  });
}

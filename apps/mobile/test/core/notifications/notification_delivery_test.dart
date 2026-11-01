import 'dart:io';
import 'package:well_irrigation_mobile/core/sync/background_sync_worker.dart';

import 'package:well_irrigation_mobile/core/notifications/notification_router.dart';

import 'package:well_irrigation_mobile/core/notifications/booking_notification_event_factory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/notifications/app_notification_event.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_event_store.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_delivery_coordinator.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_presenter.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

class RecordingPresenter implements NotificationPresenter {
  bool allowed = true, throwsOnShow = false;
  int initialized = 0;
  final ids = <int>[];
  @override
  Future<void> initialize() async {
    initialized++;
  }

  @override
  Future<bool> permissionGranted() async => allowed;
  @override
  Future<void> show(
    int id,
    AppNotificationEvent event,
    NotificationPresentation presentation,
  ) async {
    ids.add(id);
    if (throwsOnShow) throw StateError('OS failure');
  }
}

AppNotificationEvent event(
  String key, {
  String account = 'a',
  String well = 'w',
  String type = 'booking.confirmed',
}) => AppNotificationEvent(
  eventKey: key,
  accountId: account,
  wellId: well,
  category: 'booking_results',
  presentationPolicy: 'always_alert',
  eventType: type,
  entityType: 'booking_request',
  entityId: 'r',
  routeType: 'bookings',
  routePayload: {'day': '2026-10-16', 'request_id': 'r'},
  createdAt: DateTime.utc(2026, 10, 16),
);

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late SqliteOutboxStore outbox;
  late SqliteNotificationEventStore store;
  late DateTime now;
  late RecordingPresenter presenter;
  SqliteOutboxStore open() => SqliteOutboxStore(
    databasePath: '${dir.path}/outbox.db',
    sqfliteFactory: databaseFactoryFfi,
    singleInstance: false,
  );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('c3_delivery');
    outbox = open();
    await outbox.initialize();
    store = outbox.notificationEvents;
    now = DateTime.utc(2026, 10, 16);
    presenter = RecordingPresenter();
  });
  tearDown(() async {
    await outbox.close();
    await dir.delete(recursive: true);
  });
  NotificationDeliveryCoordinator coordinator() =>
      NotificationDeliveryCoordinator(
        store: store,
        presenter: presenter,
        clock: () => now,
        policies: bookingNotificationPolicies,
      );

  test('same account/key dedupes local and future remote ingress, accounts stay isolated', () async {
    await store.insertEvent(event('x'));
    await store.insertEvent(event('x'));
    await store.insertEvent(event('x', account: 'b'));
    expect(await store.pending('a', now), hasLength(1));
    expect(await store.pending('b', now), hasLength(1));
    expect(
      (await store.pending('a', now)).single.localId,
      isNot((await store.pending('b', now)).single.localId),
    );
  });
  test('one opportunity presents at most 20 in local ID order', () async {
    for (var i = 0; i < 25; i++) {
      await store.insertEvent(event('$i'));
    }
    expect(await coordinator().deliver('a'), isTrue);
    expect(presenter.ids, List.generate(20, (i) => i + 1));
    expect(await store.pending('a', now), hasLength(5));
  });
  test('presentation exception retries same platform ID only three times then suppresses', () async {
    await store.insertEvent(event('x'));
    presenter.throwsOnShow = true;
    for (var i = 0; i < 5; i++) {
      await coordinator().deliver('a');
    }
    expect(presenter.ids, [1, 1, 1]);
    expect(await store.pending('a', now), isEmpty);
  });
  test('denied permission suppresses without presentation attempts and never replays', () async {
    await store.insertEvent(event('x'));
    presenter.allowed = false;
    await coordinator().deliver('a');
    presenter.allowed = true;
    await coordinator().deliver('a');
    expect(presenter.ids, isEmpty);
    final db = await databaseFactoryFfi.openDatabase(
      '${dir.path}/outbox.db',
      options: OpenDatabaseOptions(singleInstance: false),
    );
    expect(
      (await db.query('notification_events')).single,
      containsPair('attempt_count', 0),
    );
    expect(
      (await db.query('notification_events')).single,
      containsPair('suppressed_reason', 'permission_denied'),
    );
    await db.close();
  });
  test(
    'future consumer is persisted but cannot emit until explicitly enabled',
    () async {
      await store.insertEvent(event('x', type: 'future.disabled'));
      await coordinator().deliver('a');
      expect(presenter.ids, isEmpty);
    },
  );
  test('two connections race for one lease and expired lease recovers after reopen', () async {
    await store.insertEvent(event('x'));
    final other = open();
    await other.initialize();
    final expiry = now.add(const Duration(minutes: 1));
    final claims = await Future.wait([
      store.claim('a', 1, now, expiry),
      other.notificationEvents.claim('a', 1, now, expiry),
    ]);
    expect(claims.where((x) => x), hasLength(1));
    expect(await store.pending('a', now), isEmpty);
    await other.close();
    await outbox.close();
    outbox = open();
    await outbox.initialize();
    store = outbox.notificationEvents;
    now = expiry;
    await coordinator().deliver('a');
    expect(presenter.ids, [1]);
    expect(await store.pending('a', now), isEmpty);
  });
  test(
    'pending lookup uses partial index and cannot claim another account event',
    () async {
      await store.insertEvent(event('x', account: 'b'));
      expect(
        await store.claim('a', 1, now, now.add(const Duration(minutes: 1))),
        isFalse,
      );
      final db = await databaseFactoryFfi.openDatabase(
        '${dir.path}/outbox.db',
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final plan = await db.rawQuery(
        'EXPLAIN QUERY PLAN ${SqliteNotificationEventStore.pendingSql}',
        ['a', now.toIso8601String()],
      );
      expect(
        plan.map((x) => x['detail']).join(),
        contains(
          'SEARCH notification_events USING INDEX notification_pending_idx',
        ),
      );
      await db.close();
    },
  );
  test(
    'delivered ledger survives restart, no second OS notification',
    () async {
      await store.insertEvent(event('x'));
      await coordinator().deliver('a');
      await outbox.close();
      outbox = open();
      await outbox.initialize();
      store = outbox.notificationEvents;
      await store.insertEvent(event('x'));
      await coordinator().deliver('a');
      expect(presenter.ids, [1]);
    },
  );
  test(
    'worker builds and initializes its own injected presentation capability',
    () async {
      await store.insertEvent(event('x'));
      final worker = createBackgroundNotificationDelivery(
        outbox,
        presenter: presenter,
      );
      await worker.deliver('a');
      expect(presenter.initialized, 1);
      expect(presenter.ids, [1]);
    },
  );

  test('foreground/background presenters racing on two connections display one tray identity', () async {
    await store.insertEvent(event('x'));
    final other = open();
    await other.initialize();
    try {
      await Future.wait([
        coordinator().deliver('a'),
        NotificationDeliveryCoordinator(
          store: other.notificationEvents,
          presenter: presenter,
          clock: () => now,
          policies: bookingNotificationPolicies,
        ).deliver('a'),
      ]);
      expect(presenter.ids, [1]);
      expect(await store.hasOutstanding('a'), isFalse);
    } finally {
      await other.close();
    }
  });
  test('future remote ingress uses the same account/event identity as local insertion', () async {
    await store.insertEvent(event('shared'));
    await NotificationIngress(store.insertEvent).receive(event('shared'));
    expect(await store.pending('a', now), hasLength(1));
  });
  test('generic event snapshots nested routing data immutably', () {
    final nested = <String, Object?>{
      'ids': ['one'],
    };
    final saved = AppNotificationEvent(
      eventKey: 'immutable',
      accountId: 'a',
      category: 'future',
      eventType: 'future.type',
      entityType: 'thing',
      routeType: 'future',
      routePayload: nested,
      createdAt: now,
    );
    (nested['ids'] as List).add('two');
    (saved.routePayload['ids'] as List).add('three');
    expect(saved.routePayload['ids'], ['one']);
  });
  test('authenticated account change prevents presentation without consuming or retrying booking', () async {
    await store.insertEvent(event('x'));
    final coordinator = NotificationDeliveryCoordinator(
      store: store,
      presenter: presenter,
      policies: bookingNotificationPolicies,
      isAccountActive: (_) => false,
    );
    expect(await coordinator.deliver('a'), isFalse);
    expect(presenter.ids, isEmpty);
    expect((await store.pending('a', now)).single.attempts, 0);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_delivery_coordinator.dart';
import 'package:well_irrigation_mobile/core/notifications/operational_notification_event_factory.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

import 'notification_delivery_test.dart' show RecordingPresenter, event;

// يعمل هذا الفحص في Dart VM مستقل لأن Flutter لا يدعم dart:mirrors.
// يفحص المكتبة المحمّلة ورموزها واعتمادها الفعلي دون مطابقة نص المصدر.
const _factoryProbe = r'''
import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';
import 'package:well_irrigation_mobile/core/notifications/operational_notification_event_factory.dart' as notifications;

void main() {
  // أسماء typedef لا تظهر في mirrors؛ يثبت هذا الإسناد عقد النوع بالمترجم.
  final notifications.ScheduledNotificationIntent? absent = notifications.sessionNearEndEvent(
    accountId: 'a', wellId: 'w', sessionId: 's',
    trustedEnd: null, createdAt: DateTime.utc(2027),
  );
  final library = currentMirrorSystem().libraries.values.singleWhere(
    (value) => value.uri.path.endsWith('/operational_notification_event_factory.dart'),
  );
  final visited = <Uri>{};
  final pending = <LibraryMirror>[library];
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    if (!visited.add(current.uri)) continue;
    for (final dependency in current.libraryDependencies) {
      final target = dependency.targetLibrary;
      if (target != null && target.uri.scheme != 'dart') pending.add(target);
    }
  }
  final nearEnd = library.declarations[#sessionNearEndEvent] as MethodMirror;
  stdout.write(jsonEncode({
    'symbols': library.declarations.keys.map(MirrorSystem.getName).toList()..sort(),
    'libraries': visited.map((uri) => uri.toString()).toList()..sort(),
    'parameters': nearEnd.parameters.map((p) => MirrorSystem.getName(p.simpleName)).toList(),
    'missingEndProducesNothing': absent == null,
  }));
}
''';

void main() {
  setUpAll(sqfliteFfiInit);

  test('المصنع المحمّل يقتصر على C06-A دون اعتماد تشغيل أو إيصالات', () async {
    final directory = await Directory.systemTemp.createTemp('c06a_symbols_');
    addTearDown(() => directory.delete(recursive: true));
    final config = File('.dart_tool/package_config.json').absolute;
    final packages =
        (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
    final flutter = packages.cast<Map>().singleWhere(
      (p) => p['name'] == 'flutter',
    );
    final flutterRoot = config.uri.resolve('${flutter['rootUri']}/');
    final sdk = flutterRoot.resolve('../../bin/cache/dart-sdk/bin/');
    final executable = sdk
        .resolve(Platform.isWindows ? 'dart.exe' : 'dart')
        .toFilePath();
    final probe = File('${directory.path}/factory_probe.dart');
    await probe.writeAsString(_factoryProbe);
    final result = await Process.run(executable, [
      // تشغيل VM مباشرةً يتجاوز أدوات pub والقياس عن بُعد.
      '--disable-dart-dev',
      '--packages=${config.path}',
      probe.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final evidence = jsonDecode(result.stdout as String) as Map;
    expect(
      evidence['symbols'],
      unorderedEquals([
        'operationalEvent',
        'bookingReminderEvents',
        'sessionNearEndEvent',
        'appNotificationPolicies',
        '_presentation',
        '_texts',
      ]),
    );
    expect(
      (evidence['libraries'] as List).map((uri) {
        final path = Uri.parse(uri as String).path;
        return path.substring(path.indexOf('/core/') + 1);
      }),
      unorderedEquals([
        'core/notifications/operational_notification_event_factory.dart',
        'core/notifications/app_notification_event.dart',
        'core/notifications/booking_notification_event_factory.dart',
        'core/notifications/notification_presenter.dart',
        'core/sync/sync_status.dart',
      ]),
    );
    expect(evidence['parameters'], [
      'accountId',
      'wellId',
      'sessionId',
      'trustedEnd',
      'createdAt',
    ]);
    expect(evidence['missingEndProducesNothing'], isTrue);
  });

  test('السياسات المفعلة محصورة في نتائج الحجز والتذكيرات المعتمدة', () {
    expect(
      appNotificationPolicies.builders.keys,
      unorderedEquals([
        'booking.confirmed',
        'booking.time_unavailable',
        'booking.rejected',
        'booking.review_required',
        'booking.reminder_upcoming',
        'booking.due',
        'session.near_end',
      ]),
    );
  });

  for (final outcome in ['delivered', 'permission_denied', 'retry_exhausted']) {
    test(
      'التسليم $outcome يحفظ أوامر الأعمال والربط ولا يولّد إكمال جلسة',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'c06a_delivery_',
        );
        addTearDown(() => directory.delete(recursive: true));
        final outbox = SqliteOutboxStore(
          databasePath: '${directory.path}/db',
          sqfliteFactory: databaseFactoryFfi,
        );
        await outbox.initialize();
        addTearDown(outbox.close);
        final now = DateTime.utc(2027);
        await outbox.insert(
          CommandEnvelope(
            localId: 'kept-command',
            commandId: 'kept-id',
            accountId: 'a',
            wellId: 'w',
            type: CommandType.createBooking,
            sequence: 1,
            occurredAt: now,
            createdLocalAt: now,
            payload: const {
              'p_well_id': 'w',
              'p_farmer_well_account_id': 'farmer',
              'p_farm_id': 'farm',
              'p_scheduled_start': '2027-01-01T07:00:00Z',
              'p_scheduled_end': '2027-01-01T08:00:00Z',
              'p_expected_energy_source': 'well_diesel',
            },
          ),
        );
        await outbox.putMapping(
          'a',
          IdMapping(
            localId: 'kept-farm',
            kind: EntityKind.farm,
            serverId: 'canonical-farm',
            resolvedAt: now,
          ),
        );
        final store = outbox.notificationEvents;
        final db = store.db;
        final tables = (await db.rawQuery(
          "select name from sqlite_master where type='table' and name not like 'sqlite_%' and name not in ('android_metadata','notification_events','notification_reconcile_keys') order by name",
        )).map((row) => row['name'] as String).toList();
        final before = {
          for (final table in tables) table: await db.query(table),
        };
        expect(before['outbox_commands'], hasLength(1));
        expect(before['id_mappings'], hasLength(1));

        await store.insertEvent(event('only-immediate'));
        final end = now.add(const Duration(hours: 1));
        final reminder = sessionNearEndEvent(
          accountId: 'a',
          wellId: 'w',
          sessionId: 'data-only-session',
          trustedEnd: end,
          createdAt: now,
        )!;
        expect(reminder.event.eventType, 'session.near_end');
        expect(reminder.due, end.subtract(const Duration(minutes: 5)));
        expect(reminder.event.routePayload, isEmpty);
        // توليد البيانات وحده لا يكتب حدثًا ولا يقرأ جلسة تشغيل.
        expect(await db.query('notification_events'), hasLength(1));
        await store.saveSchedule(reminder.event, reminder.due, now);

        final presenter = RecordingPresenter()
          ..allowed = outcome != 'permission_denied'
          ..throwsOnShow = outcome == 'retry_exhausted';
        final delivery = NotificationDeliveryCoordinator(
          store: store,
          presenter: presenter,
          clock: () => now,
          policies: appNotificationPolicies,
        );
        for (var attempt = 0; attempt < 4; attempt++) {
          await delivery.deliver('a');
        }
        for (final table in tables) {
          expect(await db.query(table), before[table], reason: table);
        }
        final rows = await db.query('notification_events');
        expect(rows, hasLength(2));
        expect(
          rows.map((row) => row['event_type']),
          unorderedEquals(['booking.confirmed', 'session.near_end']),
        );
        final immediate = rows.singleWhere(
          (row) => row['event_key'] == 'only-immediate',
        );
        expect(
          immediate['state'],
          outcome == 'delivered' ? 'delivered' : 'suppressed',
        );
        expect(presenter.ids.length, switch (outcome) {
          'delivered' => 1,
          'permission_denied' => 0,
          _ => 3,
        });
        expect(
          rows.singleWhere(
            (row) => row['event_type'] == 'session.near_end',
          )['schedule_state'],
          'arm_pending',
        );
      },
    );
  }
}

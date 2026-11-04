import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/app/authenticated_shell.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/notifications/app_notification_event.dart';
import 'package:well_irrigation_mobile/core/notifications/booking_notification_event_factory.dart';
import 'package:well_irrigation_mobile/core/notifications/local_notification_presenter.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_delivery_coordinator.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_permission_coordinator.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_router.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_services.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/features/bookings/bookings_screen.dart';

import '../../support/identity_fixture.dart';
import 'notification_delivery_test.dart' show RecordingPresenter;
import 'notification_host_test.dart' show EmptyStore;
import 'notification_routing_permission_test.dart' show Permission;
import 'operational_notification_cache_test.dart' show day;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  late Directory dir;
  late SqliteOutboxStore store;
  late String previousPath;
  late NotificationRouter router;
  late AppNotificationEvent routeEvent;
  late int loads;

  setUp(() async {
    previousPath = await databaseFactoryFfiNoIsolate.getDatabasesPath();
    dir = await Directory.systemTemp.createTemp('notification_app_route');
    await databaseFactory.setDatabasesPath(dir.path);
    store = SqliteOutboxStore();
    await store.initialize();
    loads = 0;
    router = NotificationRouter(load: (account, id) async {
      loads++;
      return routeEvent;
    });
    NotificationServices.current = NotificationServices(
      delivery: NotificationDeliveryCoordinator(store: EmptyStore(), presenter: RecordingPresenter()),
      permission: NotificationPermissionCoordinator(gateway: Permission(),
        wasExplained: (_) async => true, markExplained: (_) async {}),
      router: router,
    );
  });
  tearDown(() async {
    NotificationServices.current = null;
    await store.close();
    await databaseFactory.setDatabasesPath(previousPath);
    await dir.delete(recursive: true);
  });

  AppNotificationEvent event({String account = 'a', String well = 'destination',
    String date = '2027-01-15', String? request, String? booking}) => AppNotificationEvent(
      eventKey: 'route', accountId: account, wellId: well,
      category: 'booking_results', eventType: 'booking.confirmed',
      entityType: 'booking_request', entityId: 'target', routeType: 'bookings',
      routePayload: {'day': date, 'request_id': ?request,
        'booking_id': ?booking}, createdAt: DateTime.utc(2027));

  Future<void> shell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'), supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: AuthenticatedShell(identity: testIdentity(accountId: 'a', wells: [
        testWell(id: 'home'), testWell(id: 'destination'),
        testWell(id: 'inactive', status: 'inactive'),
      ]), onWellChanged: (_) {}, onLogout: () {}),
    ));
    await tester.pumpAndSettle();
  }

  for (final canonical in [false, true]) {
    testWidgets('actual shell opens selected well/day and highlights ${canonical ? "canonical" : "local"} target once without business actions', (tester) async {
      await tester.runAsync(() async {
        final ledger = BookingLocalLedger(store);
        await ledger.saveSchedule(accountId: 'a', wellId: 'destination',
          response: {...day('2027-01-14'), 'well_id': 'destination'}, fetchedAt: DateTime.utc(2027));
        await ledger.saveSchedule(accountId: 'a', wellId: 'destination',
          response: {...day('2027-01-15'), 'well_id': 'destination', 'bookings': [if (canonical) {
            'id': 'canonical', 'public_code': 'B', 'well_id': 'destination',
            'farmer_well_account_id': 'f', 'farm_id': 'farm',
            'scheduled_start': '2027-01-15T07:00:00Z', 'scheduled_end': '2027-01-15T08:00:00Z',
            'scheduled_day': '2027-01-15', 'expected_duration_minutes': 60,
            'status': 'confirmed', 'priority': 0, 'status_group': 'upcoming',
          }]}, fetchedAt: DateTime.utc(2027), updateLatest: false);
        if (!canonical) {
          await BookingRepository(null, null, ledger).saveLocalBooking(
            accountId: 'a', wellId: 'destination', requestId: 'local-target',
            farmer: const FarmerAccount(id: 'f', fullName: 'PRIVATE_FARMER', publicCode: 'F'),
            farm: const Farm(id: 'farm', wellId: 'destination', name: 'PRIVATE_FARM', farmerAccountId: 'f'),
            scheduledStart: DateTime.utc(2027, 1, 15, 7), scheduledEnd: DateTime.utc(2027, 1, 15, 8),
            expectedEnergySource: 'well_diesel');
        }
      });
      final before = await tester.runAsync(() => store.allCommands('a'));
      routeEvent = event(request: canonical ? null : 'local-target', booking: canonical ? 'canonical' : null);
      router.acceptPayload('a/42');
      await shell(tester);
      // FFI reads started by widgets settle outside the fake async clock.
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pumpAndSettle();
      }
      final screen = tester.widget<BookingsScreen>(find.byType(BookingsScreen));
      expect(screen.identity.activeWell.id, 'destination');
      expect(screen.initialDay, DateTime(2027, 1, 15));
      expect(find.byKey(const ValueKey('notification-target-booking')), findsOneWidget);
      expect(find.text('الحجز المطلوب'), findsOneWidget);
      expect(loads, 1);
      final after = await tester.runAsync(() => store.allCommands('a'));
      expect(after!.map((c) => (c.commandId, c.type, c.status)).toList(),
        before!.map((c) => (c.commandId, c.type, c.status)).toList());
      expect(await tester.runAsync(() => store.notificationEvents.db.query('notification_events')), isEmpty);
      expect(find.text('بدء السقي'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      // Dispose the existing shell session projection ticker; no session action.
      OfflineSessionCoordinator.instance.dispose();
    });
  }

  for (final invalid in ['account', 'well', 'inactive', 'date', 'normalized-date']) {
    testWidgets('actual shell safely rejects $invalid notification destination', (tester) async {
      routeEvent = event(account: invalid == 'account' ? 'other' : 'a',
        well: invalid == 'well' ? 'missing' : invalid == 'inactive' ? 'inactive' : 'destination',
        date: invalid == 'date' ? 'invalid' : invalid == 'normalized-date' ? '2027-02-30' : '2027-01-15');
      router.acceptPayload('${routeEvent.accountId}/42');
      await shell(tester);
      expect(find.byType(BookingsScreen), findsNothing);
      expect(await tester.runAsync(() => store.allCommands('a')), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('platform payload contains only opaque lookup identity, never display/business data', () async {
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call); return true;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final e = AppNotificationEvent(eventKey: 'private', accountId: 'a', wellId: 'destination',
      category: 'booking_results', eventType: 'booking.confirmed', entityType: 'booking_request',
      routeType: 'bookings', routePayload: {'day': '2027-01-15', 'request_id': 'secret-request',
        'farmer_name': 'PRIVATE_FARMER', 'amount': 9000}, createdAt: DateTime.utc(2027));
    final presenter = LocalNotificationPresenter();
    await presenter.initialize();
    await presenter.show(42, e, bookingNotificationPolicies.presentation(e)!);
    final args = calls.singleWhere((c) => c.method == 'show').arguments as Map;
    expect(args['payload'], 'a/42');
    expect(args['title'], 'تم تثبيت الحجز');
    expect(args['body'], 'افتح الحجوزات للاطلاع على الموعد.');
    expect(args.toString(), isNot(contains('PRIVATE_FARMER')));
    expect(args.toString(), isNot(contains('9000')));
    expect(args.toString(), isNot(contains('secret-request')));
  });
}

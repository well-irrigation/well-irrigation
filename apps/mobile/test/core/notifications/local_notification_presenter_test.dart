import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/notifications/local_notification_presenter.dart';
import 'package:well_irrigation_mobile/core/notifications/booking_notification_event_factory.dart';

import 'notification_delivery_test.dart' show event;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  late List<MethodCall> calls;
  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'areNotificationsEnabled') return true;
          return true;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test('Android initialization preserves legacy and creates audible channels and never requests permission', () async {
    final presenter = LocalNotificationPresenter();
    await presenter.initialize();
    expect(
      calls.where((c) => c.method == 'requestNotificationsPermission'),
      isEmpty,
    );
    final channels = calls
        .where((c) => c.method == 'createNotificationChannel')
        .toList();
    expect(channels, hasLength(3));
    final args = channels.first.arguments as Map;
    for (final call in channels.skip(1)) {
      final details = call.arguments as Map;
      expect(details['importance'], 3);
      expect(details['playSound'], true);
      expect(details['enableVibration'], true);
    }
    expect(args['id'], 'booking_results_v1');
    expect(args['playSound'], false);
    expect(args['enableVibration'], false);
  });
  test('platform calls use stable IDs, private icon, audible foreground details and safe text', () async {
    final presenter = LocalNotificationPresenter();
    await presenter.initialize();
    final e = event('x');
    final presentation = bookingNotificationPolicies.presentation(e)!;
    await presenter.show(42, e, presentation);
    await presenter.show(42, e, presentation);
    final shows = calls.where((c) => c.method == 'show').toList();
    expect(shows, hasLength(2));
    for (final c in shows) {
      final args = c.arguments as Map;
      expect(args['id'], 42);
      expect(args['title'], 'تم تثبيت الحجز');
      expect(args['body'], 'افتح الحجوزات للاطلاع على الموعد.');
      expect(args['payload'], 'a/42');
      final android = (args['platformSpecifics'] as Map);
      expect(android['icon'], 'ic_notification');
      expect(android['playSound'], true);
      expect(android['priority'], 0);
      expect(android['importance'], 3);
      expect(android['channelId'], 'booking_results_v2');
      expect(android['enableVibration'], true);
      expect(android['onlyAlertOnce'], true);
    }
  });
  test(
    'schedule uses inexact mode, stable ID and the same private presentation',
    () async {
      final presenter = LocalNotificationPresenter();
      await presenter.initialize();
      final e = event('future');
      await presenter.schedule(
        42,
        e,
        bookingNotificationPolicies.presentation(e)!,
        DateTime.utc(2040),
      );
      await presenter.cancel(42);
      final args =
          calls.singleWhere((c) => c.method == 'zonedSchedule').arguments
              as Map;
      expect(args['id'], 42);
      final android = args['platformSpecifics'] as Map;
      expect(android['scheduleMode'], 'inexactAllowWhileIdle');
      expect(android['playSound'], true);
      expect(calls.singleWhere((c) => c.method == 'cancel').arguments, {
        'id': 42,
        'tag': null,
      });
    },
  );
}

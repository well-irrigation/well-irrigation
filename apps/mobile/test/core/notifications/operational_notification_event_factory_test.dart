import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/notifications/operational_notification_event_factory.dart';

import 'package:well_irrigation_mobile/core/notifications/booking_notification_event_factory.dart';
import 'package:well_irrigation_mobile/core/notifications/app_notification_event.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

final epoch = DateTime.utc(2027, 1, 1);

void main() {
  test(
    'العائلات المعتمدة ترفض تصنيف الخصوصية والفئة وسياسة العرض غير المصرح بها',
    () {
      for (final type in appNotificationPolicies.builders.keys) {
        final bookingResult = bookingNotificationPolicies.builders.containsKey(
          type,
        );
        final original = AppNotificationEvent(
          eventKey: 'privacy/$type',
          accountId: 'a',
          wellId: 'w',
          category: bookingResult ? 'booking_results' : 'operational_alerts',
          eventType: type,
          entityType: 'booking',
          entityId: 'b',
          routeType: 'bookings',
          routePayload: const {'day': '2027-01-01'},
          createdAt: epoch,
          presentationPolicy: 'always_alert',
        );
        expect(original.privacyClass, 'private');
        expect(appNotificationPolicies.presentation(original), isNotNull);
        for (final privacy in ['public', 'secret', 'unknown', '']) {
          final unsafe = AppNotificationEvent.fromRow({
            ...original.toRow(),
            'privacy_class': privacy,
          });
          expect(
            appNotificationPolicies.presentation(unsafe),
            isNull,
            reason: '$type/$privacy',
          );
        }
        for (final change in [
          {
            'category': bookingResult
                ? 'operational_alerts'
                : 'booking_results',
          },
          {'presentation_policy': 'unknown'},
          if (!bookingResult) {'presentation_policy': 'always_silent'},
        ]) {
          expect(
            appNotificationPolicies.presentation(
              AppNotificationEvent.fromRow({...original.toRow(), ...change}),
            ),
            isNull,
            reason: '$type/$change',
          );
        }
      }
    },
  );

  test('all new booking result kinds use audible v2 while persisted silent legacy stays v1', () {
    for (final response in [
      <String, Object?>{'status': 'confirmed'},
      {'status': 'conflict'},
      {'status': 'rejected'},
      <String, Object?>{},
    ]) {
      final e = bookingNotificationEvent(
        accountId: 'a',
        wellId: 'w',
        commandId: 'c',
        requestId: 'r',
        scheduledDay: '2027-01-01',
        at: epoch,
        status: response['status'] == 'confirmed'
            ? CommandStatus.confirmed
            : CommandStatus.review,
        response: response,
      )!.event;
      expect(
        appNotificationPolicies.presentation(e)!.channelId,
        'booking_results_v2',
      );
      final legacy = AppNotificationEvent.fromRow({
        ...e.toRow(),
        'presentation_policy': 'always_silent',
      });
      expect(
        appNotificationPolicies.presentation(legacy)!.channelId,
        'booking_results_v1',
      );
    }
  });
  test('every operational presentation uses approved generic private text, ignoring sensitive context', () {
    for (final type in [
      'booking.reminder_upcoming',
      'booking.due',
      'session.near_end',
    ]) {
      final e = operationalEvent(
        accountId: 'a',
        wellId: 'w',
        eventType: type,
        identity: 'secret-command',
        entityType: 'session',
        entityId: 'secret-uuid',
        at: epoch,
        routePayload: {
          'farmer_name': 'اسم سري',
          'farm_name': 'أرض سرية',
          'phone': '770123456',
          'amount': 123456,
        },
      );
      final p = appNotificationPolicies.presentation(e)!;
      expect(p.channelId, 'operational_alerts_v1');
      for (final secret in [
        'اسم سري',
        'أرض سرية',
        '770123456',
        '123456',
        'secret-uuid',
        'secret-command',
      ]) {
        expect('${p.title} ${p.body}', isNot(contains(secret)));
      }
    }
    final e = operationalEvent(
      accountId: 'a',
      wellId: 'w',
      eventType: 'future.disabled',
      identity: 'x',
      entityType: 'future',
      entityId: 'x',
      at: epoch,
    );
    expect(appNotificationPolicies.presentation(e), null);
  });
  test('booking route uses canonical well day across UTC midnight', () {
    final reminders = bookingReminderEvents(
      accountId: 'a',
      wellId: 'w',
      bookingId: 'b',
      scheduledStart: DateTime.utc(2027, 1, 1, 21, 30),
      scheduledDay: '2027-01-02',
      createdAt: epoch,
    );
    expect(reminders[1].event.routePayload['day'], '2027-01-02');
    expect(
      reminders[1].event.eventKey,
      'booking-reminder/due/b/1798839000000000',
    );
  });
  test('booking reminders use exact offsets and stable business identity', () {
    final start = DateTime.utc(2027, 1, 1, 12);
    final reminders = bookingReminderEvents(
      accountId: 'a',
      wellId: 'w',
      bookingId: 'b',
      scheduledStart: start,
      createdAt: DateTime.utc(2027),
    );
    expect(reminders[0].due, DateTime.utc(2027, 1, 1, 11, 50));
    expect(reminders[1].due, start);
    expect(
      reminders[0].event.eventKey,
      'booking-reminder/upcoming/b/1798804800000000',
    );
    expect(
      reminders[1].event.eventKey,
      'booking-reminder/due/b/1798804800000000',
    );
    expect(
      appNotificationPolicies.presentation(reminders[0].event)!.channelId,
      'operational_alerts_v1',
    );
  });
  test('near end requires trusted finite end and subtracts five minutes', () {
    expect(
      sessionNearEndEvent(
        accountId: 'a',
        wellId: 'w',
        sessionId: 's',
        trustedEnd: null,
        createdAt: DateTime.utc(2027),
      ),
      isNull,
    );
    final reminder = sessionNearEndEvent(
      accountId: 'a',
      wellId: 'w',
      sessionId: 's',
      trustedEnd: DateTime.utc(2027, 1, 1, 12),
      createdAt: DateTime.utc(2027),
    )!;
    expect(reminder.due, DateTime.utc(2027, 1, 1, 11, 55));
    expect(
      reminder.event.eventKey,
      'session-reminder/near-end/s/1798804800000000',
    );
  });
}

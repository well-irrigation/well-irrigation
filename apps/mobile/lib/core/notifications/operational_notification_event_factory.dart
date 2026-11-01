import 'app_notification_event.dart';
import 'booking_notification_event_factory.dart';
import 'notification_presenter.dart';

/// Intent only: the scheduler must separately prove current eligibility/time.
typedef ScheduledNotificationIntent = ({
  AppNotificationEvent event,
  DateTime due,
});

AppNotificationEvent operationalEvent({
  required String accountId,
  required String wellId,
  required String eventType,
  required String identity,
  required String entityType,
  required String entityId,
  required DateTime at,
  String routeType = 'operations',
  Map<String, Object?> routePayload = const {},
}) => AppNotificationEvent(
  eventKey: '$eventType/$identity',
  accountId: accountId,
  wellId: wellId,
  category: 'operational_alerts',
  eventType: eventType,
  entityType: entityType,
  entityId: entityId,
  routeType: routeType,
  routePayload: routePayload,
  createdAt: at,
  presentationPolicy: 'always_alert',
);

List<ScheduledNotificationIntent> bookingReminderEvents({
  required String accountId,
  required String wellId,
  required String bookingId,
  required DateTime scheduledStart,
  required DateTime createdAt,
  String? scheduledDay,
}) {
  final start = scheduledStart.toUtc();
  final day =
      '${scheduledStart.year}-${scheduledStart.month.toString().padLeft(2, '0')}-${scheduledStart.day.toString().padLeft(2, '0')}';
  return [
    for (final kind in ['upcoming', 'due'])
      (
        event: AppNotificationEvent(
          eventKey:
              'booking-reminder/$kind/$bookingId/${start.microsecondsSinceEpoch}',
          accountId: accountId,
          wellId: wellId,
          category: 'operational_alerts',
          eventType: kind == 'upcoming'
              ? 'booking.reminder_upcoming'
              : 'booking.due',
          entityType: 'booking',
          entityId: bookingId,
          routeType: 'bookings',
          routePayload: {'day': scheduledDay ?? day, 'booking_id': bookingId},
          createdAt: createdAt,
          presentationPolicy: 'always_alert',
        ),
        due: kind == 'upcoming'
            ? start.subtract(const Duration(minutes: 10))
            : start,
      ),
  ];
}

ScheduledNotificationIntent? sessionNearEndEvent({
  required String accountId,
  required String wellId,
  required String sessionId,
  required DateTime? trustedEnd,
  required DateTime createdAt,
}) {
  if (trustedEnd == null) return null;
  final end = trustedEnd.toUtc();
  return (
    event: AppNotificationEvent(
      eventKey:
          'session-reminder/near-end/$sessionId/${end.microsecondsSinceEpoch}',
      accountId: accountId,
      wellId: wellId,
      category: 'operational_alerts',
      eventType: 'session.near_end',
      entityType: 'session',
      entityId: sessionId,
      routeType: 'operations',
      routePayload: const {},
      createdAt: createdAt,
      presentationPolicy: 'always_alert',
    ),
    due: end.subtract(const Duration(minutes: 5)),
  );
}

final appNotificationPolicies = NotificationPolicyRegistry(
  builders: {
    ...bookingNotificationPolicies.builders,
    for (final type in _texts.keys) type: _presentation,
  },
);
const _texts = <String, (String, String)>{
  'booking.reminder_upcoming': (
    'اقترب موعد الحجز',
    'راجع الحجوزات للاستعداد للموعد.',
  ),
  'booking.due': ('حان موعد الحجز', 'الحجز جاهز للبدء.'),
  'session.near_end': ('اقترب انتهاء الجلسة', 'راجع الجلسة قبل انتهاء الوقت.'),
};
NotificationPresentation? _presentation(AppNotificationEvent event) {
  if (event.category != 'operational_alerts' ||
      event.privacyClass != 'private' ||
      event.presentationPolicy != 'always_alert') {
    return null;
  }
  final text = _texts[event.eventType];
  return text == null
      ? null
      : NotificationPresentation(text.$1, text.$2, 'operational_alerts_v1');
}

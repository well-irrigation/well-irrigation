import 'app_notification_event.dart';

abstract interface class NotificationPresenter {
  Future<void> initialize();
  Future<bool> permissionGranted();
  Future<void> show(
    int id,
    AppNotificationEvent event,
    NotificationPresentation presentation,
  );
}

abstract interface class ScheduledNotificationPresenter
    implements NotificationPresenter {
  Future<void> schedule(
    int id,
    AppNotificationEvent event,
    NotificationPresentation presentation,
    DateTime wallTime,
  );
  Future<void> cancel(int id);
}

class NotificationPresentation {
  const NotificationPresentation(this.title, this.body, this.channelId);
  final String title, body, channelId;
}

/// سياسة التسجيل مستقلة عن المجال؛ المستهلك يسجل أنواع أحداثه المفعّلة فقط.
class NotificationPolicyRegistry {
  const NotificationPolicyRegistry({this.builders = const {}});
  final Map<String, NotificationPresentation? Function(AppNotificationEvent)>
  builders;
  NotificationPresentation? presentation(AppNotificationEvent event) =>
      builders[event.eventType]?.call(event);
}

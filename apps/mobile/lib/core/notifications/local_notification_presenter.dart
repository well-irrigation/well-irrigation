import 'package:flutter/foundation.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_notification_event.dart';
import 'notification_channel_registry.dart';
import 'notification_presenter.dart';
import 'notification_permission_coordinator.dart';

class LocalNotificationPresenter
    implements ScheduledNotificationPresenter, NotificationPermissionGateway {
  LocalNotificationPresenter({
    FlutterLocalNotificationsPlugin? plugin,
    this.onTap,
    this.channels = const NotificationChannelRegistry(),
  }) : plugin = plugin ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin plugin;
  final void Function(String?)? onTap;
  final NotificationChannelRegistry channels;
  Future<void>? _initialization;
  AndroidFlutterLocalNotificationsPlugin? get _android => plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  @override
  Future<void> initialize() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await (_initialization ??= _initialize());
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  Future<void> _initialize() async {
    // التهيئة صريحة في كل عملية، بما فيها نقطة دخول WorkManager غير main.
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
      ),
      onDidReceiveNotificationResponse: onTap == null
          ? null
          : (response) => onTap!(response.payload),
    );
    for (final channel in channels.channels) {
      await _android!.createNotificationChannel(channel);
    }
  }

  Future<String?> launchPayload() async =>
      (await plugin.getNotificationAppLaunchDetails())
          ?.notificationResponse
          ?.payload;
  @override
  Future<bool> permissionGranted() async {
    await initialize();
    return defaultTargetPlatform == TargetPlatform.android &&
        (await _android?.areNotificationsEnabled() ?? false);
  }

  @override
  Future<bool> requestPermission() async {
    await initialize();
    return await _android?.requestNotificationsPermission() ?? false;
  }

  @override
  Future<void> show(
    int id,
    AppNotificationEvent event,
    NotificationPresentation presentation,
  ) async {
    await plugin.show(
      id: id,
      title: presentation.title,
      body: presentation.body,
      notificationDetails: _details(presentation),
      payload: '${event.accountId}/$id',
    );
  }

  NotificationDetails _details(NotificationPresentation presentation) {
    final channel = channels.channels.singleWhere(
      (c) => c.id == presentation.channelId,
    );
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channel.id,
        channel.name,
        channelDescription: channel.description,
        importance: channel.importance,
        priority: channel.importance == Importance.low
            ? Priority.low
            : Priority.defaultPriority,
        playSound: channel.playSound,
        enableVibration: channel.enableVibration,
        onlyAlertOnce: true,
        visibility: NotificationVisibility.private,
        icon: 'ic_notification',
      ),
    );
  }

  @override
  Future<void> schedule(
    int id,
    AppNotificationEvent event,
    NotificationPresentation presentation,
    DateTime wallTime,
  ) async {
    await initialize();
    await plugin.zonedSchedule(
      id: id,
      title: presentation.title,
      body: presentation.body,
      scheduledDate: tz.TZDateTime.from(wallTime.toUtc(), tz.UTC),
      notificationDetails: _details(presentation),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: '${event.accountId}/$id',
    );
  }

  @override
  Future<void> cancel(int id) => plugin.cancel(id: id);
}

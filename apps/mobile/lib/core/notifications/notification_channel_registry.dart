import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// معرّفات قنوات ثابتة؛ يضاف المستهلك المستقبلي هنا عند تفعيله فقط.
class NotificationChannelRegistry {
  const NotificationChannelRegistry();
  List<AndroidNotificationChannel> get channels => const [
    AndroidNotificationChannel(
      'booking_results_v1',
      'نتائج الحجوزات',
      description: 'نتائج تأكيد الحجوزات والحالات التي تحتاج إجراء',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    ),
    AndroidNotificationChannel(
      'booking_results_v2',
      'نتائج الحجوزات',
      description: 'نتائج تأكيد الحجوزات والحالات التي تحتاج إجراء',
      importance: Importance.defaultImportance,
      playSound: true,
      enableVibration: true,
    ),
    AndroidNotificationChannel(
      'operational_alerts_v1',
      'تنبيهات التشغيل والجلسات',
      description: 'تنبيهات مواعيد الحجوزات وحالة جلسات السقي والتشغيل',
      importance: Importance.defaultImportance,
      playSound: true,
      enableVibration: true,
    ),
  ];
}

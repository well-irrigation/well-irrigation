import 'dart:async';

import 'notification_delivery_coordinator.dart';
import 'notification_permission_coordinator.dart';
import 'notification_router.dart';
import 'operational_notification_scheduler.dart';

/// تركيب الخدمات في عملية الواجهة فقط. العامل يبني نسخته المستقلة.
class NotificationServices {
  NotificationServices({
    required this.delivery,
    required this.permission,
    required this.router,
    this.scheduling,
    this.recoverSchedules,
  });
  static NotificationServices? current;
  final NotificationDeliveryCoordinator delivery;
  final NotificationPermissionCoordinator permission;
  final NotificationRouter router;
  final OperationalNotificationScheduler? scheduling;
  final Future<void> Function(String account, String well)? recoverSchedules;
  final Map<String, Completer<void>> _recovering = {};

  Future<void> recover(String account, String well) {
    final active = _recovering[account];
    if (active != null) return active.future;
    final flight = Completer<void>();
    _recovering[account] = flight;
    unawaited(() async {
      try {
        await recoverSchedules?.call(account, well);
      } catch (_) {
        // فرصة لاحقة تعيد المحاولة؛ لا يفشل مسار الواجهة.
      } finally {
        _recovering.remove(account);
        flight.complete();
      }
    }());
    return flight.future;
  }
}

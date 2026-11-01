import 'package:flutter/foundation.dart';

import 'app_notification_event.dart';

class NotificationRoute {
  NotificationRoute({
    required this.type,
    required this.wellId,
    required this.payload,
  });
  final String type;
  final String? wellId;
  final Map<String, Object?> payload;
}

/// يحتفظ بنقرة الإقلاع حتى وصول الهوية؛ الحمولة مجرد مفتاح لصف محلي موثوق.
class NotificationRouter extends ChangeNotifier {
  NotificationRouter({required this.load});
  final Future<AppNotificationEvent?> Function(String, int) load;
  (String, int)? _pending;
  bool get hasPending => _pending != null;
  void acceptPayload(String? payload) {
    final parts = payload?.split('/');
    if (parts == null || parts.length != 2 || parts[0].isEmpty) return;
    final id = int.tryParse(parts[1]);
    if (id == null || id < 1) return;
    _pending = (parts[0], id);
    notifyListeners();
  }

  Future<NotificationRoute?> resolve({
    required String accountId,
    required Set<String> accessibleWellIds,
  }) async {
    final target = _pending;
    if (target == null) return null;
    _pending = null;
    if (target.$1 != accountId) return null;
    final event = await load(accountId, target.$2);
    if (event == null ||
        event.accountId != accountId ||
        event.wellId != null && !accessibleWellIds.contains(event.wellId)) {
      return null;
    }
    return NotificationRoute(
      type: event.routeType,
      wellId: event.wellId,
      payload: event.routePayload,
    );
  }
}

/// إدخال عام؛ لا أنواع Firebase ولا إصدار إشعار مباشرة من المصدر.
class NotificationIngress {
  NotificationIngress(this.persist);
  final Future<void> Function(AppNotificationEvent) persist;
  Future<void> receive(AppNotificationEvent event) => persist(event);
}

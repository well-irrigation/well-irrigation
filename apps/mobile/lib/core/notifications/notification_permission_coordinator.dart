abstract interface class NotificationPermissionGateway {
  Future<bool> permissionGranted();
  Future<bool> requestPermission();
}

class NotificationRationale {
  const NotificationRationale({required this.title, required this.body});
  final String title, body;
}

const bookingResultRationale = NotificationRationale(
  title: 'السماح بإشعارات نتيجة الحجز',
  body: 'لتصلك نتيجة الحجز حتى عندما لا يكون التطبيق أمامك.',
);

/// لا يعرف الحجز ولا يملك نافذة: المضيف المرئي يوفّر الشرح، والمستخدم يقرر.
class NotificationPermissionCoordinator {
  NotificationPermissionCoordinator({
    required this.gateway,
    required this.wasExplained,
    required this.markExplained,
  });
  final NotificationPermissionGateway gateway;
  final Future<bool> Function(String) wasExplained;
  final Future<void> Function(String) markExplained;
  Future<bool> Function(NotificationRationale)? explain;
  bool _busy = false;
  Future<void> offer(String accountId, NotificationRationale rationale) async {
    if (_busy || explain == null) return;
    _busy = true;
    try {
      if (await wasExplained(accountId) || await gateway.permissionGranted()) {
        return;
      }
      await markExplained(accountId);
      if (await explain!(rationale)) await gateway.requestPermission();
    } catch (_) {
      // الصلاحية اختيارية؛ لا تؤثر على الحفظ المحلي.
    } finally {
      _busy = false;
    }
  }
}

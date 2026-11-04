import 'notification_event_store.dart';
import 'notification_presenter.dart';

/// فرصة محدودة، مستقلة تمامًا عن النقل التجاري. لا تجدول ولا تعيد إرسال حجز.
class NotificationDeliveryCoordinator {
  NotificationDeliveryCoordinator({
    required this.store,
    required this.presenter,
    DateTime Function()? clock,
    this.isAccountActive,
    this.scheduledCleanup,
    this.policies = const NotificationPolicyRegistry(),
  }) : clock = clock ?? DateTime.now;
  final NotificationEventStore store;
  final NotificationPresenter presenter;
  final DateTime Function() clock;
  final NotificationPolicyRegistry policies;
  final bool Function(String accountId)? isAccountActive;
  final Future<bool> Function(String account, int limit)? scheduledCleanup;
  static const leaseDuration = Duration(minutes: 1);

  /// true: توجد حاجة لفرصة لاحقة عادية، عبر المجدول القائم فقط.
  Future<bool> deliver(String accountId) async {
    try {
      if (isAccountActive?.call(accountId) == false) return false;
      await presenter.initialize().timeout(const Duration(seconds: 10));
      final page = await store.pending(accountId, clock());
      var retry = false;
      for (final item in page) {
        final now = clock();
        final lease = now.add(leaseDuration);
        if (!await store.claim(accountId, item.localId, now, lease)) continue;
        final presentation = policies.presentation(item.event);
        if (presentation == null) {
          await store.complete(
            accountId,
            item.localId,
            lease,
            clock(),
            suppressedReason: 'policy_not_enabled',
          );
          continue;
        }
        if (!await presenter.permissionGranted().timeout(
          const Duration(seconds: 10),
        )) {
          await store.complete(
            accountId,
            item.localId,
            lease,
            clock(),
            suppressedReason: 'permission_denied',
          );
          continue;
        }
        if (isAccountActive?.call(accountId) == false) {
          await store.complete(
            accountId,
            item.localId,
            lease,
            clock(),
            retry: true,
          );
          return false;
        }
        if (!await store.beginPresentation(accountId, item.localId, lease)) {
          await store.complete(
            accountId,
            item.localId,
            lease,
            clock(),
            suppressedReason: 'delivery_failed',
          );
          continue;
        }
        try {
          await presenter
              .show(item.localId, item.event, presentation)
              .timeout(const Duration(seconds: 20));
        } catch (_) {
          final exhausted = item.attempts + 1 >= 3;
          await store.complete(
            accountId,
            item.localId,
            lease,
            clock(),
            retry: !exhausted,
            suppressedReason: exhausted ? 'delivery_failed' : null,
          );
          retry = retry || !exhausted;
          continue;
        }
        // إن فشل هذا التحديث تبقى المطالبة قابلة للاستعادة؛ لا نعيد النقل التجاري.
        await store.complete(accountId, item.localId, lease, clock());
      }
      final cleanup =
          await scheduledCleanup?.call(accountId, 20 - page.length) ?? false;
      return retry || cleanup || await store.hasOutstanding(accountId);
    } catch (_) {
      // يشمل فشل التهيئة/المطالبة/تحديث الحالة بعد حفظ النتيجة.
      return true;
    }
  }
}

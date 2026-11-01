import '../sync/sync_status.dart';
import 'app_notification_event.dart';
import 'notification_presenter.dart';

/// تحويل حقيقة الحجز إلى حدث عام؛ طبقة التسليم لا تعرف نماذج الحجز.
({AppNotificationEvent event, String? suppression})? bookingNotificationEvent({
  required String accountId,
  required String wellId,
  required String commandId,
  required String requestId,
  required String scheduledDay,
  required DateTime at,
  required CommandStatus status,
  Map<String, Object?>? response,
  String? supersededBy,
}) {
  final kind = status == CommandStatus.confirmed
      ? 'confirmed'
      : status != CommandStatus.review
      ? null
      : switch (response?['status']) {
          'conflict' => 'time_unavailable',
          'rejected' => 'rejected',
          _ => 'review_required',
        };
  if (kind == null) return null;
  final lateConfirmed = supersededBy != null && kind == 'confirmed';
  return (
    event: AppNotificationEvent(
      eventKey: 'booking-result/$commandId/$kind',
      accountId: accountId,
      wellId: wellId,
      category: 'booking_results',
      eventType: 'booking.${lateConfirmed ? 'review_required' : kind}',
      entityType: 'booking_request',
      entityId: requestId,
      routeType: 'bookings',
      routePayload: {
        'day': scheduledDay,
        'request_id': requestId,
        if (status == CommandStatus.confirmed &&
            response?['booking_id'] is String)
          'booking_id': response!['booking_id'],
        if (lateConfirmed) 'previous_confirmed': true,
      },
      createdAt: at,
      presentationPolicy: 'always_alert',
    ),
    suppression: supersededBy != null && !lateConfirmed ? 'superseded' : null,
  );
}

const bookingNotificationPolicies = NotificationPolicyRegistry(
  builders: {
    'booking.confirmed': _bookingPresentation,
    'booking.time_unavailable': _bookingPresentation,
    'booking.rejected': _bookingPresentation,
    'booking.review_required': _bookingPresentation,
  },
);
NotificationPresentation? _bookingPresentation(AppNotificationEvent event) {
  if (event.category != 'booking_results' ||
      !const {
        'always_silent',
        'always_alert',
      }.contains(event.presentationPolicy) ||
      event.privacyClass != 'private') {
    return null;
  }
  final channel = event.presentationPolicy == 'always_silent'
      ? 'booking_results_v1'
      : 'booking_results_v2';
  return switch (event.eventType) {
    'booking.confirmed' => NotificationPresentation(
      'تم تثبيت الحجز',
      'افتح الحجوزات للاطلاع على الموعد.',
      channel,
    ),
    'booking.time_unavailable' => NotificationPresentation(
      'هذا الموعد لم يعد متاحًا',
      'افتح الحجز لاختيار موعد آخر.',
      channel,
    ),
    'booking.rejected' => NotificationPresentation(
      'يحتاج الحجز إلى تعديل',
      'افتح الحجز لتعديل بياناته.',
      channel,
    ),
    'booking.review_required' => NotificationPresentation(
      'راجع الحجز',
      event.routePayload['previous_confirmed'] == true
          ? 'تم تثبيت طلب سابق. افتح الحجوزات للمراجعة.'
          : 'افتح الحجز للاطلاع على حالته.',
      channel,
    ),
    _ => null,
  };
}

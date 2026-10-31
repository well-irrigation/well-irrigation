import '../sync/sync_status.dart';
import 'app_notification_event.dart';

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

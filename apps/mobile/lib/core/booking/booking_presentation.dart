import 'package:flutter/material.dart';

import '../api/booking_repository.dart';
import '../session/active_session_record.dart';
import '../theme/app_colors.dart';
import 'booking_reactivity.dart';

enum BookingPresentationState {
  current,
  executed,
  cancelled,
  noShow,
  postponed,
  next,
  confirmed,
  pending,
  waiting,
  ready,
  draft,
  unknown,
}

class BookingPresentation {
  const BookingPresentation(this.state, {this.endedAt, this.syncState});
  final BookingPresentationState state;
  final DateTime? endedAt;
  final SessionSyncState? syncState;
  bool get isCurrent => state == BookingPresentationState.current;
  bool get isNext => state == BookingPresentationState.next;
  bool get isTerminal => switch (state) {
    BookingPresentationState.executed ||
    BookingPresentationState.cancelled ||
    BookingPresentationState.noShow ||
    BookingPresentationState.postponed => true,
    _ => false,
  };
  bool get canStart => state == BookingPresentationState.confirmed || isNext;
  String get label => switch (state) {
    BookingPresentationState.current => 'جاري',
    BookingPresentationState.executed => 'منفذ',
    BookingPresentationState.cancelled => 'ملغى',
    BookingPresentationState.noShow => 'لم يُنفذ',
    BookingPresentationState.postponed => 'مؤجل',
    BookingPresentationState.next => 'التالي',
    BookingPresentationState.confirmed => 'مؤكد',
    BookingPresentationState.pending => 'بانتظار التأكيد',
    BookingPresentationState.waiting => 'بانتظار الموعد',
    BookingPresentationState.ready => 'جاهز',
    BookingPresentationState.draft => 'مسودة غير مكتملة',
    BookingPresentationState.unknown => 'غير محدد',
  };
  String? get syncLabel => switch (syncState) {
    null || SessionSyncState.synced => null,
    SessionSyncState.localOnly =>
      state == BookingPresentationState.executed
          ? 'بانتظار المزامنة'
          : 'محفوظ على الجهاز',
    SessionSyncState.pending => 'بانتظار المزامنة',
    SessionSyncState.syncing => 'جارٍ المزامنة',
    SessionSyncState.conflict => 'يحتاج مراجعة',
  };
  Color get color => switch (state) {
    BookingPresentationState.executed => AppColors.success,
    BookingPresentationState.current => AppColors.agriculturalGreen,
    BookingPresentationState.cancelled => AppColors.error,
    BookingPresentationState.noShow => AppColors.warning,
    BookingPresentationState.postponed => AppColors.textSecondary,
    BookingPresentationState.next ||
    BookingPresentationState.confirmed => AppColors.waterBlue,
    _ => AppColors.textSecondary,
  };
  IconData get icon => switch (state) {
    BookingPresentationState.executed => Icons.check_circle_rounded,
    BookingPresentationState.current => Icons.play_circle_rounded,
    BookingPresentationState.cancelled => Icons.cancel_rounded,
    BookingPresentationState.noShow => Icons.warning_amber_rounded,
    BookingPresentationState.postponed => Icons.update_rounded,
    BookingPresentationState.next => Icons.skip_next_rounded,
    _ => Icons.event_available_rounded,
  };
}

String? armedNextBookingId(BookingAutomationState? automation) =>
    automation?.enabled == true &&
        const {'active', 'waiting'}.contains(automation?.activeChainStatus)
    ? automation?.activeChainNextBookingId
    : null;

BookingPresentation presentBooking({
  required String id,
  required String status,
  BookingSessionSummary? session,
  BookingScope? scope,
  String? currentBookingId,
  String? nextBookingId,
}) {
  final local = scope?.sessions[id];
  final completed =
      local?.completedAt != null ||
      (scope?.completedBookings.containsKey(id) ?? false) ||
      (session != null &&
          (scope?.closedSessionIds.contains(session.sessionId) ?? false));
  final state = local?.businessState.isActive == true
      ? BookingPresentationState.current
      : completed
      ? BookingPresentationState.executed
      : session?.status == 'open' ||
            (currentBookingId == id && session?.status != 'closed')
      ? BookingPresentationState.current
      : session?.status == 'closed' || status == 'completed'
      ? BookingPresentationState.executed
      : switch (status) {
          'cancelled' || 'canceled' => BookingPresentationState.cancelled,
          'no_show' => BookingPresentationState.noShow,
          'postponed' => BookingPresentationState.postponed,
          'confirmed' =>
            (scope?.hasLocalChain == true
                            ? scope?.nextBookingId
                            : nextBookingId) ==
                        id &&
                    session == null
                ? BookingPresentationState.next
                : BookingPresentationState.confirmed,
          'pending' => BookingPresentationState.pending,
          'waiting' => BookingPresentationState.waiting,
          'ready' => BookingPresentationState.ready,
          'draft' => BookingPresentationState.draft,
          'running' ||
          'in_progress' ||
          'started' => BookingPresentationState.current,
          _ => BookingPresentationState.unknown,
        };
  return BookingPresentation(
    state,
    endedAt:
        local?.completedAt ?? scope?.completedBookings[id] ?? session?.endedAt,
    syncState: local?.syncState ?? scope?.completionSync[id],
  );
}

/// الجاري، التالي، ثم الموعد تصاعديًا والأولوية تنازليًا والرمز تصاعديًا.
int compareBookingPresentation({
  required BookingPresentation a,
  required BookingPresentation b,
  required DateTime aStart,
  required DateTime bStart,
  required int aPriority,
  required int bPriority,
  required String aCode,
  required String bCode,
}) {
  int rank(BookingPresentation value) => value.isCurrent
      ? 0
      : value.isNext
      ? 1
      : 2;
  var result = rank(a).compareTo(rank(b));
  if (result == 0) result = aStart.compareTo(bStart);
  if (result == 0) result = bPriority.compareTo(aPriority);
  if (result == 0) result = aCode.compareTo(bCode);
  return result;
}

int compareBookingHistory(
  BookingPresentation a,
  BookingPresentation b,
  DateTime aStart,
  DateTime bStart,
  String aCode,
  String bCode,
) {
  final result = (b.endedAt ?? bStart).compareTo(a.endedAt ?? aStart);
  return result == 0 ? aCode.compareTo(bCode) : result;
}

String bookingEndedText(DateTime at) {
  final time = at.toUtc().add(const Duration(hours: 3));
  return 'اكتملت الجلسة ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

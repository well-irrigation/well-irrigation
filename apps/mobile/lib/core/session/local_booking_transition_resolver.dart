import '../api/booking_repository.dart';

/// قرار تشغيل محلي مؤقت من لقطة القراءة؛ لا يمنح سلطة تنفيذ خادمية.
class ResolvedLocalBookingTransitionCandidate {
  const ResolvedLocalBookingTransitionCandidate({
    required this.currentBooking,
    required this.nextBooking,
    required this.operationalEnd,
    required this.dueAt,
    required this.currentSessionId,
    required this.chainId,
    required this.decisionRevision,
    required this.automationRevision,
  });
  final BookingDayItem currentBooking;
  final BookingDayItem nextBooking;
  final DateTime operationalEnd;
  final DateTime dueAt;
  final String currentSessionId;
  final String chainId;
  final int decisionRevision;
  final int automationRevision;

  bool sameDecisionAs(ResolvedLocalBookingTransitionCandidate other) =>
      currentSessionId == other.currentSessionId &&
      chainId == other.chainId &&
      decisionRevision == other.decisionRevision &&
      automationRevision == other.automationRevision &&
      currentBooking.id == other.currentBooking.id &&
      nextBooking.id == other.nextBooking.id &&
      operationalEnd == other.operationalEnd &&
      dueAt == other.dueAt;
}

ResolvedLocalBookingTransitionCandidate? resolveLocalBookingTransition({
  required WellDaySchedule schedule,
  required BookingAutomationState automation,
}) {
  final current = schedule.currentSession;
  if (!automation.enabled ||
      !automation.settingsRowExists ||
      automation.wellId != schedule.wellId ||
      automation.firstSession != 'manual' ||
      automation.activeChainStatus != 'active' ||
      automation.activeChainId == null ||
      automation.activeChainDecisionRevision == null ||
      automation.revision == null ||
      current == null ||
      current.status != 'open' ||
      current.wellId != schedule.wellId ||
      current.bookingId == null ||
      !schedule.dayStart.isBefore(schedule.dayEnd)) {
    return null;
  }
  final currentBookings = schedule.bookings
      .where((b) => b.id == current.bookingId)
      .toList();
  if (currentBookings.length != 1) return null;
  final currentBooking = currentBookings.single;
  bool structurallyValid(BookingDayItem b) =>
      b.wellId == schedule.wellId &&
      b.expectedDurationMinutes > 0 &&
      b.scheduledStart.isBefore(b.scheduledEnd) &&
      !b.scheduledStart.isBefore(schedule.dayStart) &&
      !b.scheduledEnd.isAfter(schedule.dayEnd);
  if (!structurallyValid(currentBooking)) return null;
  final candidates = schedule.bookings
      .where(
        (b) =>
            b.id != current.bookingId &&
            b.status == 'confirmed' &&
            b.session == null &&
            b.canStartManually &&
            b.farmId!.isNotEmpty &&
            b.expectedEnergySource!.isNotEmpty &&
            structurallyValid(b),
      )
      .toList();
  int compare(BookingDayItem a, BookingDayItem b) {
    final start = a.scheduledStart.compareTo(b.scheduledStart);
    if (start != 0) return start;
    final priority = b.priority.compareTo(a.priority);
    return priority != 0 ? priority : a.publicCode.compareTo(b.publicCode);
  }

  candidates.sort(compare);
  if (candidates.isEmpty ||
      (candidates.length > 1 && compare(candidates[0], candidates[1]) == 0)) {
    return null;
  }
  final next = candidates.first;
  // لا نعيد تفسير مؤشر قرار قائم؛ active/null هو المسار الطبيعي للبدء اليدوي.
  if (automation.activeChainNextBookingId != null &&
      automation.activeChainNextBookingId != next.id) {
    return null;
  }
  final operationalEnd = current.startedAt.add(
    Duration(minutes: currentBooking.expectedDurationMinutes),
  );
  return ResolvedLocalBookingTransitionCandidate(
    currentSessionId: current.sessionId,
    chainId: automation.activeChainId!,
    decisionRevision: automation.activeChainDecisionRevision!,
    automationRevision: automation.revision!,
    currentBooking: currentBooking,
    nextBooking: next,
    operationalEnd: operationalEnd,
    dueAt: operationalEnd.isAfter(next.scheduledStart)
        ? operationalEnd
        : next.scheduledStart,
  );
}

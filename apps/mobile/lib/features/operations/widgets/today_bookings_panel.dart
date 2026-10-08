import 'package:flutter/material.dart';

import '../../../core/api/booking_repository.dart';
import '../../../core/api/operations_repository.dart';
import '../../../core/theme/app_colors.dart';

class TodayBookingsPanel extends StatelessWidget {
  const TodayBookingsPanel({
    required this.schedule,
    required this.automation,
    required this.isLoadingSchedule,
    required this.isLoadingAutomation,
    required this.isUpdatingAutomation,
    required this.canManageAutomation,
    required this.hasLocalActiveSession,
    required this.onRefresh,
    required this.onToggleAutomation,
    required this.onStartBooking,
    this.scheduleError,
    this.automationError,
    this.startingBookingId,
    super.key,
  });

  final WellDaySchedule? schedule;
  final BookingAutomationState? automation;
  final bool isLoadingSchedule;
  final bool isLoadingAutomation;
  final bool isUpdatingAutomation;
  final bool canManageAutomation;
  final bool hasLocalActiveSession;
  final String? scheduleError;
  final String? automationError;
  final String? startingBookingId;
  final VoidCallback onRefresh;
  final ValueChanged<bool> onToggleAutomation;
  final Future<void> Function(BookingDayItem booking) onStartBooking;

  @override
  Widget build(BuildContext context) {
    final data = schedule;
    final automationState = automation;
    final hasAnyOpenSession =
        hasLocalActiveSession || data?.currentSession != null;

    return Container(
      key: const Key('today-bookings-panel'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'حجوزات اليوم',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.deepBlue,
                  ),
                ),
              ),
              IconButton(
                key: const Key('bookings-refresh'),
                tooltip: 'تحديث حجوزات اليوم',
                onPressed: isLoadingSchedule ? null : onRefresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _AutomationTile(
            state: automationState,
            isLoading: isLoadingAutomation,
            isUpdating: isUpdatingAutomation,
            canManage: canManageAutomation,
            error: automationError,
            onChanged: onToggleAutomation,
          ),
          const Divider(height: 24),
          if (isLoadingSchedule && data == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: CircularProgressIndicator(),
              ),
            )
          else if (scheduleError != null && data == null)
            _ErrorState(
              message: scheduleError!,
              onRetry: onRefresh,
            )
          else if (data != null) ...[
            _ScheduleHeader(schedule: data),
            if (scheduleError != null) ...[
              const SizedBox(height: 8),
              Text(
                scheduleError!,
                style: const TextStyle(
                  color: AppColors.error,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (data.bookings.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Text(
                  'لا توجد حجوزات في جدول اليوم.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              )
            else
              ...data.bookings.map(
                (booking) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _BookingCard(
                    booking: booking,
                    isCurrent:
                        data.currentSession?.bookingId == booking.id ||
                        booking.session?.status == 'open',
                    isNext:
                        automationState?.activeChainNextBookingId == booking.id,
                    canStart:
                        !hasAnyOpenSession && booking.canStartManually,
                    isStarting: startingBookingId == booking.id,
                    onStart: () => onStartBooking(booking),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _AutomationTile extends StatelessWidget {
  const _AutomationTile({
    required this.state,
    required this.isLoading,
    required this.isUpdating,
    required this.canManage,
    required this.error,
    required this.onChanged,
  });

  final BookingAutomationState? state;
  final bool isLoading;
  final bool isUpdating;
  final bool canManage;
  final String? error;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    if (isLoading && state == null) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('الانتقال التلقائي'),
        trailing: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final value = state?.enabled ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile.adaptive(
          key: const Key('booking-automation-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'الانتقال التلقائي',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            canManage
                ? 'أول حجز يبدأ يدويًا. هذا المفتاح يحفظ إعداد البئر، ولا يعني تفعيل التشغيل الإنتاجي الدائم.'
                : 'يمكنك مشاهدة الإعداد. تغييره متاح للمشغّل المخوّل على هاتف التشغيل فقط.',
          ),
          value: value,
          onChanged:
              state == null || isUpdating || !canManage ? null : onChanged,
          secondary: isUpdating
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  value ? Icons.autorenew : Icons.pause_circle_outline,
                  color: value
                      ? AppColors.agriculturalGreen
                      : AppColors.textSecondary,
                ),
        ),
        if (error != null)
          Text(
            error!,
            key: const Key('booking-automation-error'),
            style: const TextStyle(color: AppColors.error, fontSize: 12),
          ),
      ],
    );
  }
}

class _ScheduleHeader extends StatelessWidget {
  const _ScheduleHeader({required this.schedule});

  final WellDaySchedule schedule;

  @override
  Widget build(BuildContext context) {
    final current = schedule.currentSession;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'اليوم: ${_formatDate(schedule.requestedDay)}',
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        if (current != null) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.agriculturalGreen.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppColors.agriculturalGreen.withValues(alpha: 0.25),
              ),
            ),
            child: Text(
              current.bookingPublicCode == null
                  ? 'توجد جلسة سقي جارية بدأت ${_formatAdenTime(current.startedAt)}.'
                  : 'الجلسة الجارية من الحجز ${current.bookingPublicCode} — بدأت ${_formatAdenTime(current.startedAt)}.',
              style: const TextStyle(
                color: AppColors.agriculturalGreen,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _BookingCard extends StatelessWidget {
  const _BookingCard({
    required this.booking,
    required this.isCurrent,
    required this.isNext,
    required this.canStart,
    required this.isStarting,
    required this.onStart,
  });

  final BookingDayItem booking;
  final bool isCurrent;
  final bool isNext;
  final bool canStart;
  final bool isStarting;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final borderColor = isCurrent
        ? AppColors.agriculturalGreen
        : isNext
        ? AppColors.deepBlue
        : AppColors.border;

    return Container(
      key: Key('booking-card-${booking.id}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isCurrent
            ? AppColors.agriculturalGreen.withValues(alpha: 0.04)
            : isNext
            ? AppColors.deepBlue.withValues(alpha: 0.035)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Text(
                booking.farmerName?.trim().isNotEmpty == true
                    ? booking.farmerName!
                    : 'اسم المزارع غير متاح',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              Wrap(
                spacing: 6,
                children: [
                  if (isCurrent)
                    const _Tag(
                      text: 'الجاري',
                      color: AppColors.agriculturalGreen,
                    ),
                  if (isNext)
                    const _Tag(text: 'التالي', color: AppColors.deepBlue),
                  _Tag(
                    text: _statusLabel(booking.status),
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            booking.farmName?.trim().isNotEmpty == true
                ? 'الأرض: ${booking.farmName}'
                : 'الأرض: غير متاحة',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            '${_formatAdenTime(booking.scheduledStart)} – ${_formatAdenTime(booking.scheduledEnd)}'
            '  •  ${booking.expectedDurationMinutes} دقيقة',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: AppColors.deepBlue,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'مصدر الطاقة: ${energySourceLabel(booking.expectedEnergySource)}',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          if (canStart) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              key: Key('start-booking-${booking.id}'),
              onPressed: isStarting ? null : onStart,
              icon: isStarting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.play_arrow),
              label: const Text('بدء هذا الحجز يدويًا'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.error),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('إعادة المحاولة'),
        ),
      ],
    );
  }
}

DateTime _asAden(DateTime value) =>
    value.toUtc().add(const Duration(hours: 3));

String _formatAdenTime(DateTime value) {
  final local = _asAden(value);
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

String _formatDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _statusLabel(String status) => switch (status) {
  'confirmed' => 'مؤكد',
  'pending' => 'قيد التأكيد',
  'waiting' => 'بانتظار الموعد',
  'ready' => 'جاهز',
  'started' => 'بدأ',
  'completed' => 'مكتمل',
  'postponed' => 'مؤجل',
  'cancelled' => 'ملغى',
  'no_show' => 'لم يحضر',
  'draft' => 'مسودة',
  _ => status,
};

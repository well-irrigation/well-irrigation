import 'package:flutter/material.dart';

import '../../core/api/booking_repository.dart';
import '../../core/booking/booking_reactivity.dart';
import '../../core/booking/booking_presentation.dart';
import '../../core/api/operations_repository.dart' show energySourceLabel;
import '../../core/identity/app_identity.dart';
import '../../core/theme/app_colors.dart';
import 'booking_form_screen.dart' show BookingScheduleEditor;
import 'bookings_screen.dart';

/// تفاصيل حجز غير جارٍ (OB-5 / البند 393). يجلب get_booking_detail عند
/// الفتح فقط (لا N+1 من القائمة). التسلسل البصري هادئ ومقروء، وإعادة
/// الجدولة تعيد استخدام محرّر الموعد نفسه لا حوارًا خامًّا. الإلغاء إجراء
/// ثانوي هدّام بتأكيد. الكتابات online فقط في حزمة B.
class BookingDetailScreen extends StatefulWidget {
  const BookingDetailScreen({
    required this.bookingId,
    required this.identity,
    this.bookingRepository,
    this.online = true,
    super.key,
  });

  final String bookingId;
  final AppIdentity identity;
  final BookingRepository? bookingRepository;
  final bool online;

  @override
  State<BookingDetailScreen> createState() => _BookingDetailScreenState();
}

class _BookingDetailScreenState extends State<BookingDetailScreen> {
  late final BookingRepository _repo;
  bool _loading = true;
  Object? _error;
  WellBookingDetail? _detail;
  bool _busy = false;
  late final BookingScope _scope;
  WellDaySchedule? _schedule;
  void _changed() {
    if (!mounted) return;
    if (_scope.refreshRequired) {
      _load();
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _scope.removeListener(_changed);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _repo = widget.bookingRepository ?? BookingRepository();
    _scope = BookingReactivity.instance.scope(
      widget.identity.accountId,
      widget.identity.activeWell.id,
    );
    _scope.addListener(_changed);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await _repo.getBookingDetail(widget.bookingId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
      try {
        final view = await _scope.read(
          'schedule',
          () => _repo.fetchScheduleView(
            accountId: widget.identity.accountId,
            wellId: widget.identity.activeWell.id,
          ),
        );
        if (mounted) setState(() => _schedule = view.schedule);
      } catch (_) {
        /* التفاصيل المقروءة تبقى متاحة. */
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  bool _guardOffline() {
    if (widget.online) return false;
    _notify('هذه العملية تحتاج اتصالًا بالخادم حاليًا.');
    return true;
  }

  Future<void> _runMutation(
    Future<BookingMutationResult> Function() action, {
    Set<String>? days,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await action();
      if (result.isConflict) {
        _notify(
          result.message ?? 'هذا الوقت محجوز بالفعل. اختر وقتًا مختلفًا.',
        );
      } else if (result.isOk) {
        _notify('تم تنفيذ العملية على الخادم.');
        _scope.mutation(days: days);
      } else {
        _notify(result.message ?? 'لم تكتمل العملية. أعد المحاولة.');
      }
    } catch (_) {
      _notify('تعذّر إتمام العملية. تحقّق من الاتصال وأعد المحاولة.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openReschedule() async {
    final booking = _detail?.booking;
    if (booking == null) return;
    if (_guardOffline()) return;
    final result = await showModalBottomSheet<_RescheduleResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _RescheduleSheet(
        originalStart: booking.scheduledStart,
        originalEnd: booking.scheduledEnd,
      ),
    );
    if (result == null) return;
    final commandId = _repo.newCommandId();
    await _runMutation(
      () => _repo.rescheduleBooking(
        bookingId: booking.id,
        scheduledStart: result.start,
        scheduledEnd: result.end,
        reason: 'إعادة جدولة من قسم الحجوزات',
        commandId: commandId,
      ),
      days: {
        BookingScope.dayKey(
          booking.scheduledStart.toUtc().add(const Duration(hours: 3)),
        ),
        BookingScope.dayKey(result.start),
        BookingScope.dayKey(result.start.toUtc().add(const Duration(hours: 3))),
      },
    );
  }

  Future<void> _confirmCancel() async {
    final booking = _detail?.booking;
    if (booking == null) return;
    if (_guardOffline()) return;
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _CancelDialog(),
    );
    if (reason == null) return;
    final commandId = _repo.newCommandId();
    await _runMutation(
      () => _repo.cancelBooking(
        bookingId: booking.id,
        reason: reason.trim().isEmpty ? 'إلغاء من قسم الحجوزات' : reason.trim(),
        commandId: commandId,
      ),
      days: {
        BookingScope.dayKey(
          booking.scheduledStart.toUtc().add(const Duration(hours: 3)),
        ),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        title: const Text(
          'تفاصيل الحجز',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: AppColors.deepBlue,
          ),
        ),
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null || _detail == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off_rounded,
                size: 40,
                color: AppColors.warning,
              ),
              const SizedBox(height: 12),
              const Text(
                'تعذّر تحميل تفاصيل الحجز.',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepBlue,
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      );
    }
    final b = _detail!.booking;
    final canonical = _schedule?.bookings
        .where((item) => item.id == b.id)
        .firstOrNull;
    final presentation = presentBooking(
      id: b.id,
      status: b.status,
      session: canonical?.session,
      scope: _scope,
    );
    final style = BookingStatusStyle(
      presentation.color,
      presentation.icon,
      presentation.label,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        _StatusHero(style: style, publicCode: b.publicCode),
        if (presentation.syncLabel != null) Text(presentation.syncLabel!),
        if (presentation.endedAt != null)
          Text(bookingEndedText(presentation.endedAt!)),
        const SizedBox(height: 14),
        _DetailSection(
          title: 'المزارع والأرض',
          icon: Icons.person_pin_circle_rounded,
          rows: [
            _DetailRow(
              icon: Icons.person_rounded,
              label: 'المزارع',
              value: b.farmerName.isEmpty ? 'غير محدد' : b.farmerName,
            ),
            if (b.farmName.isNotEmpty)
              _DetailRow(
                icon: Icons.terrain_rounded,
                label: 'الأرض',
                value: b.farmName,
              ),
          ],
        ),
        const SizedBox(height: 14),
        _DetailSection(
          title: 'الموعد',
          icon: Icons.event_rounded,
          rows: [
            _DetailRow(
              icon: Icons.calendar_month_rounded,
              label: 'اليوم',
              value: bookingFullArabicDate(b.scheduledStart.toLocal()),
            ),
            _DetailRow(
              icon: Icons.schedule_rounded,
              label: 'الوقت',
              value: bookingClockRange(b.scheduledStart, b.scheduledEnd),
            ),
            if (b.expectedDurationMinutes != null)
              _DetailRow(
                icon: Icons.timelapse_rounded,
                label: 'المدة',
                value: formatBookingDuration(b.expectedDurationMinutes!),
              ),
          ],
        ),
        if ((b.expectedEnergySource ?? '').isNotEmpty ||
            (b.notes ?? '').trim().isNotEmpty ||
            b.priority > 0) ...[
          const SizedBox(height: 14),
          _DetailSection(
            title: 'تفاصيل إضافية',
            icon: Icons.info_outline_rounded,
            rows: [
              if ((b.expectedEnergySource ?? '').isNotEmpty)
                _DetailRow(
                  icon: Icons.bolt_rounded,
                  label: 'مصدر الطاقة',
                  value: energySourceLabel(b.expectedEnergySource!),
                ),
              if ((b.alternativeEnergySource ?? '').isNotEmpty)
                _DetailRow(
                  icon: Icons.bolt_outlined,
                  label: 'المصدر البديل',
                  value: energySourceLabel(b.alternativeEnergySource!),
                ),
              if (b.priority > 0)
                _DetailRow(
                  icon: Icons.priority_high_rounded,
                  label: 'الأولوية',
                  value: 'مرتفعة',
                ),
              if ((b.notes ?? '').trim().isNotEmpty)
                _DetailRow(
                  icon: Icons.sticky_note_2_outlined,
                  label: 'ملاحظات',
                  value: b.notes!.trim(),
                ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        SizedBox(
          height: 50,
          child: FilledButton.icon(
            onPressed: _busy ? null : _openReschedule,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.waterBlue,
              textStyle: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
            icon: const Icon(Icons.event_repeat_rounded),
            label: const Text('إعادة الجدولة'),
          ),
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: _busy ? null : _confirmCancel,
          style: TextButton.styleFrom(foregroundColor: AppColors.error),
          icon: const Icon(Icons.cancel_outlined, size: 18),
          label: const Text('إلغاء الحجز'),
        ),
      ],
    );
  }
}

/// شارة الحالة البارزة أعلى الصفحة: لون + أيقونة + نص (لغة الحالات).
class _StatusHero extends StatelessWidget {
  const _StatusHero({required this.style, required this.publicCode});
  final BookingStatusStyle style;
  final String publicCode;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: style.color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: style.color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(style.icon, size: 26, color: style.color),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                style.label,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: style.color,
                ),
              ),
              if (publicCode.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  'رمز الحجز: $publicCode',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.title,
    required this.icon,
    required this.rows,
  });

  final String title;
  final IconData icon;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: AppColors.waterBlue),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepBlue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...rows,
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: AppColors.textMuted),
          const SizedBox(width: 10),
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RescheduleResult {
  const _RescheduleResult(this.start, this.end);
  final DateTime start;
  final DateTime end;
}

/// ورقة إعادة الجدولة: تعرض الموعد الأصلي ثم تعيد استخدام محرّر الموعد
/// نفسه (لا حوار خام يكشف start/end فقط). يفهم المستخدم القديم والجديد.
class _RescheduleSheet extends StatefulWidget {
  const _RescheduleSheet({
    required this.originalStart,
    required this.originalEnd,
  });

  final DateTime originalStart;
  final DateTime originalEnd;

  @override
  State<_RescheduleSheet> createState() => _RescheduleSheetState();
}

class _RescheduleSheetState extends State<_RescheduleSheet> {
  late DateTime _start;
  late int _duration;
  bool _valid = true;

  @override
  void initState() {
    super.initState();
    _start = widget.originalStart.toLocal();
    _duration = bookingDurationMinutes(
      widget.originalStart,
      widget.originalEnd,
    );
    if (_duration <= 0) _duration = 60;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Text(
                  'إعادة جدولة الحجز',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.deepBlue,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.history_rounded,
                        size: 18,
                        color: AppColors.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'الموعد الحالي: '
                          '${bookingShortArabicDate(widget.originalStart)} · '
                          '${bookingClockRange(widget.originalStart, widget.originalEnd)}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                const Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    'الموعد الجديد',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.bold,
                      color: AppColors.waterBlue,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                BookingScheduleEditor(
                  initialStart: _start,
                  initialDurationMinutes: _duration,
                  onChanged: (start, duration, valid) {
                    setState(() {
                      _start = start;
                      _duration = duration;
                      _valid = valid;
                    });
                  },
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: _valid
                        ? () => Navigator.of(context).pop(
                            _RescheduleResult(
                              _start,
                              bookingEndFromDuration(_start, _duration),
                            ),
                          )
                        : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.waterBlue,
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('حفظ الموعد الجديد'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// حوار تأكيد الإلغاء — إجراء هدّام صريح بسبب اختياري (البند 393).
class _CancelDialog extends StatefulWidget {
  const _CancelDialog();

  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إلغاء الحجز'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'سيُلغى هذا الحجز. لا يُحذف الحجز التاريخي، بل يُسجَّل كملغى.',
            style: TextStyle(fontSize: 13.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _reason,
            maxLines: 2,
            minLines: 1,
            decoration: const InputDecoration(
              labelText: 'السبب (اختياري)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('تراجع'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_reason.text),
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          child: const Text('تأكيد الإلغاء'),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../../core/api/app_bootstrap_repository.dart';
import '../../core/api/booking_repository.dart';
import '../../core/api/operations_repository.dart';
import '../../core/identity/app_identity.dart';
import '../../core/booking/booking_reactivity.dart';
import '../../core/booking/booking_presentation.dart';
import '../../core/session/offline_session_coordinator.dart';
import '../../core/theme/app_colors.dart';
import 'booking_detail_screen.dart';
import 'booking_form_screen.dart';

/// قسم الحجوزات المستقل (OB-5 / البند 387).
///
/// الفئات الموثّقة الثلاث محفوظة كتبويبات: اليوم / القادمة / السابقة.
/// تبويب «اليوم» وحده يحمل متصفّح يوم مفرد (السابق · اليوم · التالي) حتى
/// لا تلتبس أسهم تنقّل التاريخ بأسماء الفئات. القراءات محدودة بالنطاق
/// (listWellBookings مع from/to/limit) فلا مسح شامل ولا N+1؛ ووسم
/// «يعمل الآن» من currentSession.bookingId الكنوني لا من تداخل الوقت.
class BookingsScreen extends StatefulWidget {
  const BookingsScreen({
    required this.identity,
    this.bookingRepository,
    this.operationsRepository,
    this.onOpenOperations,
    this.onlineOverride,
    super.key,
  });

  final AppIdentity identity;
  final BookingRepository? bookingRepository;
  final OperationsRepository? operationsRepository;

  /// يفتح شاشة العمليات/الجلسة الحيّة عند النقر على الحجز الجاري.
  final VoidCallback? onOpenOperations;

  /// للاختبار فقط: تجاوز اكتشاف الاتصال (الكتابة online فقط في حزمة B).
  final bool? onlineOverride;

  @override
  State<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends State<BookingsScreen> {
  late final BookingRepository _repo;
  late WellSummary _well;
  String? _runningBookingId;
  WellDaySchedule? _schedule;
  BookingAutomationState? _automation;
  late BookingScope _scope;
  String? _localProjectionError;
  int _scheduleGeneration = 0;
  void _changed() {
    if (!mounted ||
        (!_scope.refreshRequired && !_scope.affects(_displayedDay))) {
      return;
    }
    if (_scope.refreshRequired && _scope.affects(_canonicalToday)) {
      _loadRunning();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _scope.removeListener(_changed);
    super.dispose();
  }

  /// اليوم المرجعي الكنوني (يوم البئر): من requestedADay عند توفّر قراءة
  /// الجدول، وإلا ساعة الجهاز. لا يُستنتج يوم من ساعة الجهاز وحدها متى
  /// توفّر المرجع الخادمي.
  late DateTime _canonicalToday;

  /// اليوم المعروض — الصفحة اليومية هي نموذج التصفّح الوحيد الآن؛ تنقّل
  /// التاريخ (السابق · اليوم · التالي) يحكمها، بلا تبويبات فئات أعلاها.
  late DateTime _displayedDay;
  bool _userMovedDay = false;

  @override
  void initState() {
    super.initState();
    _repo = widget.bookingRepository ?? BookingRepository();
    _well = widget.identity.activeWell;
    final now = DateTime.now();
    _canonicalToday = DateTime(now.year, now.month, now.day);
    _displayedDay = _canonicalToday;
    _scope = BookingReactivity.instance.scope(
      widget.identity.accountId,
      _well.id,
    );
    _scope.addListener(_changed);
    _loadRunning();
    if (widget.bookingRepository == null) {
      _restoreLocalFacts();
    }
  }

  @override
  void didUpdateWidget(covariant BookingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity.accountId == widget.identity.accountId &&
        oldWidget.identity.activeWell.id == widget.identity.activeWell.id) {
      return;
    }
    _scope.removeListener(_changed);
    _well = widget.identity.activeWell;
    _scope = BookingReactivity.instance.scope(
      widget.identity.accountId,
      _well.id,
    );
    _scope.addListener(_changed);
    _schedule = null;
    _automation = null;
    _runningBookingId = null;
    _localProjectionError = null;
    _loadRunning();
    if (widget.bookingRepository == null) _restoreLocalFacts();
  }

  Future<void> _restoreLocalFacts() async {
    try {
      await OfflineSessionCoordinator.instance.freshProjectActiveSession(
        accountId: widget.identity.accountId,
        wellId: _well.id,
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _localProjectionError =
              'تعذر قراءة حالة التشغيل المحفوظة على الجهاز.',
        );
      }
    }
  }

  /// مصدر «يعمل الآن» الكنوني الوحيد: جلسة الجدول الجارية ومعرّف حجزها.
  /// نلتقط من الاستجابة ذاتها اليومَ الكنوني (requestedDay) لنثبّت «اليوم»
  /// على يوم البئر لا على ساعة الجهاز. فشل القراءة (offline) يُبقي الحالي.
  Future<void> _loadRunning() async {
    final generation = ++_scheduleGeneration;
    final scope = _scope;
    final accountId = widget.identity.accountId;
    final wellId = _well.id;
    try {
      final view = await scope.read(
        'schedule',
        () => _repo.fetchScheduleView(accountId: accountId, wellId: wellId),
      );
      if (!mounted ||
          generation != _scheduleGeneration ||
          !identical(scope, _scope)) {
        return;
      }
      final canonicalDay = view.schedule.requestedDay;
      setState(() {
        _schedule = view.schedule;
        _runningBookingId = view.schedule.currentSession?.bookingId;
        _canonicalToday = DateTime(
          canonicalDay.year,
          canonicalDay.month,
          canonicalDay.day,
        );
        if (!_userMovedDay) _displayedDay = _canonicalToday;
      });
      try {
        final (automation, _) = await scope.read(
          'automation',
          () => _repo.fetchAutomationView(
            accountId: widget.identity.accountId,
            wellId: _well.id,
          ),
        );
        if (mounted &&
            generation == _scheduleGeneration &&
            identical(scope, _scope)) {
          setState(() => _automation = automation);
        }
      } catch (_) {
        /* تبقى قراءة الجدول متاحة دون إعداد أتمتة. */
      }
    } catch (_) {
      /* لا جلسة جارية معروفة ولا مرجع يوم خادمي؛ نُبقي الحالي. */
    }
  }

  bool get _online => widget.onlineOverride ?? true;

  bool get _displayedIsToday => _isSameDay(_displayedDay, _canonicalToday);

  void _shiftDay(int deltaDays) {
    setState(() {
      _displayedDay = _displayedDay.add(Duration(days: deltaDays));
      _userMovedDay = !_isSameDay(_displayedDay, _canonicalToday);
    });
  }

  void _goToday() {
    setState(() {
      _displayedDay = _canonicalToday;
      _userMovedDay = false;
    });
  }

  Future<void> _openAdd(DateTime initialDate) async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BookingFormScreen(
          identity: widget.identity,
          bookingRepository: _repo,
          operationsRepository: widget.operationsRepository,
          initialDate: initialDate,
          online: _online,
        ),
      ),
    );
    if (mounted && created == true) setState(() {});
  }

  void _openBooking(WellBookingListItem booking) {
    if (presentBooking(
      id: booking.id,
      status: booking.status,
      scope: _scope,
      session: _schedule?.bookings
          .where((b) => b.id == booking.id)
          .firstOrNull
          ?.session,
      currentBookingId: _runningBookingId,
    ).isCurrent) {
      widget.onOpenOperations?.call();
      return;
    }
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => BookingDetailScreen(
              bookingId: booking.id,
              identity: widget.identity,
              bookingRepository: _repo,
              online: _online,
            ),
          ),
        )
        .then((_) {
          if (mounted) setState(() {});
        });
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
          'الحجوزات',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: AppColors.deepBlue,
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openAdd(_displayedDay),
        backgroundColor: AppColors.waterBlue,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text(
          'إضافة حجز',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _DayNavBar(
              isToday: _displayedIsToday,
              onPrev: () => _shiftDay(-1),
              onNext: () => _shiftDay(1),
              onToday: _goToday,
            ),
            _DateHeadline(day: _displayedDay, isToday: _displayedIsToday),
            if (_localProjectionError != null) Text(_localProjectionError!),
            const Divider(height: 1),
            Expanded(
              child: _DayBookingList(
                key: ValueKey(
                  '${widget.identity.accountId}-${_well.id}-day-${_displayedDay.toIso8601String()}',
                ),
                accountId: widget.identity.accountId,
                scope: _scope,
                schedule: _schedule,
                nextBookingId: armedNextBookingId(_automation),
                repo: _repo,
                wellId: _well.id,
                day: _displayedDay,
                runningBookingId: _runningBookingId,
                onOpen: _openBooking,
                onAdd: () => _openAdd(_displayedDay),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _two(int n) => n.toString().padLeft(2, '0');

/// نصّ الحالة العربي الكنوني. يبقى مُصدَّرًا لإعادة الاستخدام في التفاصيل.
String bookingStatusText(String status) =>
    presentBooking(id: '', status: status).label;

/// الموعد كاملًا بالتاريخ (يُستخدم في التفاصيل حيث لا رأس يوم).
String bookingTimeText(DateTime start, DateTime end) {
  final s = start.toLocal();
  final e = end.toLocal();
  final day = '${s.year}/${_two(s.month)}/${_two(s.day)}';
  return '$day · ${_two(s.hour)}:${_two(s.minute)} — ${_two(e.hour)}:${_two(e.minute)}';
}

/// نطاق الساعة فقط «08:00 — 10:30» — بلا تكرار التاريخ على كل بطاقة.
String bookingClockRange(DateTime start, DateTime end) {
  final s = start.toLocal();
  final e = end.toLocal();
  return '${_two(s.hour)}:${_two(s.minute)} — ${_two(e.hour)}:${_two(e.minute)}';
}

/// أسماء الأيام العربية. ‏DateTime.weekday‎ من 1 (الإثنين) إلى 7 (الأحد).
String bookingWeekdayName(DateTime d) => const [
  '',
  'الإثنين',
  'الثلاثاء',
  'الأربعاء',
  'الخميس',
  'الجمعة',
  'السبت',
  'الأحد',
][d.weekday];

/// أسماء الأشهر الميلادية بالعربية الشائعة.
String bookingMonthName(int month) => const [
  '',
  'يناير',
  'فبراير',
  'مارس',
  'أبريل',
  'مايو',
  'يونيو',
  'يوليو',
  'أغسطس',
  'سبتمبر',
  'أكتوبر',
  'نوفمبر',
  'ديسمبر',
][month];

/// التاريخ الكامل الأنيق: «السبت • 10 أكتوبر 2026» (أرقام إنجليزية ثابتة).
String bookingFullArabicDate(DateTime d) =>
    '${bookingWeekdayName(d)} • ${d.day} ${bookingMonthName(d.month)} ${d.year}';

/// تاريخ مختصر للبطاقات في القوائم متعددة الأيام: «السبت 10 أكتوبر».
String bookingShortArabicDate(DateTime d) {
  final l = d.toLocal();
  return '${bookingWeekdayName(l)} ${l.day} ${bookingMonthName(l.month)}';
}

/// الطابع البصري للحالة: لون + أيقونة + نص (لغة الحالات — الهوية §14).
class BookingStatusStyle {
  const BookingStatusStyle(this.color, this.icon, this.label);
  final Color color;
  final IconData icon;
  final String label;
}

BookingStatusStyle resolveBookingStatusStyle(
  String status, {
  bool running = false,
}) {
  final p = presentBooking(
    id: 'booking',
    status: status,
    currentBookingId: running ? 'booking' : null,
  );
  return BookingStatusStyle(p.color, p.icon, p.label);
}

/// شريط تنقّل التاريخ. في RTL: «السابق» يمينًا، «اليوم» وسطًا، «التالي»
/// يسارًا — بأسهم اتجاهية صحيحة اتجاهيًّا (رجوع نحو اليمين، تقدّم نحو اليسار).
class _DayNavBar extends StatelessWidget {
  const _DayNavBar({
    required this.isToday,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
  });

  final bool isToday;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _ArrowButton(
            icon: Icons.chevron_right_rounded,
            label: 'السابق',
            onTap: onPrev,
          ),
          _TodayPill(isToday: isToday, onTap: onToday),
          _ArrowButton(
            icon: Icons.chevron_left_rounded,
            label: 'التالي',
            trailingIcon: true,
            onTap: onNext,
          ),
        ],
      ),
    );
  }
}

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailingIcon = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool trailingIcon;

  @override
  Widget build(BuildContext context) {
    final iconWidget = Icon(icon, size: 22, color: AppColors.waterBlue);
    final textWidget = Text(
      label,
      style: const TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: AppColors.deepBlue,
      ),
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: trailingIcon
              ? [textWidget, const SizedBox(width: 2), iconWidget]
              : [iconWidget, const SizedBox(width: 2), textWidget],
        ),
      ),
    );
  }
}

class _TodayPill extends StatelessWidget {
  const _TodayPill({required this.isToday, required this.onTap});

  final bool isToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // على اليوم: حالة ساكنة محدّدة. خارج اليوم: دعوة بارزة للعودة.
    final bg = isToday ? Colors.transparent : AppColors.waterBlue;
    final fg = isToday ? AppColors.textSecondary : Colors.white;
    return InkWell(
      onTap: isToday ? null : onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isToday ? AppColors.border : AppColors.waterBlue,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.today_rounded, size: 17, color: fg),
            const SizedBox(width: 6),
            Text(
              'اليوم',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.bold,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateHeadline extends StatelessWidget {
  const _DateHeadline({required this.day, required this.isToday});

  final DateTime day;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.calendar_month_rounded,
            size: 18,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              bookingFullArabicDate(day),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.bold,
                color: AppColors.deepBlue,
              ),
            ),
          ),
          if (isToday) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.agriculturalGreen.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'اليوم',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: AppColors.agriculturalGreen,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// تبويب اليوم: يحوّل اليوم المعروض إلى نطاق [00:00, اليوم التالي) ويعرضه.
class _DayBookingList extends StatelessWidget {
  const _DayBookingList({
    required this.accountId,
    required this.scope,
    required this.schedule,
    required this.nextBookingId,
    required this.repo,
    required this.wellId,
    required this.day,
    required this.runningBookingId,
    required this.onOpen,
    required this.onAdd,
    super.key,
  });

  final String accountId;
  final BookingScope scope;
  final WellDaySchedule? schedule;
  final String? nextBookingId;
  final BookingRepository repo;
  final String wellId;
  final DateTime day;
  final String? runningBookingId;
  final void Function(WellBookingListItem) onOpen;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final start = DateTime(day.year, day.month, day.day);
    return _BookingList(
      accountId: accountId,
      scope: scope,
      schedule: schedule,
      nextBookingId: nextBookingId,
      repo: repo,
      wellId: wellId,
      from: start,
      to: start.add(const Duration(days: 1)),
      newestFirst: false,
      showDate: false,
      runningBookingId: runningBookingId,
      onOpen: onOpen,
      onAdd: onAdd,
      emptyTitle: 'لا توجد حجوزات في هذا اليوم',
      emptyHint: 'يمكنك إضافة حجز جديد لهذا اليوم.',
    );
  }
}

/// القائمة المحدودة بالنطاق: تحميل/خطأ/فراغ/محتوى. تجلب القائمة فقط
/// (listWellBookings) فلا تفاصيل لكل بطاقة ولا N+1.
class _BookingList extends StatefulWidget {
  const _BookingList({
    required this.accountId,
    required this.scope,
    required this.schedule,
    required this.nextBookingId,
    required this.repo,
    required this.wellId,
    required this.from,
    required this.to,
    required this.newestFirst,
    required this.showDate,
    required this.runningBookingId,
    required this.onOpen,
    required this.onAdd,
    required this.emptyTitle,
    required this.emptyHint,
  });

  final String accountId;
  final BookingScope scope;
  final WellDaySchedule? schedule;
  final String? nextBookingId;
  final BookingRepository repo;
  final String wellId;
  final DateTime from;
  final DateTime to;
  final bool newestFirst;
  final bool showDate;
  final String? runningBookingId;
  final void Function(WellBookingListItem) onOpen;
  final VoidCallback? onAdd;
  final String emptyTitle;
  final String emptyHint;

  @override
  State<_BookingList> createState() => _BookingListState();
}

class _BookingListState extends State<_BookingList> {
  bool _loading = true;
  Object? _error;
  List<WellBookingListItem> _items = const [];
  int _generation = 0;
  WellDaySchedule? _dayFacts;
  void _applyDayFacts(WellDaySchedule schedule) {
    if (!mounted) return;
    setState(() {
      _dayFacts = schedule;
      if (_error != null) {
        _items = schedule.bookings
            .map(
              (b) => WellBookingListItem(
                id: b.id,
                publicCode: b.publicCode,
                farmerWellAccountId: b.farmerWellAccountId,
                farmerName: b.farmerName ?? '',
                farmId: b.farmId ?? '',
                farmName: b.farmName ?? '',
                scheduledStart: b.scheduledStart,
                scheduledEnd: b.scheduledEnd,
                scheduledDay: b.scheduledDay,
                expectedDurationMinutes: b.expectedDurationMinutes,
                status: b.status,
                priority: b.priority,
                expectedEnergySource: b.expectedEnergySource,
                alternativeEnergySource: b.alternativeEnergySource,
                notes: b.notes,
              ),
            )
            .toList();
        _error = null;
      }
    });
  }

  void _changed() {
    if (!mounted || !widget.scope.affects(widget.from)) return;
    if (widget.scope.refreshRequired) {
      _load();
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.scope.removeListener(_changed);
    super.dispose();
  }

  BookingPresentation _present(WellBookingListItem b) {
    final schedule = _dayFacts ?? widget.schedule;
    final current = schedule?.currentSession;
    final closed =
        current != null &&
        (widget.scope.closedSessionIds.contains(current.sessionId) ||
            widget.scope.sessions[current.bookingId]?.completedAt != null);
    return presentBooking(
      id: b.id,
      status: b.status,
      scope: widget.scope,
      session: schedule?.bookings
          .where((item) => item.id == b.id)
          .firstOrNull
          ?.session,
      currentBookingId: closed ? null : widget.runningBookingId,
      nextBookingId: widget.nextBookingId,
    );
  }

  @override
  void initState() {
    super.initState();
    widget.scope.addListener(_changed);
    _load();
  }

  @override
  void didUpdateWidget(covariant _BookingList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.schedule != oldWidget.schedule && widget.schedule != null) {
      _loadDayFacts();
    }
  }

  Future<void> _loadDayFacts() async {
    final today = widget.schedule;
    if (today == null) return;
    if (_isSameDay(today.requestedDay, widget.from)) {
      _applyDayFacts(today);
      return;
    }
    try {
      final view = await widget.scope.read(
        'day-${BookingScope.dayKey(widget.from)}',
        () => widget.repo.fetchDayScheduleView(
          accountId: widget.accountId,
          wellId: widget.wellId,
          day: widget.from,
        ),
      );
      _applyDayFacts(view.schedule);
    } catch (_) {
      /* القائمة المحدودة تبقى متاحة؛ الحقائق المحلية لا تُمحى. */
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.scope.read(
        'list-${BookingScope.dayKey(widget.from)}',
        () => widget.repo.listWellBookings(
          wellId: widget.wellId,
          from: widget.from,
          to: widget.to,
        ),
      );
      await _loadDayFacts();
      final items = [...list.bookings];
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error;
        _loading = false;
      });
      await _loadDayFacts();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ListMessage(
        icon: Icons.cloud_off_rounded,
        iconColor: AppColors.warning,
        title: 'تعذّر تحديث الحجوزات',
        hint: 'تُعرض البيانات المحفوظة المتاحة على هذا الجهاز عند توفّرها.',
        actionLabel: 'إعادة المحاولة',
        actionIcon: Icons.refresh_rounded,
        onAction: _load,
      );
    }
    if (_items.isEmpty) {
      return _ListMessage(
        icon: Icons.event_busy_rounded,
        iconColor: AppColors.textMuted,
        title: widget.emptyTitle,
        hint: widget.emptyHint,
        actionLabel: widget.onAdd == null ? null : 'إضافة حجز',
        actionIcon: Icons.add,
        onAction: widget.onAdd,
      );
    }
    final primary = _items.where((b) => !_present(b).isTerminal).toList();
    final history = _items.where((b) => _present(b).isTerminal).toList();
    primary.sort(
      (a, b) => compareBookingPresentation(
        a: _present(a),
        b: _present(b),
        aStart: a.scheduledStart,
        bStart: b.scheduledStart,
        aPriority: a.priority,
        bPriority: b.priority,
        aCode: a.publicCode,
        bCode: b.publicCode,
      ),
    );
    history.sort(
      (a, b) => compareBookingHistory(
        _present(a),
        _present(b),
        a.scheduledStart,
        b.scheduledStart,
        a.publicCode,
        b.publicCode,
      ),
    );
    Widget card(WellBookingListItem b) => _BookingCard(
      booking: b,
      presentation: _present(b),
      running: _present(b).isCurrent,
      showDate: widget.showDate,
      onTap: () => widget.onOpen(b),
    );
    return RefreshIndicator(
      onRefresh: () async {
        widget.scope.mutation(days: {BookingScope.dayKey(widget.from)});
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          ...primary.map(card),
          if (history.isNotEmpty)
            ExpansionTile(
              key: ValueKey('booking-history-${widget.from}'),
              title: Text('السجل المنتهي لليوم (${history.length})'),
              children: history.map(card).toList(),
            ),
        ],
      ),
    );
  }
}

/// رسالة قائمة موحّدة: فراغ/خطأ بنمط بصري هادئ وإجراء اختياري.
class _ListMessage extends StatelessWidget {
  const _ListMessage({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.hint,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String hint;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 32, color: iconColor),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.deepBlue,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13.5,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onAction,
                icon: Icon(actionIcon ?? Icons.add, size: 18),
                label: Text(actionLabel!),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.waterBlue,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// بطاقة حجز مدمجة غنية بالمعلومات، بتمييز حالة مُنضبط (البند 388).
/// شريط جانبي + شارة حالة (لون + أيقونة + نص) تميّز الجاري عن المنتهي
/// والملغى دون إفراط لوني. الجاري يأخذ أقوى تأكيد.
class _BookingCard extends StatelessWidget {
  const _BookingCard({
    required this.booking,
    required this.presentation,
    required this.running,
    required this.showDate,
    required this.onTap,
  });

  final WellBookingListItem booking;
  final BookingPresentation presentation;
  final bool running;
  final bool showDate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final b = booking;
    final style = BookingStatusStyle(
      presentation.color,
      presentation.icon,
      presentation.label,
    );
    final subdued =
        !running &&
        (b.status == 'cancelled' ||
            b.status == 'canceled' ||
            b.status == 'completed' ||
            b.status == 'postponed');
    final clock = showDate
        ? '${bookingShortArabicDate(b.scheduledStart)} · '
              '${bookingClockRange(b.scheduledStart, b.scheduledEnd)}'
        : bookingClockRange(b.scheduledStart, b.scheduledEnd);
    final duration = b.expectedDurationMinutes != null
        ? formatBookingDuration(b.expectedDurationMinutes!)
        : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: running
              ? AppColors.agriculturalGreen.withValues(alpha: 0.5)
              : AppColors.border.withValues(alpha: 0.5),
          width: running ? 1.4 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // شريط الحالة الجانبي (الحافة البادئة في RTL = اليمين).
                Container(
                  width: 5,
                  decoration: BoxDecoration(
                    color: style.color,
                    borderRadius: const BorderRadiusDirectional.horizontal(
                      start: Radius.circular(16),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                    child: Opacity(
                      opacity: subdued ? 0.72 : 1,
                      child: _content(b, style, clock, duration),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(
    WellBookingListItem b,
    BookingStatusStyle style,
    String clock,
    String? duration,
  ) {
    final notes = (b.notes ?? '').trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                b.farmerName.isEmpty ? 'مزارع غير محدد' : b.farmerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepBlue,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _StatusChip(style: style),
          ],
        ),
        if (presentation.isNext) const Text('مؤكد'),
        if (presentation.syncLabel != null) Text(presentation.syncLabel!),
        if (presentation.endedAt != null)
          Text(bookingEndedText(presentation.endedAt!)),
        if (b.farmName.isNotEmpty) ...[
          const SizedBox(height: 6),
          _IconLine(icon: Icons.terrain_rounded, text: b.farmName),
        ],
        const SizedBox(height: 4),
        _IconLine(
          icon: Icons.schedule_rounded,
          text: duration == null ? clock : '$clock  ·  $duration',
        ),
        if ((b.expectedEnergySource ?? '').isNotEmpty) ...[
          const SizedBox(height: 4),
          _IconLine(
            icon: Icons.bolt_rounded,
            text: energySourceLabel(b.expectedEnergySource!),
          ),
        ],
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 4),
          _IconLine(
            icon: Icons.sticky_note_2_outlined,
            text: notes,
            maxLines: 2,
          ),
        ],
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.style});
  final BookingStatusStyle style;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: 14, color: style.color),
          const SizedBox(width: 4),
          Text(
            style.label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.bold,
              color: style.color,
            ),
          ),
        ],
      ),
    );
  }
}

class _IconLine extends StatelessWidget {
  const _IconLine({required this.icon, required this.text, this.maxLines = 1});
  final IconData icon;
  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 15, color: AppColors.textMuted),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

/// مدة بصيغة عربية مقروءة بأرقام إنجليزية ثابتة: «ساعتان و30 دقيقة».
String formatBookingDuration(int totalMinutes) {
  if (totalMinutes <= 0) return '0 دقيقة';
  final h = totalMinutes ~/ 60;
  final m = totalMinutes % 60;
  String hoursPart() {
    if (h == 1) return 'ساعة';
    if (h == 2) return 'ساعتان';
    if (h >= 3 && h <= 10) return '$h ساعات';
    return '$h ساعة';
  }

  String minutesPart() {
    if (m == 1) return 'دقيقة';
    if (m == 2) return 'دقيقتان';
    if (m >= 3 && m <= 10) return '$m دقائق';
    return '$m دقيقة';
  }

  if (h == 0) return minutesPart();
  if (m == 0) return hoursPart();
  return '${hoursPart()} و${minutesPart()}';
}

/// النهاية مشتقّة من البداية والمدة — مصدر الحقيقة الوحيد هو (البداية، المدة).
DateTime bookingEndFromDuration(DateTime start, int durationMinutes) =>
    start.add(Duration(minutes: durationMinutes));

/// المدة بالدقائق بين لحظتين (قد تكون سالبة إذا سبقت النهايةُ البداية).
int bookingDurationMinutes(DateTime start, DateTime end) =>
    end.difference(start).inMinutes;

/// نافذة الطاقة الشمسية الحاكمة: [06:00, 18:00) بتوقيت Asia/Aden — مرآة
/// `ops.solar_window_for_day` (ق-132). الخادم يبقى السلطة النهائية؛ هذا
/// تحقّق عميل للعرض ومنع فشل متوقّع فقط، لا قاعدة أعمال مستقلة ثانية.
const int kSolarWindowStartHour = 6;
const int kSolarWindowEndHour = 18;
const String kSolarWindowLabel = '06:00–18:00';

enum SolarAssessment { ok, startOutsideWindow, requiresAlternative }

/// تقييم نقيّ تمامًا للموعد الشمسي من قيمه الاسمية وحدها: دقيقة البداية
/// ضمن يوم عدن (0..1439) ومدته بالدقائق. لا DateTime ولا منطقة جهاز ولا
/// ساعة حائط ولا `now` ولا `toUtc`/تحويل محلي ولا DST — فالنتيجة ثابتة
/// مهما كانت منطقة الجهاز. الموعد المختار يُفسَّر دائمًا بتوقيت Asia/Aden.
///
/// الحدود كعقد الخادم: البداية داخل [06:00, 18:00) — 18:00 بالضبط خارجها،
/// والبديل مطلوب متى تجاوزت النهاية 18:00 (ومنها عبور منتصف الليل).
SolarAssessment assessSolarWindow({
  required int startMinuteOfDay,
  required int durationMinutes,
}) {
  const lower = kSolarWindowStartHour * 60;
  const upper = kSolarWindowEndHour * 60;
  if (startMinuteOfDay < lower || startMinuteOfDay >= upper) {
    return SolarAssessment.startOutsideWindow;
  }
  if (startMinuteOfDay + durationMinutes > upper) {
    return SolarAssessment.requiresAlternative;
  }
  return SolarAssessment.ok;
}

/// دقيقة اليوم (0..1439) من القيم الاسمية لموعد مختار؛ `hour`/`minute`
/// لِـ `DateTime` المبنيّ بمكوّنات صريحة ثابتان مهما كانت منطقة الجهاز.
int solarStartMinuteOfDay(DateTime start) => start.hour * 60 + start.minute;

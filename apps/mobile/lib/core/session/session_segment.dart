/// مقاطع الجلسة وحساب الزمن المحتسب والمستحق.
///
/// المقطع هو وحدة القياس: كل فترة متصلة بحالة واحدة (سقي أو توقف)
/// ومصدر طاقة واحد. الخادم يخزّنها في `ops.session_segments`، وهذا
/// الملف يبنيها محليًا من نفس الأحداث ليعرض عدّادًا حيًّا بلا شبكة.
///
/// **الحساب يطابق الخادم مقطعًا مقطعًا لا في المجموع.** القسمة الصحيحة
/// تُقتطع (الثابت 6 و7): مجموع القسمة على المقاطع ≠ قسمة المجموع. مقطعان
/// من 100 ثانية بسعر 3600 يعطيان 99+99=198 على الخادم، لا 199. لو جمعنا
/// الثواني ثم قسمنا لظهر للمستخدم رقم يخالف فاتورته بريال — ووثيقة
/// الجلسة النشطة تعتبر أي اختلاف في هذه السلسلة عيبًا يمنع الإغلاق
/// (القسم 19 من `ACTIVE_SESSION_ARCHITECTURE.md`).
///
/// **الوقود مستثنى عن قصد.** ق-17: تسعير الديزل شامل بالساعة، والوقود
/// تكلفة ورقابة لا دين إضافي على المزارع. Migration 066 تجمع
/// `fuel_charge_minor` في `total_charge_minor` وهو تعارض معروف مسجَّل في
/// م-26 ويُصحَّح في Migration 085+. هذا الملف يتبع ق-17 لا 066 — فحتى
/// تُصحَّح 066 قد يفرق المعروض محليًا عن تسوية الخادم لجلسة ديزل بها
/// وقود مسجَّل.
library;

import 'session_business_state.dart';

/// نوع المقطع. يحدد وحده هل يزيد الزمن المحتسب أم لا.
enum SegmentKind {
  /// سقي فعلي — محتسب.
  running,

  /// توقف — غير محتسب (القسم 5: «لا يزيد عداد السقي أثناء Pause»).
  paused;

  bool get isBillable => this == SegmentKind.running;
}

/// مقطع واحد من الجلسة. مفتوح إذا كان [endedAt] فارغًا.
class SessionSegment {
  const SessionSegment({
    required this.kind,
    required this.startedAt,
    this.endedAt,
    this.energySource,
    this.hourlyRateMinor,
    this.pauseReason,
  });

  final SegmentKind kind;
  final DateTime startedAt;

  /// `null` = المقطع الجاري الآن.
  final DateTime? endedAt;

  /// مصدر الطاقة خلال هذا المقطع. من هنا يأتي «Modern Energy Source»
  /// في التقارير (ق-100) بدل حقل واحد على الجلسة.
  final String? energySource;

  /// السعر الساعي الشامل المطبَّق على هذا المقطع.
  ///
  /// `null` = لا لقطة تسعير موثوقة، فلا يُحسب لهذا المقطع مبلغ ولا
  /// يُخمَّن (القسم 17 والقرار 341).
  final int? hourlyRateMinor;

  final String? pauseReason;

  bool get isOpen => endedAt == null;

  /// مدة المقطع حتى [now] إن كان مفتوحًا، وإلا مدته النهائية.
  ///
  /// لا تكون سالبة أبدًا: وقت حدث أسبق من بداية مقطعه يرفع علم سلامة
  /// زمن في المُسقِط، ولا يُنتج مدة سالبة تُطرح من مستحق المزارع.
  Duration duration(DateTime now) {
    final end = endedAt ?? now;
    final elapsed = end.difference(startedAt);

    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// الثواني المحتسبة — صفر لمقطع التوقف بحكم نوعه.
  int billableSeconds(DateTime now) =>
      kind.isBillable ? duration(now).inSeconds : 0;

  /// مبلغ هذا المقطع، أو `null` إذا كان سعره غير معلوم.
  ///
  /// القسمة الصحيحة مرة واحدة على المقطع — نفس تعبير Migration 066:
  /// `(billable_seconds * rate) / 3600`.
  int? timeChargeMinor(DateTime now) {
    final rate = hourlyRateMinor;

    if (!kind.isBillable) {
      return 0;
    }

    if (rate == null) {
      return null;
    }

    return (billableSeconds(now) * rate) ~/ 3600;
  }

  SessionSegment closedAt(DateTime at) => SessionSegment(
    kind: kind,
    startedAt: startedAt,
    endedAt: at,
    energySource: energySource,
    hourlyRateMinor: hourlyRateMinor,
    pauseReason: pauseReason,
  );

  @override
  String toString() =>
      'SessionSegment(${kind.name} $startedAt→${endedAt ?? "..."} '
      'energy=$energySource)';
}

/// حصيلة الزمن والمال المشتقّة من مقاطع الجلسة.
class SessionTotals {
  const SessionTotals({
    required this.billableSeconds,
    required this.wallClockSeconds,
    required this.totalPausedSeconds,
    required this.currentPauseSeconds,
    required this.accruedMinor,
    required this.pricingPending,
  });

  /// العدّاد الرئيسي: «مدة السقي المحتسبة» (القرار 339).
  final int billableSeconds;

  /// «منذ بدء الجلسة» — تفصيل لا عدّاد رئيسي.
  final int wallClockSeconds;

  /// «إجمالي التوقف».
  final int totalPausedSeconds;

  /// «مدة التوقف الحالية» — صفر إن لم تكن موقوفة الآن (القرار 346).
  final int currentPauseSeconds;

  /// «المستحق حتى الآن»، أو `null` إذا لم يكن قابلًا للحساب.
  final int? accruedMinor;

  /// هل هناك مقطع محتسب واحد على الأقل بلا سعر معلوم؟
  ///
  /// حين تكون `true` يُعرض «التكلفة بانتظار المزامنة» بدل رقم، ولا
  /// يُعرض «0 ريال» (القرار 341).
  final bool pricingPending;
}

/// يجمع المقاطع إلى حصيلة واحدة عند اللحظة [now].
///
/// لا يقرّب ولا يُدوّر: كل مقطع يُقسَّم وحده ثم تُجمع النواتج.
SessionTotals summarize(List<SessionSegment> segments, DateTime now) {
  var billable = 0;
  var paused = 0;
  var currentPause = 0;
  var accrued = 0;
  var pricingPending = false;

  for (final segment in segments) {
    final seconds = segment.duration(now).inSeconds;

    if (segment.kind.isBillable) {
      billable += seconds;

      final charge = segment.timeChargeMinor(now);

      if (charge == null) {
        // مقطع بلا سعر معلوم. لا يُصفَّر ولا يُخمَّن سعره من مقطع
        // آخر: المجموع كله يصير «بانتظار المزامنة».
        pricingPending = true;
      } else {
        accrued += charge;
      }
    } else {
      paused += seconds;

      if (segment.isOpen) {
        currentPause = seconds;
      }
    }
  }

  final start = segments.isEmpty ? now : segments.first.startedAt;
  final lastEnd = segments.isEmpty
      ? now
      : (segments.last.endedAt ?? now);
  final wallClock = lastEnd.difference(start);

  return SessionTotals(
    billableSeconds: billable,
    wallClockSeconds: wallClock.isNegative ? 0 : wallClock.inSeconds,
    totalPausedSeconds: paused,
    currentPauseSeconds: currentPause,
    accruedMinor: pricingPending ? null : accrued,
    pricingPending: pricingPending,
  );
}

/// الحالة التجارية المشتقّة من المقاطع.
///
/// المصدر هو المقاطع لا حقل حالة مخزَّن: حقل الحالة يمكن أن يتناقض مع
/// الأحداث بعد استعادة ناقصة، والمقاطع مبنية من الأحداث نفسها.
SessionBusinessState stateFromSegments(
  List<SessionSegment> segments, {
  required bool completed,
}) {
  if (completed) {
    return SessionBusinessState.completed;
  }

  final open = segments.where((segment) => segment.isOpen);

  if (open.isEmpty) {
    // كل المقاطع مغلقة وما اكتُشف أمر إنهاء: يقع هذا فقط إذا انقطع
    // تسجيل حدث. تُعامل كموقوفة — الأسلم أن لا يزيد عدّاد مالي على
    // مقطع لم يُثبَت أنه مفتوح.
    return SessionBusinessState.paused;
  }

  return open.first.kind.isBillable
      ? SessionBusinessState.running
      : SessionBusinessState.paused;
}

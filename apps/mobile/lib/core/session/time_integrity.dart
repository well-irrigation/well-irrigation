/// سلامة الزمن — القسم 19 من `ANDROID_OFFLINE_BACKGROUND_SYNC.md`.
///
/// المسألة: عدّاد الجلسة يعرض «كم سقى» ومنه يُحسب المستحق. لو أخذنا
/// الزمن من ساعة الهاتف وحدها، فتعديل الساعة — يدويًا أو بمزامنة شبكة
/// أو بإعادة إقلاع — يغيّر مبلغًا ماليًا. وهذا غير مقبول.
///
/// الحل الذي تفرضه الوثيقة: يُحفظ للجلسة **مرساة** فيها أربعة أشياء:
/// وقت خادمي إن وُجد، وقراءة ساعة الجهاز، وعدّاد تصاعدي لا يتأثر
/// بتعديل الساعة، وعلامة إقلاع. وداخل نفس الإقلاع يُحسب المنقضي من
/// العدّاد التصاعدي لا من فروق ساعة الحائط.
///
/// القاعدة الحاكمة: عند الشك **يُرفع علم ولا تُعدَّل التكلفة بصمت**.
/// هذا الملف لا يصحّح مبلغًا ولا يحجب رقمًا؛ يُخرِج زمنًا وأعلامًا،
/// والعرض هو من يقرر ماذا يقول للمستخدم.
///
/// Dart خالص بلا أي تبعية منصة: القراءات تُمرَّر إليه. الرابط الأندرويدي
/// لاحقًا يقرأ `SystemClock.elapsedRealtime()` وعلامة إقلاع من المنصة
/// ويمرّرهما هنا — ولا يتغير شيء في هذا المنطق ولا في اختباره.
library;

/// ما اكتُشف من خلل في خط الزمن.
enum TimeIntegrityFlag {
  /// ساعة الهاتف تغيّرت تغيّرًا كبيرًا داخل نفس الإقلاع.
  ///
  /// العدّاد التصاعدي يقول إن المنقضي كذا، وساعة الحائط تقول شيئًا
  /// آخر. العدّاد هو الأصدق، فيُستخدم — ويُرفع هذا العلم.
  deviceClockChanged,

  /// أُعيد إقلاع الجهاز، فالعدّاد التصاعدي صُفِّر ولا يُقارَن بمرساة
  /// إقلاع سابق. نرجع إلى ساعة الحائط، وهي غير مبرهنة.
  rebootTimelineUnverified,

  /// لم تُلتقط مرساة خادمية بعد — الجلسة كلها بدأت بلا اتصال.
  ///
  /// ليس خطأً: ق-89 يسمح بها صراحة. لكن العرض يجب أن يعرف أن لا وقت
  /// خادمي يستند إليه.
  noServerAnchor,

  /// ترتيب الأحداث مستحيل: حدث تسلسله لاحق ووقته أسبق.
  ///
  /// لا يُصلَح تلقائيًا — إصلاحه يعني اختراع وقت لم يُسجَّل.
  impossibleEventOrdering,
}

/// الفرق الذي يُعتبر بعده اختلاف ساعة الحائط تعديلًا لا انحرافًا.
///
/// انحراف الساعات العادي ثوانٍ. دقيقتان حدٌّ يتجاوز أي انحراف طبيعي
/// خلال جلسة سقي، ولا يُرفع العلم بسبب ضوضاء قياس.
const Duration deviceClockDriftTolerance = Duration(minutes: 2);

/// مرساة زمن الجلسة، تُحفظ مع الجلسة وتبقى بعد موت التطبيق.
class SessionTimeAnchor {
  const SessionTimeAnchor({
    required this.wallClock,
    required this.monotonic,
    required this.bootId,
    this.serverTime,
  });

  /// قراءة ساعة الجهاز لحظة إنشاء المرساة.
  final DateTime wallClock;

  /// قراءة عدّاد تصاعدي لا يتأثر بتعديل الساعة.
  ///
  /// على أندرويد `SystemClock.elapsedRealtime()`: يزيد أثناء النوم
  /// العميق، ويُصفَّر بإعادة الإقلاع وحدها.
  final Duration monotonic;

  /// علامة الإقلاع الحالي. تغيّرها يعني أن [monotonic] لم يعد قابلًا
  /// للمقارنة.
  final String bootId;

  /// وقت الخادم في آخر اتصال، إن وُجد.
  final DateTime? serverTime;

  /// إزاحة ساعة الجهاز عن الخادم لحظة المرساة.
  ///
  /// موجبة = ساعة الجهاز متقدّمة. تُستخدم للعرض والتشخيص فقط، ولا
  /// تُطبَّق على وقت حدث محفوظ: الوقت المحفوظ هو ما وقع فعلًا.
  Duration? get deviceOffsetFromServer {
    final server = serverTime;

    return server == null ? null : wallClock.difference(server);
  }
}

/// قراءة زمن لحظية من الجهاز.
class TimeReading {
  const TimeReading({
    required this.wallClock,
    required this.monotonic,
    required this.bootId,
  });

  final DateTime wallClock;
  final Duration monotonic;
  final String bootId;
}

/// «الآن» بعد التحقق، مع ما اكتُشف من خلل.
class ResolvedNow {
  const ResolvedNow({required this.at, required this.flags});

  /// اللحظة التي يُبنى عليها العدّاد الجاري.
  final DateTime at;

  final Set<TimeIntegrityFlag> flags;

  /// هل خط الزمن مبرهن بلا ملاحظات؟
  ///
  /// [TimeIntegrityFlag.noServerAnchor] وحدها لا تُسقط الثقة: العمل
  /// بلا اتصال حالة معتمدة (ق-89)، والعدّاد التصاعدي داخل نفس الإقلاع
  /// كافٍ لقياس مدة.
  bool get isTrusted => flags
      .where((flag) => flag != TimeIntegrityFlag.noServerAnchor)
      .isEmpty;
}

/// يحسم «الآن» من المرساة والقراءة الحالية.
///
/// داخل نفس الإقلاع: المنقضي من العدّاد التصاعدي، ويُرفع علم إن خالفت
/// ساعة الحائط ذلك بما يتجاوز [deviceClockDriftTolerance]. بعد إقلاع
/// جديد: ساعة الحائط مع علم، لأن العدّاد صُفِّر.
ResolvedNow resolveNow({
  required SessionTimeAnchor anchor,
  required TimeReading reading,
}) {
  final flags = <TimeIntegrityFlag>{};

  if (anchor.serverTime == null) {
    flags.add(TimeIntegrityFlag.noServerAnchor);
  }

  if (reading.bootId != anchor.bootId) {
    // العدّاد التصاعدي صُفِّر مع الإقلاع. مقارنته بمرساة إقلاع سابق
    // تُنتج مدة سالبة أو عشوائية، فلا تُقارَن أصلًا.
    flags.add(TimeIntegrityFlag.rebootTimelineUnverified);

    return ResolvedNow(at: reading.wallClock.toUtc(), flags: flags);
  }

  final monotonicElapsed = reading.monotonic - anchor.monotonic;
  final fromMonotonic = anchor.wallClock.toUtc().add(monotonicElapsed);
  final wallDifference = reading.wallClock
      .toUtc()
      .difference(fromMonotonic)
      .abs();

  if (wallDifference > deviceClockDriftTolerance) {
    flags.add(TimeIntegrityFlag.deviceClockChanged);
  }

  // العدّاد التصاعدي يُستخدم في الحالتين داخل نفس الإقلاع: هو الأصدق
  // بحكم القسم 19، لا فقط عند اكتشاف تعديل.
  return ResolvedNow(at: fromMonotonic, flags: flags);
}

/// يفحص ترتيب أوقات الأحداث المحفوظة.
///
/// [occurredAtBySequence] أوقات وقوع الأحداث بترتيب تسلسلها الصاعد.
/// يُعيد علمًا واحدًا عند اكتشاف ترتيب مستحيل، أو مجموعة فارغة.
///
/// المساواة مسموحة: أمران في نفس الثانية شيء يحدث فعلًا (استئناف ثم
/// تغيير طاقة فورًا)، ولا يعني خللًا.
Set<TimeIntegrityFlag> checkEventOrdering(List<DateTime> occurredAtBySequence) {
  for (var index = 1; index < occurredAtBySequence.length; index += 1) {
    if (occurredAtBySequence[index].isBefore(occurredAtBySequence[index - 1])) {
      return const {TimeIntegrityFlag.impossibleEventOrdering};
    }
  }

  return const {};
}

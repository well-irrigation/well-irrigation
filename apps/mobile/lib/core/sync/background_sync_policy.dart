/// متى نوقظ الهاتف مرة أخرى، ومتى نتركه؟
///
/// هذا الملف هو القرار وحده، بلا WorkManager وبلا شبكة وبلا جهاز، حتى
/// يكون قابلًا للإثبات على الحاسب. الملف الذي يعرف WorkManager هو
/// `workmanager_sync_scheduler.dart` فقط.
///
/// ثلاث قواعد تحكمه:
///
/// 1. **لا استسلام على عملٍ قد ينجح.** ما فشل لسبب عابر يبقى مجدولًا
///    بلا سقف لعدد المحاولات — السقف على *المدة بين المحاولات* لا على
///    عددها. إسقاط أمر معلَّق يعني ضياع دخل بئر فعلي، وهذا لا يجوز.
/// 2. **لا إيقاظ بلا فائدة.** طابور فارغ، أو طابور كل ما فيه موقوف على
///    قرار إنسان، لا يُجدَّد له موعد. إعادة المحاولة على رفضٍ عملي لا
///    تصلحه شبكة (ق-90 بند 20، القسم 20).
/// 3. **التراجع أُسّي مع سقف.** كل محاولة فاشلة تضاعف الانتظار حتى
///    [maxDelay]، فلا تُستنزف البطارية على شبكة غائبة طويلًا.
library;

import 'sync_engine.dart';

/// ما انتهى إليه تشغيل خلفي واحد — بلغة تُعرض للمستخدم لا بلغة كود.
enum BackgroundSyncOutcome {
  /// لا شيء في الطابور. كل ما سجّله المستخدم وصل.
  nothingToSend,

  /// أُرسل كل ما كان جاهزًا في هذا التشغيل.
  allSent,

  /// بقي عمل، والسبب عابر: نعيد المحاولة لاحقًا بلا تدخل.
  retryLater,

  /// بقي عمل موقوف على قرار إنسان: لا إعادة تلقائية.
  awaitsHumanDecision,

  /// حلقة أخرى تعمل الآن (التطبيق مفتوح مثلًا) — نمرّ لاحقًا.
  alreadyRunning,
}

/// قرار الجدولة بعد تشغيل واحد.
class BackgroundSyncDecision {
  const BackgroundSyncDecision({
    required this.outcome,
    required this.attempt,
    this.retryDelay,
  });

  final BackgroundSyncOutcome outcome;

  /// رقم المحاولة التي انتهت الآن (تبدأ من 1).
  final int attempt;

  /// الانتظار قبل المحاولة التالية، أو `null` إن لا محاولة تالية.
  final Duration? retryDelay;

  bool get shouldRetry => retryDelay != null;

  /// رقم المحاولة القادمة كما يُمرَّر إلى العامل التالي.
  int get nextAttempt => shouldRetry ? attempt + 1 : 1;

  /// نصّ عربي قصير يصلح لسطر حالة في الشاشة.
  String get statusText => switch (outcome) {
    BackgroundSyncOutcome.nothingToSend => 'لا شيء في الانتظار',
    BackgroundSyncOutcome.allSent => 'تم إرسال كل شيء',
    BackgroundSyncOutcome.retryLater => 'سيُرسل تلقائيًا عند توفر الشبكة',
    BackgroundSyncOutcome.awaitsHumanDecision => 'يحتاج مراجعتك',
    BackgroundSyncOutcome.alreadyRunning => 'الإرسال جارٍ الآن',
  };

  @override
  String toString() =>
      'BackgroundSyncDecision(${outcome.name} attempt=$attempt '
      'retryDelay=$retryDelay)';
}

class BackgroundSyncPolicy {
  const BackgroundSyncPolicy({
    this.firstDelay = const Duration(seconds: 30),
    this.maxDelay = const Duration(hours: 1),
    this.busyDelay = const Duration(minutes: 1),
    this.maxPassesPerRun = 5,
  });

  /// الانتظار بعد أول فشل عابر.
  final Duration firstDelay;

  /// أقصى انتظار بين محاولتين — السقف الذي يمنع استنزاف البطارية.
  final Duration maxDelay;

  /// الانتظار حين تكون حلقة أخرى تعمل الآن.
  final Duration busyDelay;

  /// أقصى عدد مرّات يُعاد فيها تشغيل الحلقة داخل *نفس* التشغيل الخلفي
  /// ما دام التقدّم مستمرًّا.
  ///
  /// طابور طويل يجب أن يُفرَّغ في نافذة واحدة، لا أمرًا واحدًا في كل
  /// نافذة تراجع. والسقف موجود لأن نافذة العامل الخلفي محدودة أصلًا.
  final int maxPassesPerRun;

  /// انتظار المحاولة رقم [attempt] — أُسّي مضاعف حتى [maxDelay].
  Duration delayForAttempt(int attempt) {
    if (attempt <= 1) {
      return firstDelay;
    }

    final capMicros = maxDelay.inMicroseconds;
    var micros = firstDelay.inMicroseconds;

    for (var step = 1; step < attempt; step += 1) {
      micros *= 2;

      if (micros >= capMicros) {
        return maxDelay;
      }
    }

    return Duration(microseconds: micros);
  }

  /// هل نعيد تشغيل الحلقة فورًا داخل نفس التشغيل الخلفي؟
  ///
  /// شرطه تقدّمٌ فعلي: أمرٌ واحد على الأقل قَبِله الخادم، وبقي عملٌ قد
  /// ينجح. بلا شرط التقدّم تصير هذه حلقة مشدودة على شبكة غائبة.
  bool shouldContinueDraining(SyncRunReport report, int passesDone) =>
      passesDone < maxPassesPerRun &&
      report.confirmed > 0 &&
      report.canRetryWithoutHelp;

  BackgroundSyncDecision decide({
    required SyncRunReport report,
    int attempt = 1,
  }) {
    if (report.alreadyRunning) {
      return BackgroundSyncDecision(
        outcome: BackgroundSyncOutcome.alreadyRunning,
        attempt: attempt,
        retryDelay: busyDelay,
      );
    }

    if (report.canRetryWithoutHelp) {
      return BackgroundSyncDecision(
        outcome: BackgroundSyncOutcome.retryLater,
        attempt: attempt,
        // تقدَّمنا فعلًا؟ إذن الشبكة تعمل والطابور طويل فقط: نعود سريعًا
        // بأول انتظار بدل مواصلة التراجع الأُسّي.
        retryDelay: report.confirmed > 0
            ? firstDelay
            : delayForAttempt(attempt),
      );
    }

    if (report.awaitsHumanDecision) {
      return BackgroundSyncDecision(
        outcome: BackgroundSyncOutcome.awaitsHumanDecision,
        attempt: attempt,
      );
    }

    return BackgroundSyncDecision(
      outcome: report.confirmed > 0
          ? BackgroundSyncOutcome.allSent
          : BackgroundSyncOutcome.nothingToSend,
      attempt: attempt,
    );
  }
}

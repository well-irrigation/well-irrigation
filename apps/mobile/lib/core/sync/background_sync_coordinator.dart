/// الوصل بين حلقة الإرسال وسياسة الجدولة.
///
/// مسؤوليته الوحيدة: شغّل الحلقة، وفرّغ الطابور ما دام هناك تقدّم، ثم
/// أعطِ قرارًا واحدًا واضحًا. لا يعرف WorkManager ولا Supabase ولا
/// sqflite، فيُختبر كاملًا على الحاسب.
///
/// **من أين يُعاد الإيقاظ — تفصيلة تمنع خطأً حقيقيًا:**
///
/// - من العامل الخلفي: القرار يُترجم إلى قيمة الإرجاع (`false` = أعِد
///   جدولتي)، ونظام التشغيل نفسه يتولى الموعد بتراجعه الأُسّي. لا نطلب
///   عملًا جديدًا بنفس الاسم الفريد ونحن ما زلنا نعمل تحته — ذلك يلغي
///   العامل الجاري أو يبني سلسلة عمل معقّدة بلا داعٍ.
/// - من التطبيق المفتوح: لا توجد قيمة إرجاع يفهمها النظام، فنطلب موعدًا
///   خلفيًا صريحًا. هذا ما يجعل «سجّلت ثم أغلقت التطبيق» يصل.
library;

import 'background_sync_policy.dart';
import 'background_sync_scheduler.dart';
import 'sync_engine.dart';

class BackgroundSyncCoordinator {
  BackgroundSyncCoordinator({
    required this._engine,
    required this._scheduler,
    this.policy = const BackgroundSyncPolicy(),
  });

  final SyncEngine _engine;
  final BackgroundSyncScheduler _scheduler;
  final BackgroundSyncPolicy policy;

  /// عدد مرّات تشغيل الحلقة في آخر نداء — للاختبار والقياس.
  int get passesInLastRun => _passesInLastRun;
  int _passesInLastRun = 0;

  /// تشغيل من داخل العامل الخلفي.
  ///
  /// لا يجدول شيئًا بنفسه: المتصل يترجم [BackgroundSyncDecision.shouldRetry]
  /// إلى قيمة الإرجاع التي يفهمها نظام التشغيل.
  Future<BackgroundSyncDecision> runFromWorker(
    String accountId, {
    int attempt = 1,
  }) => _drain(accountId, attempt: attempt);

  /// تشغيل من التطبيق المفتوح، ويضمن استمرار العمل بعد إغلاقه.
  Future<BackgroundSyncDecision> runFromApp(
    String accountId, {
    int attempt = 1,
  }) async {
    final decision = await _drain(accountId, attempt: attempt);
    final delay = decision.retryDelay;

    if (delay != null) {
      await _scheduler.scheduleSync(
        accountId,
        delay: delay,
        attempt: decision.nextAttempt,
      );
    }

    return decision;
  }

  Future<BackgroundSyncDecision> _drain(
    String accountId, {
    required int attempt,
  }) async {
    var report = await _engine.run(accountId);
    var passes = 1;

    // طابور طويل يجب أن يُفرَّغ في نافذة واحدة. شرط الاستمرار هو تقدّمٌ
    // فعلي في التمريرة السابقة، فلا تصير هذه حلقة مشدودة بلا شبكة.
    while (policy.shouldContinueDraining(report, passes)) {
      final next = await _engine.run(accountId);

      if (next.alreadyRunning) {
        break;
      }

      report = next;
      passes += 1;
    }

    _passesInLastRun = passes;

    return policy.decide(report: report, attempt: attempt);
  }
}

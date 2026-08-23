/// الأسباب التي تستدعي إرسالًا، ومنع تكرارها بلا فائدة.
///
/// أربعة أسباب تستدعي الإرسال: فتح التطبيق، رجوعه إلى الواجهة، عودة
/// الشبكة، وتسجيل عملية جديدة. وسبب خامس صريح: طلب المستخدم اليدوي.
///
/// المشكلة التي يحلّها هذا الملف: هذه الأسباب تتزامن. المستخدم يفتح
/// التطبيق فتعود الشبكة فيسجّل عملية في ثانيتين — ثلاث طلبات جدولة على
/// نفس الطابور. الكبح الزمني يجعلها طلبًا واحدًا.
///
/// وقاعدة مقصودة: الطلب اليدوي **لا يُكبح أبدًا**. ضغط المستخدم على
/// «أرسل الآن» بلا أثر ظاهر أسوأ من طلب زائد.
library;

import 'background_sync_scheduler.dart';

/// سبب طلب الإرسال — يُسجَّل ويُختبر، ويصلح للقياس الميداني لاحقًا.
enum SyncTriggerReason {
  appStarted,
  appResumed,
  connectivityRestored,
  commandQueued,
  manualRequest,
}

class BackgroundSyncTrigger {
  BackgroundSyncTrigger({
    required this._scheduler,
    DateTime Function()? clock,
    this.minimumInterval = const Duration(seconds: 20),
  }) : _clock = clock ?? DateTime.now;

  final BackgroundSyncScheduler _scheduler;
  final DateTime Function() _clock;

  /// أقل فاصل بين طلبَي جدولة تلقائيَّين.
  final Duration minimumInterval;

  DateTime? _lastRequestAt;

  /// آخر سبب أدّى إلى جدولة فعلية — للعرض والتشخيص.
  SyncTriggerReason? get lastAcceptedReason => _lastAcceptedReason;
  SyncTriggerReason? _lastAcceptedReason;

  /// يطلب الجدولة، ويُعيد `true` إن طُلبت فعلًا لا مكبوحة.
  Future<bool> request(String accountId, SyncTriggerReason reason) async {
    final now = _clock();
    final isManual = reason == SyncTriggerReason.manualRequest;

    // فتح التطبيق من جديد يعني عمليةً جديدة تمامًا (قد يكون الهاتف أُقلع
    // للتو)، فلا يُكبح بموعدٍ قديم من تشغيل سابق.
    final isForced = isManual || reason == SyncTriggerReason.appStarted;

    if (!isForced) {
      final last = _lastRequestAt;

      if (last != null && now.difference(last) < minimumInterval) {
        return false;
      }
    }

    _lastRequestAt = now;
    _lastAcceptedReason = reason;

    await _scheduler.scheduleSync(
      accountId,
      // اليدوي وحده يستبدل الموعد القائم: المستخدم ينتظر الآن. وما عداه
      // يحترم تراجعًا أُسّيًا قائمًا بدل تصفيره في كل مرة.
      replaceExisting: isManual,
    );

    return true;
  }

  /// يُنسي الكبح — عند تسجيل خروج أو تبديل حساب.
  void reset() {
    _lastRequestAt = null;
    _lastAcceptedReason = null;
  }
}

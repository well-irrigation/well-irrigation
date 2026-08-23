/// التنفيذ فوق WorkManager — الملف الوحيد في هذا المجلد الذي يعرفه.
///
/// لماذا WorkManager وليس مؤقّتًا داخل التطبيق: المؤقّت يموت مع العملية.
/// WorkManager يحفظ العمل المطلوب في قاعدة بياناته الخاصة، فيبقى بعد
/// إغلاق التطبيق وبعد قتل النظام له، ويُعاد جدولته بعد إقلاع الهاتف
/// عبر مستقبِل الإقلاع الذي تُعلنه مكتبة `androidx.work` نفسها.
///
/// الحدّ الذي لا يُتجاوَز: **Force Stop** من إعدادات النظام يمنع أي عمل
/// خلفي حتى يفتح المستخدم التطبيق مرة أخرى. لا حيلة تقنية مشروعة تتجاوزه
/// (القسم 8)، ولذلك يبقى فتح التطبيق مصدرًا ثالثًا للإرسال.
///
/// **شرط الشبكة** [NetworkType.connected] يعني أن النظام لا يوقظ العامل
/// أصلًا بلا واجهة شبكة — فلا محاولة فاشلة مؤكَّدة سلفًا، ولا استنزاف
/// بطارية. وهو مؤشِّر لا دليل: قد يوقظنا على شبكة بلا إنترنت، وحينها
/// يفشل الإرسال فشلًا عابرًا ويُعاد بالتراجع الأُسّي.
library;

import 'package:workmanager/workmanager.dart';

import 'background_sync_policy.dart';
import 'background_sync_scheduler.dart';

class WorkmanagerSyncScheduler implements BackgroundSyncScheduler {
  WorkmanagerSyncScheduler({
    Workmanager? workmanager,
    this.policy = const BackgroundSyncPolicy(),
  }) : _workmanager = workmanager ?? Workmanager();

  final Workmanager _workmanager;
  final BackgroundSyncPolicy policy;

  /// يُهيّئ نقطة الدخول التي ينادِيها النظام عند حلول الموعد.
  ///
  /// تُنادى مرة واحدة عند بدء التطبيق، قبل أي جدولة.
  Future<void> initialize(Function callbackDispatcher) =>
      _workmanager.initialize(callbackDispatcher);

  @override
  Future<void> scheduleSync(
    String accountId, {
    Duration? delay,
    int attempt = 1,
    bool replaceExisting = false,
  }) {
    return _workmanager.registerOneOffTask(
      backgroundSyncWorkName(accountId),
      backgroundSyncTaskName,
      inputData: {
        backgroundSyncAccountKey: accountId,
        backgroundSyncAttemptKey: attempt,
      },
      initialDelay: delay,
      constraints: Constraints(networkType: NetworkType.connected),
      // `keep` عند فتح التطبيق وعودة الشبكة: موعدٌ قائم لا يُصفَّر ولا
      // يُضاعَف. و`update` للطلب اليدوي: نفس العمل الفريد بموعد الآن.
      existingWorkPolicy: replaceExisting
          ? ExistingWorkPolicy.update
          : ExistingWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: policy.firstDelay,
      // لا `expedited` ولا خدمة أمامية: الإرسال لا يستحق إشعارًا دائمًا
      // على شاشة المستخدم ولا صلاحيات أوسع (القسم 11).
    );
  }

  @override
  Future<void> cancelSync(String accountId) =>
      _workmanager.cancelByUniqueName(backgroundSyncWorkName(accountId));
}

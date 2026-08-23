/// أسلاك الإرسال الخلفي داخل التطبيق المفتوح.
///
/// يجمع ثلاثة مصادر إيقاظ في مكان واحد:
///
/// 1. **فتح التطبيق** — جدولة فورية. تغطي الحالة التي لا يغطيها نظام
///    التشغيل: مستخدم أوقف التطبيق قسريًا (Force Stop) فمُنع كل عمل
///    خلفي حتى يفتحه بنفسه (القسم 8).
/// 2. **رجوعه إلى الواجهة** — المستخدم عاد وربما دخل تحت تغطية شبكة.
/// 3. **عودة الشبكة** — مؤشِّر من النظام: جرِّب الآن.
///
/// كل المنطق القابل للخطأ (الكبح، والقرار، والتراجع) في ملفات أخرى
/// مُختبَرة. هذا الملف أسلاك فقط، ولذلك يبقى قصيرًا مقصودًا.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'background_sync_trigger.dart';
import 'connectivity_plus_watcher.dart';
import 'connectivity_watcher.dart';

class BackgroundSyncBinding {
  BackgroundSyncBinding({
    required this._trigger,
    ConnectivityWatcher? connectivity,
    this.observeLifecycle = true,
  }) : _connectivity = connectivity ?? ConnectivityPlusWatcher();

  final BackgroundSyncTrigger _trigger;
  final ConnectivityWatcher _connectivity;

  /// يُطفأ في الاختبار: مراقبة دورة حياة التطبيق تحتاج ربطًا حقيقيًا.
  final bool observeLifecycle;

  String? _accountId;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<void>? _connectivitySubscription;

  /// يبدأ المراقبة لحساب داخلٍ الآن، ويجدول إرسالًا فوريًا.
  Future<void> attach(String accountId) async {
    _accountId = accountId;

    final watcher = _connectivity;

    if (watcher is ConnectivityPlusWatcher) {
      watcher.start();
    }

    _connectivitySubscription ??= watcher.onConnectivityRestored.listen(
      (_) => handleConnectivityRestored(),
    );

    if (observeLifecycle) {
      _lifecycle ??= AppLifecycleListener(onResume: handleAppResumed);
    }

    await _trigger.request(accountId, SyncTriggerReason.appStarted);
  }

  /// عملية جديدة سُجّلت على القرص الآن.
  Future<bool> handleCommandQueued() =>
      _request(SyncTriggerReason.commandQueued);

  Future<bool> handleAppResumed() => _request(SyncTriggerReason.appResumed);

  Future<bool> handleConnectivityRestored() =>
      _request(SyncTriggerReason.connectivityRestored);

  /// «أرسل الآن» بطلب المستخدم — لا يُكبح.
  Future<bool> requestManualSync() => _request(SyncTriggerReason.manualRequest);

  Future<bool> _request(SyncTriggerReason reason) async {
    final accountId = _accountId;

    if (accountId == null) {
      return false;
    }

    return _trigger.request(accountId, reason);
  }

  /// تسجيل خروج أو إغلاق: يوقف المراقبة ويُنسي الكبح.
  ///
  /// لا يُلغي الإرسال المجدول: عملياتٌ محفوظة على القرص يجب أن تصل، وهي
  /// لا تُرسل أصلًا بلا جلسة دخول صالحة (الطبقة الناقلة تُعيدها كفشل
  /// عابر). إلغاء الطابور قرارٌ منفصل اسمه فكّ ربط الجهاز.
  Future<void> detach() async {
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    await _connectivity.dispose();
    _trigger.reset();
    _accountId = null;
  }
}

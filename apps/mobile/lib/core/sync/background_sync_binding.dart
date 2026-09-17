// ignore_for_file: prefer_initializing_formals

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
    required BackgroundSyncTrigger trigger,
    ConnectivityWatcher? connectivity,
    this.observeLifecycle = true,
  }) : _trigger = trigger,
       _connectivity = connectivity ?? ConnectivityPlusWatcher();

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

    try {
      return await _trigger.request(accountId, reason);
    } catch (_) {
      // الجدولة فقط فشلت؛ لا يُلمس الأمر المتين ولا تُرمى من مستمعات النظام.
      return false;
    }
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

/// يربط مراقبة الخلفية بالحساب الذي تُمثّله جلسة المصادقة المحلية الآن.
/// يُنشئ مراقبًا جديدًا بعد الخروج لأن المراقب القديم أُغلق عند فصله.
class AuthenticatedBackgroundSync {
  AuthenticatedBackgroundSync({
    required Stream<void> authChanges,
    required String? Function() currentAccountId,
    required BackgroundSyncBinding Function() bindingFactory,
  }) : _authChanges = authChanges,
       _currentAccountId = currentAccountId,
       _bindingFactory = bindingFactory;

  final Stream<void> _authChanges;
  final String? Function() _currentAccountId;
  final BackgroundSyncBinding Function() _bindingFactory;
  StreamSubscription<void>? _authSubscription;
  BackgroundSyncBinding? _binding;
  String? _boundAccountId;
  Future<void> _transition = Future<void>.value();
  bool _disposed = false;

  Future<void> start() async {
    if (_disposed || _authSubscription != null) return;
    _authSubscription = _authChanges.listen((_) {
      unawaited(refresh());
    });
    await refresh();
  }

  /// يُستدعى أيضًا بعد نجاح إعادة التحقق حتى لو لم تصدر نبضة مصادقة.
  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    _transition = _transition.then((_) async {
      if (_disposed) return;
      final accountId = _currentAccountId();
      if (accountId == _boundAccountId) return;
      final previous = _binding;
      _binding = null;
      _boundAccountId = null;
      await previous?.detach();
      if (_disposed || accountId == null || _currentAccountId() != accountId) {
        return;
      }
      final binding = _bindingFactory();
      _binding = binding;
      _boundAccountId = accountId;
      try {
        await binding.attach(accountId);
      } catch (_) {
        // فشل الجدولة لا يُسقط المراقبة؛ عودة الاتصال تعيد الطلب.
      }
    });
    return _transition;
  }

  /// لا يطلب عملًا باسم مالك الأمر إلا إذا بقي هو الحساب المصادَق الحالي.
  Future<bool> commandQueued(String accountId) async {
    await _transition;
    if (_disposed ||
        _boundAccountId != accountId ||
        _currentAccountId() != accountId) {
      return false;
    }
    return _binding!.handleCommandQueued();
  }

  Future<void> dispose() async {
    _disposed = true;
    await _authSubscription?.cancel();
    await _transition;
    await _binding?.detach();
    _binding = null;
    _boundAccountId = null;
  }
}

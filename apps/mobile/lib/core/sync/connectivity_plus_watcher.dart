/// التنفيذ فوق `connectivity_plus` — الملف الوحيد الذي يعرفه.
///
/// يترجم تدفّق حالات الواجهات الخام إلى نبضة واحدة: «عادت الشبكة».
/// المنطق نفسه في [ConnectivityRestoredDetector] وهو مُختبَر بلا جهاز؛
/// هنا الأسلاك فقط.
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'connectivity_watcher.dart';

class ConnectivityPlusWatcher implements ConnectivityWatcher {
  ConnectivityPlusWatcher({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;
  final ConnectivityRestoredDetector _detector = ConnectivityRestoredDetector();
  final StreamController<void> _restored = StreamController<void>.broadcast();

  StreamSubscription<List<ConnectivityResult>>? _subscription;

  /// يبدأ المراقبة. يُنادى مرة واحدة عند تهيئة التطبيق.
  void start() {
    _subscription ??= _connectivity.onConnectivityChanged.listen((results) {
      if (_detector.accept(_looksOnline(results)) && !_restored.isClosed) {
        _restored.add(null);
      }
    });
  }

  @override
  Future<bool> looksOnline() async =>
      _looksOnline(await _connectivity.checkConnectivity());

  @override
  Stream<void> get onConnectivityRestored => _restored.stream;

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _restored.close();
  }

  /// أي واجهة غير [ConnectivityResult.none] تكفي كمؤشِّر للمحاولة.
  ///
  /// قائمة فارغة تُعدّ «بلا شبكة»: بعض المنصّات تُبلّغ بها عند الانقطاع.
  static bool _looksOnline(List<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);
}

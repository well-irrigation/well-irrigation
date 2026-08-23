/// مراقب الشبكة — **مؤشِّر** لا دليل.
///
/// نظام التشغيل يقول «هناك واجهة شبكة متصلة»، ولا يقول «الخادم يستجيب».
/// شبكة مقهى بصفحة تسجيل دخول، وشبكة قرية بـ«شرطتين» بلا بيانات فعلية،
/// كلتاهما «متصلة» في نظر النظام. لذلك:
///
/// - وجود شبكة = **جرِّب الإرسال الآن**، لا «الإرسال سينجح».
/// - غياب الشبكة = **لا تُحاول الآن**، ولا «العملية فشلت». لا يُعلَّم أي
///   أمر فاشلًا ولا يُلمس عدّاد محاولاته اعتمادًا على هذا الملف. الحقيقة
///   الوحيدة في نجاح الإرسال هي ردّ الخادم (القسم 20).
///
/// الواجهة Dart خالص، والتنفيذ الذي يعرف `connectivity_plus` ملف واحد
/// هو `connectivity_plus_watcher.dart`.
library;

/// مصدر مؤشِّر الاتصال.
abstract interface class ConnectivityWatcher {
  /// هل يبدو الجهاز متصلًا الآن؟ (مؤشِّر لحظي، غير مضمون.)
  Future<bool> looksOnline();

  /// نبضة عند كل *عودة* من «بلا شبكة» إلى «هناك شبكة».
  ///
  /// عودة الشبكة فقط هي الحدث المفيد: انقطاعها لا يستدعي عملًا.
  Stream<void> get onConnectivityRestored;

  Future<void> dispose();
}

/// يحوّل تدفّق حالات الاتصال الخام إلى نبضات «عادت الشبكة».
///
/// منطق خالص مفصول عن الحزمة كي يُختبر بلا جهاز: يستقبل `bool` ويُخرج
/// النبضة عند الحدّ الصاعد وحده، ويتجاهل تكرار نفس الحالة.
class ConnectivityRestoredDetector {
  ConnectivityRestoredDetector({bool initiallyOnline = false})
    : _online = initiallyOnline;

  bool _online;

  bool get isOnline => _online;

  /// يُعيد `true` إن كان هذا الانتقال «عودةً» تستدعي محاولة إرسال.
  bool accept(bool online) {
    final restored = online && !_online;
    _online = online;

    return restored;
  }
}

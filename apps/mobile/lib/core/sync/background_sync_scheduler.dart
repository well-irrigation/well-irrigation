/// بوابة الجدولة: «أوقظني لأرسل» بلا معرفة بأي نظام تشغيل.
///
/// الفصل هنا هو نفسه الفصل في `OutboxStore`: الواجهة Dart خالص، والتنفيذ
/// الذي يعرف WorkManager ملف واحد فقط. فائدته المباشرة أن كل سلوك
/// الجدولة يُختبر على الحاسب بمزيَّف، بلا جهاز ولا محاكي.
library;

/// اسم العمل الفريد لكل حساب.
///
/// فريدٌ **لكل حساب** لا للتطبيق كله: عاملان لحسابين مختلفين لا يلغي
/// أحدهما الآخر، وحسابٌ واحد لا يحصل على عاملين متوازيين على نفس
/// الطابور. (الحماية النهائية من الإرسال المزدوج تبقى الحجز الشرطي في
/// التخزين — هذا توفير عمل لا ضمان صحّة.)
String backgroundSyncWorkName(String accountId) =>
    'well_irrigation_outbox_sync::$accountId';

/// اسم المهمة كما يستقبله معالج العامل الخلفي.
const String backgroundSyncTaskName = 'outbox_sync';

/// مفاتيح البيانات المُمرَّرة إلى العامل.
const String backgroundSyncAccountKey = 'account_id';
const String backgroundSyncAttemptKey = 'attempt';

/// ما تحتاجه طبقة المزامنة من نظام التشغيل، ولا أكثر.
abstract interface class BackgroundSyncScheduler {
  /// اجدُل إرسالًا في أقرب فرصة تتوفر فيها شبكة.
  ///
  /// [replaceExisting] = `false` (الافتراض) يعني: إن كان هناك موعد
  /// مجدول فلا تُلغِه ولا تُضِف ثانيًا. هذا هو المطلوب عند فتح التطبيق
  /// أو عودة الشبكة، وإلا لصفَّرنا تراجعًا أُسّيًا قائمًا في كل مرة.
  ///
  /// [replaceExisting] = `true` للمزامنة اليدوية: المستخدم طلب الآن.
  /// آمنٌ حتى لو كان عاملٌ يعمل في تلك اللحظة، لأن الحجز الشرطي
  /// واستعادة الحجوزات الميتة يغطيان الإلغاء في منتصف الإرسال.
  Future<void> scheduleSync(
    String accountId, {
    Duration? delay,
    int attempt = 1,
    bool replaceExisting = false,
  });

  /// ألغِ أي إرسال مجدول لهذا الحساب (تسجيل خروج، أو فكّ ربط الجهاز).
  Future<void> cancelSync(String accountId);
}

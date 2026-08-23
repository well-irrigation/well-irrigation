/// الحالة التجارية للجلسة — منفصلة تمامًا عن حالة المزامنة.
///
/// القسم 3 من `ACTIVE_SESSION_ARCHITECTURE.md` صريح: `business_state`
/// و`sync_state` **لا يدمجان في Status واحد**. جلسة `running` مع
/// `pending` حالة صالحة تمامًا — السقي يعمل في الأرض والعملية لم تصل
/// الخادم بعد. دمجهما يعني أن انقطاع الشبكة يظهر للمستخدم كأنه توقف
/// المضخة، وهو خطأ عرض يقود إلى قرار ميداني خاطئ.
///
/// لذلك هذا الملف لا يستورد شيئًا من `core/sync/`: النوعان لا يلتقيان
/// إلا في نموذج القراءة، كل واحد في حقله.
library;

/// حالة السقي نفسه كما يراها المشغّل في الأرض.
enum SessionBusinessState {
  /// المضخة تعمل والوقت المحتسب يزيد.
  running,

  /// موقوفة مؤقتًا. الوقت المحتسب **لا** يزيد (القسم 5).
  paused,

  /// أُنهيت محليًا. التسوية النهائية عند الخادم (ق-92).
  completed;

  bool get isActive =>
      this == SessionBusinessState.running ||
      this == SessionBusinessState.paused;

  String get storageValue => name;

  static SessionBusinessState fromStorage(String value) =>
      SessionBusinessState.values.firstWhere((state) => state.name == value);
}

/// نصوص الحالة التجارية المعتمدة حرفيًا في `design/UX_UI_SPEC.md`.
///
/// لا تُصَغ من جديد هنا — نفس قاعدة `SyncStatusText` في طبقة المزامنة.
abstract final class SessionStateText {
  /// القرار 344 وما بعده.
  static const String running = 'جلسة جارية';

  /// القرار 346 والقرار 266.
  static const String paused = 'الجلسة متوقفة مؤقتًا';

  /// القرار 4286 في المواصفة: نصّ إنهاء الجلسة محليًا.
  static const String completed = 'تم إنهاء الجلسة';

  /// القرار 339: عنوان العدّاد الرئيسي.
  static const String billableLabel = 'مدة السقي المحتسبة';

  /// القرار 346.
  static const String currentPauseLabel = 'مدة التوقف الحالية';

  /// القرار 339 — تفصيل لا عدّاد رئيسي.
  static const String sinceStartLabel = 'منذ بدء الجلسة';

  /// القرار 339.
  static const String totalPauseLabel = 'إجمالي التوقف';

  /// القرار 340.
  static const String accruedLabel = 'المستحق حتى الآن';

  /// القرار 341: يظهر **بدل** الرقم، لا معه. لا «0 ريال» ولا رقم مخمَّن.
  static const String pricingPending = 'التكلفة بانتظار المزامنة';
}

String sessionStateText(SessionBusinessState state) => switch (state) {
  SessionBusinessState.running => SessionStateText.running,
  SessionBusinessState.paused => SessionStateText.paused,
  SessionBusinessState.completed => SessionStateText.completed,
};

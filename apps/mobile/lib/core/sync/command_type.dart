/// أنواع العمليات الميدانية التي يقبلها الخادم بحماية تكرار (ق-114).
///
/// كل نوع يحمل عقده الكامل مع طبقة `api`: اسم الدالة، اسم وسيط وقت
/// الحدث، أي مرجع يحدد الجهة، وأي كيان يُنتَج ويُسجَّل في جدول الربط.
/// هذا الملف Dart خالص بلا أي تبعية.
library;

/// الجهة التي يُحسم بها `command_id` على الخادم.
///
/// الخادم يستخرج الجهة بنفسه (`sync.begin_well_command` أو
/// `sync.begin_session_command`)، لكن العميل يجب أن يعرف أي معرّف
/// يُرسله حتى يُحسم — ولا يُرسل الأمر قبل حسم ذلك المعرّف.
enum CommandScope {
  /// الأمر معرَّف ببئر — يُستخدم عندما لا تكون الجلسة قد أُنشئت بعد.
  well,

  /// الأمر معرَّف بجلسة قائمة.
  session,
}

/// أنواع الكيانات التي يمكن أن يُنتجها أمرٌ فيصير معرّفها الخادمي
/// مرجعًا لأوامر لاحقة.
enum EntityKind {
  session,
  farmerWellAccount,
  farm,
  payment;

  String get storageValue => name;

  static EntityKind fromStorage(String value) =>
      EntityKind.values.firstWhere((kind) => kind.name == value);
}

/// العمليات الثماني للدورة الميدانية الأولى.
///
/// الترتيب هنا لا يعني ترتيب الإرسال؛ الإرسال يتبع `sequence` في
/// الطابور.
enum CommandType {
  createFarmer(
    rpcName: 'create_farmer',
    scope: CommandScope.well,
    scopeArgument: 'p_well_id',
    returnsJson: true,
    resultKey: 'farmer_well_account_id',
    produces: EntityKind.farmerWellAccount,
  ),

  createFarm(
    rpcName: 'create_farm',
    scope: CommandScope.well,
    scopeArgument: 'p_well_id',
    returnsJson: true,
    resultKey: 'farm_id',
    produces: EntityKind.farm,
  ),

  startIrrigationSession(
    rpcName: 'start_irrigation_session',
    scope: CommandScope.well,
    scopeArgument: 'p_well_id',
    eventTimeArgument: 'p_started_at',
    returnsJson: false,
    produces: EntityKind.session,
  ),

  pauseIrrigationSession(
    rpcName: 'pause_irrigation_session',
    scope: CommandScope.session,
    scopeArgument: 'p_session_id',
    eventTimeArgument: 'p_paused_at',
    returnsJson: false,
  ),

  resumeIrrigationSession(
    rpcName: 'resume_irrigation_session',
    scope: CommandScope.session,
    scopeArgument: 'p_session_id',
    eventTimeArgument: 'p_resumed_at',
    returnsJson: false,
  ),

  changeSessionEnergySource(
    rpcName: 'change_session_energy_source',
    scope: CommandScope.session,
    scopeArgument: 'p_session_id',
    eventTimeArgument: 'p_changed_at',
    returnsJson: false,
  ),

  recordPayment(
    rpcName: 'record_payment',
    scope: CommandScope.well,
    scopeArgument: 'p_well_id',
    eventTimeArgument: 'p_paid_at',
    returnsJson: true,
    resultKey: 'payment_id',
    produces: EntityKind.payment,
  ),

  completeIrrigationSession(
    rpcName: 'complete_irrigation_session',
    scope: CommandScope.session,
    scopeArgument: 'p_session_id',
    eventTimeArgument: 'p_ended_at',
    returnsJson: true,
    resultKey: 'session_id',
  );

  const CommandType({
    required this.rpcName,
    required this.scope,
    required this.scopeArgument,
    required this.returnsJson,
    this.eventTimeArgument,
    this.resultKey,
    this.produces,
  });

  /// اسم الدالة داخل مخطط `api`. هو نفسه `command_type` الذي يخزّنه
  /// الخادم في `sync.processed_commands` (Migration 084).
  final String rpcName;

  /// هل الأمر معرَّف ببئر أم بجلسة.
  final CommandScope scope;

  /// اسم الوسيط الذي يحمل معرّف الجهة.
  final String scopeArgument;

  /// اسم وسيط وقت الحدث.
  ///
  /// الخادم يستخدم `clock_timestamp()` افتراضيًا — أي وقت الإرسال لا
  /// وقت الحدث. لذلك يُرسل هذا الوسيط **دائمًا** من الطابور، وإلا
  /// حُسِب سعر عملية وقعت قبل ساعات بسعر لحظة المزامنة.
  ///
  /// `null` فقط لأوامر لا تحمل وقت حدث في عقدها الحالي
  /// (`create_farmer` و`create_farm`).
  final String? eventTimeArgument;

  /// هل الدالة تُرجِع `jsonb`؟ الأربع الأخرى تُرجِع `uuid` مجردًا.
  final bool returnsJson;

  /// مفتاح استخراج المعرّف من ردّ `jsonb`. `null` عندما يكون الردّ
  /// `uuid` مجردًا فيكون هو المعرّف نفسه.
  final String? resultKey;

  /// الكيان الذي يُنتجه هذا الأمر ويُسجَّل في جدول الربط لتعتمد عليه
  /// أوامر لاحقة.
  ///
  /// `null` لأحداث الجلسة (إيقاف/استئناف/تغيير طاقة/إنهاء): نتائجها
  /// تُخزَّن كما هي، لكنها لا تُنشئ كيانًا جديدًا يشير إليه أمر آخر —
  /// الجلسة نفسها ربطت عند البدء.
  final EntityKind? produces;

  String get storageValue => name;

  static CommandType fromStorage(String value) =>
      CommandType.values.firstWhere((type) => type.name == value);
}

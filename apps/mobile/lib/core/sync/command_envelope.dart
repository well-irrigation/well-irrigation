/// المغلَّف المحلي لعملية ميدانية واحدة.
///
/// يطابق حقول القسم 4 من `ANDROID_OFFLINE_BACKGROUND_SYNC.md`.
///
/// ملاحظتان بنيويتان:
///
/// 1. `commandId` حقل نهائي (`final`) بلا أي مُعدِّل. لا يوجد في هذا
///    الملف ولا في `SyncEngine` أي مسار لتغييره. تغييره بين المحاولات
///    يُبطل حماية التكرار الخادمية كلها (القسم 2 والقسم 7).
///
/// 2. لا يحمل المغلَّف هوية المنفِّذ. الخادم يقرأها من `auth.uid()`،
///    والقسم 4 يمنع أن يُرسل العميل منفِّذًا مختلفًا عمّا يستطيع
///    الخادم التحقق منه. `accountId` هنا للعزل المحلي فقط (ق-101) ولا
///    يُرسل.
library;

import 'command_reference.dart';
import 'command_type.dart';
import 'sync_status.dart';

class CommandEnvelope {
  CommandEnvelope({
    required this.localId,
    required this.commandId,
    required this.type,
    required this.accountId,
    required this.sequence,
    required this.occurredAt,
    required this.createdLocalAt,
    required this.payload,
    this.wellId,
    this.aggregateLocalId,
    this.status = CommandStatus.pending,
    this.retryCount = 0,
    this.lastError,
    this.lastAttemptAt,
    this.serverResponse,
  }) {
    _assertPayloadDoesNotOwnReservedArguments(type, payload);
  }

  /// معرّف الصفّ المحلي. تشير إليه المراجع في حمولات الأوامر التابعة.
  final String localId;

  /// معرّف العملية المُرسَل إلى الخادم في `p_command_id`.
  ///
  /// يُولَّد مرة واحدة عند الإدخال ولا يتغير أبدًا.
  final String commandId;

  final CommandType type;

  /// الحساب المصادَق الذي يملك هذا الأمر (ق-101). لا يُرسل للخادم.
  final String accountId;

  /// ترتيب تصاعدي عالمي داخل الحساب. يحدد ترتيب الإرسال.
  final int sequence;

  /// وقت وقوع العملية فعلًا في الميدان.
  ///
  /// يُرسل صراحة في كل محاولة. تركه للخادم يعني حساب سعر عملية وقعت
  /// قبل ساعات بسعر لحظة المزامنة (القسم 18).
  final DateTime occurredAt;

  /// وقت حفظ الأمر على الجهاز.
  final DateTime createdLocalAt;

  /// البئر التي تنتمي إليها العملية — للعرض والفلترة محليًا.
  ///
  /// أوامر الجلسة معرَّفة بجلسة لا ببئر، لكن معرفة بئرها محليًا تُغني
  /// عن تتبع سلسلة المراجع لعرض «عمليات هذه البئر».
  final String? wellId;

  /// الأصل الذي ينتمي إليه هذا الأمر — عادةً معرّف أمر بدء الجلسة.
  ///
  /// أوامر الأصل الواحد تُرسل بترتيبها ولا يُرسل لاحق قبل حسم سابقه.
  /// أصول مختلفة تُرسل بالتوازي (القسم 6).
  final String? aggregateLocalId;

  /// وسائط دالة `api` كما ستُرسل، وقد تحتوي مراجع غير محسومة.
  ///
  /// لا تحتوي `p_command_id` ولا وسيط وقت الحدث — يضيفهما المُرسِل من
  /// حقلي [commandId] و[occurredAt] حتى لا يوجد لهما مصدران.
  final Map<String, Object?> payload;

  final CommandStatus status;
  final int retryCount;
  final String? lastError;
  final DateTime? lastAttemptAt;

  /// ردّ الخادم المخزَّن بعد القبول.
  final Map<String, Object?>? serverResponse;

  /// الأصل الفعلي: الأمر الذي لا ينتمي لأصل هو أصل نفسه.
  String get effectiveAggregateId => aggregateLocalId ?? localId;

  /// هل جرت محاولة إرسال واحدة على الأقل؟
  bool get wasAttempted => retryCount > 0;

  /// نصّ الحالة المعروض للمستخدم.
  String get statusText => syncStatusText(status, attempted: wasAttempted);

  /// كل المراجع التي يجب حسمها قبل الإرسال.
  Set<CommandReference> get references => collectReferences(payload);

  CommandEnvelope copyWith({
    CommandStatus? status,
    int? retryCount,
    String? lastError,
    bool clearLastError = false,
    DateTime? lastAttemptAt,
    Map<String, Object?>? serverResponse,
  }) {
    return CommandEnvelope(
      localId: localId,
      commandId: commandId,
      type: type,
      accountId: accountId,
      sequence: sequence,
      occurredAt: occurredAt,
      createdLocalAt: createdLocalAt,
      payload: payload,
      wellId: wellId,
      aggregateLocalId: aggregateLocalId,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      serverResponse: serverResponse ?? this.serverResponse,
    );
  }

  @override
  String toString() =>
      'CommandEnvelope(${type.rpcName} seq=$sequence '
      'status=${status.storageValue} local=$localId)';
}

/// اسم وسيط معرّف العملية في كل أغلفة `api` (Migration 084).
const String commandIdArgument = 'p_command_id';

/// يمنع أن تحمل الحمولة وسيطًا يملكه المغلَّف.
///
/// مصدران لنفس القيمة يعنيان أن أحدهما سيُهمَل بصمت — وهو تمامًا نوع
/// الخطأ الذي يُبطل حماية التكرار أو يُفسد السعر التاريخي.
void _assertPayloadDoesNotOwnReservedArguments(
  CommandType type,
  Map<String, Object?> payload,
) {
  if (payload.containsKey(commandIdArgument)) {
    throw ArgumentError.value(
      payload,
      'payload',
      'لا تُمرَّر $commandIdArgument في الحمولة؛ مصدرها الوحيد هو '
          'commandId في المغلَّف',
    );
  }

  final eventTimeArgument = type.eventTimeArgument;

  if (eventTimeArgument != null && payload.containsKey(eventTimeArgument)) {
    throw ArgumentError.value(
      payload,
      'payload',
      'لا تُمرَّر $eventTimeArgument في الحمولة؛ مصدرها الوحيد هو '
          'occurredAt في المغلَّف',
    );
  }

  if (!payload.containsKey(type.scopeArgument)) {
    throw ArgumentError.value(
      payload,
      'payload',
      'الحمولة تفتقد ${type.scopeArgument} الذي يحدد جهة الأمر',
    );
  }
}

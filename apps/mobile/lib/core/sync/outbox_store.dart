/// بوابة التخزين الدائم للطابور.
///
/// كل ما تحت هذه البوابة قابل للاستبدال: التنفيذ الحالي `sqflite`،
/// وقد يصبح `drift` أو PowerSync في Stage 7 (القسم 3 من
/// `ANDROID_OFFLINE_BACKGROUND_SYNC.md` يفوّض اختيار المكتبة للتنفيذ).
/// المنطق فوق البوابة لا يعرف أيًّا منها.
///
/// كل الدوال مقيَّدة بـ`accountId` — ق-101: الحالة المحلية مربوطة
/// بالحساب المصادَق، والدخول بحساب آخر لا يكشف طابور السابق.
library;

import 'command_envelope.dart';
import 'command_type.dart';

/// المعرّف الخادمي المحسوم لكيان أُنشئ محليًا.
class IdMapping {
  const IdMapping({
    required this.localId,
    required this.kind,
    required this.serverId,
    required this.resolvedAt,
    this.matchedExisting = false,
  });

  final String localId;
  final EntityKind kind;
  final String serverId;
  final DateTime resolvedAt;

  /// هل طابق الخادم كيانًا قائمًا بدل إنشاء جديد؟
  ///
  /// `api.create_farmer` تُعيد `already_exists` — منع التكرار في ق-88.
  /// الربط صحيح في الحالتين، لكن الفرق يهم العرض والتشخيص.
  final bool matchedExisting;
}

abstract interface class OutboxStore {
  /// يهيّئ التخزين. يجب أن يُنادى قبل أي عملية أخرى.
  Future<void> initialize();

  /// يُدخل أمرًا جديدًا ويُعيد نسخته المخزَّنة.
  ///
  /// يجب أن يفشل إذا كان `commandId` موجودًا — الفرادة مفروضة في
  /// التخزين لا في الكود، فلا يمكن أن يحمل صفّان نفس المعرّف.
  Future<CommandEnvelope> insert(CommandEnvelope envelope);

  /// يُعيد رقم التسلسل التالي لهذا الحساب.
  ///
  /// تصاعدي ولا يتراجع بعد إعادة تشغيل التطبيق.
  Future<int> nextSequence(String accountId);

  /// كل الأوامر غير المؤكَّدة مرتَّبة بالتسلسل تصاعديًا.
  Future<List<CommandEnvelope>> pendingCommands(String accountId);

  /// أمر واحد بمعرّفه المحلي.
  Future<CommandEnvelope?> commandByLocalId(String accountId, String localId);

  /// كل الأوامر — للعرض والتشخيص.
  Future<List<CommandEnvelope>> allCommands(String accountId);

  /// يحجز الأمر لمحاولة إرسال.
  ///
  /// تحديث شرطي: ينجح فقط إذا كانت الحالة `pending` لحظة التحديث.
  /// يُعيد `false` إذا سبقه غيره — فلا يُرسل الأمر مرتين من حلقتين
  /// متزامنتين، ولا بين التطبيق وعامل خلفي لاحقًا.
  ///
  /// [attemptedAt] يُكتب مع الحجز ليصير للحجز عمر معروف. بدونه لا
  /// يمكن التمييز بين حجز جارٍ الآن وحجزٍ مات التطبيق في منتصفه.
  Future<bool> claim(
    String accountId,
    String localId, {
    required DateTime attemptedAt,
  });

  /// يُحرِّر حجزًا ويُعيد الأمر إلى `pending` مع تسجيل سبب الفشل.
  Future<void> releaseForRetry(
    String accountId,
    String localId, {
    required String error,
    required DateTime attemptedAt,
  });

  /// يثبّت قبول الخادم: الحالة `confirmed` والردّ مخزَّن.
  Future<void> markConfirmed(
    String accountId,
    String localId, {
    required Map<String, Object?> serverResponse,
    required DateTime attemptedAt,
  });

  /// يحوّل الأمر إلى «يحتاج مراجعة» ويخرجه من إعادة المحاولة التلقائية.
  Future<void> markNeedsReview(
    String accountId,
    String localId, {
    required String error,
    required DateTime attemptedAt,
  });

  /// يسجّل ربط معرّف محلي بمعرّف خادمي.
  Future<void> putMapping(String accountId, IdMapping mapping);

  /// يقرأ ربطًا محسومًا، أو `null` إذا لم يُحسم بعد.
  Future<IdMapping?> mapping(
    String accountId,
    String localId,
    EntityKind kind,
  );

  /// كل الروابط المحسومة لهذا الحساب.
  Future<List<IdMapping>> mappings(String accountId);

  /// وقت آخر مزامنة ناجحة، أو `null` إن لم تحدث بعد.
  Future<DateTime?> lastSuccessfulSyncAt(String accountId);

  Future<void> setLastSuccessfulSyncAt(String accountId, DateTime at);

  /// يُغلق التخزين. لا يحذف شيئًا.
  Future<void> close();
}

/// يُرفع عند محاولة إدخال أمر بمعرّف عملية مستخدَم أصلًا.
class DuplicateCommandIdException implements Exception {
  const DuplicateCommandIdException(this.commandId);

  final String commandId;

  @override
  String toString() => 'معرّف عملية مستخدَم أصلًا: $commandId';
}

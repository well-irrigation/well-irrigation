/// نموذج قراءة الجلسة الجارية — القسم 4 من `ACTIVE_SESSION_ARCHITECTURE.md`.
///
/// نموذج واحد تقرأ منه شاشة UX-11 كل ما تعرضه. يُبنى محليًا من طابور
/// العمليات، فيعمل بلا شبكة وبعد موت التطبيق.
///
/// ما فيه وما ليس فيه: الحقول المشتقّة من الأحداث المحفوظة موجودة
/// (الحالة، الزمن، الطاقة، الدفعات المحلية، حالة المزامنة). أما ما لا
/// يملكه الجهاز — أسماء المزارع والأرض والمضخة للعرض — فيأتي من عقد
/// قراءة `api.*` مذكور في القسم 20 بند 2 وغير منفَّذ بعد؛ لذلك يحمل
/// النموذج معرّفات لا أسماء، ولا يخترع نصًّا معروضًا.
library;

import '../sync/sync_status.dart';
import 'session_business_state.dart';
import 'session_segment.dart';
import 'time_integrity.dart';

/// دفعة سُجِّلت على هذا الجهاز.
///
/// القسم 20 من وثيقة أندرويد: قبل قبول الخادم تُعرض «محلية/بانتظار»
/// ولا يقال إنها مُرحَّلة. لذلك يحمل السجل حالتها لا مجرد مبلغها.
class LocalPayment {
  const LocalPayment({
    required this.localId,
    required this.amountMinor,
    required this.paidAt,
    required this.status,
    this.method,
    this.serverId,
  });

  final String localId;
  final int amountMinor;
  final DateTime paidAt;
  final CommandStatus status;
  final String? method;

  /// المعرّف الخادمي بعد القبول، أو `null` قبله.
  final String? serverId;

  /// هل قَبِلها الخادم فعلًا؟
  ///
  /// «مُرحَّلة» تعني معرّفًا خادميًا محسومًا، لا مجرد حالة مؤكَّدة.
  bool get isPosted =>
      status == CommandStatus.confirmed && serverId != null;
}

/// حالة المزامنة المجمَّعة للجلسة — القسم 27 من وثيقة أندرويد.
///
/// مستقلة تمامًا عن [SessionBusinessState] (القسم 3).
enum SessionSyncState {
  /// لم تُحاول أي عملية من الجلسة بعد.
  localOnly,

  /// محفوظة وتنتظر دورها، وقد فشلت محاولة أو أكثر فشلًا عابرًا.
  pending,

  /// محاولة إرسال جارية الآن.
  syncing,

  /// كل عمليات الجلسة قَبِلها الخادم.
  synced,

  /// عملية تحتاج تدخلًا بشريًا (رفض عملي أو صلاحية).
  conflict;

  /// النصّ المعروض — من نصوص ق-108 المعتمدة، بلا صياغة جديدة.
  String get text => switch (this) {
    SessionSyncState.localOnly => SyncStatusText.localDurable,
    SessionSyncState.pending => SyncStatusText.pending,
    SessionSyncState.syncing => SyncStatusText.dispatching,
    SessionSyncState.synced => SyncStatusText.confirmed,
    SessionSyncState.conflict => SyncStatusText.needsReview,
  };
}

class ActiveSessionRecord {
  const ActiveSessionRecord({
    required this.localId,
    required this.accountId,
    required this.startedAt,
    required this.businessState,
    required this.syncState,
    required this.segments,
    required this.totals,
    required this.payments,
    required this.timeIntegrityFlags,
    required this.pendingCommandCount,
    this.serverSessionId,
    this.wellId,
    this.farmReference,
    this.farmerReference,
    this.pumpId,
    this.completedAt,
    this.lastSuccessfulSyncAt,
    this.oldestPendingAt,
  });

  /// معرّف أمر بدء الجلسة. هو أصل الجلسة محليًا ومفتاح استعادتها.
  final String localId;

  /// الحساب المالك (ق-101). جلسة حساب لا تظهر لحساب آخر.
  final String accountId;

  /// معرّف الجلسة على الخادم، أو `null` إن لم يُحسم بعد.
  ///
  /// وجوده هو «server reconciliation marker» في القسم 4.
  final String? serverSessionId;

  final String? wellId;

  /// معرّف الأرض: معرّف خادمي، أو معرّف محلي لأرض أُنشئت بلا اتصال
  /// (القسم 21). لا يُخترع اسم للعرض.
  final String? farmReference;

  final String? farmerReference;
  final String? pumpId;

  final DateTime startedAt;
  final DateTime? completedAt;

  final SessionBusinessState businessState;
  final SessionSyncState syncState;

  final List<SessionSegment> segments;
  final SessionTotals totals;
  final List<LocalPayment> payments;

  final Set<TimeIntegrityFlag> timeIntegrityFlags;

  /// عدد عمليات هذه الجلسة التي لم تصل الخادم بعد.
  final int pendingCommandCount;

  final DateTime? lastSuccessfulSyncAt;

  /// وقت أقدم عملية معلَّقة — القسم 27 يطلب عرضه.
  final DateTime? oldestPendingAt;

  /// المقطع الجاري الآن، أو `null` بعد الإنهاء.
  SessionSegment? get currentSegment =>
      segments.where((segment) => segment.isOpen).firstOrNull;

  /// مصدر الطاقة الحالي — من المقطع الجاري، أو الأخير بعد الإنهاء.
  String? get currentEnergySource =>
      (currentSegment ?? segments.lastOrNull)?.energySource;

  /// سبب التوقف الحالي (القرار 346).
  String? get currentPauseReason {
    final current = currentSegment;

    return current != null && !current.kind.isBillable
        ? current.pauseReason
        : null;
  }

  /// مجموع ما استُلم على هذا الجهاز — بما لم يُقبل خادميًا بعد.
  int get receivedLocallyMinor =>
      payments.fold(0, (sum, payment) => sum + payment.amountMinor);

  /// مجموع ما أثبته الخادم فعلًا.
  int get postedMinor => payments
      .where((payment) => payment.isPosted)
      .fold(0, (sum, payment) => sum + payment.amountMinor);

  /// المتبقي، أو `null` إذا كان المستحق غير قابل للحساب.
  ///
  /// ق-99: لا مقاصّة صامتة. الزيادة على المستحق تظهر سالبة هنا ويعالجها
  /// العرض كرصيد مقدَّم، ولا تُقصَّر إلى صفر في هذه الطبقة.
  int? get remainingMinor {
    final accrued = totals.accruedMinor;

    return accrued == null ? null : accrued - receivedLocallyMinor;
  }

  /// هل خط زمن الجلسة مبرهن؟
  bool get timeIsTrusted => timeIntegrityFlags
      .where((flag) => flag != TimeIntegrityFlag.noServerAnchor)
      .isEmpty;

  String get businessStateText => sessionStateText(businessState);

  /// نصّ المستحق: رقم، أو نصّ الانتظار المعتمد بلا رقم مخمَّن.
  ///
  /// التنسيق (فاصلة الآلاف ولفظ «ريال») شأن طبقة العرض؛ هنا يُحسم فقط
  /// **هل يوجد رقم أصلًا**.
  String? get accruedTextOrPending =>
      totals.pricingPending ? SessionStateText.pricingPending : null;

  @override
  String toString() =>
      'ActiveSessionRecord($localId ${businessState.name}/${syncState.name} '
      'billable=${totals.billableSeconds}s pending=$pendingCommandCount)';
}

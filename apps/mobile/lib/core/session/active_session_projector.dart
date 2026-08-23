/// إعادة بناء الجلسة الجارية من طابور العمليات — القسم 16 «Local recovery».
///
/// **لا جدول جلسات محلي ولا كتابة ثانية.** الطابور يحفظ كل حدث ميداني
/// حفظًا دائمًا مع وقت وقوعه وتسلسله (ق-115)، فالحالة تُعاد **إعادة
/// تشغيل** منه. لهذا سببان لا واحد:
///
/// 1. مصدر واحد للحق. جدول حالة موازٍ يعني كتابتين لكل حدث، وأي انقطاع
///    بينهما يترك حالة تخالف الأحداث المحفوظة — وهو أسوأ من فقدها لأنه
///    يُعرض على المستخدم كأنه صحيح.
/// 2. الاستعادة تصير مجانية. القسم 16 يطلب إعادة بناء الحالة والزمن
///    والطاقة والدفعات بعد Process Death أو Reboot، ويشترط ألّا يُعتمد
///    على `Timer` في الذاكرة. المُسقِط يقرأ القرص ويُخرج الحالة كاملة،
///    فلا فرق بين «التطبيق لم يُغلق» و«الهاتف أُعيد إقلاعه».
///
/// المُسقِط دالة خالصة على مدخلاته: نفس الأوامر ونفس اللحظة ⟹ نفس
/// النتيجة. لا يكتب في المخزن ولا ينادي شبكة.
library;

import '../sync/command_envelope.dart';
import '../sync/command_type.dart';
import '../sync/outbox_store.dart';
import '../sync/sync_status.dart';
import 'active_session_record.dart';
import 'session_segment.dart';
import 'time_integrity.dart';

/// لقطة تسعير محلية — القسم 17 من وثيقة أندرويد.
///
/// السعر الساعي الشامل الذي يُعرض به العدّاد بلا اتصال. إن غابت، تُعرض
/// «التكلفة بانتظار المزامنة» ولا يُخمَّن رقم (القرار 341).
///
/// الخادم يبقى مرجع السعر التاريخي النهائي: يحسمه بوقت الحدث المُرسَل
/// لا بوقت المزامنة (القسم 18)، فقد يخالف هذه اللقطة، وحينها الخادم
/// أصحّ.
class PricingSnapshot {
  const PricingSnapshot({
    required this.hourlyRateMinor,
    required this.effectiveFrom,
    this.energySource,
    this.effectiveTo,
    this.ruleId,
  });

  final int hourlyRateMinor;
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;

  /// مصدر الطاقة الذي تنطبق عليه، أو `null` لسعر عام لكل المصادر.
  final String? energySource;

  final String? ruleId;

  bool appliesAt(DateTime at, {String? energySource}) {
    if (this.energySource != null && this.energySource != energySource) {
      return false;
    }

    if (at.isBefore(effectiveFrom)) {
      return false;
    }

    final until = effectiveTo;

    return until == null || at.isBefore(until);
  }
}

/// يحسم سعر مقطع من لقطات التسعير المحفوظة.
///
/// الحسم **بوقت بداية المقطع** لا بالوقت الحالي: مقطع بدأ أمس يُسعَّر
/// بسعر أمس، وهي نفس قاعدة القسم 18 التي يطبّقها الخادم.
class PricingResolver {
  const PricingResolver(this.snapshots);

  const PricingResolver.none() : snapshots = const [];

  final List<PricingSnapshot> snapshots;

  int? rateFor(DateTime at, {String? energySource}) {
    for (final snapshot in snapshots) {
      if (snapshot.appliesAt(at, energySource: energySource)) {
        return snapshot.hourlyRateMinor;
      }
    }

    return null;
  }
}

/// مرساة الجلسة مع قراءة الجهاز الحالية — القسم 19.
///
/// الاثنان معًا لا أحدهما: المرساة تقول «من أين» والقراءة تقول «كم
/// انقضى». لو اشتُقت القراءة من ساعة الحائط لصار العلم مستحيلًا، لأن
/// المقارنة ستكون بين الرقم ونفسه.
class SessionTimeContext {
  const SessionTimeContext({required this.anchor, required this.reading});

  final SessionTimeAnchor anchor;
  final TimeReading reading;
}

class ActiveSessionProjector {
  const ActiveSessionProjector({
    required this.store,
    this.pricing = const PricingResolver.none(),
  });

  final OutboxStore store;
  final PricingResolver pricing;

  /// كل الجلسات غير المنتهية لهذا الحساب.
  ///
  /// عادةً واحدة (البئر لا تسقي أرضين معًا)، لكن الحساب الواحد قد يملك
  /// عدة آبار وفق ق-84 — فالجمع لا الإفراد.
  Future<List<ActiveSessionRecord>> activeSessions(
    String accountId, {
    required DateTime now,
    Map<String, SessionTimeContext> timeContexts = const {},
  }) async {
    final all = await projectAll(
      accountId,
      now: now,
      timeContexts: timeContexts,
    );

    return all
        .where((session) => session.businessState.isActive)
        .toList();
  }

  /// جلسة واحدة بمعرّف أمر بدئها.
  Future<ActiveSessionRecord?> projectSession(
    String accountId,
    String startCommandLocalId, {
    required DateTime now,
    SessionTimeContext? timeContext,
  }) async {
    final all = await projectAll(
      accountId,
      now: now,
      timeContexts: timeContext == null
          ? const {}
          : {startCommandLocalId: timeContext},
    );

    return all
        .where((session) => session.localId == startCommandLocalId)
        .firstOrNull;
  }

  /// يُسقِط كل جلسات الحساب من الطابور.
  Future<List<ActiveSessionRecord>> projectAll(
    String accountId, {
    required DateTime now,
    Map<String, SessionTimeContext> timeContexts = const {},
  }) async {
    final commands = await store.allCommands(accountId);
    final mappings = await store.mappings(accountId);
    final lastSync = await store.lastSuccessfulSyncAt(accountId);

    final serverIdByLocalId = <String, IdMapping>{
      for (final mapping in mappings) mapping.localId: mapping,
    };

    // تجميع بالأصل: أوامر الجلسة الواحدة تحمل `aggregateLocalId` يشير
    // إلى أمر بدئها (القسم 6). ترتيب `allCommands` بالتسلسل مضمون من
    // المخزن، ونحافظ عليه.
    final byAggregate = <String, List<CommandEnvelope>>{};

    for (final command in commands) {
      if (command.type == CommandType.startIrrigationSession) {
        byAggregate.putIfAbsent(command.localId, () => []).add(command);
        continue;
      }

      final aggregate = command.aggregateLocalId;

      if (aggregate != null && _isSessionScoped(command.type)) {
        byAggregate.putIfAbsent(aggregate, () => []).add(command);
      }
    }

    final sessions = <ActiveSessionRecord>[];

    for (final entry in byAggregate.entries) {
      final start = entry.value
          .where((c) => c.type == CommandType.startIrrigationSession)
          .firstOrNull;

      // مجموعة بلا أمر بدء تعني أوامر تابعة لأصل حُذف أو لم يُسجَّل.
      // لا تُخترع لها جلسة.
      if (start == null) {
        continue;
      }

      sessions.add(
        _project(
          accountId: accountId,
          start: start,
          events: entry.value,
          now: now,
          timeContext: timeContexts[start.localId],
          serverIdByLocalId: serverIdByLocalId,
          lastSync: lastSync,
        ),
      );
    }

    sessions.sort((a, b) => a.startedAt.compareTo(b.startedAt));

    return sessions;
  }

  ActiveSessionRecord _project({
    required String accountId,
    required CommandEnvelope start,
    required List<CommandEnvelope> events,
    required DateTime now,
    required SessionTimeContext? timeContext,
    required Map<String, IdMapping> serverIdByLocalId,
    required DateTime? lastSync,
  }) {
    final ordered = [...events]
      ..sort((a, b) => a.sequence.compareTo(b.sequence));

    final flags = <TimeIntegrityFlag>{}
      ..addAll(
        checkEventOrdering([for (final e in ordered) e.occurredAt]),
      );

    // «الآن» المستخدَم في العدّاد الجاري. بلا سياق زمني نستخدم [now] كما
    // وصل — الاستعادة يجب أن تنجح على جلسة قديمة سُجِّلت قبل أن توجد
    // المراسي، ولا تُسقَط لغياب حقل.
    var effectiveNow = now.toUtc();

    if (timeContext != null) {
      final resolved = resolveNow(
        anchor: timeContext.anchor,
        reading: timeContext.reading,
      );

      effectiveNow = resolved.at;
      flags.addAll(resolved.flags);
    }

    final segments = <SessionSegment>[];
    final payments = <LocalPayment>[];

    DateTime? completedAt;
    var energySource = start.payload['p_energy_source'] as String?;

    void openSegment(
      SegmentKind kind,
      DateTime at, {
      String? pauseReason,
    }) {
      segments.add(
        SessionSegment(
          kind: kind,
          startedAt: at,
          energySource: energySource,
          hourlyRateMinor: kind.isBillable
              ? pricing.rateFor(at, energySource: energySource)
              : null,
          pauseReason: pauseReason,
        ),
      );
    }

    /// يُغلق المقطع المفتوح عند [at].
    ///
    /// وقت إغلاق أسبق من بداية المقطع يُثبَّت على البداية (مقطع صفري)
    /// ويُرفع علم الترتيب — لا مدة سالبة تُطرح من مستحق المزارع.
    void closeOpenSegment(DateTime at) {
      final index = segments.lastIndexWhere((segment) => segment.isOpen);

      if (index < 0) {
        return;
      }

      final open = segments[index];
      final safeAt = at.isBefore(open.startedAt) ? open.startedAt : at;

      if (safeAt != at) {
        flags.add(TimeIntegrityFlag.impossibleEventOrdering);
      }

      segments[index] = open.closedAt(safeAt);
    }

    for (final command in ordered) {
      final at = command.occurredAt.toUtc();

      switch (command.type) {
        case CommandType.startIrrigationSession:
          openSegment(SegmentKind.running, at);

        case CommandType.pauseIrrigationSession:
          closeOpenSegment(at);
          openSegment(
            SegmentKind.paused,
            at,
            pauseReason: command.payload['p_reason'] as String?,
          );

        case CommandType.resumeIrrigationSession:
          closeOpenSegment(at);
          openSegment(SegmentKind.running, at);

        case CommandType.changeSessionEnergySource:
          // تغيير الطاقة يُغلق مقطعًا ويفتح آخر بالمصدر الجديد، لأن
          // مصدر الطاقة خاصية مقطع لا خاصية جلسة (ق-100). النوع يُحفظ:
          // تغيير الطاقة أثناء التوقف لا يستأنف السقي.
          final openIndex = segments.lastIndexWhere((s) => s.isOpen);
          final previousKind = openIndex >= 0
              ? segments[openIndex].kind
              : (segments.lastOrNull?.kind ?? SegmentKind.running);

          closeOpenSegment(at);
          energySource =
              command.payload['p_new_source'] as String? ?? energySource;
          openSegment(previousKind, at);

        case CommandType.completeIrrigationSession:
          closeOpenSegment(at);
          completedAt = at;

        case CommandType.recordPayment:
          final mapping = serverIdByLocalId[command.localId];

          payments.add(
            LocalPayment(
              localId: command.localId,
              amountMinor: (command.payload['p_amount_minor'] as num?)?.toInt() ?? 0,
              paidAt: at,
              status: command.status,
              method: command.payload['p_method'] as String?,
              serverId: mapping?.serverId,
            ),
          );

        case CommandType.createFarmer:
        case CommandType.createFarm:
          // كيانات مرجعية، ليست أحداث جلسة. لا تُنشئ مقطعًا.
          break;
      }
    }

    final pendingCommands = ordered
        .where((command) => command.status != CommandStatus.confirmed)
        .toList();

    return ActiveSessionRecord(
      localId: start.localId,
      accountId: accountId,
      serverSessionId: serverIdByLocalId[start.localId]?.serverId,
      wellId: start.wellId ?? start.payload['p_well_id'] as String?,
      farmReference: _referenceOrId(start.payload['p_farm_id']),
      farmerReference: _referenceOrId(
        start.payload['p_farmer_well_account_id'],
      ),
      pumpId: _referenceOrId(start.payload['p_pump_id']),
      startedAt: start.occurredAt.toUtc(),
      completedAt: completedAt,
      businessState: stateFromSegments(
        segments,
        completed: completedAt != null,
      ),
      syncState: _syncStateOf(ordered),
      segments: List.unmodifiable(segments),
      totals: summarize(segments, effectiveNow),
      payments: List.unmodifiable(payments),
      timeIntegrityFlags: Set.unmodifiable(flags),
      pendingCommandCount: pendingCommands.length,
      lastSuccessfulSyncAt: lastSync,
      oldestPendingAt: pendingCommands.firstOrNull?.occurredAt,
    );
  }

  /// هل النوع حدثًا على جلسة قائمة، أو دفعةً في سياقها؟
  ///
  /// الدفعة معرَّفة ببئر لا بجلسة (`p_well_id`)، لكن دفعة سياق الجلسة
  /// تُعرض على شاشتها وتُخصَّص لفاتورتها (ق-92). ارتباطها بالجلسة يأتي
  /// من `aggregateLocalId` الذي كتبه المُدخِل.
  static bool _isSessionScoped(CommandType type) =>
      type.scope == CommandScope.session || type == CommandType.recordPayment;

  /// أعلى حالة مزامنة في أوامر الجلسة، بأولوية القسم 32.
  ///
  /// الترتيب مقصود: التعارض أولًا، ثم الإرسال الجاري، ثم الانتظار. محاولة
  /// فاشلة واحدة لا ترفع الحالة إلى حرجة — تبقى «بانتظار المزامنة».
  static SessionSyncState _syncStateOf(List<CommandEnvelope> commands) {
    if (commands.any((c) => c.status == CommandStatus.review)) {
      return SessionSyncState.conflict;
    }

    if (commands.any((c) => c.status == CommandStatus.dispatching)) {
      return SessionSyncState.syncing;
    }

    final unconfirmed = commands
        .where((c) => c.status != CommandStatus.confirmed)
        .toList();

    if (unconfirmed.isEmpty) {
      return SessionSyncState.synced;
    }

    // لم تُحاول أي عملية بعد ⟹ «محفوظ على الجهاز»، وهو نصّ أدقّ من
    // «بانتظار المزامنة» في أول لحظة بعد الحفظ (القسم 15).
    return unconfirmed.every((c) => !c.wasAttempted)
        ? SessionSyncState.localOnly
        : SessionSyncState.pending;
  }

  /// يُخرِج معرّفًا معروضًا من قيمة قد تكون مرجعًا محليًا غير محسوم.
  static String? _referenceOrId(Object? value) {
    if (value is String) {
      return value;
    }

    if (value is Map) {
      return value[r'$ref'] as String?;
    }

    return null;
  }
}

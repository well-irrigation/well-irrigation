/// حلقة الإرسال المرتَّبة.
///
/// ما يفعله في كل تشغيل:
///
/// 1. يستعيد الحجوزات الميتة (حجزٌ مات التطبيق في منتصفه).
/// 2. يمرّ على الأوامر غير المؤكَّدة بترتيب `sequence`.
/// 3. يتخطى كل أمر ما زال مرجعٌ من مراجعه غير محسوم (القسم 22).
/// 4. يحجز الأمر بتحديث شرطي، فلا يُرسل مرتين من حلقتين متزامنتين.
/// 5. يستبدل المراجع بالمعرّفات الخادمية ويُرسل بمعرّف العملية الثابت.
/// 6. يوقف أصلًا كاملًا عند أول أمر لم يُحسم فيه، ويتابع أصولًا أخرى.
///
/// ما لا يفعله: لا يولّد معرّفات (لا يملك مولّدًا)، ولا يكتب على
/// `commandId`، ولا يُرسل وقتًا غير وقت الحدث المحفوظ.
///
/// الحلقة تعمل عند فتح التطبيق وكذلك من عامل خلفي بلا فتح التطبيق
/// (ق-117). الحجز الشرطي هو ما يجعل الحالتين آمنتين معًا بلا إعادة
/// تصميم (القسم 35).
library;

import 'command_envelope.dart';
import 'command_reference.dart';
import 'command_transport.dart';
import 'outbox_store.dart';
import 'sync_status.dart';

/// حصيلة تشغيل واحد للحلقة.
class SyncRunReport {
  const SyncRunReport({
    this.attempted = 0,
    this.confirmed = 0,
    this.retryScheduled = 0,
    this.needsReview = 0,
    this.skipped = 0,
    this.blockedByReview = 0,
    this.recoveredClaims = 0,
    this.alreadyRunning = false,
  });

  /// عدد الأوامر التي حُجزت وأُرسلت فعلًا.
  final int attempted;

  /// قَبِلها الخادم (أو أعاد نتيجتها المخزونة لأنها مكرَّرة).
  final int confirmed;

  /// فشلت لسبب عابر وبقيت في الطابور.
  final int retryScheduled;

  /// تحتاج تدخلًا بشريًا.
  final int needsReview;

  /// لم تُحاول: مرجع غير محسوم، أو أصلٌ موقوف، أو سبقها غيرها للحجز.
  final int skipped;

  /// من [skipped]: ما لا يمكن أن يتحرك إلا بقرار إنسان.
  ///
  /// أمرٌ صار `review` يوقف أصله كله، والأوامر التي تشير إليه لن تُحلّ
  /// مراجعها أبدًا بلا تدخل. عدّها منفصلةً هو ما يمنع العامل الخلفي من
  /// إعادة المحاولة إلى الأبد على شيء لا تُصلحه شبكة (ق-90 بند 20).
  final int blockedByReview;

  /// حجوزات ميتة أُعيدت إلى الطابور.
  final int recoveredClaims;

  /// كانت هناك حلقة تعمل، فلم تبدأ حلقة ثانية.
  final bool alreadyRunning;

  bool get hasPendingWork => retryScheduled > 0 || skipped > 0;

  /// هل بقي عملٌ قد ينجح وحده لو أُعيدت المحاولة لاحقًا؟
  ///
  /// هذا وحده مبرِّر إعادة الجدولة. `skipped` كلها موقوفة على إنسان
  /// يعني: لا تُوقظ الهاتف مرة أخرى بلا فائدة.
  bool get canRetryWithoutHelp =>
      retryScheduled > 0 || skipped > blockedByReview;

  /// هل يوجد ما ينتظر قرار إنسان؟ (يظهر للمستخدم، ولا يُعاد تلقائيًا.)
  bool get awaitsHumanDecision => needsReview > 0 || blockedByReview > 0;

  @override
  String toString() =>
      'SyncRunReport(attempted=$attempted confirmed=$confirmed '
      'retry=$retryScheduled review=$needsReview skipped=$skipped '
      'blockedByReview=$blockedByReview recovered=$recoveredClaims)';
}

/// سبب توقّف الإرسال في أصل معيّن داخل تشغيل واحد.
enum _BlockReason {
  /// سبب عابر: شبكة، أو حجزٌ سبقنا إليه غيرنا، أو مرجع سيُحلّ بنفسه.
  transient,

  /// موقوف على قرار إنسان — لا تُعيد المحاولة تلقائيًا.
  awaitingReview,
}

class SyncEngine {
  SyncEngine({
    required this._store,
    required this._transport,
    DateTime Function()? clock,
    this.staleClaimTimeout = const Duration(minutes: 2),
  }) : _clock = clock ?? DateTime.now;

  final OutboxStore _store;
  final CommandTransport _transport;
  final DateTime Function() _clock;

  /// المدة التي يُعتبر بعدها الحجز ميتًا فيُعاد إلى الطابور.
  ///
  /// حجزٌ عمره أقل من ذلك يُفترض أنه محاولة جارية الآن، فلا يُمَس —
  /// وإلا لأرسلت حلقة ثانية نفس الأمر بالتوازي.
  final Duration staleClaimTimeout;

  Future<SyncRunReport>? _inFlight;

  /// هل هناك تشغيل جارٍ الآن؟
  bool get isRunning => _inFlight != null;

  /// يشغّل الحلقة مرة واحدة لهذا الحساب.
  ///
  /// نداء ثانٍ أثناء تشغيل جارٍ لا يبدأ حلقة ثانية — يُعيد تقريرًا
  /// بـ`alreadyRunning`. الحماية الحقيقية من الإرسال المزدوج هي الحجز
  /// الشرطي في التخزين، وهذا مجرد توفير عمل.
  Future<SyncRunReport> run(String accountId) {
    final running = _inFlight;

    if (running != null) {
      return Future.value(const SyncRunReport(alreadyRunning: true));
    }

    final started = _run(accountId);
    _inFlight = started;

    return started.whenComplete(() => _inFlight = null);
  }

  Future<SyncRunReport> _run(String accountId) async {
    final recovered = await _recoverStaleClaims(accountId);

    var attempted = 0;
    var confirmed = 0;
    var retryScheduled = 0;
    var needsReview = 0;
    var skipped = 0;
    var blockedByReview = 0;

    /// الأصول التي توقّف إرسالها في هذا التشغيل، ومعها سبب التوقف.
    ///
    /// أول أمر لم يُحسم في أصل يوقف كل ما بعده فيه: لا يُرسل استئناف
    /// لجلسة لم يُحسم إيقافها. أصول أخرى تكمل بلا تأثر (القسم 6).
    /// والسبب محفوظ لأن «موقوف على الشبكة» و«موقوف على إنسان» يقودان
    /// إلى قرارين مختلفين تمامًا في العامل الخلفي.
    final blockedAggregates = <String, _BlockReason>{};

    void block(String aggregate, _BlockReason reason) {
      blockedAggregates[aggregate] = reason;
    }

    for (final command in await _store.pendingCommands(accountId)) {
      final aggregate = command.effectiveAggregateId;
      final blockedBy = blockedAggregates[aggregate];

      if (blockedBy != null) {
        skipped += 1;

        if (blockedBy == _BlockReason.awaitingReview) {
          blockedByReview += 1;
        }

        continue;
      }

      // أمرٌ يحتاج مراجعة يوقف أصله: حالة الجلسة على الخادم غير
      // معروفة، وإرسال حدث لاحق عليها يفاقم اللبس لا يحلّه.
      if (command.status == CommandStatus.review) {
        block(aggregate, _BlockReason.awaitingReview);
        skipped += 1;
        blockedByReview += 1;
        continue;
      }

      final resolution = await _resolvePayload(accountId, command);
      final resolved = resolution.payload;

      if (resolved == null) {
        block(aggregate, resolution.reason);
        skipped += 1;

        if (resolution.reason == _BlockReason.awaitingReview) {
          blockedByReview += 1;
        }

        continue;
      }

      final attemptedAt = _clock().toUtc();
      final claimed = await _store.claim(
        accountId,
        command.localId,
        attemptedAt: attemptedAt,
      );

      if (!claimed) {
        // سبقنا إليه غيرنا — حلقة أخرى أو عامل خلفي. لا نلمسه ولا
        // نُرسل بعده في أصله، فترتيبه ما زال مضمونًا.
        block(aggregate, _BlockReason.transient);
        skipped += 1;
        continue;
      }

      attempted += 1;

      final result = await _transport.dispatch(
        DispatchRequest(
          type: command.type,
          commandId: command.commandId,
          arguments: buildRpcArguments(
            type: command.type,
            commandId: command.commandId,
            occurredAt: command.occurredAt,
            resolvedPayload: resolved,
          ),
        ),
      );

      switch (result) {
        case final DispatchAccepted accepted:
          await _confirm(accountId, command, accepted, attemptedAt);
          confirmed += 1;

        case final DispatchFailed failure when failure.isRetryable:
          await _store.releaseForRetry(
            accountId,
            command.localId,
            error: failure.message,
            attemptedAt: attemptedAt,
          );
          block(aggregate, _BlockReason.transient);
          retryScheduled += 1;

        case final DispatchFailed failure:
          await _store.markNeedsReview(
            accountId,
            command.localId,
            error: failure.message,
            attemptedAt: attemptedAt,
          );
          block(aggregate, _BlockReason.awaitingReview);
          needsReview += 1;
      }
    }

    if (confirmed > 0) {
      await _store.setLastSuccessfulSyncAt(accountId, _clock().toUtc());
    }

    return SyncRunReport(
      attempted: attempted,
      confirmed: confirmed,
      retryScheduled: retryScheduled,
      needsReview: needsReview,
      skipped: skipped,
      blockedByReview: blockedByReview,
      recoveredClaims: recovered,
    );
  }

  /// يُعيد الحجوزات الميتة إلى الطابور.
  ///
  /// الحالة: الخادم نفّذ العملية ثم مات التطبيق قبل تسجيل التأكيد.
  /// الصفّ باقٍ `dispatching` إلى الأبد لو لم يُستعد. بعد استعادته
  /// يُرسل ثانيةً **بنفس معرّف العملية**، فيعيد الخادم النتيجة
  /// المخزونة بلا تنفيذ ثانٍ (ق-114) — سجل واحد ومبلغ واحد.
  Future<int> _recoverStaleClaims(String accountId) async {
    final now = _clock().toUtc();
    var recovered = 0;

    for (final command in await _store.pendingCommands(accountId)) {
      if (command.status != CommandStatus.dispatching) {
        continue;
      }

      final lastAttemptAt = command.lastAttemptAt;
      final isStale =
          lastAttemptAt == null ||
          now.difference(lastAttemptAt) >= staleClaimTimeout;

      if (!isStale) {
        continue;
      }

      await _store.releaseForRetry(
        accountId,
        command.localId,
        error: 'انقطعت محاولة إرسال سابقة قبل ظهور نتيجتها',
        attemptedAt: lastAttemptAt ?? now,
      );

      recovered += 1;
    }

    return recovered;
  }

  /// يستبدل مراجع الحمولة بالمعرّفات الخادمية، أو يشرح سبب التعذّر.
  Future<_PayloadResolution> _resolvePayload(
    String accountId,
    CommandEnvelope command,
  ) async {
    final references = command.references;

    if (references.isEmpty) {
      return _PayloadResolution.ready(command.payload);
    }

    final resolutions = <CommandReference, String>{};

    for (final reference in references) {
      final mapping = await _store.mapping(
        accountId,
        reference.localId,
        reference.kind,
      );

      if (mapping == null) {
        // المرجع غير محسوم. الفرق الحاسم: هل الأمر المُشار إليه ما زال
        // في طريقه إلى الخادم، أم صار «مراجعة» فلن يُحسم أبدًا وحده؟
        // في الحالة الثانية إعادة المحاولة استهلاك بطارية بلا نتيجة.
        final source = await _store.commandByLocalId(
          accountId,
          reference.localId,
        );

        return _PayloadResolution.blocked(
          source?.status == CommandStatus.review
              ? _BlockReason.awaitingReview
              : _BlockReason.transient,
        );
      }

      resolutions[reference] = mapping.serverId;
    }

    final resolved = resolveReferences(
      command.payload,
      (reference) => resolutions[reference],
    );

    return _PayloadResolution.ready(Map<String, Object?>.from(resolved as Map));
  }

  Future<void> _confirm(
    String accountId,
    CommandEnvelope command,
    DispatchAccepted result,
    DateTime attemptedAt,
  ) async {
    final produces = command.type.produces;
    final entityId = result.entityId;

    // الربط الدائم محلي→خادمي (ق-115). يُكتب قبل التأكيد: لو مات
    // التطبيق بينهما، الأمر يُرسل ثانيةً ويعيد الخادم نفس المعرّف،
    // فيُكتب نفس الربط. لو كُتب التأكيد أولًا وضاع الربط، لبقيت
    // الأوامر التابعة بلا معرّف أصلها إلى الأبد.
    if (produces != null && entityId != null) {
      await _store.putMapping(
        accountId,
        IdMapping(
          localId: command.localId,
          kind: produces,
          serverId: entityId,
          resolvedAt: attemptedAt,
          matchedExisting: result.matchedExisting,
        ),
      );
    }

    await _store.markConfirmed(
      accountId,
      command.localId,
      serverResponse: result.response,
      attemptedAt: attemptedAt,
    );
  }
}

/// نتيجة محاولة حلّ حمولة أمر: جاهزة، أو موقوفة ومعها السبب.
class _PayloadResolution {
  const _PayloadResolution.ready(this.payload)
    : reason = _BlockReason.transient;

  const _PayloadResolution.blocked(this.reason) : payload = null;

  final Map<String, Object?>? payload;
  final _BlockReason reason;
}

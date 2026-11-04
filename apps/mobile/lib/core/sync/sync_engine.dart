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

import 'dart:async';
import '../session/manual_stop_request_store.dart';
import 'booking_start_receipt.dart';
import 'command_intent_policy.dart';

import '../booking/booking_reactivity.dart';
import 'background_sync_policy.dart';
import 'retry_classification.dart';
import 'command_envelope.dart';
import 'command_reference.dart';
import 'command_transport.dart';
import 'command_type.dart';
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
    this.farmMappingsCreated = 0,
    this.farmResultsChanged = false,
    this.bookingNextWake,
    this.bookingRetryDelay,
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

  final int farmMappingsCreated;
  final bool farmResultsChanged;
  final DateTime? bookingNextWake;
  final Duration? bookingRetryDelay;

  bool get hasPendingWork => retryScheduled > 0 || skipped > 0;

  /// هل بقي عملٌ قد ينجح وحده لو أُعيدت المحاولة لاحقًا؟
  ///
  /// هذا وحده مبرِّر إعادة الجدولة. `skipped` كلها موقوفة على إنسان
  /// يعني: لا تُوقظ الهاتف مرة أخرى بلا فائدة.
  bool get canRetryWithoutHelp =>
      retryScheduled > 0 || skipped > blockedByReview || bookingNextWake != null;

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

  final Map<String, Future<SyncRunReport>> _inFlight = {};
  final Map<String, Future<SyncRunReport>> _bookingInFlight = {};
  static const maxBookingBatch = 20;
  static const maxBookingWells = 3;
  static const bookingAttemptTimeout = Duration(seconds: 60);

  /// هل هناك تشغيل جارٍ الآن؟
  bool get isRunning => _inFlight.isNotEmpty;

  /// يشغّل الحلقة مرة واحدة لهذا الحساب.
  ///
  /// نداء ثانٍ أثناء تشغيل جارٍ لا يبدأ حلقة ثانية — يُعيد تقريرًا
  /// بـ`alreadyRunning`. الحماية الحقيقية من الإرسال المزدوج هي الحجز
  /// الشرطي في التخزين، وهذا مجرد توفير عمل.
  Future<SyncRunReport> run(String accountId) {
    final running = _inFlight[accountId];

    if (running != null) {
      return Future.value(const SyncRunReport(alreadyRunning: true));
    }

    final started = _run(accountId);
    _inFlight[accountId] = started;

    return started.whenComplete(() => _inFlight.remove(accountId));
  }

  final _runtimeFollowups = <String, Future<SyncRunReport>>{};

  /// فرصة إرسال معروفة واحدة بعد المرسل الجاري، بلا مؤقت أو قرار تشغيل.
  Future<SyncRunReport> runAfterCurrent(String accountId) {
    final prior = _runtimeFollowups[accountId];
    if (prior != null) return prior;
    final running = _inFlight[accountId];
    if (running == null) return run(accountId);
    late Future<SyncRunReport> work;
    work =
        () async {
          try {
            await running;
          } on Object {
            /* الأصل المتين ينتظر فرصة الإرسال الحالية. */
          }
          return run(accountId);
        }().whenComplete(() {
          if (identical(_runtimeFollowups[accountId], work)) {
            _runtimeFollowups.remove(accountId);
          }
        });
    _runtimeFollowups[accountId] = work;
    return work;
  }

  Future<SyncRunReport> _run(String accountId) async {
    await _store.initialize();
    final blockedStops = await ManualStopRequestStore(_store).recoverRecordedRequests(accountId);
    final recovered = await _recoverStaleClaims(accountId);

    var attempted = 0;
    var confirmed = 0;
    var retryScheduled = 0;
    var needsReview = 0;
    var skipped = blockedStops;
    var blockedByReview = blockedStops;
    var farmMappingsCreated = 0;
    var farmResultsChanged = false;

    var unblockedByResolver = false;
    const maxPasses = 2;

    for (var pass = 0; pass < maxPasses; pass++) {
      if (pass > 0 && !unblockedByResolver) {
        break;
      }
      if (pass > 0) {
        // إعادة تصفير المتخطى للمرور الإضافي لأن الأوامر غير المحسومة وحدها تُحسب
        skipped = blockedStops;
        blockedByReview = blockedStops;
      }
      unblockedByResolver = false;

      /// الأصول التي توقّف إرسالها في هذا المرور، ومعها سبب التوقف.
      ///
      /// أول أمر لم يُحسم في أصل يوقف كل ما بعده فيه: لا يُرسل استئناف
      /// لجلسة لم يُحسم إيقافها. أصول أخرى تكمل بلا تأثر (القسم 6).
      final blockedAggregates = <String, _BlockReason>{};

      void block(String aggregate, _BlockReason reason) {
        blockedAggregates[aggregate] = reason;
      }

      for (final command in await _legacyPending(accountId)) {
        final aggregate = command.effectiveAggregateId;
        if (q137OperationalCommand(command.type)) {
          if (blockedAggregates.containsKey(aggregate)) {
            skipped++;
            blockedByReview++;
            continue;
          }
          final result = await _runOperational(command);
          if (result == _OperationalResult.confirmed) {
            confirmed++;
          } else if (result == _OperationalResult.sent) {
            attempted++;
            confirmed++;
          } else if (result == _OperationalResult.rejected) {
            attempted++;
            needsReview++;
            block(aggregate, _BlockReason.awaitingReview);
          } else {
            skipped++;
            blockedByReview++;
            block(aggregate, _BlockReason.awaitingReview);
          }
          continue;
        }
        final blockedBy = blockedAggregates[aggregate];

        // فحص استثنائي ضيق: أمر حسم هوية المزارع هو الوحيد المخوّل بفك حظر المراجعة لأصله
        final isAuthorizedResolver =
            command.type == CommandType.resolveFarmerIdentity &&
            await _isAuthorizedFarmerResolver(accountId, command);

        if (blockedBy != null && !isAuthorizedResolver) {
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

        var dependencyPending = false;
        var dependencyInvalid = false;
        for (final localId in command.prerequisites) {
          CommandEnvelope? prerequisite;
          try {
            prerequisite = await _store.commandByLocalId(accountId, localId);
          } on Object {
            dependencyInvalid = true;
          }
          if (prerequisite == null ||
              localId == command.localId ||
              prerequisite.sequence >= command.sequence ||
              prerequisite.status == CommandStatus.review) {
            dependencyInvalid = true;
          } else if (prerequisite.status != CommandStatus.confirmed) {
            dependencyPending = true;
          }
        }
        if (dependencyInvalid) {
          await _store.markNeedsReview(
            accountId,
            command.localId,
            error: 'local_prerequisite_requires_review',
            attemptedAt: _clock().toUtc(),
          );
          block(aggregate, _BlockReason.awaitingReview);
          needsReview += 1;
          continue;
        }
        if (dependencyPending) {
          block(aggregate, _BlockReason.transient);
          skipped += 1;
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
            accountId: command.accountId,
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
            if (command.type == CommandType.resolveFarmerIdentity) {
              await _confirmFarmerResolution(
                accountId,
                command,
                accepted,
                attemptedAt,
              );
              blockedAggregates.remove(aggregate);
              unblockedByResolver = true;
            } else {
              await _confirm(accountId, command, accepted, attemptedAt);
            }
            if (command.type == CommandType.createFarm) {
              farmMappingsCreated++;
              farmResultsChanged = true;
            }
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
            if (command.type == CommandType.createFarm) farmResultsChanged = true;
            await _store.markNeedsReview(
              accountId,
              command.localId,
              error: failure.message,
              attemptedAt: attemptedAt,
              serverResponse: failure.serverResponse,
            );
            block(aggregate, _BlockReason.awaitingReview);
            needsReview += 1;
        }
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
      farmMappingsCreated: farmMappingsCreated,
      farmResultsChanged: farmResultsChanged,
    );
  }

  Future<_OperationalResult> _runOperational(CommandEnvelope candidate) async {
    if (const {CommandType.recordBookingTransitionDecision,
      CommandType.executePendingBookingStart, CommandType.endBookingTransitionChain}.contains(candidate.type)) {
      await _holdOperational(candidate, 'retired_transition_write_disabled');
      return _OperationalResult.held;
    }
    final storage = _store;
    if (storage is! AtomicCommandDispatchStore || candidate.wellId == null) {
      return _OperationalResult.held;
    }
    final atomic = storage as AtomicCommandDispatchStore;
    final row = await storage.commandByLocalId(
      candidate.accountId,
      candidate.localId,
    );
    if (row == null) return _OperationalResult.held;
    if (row.status == CommandStatus.confirmed) {
      return _OperationalResult.confirmed;
    }
    final previousRaw = await storage.readBundle(
      row.accountId,
      dispatchAttemptCurrentKey(row.localId),
    );
    final previous = DispatchAttempt.parse(previousRaw);
    // A finalized business rejection is not an unknown execution result.
    if (row.status == CommandStatus.review &&
        (row.serverResponse != null || previous?.state == DispatchAttemptState.review)) {
      await _holdOperational(row, 'terminal_result_requires_review');
      return _OperationalResult.held;
    }
    final definitelyNotSent =
        row.status == CommandStatus.pending &&
        previous != null &&
        previous.matches(row) &&
        previous.state == DispatchAttemptState.retryRequested &&
        previous.reason == 'q137_preflight_not_sent';
    final produced = row.type.produces;
    final hasAcceptedIdentity =
        produced != null &&
        await storage.mapping(row.accountId, row.localId, produced) != null;
    final uncertain =
        hasAcceptedIdentity ||
        !definitelyNotSent &&
            (row.status == CommandStatus.dispatching ||
                row.lastAttemptAt != null ||
                row.retryCount > 0 ||
                row.serverResponse != null ||
                previousRaw != null);
    if (row.type == CommandType.startBookingSession && uncertain) {
      final transport = _transport;
      final request = BookingStartReceiptRequest.fromCommand(row);
      if (request == null || transport is! BookingStartReceiptTransport) {
        return _OperationalResult.held;
      }
      try {
        final response = await (transport as BookingStartReceiptTransport)
            .readBookingStartReceipt(request);
        if (response case BookingStartReceiptResponse(
          state: BookingStartReceiptState.accepted, receipt: final receipt?,
        )) {
          if (validBookingStartReceipt(request, receipt) &&
              await atomic.reconcileBookingStartReceipt(row, receipt)) {
            return _OperationalResult.confirmed;
          }
        }
      } on Object {
        // A read failure never proves that execution did not happen.
      }
      await _holdOperational(row, 'start_reconciliation_pending');
      return _OperationalResult.held;
    }
    if (row.type == CommandType.completeIrrigationSession && uncertain) {
      final transport = _transport;
      final root = row.aggregateLocalId;
      final mapping = root == null
          ? null
          : await storage.mapping(row.accountId, root, EntityKind.session);
      if (transport is! CompletionReceiptTransport || mapping == null) {
        return _OperationalResult.held;
      }
      final originalSession = row.payload['p_session_id'];
      final bound = originalSession is Map
          ? originalSession.length == 2 &&
                originalSession[r'$ref'] == root &&
                originalSession[r'$kind'] == 'session'
          : originalSession == mapping.serverId;
      if (!bound) {
        await _holdOperational(row, 'completion_session_link_unproven');
        return _OperationalResult.held;
      }
      final request = CompletionReceiptRequest(
        accountId: row.accountId,
        wellId: row.wellId!,
        sessionId: mapping.serverId,
        commandId: row.commandId,
        commandType: row.type.rpcName,
      );
      CompletionReceiptRead response;
      try {
        response = await (transport as CompletionReceiptTransport)
            .readCompletionReceipt(request);
      } on Object {
        response = const CompletionReceiptFailure(
          CompletionReceiptFailureKind.network,
        );
      }
      if (response case CompletionReceiptResponse(
        state: CompletionReceiptState.accepted,
        receipt: final receipt?,
      )) {
        // حتى وسيلة النقل الوهمية تمر عبر مدقق الإقرار المشترك.
        final checked = parseCompletionReceipt(request, {
          'contract': 'get_completion_receipt',
          'version': 1,
          'well_id': request.wellId,
          'session_id': request.sessionId,
          'command_id': request.commandId,
          'command_type': request.commandType,
          'status': 'accepted',
          'retry_authorized': false,
          'receipt': receipt,
        });
        if (checked is CompletionReceiptResponse &&
            await atomic.reconcileCompletionReceipt(
              row,
              mapping.serverId,
              receipt,
            )) {
          return _OperationalResult.confirmed;
        }
      }
      if (response is CompletionReceiptResponse &&
              (response.state == CompletionReceiptState.notFound ||
                  response.state == CompletionReceiptState.unresolved) ||
          response is CompletionReceiptFailure &&
              (response.kind == CompletionReceiptFailureKind.forbidden ||
                  response.kind == CompletionReceiptFailureKind.malformed)) {
        if (storage is AtomicLocalRecordStore) {
          await (storage as AtomicLocalRecordStore).insertLocalRecordOnce(
            accountId: row.accountId,
            key: 'command.q137.review.v1.${row.localId}',
            value: 'receipt_requires_review',
          );
        }
      }
      await _holdOperational(row, 'completion_reconciliation_pending');
      return _OperationalResult.held;
    }
    if (uncertain || row.status != CommandStatus.pending) {
      await _holdOperational(row, 'previous_attempt_requires_review');
      return _OperationalResult.held;
    }
    final claimed = await atomic.claimDispatch(
      accountId: row.accountId,
      wellId: row.wellId!,
      localId: row.localId,
      commandId: row.commandId,
      attemptedAt: _clock().toUtc(),
      policy: (context) => switch (context.intent.origin) {
        CommandIntentOrigin.provenHuman => DispatchClaimDecision.allow,
        CommandIntentOrigin.provenAutomatic =>
          DispatchClaimDecision.automaticSuspended,
        CommandIntentOrigin.unresolved =>
          DispatchClaimDecision.originUnresolved,
      },
    );
    if (!claimed.isClaimed) {
      await _holdOperational(row, claimed.decision.name);
      return _OperationalResult.held;
    }
    final command = claimed.command!;
    final payload = claimed.context?.resolvedPayload;
    if (payload == null) return _OperationalResult.held;
    DispatchResult result;
    try {
      result = await _transport.dispatch(
        DispatchRequest(
          accountId: command.accountId,
          type: command.type,
          commandId: command.commandId,
          arguments: buildRpcArguments(
            type: command.type,
            commandId: command.commandId,
            occurredAt: command.occurredAt,
            resolvedPayload: payload,
          ),
        ),
      );
    } on Object {
      await _holdOperational(command, 'outcome_unknown');
      return _OperationalResult.held;
    }
    if (result case DispatchAccepted()) {
      if (command.type == CommandType.startBookingSession) {
        final request = BookingStartReceiptRequest.fromCommand(command);
        if (request == null || !validBookingStartReceipt(request, result.response) ||
            result.entityId != result.response['session_id']) {
          await _holdOperational(command, 'start_receipt_invalid');
          return _OperationalResult.held;
        }
      }
      if (command.type == CommandType.completeIrrigationSession) {
        final session = payload['p_session_id'];
        if (session is! String) return _OperationalResult.held;
        final request = CompletionReceiptRequest(
          accountId: command.accountId,
          wellId: command.wellId!,
          sessionId: session,
          commandId: command.commandId,
          commandType: command.type.rpcName,
        );
        final checked = parseCompletionReceipt(request, {
          'contract': 'get_completion_receipt',
          'version': 1,
          'well_id': request.wellId,
          'session_id': session,
          'command_id': command.commandId,
          'command_type': command.type.rpcName,
          'status': 'accepted',
          'retry_authorized': false,
          'receipt': result.response,
        });
        if (checked is! CompletionReceiptResponse ||
            result.entityId != result.response['session_charge_id']) {
          await _holdOperational(command, 'completion_receipt_invalid');
          return _OperationalResult.held;
        }
      }
      final applied = await atomic.finishDispatchAttempt(
        claimed.attempt!,
        status: CommandStatus.confirmed,
        serverResponse: result.response,
        entityId: result.entityId,
      );
      return applied ? _OperationalResult.sent : _OperationalResult.held;
    }
    if (result case DispatchFailed(executionNotStarted: true)) {
      await atomic.releaseDispatchAttempt(
        claimed.attempt!,
        reason: 'q137_preflight_not_sent',
      );
      return _OperationalResult.held;
    }
    // خطأ النقل ليس إثبات عدم التنفيذ. لا تحرير تلقائي لمحاولة قد تكون خرجت.
    if (result case DispatchFailed(isRetryable: false)) {
      final applied = await atomic.finishDispatchAttempt(
        claimed.attempt!,
        status: CommandStatus.review,
        serverResponse: result.serverResponse,
        error: result.message,
      );
      if (applied) return _OperationalResult.rejected;
    }
    await _holdOperational(command, 'outcome_unknown');
    return _OperationalResult.held;
  }

  Future<void> _holdOperational(CommandEnvelope row, String reason) async {
    final storage = _store;
    if (storage is AtomicLocalRecordStore) {
      await (storage as AtomicLocalRecordStore).insertLocalRecordOnce(
        accountId: row.accountId,
        key: 'command.q137.hold.v1.${row.localId}',
        value: reason,
      );
    }
  }

  Future<List<CommandEnvelope>> _legacyPending(String accountId) {
    final store = _store;
    return store is BookingDispatchStore
        ? (store as BookingDispatchStore).pendingLegacyCommands(accountId)
        : store.pendingCommands(accountId);
  }

  Future<bool> hasReadyBookingCreates(String accountId) async {
    final store = _store;
    if (store is! BookingDispatchStore) return false;
    return (await (store as BookingDispatchStore).bookingCreatesReady(
      accountId,
      now: _clock().toUtc(),
      limit: 1,
    )).isNotEmpty;
  }

  /// مرور مستقل محدود، لا يُستدعى من واجهة الحجز في C2a.
  Future<SyncRunReport> runBookingCreates(String accountId) {
    if (_bookingInFlight.containsKey(accountId)) {
      return Future.value(const SyncRunReport(alreadyRunning: true));
    }
    final run = _runBookingCreates(accountId);
    _bookingInFlight[accountId] = run;
    return run.whenComplete(() => _bookingInFlight.remove(accountId));
  }

  Future<SyncRunReport> _runBookingCreates(String accountId) async {
    final storage = _store;
    if (storage is! BookingDispatchStore) return const SyncRunReport();
    final store = storage as BookingDispatchStore;
    const policy = BackgroundSyncPolicy();
    var recovered = 0;
    final stale = await store.bookingCreatesStale(
      accountId,
      before: _clock().toUtc().subtract(staleClaimTimeout),
      limit: maxBookingBatch,
    );
    for (final command in stale) {
      final claimedAt = command.lastAttemptAt;
      if (claimedAt == null) continue;
      final restored = await store.finishBookingCreate(
        accountId,
        command.localId,
        claimedAt: claimedAt,
        status: CommandStatus.pending,
        error: 'booking_attempt_interrupted',
        nextAttemptAt: _clock().toUtc().add(
          policy.bookingCreateDelay(command.commandId, command.retryCount + 1),
        ),
      );
      if (restored) recovered++;
    }
    final candidates = await store.bookingCreatesReady(
      accountId,
      now: _clock().toUtc(),
      limit: maxBookingBatch,
    );
    final wells = <String, List<CommandEnvelope>>{};
    for (final command in candidates) {
      wells.putIfAbsent(command.wellId!, () => []).add(command);
    }
    final groups = wells.values.toList(growable: false);
    var cursor = 0;
    var attempted = 0;
    var confirmed = 0;
    var retries = 0;
    var review = 0;
    var skipped = 0;
    Future<void> lane() async {
      while (cursor < groups.length) {
        final group = groups[cursor++];
        for (final command in group) {
          final at = _clock().toUtc();
          var resolved = command.payload;
          final raw = command.payload['p_farm_id'];
          if (raw is Map) {
            final ref = CommandReference.fromJson(raw.cast<Object?, Object?>());
            final parent = await _store.commandByLocalId(
              accountId,
              ref.localId,
            );
            final valid =
                ref.kind == EntityKind.farm &&
                parent?.type == CommandType.createFarm &&
                parent?.wellId == command.wellId &&
                parent?.payload['p_farmer_well_account_id'] ==
                    command.payload['p_farmer_well_account_id'];
            if (!valid || parent?.status == CommandStatus.review) {
              if (await store.claimBookingCreate(
                accountId,
                command.localId,
                attemptedAt: at,
              )) {
                await store.finishBookingCreate(
                  accountId,
                  command.localId,
                  claimedAt: at,
                  status: CommandStatus.review,
                  error: 'farm_selection_required',
                  response: {
                    'status': 'rejected',
                    'reason_code': 'farm_selection_required',
                  },
                );
                final day = DateTime.parse(
                  command.payload['p_scheduled_start'] as String,
                ).toUtc().add(const Duration(hours: 3));
                BookingReactivity.instance
                    .scope(accountId, command.wellId!)
                    .mutation(days: {BookingScope.dayKey(day)});
                review++;
              }
              continue;
            }
            final mapping = await _store.mapping(
              accountId,
              ref.localId,
              EntityKind.farm,
            );
            if (mapping == null) {
              skipped++;
              continue;
            }
            resolved = {...command.payload, 'p_farm_id': mapping.serverId};
          }
          if (!await store.claimBookingCreate(
            accountId,
            command.localId,
            attemptedAt: at,
          )) {
            skipped++;
            break;
          }
          attempted++;
          final processed = await _dispatchAndPersist(
            accountId,
            command,
            resolved,
            at,
          );
          if (!processed.applied) {
            skipped++;
            break;
          }
          switch (processed.result) {
            case DispatchAccepted():
              confirmed++;
            case DispatchFailed(disposition: FailureDisposition.retry):
              retries++;
              break;
            case DispatchFailed():
              review++;
          }
          if (processed.result is DispatchFailed &&
              (processed.result as DispatchFailed).isRetryable) {
            break;
          }
        }
      }
    }

    // ثلاثة عمال ثابتين، لا Future لكل أمر أو لكل بئر.
    await Future.wait(List.generate(maxBookingWells, (_) => lane()));
    if (confirmed > 0) {
      await _store.setLastSuccessfulSyncAt(accountId, _clock().toUtc());
    }
    final now = _clock().toUtc();
    final wake = await store.bookingCreateNextWake(
      accountId,
      now: now,
      staleClaimTimeout: staleClaimTimeout,
    );
    final delay = wake?.difference(now);
    return SyncRunReport(
      attempted: attempted,
      confirmed: confirmed,
      retryScheduled: retries,
      needsReview: review,
      skipped: skipped,
      recoveredClaims: recovered,
      bookingNextWake: wake,
      bookingRetryDelay: delay == null
          ? null
          : delay < policy.firstDelay
          ? policy.firstDelay
          : delay,
    );
  }

  Future<_ProcessedAttempt> _dispatchAndPersist(
    String accountId,
    CommandEnvelope command,
    Map<String, Object?> resolved,
    DateTime attemptedAt,
  ) async {
    if (q137OperationalCommand(command.type)) {
      throw StateError('atomic_operational_dispatch_required');
    }
    final request = DispatchRequest(
      accountId: command.accountId,
      type: command.type,
      commandId: command.commandId,
      arguments: buildRpcArguments(
        type: command.type,
        commandId: command.commandId,
        occurredAt: command.occurredAt,
        resolvedPayload: resolved,
      ),
    );
    DispatchResult result;
      try {
        // timeout لا يلغي HTTP. لا يربط أي callback متأخر بالتخزين؛ الإعادة تحمل الهوية نفسها.
        result = await _transport
            .dispatch(request)
            .timeout(bookingAttemptTimeout);
      } on TimeoutException {
        result = const DispatchFailed(
          disposition: FailureDisposition.retry,
          message: 'booking_attempt_timeout',
        );
      } catch (error) {
        result = DispatchFailed(
          disposition: classifyThrownFailure(error),
          message: error.toString(),
        );
      }
      if (result is DispatchAccepted) {
        result = normalizeAcceptedResponse(
          CommandType.createBooking,
          result.response,
        );
        if (result is DispatchAccepted &&
            (result.response['well_id'] != command.wellId ||
                DateTime.tryParse(
                      result.response['scheduled_start']?.toString() ?? '',
                    ) !=
                    DateTime.tryParse(
                      resolved['p_scheduled_start']?.toString() ?? '',
                    ) ||
                DateTime.tryParse(
                      result.response['scheduled_end']?.toString() ?? '',
                    ) !=
                    DateTime.tryParse(
                      resolved['p_scheduled_end']?.toString() ?? '',
                    ))) {
          result = const DispatchFailed(
            disposition: FailureDisposition.retry,
            message: 'booking_receipt_mismatch',
          );
        }
      }
      final CommandStatus status;
      DateTime? next;
      String? error;
      Map<String, Object?>? response;
      String? entityId;
      switch (result) {
        case DispatchAccepted accepted:
          status = CommandStatus.confirmed;
          response = accepted.response;
          entityId = accepted.entityId;
        case DispatchFailed failure:
          status = failure.isRetryable
              ? CommandStatus.pending
              : CommandStatus.review;
          error = failure.message;
          response = failure.serverResponse;
          if (failure.isRetryable) {
            next = _clock().toUtc().add(
              const BackgroundSyncPolicy().bookingCreateDelay(
                command.commandId,
                command.retryCount + 1,
              ),
            );
          }
      }
      final applied = await (_store as BookingDispatchStore)
          .finishBookingCreate(
            accountId,
            command.localId,
            claimedAt: attemptedAt,
            status: status,
            nextAttemptAt: next,
            error: error,
            response: response,
            entityId: entityId,
          );
      if (applied &&
          response != null &&
          const {
            'confirmed',
            'conflict',
            'rejected',
          }.contains(response['status'])) {
        final scheduled = DateTime.parse(
          command.payload['p_scheduled_start'] as String,
        ).toUtc().add(const Duration(hours: 3));
        BookingReactivity.instance
            .scope(accountId, command.wellId!)
            .mutation(days: {BookingScope.dayKey(scheduled)});
      }
      return _ProcessedAttempt(result, applied);
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

    for (final command in await _legacyPending(accountId)) {
      if (q137OperationalCommand(command.type) || command.status != CommandStatus.dispatching) {
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

  Future<bool> _isAuthorizedFarmerResolver(
    String accountId,
    CommandEnvelope command,
  ) async {
    if (command.type != CommandType.resolveFarmerIdentity) return false;
    final targetLocalId = command.aggregateLocalId;
    if (targetLocalId == null) return false;
    final source = await _store.commandByLocalId(accountId, targetLocalId);
    if (source == null || source.type != CommandType.createFarmer) return false;
    if (source.status != CommandStatus.review &&
        source.status != CommandStatus.confirmed) {
      return false;
    }
    final resp = source.serverResponse;
    return resp != null && resp['status'] == 'requires_resolution';
  }

  Future<void> _confirmFarmerResolution(
    String accountId,
    CommandEnvelope command,
    DispatchAccepted result,
    DateTime attemptedAt,
  ) async {
    final targetLocalId = command.aggregateLocalId;
    final entityId =
        result.entityId ??
        result.response['farmer_well_account_id']?.toString();
    if (targetLocalId != null && entityId != null && entityId.isNotEmpty) {
      await _store.putMapping(
        accountId,
        IdMapping(
          localId: targetLocalId,
          kind: EntityKind.farmerWellAccount,
          serverId: entityId,
          resolvedAt: attemptedAt,
          matchedExisting: result.matchedExisting,
        ),
      );
      await _store.markConfirmed(
        accountId,
        targetLocalId,
        serverResponse: result.response,
        attemptedAt: attemptedAt,
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

class _ProcessedAttempt {
  const _ProcessedAttempt(this.result, this.applied);
  final DispatchResult result;
  final bool applied;
}

enum _OperationalResult { sent, confirmed, held, rejected }

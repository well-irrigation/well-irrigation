import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/operations_repository.dart';
import '../../core/api/session_financial_adjustment.dart';
import '../../core/session/offline_session_coordinator.dart';
import '../../core/sync/session_financial_adjustment.dart';
import 'session_financial_adjustment_form.dart';

const _readError = 'تعذر تحميل البيانات المالية. اتصل بالإنترنت وأعد التحميل.';
const _savedMessage =
    'تم حفظ تعديل المبلغ على الجهاز. يمكنك مغادرة الصفحة، وسيُرسل عند توفر الاتصال.';
const _acceptedMessage = 'تم اعتماد تعديل المبلغ.';
const _unknownMessage =
    'لم نتمكن من التأكد من نتيجة التعديل بعد. طلبك محفوظ؛ تابع حالته لاحقًا.';
const _unavailableFollowUp =
    'تعذر التحقق من حالة تعديل سابق بأمان. راجع الحالة لاحقًا قبل إجراء تعديل جديد.';
const _lockedMessage =
    'لا يمكن تعديل مبلغ هذه الجلسة حاليًا لارتباطها بإجراء مالي محمي.';
const _reviewMessage = 'تحتاج هذه الجلسة إلى مراجعة مالية قبل تعديل المبلغ.';
const _deniedMessage = 'لم تعد لديك صلاحية تعديل مبلغ هذه الجلسة.';

String? _unavailableReason(SessionFinancialStatus status) => switch (status) {
  SessionFinancialStatus.locked => _lockedMessage,
  SessionFinancialStatus.reviewRequired => _reviewMessage,
  SessionFinancialStatus.permissionDenied => _deniedMessage,
  SessionFinancialStatus.ready => null,
};

/// Gated entry inside the completed-session financial section.
class SessionFinancialAdjustmentAction extends StatefulWidget {
  const SessionFinancialAdjustmentAction({
    required this.accountId,
    required this.wellId,
    required this.sessionId,
    required this.sessionLabel,
    required this.repository,
    required this.coordinator,
    required this.onAccepted,
    super.key,
  });

  final String accountId;
  final String wellId;
  final String sessionId;
  final String sessionLabel;
  final OperationsRepository repository;
  final OfflineSessionCoordinator coordinator;
  final Future<void> Function() onAccepted;

  @override
  State<SessionFinancialAdjustmentAction> createState() =>
      _SessionFinancialAdjustmentActionState();
}

class _SessionFinancialAdjustmentActionState
    extends State<SessionFinancialAdjustmentAction> {
  int _generation = 0;
  bool _opening = false;
  bool _failed = false;
  bool _hasFollowUp = false;
  String? _followUpId;
  SessionFinancialAdjustmentCapability? _capability;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant SessionFinancialAdjustmentAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository ||
        oldWidget.coordinator != widget.coordinator ||
        oldWidget.accountId != widget.accountId ||
        oldWidget.wellId != widget.wellId ||
        oldWidget.sessionId != widget.sessionId) {
      _opening = false;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final scope = widget;
    setState(() {
      _failed = false;
      _hasFollowUp = false;
      _followUpId = null;
      _capability = null;
    });
    try {
      final followUp = await scope.coordinator
          .findBlockingSessionFinancialAdjustmentFollowUp(
            accountId: scope.accountId,
            wellId: scope.wellId,
            sessionId: scope.sessionId,
          );
      if (!mounted || generation != _generation) return;
      if (followUp.blocksNewIntent) {
        setState(() {
          _hasFollowUp = true;
          _followUpId = followUp.followUp?.localId;
        });
        return;
      }
      final capability = await scope.repository
          .getSessionFinancialAdjustmentCapability(
            accountId: scope.accountId,
            sessionId: scope.sessionId,
          );
      if (!mounted || generation != _generation) return;
      if (capability.sessionId != scope.sessionId ||
          (capability.wellId != null && capability.wellId != scope.wellId) ||
          (capability.canAdjust && capability.wellId != scope.wellId)) {
        setState(() => _failed = true);
        return;
      }
      setState(() => _capability = capability);
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    }
  }

  Future<void> _open() async {
    if (_opening || (!_hasFollowUp && _capability?.canAdjust != true)) return;
    final generation = _generation;
    final scope = widget;
    setState(() => _opening = true);
    try {
      final accepted = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => SessionFinancialAdjustmentScreen(
            accountId: scope.accountId,
            wellId: scope.wellId,
            sessionId: scope.sessionId,
            sessionLabel: scope.sessionLabel,
            repository: scope.repository,
            coordinator: scope.coordinator,
            localId: _followUpId,
          ),
        ),
      );
      if (!mounted || generation != _generation) return;
      if (accepted == true) {
        if (ModalRoute.of(context)?.isCurrent == true) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text(_acceptedMessage)));
        }
        await scope.onAccepted();
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _opening = false);
        await _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasFollowUp || _capability?.canAdjust == true) {
      return OutlinedButton(
        onPressed: _opening ? null : _open,
        child: Text(_hasFollowUp ? 'متابعة تعديل المبلغ' : 'تعديل المبلغ'),
      );
    }
    if (_failed) {
      return IconButton(
        onPressed: _load,
        tooltip: 'إعادة تحميل البيانات المالية',
        icon: const Icon(Icons.refresh),
        iconSize: 20,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 36),
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }
    final status = _capability?.status;
    final reason = status == null ? null : _unavailableReason(status);
    if (reason != null && status != SessionFinancialStatus.permissionDenied) {
      return Text(reason);
    }
    return const SizedBox.shrink();
  }
}

class SessionFinancialAdjustmentScreen extends StatefulWidget {
  const SessionFinancialAdjustmentScreen({
    required this.accountId,
    required this.wellId,
    required this.sessionId,
    required this.sessionLabel,
    required this.repository,
    required this.coordinator,
    this.localId,
    super.key,
  });

  final String accountId;
  final String wellId;
  final String sessionId;
  final String sessionLabel;
  final OperationsRepository repository;
  final OfflineSessionCoordinator coordinator;
  final String? localId;

  @override
  State<SessionFinancialAdjustmentScreen> createState() =>
      _SessionFinancialAdjustmentScreenState();
}

class _SessionFinancialAdjustmentScreenState
    extends State<SessionFinancialAdjustmentScreen> {
  static const _followUpInterval = Duration(seconds: 2);

  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  SessionFinancialState? _snapshot;
  SessionFinancialAdjustmentFollowUpLookup? _lookup;
  String? _localId;
  bool _loading = true;
  bool _readFailed = false;
  bool _reviewing = false;
  bool _saving = false;
  bool _departureStarted = false;
  bool _acceptedNavigationConsumed = false;
  int _generation = 0;
  ModalRoute<dynamic>? _ownerRoute;
  NavigatorState? _ownerNavigator;
  Timer? _followUpTimer;
  bool _automaticReadInProgress = false;

  bool _current(int generation) =>
      mounted && !_departureStarted && generation == _generation;

  bool get _ownsRoute =>
      mounted &&
      !_departureStarted &&
      !_acceptedNavigationConsumed &&
      _ownerRoute?.isCurrent == true &&
      _ownerNavigator?.mounted == true &&
      _ownerNavigator?.userGestureInProgress == false;

  bool get _hasPendingAcceptedNavigation {
    final followUp = _lookup?.followUp;
    return !_loading &&
        !_acceptedNavigationConsumed &&
        followUp?.phase == SessionFinancialAdjustmentFollowUpPhase.accepted &&
        followUp?.localId == _localId;
  }

  void _beginDeparture() {
    _departureStarted = true;
    _generation++;
    _cancelFollowUpObservation();
  }

  void _cancelFollowUpObservation() {
    _followUpTimer?.cancel();
    _followUpTimer = null;
  }

  void _updateFollowUpObservation() {
    if (_ownsRoute) {
      _tryConsumeAcceptedNavigation();
      _scheduleFollowUpObservation();
    } else {
      _cancelFollowUpObservation();
    }
  }

  void _tryConsumeAcceptedNavigation() {
    if (!_ownsRoute || !_hasPendingAcceptedNavigation) return;
    final generation = _generation;
    // Ownership can return during build or inside a navigator notification.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current(generation) && _hasPendingAcceptedNavigation) {
        _leave(accepted: true);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _scheduleFollowUpObservation() {
    if (!_ownsRoute ||
        _loading ||
        _localId == null ||
        _followUpTimer != null ||
        _automaticReadInProgress) {
      return;
    }
    switch (_lookup?.followUp?.phase) {
      case SessionFinancialAdjustmentFollowUpPhase.pendingFirstSend:
      case SessionFinancialAdjustmentFollowUpPhase.inFlight:
      case SessionFinancialAdjustmentFollowUpPhase.processing:
        break;
      default:
        return;
    }

    // Re-read the durable row only. Sync owns all remote recovery.
    _followUpTimer = Timer(_followUpInterval, () async {
      _followUpTimer = null;
      if (!_ownsRoute) return;
      _automaticReadInProgress = true;
      try {
        await _load(automatic: true);
      } finally {
        _automaticReadInProgress = false;
        _scheduleFollowUpObservation();
      }
    });
  }

  void _leave({bool accepted = false}) {
    if (!_ownsRoute || !_ownerNavigator!.canPop()) return;
    if (accepted) _acceptedNavigationConsumed = true;
    _beginDeparture();
    _ownerNavigator!.pop(accepted);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_ownerRoute == route) {
      _updateFollowUpObservation();
      return;
    }
    _ownerNavigator?.userGestureInProgressNotifier.removeListener(
      _updateFollowUpObservation,
    );
    _ownerRoute = route;
    _ownerNavigator = Navigator.of(context);
    _ownerNavigator!.userGestureInProgressNotifier.addListener(
      _updateFollowUpObservation,
    );
    _lookup = null;
    _localId = widget.localId;
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant SessionFinancialAdjustmentScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId ||
        oldWidget.wellId != widget.wellId ||
        oldWidget.sessionId != widget.sessionId ||
        oldWidget.localId != widget.localId ||
        oldWidget.repository != widget.repository ||
        oldWidget.coordinator != widget.coordinator) {
      _lookup = null;
      _localId = widget.localId;
      _reviewing = false;
      _saving = false;
      _amount.clear();
      _reason.clear();
      unawaited(_load());
    }
  }

  Future<SessionFinancialAdjustmentFollowUpLookup> _readBlocker(
    SessionFinancialAdjustmentScreen scope,
  ) => scope.coordinator.findBlockingSessionFinancialAdjustmentFollowUp(
    accountId: scope.accountId,
    wellId: scope.wellId,
    sessionId: scope.sessionId,
  );

  void _showFollowUp(SessionFinancialAdjustmentFollowUpLookup lookup) {
    setState(() {
      _snapshot = null;
      _lookup = lookup;
      _localId ??= lookup.followUp?.localId;
      _loading = false;
    });
    _updateFollowUpObservation();
  }

  Future<void> _load({bool automatic = false}) async {
    if (_hasPendingAcceptedNavigation) {
      _tryConsumeAcceptedNavigation();
      return;
    }
    _cancelFollowUpObservation();
    final scope = widget;
    final generation = ++_generation;
    final id = _localId;
    if (!automatic) {
      setState(() {
        _snapshot = null;
        _readFailed = false;
        _loading = true;
      });
    }
    final SessionFinancialAdjustmentFollowUpLookup lookup;
    try {
      lookup = id == null
          ? await _readBlocker(scope)
          : await scope.coordinator.readSessionFinancialAdjustmentFollowUp(
              accountId: scope.accountId,
              wellId: scope.wellId,
              sessionId: scope.sessionId,
              localId: id,
            );
    } catch (_) {
      if (_current(generation) && (!automatic || _ownsRoute)) {
        _showFollowUp(
          const SessionFinancialAdjustmentFollowUpLookup.unavailable(),
        );
      }
      return;
    }
    // The generation rejects superseded reads. Retain acceptance during a
    // temporary loss of ownership so it can be presented without another read.
    if (!_current(generation) ||
        (automatic &&
            !_ownsRoute &&
            lookup.followUp?.phase !=
                SessionFinancialAdjustmentFollowUpPhase.accepted)) {
      return;
    }
    if (id != null || lookup.blocksNewIntent) {
      _showFollowUp(
        lookup.followUp == null && id != null
            ? const SessionFinancialAdjustmentFollowUpLookup.unavailable()
            : lookup,
      );
      return;
    }
    try {
      final snapshot = await scope.repository.getSessionFinancialState(
        accountId: scope.accountId,
        sessionId: scope.sessionId,
      );
      if (!_current(generation)) return;
      if (snapshot.sessionId != scope.sessionId ||
          snapshot.wellId != scope.wellId) {
        throw const FormatException('financial state scope');
      }
      setState(() {
        _lookup = null;
        _snapshot = snapshot;
        _amount.text = snapshot.effectiveAmountYER?.toString() ?? '';
        _loading = false;
      });
    } catch (_) {
      if (!_current(generation)) return;
      setState(() {
        _lookup = null;
        _readFailed = true;
        _loading = false;
      });
    }
  }

  Future<bool> _checkBlocker(
    SessionFinancialAdjustmentScreen scope,
    int generation,
  ) async {
    final SessionFinancialAdjustmentFollowUpLookup lookup;
    try {
      lookup = await _readBlocker(scope);
    } catch (_) {
      if (_current(generation)) {
        _showFollowUp(
          const SessionFinancialAdjustmentFollowUpLookup.unavailable(),
        );
      }
      return false;
    }
    if (!_current(generation) || !_ownsRoute) return false;
    if (lookup.blocksNewIntent) {
      _showFollowUp(lookup);
      return false;
    }
    return true;
  }

  Future<void> _review() async {
    final snapshot = _snapshot;
    if (!_ownsRoute ||
        _reviewing ||
        _saving ||
        _localId != null ||
        snapshot == null ||
        !snapshot.canAdjust ||
        _formKey.currentState?.validate() != true) {
      return;
    }
    final amount = parseSessionFinancialAmount(_amount.text)!;
    final reason = _reason.text.trim();
    final generation = _generation;
    final scope = widget;
    setState(() => _reviewing = true);
    try {
      if (!await _checkBlocker(scope, generation)) return;
      if (!mounted || !_current(generation) || !_ownsRoute) return;
      var consumed = false;
      void closeConfirmation(BuildContext dialog, bool confirmed) {
        if (consumed ||
            !dialog.mounted ||
            ModalRoute.of(dialog)?.isCurrent != true ||
            (confirmed && !_current(generation))) {
          return;
        }
        consumed = true;
        Navigator.of(dialog).pop(confirmed);
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            scrollable: true,
            title: const Text('مراجعة التعديل'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('المبلغ الحالي'),
                SessionFinancialAmountText(snapshot.effectiveAmountYER),
                const Text('المبلغ الجديد'),
                SessionFinancialAmountText(amount),
                const Text('سبب تعديل المبلغ'),
                Text(reason),
                const SizedBox(height: 12),
                const Text(
                  'سيُحفظ هذا التعديل في سجل الجلسة. هذا الإجراء لا يسجل دفعة.',
                ),
                if (amount == 0)
                  const Text('سيصبح المبلغ المعتمد لهذه الجلسة صفرًا.'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => closeConfirmation(dialog, false),
                child: const Text('رجوع'),
              ),
              FilledButton(
                key: const ValueKey('financial_adjustment_confirm'),
                onPressed: () => closeConfirmation(dialog, true),
                child: const Text('تأكيد تعديل المبلغ'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true ||
          !_current(generation) ||
          !_ownsRoute ||
          !identical(snapshot, _snapshot)) {
        return;
      }
      if (!await _checkBlocker(scope, generation)) return;
      if (!_current(generation) || !_ownsRoute) return;
      setState(() => _saving = true);
      final command = await scope.coordinator.submitSessionFinancialAdjustment(
        accountId: scope.accountId,
        wellId: scope.wellId,
        sessionId: scope.sessionId,
        baseOperationalRevision: snapshot.operationalRevision,
        baseSystemFinancialRevision: snapshot.systemFinancialRevision,
        baseManualApprovalRevision: snapshot.manualApprovalRevision,
        approvedAmountYER: amount,
        reason: reason,
      );
      if (!_current(generation)) return;
      setState(() {
        _localId = command.localId;
        _snapshot = null;
        _saving = false;
        _reviewing = false;
      });
      await _load();
    } catch (_) {
      if (_current(generation)) {
        _showFollowUp(
          const SessionFinancialAdjustmentFollowUpLookup.unavailable(),
        );
      }
    } finally {
      if (_current(generation)) {
        setState(() {
          _reviewing = false;
          _saving = false;
        });
      }
    }
  }

  String _followUpMessage(SessionFinancialAdjustmentFollowUp? view) {
    if (view == null) return _unavailableFollowUp;
    return switch (view.phase) {
      SessionFinancialAdjustmentFollowUpPhase.pendingFirstSend => _savedMessage,
      SessionFinancialAdjustmentFollowUpPhase.inFlight ||
      SessionFinancialAdjustmentFollowUpPhase.processing =>
        'جارٍ التحقق من تعديل المبلغ. طلبك محفوظ ويمكنك مغادرة الصفحة.',
      SessionFinancialAdjustmentFollowUpPhase.uncertain => _unknownMessage,
      SessionFinancialAdjustmentFollowUpPhase.accepted => _acceptedMessage,
      SessionFinancialAdjustmentFollowUpPhase.needsReview =>
        switch (view.outcome?.state) {
          SessionFinancialAdjustmentState.validationError =>
            'لم يُعتمد التعديل. راجع المبلغ والسبب.',
          SessionFinancialAdjustmentState.conflictRevision =>
            'تغيرت بيانات الجلسة. حدّث البيانات وراجع المبلغ من جديد.',
          SessionFinancialAdjustmentState.conflictRequest =>
            'تعذر التحقق من سلامة هذا الطلب. تابع حالته قبل إجراء تعديل آخر.',
          SessionFinancialAdjustmentState.financialReviewRequired =>
            _reviewMessage,
          SessionFinancialAdjustmentState.locked => _lockedMessage,
          SessionFinancialAdjustmentState.permissionDenied => _deniedMessage,
          _ => _unknownMessage,
        },
    };
  }

  Widget _followUpBody(SessionFinancialAdjustmentFollowUpLookup lookup) {
    final view = lookup.followUp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(liveRegion: true, child: Text(_followUpMessage(view))),
        if (view != null) ...[
          const SizedBox(height: 12),
          const Text('المبلغ المطلوب'),
          SessionFinancialAmountText(view.approvedAmountYER),
          Text(view.reason),
        ],
        if (view?.phase ==
                SessionFinancialAdjustmentFollowUpPhase.needsReview &&
            view?.outcome?.state !=
                SessionFinancialAdjustmentState.conflictRequest)
          OutlinedButton(
            onPressed: () {
              _localId = null;
              unawaited(_load());
            },
            child: const Text('راجع البيانات من جديد'),
          )
        else
          OutlinedButton(onPressed: _load, child: const Text('متابعة الحالة')),
        TextButton(onPressed: _leave, child: const Text('إغلاق')),
      ],
    );
  }

  Widget _summary(SessionFinancialState snapshot) {
    Widget item(String label, int? value) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Text(label), SessionFinancialAmountText(value)],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        item('المبلغ المحسوب', snapshot.systemAmountYER),
        item('المبلغ المعتمد حاليًا', snapshot.effectiveAmountYER),
        if (snapshot.approvedAmountYER != null &&
            snapshot.approvedAmountYER != snapshot.effectiveAmountYER)
          item('آخر مبلغ معتمد يدويًا', snapshot.approvedAmountYER),
        item('المدفوع', snapshot.paidAmountYER),
        item('المتبقي للسداد', snapshot.outstandingAmountYER),
        if (snapshot.originalAmountYER != null &&
            snapshot.originalAmountYER != snapshot.systemAmountYER)
          ExpansionTile(
            title: const Text('المزيد من التفاصيل'),
            children: [item('المبلغ الأصلي', snapshot.originalAmountYER)],
          ),
        if (snapshot.adjustmentHistory.isNotEmpty)
          ExpansionTile(
            title: const Text('سجل تعديلات المبلغ'),
            children: [
              for (final entry in snapshot.adjustmentHistory)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      item('المبلغ السابق', entry.previousEffectiveYER),
                      item('المبلغ المعتمد', entry.approvedAmountYER),
                      Text(entry.reason),
                      Text(entry.actorName),
                      Text(
                        MaterialLocalizations.of(context)
                            .formatMediumDate(entry.acceptedAt.toLocal()),
                      ),
                      Text(
                        MaterialLocalizations.of(context).formatTimeOfDay(
                          TimeOfDay.fromDateTime(entry.acceptedAt.toLocal()),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }

  @override
  void dispose() {
    _beginDeparture();
    _ownerNavigator?.userGestureInProgressNotifier.removeListener(
      _updateFollowUpObservation,
    );
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final lookup = _lookup;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: PopScope<bool>(
        canPop: !_saving,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) _beginDeparture();
        },
        child: Scaffold(
          appBar: AppBar(
            title: const Text('تعديل مبلغ الجلسة'),
            actions: [
              if (_localId == null)
                IconButton(
                  tooltip: 'إعادة تحميل البيانات المالية',
                  onPressed: _reviewing || _saving ? null : _load,
                  icon: const Icon(Icons.refresh),
                ),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.sessionLabel,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  if (_loading)
                    Semantics(
                      liveRegion: true,
                      child: const Text('جارٍ تحميل البيانات المالية…'),
                    )
                  else if (lookup != null)
                    _followUpBody(lookup)
                  else if (_readFailed)
                    Semantics(liveRegion: true, child: const Text(_readError))
                  else if (snapshot != null) ...[
                    _summary(snapshot),
                    const SizedBox(height: 16),
                    if (snapshot.canAdjust &&
                        snapshot.effectiveAmountYER != null)
                      SessionFinancialAdjustmentForm(
                        formKey: _formKey,
                        amount: _amount,
                        reason: _reason,
                        enabled: !_reviewing && !_saving,
                        currentAmount: snapshot.effectiveAmountYER!,
                        allowSameAmount:
                            snapshot.status ==
                            SessionFinancialStatus.reviewRequired,
                        onReview: _review,
                      )
                    else
                      Text(
                        _unavailableReason(snapshot.status) ?? 'لا يمكن تعديل المبلغ وفق البيانات المالية الحالية.',
                      ),
                    if (_saving)
                      Semantics(
                        liveRegion: true,
                        child: const Text('جارٍ حفظ طلب التعديل…'),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

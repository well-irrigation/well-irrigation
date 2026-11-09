import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/operations_repository.dart';
import '../../core/session/offline_session_coordinator.dart';
import '../../core/session/active_session_record.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/currency_utils.dart';
import '../../core/widgets/currency_display.dart';
import '../operations/widgets/payment_receipt_dialog.dart';
import '../operations/widgets/session_completion_result.dart';
import 'session_correction_screen.dart';

/// شاشة تفاصيل الجلسة والخط الزمني (UX-13 / 377 / ق-98)
class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({
    required this.sessionId,
    required this.wellName,
    this.repository,
    this.coordinator,
    this.accountId,
    this.wellId,
    this.initialResult,
    super.key,
  });

  final String sessionId;
  final String wellName;
  final OperationsRepository? repository;
  final OfflineSessionCoordinator? coordinator;
  final String? accountId;
  final String? wellId;
  final ActiveSessionRecord? initialResult;

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  late OperationsRepository _repo;
  StreamSubscription<ActiveSessionRecord>? _completionSubscription;
  Object? _financeRevision;
  ActiveSessionRecord? _localCompletion;
  CompletedSessionPaymentState? _paymentState;
  bool _paymentOpening = false;
  bool _usingCachedRead = false;
  bool get _canShowCorrectionAction =>
      _detailData != null &&
      !_usingCachedRead &&
      _detailData!.canCorrectSession;
  OfflineSessionCoordinator get _coordinator =>
      widget.coordinator ?? OfflineSessionCoordinator.instance;
  bool get _canRecordPayment =>
      !_paymentOpening &&
      !(_localCompletion?.payments.any((p) => !p.isPosted) ?? false) &&
      _paymentState?.canRecordPayment == true &&
      (_detailData?.session.hasCharge == true ||
          (_paymentState!.record.approvedAmountMinor ??
                  _paymentState!.record.totals.accruedMinor ??
                  0) >
              0) &&
      _detailData?.session.isFullySettled != true;
  bool _refreshing = false;
  bool _refreshAgain = false;
  int _loadGeneration = 0;
  String? _correctionOutcome;
  String? _historicalCorrectionOutcome;
  Object? _correctionOutcomeSnapshot;
  bool _historyExpanded = false;
  bool _historyLoading = false;
  bool _historyLoaded = false;
  String? _historyError;
  SessionCorrectionHistory? _correctionHistory;
  String? _historySessionId;
  int _historyGeneration = 0;

  void _resetCorrectionHistory() {
    _historyGeneration++;
    _historyExpanded = false;
    _historyLoading = false;
    _historyLoaded = false;
    _historyError = null;
    _correctionHistory = null;
    _historySessionId = null;
  }

  void _replaceDetailData(SessionDetailData data) {
    final previousSessionId = _detailData?.session.id;
    _detailData = data;
    if (!data.canReadSessionCorrections ||
        (previousSessionId != null && previousSessionId != data.session.id)) {
      _resetCorrectionHistory();
    }
  }

  // Value equality keeps messages valid across equivalent server reads.
  // SessionHistoryItem represents financial review through financialStatus.
  Object _correctionSnapshot(SessionDetailData data) {
    final session = data.session;
    return (
      sessionId: session.id,
      wellId: session.wellId,
      revision: session.operationalRevision,
      startedAt: session.effectiveStartedAt?.microsecondsSinceEpoch,
      endedAt: session.effectiveEndedAt?.microsecondsSinceEpoch,
      financialStatus: session.financialStatus,
      financialReviewRequired:
          session.financialStatus == 'financial_review_required',
      financialAppliedRevision: session.financialAppliedRevision,
      amount: session.totalAmountYER,
      paidAmount: session.paidAmountYER,
      paymentStatus: session.paymentStatus,
      hasCharge: session.hasCharge,
      hasInvoice: session.hasInvoice,
    );
  }

  bool get _correctionOutcomeIsCurrent =>
      _detailData != null &&
      _correctionOutcomeSnapshot == _correctionSnapshot(_detailData!);

  void _onCompletion(ActiveSessionRecord record) {
    if (record.accountId != widget.accountId ||
        record.wellId != widget.wellId ||
        record.serverSessionId != widget.sessionId) {
      return;
    }
    final revision = (
      record.approvedAmountMinor,
      record.syncState,
      record.payments
          .map((p) => '${p.localId}:${p.status}:${p.serverId}')
          .join('|'),
    );
    if (revision == _financeRevision) return;
    _financeRevision = revision;
    setState(() => _localCompletion = record);
    _refreshFinance();
  }

  Future<void> _restorePaymentState() async {
    if (widget.accountId == null || widget.wellId == null) return;
    final state = await _coordinator.restoreCompletedSession(
      accountId: widget.accountId!,
      wellId: widget.wellId!,
      serverSessionId: widget.sessionId,
    );
    if (!mounted) return;
    setState(() {
      _paymentState = state;
      if (state != null) _localCompletion = state.record;
      if (_detailData == null && state?.cachedDetail != null) {
        _replaceDetailData(state!.cachedDetail!);
        _usingCachedRead = true;
        _isLoading = false;
      }
    });
  }

  Future<void> _rememberPaymentRead(
    SessionDetailData data,
    String? revision,
  ) async {
    if (revision == null || widget.accountId == null || widget.wellId == null) {
      return;
    }
    await _coordinator.rememberSessionPaymentRead(
      accountId: widget.accountId!,
      wellId: widget.wellId!,
      detail: data,
      revision: revision,
    );
    await _restorePaymentState();
  }

  Future<void> _openSessionCorrection() async {
    if (!_canShowCorrectionAction) return;
    final session = _detailData!.session;
    final start = session.effectiveStartedAt;
    final end = session.effectiveEndedAt;
    final revision = session.operationalRevision;
    if (start == null || end == null || revision == null) return;
    final result = await Navigator.of(context)
        .push<SessionCorrectionAcceptedResult>(
          MaterialPageRoute<SessionCorrectionAcceptedResult>(
            builder: (_) => SessionCorrectionScreen(
              coordinator: _coordinator,
              accountId: widget.accountId,
              wellId: widget.wellId,
              sessionId: session.id,
              effectiveStartedAt: start,
              effectiveEndedAt: end,
              operationalRevision: revision,
            ),
          ),
        );
    if (!mounted || result == null) return;
    await _verifyCorrection(result);
  }

  Future<void> _verifyCorrection(SessionCorrectionAcceptedResult result) async {
    final generation = ++_loadGeneration;
    final receipt = result.accepted.receipt!;
    final acceptedRevision = receipt['operational_revision'] as int;
    final previousRevision = receipt['previous_revision'] as int;
    final correctionId = receipt['correction_id'] as String;
    final start = DateTime.parse(receipt['actual_started_at'] as String);
    final end = DateTime.parse(receipt['actual_ended_at'] as String);
    bool same(DateTime? a, DateTime b) => a?.isAtSameMomentAs(b) == true;
    try {
      final detail = await _repo.fetchSessionDetail(widget.sessionId);
      final history = await _repo.fetchSessionCorrections(widget.sessionId);
      final status = await _repo.fetchSessionCorrectionStatus(widget.sessionId);
      if (!mounted || generation != _loadGeneration) return;
      final matches = history.items
          .where((item) => item.correctionId == correctionId)
          .toList();
      final session = detail.session;
      final revision = session.operationalRevision;
      var valid =
          session.id == widget.sessionId &&
          session.wellId == widget.wellId &&
          history.sessionId == widget.sessionId &&
          matches.length == 1 &&
          revision != null &&
          revision >= acceptedRevision;
      if (valid) {
        final item = matches.single;
        valid =
            item.sessionId == widget.sessionId &&
            item.previousRevision == previousRevision &&
            item.newRevision == acceptedRevision &&
            same(item.afterStartedAt, start) &&
            same(item.afterEndedAt, end);
      }
      final current = revision == acceptedRevision;
      if (valid && current) {
        valid =
            same(session.effectiveStartedAt, start) &&
            same(session.effectiveEndedAt, end) &&
            status.sessionId == widget.sessionId &&
            status.correctionId == correctionId &&
            status.operationalRevision == acceptedRevision &&
            status.financialStatus == session.financialStatus &&
            (status.financialStatus != 'applied' ||
                session.financialAppliedRevision == revision);
      }
      setState(() {
        _historicalCorrectionOutcome = null;
        _correctionOutcomeSnapshot = _correctionSnapshot(
          valid ? detail : _detailData!,
        );
        if (!valid) {
          _correctionOutcome =
              'تم اعتماد طلب التصحيح، لكن تعذر التحقق من أحدث بيانات الجلسة.';
          return;
        }
        _resetCorrectionHistory();
        _replaceDetailData(detail);
        _usingCachedRead = false;
        if (!current) {
          _correctionOutcome =
              'تم اعتماد هذا التصحيح، وتوجد تعديلات أحدث على السجل.';
          if (matches.single.financialReviewRequired) {
            _historicalCorrectionOutcome =
                'الأثر المالي لهذا التصحيح يحتاج إلى مراجعة.';
          }
        } else if (status.financialReviewRequired ||
            status.financialStatus == 'financial_review_required') {
          _correctionOutcome =
              'تم اعتماد التصحيح، لكن المبلغ يحتاج إلى مراجعة.';
        } else if (status.financialStatus == 'applied') {
          _correctionOutcome = 'تم اعتماد التصحيح.';
        } else {
          _correctionOutcome = 'تم اعتماد التصحيح، والأثر المالي قيد المعالجة.';
        }
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _historicalCorrectionOutcome = null;
        _correctionOutcomeSnapshot = _correctionSnapshot(_detailData!);
        _correctionOutcome =
            'تم اعتماد طلب التصحيح، لكن تعذر تحميل أحدث بيانات الجلسة.';
      });
    }
  }

  String _correctionTime(DateTime time) {
    final local = time.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _toggleCorrectionHistory() async {
    final data = _detailData;
    if (data?.canReadSessionCorrections != true || _historyLoading) return;
    if (_historyExpanded) {
      setState(() => _historyExpanded = false);
      return;
    }

    final sessionId = data!.session.id;
    setState(() => _historyExpanded = true);
    if (_historyLoaded && _historySessionId == sessionId) return;
    await _fetchCorrectionHistory(sessionId);
  }

  Future<void> _retryCorrectionHistory() async {
    final data = _detailData;
    if (data?.canReadSessionCorrections != true || _historyLoading) return;
    setState(() => _historyExpanded = true);
    await _fetchCorrectionHistory(data!.session.id);
  }

  Future<void> _fetchCorrectionHistory(String sessionId) async {
    if (_historyLoading ||
        _detailData?.canReadSessionCorrections != true ||
        _detailData?.session.id != sessionId ||
        (_historyLoaded && _historySessionId == sessionId)) {
      return;
    }

    final generation = ++_historyGeneration;
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      final history = await _repo.fetchSessionCorrections(sessionId);
      if (history.sessionId != sessionId) {
        throw StateError('Correction history session mismatch');
      }
      if (!mounted ||
          generation != _historyGeneration ||
          _detailData?.canReadSessionCorrections != true ||
          _detailData?.session.id != sessionId) {
        return;
      }
      setState(() {
        _correctionHistory = history;
        _historySessionId = sessionId;
        _historyLoaded = true;
        _historyLoading = false;
        _historyError = null;
      });
    } catch (_) {
      if (!mounted ||
          generation != _historyGeneration ||
          _detailData?.canReadSessionCorrections != true ||
          _detailData?.session.id != sessionId) {
        return;
      }
      setState(() {
        _historyLoading = false;
        _historyLoaded = false;
        _historyError = 'تعذر تحميل سجل التصحيحات. حاول مرة أخرى.';
      });
    }
  }

  String _formatCorrectionDateTime(DateTime time) {
    final local = time.toLocal();
    final date = MaterialLocalizations.of(context).formatMediumDate(local);
    return '$date، ${_formatTimeOnly(local)}';
  }

  Widget _correctionHistoryItem(SessionCorrectionItem item) {
    final financialMessage = switch (item.financialStatus) {
      'pending' => 'الأثر المالي قيد المعالجة.',
      'applied' => 'تم تطبيق الأثر المالي.',
      'financial_review_required' => 'الأثر المالي يحتاج إلى مراجعة.',
      _ => null,
    };

    return _detailCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'قبل التصحيح',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text('البداية: ${_formatCorrectionDateTime(item.beforeStartedAt)}'),
          Text('النهاية: ${_formatCorrectionDateTime(item.beforeEndedAt)}'),
          const SizedBox(height: 8),
          const Text(
            'بعد التصحيح',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text('البداية: ${_formatCorrectionDateTime(item.afterStartedAt)}'),
          Text('النهاية: ${_formatCorrectionDateTime(item.afterEndedAt)}'),
          const SizedBox(height: 8),
          const Text(
            'سبب التصحيح',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(item.reason),
          const SizedBox(height: 8),
          Text('تم الاعتماد: ${_formatCorrectionDateTime(item.acceptedAt)}'),
          if (financialMessage != null) Text(financialMessage),
          if (item.financialStatus == 'financial_review_required' &&
              (item.financialReviewReason?.trim().isNotEmpty ?? false))
            Text(item.financialReviewReason!.trim()),
        ],
      ),
    );
  }

  Widget _correctionHistorySection() {
    final history = _correctionHistory;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'سجل التصحيحات',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        TextButton(
          key: const Key('session_correction_history_toggle'),
          onPressed: _historyLoading ? null : _toggleCorrectionHistory,
          child: Text(
            _historyExpanded ? 'إخفاء سجل التصحيحات' : 'عرض سجل التصحيحات',
          ),
        ),
        if (_historyExpanded) ...[
          if (_historyLoading) const Text('جارٍ تحميل سجل التصحيحات...'),
          if (_historyError case final error?) ...[
            Text(error),
            TextButton(
              onPressed: _retryCorrectionHistory,
              child: const Text('إعادة المحاولة'),
            ),
          ],
          if (!_historyLoading &&
              _historyError == null &&
              _historyLoaded &&
              _historySessionId == _detailData?.session.id &&
              history?.items.isEmpty == true)
            const Text('لا توجد تصحيحات مسجلة لهذه الجلسة.'),
          if (!_historyLoading &&
              _historyError == null &&
              _historyLoaded &&
              _historySessionId == _detailData?.session.id &&
              history != null)
            for (final item in history.items) _correctionHistoryItem(item),
        ],
      ],
    );
  }

  Future<void> _recordDeferredPayment() async {
    if (!_canRecordPayment) return;
    setState(() => _paymentOpening = true);
    try {
      await _restorePaymentState();
      final state = _paymentState;
      if (state == null || !state.canRecordPayment || !mounted) return;
      final record = state.record;
      final session = _detailData?.session;
      final amount = session?.hasCharge == true
          ? session!.totalAmountYER
          : record.approvedAmountMinor ?? record.totals.accruedMinor;
      if (amount == null ||
          amount <= 0 ||
          record.farmerReference == null ||
          record.wellId == null) {
        return;
      }
      final saved = await showDialog<bool>(
        context: context,
        builder: (_) => PaymentReceiptDialog(
          wellName: widget.wellName,
          operatorName: session?.operatorName ?? '—',
          farmerName: session?.farmerName ?? record.farmerName ?? '—',
          farmName: session?.farmName ?? record.farmName ?? '—',
          energySource: energySourceLabel(record.currentEnergySource),
          hourlyRateYER: null,
          billableSeconds:
              session?.billableSeconds ?? record.totals.billableSeconds,
          actualSeconds:
              session?.actualSeconds ?? record.totals.wallClockSeconds,
          totalAmountYER: amount,
          amountApproved:
              session?.hasCharge == true || record.approvedAmountMinor != null,
          onConfirmPayment:
              ({
                required paidAmountYER,
                required paymentMethod,
                required isFullySettled,
              }) async {
                await _coordinator.recordPayment(
                  accountId: record.accountId,
                  wellId: record.wellId!,
                  farmerAccountId: record.farmerReference!,
                  amountMinor: paidAmountYER,
                  paymentMethod: paymentMethod,
                  sessionLocalId: record.localId,
                  sessionCompletionLocalId: record.completionCommandLocalId,
                  note: 'دفعة جلسة سقي',
                );
                await _restorePaymentState();
              },
        ),
      );
      if (saved == true && mounted) {
        await _restorePaymentState();
        // التحديث المالي يأتي من حدث المنسق القائم، لا من نجاح زر الحفظ.
      }
    } finally {
      if (mounted) setState(() => _paymentOpening = false);
    }
  }

  Widget _paymentMessages() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (_localCompletion case final local?) Text(local.syncState.text),
      if (_usingCachedRead)
        const Text(
          'قراءة محفوظة على الجهاز',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      if (_paymentState?.needsCanonicalRead == true)
        const Text('بانتظار تحديث حالة السداد من الخادم'),
      for (final payment
          in _localCompletion?.payments ?? const <LocalPayment>[])
        if (!payment.isPosted)
          Text(
            payment.status.name == 'review'
                ? 'دفعة تحتاج مراجعة'
                : 'دفعة معلقة — بانتظار المزامنة',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.deepBlue,
            ),
          )
        else if (payment.acceptedReceipt?['public_code'] case final String code)
          Text('سند قبض: $code', style: const TextStyle(fontSize: 12)),
    ],
  );

  Widget _paymentButton() => FilledButton.icon(
    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
    onPressed: _canRecordPayment ? _recordDeferredPayment : null,
    icon: const Icon(Icons.payments_outlined),
    label: const Text('تسجيل دفعة'),
  );

  Widget _localPaymentView() {
    final record = _paymentState!.record;
    return Scaffold(
      appBar: AppBar(title: const Text('تفاصيل الجلسة')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(record.farmerName ?? 'اسم المزارع غير متاح محليًا'),
              Text(record.farmName ?? 'اسم الأرض غير متاح محليًا'),
              if (record.approvedAmountMinor case final amount?) ...[
                const Text('تكلفة الجلسة المعتمدة'),
                CurrencyDisplay(amount: amount, showTafqeet: false),
                Text(
                  '${SessionCompletionResult.amountWords(amount)} فقط',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
              _paymentMessages(),
              const Text('تفاصيل السداد والفاتورة تحتاج قراءة الخادم'),
              if (_canRecordPayment) _paymentButton(),
              if (_loadError != null) Text(_loadError!),
              TextButton(
                onPressed: _loadDetail,
                child: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _refreshFinance() async {
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    do {
      _refreshAgain = false;
      final generation = ++_loadGeneration;
      try {
        await _restorePaymentState();
        final revision = _paymentState?.revision;
        final detail = await _repo.fetchSessionDetail(widget.sessionId);
        if (mounted && generation == _loadGeneration) {
          await _rememberPaymentRead(detail, revision);
          if (mounted && generation == _loadGeneration) {
            setState(() {
              _replaceDetailData(detail);
              _usingCachedRead = false;
            });
          }
        }
      } catch (_) {
        /* لا نحول فشل التحديث إلى حقيقة مالية. */
      }
    } while (mounted && _refreshAgain);
    _refreshing = false;
  }

  @override
  void dispose() {
    _completionSubscription?.cancel();
    super.dispose();
  }

  bool _isLoading = true;
  String? _loadError;
  SessionDetailData? _detailData;

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? const OperationsRepository();
    _localCompletion = widget.initialResult;
    if (widget.accountId != null && widget.wellId != null) {
      _completionSubscription =
          (widget.coordinator ?? OfflineSessionCoordinator.instance)
              .watchCompletionResult(
                accountId: widget.accountId!,
                wellId: widget.wellId!,
                serverSessionId: widget.sessionId,
              )
              .listen(_onCompletion);
    }
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    final generation = ++_loadGeneration;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      await _restorePaymentState();
      final revision = _paymentState?.revision;
      final data = await _repo.fetchSessionDetail(widget.sessionId);
      if (mounted && generation == _loadGeneration) {
        await _rememberPaymentRead(data, revision);
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          _usingCachedRead = false;
          _replaceDetailData(data);
          _isLoading = false;
        });
      }
    } catch (_) {
      // م-41C2: لا تفصيل جلسة وهمي — الفشل يظهر مع إعادة المحاولة.
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _loadError =
              'تعذّر تحميل تفاصيل الجلسة. تحقق من الاتصال ثم أعد المحاولة.';
          _isLoading = false;
        });
      }
    }
  }

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    if (hours > 0) {
      return '$hours س و $minutes د و $secs ث';
    } else if (minutes > 0) {
      return '$minutes د و $secs ث';
    } else {
      return '$secs ثانية';
    }
  }

  String _formatTimeOnly(DateTime dt) {
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final period = dt.hour >= 12 ? 'م' : 'ص';
    final minute = dt.minute.toString().padLeft(2, '0');
    final sec = dt.second.toString().padLeft(2, '0');
    return '$hour:$minute:$sec $period';
  }

  void _showPrintPreview() {
    if (_detailData == null) return;
    final session = _detailData!.session;

    // ق-99: لا نطبع فاتورة لجلسة لم تُعتمد التكلفة بعد بدل اختراع أصفار.
    if (!session.hasCharge) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('التكلفة المالية لهذه الجلسة لم تُعتمد بعد'),
        ),
      );
      return;
    }

    final receiptText =
        'ملخص الجلسة — ليس فاتورة أو سند قبض\n'
        'المزارع: ${session.farmerName}\n'
        'الأرض: ${session.farmName}\n'
        'مدة التنفيذ الفعلية: ${session.actualSeconds == null ? '—' : _formatDuration(session.actualSeconds!)}\n'
        'الوقت المفوتر: ${_formatDuration(session.billableSeconds)}\n'
        'تكلفة الجلسة المعتمدة: ${CurrencyUtils.formatAmount(session.totalAmountYER)} ريال\n'
        'المدفوع وفق قراءة الخادم: ${CurrencyUtils.formatAmount(session.paidAmountYER)} ريال';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.article_outlined, color: AppColors.deepBlue),
            SizedBox(width: 8),
            Text('ملخص الجلسة', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: Container(
          width: double.maxFinite,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFFAF9F6),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: SingleChildScrollView(
            child: Text(
              receiptText,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.4,
                color: Colors.black87,
              ),
              textDirection: TextDirection.ltr,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: receiptText));
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('تم نسخ ملخص الجلسة')),
              );
            },
            child: const Text('نسخ النص'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.deepBlue,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.print, size: 18),
            label: const Text('الطباعة غير متاحة حاليًا'),
            onPressed: () {
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('الطباعة غير متاحة حاليًا')),
              );
            },
          ),
        ],
      ),
    );
  }

  void _shareReceiptText() {
    if (_detailData == null) return;
    final s = _detailData!.session;

    final String moneyBlock;
    if (!s.hasCharge) {
      // ق-99: الجلسة غير المفوترة تُشارك بلا مبالغ مخترعة.
      moneyBlock = 'الحالة: لم تُعتمد الحالة المالية بعد — لا مبلغ مستحق مسجل';
    } else {
      moneyBlock =
          '''
المبلغ: ${CurrencyUtils.formatAmount(s.totalAmountYER)} ريال يمني (${SessionCompletionResult.amountWords(s.totalAmountYER)})
المدفوع: ${CurrencyUtils.formatAmount(s.paidAmountYER)} ريال يمني
المتبقي: ${CurrencyUtils.formatAmount(s.remainingAmountYER)} ريال يمني
الحالة: ${s.isFullySettled ? 'خالص بالكامل ✅' : 'آجل / متبقي 🔴'}''';
    }

    // المدة التشغيلية بالفعلي أولًا وبعنوان صريح (ق-131 البند 7)،
    // والمفوتر لا يظهر إلا مميزًا حين يختلف عنه.
    final durationBlock = StringBuffer(
      'مدة التنفيذ الفعلية: ${s.actualSeconds == null ? '—' : _formatDuration(s.actualSeconds!)}',
    );
    if (s.hasCharge &&
        s.actualSeconds != null &&
        s.billableSeconds != s.actualSeconds) {
      durationBlock.write(
        '\nالوقت المفوتر: ${_formatDuration(s.billableSeconds)}',
      );
    }

    final text =
        '''
إشعار سقي — ${widget.wellName}
المزارع: ${s.farmerName} (${s.farmerCode})
الأرض: ${s.farmName}
المضخة: ${s.pumpName}
التاريخ: ${s.startedAt.year}/${s.startedAt.month}/${s.startedAt.day}
$durationBlock
$moneyBlock
''';

    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('تم نسخ ملخص الجلسة للمشاركة عبر واتساب 📤'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_detailData == null && _paymentState != null) {
      return _localPaymentView();
    }
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('تفاصيل الجلسة')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_detailData == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('تفاصيل الجلسة')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.cloud_off_rounded,
                  size: 56,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  _loadError ?? 'لم يتم العثور على بيانات الجلسة',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _loadDetail,
                  icon: const Icon(Icons.refresh),
                  label: const Text('إعادة المحاولة'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final data = _detailData!;
    final session = data.session;

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        toolbarHeight:
            kToolbarHeight * MediaQuery.textScalerOf(context).scale(16) / 16,
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'تفاصيل جلسة',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
            Text(
              widget.wellName,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _paymentMessages(),
              if (_correctionOutcome case final message?) ...[
                if (_correctionOutcomeIsCurrent) ...[
                  Semantics(liveRegion: true, child: Text(message)),
                  if (_historicalCorrectionOutcome case final historical?)
                    Text(historical),
                ],
                if (session.effectiveStartedAt case final start?)
                  Text('البداية الفعلية: ${_correctionTime(start)}'),
                if (session.effectiveEndedAt case final end?)
                  Text('النهاية الفعلية: ${_correctionTime(end)}'),
                const SizedBox(height: 8),
              ],
              // 1. كرت الملخص العام
              _buildSummaryCard(session, crops: data.crops),

              if (_canShowCorrectionAction)
                OutlinedButton(
                  onPressed: _openSessionCorrection,
                  child: const Text('تصحيح السجل'),
                ),

              if (data.canReadSessionCorrections) ...[
                const SizedBox(height: 8),
                _correctionHistorySection(),
              ],

              const SizedBox(height: 8),

              // 2. الخط الزمني للجلسة (Timeline)
              _buildTimelineSection(data.segments),

              const SizedBox(height: 8),

              // 3. قسم التسوية والدفعات
              _buildSettlementCard(data),
              const SizedBox(height: 8),

              // 4. أزرار الإجراءات السريعة
              LayoutBuilder(
                builder: (context, constraints) {
                  final stacked =
                      MediaQuery.textScalerOf(context).scale(14) > 18;
                  final width = stacked
                      ? constraints.maxWidth
                      : (constraints.maxWidth - 8) / 2;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (_canRecordPayment)
                        SizedBox(
                          width: constraints.maxWidth,
                          child: _paymentButton(),
                        ),
                      SizedBox(
                        width: width,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            side: const BorderSide(color: AppColors.deepBlue),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: const Icon(
                            Icons.share,
                            color: AppColors.deepBlue,
                            size: 18,
                          ),
                          label: const Text(
                            'مشاركة الملخص',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.deepBlue,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          onPressed: _shareReceiptText,
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.deepBlue,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(48, 48),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: const Icon(Icons.article_outlined, size: 18),
                          label: const Text(
                            'عرض ملخص الجلسة',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          onPressed: _showPrintPreview,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryCard(
    SessionHistoryItem session, {
    List<String> crops = const [],
  }) {
    // ق-99: أربع حالات كما يحسمها العقد، لا ثنائية «خالص / غير مدفوع».
    final Color statusColor;
    final String statusText;
    if (!session.hasCharge) {
      statusColor = AppColors.textMuted;
      statusText = 'الحالة المالية لم تُعتمد بعد';
    } else if (session.isFullySettled) {
      statusColor = AppColors.agriculturalGreen;
      statusText = 'خالص بالكامل ✅';
    } else if (session.paymentStatus == 'partial') {
      statusColor = AppColors.warning;
      statusText = 'دفعة جزئية';
    } else {
      statusColor = AppColors.error;
      statusText = 'آجل / غير مدفوع 🔴';
    }

    return _detailCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            session.farmerName,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          Text(
            '${session.farmName} • كود: ${session.farmerCode}',
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'السداد لدى الخادم',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
                Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = MediaQuery.textScalerOf(context).scale(13) > 20;
              final width = stacked
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 8) / 2;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: width,
                    child: _buildDetailCell(
                      'المضخة',
                      session.pumpName,
                      Icons.water_drop_outlined,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _buildDetailCell(
                      'المشغل',
                      session.operatorName,
                      Icons.badge_outlined,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _buildDetailCell(
                      'مدة التنفيذ الفعلية',
                      session.actualSeconds == null
                          ? '—'
                          : _formatDuration(session.actualSeconds!),
                      Icons.timer_outlined,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _buildDetailCell(
                      'تكلفة الجلسة',
                      session.hasCharge
                          ? '${CurrencyUtils.formatAmount(session.totalAmountYER)} ريال'
                          : 'لم تُعتمد التكلفة بعد',
                      Icons.payments_outlined,
                      isBold: true,
                      secondary: session.hasCharge
                          ? '${SessionCompletionResult.amountWords(session.totalAmountYER)} فقط'
                          : null,
                    ),
                  ),
                ],
              );
            },
          ),
          if (crops.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'المحاصيل: ${crops.join('، ')}',
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailCard({required Widget child}) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: AppColors.border),
    ),
    child: Padding(padding: const EdgeInsets.all(12), child: child),
  );

  Widget _buildDetailCell(
    String label,
    String value,
    IconData icon, {
    bool isBold = false,
    String? secondary,
  }) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Icon(icon, size: 16, color: AppColors.waterBlue),
      ),
      const SizedBox(width: 4),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: isBold ? 16 : 13,
                fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
                color: isBold ? AppColors.deepBlue : AppColors.textPrimary,
              ),
            ),
            if (secondary != null)
              Text(
                secondary,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _buildTimelineSection(List<SessionSegmentItem> segments) =>
      _detailCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'الخط الزمني وتغيرات الطاقة',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: AppColors.deepBlue,
              ),
            ),
            const SizedBox(height: 8),
            if (segments.isEmpty)
              const Text(
                'لا توجد تفاصيل مقاطع مسجلة',
                style: TextStyle(fontSize: 13, color: AppColors.textMuted),
              )
            else
              for (var index = 0; index < segments.length; index++) ...[
                if (index > 0) const Divider(height: 16),
                _buildTimelineItem(segments[index]),
              ],
          ],
        ),
      );

  Widget _buildTimelineItem(SessionSegmentItem seg) {
    final isPause = seg.isStop;
    final isSolar = seg.energySourceCode == 'solar';
    final color = isPause
        ? AppColors.warning
        : (isSolar ? AppColors.agriculturalGreen : Colors.orange);
    final icon = isPause
        ? Icons.pause_circle_outline
        : (isSolar
              ? Icons.wb_sunny_outlined
              : Icons.local_gas_station_outlined);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    isPause ? seg.typeLabel : 'تشغيل عبر ${seg.energySource}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: isPause ? AppColors.warning : AppColors.deepBlue,
                    ),
                  ),
                  Text(
                    _formatTimeOnly(seg.startedAt),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
              if (isPause) ...[
                Text(
                  'محسوب على المزارع: ${seg.isBillable ? 'نعم' : 'لا'}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                Text(
                  'مدة التوقف: ${_formatDuration(seg.actualSeconds)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ] else ...[
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Text(
                      'المدة: ${_formatDuration(seg.actualSeconds)} • المحسوبة: ${_formatDuration(seg.billableSeconds)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Text(
                      '${CurrencyUtils.formatAmount(seg.totalChargeYER)} ريال',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: AppColors.deepBlue,
                      ),
                    ),
                  ],
                ),
                if (seg.appliedRateYER > 0)
                  Text(
                    'التسعيرة المثبتة: ${CurrencyUtils.formatAmount(seg.appliedRateYER)} ر/س',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSettlementCard(SessionDetailData data) {
    final s = data.session;
    return _detailCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'تفاصيل السداد',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepBlue,
                ),
              ),
              Text(
                'وفق قراءة الخادم',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              final stacked = MediaQuery.textScalerOf(context).scale(14) > 20;
              final width = stacked
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 16) / 3;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: width,
                    child: _paymentAmount(
                      'المستحق',
                      s.totalAmountYER,
                      AppColors.deepBlue,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _paymentAmount(
                      'المدفوع',
                      s.paidAmountYER,
                      AppColors.agriculturalGreen,
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _paymentAmount(
                      'المتبقي',
                      s.remainingAmountYER,
                      s.remainingAmountYER > 0
                          ? AppColors.error
                          : AppColors.textMuted,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                'طريقة السداد: ${data.paymentMethod == null ? 'غير مسجلة' : SessionCompletionResult.methodLabel(data.paymentMethod!)}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (data.paidAt != null)
                Text(
                  'تاريخ السداد: ${SessionCompletionResult.dateTimeLabel(context, data.paidAt!)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
            ],
          ),
          Text(
            s.hasInvoice
                ? 'توجد فاتورة مسجلة لدى الخادم'
                : 'لا توجد فاتورة مسجلة',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _paymentAmount(String label, int amount, Color color) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
      ),
      CurrencyDisplay(
        amount: amount,
        unit: 'ريال',
        showTafqeet: false,
        amountStyle: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: color,
        ),
        unitStyle: const TextStyle(
          fontSize: 12,
          color: AppColors.textSecondary,
        ),
      ),
    ],
  );
}

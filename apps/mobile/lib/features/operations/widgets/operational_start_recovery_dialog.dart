import 'package:flutter/material.dart';

import '../../../core/session/operational_start_recovery.dart';

/// أزرار الحل مبنية على الدليل المقروء؛ الرجوع لا يسوّي أو يرسل أي أمر.
class OperationalStartRecoveryDialog extends StatefulWidget {
  const OperationalStartRecoveryDialog({
    required this.recovery,
    required this.accountId,
    required this.wellId,
    required this.sessionLocalId,
    required this.startedAt,
    required this.isContextCurrent,
    required this.onResolved,
    this.farmerName,
    this.farmName,
    super.key,
  });
  final OperationalStartRecovery recovery;
  final String accountId, wellId, sessionLocalId;
  final DateTime startedAt;
  final String? farmerName, farmName;
  final bool Function() isContextCurrent;
  final Future<void> Function() onResolved;
  @override
  State<OperationalStartRecoveryDialog> createState() =>
      _OperationalStartRecoveryDialogState();
}

class _OperationalStartRecoveryDialogState
    extends State<OperationalStartRecoveryDialog> {
  OperationalStartRecoveryObservation? _result;
  bool _busy = false, _departed = false, _resolutionConsumed = false;
  bool _contextInvalidated = false;
  int _generation = 0;
  final _resolutionReason = TextEditingController();
  bool _confirmedNonExecution = false;
  bool? _legacy;
  @override
  void initState() {
    super.initState();
    _loadMode();
  }

  Future<void> _loadMode() async {
    final generation = _generation;
    final value = await widget.recovery.isLegacyRoot(
      accountId: widget.accountId,
      sessionLocalId: widget.sessionLocalId,
    );
    if (mounted && !_departed && generation == _generation) {
      setState(() => _legacy = value);
    }
  }

  @override
  void dispose() {
    _resolutionReason.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant OperationalStartRecoveryDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId ||
        oldWidget.wellId != widget.wellId ||
        oldWidget.sessionLocalId != widget.sessionLocalId ||
        oldWidget.recovery != widget.recovery) {
      _generation++;
      _result = null;
      _busy = false;
      _resolutionConsumed = false;
      _contextInvalidated = false;
      _legacy = null;
      _loadMode();
    }
  }

  bool get _validContext => mounted && !_departed && widget.isContextCurrent();
  bool get _owns =>
      _validContext && (ModalRoute.of(context)?.isCurrent ?? false);

  void _close([bool resolved = false]) {
    if (_departed || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
    _departed = true;
    _generation++;
    Navigator.of(context).pop(resolved);
  }

  Future<void> _run({bool adopt = false, bool resolveRejected = false}) async {
    if (mounted && !_departed && !widget.isContextCurrent()) {
      setState(() {
        _contextInvalidated = true;
        _busy = false;
        _result = null;
      });
      return;
    }
    if (_busy || !_owns || _resolutionConsumed) return;
    final observed = _result;
    if (adopt && observed?.canAdopt != true) return;
    if (resolveRejected &&
        (observed?.canResolveRejected != true ||
            !_confirmedNonExecution ||
            _resolutionReason.text.trim().isEmpty)) {
      return;
    }
    final generation = ++_generation;
    setState(() => _busy = true);
    final result = _legacy == true
        ? await widget.recovery.repairLegacyStart(
            accountId: widget.accountId,
            wellId: widget.wellId,
            sessionLocalId: widget.sessionLocalId,
            isContextCurrent: () => _validContext && generation == _generation,
          )
        : resolveRejected
        ? await widget.recovery.resolveRejectedStart(
            observed!,
            reason: _resolutionReason.text,
            confirmed: _confirmedNonExecution,
          )
        : adopt
        ? await widget.recovery.adopt(observed!)
        : await widget.recovery.check(
            accountId: widget.accountId,
            wellId: widget.wellId,
            sessionLocalId: widget.sessionLocalId,
          );
    if (!mounted || _departed || generation != _generation) return;
    if (!widget.isContextCurrent()) {
      setState(() {
        _contextInvalidated = true;
        _busy = false;
        _result = null;
      });
      return;
    }
    setState(() {
      _result = result;
      _busy = false;
    });
    if (result.state == OperationalStartRecoveryState.resolved &&
        !_resolutionConsumed) {
      _resolutionConsumed = true;
      try {
        await widget.onResolved();
      } on Object {
        // اعتماد الإيصال نجح؛ فشل تحديث العرض لا يحوّله إلى فشل أو إرسال جديد.
        return;
      }
      // يبقى النجاح ظاهرًا حتى يختار المستخدم العودة؛ لا تنقل تلقائي متأخر.
    }
  }

  String get _message {
    final result = _result;
    if (_contextInvalidated) {
      return 'تغيرت حالة الجلسة أو البئر. أغلق النافذة وأعد فتحها من الجلسة الحالية.';
    }
    if (_legacy == true) {
      if (_busy) {
        return 'جارٍ إصلاح الحالة اعتمادًا على الحالة الحالية في الخادم.';
      }
      if (result?.state == OperationalStartRecoveryState.resolved) {
        return result?.restoredCurrentSession != true
            ? 'تم إصلاح الحالة. يمكنك بدء جلسة جديدة.'
            : 'تم استعادة الجلسة الحالية ويمكنك متابعة التشغيل.';
      }
      if (result?.state == OperationalStartRecoveryState.offline) {
        return 'تعذر الاتصال بالخادم.';
      }
      if (result != null) {
        return 'تعذر التحقق من الحالة بأمان. أغلق النافذة وأعد فتحها من البئر الصحيح.';
      }
      return 'توجد مشكلة قديمة في حالة الجلسة. يمكن للتطبيق إصلاحها اعتمادًا على الحالة الحالية في الخادم.';
    }
    if (_busy) return 'جارٍ التحقق من حالة الجلسة. لن يتم إنشاء جلسة جديدة.';
    if (result == null) {
      return 'سنراجع حالة الجلسة على الخادم. لن يتم إنشاء جلسة جديدة أثناء التحقق.';
    }
    return switch (result.state) {
      OperationalStartRecoveryState.serverSessionFound =>
        'تم العثور على الجلسة المطابقة على الخادم.',
      OperationalStartRecoveryState.stillProcessing => 'ما زال الخادم يتحقق من محاولة البدء. المحاولة محفوظة ويمكنك مغادرة هذه الصفحة.',
      OperationalStartRecoveryState.offline =>
        'تعذر تحميل حالة الجلسة. المحاولة محفوظة؛ أعد التحقق عند توفر الاتصال.',
      OperationalStartRecoveryState.resolved =>
        result.session == null
            ? 'تم إنهاء المحاولة السابقة ويمكنك بدء جلسة جديدة عند الحاجة.'
            : 'تمت استعادة حالة الجلسة.',
      OperationalStartRecoveryState.unresolvedManualReview =>
        switch (result.issue) {
          OperationalStartRecoveryIssue.terminalRejected =>
            'تم التأكد أن محاولة البدء السابقة لم تُنشئ جلسة.',
          OperationalStartRecoveryIssue.dependentUnresolved => 'توجد إجراءات مرتبطة بالمحاولة لم تُحسم نتيجتها بعد. أعد التحقق؛ لا يمكن إنهاء المحاولة قبل التأكد من حالتها.',
          OperationalStartRecoveryIssue.canonicalDisagreement => 'تختلف حالة الجلسة على الخادم عن السجل المحلي. يلزم مراجعة الحالة مع مدير البئر قبل المتابعة؛ لن نغيّر أوقات التشغيل أو طلب الإيقاف تلقائيًا.',
          OperationalStartRecoveryIssue.scope => 'تغير الحساب أو تعذر مطابقة بيانات الجلسة. أغلق النافذة وافتحها من البئر الصحيح ثم أعد التحقق.',
          _ => 'لم نتمكن من التأكد من نتيجة المحاولة بأمان. أعد التحقق، وإذا استمرت الحالة فراجع مدير البئر ببيانات الجلسة أدناه.',
        },
    };
  }

  String get _blockingMessage {
    if (_result?.state == OperationalStartRecoveryState.serverSessionFound) {
      return 'لا يمكن بدء جلسة بديلة. اعتمد الجلسة الموجودة للمتابعة.';
    }
    if (_result?.issue == OperationalStartRecoveryIssue.terminalRejected) {
      return 'المحاولة السابقة ما زالت مفتوحة في السجل المحلي؛ يلزم إغلاق معتمد قبل البدء من جديد.';
    }
    if (_result?.issue == OperationalStartRecoveryIssue.canonicalDisagreement) {
      return 'لا يمكن بدء جلسة بديلة قبل تسوية اختلاف حالة الجلسة.';
    }
    return 'لا يمكن بدء جلسة جديدة حتى نتأكد من نتيجة المحاولة السابقة لتجنب التكرار.';
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final started = widget.startedAt.toLocal();
    final date = localizations.formatFullDate(started);
    final time = localizations.formatTimeOfDay(TimeOfDay.fromDateTime(started));
    final session = _result?.session;
    return PopScope<bool>(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _departed = true;
          _generation++;
        }
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(_legacy == true ? 'إصلاح الحالة' : 'حل مشكلة بدء الجلسة'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(liveRegion: true, child: Text(_message)),
              if (_busy)
                const LinearProgressIndicator(
                  semanticsLabel: 'التحقق من حالة الجلسة',
                ),
              if (_legacy != true &&
                  !_contextInvalidated &&
                  _result?.state != OperationalStartRecoveryState.resolved)
                Text(_blockingMessage),
              if (!_contextInvalidated)
                Text(
                  'المزارع: ${session?.farmerName ?? widget.farmerName ?? 'غير متاح'}',
                ),
              if (!_contextInvalidated)
                Text(
                  'الأرض: ${session?.farmName ?? widget.farmName ?? 'غير متاحة'}',
                ),
              if (!_contextInvalidated) Text('وقت البدء المسجل: $date، $time'),
              if (_legacy != true && _result?.canResolveRejected == true) ...[
                TextField(
                  controller: _resolutionReason,
                  enabled: !_busy,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'سبب إنهاء المحاولة',
                  ),
                ),
                CheckboxListTile(
                  value: _confirmedNonExecution,
                  onChanged: _busy
                      ? null
                      : (value) => setState(
                          () => _confirmedNonExecution = value == true,
                        ),
                  title: const Text(
                    'أؤكد إنهاء المحاولة السابقة فقط دون بدء جلسة جديدة',
                  ),
                ),
              ],
              const Text(
                'طلبات الإيقاف السابقة تبقى محفوظة في السجل، ولن تُرسل تلقائيًا على الحالة المعتمدة. إذا احتجت إلى الإيقاف بعدها فاستخدم إجراء الإيقاف من صفحة التشغيل.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => _close(
                _result?.state == OperationalStartRecoveryState.resolved,
              ),
              child: Text(_resolutionConsumed ? 'العودة إلى التشغيل' : 'إغلاق'),
            ),
            if (!_contextInvalidated && _result?.canResolveRejected == true)
              FilledButton(
                onPressed:
                    _busy ||
                        !_confirmedNonExecution ||
                        _resolutionReason.text.trim().isEmpty
                    ? null
                    : () => _run(resolveRejected: true),
                child: const Text('إنهاء المحاولة السابقة'),
              ),
            if (!_contextInvalidated && _result?.canAdopt == true)
              FilledButton(
                onPressed: _busy ? null : () => _run(adopt: true),
                child: const Text('اعتماد الجلسة والمتابعة'),
              ),
            if (!_contextInvalidated && !_resolutionConsumed)
              TextButton(
                onPressed: _busy || _legacy == null ? null : () => _run(),
                child: Text(
                  _legacy == true
                      ? (_result == null ? 'إصلاح الحالة' : 'إعادة المحاولة')
                      : (_result == null
                            ? 'التحقق من حالة الجلسة'
                            : 'إعادة التحقق'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

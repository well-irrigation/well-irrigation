import 'package:flutter/material.dart';

import '../../core/session/offline_session_coordinator.dart';
import '../../core/sync/command_envelope.dart';
import '../../core/sync/session_correction_receipt.dart';
import '../../core/sync/outbox_store.dart' show SessionCorrectionConflict;
import '../../core/sync/sync_status.dart';

class SessionCorrectionAcceptedResult {
  const SessionCorrectionAcceptedResult({
    required this.localId,
    required this.commandId,
    required this.accepted,
  });

  final String localId;
  final String commandId;
  final SessionCorrectionReceiptResponse accepted;
}

/// يحفظ طلب التصحيح من لقطة الفتح دون الادعاء بتحديث التفاصيل الخادمية.
class SessionCorrectionScreen extends StatefulWidget {
  const SessionCorrectionScreen({
    required this.sessionId,
    required this.effectiveStartedAt,
    required this.effectiveEndedAt,
    required this.operationalRevision,
    this.coordinator,
    this.accountId,
    this.wellId,
    super.key,
  });

  final OfflineSessionCoordinator? coordinator;
  final String? accountId;
  final String? wellId;
  final String sessionId;
  final DateTime effectiveStartedAt;
  final DateTime effectiveEndedAt;
  final int operationalRevision;

  @override
  State<SessionCorrectionScreen> createState() =>
      _SessionCorrectionScreenState();
}

class _SessionCorrectionScreenState extends State<SessionCorrectionScreen> {
  late DateTime _startedAt;
  late DateTime _endedAt;
  late final TextEditingController _startController;
  late final TextEditingController _endController;
  final _reasonController = TextEditingController();
  CommandEnvelope? _submittedCommand;
  bool _refreshingCorrection = false;
  bool _submitting = false;
  bool _submissionLocked = false;
  String? _submissionMessage;

  bool get _fieldsLocked => _submitting || _submissionLocked;
  bool get _hasExecutionContext =>
      widget.coordinator != null &&
      widget.accountId?.trim().isNotEmpty == true &&
      widget.wellId?.trim().isNotEmpty == true;

  Future<void> _submit() async {
    if (_fieldsLocked || !_hasExecutionContext ||
        _reasonError != null || _timeError != null) return;
    setState(() {
      _submitting = true;
      _submissionMessage = null;
    });
    try {
      final envelope = await widget.coordinator!.submitSessionCorrection(
        accountId: widget.accountId!,
        wellId: widget.wellId!,
        sessionId: widget.sessionId,
        baseRevision: widget.operationalRevision,
        reason: _reasonController.text.trim(),
        desiredStartedAt: _startedAt,
        desiredEndedAt: _endedAt,
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submissionLocked = true;
        _submittedCommand = envelope;
        _submissionMessage = switch (envelope.status) {
          CommandStatus.pending || CommandStatus.dispatching =>
            'تم حفظ طلب التصحيح، وسيتم التحقق من النتيجة عند المزامنة.',
          CommandStatus.review =>
            'هذا التصحيح يحتاج إلى مراجعة قبل المتابعة.',
          CommandStatus.confirmed =>
            'تم حفظ طلب التصحيح. سيتم تحديث تفاصيل الجلسة من الخادم.',
        };
      });
    } on SessionCorrectionConflict {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submissionLocked = true;
        _submissionMessage = 'يوجد تصحيح سابق غير محسوم لهذه الجلسة.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submissionLocked = false;
        _submissionMessage = 'تعذر حفظ التصحيح. حاول مرة أخرى.';
      });
    }
  }

  Future<void> _refreshCorrection() async {
    final command = _submittedCommand;
    if (_refreshingCorrection || command == null || !_hasExecutionContext) return;
    setState(() => _refreshingCorrection = true);
    try {
      final observation = await widget.coordinator!.readSessionCorrectionCommand(
        accountId: widget.accountId!,
        wellId: widget.wellId!,
        sessionId: widget.sessionId,
        localId: command.localId,
        commandId: command.commandId,
      );
      if (!mounted) return;
      if (observation == null) throw StateError('Missing correction command');
      final accepted = observation.accepted;
      if (observation.command.status == CommandStatus.confirmed) {
        if (accepted == null ||
            accepted.state != SessionCorrectionReceiptState.accepted ||
            accepted.receipt == null) {
          throw StateError('Missing accepted correction evidence');
        }
        Navigator.of(context).pop(SessionCorrectionAcceptedResult(
          localId: command.localId,
          commandId: command.commandId,
          accepted: accepted,
        ));
        return;
      }
      setState(() {
        _refreshingCorrection = false;
        _submissionMessage = observation.command.status == CommandStatus.review
            ? 'هذا التصحيح يحتاج إلى مراجعة قبل المتابعة.'
            : 'تم حفظ طلب التصحيح، وسيتم التحقق من النتيجة عند المزامنة.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _refreshingCorrection = false;
        _submissionMessage = 'تعذر التحقق من حالة التصحيح. حاول مرة أخرى.';
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _startedAt = widget.effectiveStartedAt;
    _endedAt = widget.effectiveEndedAt;
    _startController = TextEditingController(text: _formatTime(_startedAt));
    _endController = TextEditingController(text: _formatTime(_endedAt));
  }

  String? get _reasonError =>
      _reasonController.text.trim().isEmpty ? 'سبب التصحيح مطلوب' : null;

  String? get _timeError {
    if (!_startedAt.isBefore(_endedAt)) {
      return 'يجب أن تكون البداية قبل النهاية';
    }
    if (_endedAt.isAfter(DateTime.now())) {
      return 'لا يمكن أن تكون نهاية الجلسة في المستقبل';
    }
    return null;
  }

  Future<void> _pickTime({required bool start}) async {
    final current = (start ? _startedAt : _endedAt).toLocal();
    final today = DateUtils.dateOnly(DateTime.now());
    final first = DateTime(current.year < 1900 ? current.year : 1900);
    final initial = current.isAfter(today)
        ? today
        : DateUtils.dateOnly(current);
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: today,
      initialEntryMode: DatePickerEntryMode.calendarOnly,
      helpText: start
          ? 'اختر تاريخ البداية الفعلية'
          : 'اختر تاريخ النهاية الفعلية',
    );
    if (!mounted || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      helpText: start ? 'وقت البداية الفعلية' : 'وقت النهاية الفعلية',
    );
    if (!mounted || time == null) return;
    final selected = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() {
      if (start) {
        _startedAt = selected;
        _startController.text = _formatTime(_startedAt);
      } else {
        _endedAt = selected;
        _endController.text = _formatTime(_endedAt);
      }
    });
  }

  String _formatTime(DateTime value) {
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}/${two(local.month)}/${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      appBar: AppBar(title: const Text('تصحيح السجل')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsetsDirectional.all(16),
          children: [
            TextFormField(
              key: const ValueKey('session_correction_start'),
              controller: _startController,
              enabled: !_fieldsLocked,
              readOnly: true,
              onTap: () => _pickTime(start: true),
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'البداية الفعلية'),
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const ValueKey('session_correction_end'),
              controller: _endController,
              enabled: !_fieldsLocked,
              readOnly: true,
              onTap: () => _pickTime(start: false),
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: 'النهاية الفعلية',
                errorText: _timeError,
                errorMaxLines: 3,
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const ValueKey('session_correction_reason'),
              controller: _reasonController,
              enabled: !_fieldsLocked,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'سبب التصحيح',
                errorText: _reasonError,
              ),
              keyboardType: TextInputType.multiline,
              minLines: 3,
              maxLines: null,
            ),
            const SizedBox(height: 16),
            if (!_hasExecutionContext) ...[
              const Text('تعذر تحديد الحساب والبئر لحفظ التصحيح.'),
              const SizedBox(height: 16),
            ],
            if (_submissionMessage case final message?) ...[
              Semantics(liveRegion: true, child: Text(message)),
              const SizedBox(height: 16),
            ],
            if (_submitting) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 16),
            ],
            FilledButton(
              key: const Key('session_correction_submit'),
              onPressed: !_fieldsLocked && _hasExecutionContext &&
                      _reasonError == null && _timeError == null
                  ? _submit
                  : null,
              child: const Text('حفظ التصحيح'),
            ),
            if (_submittedCommand != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                key: const Key('session_correction_refresh'),
                onPressed: _refreshingCorrection ? null : _refreshCorrection,
                child: const Text('تحديث حالة التصحيح'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

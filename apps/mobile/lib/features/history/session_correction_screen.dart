import 'package:flutter/material.dart';

/// نموذج تصحيح يبدأ من لقطة التفاصيل الحية، دون إعادة قراءة أو إرسال.
class SessionCorrectionScreen extends StatefulWidget {
  const SessionCorrectionScreen({
    required this.sessionId,
    required this.effectiveStartedAt,
    required this.effectiveEndedAt,
    required this.operationalRevision,
    super.key,
  });

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
              readOnly: true,
              onTap: () => _pickTime(start: true),
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'البداية الفعلية'),
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const ValueKey('session_correction_end'),
              controller: _endController,
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
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'سبب التصحيح',
                errorText: _reasonError,
              ),
              keyboardType: TextInputType.multiline,
              minLines: 3,
              maxLines: null,
            ),
          ],
        ),
      ),
    ),
  );
}

import 'package:flutter/material.dart';

import '../../core/session/active_session_record.dart';
import '../../core/session/offline_session_coordinator.dart';
import '../../core/session/session_business_state.dart';

/// مفتاح عزل محلي فقط؛ لا يحمل بئرًا أو دورًا أو تفويضًا خادميًا.
class LocalAuthAccount {
  const LocalAuthAccount(this.id, {required this.isExpired});

  final String id;
  final bool isExpired;
}

/// شاشة الجلسات المحفوظة على هذا الجهاز حين تعجز قراءة الهوية بسبب الشبكة.
class OfflineSessionRecoveryScreen extends StatefulWidget {
  const OfflineSessionRecoveryScreen({
    required this.accountId,
    required this.sessions,
    required this.coordinator,
    required this.localAuthAccount,
    required this.onRetry,
    super.key,
  });

  final String accountId;
  final List<ActiveSessionRecord> sessions;
  final OfflineSessionCoordinator coordinator;
  final LocalAuthAccount? Function() localAuthAccount;
  final VoidCallback onRetry;

  @override
  State<OfflineSessionRecoveryScreen> createState() =>
      _OfflineSessionRecoveryScreenState();
}

class _OfflineSessionRecoveryScreenState
    extends State<OfflineSessionRecoveryScreen> {
  late List<ActiveSessionRecord> _sessions;
  String? _selectedLocalId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _sessions = widget.sessions;
    if (_sessions.length == 1) _selectedLocalId = _sessions.single.localId;
  }

  @override
  void didUpdateWidget(covariant OfflineSessionRecoveryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId) {
      _selectedLocalId = null;
    }
    if (oldWidget.sessions.length == 1 && widget.sessions.length > 1) {
      _selectedLocalId = null;
    }
    _sessions = widget.sessions;
    if (_sessions.length == 1) _selectedLocalId = _sessions.single.localId;
    if (_sessions.every((s) => s.localId != _selectedLocalId)) {
      _selectedLocalId = null;
    }
  }

  ActiveSessionRecord? get _selected {
    for (final session in _sessions) {
      if (session.localId == _selectedLocalId) return session;
    }
    return null;
  }

  bool get _accountMatches => widget.localAuthAccount()?.id == widget.accountId;

  bool _mayWrite(ActiveSessionRecord session) {
    final auth = widget.localAuthAccount();
    return !_busy &&
        auth != null &&
        auth.id == widget.accountId &&
        !auth.isExpired &&
        session.accountId == widget.accountId &&
        session.businessState.isActive &&
        session.syncState != SessionSyncState.conflict;
  }

  Future<void> _act(
    ActiveSessionRecord session, {
    required String title,
    required String confirmation,
    required Future<void> Function() write,
  }) async {
    if (!_mayWrite(session)) return;
    setState(() => _busy = true);
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: const Text(
            'سيُحفظ الإجراء على هذا الجهاز، وتبقى موافقة الخادم معلّقة.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmation),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;

      // قد يتبدّل الحساب أو تنتهي الجلسة أثناء انتظار قرار المستخدم.
      if (!_accountMatches || widget.localAuthAccount()?.isExpired != false) {
        return;
      }
      final current = await widget.coordinator.unresolvedSession(
        widget.accountId,
        session.localId,
      );
      if (current == null ||
          current.businessState != session.businessState ||
          current.syncState == SessionSyncState.conflict ||
          !_accountMatches ||
          widget.localAuthAccount()?.isExpired != false) {
        return;
      }

      await write();
      final latest = await widget.coordinator.unresolvedSessions(
        widget.accountId,
      );
      if (!mounted || !_accountMatches) return;
      setState(() {
        if (_sessions.length == 1 && latest.length > 1) {
          _selectedLocalId = null;
        }
        _sessions = latest;
      });
    } catch (_) {
      if (mounted && _accountMatches) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر حفظ الإجراء على هذا الجهاز')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _startedAt(DateTime at) {
    final local = at.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _duration(int seconds) {
    final hours = (seconds ~/ 3600).toString().padLeft(2, '0');
    final minutes = ((seconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final remaining = (seconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$remaining';
  }

  @override
  Widget build(BuildContext context) {
    if (!_accountMatches) {
      return const Scaffold(
        body: Center(child: Text('تعذر عرض الجلسة المحلية لهذا الحساب')),
      );
    }

    final selected = _selected;
    final expired = widget.localAuthAccount()?.isExpired != false;
    final canWrite = selected != null && _mayWrite(selected);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('وضع استعادة محلي')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'لم تُتحقق صلاحيات الحساب والبئر حديثًا من الخادم. '
                'الأحداث المعروضة محلية حتى تُراجعها المزامنة.',
              ),
              if (expired) ...[
                const SizedBox(height: 12),
                const Text('انتهت جلسة الدخول المحلية؛ الاستعادة للقراءة فقط.'),
              ],
              const SizedBox(height: 20),
              if (_selectedLocalId == null && _sessions.length > 1) ...[
                const Text('اختر الجلسة المحلية التي تريد عرضها:'),
                const SizedBox(height: 12),
                for (var index = 0; index < _sessions.length; index++)
                  Card(
                    child: ListTile(
                      title: Text('جلسة ${index + 1}'),
                      subtitle: Text(
                        'بدأت ${_startedAt(_sessions[index].startedAt)} — '
                        '${_sessions[index].businessStateText}',
                      ),
                      onTap: () => setState(
                        () => _selectedLocalId = _sessions[index].localId,
                      ),
                    ),
                  ),
              ] else if (selected != null) ...[
                if (_sessions.length > 1)
                  TextButton(
                    onPressed: () => setState(() => _selectedLocalId = null),
                    child: const Text('اختيار جلسة أخرى'),
                  ),
                Text('الحالة: ${selected.businessStateText}'),
                Text('بدأت: ${_startedAt(selected.startedAt)}'),
                Text(
                  'مدة السقي المحتسبة: ${_duration(selected.totals.billableSeconds)}',
                ),
                Text('حالة المزامنة: ${selected.syncState.text}'),
                if (widget.coordinator.usesDurableStore)
                  const Text('سجل الجلسة محفوظ على هذا الجهاز.'),
                if (selected.syncState == SessionSyncState.conflict)
                  const Text('تحتاج الجلسة مراجعة — السجل المحلي محفوظ'),
                if (selected.businessState == SessionBusinessState.completed)
                  const Text('اكتمل السقي محليًا، وينتظر حسم الخادم.'),
                if (canWrite) ...[
                  const SizedBox(height: 20),
                  if (selected.businessState == SessionBusinessState.running)
                    FilledButton(
                      onPressed: () => _act(
                        selected,
                        title: 'تأكيد الإيقاف المؤقت',
                        confirmation: 'تأكيد الإيقاف',
                        write: () async => widget.coordinator.pauseSession(
                          accountId: widget.accountId,
                          sessionLocalId: selected.localId,
                          reason: 'operator_pause',
                        ),
                      ),
                      child: const Text('إيقاف مؤقت'),
                    ),
                  if (selected.businessState == SessionBusinessState.paused)
                    FilledButton(
                      onPressed: () => _act(
                        selected,
                        title: 'تأكيد الاستئناف',
                        confirmation: 'تأكيد الاستئناف',
                        write: () async => widget.coordinator.resumeSession(
                          accountId: widget.accountId,
                          sessionLocalId: selected.localId,
                        ),
                      ),
                      child: const Text('استئناف'),
                    ),
                  FilledButton(
                    onPressed: () => _act(
                      selected,
                      title: 'تأكيد إنهاء الجلسة',
                      confirmation: 'تأكيد الإنهاء',
                      write: () async => widget.coordinator.completeSession(
                        accountId: widget.accountId,
                        sessionLocalId: selected.localId,
                      ),
                    ),
                    child: const Text('إنهاء الجلسة'),
                  ),
                ],
              ],
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: widget.onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة التحقق'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

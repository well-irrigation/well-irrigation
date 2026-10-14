import 'package:flutter/material.dart';

import '../core/api/bootstrap_identity_cache.dart';
import '../core/api/booking_local_ledger.dart';
import '../core/session/active_session_record.dart';
import '../core/session/offline_session_coordinator.dart';

/// غلاف محلي محدود الصلاحية للقراءة فقط عند الإقلاع دون اتصال.
///
/// ليس شاشة خطأ ولا طريقًا مسدودًا: يسلّم المستخدم إلى واجهة قابلة للتنقل
/// تعرض ما حفظه الهاتف من آخر مزامنة موثوقة (الهوية، الآبار، الأدلة
/// المحلية)، وتُظهر لباقي الأقسام حالة انقطاع آمنة بلا اختراع بيانات.
/// لا يُستعمل builder الغلاف ذي صلاحيات الكتابة، ولا تُشتق صلاحية حديثة،
/// وتبقى الأوامر والكتابات الخادمية محجوبة حتى تعود المزامنة الحاكمة.
class OfflineBootstrapView extends StatefulWidget {
  const OfflineBootstrapView({
    required this.snapshot,
    required this.coordinator,
    required this.isCurrent,
    required this.onRetry,
    this.onSignOut,
    super.key,
  });
  final CachedBootstrapIdentity snapshot;
  final OfflineSessionCoordinator? coordinator;
  final bool Function() isCurrent;
  final VoidCallback onRetry;
  final VoidCallback? onSignOut;
  @override
  State<OfflineBootstrapView> createState() => _OfflineBootstrapViewState();
}

/// قسم يحتاج الخادم ولا يملك بيانات محلية موثوقة. يُعرض معطّلًا بحالة
/// انقطاع صريحة بدل اختراع بيانات أو فتح فعل خادمي.
class _OfflineSection {
  const _OfflineSection(this.icon, this.label);
  final IconData icon;
  final String label;
}

const _serverOnlySections = <_OfflineSection>[
  _OfflineSection(Icons.play_circle_outline, 'العمليات وجلسات السقي'),
  _OfflineSection(Icons.history, 'سجل الجلسات'),
  _OfflineSection(Icons.people_outline, 'المزارعون'),
  _OfflineSection(Icons.receipt_long_outlined, 'المصروفات'),
  _OfflineSection(Icons.local_gas_station_outlined, 'الوقود'),
  _OfflineSection(Icons.handshake_outlined, 'الشركاء'),
  _OfflineSection(Icons.insights_outlined, 'التقارير والتحليلات'),
];
class _OfflineBootstrapViewState extends State<OfflineBootstrapView> {
  final Map<String, LocalProvisionalBookingSession> _provisional = {};
  List<ActiveSessionRecord> _sessions = [];
  bool _loading = true;
  bool _failed = false;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final coordinator = widget.coordinator;
      final account = widget.snapshot.data.profile.id;
      final wells = widget.snapshot.data.wells.map((w) => w.id).toSet();
      final provisional = <String, LocalProvisionalBookingSession>{};
      for (final well in wells) {
        if (!widget.isCurrent()) return;
        final session = await coordinator?.restoreProvisionalBookingSession(
          accountId: account,
          wellId: well,
        );
        if (session != null && session.wellId == well) {
          provisional[well] = session;
        }
      }
      final sessions =
          await coordinator?.unresolvedSessions(account) ??
          <ActiveSessionRecord>[];
      if (!mounted || !widget.isCurrent()) return;
      setState(() {
        _provisional.addAll(provisional);
        _sessions = sessions
            .where((s) => s.accountId == account && wells.contains(s.wellId))
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }
  @override
  Widget build(BuildContext context) {
    if (!widget.isCurrent()) return const SizedBox.shrink();
    return Scaffold(
      appBar: AppBar(title: const Text('تشغيل محلي دون اتصال')),
      body: SafeArea(
        child: Column(
          children: [
            _OfflineBanner(fetchedAt: widget.snapshot.fetchedAt),
            if (_loading) const LinearProgressIndicator(),
            Expanded(
              child: IndexedStack(
                index: _selectedIndex,
                children: [_buildOverview(), _buildSections()],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) =>
            setState(() => _selectedIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.water_drop_outlined),
            label: 'نظرة عامة',
          ),
          NavigationDestination(
            icon: Icon(Icons.grid_view_outlined),
            label: 'الأقسام',
          ),
        ],
      ),
    );
  }
  Widget _buildOverview() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_failed)
          const Text('تعذر قراءة الحالة المحلية — أعد المحاولة'),
        for (final well in widget.snapshot.data.wells)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(well.name),
                  if (_provisional[well.id] case final session?) ...[
                    const Text('انتقال حجز محفوظ على هذا الهاتف'),
                    Text(switch (session.reconciliationState) {
                      'awaiting_reconciliation' =>
                        'تم الانتقال على هذا الهاتف — بانتظار التحقق من الخادم',
                      'reconciled' => 'تمت المصالحة مع الخادم',
                      _ => 'يحتاج مراجعة',
                    }),
                    Text(
                      'وقت الحدث المحلي: ${session.startedLocallyAt.toLocal()}',
                    ),
                  ],
                  for (final session in _sessions.where(
                    (s) => s.wellId == well.id,
                  ))
                    Text(
                      'جلسة سقي محفوظة — بدأت: ${session.startedAt.toLocal()}',
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: widget.onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('إعادة التحقق من الخادم'),
        ),
        if (widget.onSignOut != null)
          TextButton(
            onPressed: widget.onSignOut,
            child: const Text('تسجيل الخروج'),
          ),
      ],
    );
  }
  Widget _buildSections() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'هذه الأقسام تحتاج اتصالًا بالخادم. لا تتاح دون اتصال، ولا تُعرض لها '
          'بيانات غير موثوقة. الأفعال التي تتطلب صلاحية حديثة أو كتابة خادمية '
          'معطّلة في هذا الوضع.',
        ),
        const SizedBox(height: 12),
        for (final section in _serverOnlySections)
          Card(
            child: ListTile(
              enabled: false,
              leading: Icon(section.icon),
              title: Text(section.label),
              subtitle: const Text('غير متاح دون اتصال — يتطلب الخادم'),
              trailing: const Icon(Icons.lock_outline),
            ),
          ),
      ],
    );
  }
}
/// تنبيه ثابت أعلى الغلاف: المستخدم دون اتصال، والبيانات محفوظة وقد لا تكون
/// حديثة، والصلاحيات لم تُتحقق من الخادم فلا تتاح أوامر جديدة.
class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.fetchedAt});
  final DateTime fetchedAt;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.cloud_off_outlined, size: 18),
              SizedBox(width: 8),
              Expanded(
                child: Text('بيانات حساب محفوظة — وضع محلي للقراءة فقط'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text('آخر مزامنة للحساب: ${fetchedAt.toLocal()}'),
          const Text(
            'لم تُتحقق الصلاحيات الحالية من الخادم. لا تتاح أوامر جديدة في هذا الوضع.',
          ),
        ],
      ),
    );
  }
}

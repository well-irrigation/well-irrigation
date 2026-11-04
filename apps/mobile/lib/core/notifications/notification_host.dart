import 'dart:async';

import 'package:flutter/material.dart';

import '../sync/workmanager_sync_scheduler.dart';
import 'notification_services.dart';
import 'notification_permission_coordinator.dart';
import 'notification_router.dart';

/// وصل دورة حياة الواجهة بالخدمات؛ لا ينشئ أحداث نتائج العمل.
class NotificationHost extends StatefulWidget {
  const NotificationHost({
    required this.accountId,
    required this.wellIds,
    required this.onRoute,
    required this.child,
    this.services,
    this.activeWellId,
    super.key,
  });
  final String accountId;
  final Set<String> wellIds;
  final void Function(NotificationRoute) onRoute;
  final Widget child;
  final NotificationServices? services;
  final String? activeWellId;
  @override
  State<NotificationHost> createState() => _NotificationHostState();
}

class _NotificationHostState extends State<NotificationHost> {
  NotificationServices? _services;
  AppLifecycleListener? _lifecycle;
  bool _routing = false;
  @override
  void initState() {
    super.initState();
    _services = widget.services ?? NotificationServices.current;
    _services?.router.addListener(_route);
    _services?.permission.explain = _explain;
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _route();
        _opportunity();
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _route();
      _opportunity();
    });
  }

  @override
  void didUpdateWidget(covariant NotificationHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId) _route();
  }

  Future<void> _route() async {
    if (!mounted || _routing || _services == null) return;
    _routing = true;
    final account = widget.accountId;
    try {
      final route = await _services!.router.resolve(
        accountId: account,
        accessibleWellIds: widget.wellIds,
      );
      if (mounted &&
          widget.accountId == account &&
          route != null &&
          (route.wellId == null || widget.wellIds.contains(route.wellId))) {
        widget.onRoute(route);
      }
    } catch (_) {
      // تعذر قراءة الوجهة لا يؤثر على العمل المحفوظ.
    } finally {
      _routing = false;
    }
  }

  void _opportunity() {
    final services = _services;
    if (services == null || !mounted) return;
    final account = widget.accountId;
    unawaited(() async {
      final well = widget.activeWellId;
      if (well != null && widget.wellIds.contains(well)) {
        try {
          await services.recover(account, well);
        } catch (_) {
          /* Later safe opportunity. */
        }
      }
      if (await services.delivery.deliver(account)) {
        try {
          await WorkmanagerSyncScheduler().scheduleSync(
            account,
            delay: const Duration(minutes: 1),
          );
        } catch (_) {
          /* محفوظ للفرصة التالية. */
        }
      }
    }());
  }

  Future<bool> _explain(NotificationRationale rationale) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return false;
    return await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          builder: (context) => SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      rationale.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Text(rationale.body),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('السماح'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('ليس الآن'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ) ??
        false;
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _services?.router.removeListener(_route);
    _services?.permission.explain = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

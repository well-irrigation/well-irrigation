import 'dart:async';

import 'app_notification_event.dart';
import 'notification_event_store.dart';
import 'notification_presenter.dart';
import 'operational_notification_event_factory.dart';

/// Uses existing app/worker opportunities. No timer, business transport or
/// autonomous boot receiver. The caller proves time and eligibility in bulk.
class OperationalNotificationScheduler {
  OperationalNotificationScheduler({
    required this.store,
    required this.presenter,
    this.isAccountActive,
    this.requestOpportunity,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final SqliteNotificationEventStore store;
  final ScheduledNotificationPresenter presenter;
  final bool Function(String)? isAccountActive;
  final Future<void> Function(String)? requestOpportunity;
  final DateTime Function() clock;
  bool accountActive(String account) {
    try {
      return isAccountActive?.call(account) != false;
    } catch (_) {
      return false;
    }
  }

  final _bookingWells = <(String, String), String>{};
  final _generations = <(String, String), int>{};
  final _rearmCursors = <(String, String, String?), (int, int)>{};
  final _bookingRecoveryCursors = <(String, String), (int, int)>{};
  int generation(String account, String well) =>
      _generations[(account, well)] ?? 0;
  void invalidate(String account, String well) {
    _generations[(account, well)] = generation(account, well) + 1;
  }

  void rememberBooking(String account, String well, String booking) {
    _bookingWells[(account, booking)] = well;
    while (_bookingWells.length > 20) {
      _bookingWells.remove(_bookingWells.keys.first);
    }
  }

  String? bookingWell(String account, String booking) =>
      _bookingWells[(account, booking)];
  Future<List<Map<String, Object?>>> bookingRecoveryPage(
    String account,
    String well,
  ) async {
    final cursor = _bookingRecoveryCursors[(account, well)] ?? (-1, 0);
    String branch(String phase) =>
        """select * from (select * from notification_events
      indexed by notification_schedule_due_idx where account_id=? and well_id=?
      and due_at is not null and schedule_state='$phase' and entity_type='booking'
      and (due_at>? or (due_at=? and local_id>?))
      order by due_at,local_id limit 20)""";
    final args = <Object?>[account, well, cursor.$1, cursor.$1, cursor.$2];
    final rows = await store.db.rawQuery(
      'select * from (${branch('armed')} union all ${branch('arm_pending')}) order by due_at,local_id limit 20',
      [...args, ...args],
    );
    if (rows.length == 20) {
      _bookingRecoveryCursors[(account, well)] = (
        rows.last['due_at'] as int,
        rows.last['local_id'] as int,
      );
    } else {
      _bookingRecoveryCursors.remove((account, well));
    }
    return rows;
  }

  /// Cancellation needs account authority, but never permission, navigation or
  /// a trusted future timestamp. This is safe in the existing worker isolate.
  Future<bool> cancelPending(
    String account,
    int limit, {
    Set<int> excludeIds = const {},
  }) async {
    if (!accountActive(account)) return false;
    final now = clock().toUtc();
    try {
      if (limit > 0) {
        await presenter.initialize().timeout(const Duration(seconds: 10));
        await store.recoverScheduleLeases(account, now);
        final rows = await store.db.rawQuery(
          """select local_id from notification_events
          indexed by notification_schedule_lease_idx where account_id=? and due_at is not null
          and schedule_state in ('arming','cancel_pending','cancelling')
          and schedule_state='cancel_pending' and schedule_attempt_count<3
          and (lease_until is null or lease_until<=?) ${excludeIds.isEmpty ? '' : 'and local_id not in (${List.filled(excludeIds.length, '?').join(',')})'} order by local_id limit ?""",
          [account, now.toIso8601String(), ...excludeIds, limit.clamp(1, 20)],
        );
        for (final row in rows) {
          if (!accountActive(account)) return false;
          final id = row['local_id'] as int;
          final attemptNow = clock().toUtc();
          final lease = attemptNow.add(const Duration(minutes: 1));
          if (!await store.claimSchedule(
            account,
            id,
            'cancel_pending',
            attemptNow,
            lease,
          )) {
            continue;
          }
          var success = false;
          try {
            await presenter.cancel(id).timeout(const Duration(seconds: 20));
            success = true;
          } catch (_) {
            /* bounded independent retry */
          }
          await store.finishSchedule(
            account,
            id,
            'cancelling',
            lease,
            success: success,
            now: clock(),
          );
        }
      }
      return (await store.db.rawQuery(
        """select local_id from notification_events
        indexed by notification_schedule_lease_idx where account_id=? and due_at is not null
        and schedule_state in ('arming','cancel_pending','cancelling')
        and schedule_state in ('cancel_pending','cancelling') and schedule_attempt_count<3 limit 1""",
        [account],
      )).isNotEmpty;
    } catch (_) {
      return true;
    }
  }

  final Map<String, Completer<void>> _running = {};

  Future<void> run(
    String account, {
    required String wellId,
    required DateTime trustedNow,
    required DateTime wallNow,
    required Set<String> eligibleKeys,
    bool rearm = false,
    String? entityType,
    bool Function()? isCurrent,
  }) {
    final active = _running[account];
    if (active != null) return active.future;
    final flight = Completer<void>();
    _running[account] = flight;
    unawaited(() async {
      try {
        await _run(account, wellId: wellId, trustedNow: trustedNow,
            wallNow: wallNow, eligibleKeys: eligibleKeys, rearm: rearm,
            entityType: entityType, isCurrent: isCurrent);
        flight.complete();
      } catch (error, stack) {
        flight.completeError(error, stack);
      } finally {
        _running.remove(account);
      }
    }());
    return flight.future;
  }

  Future<void> _run(
    String account, {
    required String wellId,
    required DateTime trustedNow,
    required DateTime wallNow,
    required Set<String> eligibleKeys,
    bool rearm = false,
    String? entityType,
    bool Function()? isCurrent,
  }) async {
    var retry = false;
    var claimed = 0;
    final cancelledThisPass = <int>{};
    try {
      if (!accountActive(account) || isCurrent?.call() == false) return;
      await presenter.initialize().timeout(const Duration(seconds: 10));
      await store.recoverScheduleLeases(account, wallNow);
      await store.expireSchedules(account, trustedNow);
      final outstanding = await store.scheduleWork(
        account,
        wallNow,
        wellId: wellId,
        entityType: entityType,
      );
      if (rearm && eligibleKeys.isNotEmpty && outstanding.isEmpty) {
        final scope = (account, wellId, entityType);
        final cursor = _rearmCursors[scope] ?? (-1, 0);
        final rows = await store.db.rawQuery(
          """select local_id,event_key,due_at from notification_events
          indexed by notification_schedule_due_idx
          where account_id=? and well_id=? and due_at is not null
          and schedule_state='armed'
          and (due_at>? or (due_at=? and local_id>?))
          ${entityType == null ? '' : 'and entity_type=?'}
          order by due_at,local_id limit 20""",
          [account, wellId, cursor.$1, cursor.$1, cursor.$2, ?entityType],
        );
        if (rows.length == 20) {
          _rearmCursors[scope] = (
            rows.last['due_at'] as int,
            rows.last['local_id'] as int,
          );
        } else {
          _rearmCursors.remove(scope);
        }
        for (final row in rows) {
          if (!eligibleKeys.contains(row['event_key'])) continue;
          final id = row['local_id'] as int;
          if ((row['due_at'] as int) <=
              trustedNow.toUtc().microsecondsSinceEpoch) {
            await store.markElapsed(account, id, trustedNow);
          } else {
            await store.db.rawUpdate(
              """update notification_events set schedule_state='arm_pending'
              where account_id=? and local_id=? and schedule_state='armed'""",
              [account, id],
            );
          }
        }
      }
      final page = await store.scheduleWork(
        account,
        wallNow,
        wellId: wellId,
        entityType: entityType,
      );
      for (final row in page) {
        if (!accountActive(account) || isCurrent?.call() == false) return;
        final id = row['local_id'] as int;
        final event = AppNotificationEvent.fromRow(row);
        final phase = row['schedule_state'] as String;
        final due = DateTime.fromMicrosecondsSinceEpoch(
          row['due_at'] as int,
          isUtc: true,
        );
        if (phase == 'arm_pending' && !due.isAfter(trustedNow)) {
          await store.markElapsed(account, id, trustedNow);
          continue;
        }
        if (phase == 'arm_pending' && !eligibleKeys.contains(event.eventKey)) {
          continue;
        }
        final attemptNow = clock().toUtc();
        final lease = attemptNow.add(const Duration(minutes: 1));
        if (!await store.claimSchedule(account, id, phase, attemptNow, lease)) {
          continue;
        }
        claimed++;
        if (phase == 'cancel_pending') cancelledThisPass.add(id);
        var success = false;
        try {
          if (phase == 'cancel_pending') {
            await presenter.cancel(id).timeout(const Duration(seconds: 20));
          } else {
            final presentation = appNotificationPolicies.presentation(event);
            if (presentation == null ||
                !await presenter.permissionGranted().timeout(
                  const Duration(seconds: 10),
                )) {
              await store.cancelSchedules(
                account,
                wellId,
                event.entityType,
                event.entityId,
                presentation == null
                    ? 'policy_not_enabled'
                    : 'permission_denied',
                wallNow,
              );
              continue;
            }
            if (!accountActive(account) || isCurrent?.call() == false) continue;
            await presenter
                .schedule(
                  id,
                  event,
                  presentation,
                  wallNow.add(due.difference(trustedNow)),
                )
                .timeout(const Duration(seconds: 20));
          }
          success = true;
        } catch (_) {
          retry = true;
        } finally {
          // An eligibility cancellation may have replaced our arming claim.
          // Its OS cancel can proceed as soon as this arm call has settled.
          await store.releaseCancellationLease(account, id, lease);
        }
        await store.finishSchedule(
          account,
          id,
          phase == 'arm_pending' ? 'arming' : 'cancelling',
          lease,
          success: success,
          now: clock(),
        );
      }
      retry =
          await cancelPending(
            account,
            20 - claimed,
            excludeIds: cancelledThisPass,
          ) ||
          retry;
    } catch (_) {
      retry = true;
    } finally {
      if (retry && accountActive(account)) {
        try {
          await requestOpportunity?.call(account);
        } catch (_) {
          /* Next normal app opportunity. */
        }
      }
    }
  }
}

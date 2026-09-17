import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/background_sync_binding.dart';
import 'package:well_irrigation_mobile/core/sync/background_sync_trigger.dart';
import 'package:well_irrigation_mobile/core/sync/connectivity_watcher.dart';

import 'fake_background_sync_scheduler.dart';

class _FailOnceScheduler extends FakeBackgroundSyncScheduler {
  bool failNext = true;

  @override
  Future<void> scheduleSync(
    String accountId, {
    Duration? delay,
    int attempt = 1,
    bool replaceExisting = false,
  }) async {
    if (failNext) {
      failNext = false;
      throw StateError('scheduler unavailable');
    }
    await super.scheduleSync(
      accountId,
      delay: delay,
      attempt: attempt,
      replaceExisting: replaceExisting,
    );
  }
}

class _Watcher implements ConnectivityWatcher {
  final restored = StreamController<void>.broadcast();
  bool disposed = false;

  @override
  Stream<void> get onConnectivityRestored => restored.stream;

  @override
  Future<bool> looksOnline() async => true;

  void reconnect() => restored.add(null);

  @override
  Future<void> dispose() async {
    disposed = true;
    await restored.close();
  }
}

void main() {
  test('فشل جدولة البدء يبقي مراقب الاتصال ليعيد المحاولة', () async {
    final authEvents = StreamController<void>.broadcast();
    final scheduler = _FailOnceScheduler();
    final watcher = _Watcher();
    final sync = AuthenticatedBackgroundSync(
      authChanges: authEvents.stream,
      currentAccountId: () => 'A',
      bindingFactory: () => BackgroundSyncBinding(
        trigger: BackgroundSyncTrigger(scheduler: scheduler),
        connectivity: watcher,
        observeLifecycle: false,
      ),
    );
    addTearDown(() async {
      await sync.dispose();
      await authEvents.close();
    });
    await sync.start();
    expect(scheduler.count, 0);
    expect(watcher.disposed, isFalse);

    watcher.reconnect();
    await Future<void>.delayed(Duration.zero);
    expect(scheduler.scheduled.map((item) => item.accountId), ['A']);
  });
  test('بدء موثّق وجدولة اتصال مع فصل الحساب عند الخروج والتبديل', () async {
    final authEvents = StreamController<void>.broadcast();
    final scheduler = FakeBackgroundSyncScheduler();
    final watchers = <_Watcher>[];
    String? currentAccount = 'A';
    final sync = AuthenticatedBackgroundSync(
      authChanges: authEvents.stream,
      currentAccountId: () => currentAccount,
      bindingFactory: () {
        final watcher = _Watcher();
        watchers.add(watcher);
        return BackgroundSyncBinding(
          trigger: BackgroundSyncTrigger(
            scheduler: scheduler,
            minimumInterval: Duration.zero,
          ),
          connectivity: watcher,
          observeLifecycle: false,
        );
      },
    );
    addTearDown(() async {
      await sync.dispose();
      await authEvents.close();
    });

    await sync.start();
    expect(scheduler.scheduled.map((item) => item.accountId), ['A']);
    watchers.single.reconnect();
    await Future<void>.delayed(Duration.zero);
    expect(scheduler.last.accountId, 'A');
    expect(scheduler.count, 2);

    currentAccount = null;
    authEvents.add(null);
    await sync.refresh();
    expect(watchers.first.disposed, isTrue);
    expect(await sync.commandQueued('A'), isFalse);
    expect(scheduler.count, 2);

    currentAccount = 'B';
    authEvents.add(null);
    await sync.refresh();
    expect(scheduler.last.accountId, 'B');
    expect(watchers, hasLength(2));
    expect(await sync.commandQueued('A'), isFalse);
    expect(await sync.commandQueued('B'), isTrue);
    expect(scheduler.last.accountId, 'B');
  });

  test(
    'بلا مصادقة لا تُجدول أعمال؛ نجاح المصادقة يعيد جدولة المعلّق',
    () async {
      final authEvents = StreamController<void>.broadcast();
      final scheduler = FakeBackgroundSyncScheduler();
      String? currentAccount;
      final sync = AuthenticatedBackgroundSync(
        authChanges: authEvents.stream,
        currentAccountId: () => currentAccount,
        bindingFactory: () => BackgroundSyncBinding(
          trigger: BackgroundSyncTrigger(scheduler: scheduler),
          connectivity: _Watcher(),
          observeLifecycle: false,
        ),
      );
      addTearDown(() async {
        await sync.dispose();
        await authEvents.close();
      });
      await sync.start();
      expect(scheduler.count, 0);
      expect(await sync.commandQueued('A'), isFalse);

      currentAccount = 'A';
      await sync.refresh();
      expect(scheduler.scheduled.map((item) => item.accountId), ['A']);
      await sync.refresh();
      expect(scheduler.count, 1, reason: 'لا جدولة مكررة للحساب نفسه');
    },
  );
}

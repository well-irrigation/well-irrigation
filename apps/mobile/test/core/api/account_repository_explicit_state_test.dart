import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/account_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';

import '../sync/fake_command_transport.dart';

class _ClearedQueueRaceCoordinator extends OfflineSessionCoordinator {
  _ClearedQueueRaceCoordinator()
    : super(
        store: InMemoryOutboxStore(),
        commandTransport: FakeCommandTransport(),
      );

  var _pendingReads = 0;

  @override
  Future<int> getPendingOperationsCount(String accountId) async =>
      _pendingReads++ == 0 ? 1 : 0;

  @override
  Future<SyncRunReport> syncNow(String accountId) async =>
      const SyncRunReport(alreadyRunning: true);
}

/// حرس مستودع الحساب: يمنع رجوع الثوابت المُلفَّقة أو النجاح بلا عمل
/// (م-41B3B / ق-118 / ق-120 — البنود 1–4 من قائمة النجاح الكاذب).
void main() {
  group('AccountRepository — حالة صريحة لا ثوابت مُلفَّقة', () {
    late OfflineSessionCoordinator coordinator;
    late AccountRepository repository;
    late InMemoryOutboxStore store;

    /// مفتاح صاحب الطابور في هذا الاختبار. لا مفتاح ثابت في التطبيق بعد
    /// حذف `placeholderAccountKey`: القراءة والكتابة بمفتاح واحد أو لا شيء.
    const accountId = 'owner-1';

    setUp(() {
      store = InMemoryOutboxStore();
      coordinator = OfflineSessionCoordinator(store: store);
      repository = AccountRepository(null, coordinator);
    });

    tearDown(() {
      coordinator.dispose();
    });

    test('1. حالة الجهاز تُقرأ من الطابور، وغير المقيس يبقى null', () async {
      final status = await repository.fetchDeviceSyncStatus(accountId);

      expect(status.pendingOperationsCount, 0);
      expect(status.lastSyncTime, isNull);
      // طابور ذاكرة لا قرص: لا يجوز إعلان جاهزية تخزين محلي دائم.
      expect(status.localStorageReady, isFalse);
      // غير مقيسين في هذا الإصدار (W2-02d).
      expect(status.isOnline, isNull);
      expect(status.backgroundSyncActive, isNull);
    });

    test('2. العملية المحفوظة تظهر في العدد المعلَّق فورًا', () async {
      await coordinator.recordPayment(
        accountId: accountId,
        wellId: 'well-1',
        farmerAccountId: 'farmer-1',
        amountMinor: 25000,
        paymentMethod: 'cash',
      );

      final status = await repository.fetchDeviceSyncStatus(accountId);
      expect(status.pendingOperationsCount, 1);
      expect(await repository.checkPendingOperationsBeforeLogout(accountId), 1);

      // طابور حساب آخر لا يُقرأ هنا: الغياب هنا حقيقة لا نجاح كاذب.
      final other = await repository.fetchDeviceSyncStatus('owner-2');
      expect(other.pendingOperationsCount, 0);
    });

    test(
      '3. المزامنة اليدوية بلا ناقل تُعلن عدم توفرها ولا تُعلن نجاحًا',
      () async {
        expect(coordinator.canSyncNow, isFalse);

        await expectLater(
          repository.triggerManualSync(accountId),
          throwsA(isA<ManualSyncUnavailableException>()),
        );
      },
    );

    test('3ب. المزامنة اليدوية تمر بالمحرك الحقيقي وتحتاج إقرارًا', () async {
      await coordinator.recordPayment(
        accountId: accountId,
        wellId: 'well-1',
        farmerAccountId: 'farmer-1',
        amountMinor: 25000,
        paymentMethod: 'cash',
      );
      coordinator.dispose();

      final wired = OfflineSessionCoordinator(
        store: store,
        commandTransport: FakeCommandTransport(),
      );
      coordinator = wired;
      repository = AccountRepository(null, wired);

      await repository.triggerManualSync(accountId);

      expect(await wired.getPendingOperationsCount(accountId), 0);
      expect(await wired.lastSuccessfulSyncAt(accountId), isNotNull);
    });

    test('3ج. فشل النقل في المزامنة اليدوية لا يعود نجاحًا', () async {
      final command = await coordinator.recordPayment(
        accountId: accountId,
        wellId: 'well-1',
        farmerAccountId: 'farmer-1',
        amountMinor: 25000,
        paymentMethod: 'cash',
      );
      coordinator.dispose();
      final transport = FakeCommandTransport()
        ..scheduleNetworkFailure(command.type);
      final wired = OfflineSessionCoordinator(
        store: store,
        commandTransport: transport,
      );
      coordinator = wired;
      repository = AccountRepository(null, wired);

      await expectLater(
        repository.triggerManualSync(accountId),
        throwsA(isA<ManualSyncIncompleteException>()),
      );
      expect(await wired.getPendingOperationsCount(accountId), 1);
    });

    test('3د. الطابور الفارغ يعيد نتيجة محايدة لا نجاحًا ولا فشلًا', () async {
      coordinator.dispose();
      final wired = OfflineSessionCoordinator(
        store: store,
        commandTransport: FakeCommandTransport(),
      );
      coordinator = wired;
      repository = AccountRepository(null, wired);

      await expectLater(
        repository.triggerManualSync(accountId),
        throwsA(isA<ManualSyncNothingPendingException>()),
      );
    });

    test(
      '3هـ. سبق مزامنة أخرى وتفريغها الطابور يعيد النتيجة المحايدة',
      () async {
        coordinator.dispose();
        final raceCoordinator = _ClearedQueueRaceCoordinator();
        coordinator = raceCoordinator;
        repository = AccountRepository(null, raceCoordinator);

        await expectLater(
          repository.triggerManualSync(accountId),
          throwsA(isA<ManualSyncNothingPendingException>()),
        );
      },
    );

    test(
      '4. تغيير كلمة المرور بلا جلسة مصدَّقة يفشل ولا يعود نجاحًا',
      () async {
        await expectLater(
          repository.updatePassword(
            currentPassword: 'كلمة-قديمة-1',
            newPassword: 'كلمة-مرور-قوية-1',
          ),
          throwsA(isA<StateError>()),
        );

        await expectLater(
          repository.updatePassword(
            currentPassword: 'كلمة-قديمة-1',
            newPassword: '',
          ),
          throwsA(isA<ArgumentError>()),
        );

        // كلمة المرور الحالية الفارغة تُرفض قبل أي نداء: الخانة تُقرأ فعلًا.
        await expectLater(
          repository.updatePassword(
            currentPassword: '',
            newPassword: 'كلمة-مرور-قوية-1',
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });
}

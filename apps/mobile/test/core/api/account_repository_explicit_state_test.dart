import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/account_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';

/// حرس مستودع الحساب: يمنع رجوع الثوابت المُلفَّقة أو النجاح بلا عمل
/// (م-41B3B / ق-118 / ق-120 — البنود 1–4 من قائمة النجاح الكاذب).
void main() {
  group('AccountRepository — حالة صريحة لا ثوابت مُلفَّقة', () {
    late OfflineSessionCoordinator coordinator;
    late AccountRepository repository;

    /// مفتاح صاحب الطابور في هذا الاختبار. لا مفتاح ثابت في التطبيق بعد
    /// حذف `placeholderAccountKey`: القراءة والكتابة بمفتاح واحد أو لا شيء.
    const accountId = 'owner-1';

    setUp(() {
      coordinator = OfflineSessionCoordinator(store: InMemoryOutboxStore());
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

    test('3. المزامنة اليدوية بلا ناقل تُعلن عدم توفرها ولا تُعلن نجاحًا',
        () async {
      expect(coordinator.canSyncNow, isFalse);

      await expectLater(
        repository.triggerManualSync(accountId),
        throwsA(isA<ManualSyncUnavailableException>()),
      );
    });

    test('4. تغيير كلمة المرور بلا جلسة مصدَّقة يفشل ولا يعود نجاحًا',
        () async {
      await expectLater(
        repository.updatePassword('كلمة-مرور-قوية-1'),
        throwsA(isA<StateError>()),
      );

      await expectLater(
        repository.updatePassword(''),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

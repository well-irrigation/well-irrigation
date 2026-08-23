/// أسباب الإيقاظ ومنع تكرارها، ومؤشِّر الشبكة كمؤشِّر لا دليل.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/background_sync_trigger.dart';
import 'package:well_irrigation_mobile/core/sync/connectivity_watcher.dart';

import 'fake_background_sync_scheduler.dart';
import 'sync_test_support.dart';

void main() {
  late FakeBackgroundSyncScheduler scheduler;
  late BackgroundSyncTrigger trigger;

  setUp(() {
    testNow = DateTime.utc(2026, 8, 23, 6);
    scheduler = FakeBackgroundSyncScheduler();
    trigger = BackgroundSyncTrigger(scheduler: scheduler, clock: clock);
  });

  group('الكبح الزمني', () {
    test('فتح التطبيق يجدول دائمًا', () async {
      expect(
        await trigger.request(accountA, SyncTriggerReason.appStarted),
        isTrue,
      );
      expect(scheduler.count, 1);
    });

    test('ثلاثة أسباب في ثانيتين تصير طلبًا واحدًا', () async {
      await trigger.request(accountA, SyncTriggerReason.appStarted);

      advanceClock(const Duration(seconds: 1));
      final resumed = await trigger.request(
        accountA,
        SyncTriggerReason.appResumed,
      );

      advanceClock(const Duration(seconds: 1));
      final queued = await trigger.request(
        accountA,
        SyncTriggerReason.commandQueued,
      );

      expect(resumed, isFalse);
      expect(queued, isFalse);
      expect(scheduler.count, 1, reason: 'طلب واحد على نفس الطابور');
    });

    test('بعد انقضاء الفاصل يُقبل السبب التالي', () async {
      await trigger.request(accountA, SyncTriggerReason.appStarted);
      advanceClock(const Duration(seconds: 21));

      expect(
        await trigger.request(accountA, SyncTriggerReason.commandQueued),
        isTrue,
      );
      expect(scheduler.count, 2);
    });

    test('الطلب اليدوي لا يُكبح ويستبدل الموعد القائم', () async {
      await trigger.request(accountA, SyncTriggerReason.appStarted);
      advanceClock(const Duration(seconds: 1));

      expect(
        await trigger.request(accountA, SyncTriggerReason.manualRequest),
        isTrue,
      );
      expect(scheduler.last.replaceExisting, isTrue);
    });

    test('الأسباب التلقائية لا تستبدل موعدًا قائمًا', () async {
      await trigger.request(accountA, SyncTriggerReason.appStarted);

      expect(scheduler.last.replaceExisting, isFalse);
    });

    test('فتح التطبيق من جديد يتجاوز الكبح', () async {
      // قد يكون الهاتف أُقلع للتوّ: موعدٌ قديم من تشغيل سابق لا يمنعنا.
      await trigger.request(accountA, SyncTriggerReason.commandQueued);
      advanceClock(const Duration(seconds: 2));

      expect(
        await trigger.request(accountA, SyncTriggerReason.appStarted),
        isTrue,
      );
    });

    test('reset ينسي الكبح عند تبديل الحساب', () async {
      await trigger.request(accountA, SyncTriggerReason.appResumed);
      trigger.reset();

      expect(
        await trigger.request(accountB, SyncTriggerReason.appResumed),
        isTrue,
      );
      expect(trigger.lastAcceptedReason, SyncTriggerReason.appResumed);
      expect(scheduler.last.accountId, accountB);
    });
  });

  group('مؤشِّر الشبكة', () {
    test('النبضة عند العودة وحدها لا عند كل تغيّر', () {
      final detector = ConnectivityRestoredDetector();

      expect(detector.isOnline, isFalse);
      expect(detector.accept(true), isTrue, reason: 'عادت الشبكة');
      expect(detector.accept(true), isFalse, reason: 'ما زالت متصلة');
      expect(
        detector.accept(false),
        isFalse,
        reason: 'الانقطاع لا يستدعي عملًا',
      );
      expect(detector.accept(true), isTrue, reason: 'عادت ثانيةً');
    });

    test('البدء متصلًا لا يُنتج نبضة كاذبة', () {
      final detector = ConnectivityRestoredDetector(initiallyOnline: true);

      expect(detector.accept(true), isFalse);
    });
  });
}

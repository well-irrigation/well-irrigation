/// متى يُوقظ الهاتف ومتى يُترك — القرار وحده، بلا جهاز.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/background_sync_policy.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';

void main() {
  const policy = BackgroundSyncPolicy();

  group('التراجع الأُسّي', () {
    test('يتضاعف من أول انتظار حتى السقف ثم يثبت', () {
      expect(policy.delayForAttempt(1), const Duration(seconds: 30));
      expect(policy.delayForAttempt(2), const Duration(minutes: 1));
      expect(policy.delayForAttempt(3), const Duration(minutes: 2));
      expect(policy.delayForAttempt(4), const Duration(minutes: 4));
      expect(policy.delayForAttempt(7), const Duration(minutes: 32));
      expect(policy.delayForAttempt(8), const Duration(hours: 1));
      expect(policy.delayForAttempt(50), const Duration(hours: 1));
    });

    test('محاولة صفر أو سالبة تُعالَج كأولى', () {
      expect(policy.delayForAttempt(0), policy.firstDelay);
      expect(policy.delayForAttempt(-3), policy.firstDelay);
    });

    test('السقف على المدة لا على عدد المحاولات', () {
      // القاعدة المالية: أمرٌ في الطابور لا يُسقَط أبدًا. المحاولة رقم
      // ألف ما زالت مجدولة، لكنها بانتظار السقف لا بانتظار متزايد بلا
      // نهاية.
      final decision = policy.decide(
        report: const SyncRunReport(retryScheduled: 1),
        attempt: 1000,
      );

      expect(decision.shouldRetry, isTrue);
      expect(decision.retryDelay, policy.maxDelay);
    });
  });

  group('قرار الجدولة', () {
    test('طابور فارغ لا يُجدَّد له موعد', () {
      final decision = policy.decide(report: const SyncRunReport());

      expect(decision.outcome, BackgroundSyncOutcome.nothingToSend);
      expect(decision.shouldRetry, isFalse);
      expect(decision.retryDelay, isNull);
    });

    test('أُرسل كل شيء بنجاح فلا موعد جديد', () {
      final decision = policy.decide(
        report: const SyncRunReport(attempted: 3, confirmed: 3),
      );

      expect(decision.outcome, BackgroundSyncOutcome.allSent);
      expect(decision.shouldRetry, isFalse);
    });

    test('فشل عابر يُجدَّد له موعد بحسب رقم المحاولة', () {
      final decision = policy.decide(
        report: const SyncRunReport(attempted: 1, retryScheduled: 1),
        attempt: 3,
      );

      expect(decision.outcome, BackgroundSyncOutcome.retryLater);
      expect(decision.retryDelay, const Duration(minutes: 2));
      expect(decision.nextAttempt, 4);
    });

    test('تقدُّمٌ مع بقاء عمل يُرجع الانتظار إلى أوّله', () {
      // الشبكة تعمل والطابور طويل فقط. مواصلة التراجع الأُسّي هنا تعني
      // تعطيلًا بلا سبب.
      final decision = policy.decide(
        report: const SyncRunReport(
          attempted: 6,
          confirmed: 5,
          retryScheduled: 1,
        ),
        attempt: 6,
      );

      expect(decision.retryDelay, policy.firstDelay);
      expect(decision.nextAttempt, 7);
    });

    test('حلقة تعمل الآن: نمرّ لاحقًا بلا محاولة ثانية', () {
      final decision = policy.decide(
        report: const SyncRunReport(alreadyRunning: true),
      );

      expect(decision.outcome, BackgroundSyncOutcome.alreadyRunning);
      expect(decision.retryDelay, policy.busyDelay);
    });
  });

  group('ما ينتظر إنسانًا لا يُعاد تلقائيًا', () {
    test('أمرٌ يحتاج مراجعة لا يُجدَّد له موعد', () {
      final decision = policy.decide(
        report: const SyncRunReport(attempted: 1, needsReview: 1),
      );

      expect(decision.outcome, BackgroundSyncOutcome.awaitsHumanDecision);
      expect(decision.shouldRetry, isFalse);
    });

    test('أوامر موقوفة خلف مراجعة لا تُوقظ الهاتف', () {
      // هذه هي الحالة التي كانت ستصير حلقة أبدية: `skipped` أكبر من صفر
      // بلا شيء قابل للنجاح. تمييز `blockedByReview` هو ما يمنعها.
      final report = const SyncRunReport(skipped: 3, blockedByReview: 3);

      expect(report.hasPendingWork, isTrue);
      expect(report.canRetryWithoutHelp, isFalse);

      final decision = policy.decide(report: report);

      expect(decision.outcome, BackgroundSyncOutcome.awaitsHumanDecision);
      expect(decision.shouldRetry, isFalse);
    });

    test('مراجعة مع عملٍ آخر قابل للنجاح تبقى الجدولة', () {
      // بئر موقوفة على مراجعة لا تعطّل بئرًا أخرى تنتظر الشبكة فقط.
      final report = const SyncRunReport(
        skipped: 3,
        blockedByReview: 2,
        needsReview: 1,
      );

      expect(report.canRetryWithoutHelp, isTrue);
      expect(
        policy.decide(report: report).outcome,
        BackgroundSyncOutcome.retryLater,
      );
    });
  });

  group('تفريغ الطابور داخل تشغيل واحد', () {
    test('يستمر ما دام هناك تقدّم وعملٌ باقٍ', () {
      const report = SyncRunReport(
        attempted: 2,
        confirmed: 1,
        retryScheduled: 1,
      );

      expect(policy.shouldContinueDraining(report, 1), isTrue);
      expect(
        policy.shouldContinueDraining(report, policy.maxPassesPerRun),
        isFalse,
      );
    });

    test('بلا تقدّم يتوقف فورًا — لا حلقة مشدودة بلا شبكة', () {
      const report = SyncRunReport(attempted: 1, retryScheduled: 1);

      expect(policy.shouldContinueDraining(report, 1), isFalse);
    });

    test('تقدّم بلا عمل باقٍ يتوقف', () {
      const report = SyncRunReport(attempted: 2, confirmed: 2);

      expect(policy.shouldContinueDraining(report, 1), isFalse);
    });
  });
}

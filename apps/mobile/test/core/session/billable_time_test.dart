/// اختبارات الزمن المحتسب والمستحق على المقاطع — القسمان 5 و6.
///
/// أهم ما يُبرهن هنا: القسمة تجري **على كل مقطع** لا على المجموع، وهي
/// نفس سياسة Migration 066 — فما يراه المستخدم حيًّا يطابق فاتورته.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/session/session_segment.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 23, 6);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  SessionSegment running(int from, int? to, {int? rate = 3600}) =>
      SessionSegment(
        kind: SegmentKind.running,
        startedAt: at(from),
        endedAt: to == null ? null : at(to),
        hourlyRateMinor: rate,
        energySource: 'diesel',
      );

  SessionSegment paused(int from, int? to) => SessionSegment(
    kind: SegmentKind.paused,
    startedAt: at(from),
    endedAt: to == null ? null : at(to),
  );

  group('الزمن المحتسب', () {
    test('التوقف لا يزيد عدّاد السقي', () {
      final totals = summarize([
        running(0, 600),
        paused(600, 900),
        running(900, 1200),
      ], at(1200));

      expect(totals.billableSeconds, 900);
      expect(totals.totalPausedSeconds, 300);
      expect(
        totals.wallClockSeconds,
        1200,
        reason: 'الزمن منذ البدء يشمل التوقف، والمحتسب لا يشمله',
      );
    });

    test('المقطع المفتوح يُقاس حتى اللحظة الحالية', () {
      final totals = summarize([running(0, null)], at(45));

      expect(totals.billableSeconds, 45);
    });

    test('التوقف الجاري يُقاس منفصلًا عن إجمالي التوقف', () {
      final totals = summarize([
        running(0, 100),
        paused(100, 200),
        running(200, 300),
        paused(300, null),
      ], at(340));

      expect(totals.currentPauseSeconds, 40);
      expect(totals.totalPausedSeconds, 140);
      expect(
        totals.billableSeconds,
        200,
        reason: 'العدّاد متجمّد أثناء التوقف الجاري',
      );
    });

    test('جلسة موقوفة الآن لا يزيد محتسبها بمرور الوقت', () {
      final segments = [running(0, 100), paused(100, null)];

      expect(summarize(segments, at(200)).billableSeconds, 100);
      expect(summarize(segments, at(9000)).billableSeconds, 100);
    });
  });

  group('المستحق', () {
    test('سعر 3600 للساعة = ريال لكل ثانية', () {
      final totals = summarize([running(0, 250)], at(250));

      expect(totals.accruedMinor, 250);
      expect(totals.pricingPending, isFalse);
    });

    test('القسمة تجري على كل مقطع لا على المجموع', () {
      // مقطعان من 100 ثانية بسعر 3599/ساعة.
      // على المقطع: (100*3599)/3600 = 99، والمجموع 198.
      // على المجموع لو جُمعت الثواني: (200*3599)/3600 = 199.
      // الخادم يحسبها مقطعًا مقطعًا، فالصحيح 198.
      final totals = summarize([
        running(0, 100, rate: 3599),
        paused(100, 150),
        running(150, 250, rate: 3599),
      ], at(250));

      expect(totals.billableSeconds, 200);
      expect(
        totals.accruedMinor,
        198,
        reason: 'مجموع القسمة على المقاطع، لا قسمة مجموع الثواني',
      );
    });

    test('الكسر يُقتطع دائمًا ولا يُقرَّب', () {
      // (1 * 5000)/3600 = 1.388 → 1 (الثابت 6 والثابت في INVARIANTS).
      final totals = summarize([running(0, 1, rate: 5000)], at(1));

      expect(totals.accruedMinor, 1);
    });

    test('التوقف لا يضيف مبلغًا', () {
      final withPause = summarize([
        running(0, 100),
        paused(100, 5000),
      ], at(5000));

      expect(withPause.accruedMinor, 100);
    });

    test('مقطع بلا سعر يجعل المجموع «بانتظار المزامنة» بلا رقم', () {
      final totals = summarize([running(0, 100, rate: null)], at(100));

      expect(totals.pricingPending, isTrue);
      expect(
        totals.accruedMinor,
        isNull,
        reason: 'القرار 341: لا يُعرض رقم مخمَّن ولا «0 ريال»',
      );
      expect(
        totals.billableSeconds,
        100,
        reason: 'غياب السعر لا يُخفي الزمن المقاس',
      );
    });

    test('مقطع واحد بلا سعر يكفي لتعليق المجموع كله', () {
      final totals = summarize([
        running(0, 100),
        paused(100, 150),
        running(150, 250, rate: null),
      ], at(250));

      expect(totals.pricingPending, isTrue);
      expect(totals.accruedMinor, isNull);
    });
  });

  group('حماية من المدة السالبة', () {
    test('وقت إغلاق أسبق من البداية لا يُنتج مدة سالبة', () {
      final segment = SessionSegment(
        kind: SegmentKind.running,
        startedAt: at(500),
        endedAt: at(100),
        hourlyRateMinor: 3600,
      );

      expect(segment.duration(at(500)), Duration.zero);
      expect(segment.billableSeconds(at(500)), 0);
      expect(
        segment.timeChargeMinor(at(500)),
        0,
        reason: 'لا يُطرح مبلغ من مستحق المزارع بسبب وقت مقلوب',
      );
    });

    test('«الآن» أسبق من بداية مقطع مفتوح لا ينتج سالبًا', () {
      expect(summarize([running(500, null)], at(100)).billableSeconds, 0);
    });
  });

  group('الحالة المشتقّة من المقاطع', () {
    test('مقطع سقي مفتوح = جارية', () {
      expect(
        stateFromSegments([running(0, null)], completed: false),
        SessionBusinessState.running,
      );
    });

    test('مقطع توقف مفتوح = متوقفة', () {
      expect(
        stateFromSegments([
          running(0, 100),
          paused(100, null),
        ], completed: false),
        SessionBusinessState.paused,
      );
    });

    test('أمر إنهاء يتقدم على أي مقطع', () {
      expect(
        stateFromSegments([running(0, 100)], completed: true),
        SessionBusinessState.completed,
      );
    });

    test('لا مقطع مفتوح بلا إنهاء = متوقفة لا جارية', () {
      expect(
        stateFromSegments([running(0, 100)], completed: false),
        SessionBusinessState.paused,
        reason: 'الأسلم ألّا يزيد عدّاد مالي على مقطع لم يُثبَت أنه مفتوح',
      );
    });
  });
}

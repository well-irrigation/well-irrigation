/// اختبارات سلامة الزمن — القسم 19.
///
/// ما يُبرهن هنا: تعديل ساعة الهاتف لا يغيّر مدة مقاسة، وإعادة الإقلاع
/// تُعلَن ولا تُخفى، والترتيب المستحيل يُكتشف.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/time_integrity.dart';

void main() {
  const boot = 'boot-1';
  final anchorWall = DateTime.utc(2026, 8, 23, 6);

  SessionTimeAnchor anchor({DateTime? serverTime, String bootId = boot}) =>
      SessionTimeAnchor(
        wallClock: anchorWall,
        monotonic: const Duration(hours: 5),
        bootId: bootId,
        serverTime: serverTime,
      );

  group('حسم «الآن» داخل نفس الإقلاع', () {
    test('ساعة سليمة: المنقضي من العدّاد، وخط الزمن مبرهن', () {
      final resolved = resolveNow(
        anchor: anchor(serverTime: anchorWall),
        reading: TimeReading(
          wallClock: anchorWall.add(const Duration(minutes: 30)),
          monotonic: const Duration(hours: 5, minutes: 30),
          bootId: boot,
        ),
      );

      expect(resolved.at, anchorWall.add(const Duration(minutes: 30)));
      expect(resolved.isTrusted, isTrue);
      expect(resolved.flags, isEmpty);
    });

    test(
      'قُدِّمت ساعة الهاتف ساعتين: المدة تبقى 30 دقيقة ويُرفع العلم',
      () {
        final resolved = resolveNow(
          anchor: anchor(serverTime: anchorWall),
          reading: TimeReading(
            // المستخدم قدّم الساعة، والعدّاد التصاعدي لم يتأثر.
            wallClock: anchorWall.add(const Duration(hours: 2, minutes: 30)),
            monotonic: const Duration(hours: 5, minutes: 30),
            bootId: boot,
          ),
        );

        expect(
          resolved.at,
          anchorWall.add(const Duration(minutes: 30)),
          reason: 'العدّاد التصاعدي هو المرجع، لا ساعة الحائط',
        );
        expect(resolved.flags, contains(TimeIntegrityFlag.deviceClockChanged));
        expect(resolved.isTrusted, isFalse);
      },
    );

    test('أُخِّرت الساعة: يُرفع نفس العلم ولا تنقص المدة', () {
      final resolved = resolveNow(
        anchor: anchor(serverTime: anchorWall),
        reading: TimeReading(
          wallClock: anchorWall.subtract(const Duration(hours: 3)),
          monotonic: const Duration(hours: 5, minutes: 30),
          bootId: boot,
        ),
      );

      expect(resolved.at, anchorWall.add(const Duration(minutes: 30)));
      expect(resolved.flags, contains(TimeIntegrityFlag.deviceClockChanged));
    });

    test('انحراف ثوانٍ لا يرفع علمًا', () {
      final resolved = resolveNow(
        anchor: anchor(serverTime: anchorWall),
        reading: TimeReading(
          wallClock: anchorWall.add(const Duration(minutes: 30, seconds: 20)),
          monotonic: const Duration(hours: 5, minutes: 30),
          bootId: boot,
        ),
      );

      expect(resolved.flags, isEmpty);
    });
  });

  group('بعد إعادة الإقلاع', () {
    test('يُعلَن أن خط الزمن غير مبرهن ويُرجَع لساعة الحائط', () {
      final afterReboot = anchorWall.add(const Duration(hours: 1));

      final resolved = resolveNow(
        anchor: anchor(serverTime: anchorWall),
        reading: TimeReading(
          wallClock: afterReboot,
          // العدّاد صُفِّر بالإقلاع، فقيمته أصغر من المرساة.
          monotonic: const Duration(minutes: 3),
          bootId: 'boot-2',
        ),
      );

      expect(resolved.at, afterReboot);
      expect(
        resolved.flags,
        contains(TimeIntegrityFlag.rebootTimelineUnverified),
      );
      expect(
        resolved.at.isAfter(anchorWall),
        isTrue,
        reason: 'عدّاد صُفِّر لا يجوز أن يُنتج زمنًا سابقًا للمرساة',
      );
    });
  });

  group('المرساة الخادمية', () {
    test('غيابها يُعلَن ولا يُسقط الثقة بمدة مقاسة', () {
      final resolved = resolveNow(
        anchor: anchor(),
        reading: TimeReading(
          wallClock: anchorWall.add(const Duration(minutes: 10)),
          monotonic: const Duration(hours: 5, minutes: 10),
          bootId: boot,
        ),
      );

      expect(resolved.flags, contains(TimeIntegrityFlag.noServerAnchor));
      expect(
        resolved.isTrusted,
        isTrue,
        reason: 'العمل بلا اتصال حالة معتمدة بق-89، وليست خللًا في الزمن',
      );
    });

    test('إزاحة ساعة الجهاز عن الخادم تُقاس ولا تُطبَّق', () {
      final withOffset = SessionTimeAnchor(
        wallClock: anchorWall.add(const Duration(minutes: 4)),
        monotonic: const Duration(hours: 5),
        bootId: boot,
        serverTime: anchorWall,
      );

      expect(withOffset.deviceOffsetFromServer, const Duration(minutes: 4));
    });
  });

  group('ترتيب الأحداث', () {
    test('ترتيب صاعد سليم', () {
      expect(
        checkEventOrdering([
          anchorWall,
          anchorWall.add(const Duration(minutes: 5)),
          anchorWall.add(const Duration(minutes: 9)),
        ]),
        isEmpty,
      );
    });

    test('تساوي وقتَي حدثين مسموح', () {
      expect(checkEventOrdering([anchorWall, anchorWall]), isEmpty);
    });

    test('حدث لاحق بوقت أسبق يُكتشف', () {
      expect(
        checkEventOrdering([
          anchorWall,
          anchorWall.subtract(const Duration(minutes: 1)),
        ]),
        contains(TimeIntegrityFlag.impossibleEventOrdering),
      );
    });
  });
}

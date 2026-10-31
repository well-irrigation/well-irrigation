import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/solar_availability_policy.dart';

void main() {
  test('Aden instant boundaries are inclusive start and exclusive end', () {
    for (final row in [
      (2, 59, 59, false),
      (3, 0, 0, true),
      (14, 59, 59, true),
      (15, 0, 0, false),
    ]) {
      expect(
        solarAvailableAt(DateTime.utc(2026, 10, 17, row.$1, row.$2, row.$3)),
        row.$4,
      );
    }
  });
  test(
    'booking end exactly at cutoff needs no alternative, crossing it does',
    () {
      expect(
        assessSolarWindow(startMinuteOfDay: 6 * 60, durationMinutes: 12 * 60),
        SolarAssessment.ok,
      );
      expect(
        assessSolarWindow(startMinuteOfDay: 18 * 60, durationMinutes: 1),
        SolarAssessment.startOutsideWindow,
      );
      expect(
        assessSolarWindow(startMinuteOfDay: 17 * 60, durationMinutes: 61),
        SolarAssessment.requiresAlternative,
      );
    },
  );
  test('all seconds of an Aden day follow the same window independent of device zone', () {
    for (var s = 0; s < 86400; s += 37) {
      final utc = DateTime.utc(2026, 10, 16, 21).add(Duration(seconds: s));
      expect(solarAvailableAt(utc), s >= 21600 && s < 64800);
    }
  });
}

/// Mirrors ops.solar_window_for_day: Asia/Aden, inclusive 06:00,
/// exclusive 18:00. Callers must prove operational time before using now.
const int kSolarWindowStartHour = 6;
const int kSolarWindowEndHour = 18;
const String kSolarWindowLabel = '06:00–18:00';
const String solarAvailabilityWindow = 'متاحة من 6:00 صباحًا إلى 6:00 مساءً';
const String solarUnavailableMessage = 'الطاقة الشمسية غير متاحة الآن';
const String solarTimeUnverifiedMessage =
    'تعذر التحقق من وقت إتاحة الطاقة الشمسية';

enum SolarAssessment { ok, startOutsideWindow, requiresAlternative }

bool solarAvailableAt(DateTime trustedNow) {
  final aden = trustedNow.toUtc().add(const Duration(hours: 3));
  return aden.hour >= kSolarWindowStartHour && aden.hour < kSolarWindowEndHour;
}

SolarAssessment assessSolarWindow({
  required int startMinuteOfDay,
  required int durationMinutes,
}) {
  const lower = kSolarWindowStartHour * 60;
  const upper = kSolarWindowEndHour * 60;
  if (startMinuteOfDay < lower || startMinuteOfDay >= upper)
    { return SolarAssessment.startOutsideWindow; }
  if (startMinuteOfDay + durationMinutes > upper)
    { return SolarAssessment.requiresAlternative; }
  return SolarAssessment.ok;
}

SolarAssessment assessSolarInterval(DateTime start, DateTime end) {
  final aden = start.toUtc().add(const Duration(hours: 3));
  if (!solarAvailableAt(start)) return SolarAssessment.startOutsideWindow;
  final cutoff = DateTime.utc(aden.year, aden.month, aden.day, 15);
  return end.isAfter(cutoff)
      ? SolarAssessment.requiresAlternative
      : SolarAssessment.ok;
}

int solarStartMinuteOfDay(DateTime start) => start.hour * 60 + start.minute;

class SolarAvailabilityException extends StateError {
  SolarAvailabilityException.untrusted() : super(solarTimeUnverifiedMessage);
  SolarAvailabilityException.outsideWindow()
    : super('$solarUnavailableMessage\n$solarAvailabilityWindow');
}

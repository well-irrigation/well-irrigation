import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/features/well_setup/create_well_wizard_screen.dart';

void main() {
  test('whole-YER pricing is sent without minor-unit scaling', () {
    expect(
      buildWellSetupPricing(
        enableSolar: true,
        solarHourlyRate: 3500,
        enableWellDiesel: true,
        wellDieselHourlyRate: 7000,
        enableFarmerDiesel: true,
        farmerDieselHourlyRate: 6000,
      ),
      {
        'solar_rate_minor': 3500,
        'well_diesel_rate_minor': 7000,
        'farmer_diesel_rate_minor': 6000,
      },
    );
  });

  test('backend failure preserves data and cannot complete or close', () async {
    final data = WellSetupData()
      ..ownerFullName = 'مالك الاختبار'
      ..wellName = 'بئر الاختبار'
      ..district = 'همدان';
    var completed = false;
    var closed = false;

    final flow = WellSetupSubmissionFlow((_) async {
      throw Exception('backend unavailable');
    });

    final result = await flow.submit(
      data,
      onCompleted: () => completed = true,
      close: () => closed = true,
    );

    expect(result.succeeded, isFalse);
    expect(result.message, 'تعذر إنشاء البئر. تحقق من الاتصال وحاول مرة أخرى.');
    expect(result.message, isNot(contains('تم حفظ بيانات البئر محلياً')));
    expect(completed, isFalse);
    expect(closed, isFalse);
    expect(data.ownerFullName, 'مالك الاختبار');
    expect(data.wellName, 'بئر الاختبار');
    expect(data.district, 'همدان');
  });
}

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

  test('failed setup cannot complete the success flow', () {
    expect(shouldCompleteWellSetup(databaseSaved: false), isFalse);
    expect(shouldCompleteWellSetup(databaseSaved: true), isTrue);
  });
}

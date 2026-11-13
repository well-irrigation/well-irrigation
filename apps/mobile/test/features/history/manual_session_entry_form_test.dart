import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/features/history/manual_session_entry_form.dart';

import '../../core/sync/manual_session_entry_test.dart' as f;

ManualSessionEntryForm validForm({bool completed = true}) =>
    ManualSessionEntryForm(wellId: f.well, completed: completed)
      ..farmer = const FarmerAccount(
        id: f.farmer,
        fullName: 'مزارع',
        publicCode: '',
      )
      ..farm = const Farm(
        id: f.farm,
        wellId: f.well,
        farmerAccountId: f.farmer,
        name: 'أرض',
      )
      ..pump = const Pump(
        id: f.pump,
        wellId: f.well,
        name: 'مضخة',
        publicCode: '',
      )
      ..energy = 'solar'
      ..startedAt = f.start
      ..endedAt = f.end
      ..reason = 'إضافة فعلية';

void main() {
  for (final field in [
    'farmer',
    'farm',
    'pump',
    'energy',
    'startedAt',
    'endedAt',
    'reason',
  ]) {
    test('missing $field is actionable and blocks completed entry', () {
      final form = validForm();
      switch (field) {
        case 'farmer':
          form.farmer = null;
        case 'farm':
          form.farm = null;
        case 'pump':
          form.pump = null;
        case 'energy':
          form.energy = null;
        case 'startedAt':
          form.startedAt = null;
        case 'endedAt':
          form.endedAt = null;
        case 'reason':
          form.reason = '   ';
      }
      expect(form.validate(f.now), contains(field));
    });
  }
  test(
    'completed ordering and future end are rejected without changing values',
    () {
      final form = validForm()..endedAt = f.start;
      expect(form.validate(f.now), contains('endedAt'));
      form.endedAt = f.now.add(const Duration(hours: 1));
      expect(form.validate(f.now), contains('endedAt'));
      expect(form.endedAt, f.now.add(const Duration(hours: 1)));
    },
  );
  test('active future start is rejected', () {
    final form = validForm(completed: false)
      ..startedAt = f.now.add(const Duration(hours: 1));
    expect(form.validate(f.now), contains('startedAt'));
  });
  test('switching to active discards hidden end authority', () {
    final form = validForm()..setCompleted(false);
    expect(form.endedAt, isNull);
    expect(
      form.facts(f.now).payload['p_request'] as Map,
      isNot(contains('ended_at')),
    );
  });
  test('farmer change clears the previous farm', () {
    final form = validForm()..selectFarmer(null);
    expect(form.farm, isNull);
  });
  test(
    'old dates remain valid and facts contain no booking or local money',
    () {
      final form = validForm()..notes = 'ملاحظات';
      expect(form.validate(f.now), isEmpty);
      expect(
        (form.facts(f.now).payload['p_request'] as Map).keys,
        unorderedEquals([
          'version',
          'farmer_well_account_id',
          'farm_id',
          'pump_id',
          'started_at',
          'ended_at',
          'energy_source',
          'reason',
          'notes',
        ]),
      );
    },
  );
}

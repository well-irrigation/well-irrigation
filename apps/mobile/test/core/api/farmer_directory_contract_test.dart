import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';

void main() {
  group('FarmerDirectoryData contract', () {
    test('uses the well current day returned by contract 099', () {
      final data = FarmerDirectoryData.fromContract({
        'contract': 'list_well_farmer_directory',
        'version': 1,
        'current_day': '2100-01-10',
        'items': [
          {
            'id': 'account-1',
            'full_name': 'مزارع الاختبار',
            'public_code': 'FWA-1',
            'status': 'active',
            'farms_count': 1,
            'debt_minor': 0,
            'advance_minor': 0,
            'sessions_count': 1,
            'has_open_session': false,
            'last_session_day': '2100-01-09',
          },
        ],
      });

      expect(data.currentDay, DateTime(2100, 1, 10));
      expect(data.entries.single.lastSessionDay, DateTime(2100, 1, 9));
    });

    test('rejects missing financial fields instead of inventing zeroes', () {
      expect(
        () => FarmerDirectoryData.fromContract({
          'contract': 'list_well_farmer_directory',
          'version': 1,
          'current_day': '2100-01-10',
          'items': [
            {
              'id': 'account-1',
              'full_name': 'مزارع الاختبار',
              'public_code': 'FWA-1',
              'status': 'active',
              'farms_count': 1,
              'advance_minor': 0,
              'sessions_count': 1,
              'has_open_session': false,
            },
          ],
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects a response from an incompatible contract version', () {
      expect(
        () => FarmerDirectoryData.fromContract({
          'contract': 'list_well_farmer_directory',
          'version': 2,
          'current_day': '2100-01-10',
          'items': <Object>[],
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects a response without the current well day', () {
      expect(
        () => FarmerDirectoryData.fromContract({
          'contract': 'list_well_farmer_directory',
          'version': 1,
          'items': <Object>[],
        }),
        throwsA(isA<StateError>()),
      );
    });
  });
}

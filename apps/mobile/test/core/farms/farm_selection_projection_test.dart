import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/farms/farm_selection_projection.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';

void main() {
  test('resolved local identity collapses with canonical row and never merges empty ids', () {
    final time = DateTime.utc(2026);
    FarmCommandRow row(String id, String? server) => FarmCommandRow(
      command: CommandEnvelope(
        localId: id,
        commandId: id,
        type: CommandType.createFarm,
        accountId: 'a',
        wellId: 'w',
        sequence: 1,
        occurredAt: time,
        createdLocalAt: time,
        payload: {
          'p_well_id': 'w',
          'p_name': id,
          'p_farmer_well_account_id': 'f',
        },
      ),
      serverId: server,
      farmerId: 'f',
    );
    final list = projectFarmSelection(
      canonical: const [
        Farm(id: 'canonical', wellId: 'w', name: 'أرض', farmerAccountId: 'f'),
      ],
      local: [row('one', 'canonical'), row('two', null), row('three', null)],
      wellId: 'w',
      farmerId: 'f',
    );
    expect(list, hasLength(3));
    expect(list.where((f) => f.id == 'canonical'), hasLength(1));
    expect(list.where((f) => f.isPending), hasLength(2));
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/booking/booking_presentation.dart';
import 'package:well_irrigation_mobile/core/booking/booking_reactivity.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';

import '../sync/package_a_outbox_test.dart' as fixture;

void main() {
  test('coordinator ACK refreshes mounted booking facts without manual projection or schedule fetch', () async {
    final store = InMemoryOutboxStore();
    await store.insert(
      fixture.command('B', CommandType.startBookingSession, 1),
    );
    await store.insert(
      CommandEnvelope(
        localId: 'complete',
        commandId: 'complete-command',
        type: CommandType.completeIrrigationSession,
        accountId: 'account',
        wellId: 'well',
        aggregateLocalId: 'B',
        sequence: 2,
        occurredAt: fixture.instant.add(const Duration(minutes: 2)),
        createdLocalAt: fixture.instant,
        payload: {'p_session_id': 'server-B'},
      ),
    );
    final coordinator = OfflineSessionCoordinator(
      store: store,
      commandTransport: fixture.PackageTransport(),
    );
    final scope = BookingReactivity.instance.scope('account', 'well');
    var events = 0;
    void listener() => events++;
    scope.addListener(listener);
    await coordinator.freshProjectActiveSession(
      accountId: 'account',
      wellId: 'well',
    );
    expect(
      presentBooking(id: 'B', status: 'confirmed', scope: scope).label,
      'منفذ',
    );
    expect(scope.sessions['B']?.syncState, SessionSyncState.localOnly);
    events = 0;
    final report = await coordinator.syncNow('account');
    expect(report.confirmed, 2);
    expect(events, 1);
    expect(
      presentBooking(id: 'B', status: 'confirmed', scope: scope).label,
      'منفذ',
    );
    expect(
      presentBooking(id: 'B', status: 'confirmed', scope: scope).syncLabel,
      isNull,
    );
    scope.removeListener(listener);
    coordinator.dispose();
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/manual_stop_request_store.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';

import '../../support/identity_fixture.dart';
import '../../core/session/local_booking_transition_regression_test.dart'
    show EmptyFieldOperations, EmptyFieldPrices;

void main() {
  testWidgets(
    'recorded stop freezes display on reopen and disables conflicting actions',
    (t) async {
      final store = InMemoryOutboxStore();
      final coordinator = OfflineSessionCoordinator(store: store);
      final startAt = DateTime.now().subtract(const Duration(minutes: 2));
      var now = startAt.add(const Duration(seconds: 20));
      final root = await coordinator.startSession(
        accountId: 'account',
        wellId: 'well',
        pumpId: 'pump',
        farmId: 'farm',
        farmerAccountId: 'farmer',
        energySource: 'solar',
        startedAt: startAt,
      );
      await ManualStopRequestStore(store).recordHumanStopRequest(
        accountId: 'account',
        wellId: 'well',
        sessionLocalId: root.localId,
        requestedAt: now,
      );
      await t.pumpWidget(
        MaterialApp(
          home: OperationsScreen(
            identity: testIdentity(
              accountId: 'account',
              wells: [
                testWell(id: 'well', roles: ['operator']),
              ],
            ),
            coordinator: coordinator,
            repository: EmptyFieldOperations(),
            priceRepository: EmptyFieldPrices(),
            clock: () => now,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('متوقف محليًا'), findsWidgets);
      expect(find.text('00:00:20'), findsOneWidget);
      now = now.add(const Duration(minutes: 5));
      await t.pump(const Duration(seconds: 4));
      expect(find.text('00:00:20'), findsOneWidget);
      for (final label in ['إنهاء الجلسة', 'استئناف', 'إيقاف مؤقت']) {
        for (final element
            in find.widgetWithText(ElevatedButton, label).evaluate()) {
          expect((element.widget as ElevatedButton).onPressed, isNull);
        }
      }
      expect((await store.allCommands('account')), hasLength(1));
      await t.pumpWidget(const SizedBox());
      coordinator.dispose();
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_router.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_host.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_services.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_permission_coordinator.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_delivery_coordinator.dart';
import 'package:well_irrigation_mobile/core/notifications/operational_notification_event_factory.dart';

import 'notification_host_test.dart' show EmptyStore;
import 'notification_delivery_test.dart' show RecordingPresenter;
import 'notification_routing_permission_test.dart' show Permission;

void main() {
  testWidgets(
    'operations cold tap waits for auth; warm tap uses stored well and denies another account/well',
    (tester) async {
      final e = operationalEvent(
        accountId: 'a',
        wellId: 'w',
        eventType: 'session.started',
        identity: 'stable',
        entityType: 'session',
        entityId: 's',
        at: DateTime.utc(2027),
      );
      final router = NotificationRouter(
        load: (account, id) async => account == 'a' ? e : null,
      );
      final services = NotificationServices(
        router: router,
        delivery: NotificationDeliveryCoordinator(
          store: EmptyStore(),
          presenter: RecordingPresenter(),
        ),
        permission: NotificationPermissionCoordinator(
          gateway: Permission(),
          wasExplained: (a) async => true,
          markExplained: (a) async {},
        ),
      );
      final routes = <NotificationRoute>[];
      router.acceptPayload('a/1');
      expect(router.hasPending, true);
      await tester.pumpWidget(const MaterialApp(home: Text('auth')));
      expect(routes, isEmpty);
      Widget host(String account, Set<String> wells) => MaterialApp(
        home: NotificationHost(
          accountId: account,
          wellIds: wells,
          services: services,
          onRoute: routes.add,
          child: const Text('ready'),
        ),
      );
      await tester.pumpWidget(host('a', {'w'}));
      await tester.pump();
      expect(routes.single.type, 'operations');
      expect(routes.single.wellId, 'w');
      router.acceptPayload('a/1');
      await tester.pump();
      expect(routes, hasLength(2));
      await tester.pumpWidget(host('other', {'w'}));
      router.acceptPayload('a/1');
      await tester.pump();
      expect(routes, hasLength(2));
      await tester.pumpWidget(host('a', {'other'}));
      router.acceptPayload('a/1');
      await tester.pump();
      expect(routes, hasLength(2));
      await tester.pumpWidget(const SizedBox());
      router.dispose();
    },
  );
}

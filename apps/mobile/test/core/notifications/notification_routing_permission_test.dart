import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_router.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_permission_coordinator.dart';

import 'notification_delivery_test.dart' show event;

class Permission implements NotificationPermissionGateway {
  int requests = 0;
  bool allowed = false;
  @override
  Future<bool> permissionGranted() async => allowed;
  @override
  Future<bool> requestPermission() async {
    requests++;
    return allowed;
  }
}

void main() {
  test('cold tap waits for identity, warm tap resolves stored well/day/request, wrong account/well denied', () async {
    final router = NotificationRouter(
      load: (account, id) async =>
          account == 'a' && id == 1 ? event('x') : null,
    );
    router.acceptPayload('a/1');
    expect(router.hasPending, isTrue);
    final route = await router.resolve(
      accountId: 'a',
      accessibleWellIds: {'w'},
    );
    expect(route!.type, 'bookings');
    expect(route.wellId, 'w');
    expect(route.payload['day'], '2026-10-16');
    expect(route.payload['request_id'], 'r');
    expect(router.hasPending, isFalse);
    router.acceptPayload('a/1');
    expect(
      await router.resolve(accountId: 'b', accessibleWellIds: {'w'}),
      isNull,
    );
    router.acceptPayload('a/1');
    expect(
      await router.resolve(accountId: 'a', accessibleWellIds: {'other'}),
      isNull,
    );
    router.acceptPayload('forged payload');
    expect(router.hasPending, isFalse);
  });
  for (final allow in [true, false]) {
    test(
      'permission is requested only after explicit allow=$allow, never at startup, rationale offered once',
      () async {
        final gateway = Permission();
        final seen = <String>{};
        var explanations = 0;
        final coordinator = NotificationPermissionCoordinator(
          gateway: gateway,
          wasExplained: (a) async => seen.contains(a),
          markExplained: (a) async {
            seen.add(a);
          },
        );
        expect(gateway.requests, 0);
        await coordinator.offer('a', bookingResultRationale);
        expect(seen, isEmpty);
        coordinator.explain = (r) async {
          explanations++;
          expect(r.title, 'السماح بإشعارات نتيجة الحجز');
          return allow;
        };
        await coordinator.offer('a', bookingResultRationale);
        await coordinator.offer('a', bookingResultRationale);
        expect(explanations, 1);
        expect(gateway.requests, allow ? 1 : 0);
      },
    );
  }
}

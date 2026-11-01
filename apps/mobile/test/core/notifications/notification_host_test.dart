import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/notifications/app_notification_event.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_event_store.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_delivery_coordinator.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_host.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_permission_coordinator.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_router.dart';
import 'package:well_irrigation_mobile/core/notifications/notification_services.dart';

import 'notification_delivery_test.dart' show RecordingPresenter, event;
import 'notification_routing_permission_test.dart' show Permission;

class EmptyStore implements NotificationEventStore {
  @override
  Future<void> insertEvent(AppNotificationEvent e) async {}
  @override
  Future<List<NotificationDelivery>> pending(String a, DateTime n) async => [];
  @override
  Future<bool> hasOutstanding(String a) async => false;
  @override
  Future<bool> claim(String a, int i, DateTime n, DateTime l) async => false;
  @override
  Future<bool> beginPresentation(String a, int i, DateTime l) async => false;
  @override
  Future<void> complete(
    String a,
    int i,
    DateTime l,
    DateTime n, {
    String? suppressedReason,
    bool retry = false,
  }) async {}
}

void main() {
  for (final allow in [false, true]) {
    testWidgets(
      'rationale at text scale 2: explicit allow=$allow controls runtime permission, booking remains visible',
      (tester) async {
        final gateway = Permission();
        final seen = <String>{};
        final permission = NotificationPermissionCoordinator(
          gateway: gateway,
          wasExplained: (a) async => seen.contains(a),
          markExplained: (a) async {
            seen.add(a);
          },
        );
        final services = NotificationServices(
          delivery: NotificationDeliveryCoordinator(
            store: EmptyStore(),
            presenter: RecordingPresenter(),
          ),
          permission: permission,
          router: NotificationRouter(load: (a, id) async => null),
        );
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            supportedLocales: const [Locale('ar')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: NotificationHost(
              accountId: 'a',
              wellIds: {'w'},
              services: services,
              onRoute: (_) {},
              child: const Scaffold(body: Text('تم حفظ الحجز')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(gateway.requests, 0);
        expect(find.text('السماح بإشعارات نتيجة الحجز'), findsNothing);
        final offer = permission.offer('a', bookingResultRationale);
        await tester.pumpAndSettle();
        expect(
          find.text('لتصلك نتيجة الحجز حتى عندما لا يكون التطبيق أمامك.'),
          findsOneWidget,
        );
        final button = find.text(allow ? 'السماح' : 'ليس الآن');
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        await offer;
        expect(gateway.requests, allow ? 1 : 0);
        expect(find.text('تم حفظ الحجز'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'cold tap held until authenticated host, warm tap navigates stored context and account switch denies',
    (tester) async {
      final router = NotificationRouter(load: (a, id) async => event('x'));
      router.acceptPayload('a/1');
      final routes = <NotificationRoute>[];
      final services = NotificationServices(
        delivery: NotificationDeliveryCoordinator(
          store: EmptyStore(),
          presenter: RecordingPresenter(),
        ),
        permission: NotificationPermissionCoordinator(
          gateway: Permission(),
          wasExplained: (_) async => false,
          markExplained: (_) async {},
        ),
        router: router,
      );
      Widget app(String account) => MaterialApp(
        home: NotificationHost(
          accountId: account,
          wellIds: {'w'},
          services: services,
          onRoute: routes.add,
          child: const Scaffold(),
        ),
      );
      await tester.pumpWidget(app('a'));
      await tester.pumpAndSettle();
      expect(routes, hasLength(1));
      expect(routes.single.wellId, 'w');
      expect(routes.single.payload['request_id'], 'r');
      router.acceptPayload('a/1');
      await tester.pumpAndSettle();
      expect(routes, hasLength(2));
      await tester.pumpWidget(app('b'));
      await tester.pumpAndSettle();
      router.acceptPayload('a/1');
      await tester.pumpAndSettle();
      expect(routes, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    },
  );
}

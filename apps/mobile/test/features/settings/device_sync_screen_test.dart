import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/features/settings/device_sync_screen.dart';

void main() {
  group('DeviceSyncScreen Tests (UX-16A / القرارات 556–570)', () {
    tearDown(() {
      OfflineSessionCoordinator.instance.dispose();
    });
    testWidgets('1. عرض جاهزية التخزين المحلي وزر المزامنة اليدوية', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: DeviceSyncScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('الجهاز والمزامنة'), findsOneWidget);
      expect(find.text('جاهزية التخزين المحلي على الهاتف'), findsOneWidget);
      expect(find.text('العمل الميداني دون اتصال (Offline-First)'), findsOneWidget);
      expect(find.text('مزامنة الآن يدوياً'), findsOneWidget);
    });

    testWidgets('2. النقر على زر المزامنة اليدوية وتأكيد الاكتمال', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('ar'),
          home: DeviceSyncScreen(),
        ),
      );
      await tester.pumpAndSettle();

      final syncBtn = find.text('مزامنة الآن يدوياً');
      await tester.tap(syncBtn);
      await tester.pumpAndSettle();

      expect(find.text('اكتملت محاولة المزامنة وتحديث البيانات بنجاح ✅'), findsOneWidget);
    });
  });
}

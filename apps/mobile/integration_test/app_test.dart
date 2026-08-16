import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:well_irrigation_mobile/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'S7-01 renders Arabic bootstrap and protects health behind auth',
    (tester) async {
      await app.main();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      expect(find.text('إعداد التطبيق غير مكتمل'), findsNothing);

      expect(find.text('إدارة البئر والسقي'), findsOneWidget);

      expect(find.text('Stage 7 • S7-01'), findsOneWidget);

      expect(find.text('Flutter'), findsOneWidget);

      expect(find.text('Supabase'), findsOneWidget);

      expect(find.text('لا توجد جلسة دخول'), findsOneWidget);

      expect(find.text('schema: api'), findsOneWidget);

      expect(find.text('فحص عقد API'), findsOneWidget);

      final titleContext = tester.element(find.text('إدارة البئر والسقي'));

      expect(Directionality.of(titleContext), TextDirection.rtl);

      await tester.tap(find.text('فحص عقد API'));

      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      expect(find.text('المصادقة مطلوبة'), findsOneWidget);

      expect(find.text('api.health محمي ولا يعمل كـ anon.'), findsOneWidget);
    },
  );
}

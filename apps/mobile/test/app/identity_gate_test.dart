import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/app/identity_gate.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/identity/app_identity.dart';
import '../support/identity_fixture.dart';

/// بوابة الهوية: الحالات الثلاث تُقاس سلوكًا لا نصًّا (ق-113 / جولة الهوية).
///
/// الحالة التي كانت خطرة: فشل `api.app_bootstrap()` يُبتلع، فيدخل المستخدم
/// إلى شاشات ممتلئة باسم وبئر ودور جاهزين ليست له. الاختبار هنا يُثبِّت أن
/// المحتوى لا يُبنى أصلًا إلا من هوية حقيقية.
void main() {
  /// نصّ لا يظهر إلا إذا نُودي بانٍ المحتوى فعلًا: وجوده دليل بناء، وغيابه
  /// دليل أن البوابة لم تسلّم شيئًا لشاشة.
  const contentMarker = 'محتوى الهوية';

  Widget wrap(
    Future<BootstrapData> Function() load, {
    void Function(AppIdentity identity)? onBuilt,
    ValueChanged<ValueChanged<WellSummary>>? exposeWellChanged,
  }) {
    return MaterialApp(
      locale: const Locale('ar'),
      home: IdentityGate(
        loadBootstrap: load,
        builder: (context, identity, onWellChanged) {
          onBuilt?.call(identity);
          exposeWellChanged?.call(onWellChanged);
          return Scaffold(
            body: Column(
              children: [
                const Text(contentMarker),
                Text(identity.activeWell.name),
                Text(identity.accountId),
              ],
            ),
          );
        },
      ),
    );
  }

  group('resolveIdentity — ثلاث حالات صريحة لا رابعة', () {
    test('حمولة بلا هوية مستخدم = تعذُّر لا هوية فارغة', () {
      final resolution = resolveIdentity(
        BootstrapData(
          profile: testProfile(id: ''),
          wells: [testWell()],
        ),
      );

      expect(resolution, isA<IdentityUnavailable>());
      expect(
        (resolution as IdentityUnavailable).reason,
        'استجابة الحساب وصلت بلا هوية مستخدم',
      );
    });

    test('حساب بلا بئر = حالة مشروعة معلنة لا بئر مُلفَّق', () {
      final resolution = resolveIdentity(
        BootstrapData(profile: testProfile(), wells: const []),
      );

      expect(resolution, isA<IdentityWithoutWell>());
    });

    test('بئر بمعرّف فارغ يُستبعد ولا يُكمَّل في العميل', () {
      final resolution = resolveIdentity(
        BootstrapData(
          profile: testProfile(),
          wells: [testWell(id: '')],
        ),
      );

      expect(resolution, isA<IdentityWithoutWell>());
    });

    test('هوية كاملة: البئر النشط أول بئر حقيقي والمفتاح مفتاح العقد', () {
      final resolution = resolveIdentity(
        BootstrapData(
          profile: testProfile(id: 'auth-uid-9'),
          wells: [
            testWell(id: 'w-a', name: 'بئر أ'),
            testWell(id: 'w-b', name: 'بئر ب'),
          ],
        ),
      );

      expect(resolution, isA<IdentityReady>());
      final identity = (resolution as IdentityReady).identity;
      expect(identity.accountId, 'auth-uid-9');
      expect(identity.activeWell.id, 'w-a');
      expect(identity.wells.length, 2);
    });
  });

  group('IdentityGate — لا محتوى إلا من هوية حقيقية', () {
    testWidgets('1. فشل العقد يُعلن مع إعادة محاولة ولا يُبنى محتوى',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        wrap(() async {
          calls++;
          throw StateError('bootstrap unavailable');
        }),
      );
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.text('تعذر تحميل بيانات حسابك'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsOneWidget);
      expect(find.textContaining('bootstrap unavailable'), findsOneWidget);
      // لا اسم ولا بئر ولا دور جاهز يظهر بدل البيانات الحقيقية.
      expect(find.text(contentMarker), findsNothing);
      expect(find.text('بئر الخير الرئيسي'), findsNothing);
    });

    testWidgets('2. إعادة المحاولة تقرأ العقد من جديد وتبني بالهوية الحقيقية',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        wrap(() async {
          calls++;
          if (calls == 1) throw StateError('bootstrap unavailable');
          return BootstrapData(
            profile: testProfile(id: 'auth-uid-1', fullName: 'صاحب الحساب'),
            wells: [testWell(id: 'w-real', name: 'بئر حقيقي')],
          );
        }),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(calls, 2);
      expect(find.text(contentMarker), findsOneWidget);
      expect(find.text('بئر حقيقي'), findsOneWidget);
      expect(find.text('auth-uid-1'), findsOneWidget);
      expect(find.text('تعذر تحميل بيانات حسابك'), findsNothing);
    });

    testWidgets('3. حساب بلا بئر يُعلن حالته ولا يدخل شاشات ببئر مُلفَّق',
        (tester) async {
      await tester.pumpWidget(
        wrap(() async => BootstrapData(
              profile: testProfile(),
              wells: const [],
            )),
      );
      await tester.pumpAndSettle();

      expect(find.text('لا يوجد بئر مرتبط بحسابك'), findsOneWidget);
      expect(find.text(contentMarker), findsNothing);
      expect(find.text('إعادة المحاولة'), findsOneWidget);
    });

    testWidgets('4. تبديل البئر يُمرَّر بمعرّف حقيقي من آبار الحساب',
        (tester) async {
      final builtWells = <String>[];
      ValueChanged<WellSummary>? switchWell;

      await tester.pumpWidget(
        wrap(
          () async => BootstrapData(
            profile: testProfile(id: 'auth-uid-2'),
            wells: [
              testWell(id: 'w-a', name: 'بئر أ'),
              testWell(id: 'w-b', name: 'بئر ب', roles: const ['operator']),
            ],
          ),
          onBuilt: (identity) => builtWells.add(identity.activeWell.id),
          exposeWellChanged: (callback) => switchWell = callback,
        ),
      );
      await tester.pumpAndSettle();

      expect(builtWells.last, 'w-a');
      expect(find.text('بئر أ'), findsOneWidget);

      switchWell!(
        testWell(id: 'w-b', name: 'بئر ب', roles: const ['operator']),
      );
      await tester.pumpAndSettle();

      expect(builtWells.last, 'w-b');
      expect(find.text('بئر ب'), findsOneWidget);
      // الحساب لم يتغيّر بتغيّر البئر: مفتاح الطابور واحد للجولة كلها.
      expect(find.text('auth-uid-2'), findsOneWidget);
    });
  });
}

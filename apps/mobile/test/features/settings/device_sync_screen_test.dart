import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/account_repository.dart';
import 'package:well_irrigation_mobile/features/settings/device_sync_screen.dart';

/// مستودع اختبار يعيد حالة صريحة ولا يمس المنسق العام، فلا يُشغَّل مؤقت
/// الجلسة الحية داخل اختبار واجهة.
class _FakeSyncRepository extends AccountRepository {
  _FakeSyncRepository({
    this.status = const DeviceSyncStatusModel(
      localStorageReady: false,
      pendingOperationsCount: 0,
    ),
    this.failStatus = false,
    this.syncError,
  });

  final DeviceSyncStatusModel status;
  final bool failStatus;
  final Object? syncError;

  int statusReads = 0;
  int syncCalls = 0;

  /// آخر مفتاح حساب طلبته الشاشة. يُثبَّت في الاختبار لأن قراءة الطابور
  /// بمفتاح غير مفتاح صاحبه تُظهر «لا معلَّق» كذبًا (ق-113).
  final List<String> requestedAccountIds = [];

  @override
  Future<DeviceSyncStatusModel> fetchDeviceSyncStatus(String accountId) async {
    statusReads++;
    requestedAccountIds.add(accountId);
    if (failStatus) {
      throw StateError('device status unavailable');
    }
    return status;
  }

  @override
  Future<void> triggerManualSync(String accountId) async {
    syncCalls++;
    requestedAccountIds.add(accountId);
    final error = syncError;
    if (error != null) {
      throw error;
    }
  }
}

Future<void> _pumpScreen(
  WidgetTester tester,
  AccountRepository repository, {
  String accountId = 'owner-42',
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      home: DeviceSyncScreen(accountId: accountId, repository: repository),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('DeviceSyncScreen — المقيس فقط (م-41B3B / ق-120)', () {
    testWidgets('1. ما لم يُقس يُعرض «غير مقيس» لا «يعمل»', (tester) async {
      final repository = _FakeSyncRepository(
        status: const DeviceSyncStatusModel(
          localStorageReady: false,
          pendingOperationsCount: 3,
        ),
      );

      await _pumpScreen(tester, repository);

      expect(find.text('الجهاز والمزامنة'), findsOneWidget);
      expect(find.text('بانتظار المزامنة: 3 عملية'), findsOneWidget);
      expect(
        find.text('حالة الاتصال غير مقيسة في هذا الإصدار'),
        findsOneWidget,
      );
      expect(find.text('غير مقيسة في هذا الإصدار'), findsOneWidget);
      expect(find.text('غير موصول — الطابور في الذاكرة'), findsOneWidget);
      expect(find.text('لم تنجح مزامنة بعد'), findsOneWidget);

      // ادعاءات الإصدار السابق المُلفَّقة يجب أن تكون قد زالت.
      expect(find.text('متصل بالخادم السحابي'), findsNothing);
      expect(find.text('مفعلة وتعمل تلقائياً'), findsNothing);
      expect(find.text('جاهز ومؤمّن ✅'), findsNothing);
      expect(find.text('منذ دقيقتين (19/08/2026)'), findsNothing);
    });

    testWidgets(
      '2. المزامنة اليدوية غير الموصولة تُعلن صريحًا ولا تُعلن نجاحًا',
      (tester) async {
        final repository = _FakeSyncRepository(
          syncError: const ManualSyncUnavailableException(),
        );

        await _pumpScreen(tester, repository);

        await tester.tap(find.text('مزامنة الآن'));
        await tester.pumpAndSettle();

        expect(repository.syncCalls, 1);
        expect(
          find.text('المزامنة اليدوية غير متاحة في هذا الإصدار — لم يُرسل شيء'),
          findsOneWidget,
        );
        expect(
          find.text('اكتملت المزامنة وتحديث البيانات بنجاح ✅'),
          findsNothing,
        );
      },
    );

    testWidgets(
      '2ب. الطابور يُقرأ ويُزامَن بمفتاح صاحب الحساب لا بمفتاح ثابت',
      (tester) async {
        final repository = _FakeSyncRepository();

        await _pumpScreen(tester, repository, accountId: 'owner-99');

        await tester.tap(find.text('مزامنة الآن'));
        await tester.pumpAndSettle();

        expect(repository.requestedAccountIds, everyElement('owner-99'));
        expect(repository.requestedAccountIds.length, greaterThanOrEqualTo(2));
      },
    );

    testWidgets(
      '3. فشل قراءة الحالة يعرض خطأ صريحًا مع إعادة المحاولة',
      (tester) async {
        final repository = _FakeSyncRepository(failStatus: true);

        await _pumpScreen(tester, repository);

        expect(find.text('تعذر قراءة حالة الجهاز والمزامنة'), findsOneWidget);
        expect(find.text('مزامنة الآن'), findsNothing);
        expect(repository.statusReads, 1);

        await tester.tap(find.text('إعادة المحاولة'));
        await tester.pumpAndSettle();

        expect(repository.statusReads, 2);
      },
    );

    testWidgets(
      '4. الحالة المقيسة تُعرض كما هي، والنجاح الحقيقي وحده يعرض نجاحًا',
      (tester) async {
        final repository = _FakeSyncRepository(
          status: DeviceSyncStatusModel(
            localStorageReady: true,
            pendingOperationsCount: 0,
            lastSyncTime: DateTime(2026, 9, 2, 8, 5),
            isOnline: true,
            backgroundSyncActive: true,
          ),
        );

        await _pumpScreen(tester, repository);

        expect(find.text('لا توجد عمليات بانتظار المزامنة'), findsOneWidget);
        expect(find.text('متصل بالخادم السحابي'), findsOneWidget);
        expect(find.text('جاهز على قرص الهاتف ✅'), findsOneWidget);
        expect(find.text('02/09/2026 08:05'), findsOneWidget);
        expect(find.text('مفعّلة'), findsOneWidget);

        await tester.tap(find.text('مزامنة الآن'));
        await tester.pumpAndSettle();

        expect(repository.syncCalls, 1);
        expect(
          find.text('اكتملت المزامنة وتحديث البيانات بنجاح ✅'),
          findsOneWidget,
        );
      },
    );
  });
}

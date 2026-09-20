import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/account_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/farmer_identity_review.dart';
import 'package:well_irrigation_mobile/features/settings/device_sync_screen.dart';

class _FakeResolutionCoordinator extends OfflineSessionCoordinator {
  _FakeResolutionCoordinator();

  @override
  Future<void> initialize() async {}

  @override
  Future<CommandEnvelope> resolveFarmerWithExisting({
    required String accountId,
    required FarmerIdentityReview review,
    required String selectedPersonId,
  }) async {
    return CommandEnvelope(
      localId: 'res-local',
      commandId: 'res-cmd',
      type: CommandType.resolveFarmerIdentity,
      accountId: accountId,
      sequence: 1,
      occurredAt: DateTime.now(),
      createdLocalAt: DateTime.now(),
      payload: const {'p_well_id': 'well-1'},
    );
  }
}

class _TestSyncRepository extends AccountRepository {
  _TestSyncRepository({
    required this.reviews,
    required OfflineSessionCoordinator coordinator,
  }) : super(null, coordinator);

  final List<FarmerIdentityReview> reviews;

  @override
  Future<DeviceSyncStatusModel> fetchDeviceSyncStatus(String accountId) async {
    return const DeviceSyncStatusModel(
      localStorageReady: true,
      pendingOperationsCount: 1,
    );
  }

  @override
  Future<List<FarmerIdentityReview>> fetchFarmerIdentityReviews(
    String accountId,
  ) async {
    return reviews;
  }
}

void main() {
  testWidgets(
    '13, 14, 15, 16. DeviceSyncScreen and FarmerIdentityResolutionSheet UI, safe labels, same-phone validation, queued wording',
    (tester) async {
      final coordinator = _FakeResolutionCoordinator();
      final review = FarmerIdentityReview(
        commandLocalId: 'loc-1',
        commandId: 'cmd-1',
        wellId: 'well-1',
        fullName: 'سالم صالح',
        phone: '775555555',
        candidates: const [
          FarmerDuplicateCandidate(
            personId: 'p-salem',
            publicCode: 'FARMER-88',
            fullName: 'سالم صالح اليافعي',
            matchLevel: 'suspect',
            matchedOn: 'name+phone',
          ),
        ],
        occurredAt: DateTime(2026, 9, 20),
      );
      final repo = _TestSyncRepository(
        reviews: [review],
        coordinator: coordinator,
      );

      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          home: DeviceSyncScreen(
            accountId: 'acc-1',
            repository: repo,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 13. يظهر قسم العمليات المحتاجة مراجعة واسم المزارع
      expect(find.text('عمليات تحتاج مراجعة'), findsOneWidget);
      expect(find.text('سالم صالح'), findsOneWidget);

      // فتح نافذة الحسم
      await tester.tap(find.text('حسم'));
      await tester.pumpAndSettle();

      // 14. عرض الحقول الآمنة فقط للمرشح
      expect(find.text('سالم صالح اليافعي'), findsOneWidget);
      expect(find.text('FARMER-88'), findsOneWidget);
      expect(find.text('اشتباه تكرار'), findsOneWidget);
      expect(find.text('تطابق في الاسم ورقم الهاتف'), findsOneWidget);
      expect(find.text('استخدام هذا المزارع'), findsOneWidget);
      expect(find.text('هذا شخص مختلف'), findsOneWidget);

      // 15. فتح نموذج شخص مختلف والتحقق من منع استخدام نفس الهاتف
      await tester.tap(find.text('هذا شخص مختلف'));
      await tester.pumpAndSettle();

      // ظهور التنبيه التفسيري لحماية خصوصية هاتف المرشح وتأكيد التحقق الخادمي
      expect(
        find.textContaining('لا يُكشف هاتف المرشح حمايةً للخصوصية'),
        findsOneWidget,
      );

      // الضغط على تأكيد بينما الهاتف مطابق لرقم المرشح
      await tester.tap(find.text('تأكيد وحفظ القرار'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('لا يمكن تأكيد شخص مختلف بنفس رقم الهاتف المُدخل سابقًا'),
        findsOneWidget,
      );

      // 16. اختيار المرشح القائم والتحقق من نص الحفظ دون ادعاء نجاح سحابي
      await tester.ensureVisible(find.text('استخدام هذا المزارع'));
      await tester.tap(find.text('استخدام هذا المزارع'));
      await tester.pumpAndSettle();

      expect(
        find.text('تم حفظ قرار الحسم وسيتم مزامنته'),
        findsOneWidget,
      );
    },
  );
}

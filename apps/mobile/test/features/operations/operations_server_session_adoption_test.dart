import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';

import '../../support/identity_fixture.dart';

const _well = WellSummary(
  id: 'well-1',
  tenantId: 'tenant-1',
  name: 'بئر الخير الرئيسي',
  status: 'active',
  roles: ['owner', 'operator'],
);

WellDaySchedule _scheduleWithServerCurrent() => WellDaySchedule(
  wellId: 'well-1',
  requestedDay: DateTime.utc(2026, 10, 10),
  serverTime: DateTime.utc(2026, 10, 10, 8, 10),
  timezone: 'Asia/Aden',
  dayStart: DateTime.utc(2026, 10, 10, 3),
  dayEnd: DateTime.utc(2026, 10, 11, 3),
  wellTimezone: 'Asia/Aden',
  bookings: const [],
  currentSession: CurrentBookingSession(
    sessionId: 'server-B',
    status: 'open',
    startedAt: DateTime.utc(2026, 10, 10, 8, 0),
    wellId: 'well-1',
    bookingId: 'booking-B',
    bookingPublicCode: 'BK-002',
  ),
);

/// مستودع حجز يعيد قراءة طازجة (isCached=false) بجلسة خادمية جارية.
class _AdoptionBookingRepo extends BookingRepository {
  _AdoptionBookingRepo(this._schedule)
    : super(null, null, BookingLocalLedger(SqliteOutboxStore()), null);
  final WellDaySchedule _schedule;
  @override
  Future<BookingScheduleView> fetchScheduleView({
    required String accountId,
    required String wellId,
  }) async => BookingScheduleView(
    schedule: _schedule,
    isCached: false,
    fetchedAt: DateTime.utc(2026, 10, 10, 8, 10),
    timeAnchor: null,
  );
  @override
  Future<(BookingAutomationState, bool)> fetchAutomationView({
    required String accountId,
    required String wellId,
  }) async => (
    BookingAutomationState(
      wellId: wellId,
      enabled: false,
      settingsRowExists: true,
      firstSession: 'manual',
    ),
    false,
  );
  @override
  Future<List<BookingTransitionIntent>> reconcilePendingLocalIntents({
    required String accountId,
    required String wellId,
  }) async => const [];
}

class _EmptyOpsRepo extends OperationsRepository {
  const _EmptyOpsRepo();
  @override
  Future<List<Pump>> fetchPumps(String wellId) async => const [];
}

/// منسّق يعزل مسار الربط الخادمي ليبقى الاختبار على سلوك التبنّي في العرض.
class _AdoptionCoordinator extends OfflineSessionCoordinator {
  _AdoptionCoordinator() : super(store: InMemoryOutboxStore());
  @override
  Future<ServerBookingSessionLink?> reconcileServerBookingSession({
    required String accountId,
    required String wellId,
    required CurrentBookingSession? current,
  }) async => null;
  @override
  Future<ServerBookingSessionLink?> restoreServerBookingSession({
    required String accountId,
    required String wellId,
  }) async => null;
  @override
  Future<LocalProvisionalBookingSession?> restoreProvisionalBookingSession({
    required String accountId,
    required String wellId,
  }) async => null;
}

void main() {
  group('server session adoption (Slice 1)', () {
    late _AdoptionCoordinator coordinator;
    setUp(() async {
      coordinator = _AdoptionCoordinator();
      await coordinator.initialize();
    });
    tearDown(() => coordinator.dispose());

    testWidgets(
      'fresh server currentSession is adopted read-only with a live timer and disabled actions',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: OperationsScreen(
              identity: testIdentity(accountId: 'owner-1', wells: const [_well]),
              coordinator: coordinator,
              bookingRepository: _AdoptionBookingRepo(
                _scheduleWithServerCurrent(),
              ),
              repository: const _EmptyOpsRepo(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(seconds: 1));

        // الجلسة الخادمية الجارية مُتبنّاة للعرض فقط.
        expect(
          find.text('جلسة محجوزة جارية على الخادم (عرض فقط)'),
          findsOneWidget,
        );
        // عداد حيّ حقيقي من started_at الكنوني (ليس المعطّل --:--:--).
        expect(find.text('--:--:--'), findsNothing);
        // أفعال الجلسة معطّلة لجلسة بدأها الخادم.
        expect(find.textContaining('أوامرها'), findsOneWidget);
        expect(find.text('إيقاف مؤقت'), findsNothing);
        expect(find.text('إنهاء الجلسة'), findsNothing);
        expect(find.text('بدء جلسة سقي جديدة'), findsNothing);

        // تفكيك الغلاف يلغي المؤقّت.
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/features/bookings/booking_detail_screen.dart';

import '../../support/identity_fixture.dart';

WellBookingListItem _item() => WellBookingListItem(
  id: 'b1',
  publicCode: 'B-001',
  farmerWellAccountId: 'fa1',
  farmerName: 'مزارع الاختبار',
  farmId: 'farm1',
  farmName: 'الأرض الأولى',
  scheduledStart: DateTime.utc(2026, 10, 10, 5),
  scheduledEnd: DateTime.utc(2026, 10, 10, 6),
  scheduledDay: '2026-10-10',
  expectedDurationMinutes: 60,
  status: 'confirmed',
  priority: 0,
  expectedEnergySource: 'solar',
  notes: 'ملاحظة مهمة',
);

class _FakeRepo extends BookingRepository {
  _FakeRepo({this.cancelResult}) : super(null);
  BookingMutationResult? cancelResult;
  int cancelCalls = 0;
  @override
  Future<WellBookingDetail> getBookingDetail(String bookingId) async =>
      WellBookingDetail(booking: _item(), wellTimezone: 'Asia/Aden');
  @override
  Future<BookingMutationResult> cancelBooking({
    required String bookingId,
    required String reason,
    required String commandId,
  }) async {
    cancelCalls++;
    return cancelResult ??
        const BookingMutationResult(status: 'ok', bookingId: 'b1');
  }
}

void main() {
  Widget wrap(Widget child) => MaterialApp(
    locale: const Locale('ar'),
    home: Directionality(textDirection: TextDirection.rtl, child: child),
  );

  void sizeLarge(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('يعرض الحقول الكنونية بلا محاصيل مُختلقة', (tester) async {
    sizeLarge(tester);
    await tester.pumpWidget(
      wrap(
        BookingDetailScreen(
          bookingId: 'b1',
          identity: testIdentity(),
          bookingRepository: _FakeRepo(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('مزارع الاختبار'), findsOneWidget);
    expect(find.text('الأرض الأولى'), findsOneWidget);
    expect(find.text('مؤكد'), findsOneWidget);
    expect(find.textContaining('المحاصيل'), findsNothing);
  });

  testWidgets('الإلغاء دون اتصال لا يدّعي النجاح', (tester) async {
    sizeLarge(tester);
    final repo = _FakeRepo();
    await tester.pumpWidget(
      wrap(
        BookingDetailScreen(
          bookingId: 'b1',
          identity: testIdentity(),
          bookingRepository: repo,
          online: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('إلغاء الحجز'));
    await tester.pump();
    expect(
      find.text('هذه العملية تحتاج اتصالًا بالخادم حاليًا.'),
      findsOneWidget,
    );
    expect(repo.cancelCalls, 0);
  });

  testWidgets('الإلغاء يتطلب تأكيدًا صريحًا قبل تنفيذه', (tester) async {
    sizeLarge(tester);
    final repo = _FakeRepo();
    await tester.pumpWidget(
      wrap(
        BookingDetailScreen(
          bookingId: 'b1',
          identity: testIdentity(),
          bookingRepository: repo,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('إلغاء الحجز'));
    await tester.pumpAndSettle();
    // حوار تأكيد ظهر ولم يُنفَّذ الإلغاء بعد.
    expect(find.text('تأكيد الإلغاء'), findsOneWidget);
    expect(repo.cancelCalls, 0);
    await tester.tap(find.text('تأكيد الإلغاء'));
    await tester.pumpAndSettle();
    expect(repo.cancelCalls, 1);
  });

  testWidgets('التعارض يُعرض كنتيجة أعمال لا خطأ نقل', (tester) async {
    sizeLarge(tester);
    final repo = _FakeRepo(
      cancelResult: const BookingMutationResult(
        status: 'conflict',
        message: 'لا يمكن الإلغاء الآن',
      ),
    );
    await tester.pumpWidget(
      wrap(
        BookingDetailScreen(
          bookingId: 'b1',
          identity: testIdentity(),
          bookingRepository: repo,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('إلغاء الحجز'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأكيد الإلغاء'));
    await tester.pumpAndSettle();
    expect(find.text('لا يمكن الإلغاء الآن'), findsOneWidget);
    expect(repo.cancelCalls, 1);
  });
}

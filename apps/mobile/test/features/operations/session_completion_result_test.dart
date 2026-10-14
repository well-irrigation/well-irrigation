import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/active_session_record.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/session/session_business_state.dart';
import 'package:well_irrigation_mobile/core/session/session_segment.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/session_completion_result.dart';

ActiveSessionRecord result({
  int? approved,
  bool priced = true,
  List<LocalPayment> payments = const [],
}) {
  final at = DateTime.utc(2026, 10, 14, 3, 13);
  final segments = [
    SessionSegment(
      kind: SegmentKind.running,
      startedAt: at,
      endedAt: at.add(const Duration(minutes: 2)),
      energySource: 'solar',
      hourlyRateMinor: priced ? 3600 : null,
    ),
  ];
  return ActiveSessionRecord(
    localId: 'A',
    accountId: 'account',
    wellId: 'well',
    startedAt: at,
    completedAt: at.add(const Duration(minutes: 2)),
    businessState: SessionBusinessState.completed,
    syncState: SessionSyncState.pending,
    segments: segments,
    totals: summarize(segments, at.add(const Duration(minutes: 2))),
    payments: payments,
    timeIntegrityFlags: const {},
    pendingCommandCount: 1,
    approvedAmountMinor: approved,
  );
}

void main() {
  testWidgets('الإكمال بطاقة مستقلة ويتغير التقدير إلى المعتمد بلا تنقل', (
    tester,
  ) async {
    Future<void> show(ActiveSessionRecord record) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionCompletionResult(record: record, onLater: () {}),
        ),
      ),
    );
    await show(result());
    expect(find.text('انتهت الجلسة'), findsOneWidget);
    expect(find.text('المبلغ التقديري'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    await show(result(approved: 125));
    expect(find.text('المبلغ المعتمد'), findsOneWidget);
    expect(find.text('المبلغ التقديري'), findsNothing);
  });
  for (final entry in {
    'unpaid': 'غير مسدد',
    'partial': 'مدفوع جزئيًا',
    'settled': 'خالص',
  }.entries) {
    testWidgets('حالة السداد ${entry.key} تأتي من القراءة الكنونية', (
      tester,
    ) async {
      final detail = SessionDetailData(
        session: SessionHistoryItem(
          id: 'server',
          wellId: 'well',
          farmerName: 'مزارع',
          farmerCode: 'F',
          farmerAccountId: 'farmer',
          farmName: 'أرض',
          pumpName: 'مضخة',
          operatorName: 'مشغل',
          startedAt: DateTime.utc(2026),
          hasCharge: true,
          paymentStatus: entry.key,
        ),
        segments: const [],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionCompletionResult(
              record: result(approved: 120),
              detail: detail,
              onLater: () {},
            ),
          ),
        ),
      );
      expect(find.text(entry.value), findsOneWidget);
    });
  }
  for (final status in [
    CommandStatus.pending,
    CommandStatus.review,
    CommandStatus.confirmed,
  ]) {
    testWidgets('الدفعة ${status.name} لا تستبدل حالة السداد', (tester) async {
      final payment = LocalPayment(
        localId: 'payment',
        amountMinor: 120,
        paidAt: DateTime.utc(2026),
        status: status,
        serverId: status == CommandStatus.confirmed ? 'p-server' : null,
        acceptedReceipt: status == CommandStatus.confirmed
            ? {'public_code': 'PMT-123', 'amount_minor': 120}
            : null,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionCompletionResult(
              record: result(approved: 120, payments: [payment]),
              onLater: () {},
            ),
          ),
        ),
      );
      expect(find.text('خالص'), findsNothing);
      expect(find.textContaining('INV-'), findsNothing);
      if (status == CommandStatus.confirmed) {
        expect(find.text('سند القبض: PMT-123'), findsOneWidget);
      } else {
        expect(
          find.textContaining(
            status == CommandStatus.review
                ? 'يحتاج مراجعة'
                : 'دفعة معلقة — بانتظار المزامنة',
          ),
          findsOneWidget,
        );
      }
    });
  }
  testWidgets('التكلفة المجهولة ليست صفرا معتمدا', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionCompletionResult(
            record: result(priced: false),
            onLater: () {},
          ),
        ),
      ),
    );
    expect(find.text('المبلغ النهائي سيظهر بعد المزامنة'), findsOneWidget);
    expect(find.text('المبلغ المعتمد'), findsNothing);
  });
}

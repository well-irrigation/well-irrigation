import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/api/well_management_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';
import 'package:well_irrigation_mobile/features/history/session_detail_screen.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/payment_receipt_dialog.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/session_completion_result.dart';

import '../../support/identity_fixture.dart';

class _Repo extends OperationsRepository {
  String status = 'unpaid';
  int reads = 0;
  @override
  Future<List<FarmerAccount>> fetchFarmers(String id, {String? query}) async =>
      [];
  @override
  Future<List<Farm>> fetchFarms(String id, {String? farmerAccountId}) async =>
      [];
  @override
  Future<List<Pump>> fetchPumps(String id) async => [];
  @override
  Future<SessionDetailData> fetchSessionDetail(String id) async {
    reads++;
    return SessionDetailData(
      session: SessionHistoryItem(
        id: id,
        wellId: 'well',
        farmerName: 'محمد علي',
        farmerCode: 'F1',
        farmerAccountId: 'farmer',
        farmName: 'أرض الخير',
        pumpName: 'المضخة 1',
        operatorName: 'مشغل',
        startedAt: DateTime.utc(2026, 10, 14, 9),
        endedAt: DateTime.utc(2026, 10, 14, 9, 10),
        actualSeconds: 600,
        billableSeconds: 600,
        hasCharge: true,
        hasInvoice: false,
        totalAmountYER: 86,
        paidAmountYER: status == 'settled'
            ? 86
            : status == 'partial'
            ? 20
            : 0,
        paymentStatus: status,
      ),
      segments: const [],
    );
  }
}

class _Prices extends WellManagementRepository {
  @override
  Future<PriceScheduleModel?> fetchActivePriceSchedule(
    String id, {
    DateTime? at,
  }) async => null;
}

void main() {
  setUpAll(() async {
    final fonts = FontLoader('NotoSansArabic');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      fonts.addFont(rootBundle.load('assets/fonts/NotoSansArabic-$weight.ttf'));
    }
    await fonts.load();
  });
  for (final scenario in [
    'none',
    'unpaid',
    'partial',
    'settled',
    'settled-read',
    'pending',
    'review',
    'unknown',
  ]) {
    testWidgets(
      '$scenario reminder uses shared eligibility and never creates commands on open/rebuild',
      (t) async {
        t.view.physicalSize = const Size(720, 1600);
        t.view.devicePixelRatio = 2;
        addTearDown(t.view.reset);
        final store = InMemoryOutboxStore();
        final c = OfflineSessionCoordinator(store: store);
        addTearDown(c.dispose);
        final repo = _Repo()
          ..status = scenario == 'settled-read'
              ? 'settled'
              : scenario == 'unknown'
              ? 'unknown'
              : scenario == 'partial' || scenario == 'settled'
              ? scenario
              : 'unpaid';
        final at = DateTime.utc(2026, 10, 14, 9);
        await c.initialize();
        late StateSetter rebuild;
        if (scenario != 'none') {
          final start = await c.startSession(
            accountId: 'account',
            wellId: 'well',
            pumpId: 'pump',
            farmId: 'farm',
            farmerAccountId: 'farmer',
            energySource: 'solar',
            farmerName: 'محمد علي',
            farmName: 'أرض الخير',
            pumpName: 'المضخة 1',
            startedAt: at,
          );
          final end = await c.completeSession(
            accountId: 'account',
            sessionLocalId: start.localId,
            completedAt: at.add(const Duration(minutes: 10)),
          );
          await store.putMapping(
            'account',
            IdMapping(
              localId: start.localId,
              kind: EntityKind.session,
              serverId: 'server',
              resolvedAt: at,
            ),
          );
          await store.markConfirmed(
            'account',
            start.localId,
            serverResponse: {'session_id': 'server'},
            attemptedAt: at,
          );
          await store.markConfirmed(
            'account',
            end.localId,
            serverResponse: {'session_charge_id': 'charge', 'amount_minor': 86},
            attemptedAt: at,
          );
          if (['partial', 'settled', 'pending', 'review'].contains(scenario)) {
            final payment = await c.recordPayment(
              accountId: 'account',
              wellId: 'well',
              farmerAccountId: 'farmer',
              amountMinor: 20,
              paymentMethod: 'cash',
              sessionLocalId: start.localId,
              sessionCompletionLocalId: end.localId,
            );
            if (scenario == 'review') {
              await store.markNeedsReview(
                'account',
                payment.localId,
                error: 'review',
                attemptedAt: at,
              );
            } else if (scenario != 'pending') {
              await store.putMapping(
                'account',
                IdMapping(
                  localId: payment.localId,
                  kind: EntityKind.payment,
                  serverId: 'pay',
                  resolvedAt: at,
                ),
              );
              await store.markConfirmed(
                'account',
                payment.localId,
                serverResponse: {
                  'payment_id': 'pay',
                  'receipt': {'public_code': 'PAY-26-FA378'},
                },
                attemptedAt: at,
              );
            }
          }
          final state = (await c.restoreCompletedSession(
            accountId: 'account',
            wellId: 'well',
            serverSessionId: 'server',
          ))!;
          if (scenario != 'settled-read') {
            await c.rememberSessionPaymentRead(
              accountId: 'account',
              wellId: 'well',
              detail: await repo.fetchSessionDetail('server'),
              revision: state.revision,
            );
          }
        }
        await t.pumpWidget(
          MaterialApp(
            locale: const Locale('ar'),
            supportedLocales: const [Locale('ar')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: ThemeData(fontFamily: 'NotoSansArabic', useMaterial3: true),
            home: StatefulBuilder(
              builder: (ctx, setState) {
                rebuild = setState;
                return OperationsScreen(
                  identity: testIdentity(
                    accountId: 'account',
                    wells: [
                      testWell(id: 'well', roles: ['operator']),
                    ],
                  ),
                  coordinator: c,
                  repository: repo,
                  priceRepository: _Prices(),
                  clock: () => at.add(const Duration(minutes: 10)),
                );
              },
            ),
          ),
        );
        await t.pumpAndSettle();
        await c.freshProjectActiveSession(accountId: 'account', wellId: 'well');
        await t.pumpAndSettle();
        final payable = ['unpaid', 'partial'].contains(scenario);
        expect(
          find.text('دفعة مؤجلة'),
          payable ? findsOneWidget : findsNothing,
        );
        expect(find.byType(SessionCompletionResult), findsNothing);
        expect(find.text('تسجيل دفعة'), findsNothing);
        expect(
          find.byType(BottomSheet),
          findsNothing,
          reason: 'completion never auto-opens a finance surface',
        );
        final commandsBefore = (await store.allCommands('account')).length;
        final readsBefore = repo.reads;
        rebuild(() {});
        await t.pumpAndSettle();
        expect((await store.allCommands('account')).length, commandsBefore);
        await t.pump(const Duration(seconds: 2));
        await t.pumpAndSettle();
        expect(
          repo.reads,
          readsBefore,
          reason: 'no polling or rebuild-triggered network refresh',
        );
        expect(t.takeException(), isNull);
        if (payable) {
          final hint = find.text('دفعة مؤجلة');
          await t.ensureVisible(hint);
          final card = find
              .ancestor(of: hint, matching: find.byType(Card))
              .first;
          expect(t.getSize(card).height, lessThan(110));
          await t.tap(hint);
          await t.pumpAndSettle();
          expect(find.byType(BottomSheet), findsOneWidget);
          expect(find.text('تسجيل دفعة'), findsOneWidget);
          expect(find.text('عرض التفاصيل'), findsOneWidget);
          expect(find.text('لاحقًا'), findsNothing);
          expect(find.text('ستة وثمانون ريالًا فقط'), findsOneWidget);
          expect(
            find.textContaining('PAY-'),
            findsNothing,
            reason: 'summary does not duplicate legal receipt details',
          );
          expect(t.takeException(), isNull);
          for (final scroll in t.widgetList<Scrollable>(
            find.descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Scrollable),
            ),
          )) {
            final state = t.state<ScrollableState>(find.byWidget(scroll));
            expect(
              state.position.maxScrollExtent,
              0,
              reason: 'default summary fits without scrolling',
            );
          }
          await t.tap(find.byTooltip('إغلاق'));
          await t.pumpAndSettle();
          expect(find.byType(BottomSheet), findsNothing);
          expect((await store.allCommands('account')).length, commandsBefore);
          await t.tap(hint);
          await t.pumpAndSettle();
          await t.tap(find.text('تسجيل دفعة'));
          await t.pumpAndSettle();
          expect(find.byType(PaymentReceiptDialog), findsOneWidget);
          expect(find.text('مبلغ الدفعة'), findsOneWidget);
          expect(find.text('نقدًا'), findsOneWidget);
          await t.tap(find.byTooltip('إغلاق طلب الدفعة'));
          await t.pumpAndSettle();
          expect((await store.allCommands('account')).length, commandsBefore);
          await t.tap(hint);
          await t.pumpAndSettle();
          await t.tap(find.text('عرض التفاصيل'));
          await t.pumpAndSettle();
          expect(find.byType(SessionDetailScreen), findsOneWidget);
          expect(find.text('لا توجد فاتورة مسجلة'), findsOneWidget);
          Navigator.of(t.element(find.byType(SessionDetailScreen))).pop();
          await t.pumpAndSettle();
          expect((await store.allCommands('account')).length, commandsBefore);
          if (scenario == 'unpaid') {
            await t.tap(hint);
            await t.pumpAndSettle();
            final end = (await store.allCommands('account')).singleWhere(
              (c) => c.type == CommandType.completeIrrigationSession,
            );
            final pending = await c.recordPayment(
              accountId: 'account',
              wellId: 'well',
              farmerAccountId: 'farmer',
              amountMinor: 86,
              paymentMethod: 'cash',
              sessionLocalId: end.aggregateLocalId,
              sessionCompletionLocalId: end.localId,
            );
            await t.pumpAndSettle();
            expect(
              find.text('تسجيل دفعة'),
              findsNothing,
              reason: 'an open summary also responds to pending state',
            );
            expect(find.text('دفعة معلقة — بانتظار المزامنة'), findsOneWidget);
            await t.tap(find.byTooltip('إغلاق'));
            await t.pumpAndSettle();
            expect(find.text('دفعة مؤجلة'), findsNothing);
            repo.status = 'settled';
            await store.putMapping(
              'account',
              IdMapping(
                localId: pending.localId,
                kind: EntityKind.payment,
                serverId: 'accepted-payment',
                resolvedAt: at,
              ),
            );
            await store.markConfirmed(
              'account',
              pending.localId,
              serverResponse: {
                'payment_id': 'accepted-payment',
                'receipt': {'public_code': 'PAY-26-FA378'},
              },
              attemptedAt: at,
            );
            final accepted = (await c.restoreCompletedSession(
              accountId: 'account',
              wellId: 'well',
              serverSessionId: 'server',
            ))!;
            await c.rememberSessionPaymentRead(
              accountId: 'account',
              wellId: 'well',
              detail: await repo.fetchSessionDetail('server'),
              revision: accepted.revision,
            );
            await c.freshProjectActiveSession(
              accountId: 'account',
              wellId: 'well',
            );
            await t.pumpAndSettle();
            expect(find.text('دفعة مؤجلة'), findsNothing);
            expect(find.text('تسجيل دفعة'), findsNothing);
            expect(find.byType(SessionCompletionResult), findsNothing);
            expect(
              (await store.allCommands('account'))
                  .where((c) => c.type == CommandType.recordPayment),
              hasLength(1),
            );
          }
        }
        await t.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }
}

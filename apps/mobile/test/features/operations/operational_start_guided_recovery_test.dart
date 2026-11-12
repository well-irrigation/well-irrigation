import 'dart:async';

import 'package:flutter/material.dart';
import 'package:well_irrigation_mobile/core/session/operational_start_recovery.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/sync/operational_start_receipt.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:well_irrigation_mobile/core/sync/start_recovery_policy.dart';
import 'package:well_irrigation_mobile/features/operations/widgets/operational_start_recovery_dialog.dart';

import '../../core/session/operational_start_guided_recovery_test.dart'
    show GuidedReceiptTransport, GuidedRepository, reviewStart, startTime;

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/session/manual_stop_request_store.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';

import '../../support/identity_fixture.dart';
import '../../core/session/local_booking_transition_regression_test.dart'
    show EmptyFieldOperations, EmptyFieldPrices;

class GuidedFieldOperations extends EmptyFieldOperations {
  final details = GuidedRepository();
  @override
  Future<SessionDetailData> fetchSessionDetail(String id) =>
      details.fetchSessionDetail(id);
}

Future<void> openGuided(
  WidgetTester t,
  OperationalStartRecovery recovery,
  String root, {
  required Future<void> Function() onResolved,
  bool Function()? owns,
  bool largeText = false,
}) async {
  await t.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(largeText ? 2 : 1)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (context) => OperationalStartRecoveryDialog(
                recovery: recovery,
                accountId: 'account',
                wellId: 'well',
                sessionLocalId: root,
                startedAt: startTime,
                farmerName: 'المزارع',
                farmName: 'الأرض',
                isContextCurrent: owns ?? () => true,
                onResolved: onResolved,
              ),
            ),
            child: const Text('فتح'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('فتح'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'operations card reconciles an existing server session without any dispatch',
    (t) async {
      final store = InMemoryOutboxStore();
      final root = await reviewStart(store);
      final transport = GuidedReceiptTransport();
      final coordinator = OfflineSessionCoordinator(
        store: store,
        commandTransport: transport,
        currentAccountId: () => 'account',
      );
      await t.pumpWidget(
        MaterialApp(
          home: OperationsScreen(
            identity: testIdentity(
              accountId: 'account',
              wells: [
                testWell(id: 'well', roles: ['operator']),
              ],
            ),
            coordinator: coordinator,
            repository: GuidedFieldOperations(),
            priceRepository: EmptyFieldPrices(),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('إصلاح الحالة'));
      await t.pumpAndSettle();
      expect(transport.reads, 0);
      expect(transport.requests, isEmpty);
      await t.tap(find.text('التحقق من حالة الجلسة'));
      await t.pumpAndSettle();
      await t.tap(find.text('اعتماد الجلسة والمتابعة'));
      await t.pumpAndSettle();
      await t.tap(find.text('العودة إلى التشغيل'));
      await t.pumpAndSettle();
      expect(coordinator.currentActiveSession!.serverSessionId, 'server');
      expect(transport.requests, isEmpty);
      expect(find.text('إصلاح الحالة'), findsNothing);
      expect(
        (await store.commandByLocalId('account', root.localId))!.status,
        CommandStatus.confirmed,
      );
      await t.pumpWidget(const SizedBox());
      coordinator.dispose();
      await store.close();
    },
  );

  group('guided dialog', () {
    late InMemoryOutboxStore store;
    late GuidedReceiptTransport transport;
    late GuidedRepository repository;
    late OperationalStartRecovery recovery;
    late String root;
    int resolved = 0;
    setUp(() async {
      store = InMemoryOutboxStore();
      root = (await reviewStart(store)).localId;
      transport = GuidedReceiptTransport();
      repository = GuidedRepository();
      resolved = 0;
      recovery = OperationalStartRecovery(
        store: store,
        transport: transport,
        repository: repository,
        currentAccountId: () => 'account',
      );
    });
    tearDown(() async {
      await store.close();
    });
    testWidgets(
      'verified rejection offers explicit local closure without submission',
      (t) async {
        transport.state = OperationalStartReceiptState.rejected;
        await openGuided(
          t,
          recovery,
          root,
          onResolved: () async {
            resolved++;
          },
        );
        await t.tap(find.text('التحقق من حالة الجلسة'));
        await t.pumpAndSettle();
        expect(
          find.text('تم التأكد أن محاولة البدء السابقة لم تُنشئ جلسة.'),
          findsOneWidget,
        );
        expect(find.text('إنهاء المحاولة السابقة'), findsOneWidget);
        expect(transport.requests, isEmpty);
      },
    );
    testWidgets(
      'explicit rejected closure requires reason and confirmation, double tap commits once',
      (t) async {
        transport.state = OperationalStartReceiptState.rejected;
        await openGuided(
          t,
          recovery,
          root,
          onResolved: () async {
            resolved++;
          },
        );
        await t.tap(find.text('التحقق من حالة الجلسة'));
        await t.pumpAndSettle();
        final button = find.widgetWithText(
          FilledButton,
          'إنهاء المحاولة السابقة',
        );
        expect(t.widget<FilledButton>(button).onPressed, isNull);
        await t.enterText(find.byType(TextField), 'تمت المراجعة');
        await t.ensureVisible(find.byType(CheckboxListTile));
        await t.tap(find.byType(CheckboxListTile));
        await t.pump();
        await t.ensureVisible(button);
        await t.tap(button);
        await t.tap(button);
        await t.pumpAndSettle();
        expect(resolved, 1);
        expect(transport.requests, isEmpty);
        expect(
          (await store.commandByLocalId('account', root))!.status,
          CommandStatus.review,
        );
        expect(
          find.text(
            'تم إنهاء المحاولة السابقة ويمكنك بدء جلسة جديدة عند الحاجة.',
          ),
          findsOneWidget,
        );
        final raw = await store.readBundle('account', startRecoveryKey(root));
        expect(raw, isNotNull);
        await t.tap(find.text('العودة إلى التشغيل'));
        await t.pumpAndSettle();
        expect(await store.readBundle('account', startRecoveryKey(root)), raw);
      },
    );
    testWidgets('back after rejected proof does not implicitly resolve it', (
      t,
    ) async {
      transport.state = OperationalStartReceiptState.rejected;
      await openGuided(
        t,
        recovery,
        root,
        onResolved: () async {
          resolved++;
        },
      );
      await t.tap(find.text('التحقق من حالة الجلسة'));
      await t.pumpAndSettle();
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(await store.readBundle('account', startRecoveryKey(root)), isNull);
      expect(resolved, 0);
      expect(transport.requests, isEmpty);
    });
    testWidgets(
      'opening and back only read presentation, no command or implicit resolution',
      (t) async {
        await openGuided(
          t,
          recovery,
          root,
          onResolved: () async {
            resolved++;
          },
        );
        expect(transport.reads, 0);
        expect(transport.requests, isEmpty);
        await t.binding.handlePopRoute();
        await t.pumpAndSettle();
        expect(
          (await store.commandByLocalId('account', root))!.status,
          CommandStatus.review,
        );
        expect(resolved, 0);
        expect(await store.allCommands('account'), hasLength(1));
      },
    );
    testWidgets(
      'accepted adoption is explicit, one action, and presents resolved return step',
      (t) async {
        await openGuided(
          t,
          recovery,
          root,
          onResolved: () async {
            resolved++;
          },
        );
        await t.tap(find.text('التحقق من حالة الجلسة'));
        await t.pumpAndSettle();
        expect(
          find.text('تم العثور على الجلسة المطابقة على الخادم.'),
          findsOneWidget,
        );
        expect(
          (await store.commandByLocalId('account', root))!.status,
          CommandStatus.review,
        );
        transport.barrier = Completer<void>();
        await t.tap(find.text('اعتماد الجلسة والمتابعة'));
        await t.tap(find.text('اعتماد الجلسة والمتابعة'));
        transport.barrier!.complete();
        await t.pumpAndSettle();
        expect(resolved, 1);
        expect(transport.reads, 1);
        expect(transport.requests, isEmpty);
        expect(find.text('العودة إلى التشغيل'), findsOneWidget);
        await t.tap(find.text('العودة إلى التشغيل'));
        await t.pumpAndSettle();
        expect(find.text('فتح'), findsOneWidget);
        expect(resolved, 1);
        expect(await store.allCommands('account'), hasLength(1));
      },
    );
    for (final state in [
      OperationalStartReceiptState.processing,
      OperationalStartReceiptState.unresolved,
      OperationalStartReceiptState.notFound,
      OperationalStartReceiptState.rejected,
    ]) {
      testWidgets('$state offers check only, with no new start or resend', (
        t,
      ) async {
        transport.state = state;
        await openGuided(
          t,
          recovery,
          root,
          onResolved: () async {
            resolved++;
          },
        );
        await t.tap(find.text('التحقق من حالة الجلسة'));
        await t.pumpAndSettle();
        expect(find.text('إعادة التحقق'), findsOneWidget);
        expect(find.text('اعتماد الجلسة والمتابعة'), findsNothing);
        expect(
          find.text('إنهاء المحاولة السابقة'),
          state == OperationalStartReceiptState.rejected
              ? findsOneWidget
              : findsNothing,
        );
        expect(find.text('إرسال مرة أخرى'), findsNothing);
        expect(resolved, 0);
        expect(transport.requests, isEmpty);
        expect(
          (await store.commandByLocalId('account', root))!.status,
          CommandStatus.review,
        );
      });
    }
    testWidgets(
      'offline is retryable read and preserves evidence at large text scale',
      (t) async {
        transport.failure = OperationalStartReceiptFailureKind.network;
        await openGuided(
          t,
          recovery,
          root,
          onResolved: () async {
            resolved++;
          },
          largeText: true,
        );
        await t.ensureVisible(find.text('التحقق من حالة الجلسة'));
        await t.tap(find.text('التحقق من حالة الجلسة'));
        await t.pumpAndSettle();
        expect(
          find.textContaining('أعد التحقق عند توفر الاتصال'),
          findsOneWidget,
        );
        expect(t.takeException(), isNull);
        transport.failure = null;
        await t.ensureVisible(find.text('إعادة التحقق'));
        await t.tap(find.text('إعادة التحقق'));
        await t.pumpAndSettle();
        expect(
          find.text('تم العثور على الجلسة المطابقة على الخادم.'),
          findsOneWidget,
        );
        expect(transport.requests, isEmpty);
      },
    );
    testWidgets(
      'lost parent ownership ends checking and asks for the current session',
      (t) async {
        bool owns = true;
        transport.barrier = Completer<void>();
        await openGuided(
          t,
          recovery,
          root,
          onResolved: () async {
            resolved++;
          },
          owns: () => owns,
        );
        await t.tap(find.text('التحقق من حالة الجلسة'));
        await t.pump();
        owns = false;
        transport.barrier!.complete();
        await t.pump();
        await t.pump(const Duration(seconds: 1));
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(
          find.textContaining('أعد فتحها من الجلسة الحالية'),
          findsOneWidget,
        );
        expect(find.text('اعتماد الجلسة والمتابعة'), findsNothing);
        expect(resolved, 0);
        expect(transport.requests, isEmpty);
      },
    );
    testWidgets(
      'context replacement discards a prior well read before allowing adoption',
      (t) async {
        final well = ValueNotifier<String>('well');
        addTearDown(well.dispose);
        transport.barrier = Completer<void>();
        await t.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<bool>(
                    context: context,
                    builder: (context) => ValueListenableBuilder<String>(
                      valueListenable: well,
                      builder: (context, id, child) =>
                          OperationalStartRecoveryDialog(
                            recovery: recovery,
                            accountId: 'account',
                            wellId: id,
                            sessionLocalId: root,
                            startedAt: startTime,
                            isContextCurrent: () => true,
                            onResolved: () async {
                              resolved++;
                            },
                          ),
                    ),
                  ),
                  child: const Text('فتح'),
                ),
              ),
            ),
          ),
        );
        await t.tap(find.text('فتح'));
        await t.pumpAndSettle();
        await t.tap(find.text('التحقق من حالة الجلسة'));
        await t.pump();
        well.value = 'different-well';
        await t.pump();
        transport.barrier!.complete();
        await t.pumpAndSettle();
        expect(
          find.text('تم العثور على الجلسة المطابقة على الخادم.'),
          findsNothing,
        );
        expect(find.text('اعتماد الجلسة والمتابعة'), findsNothing);
        expect(find.text('التحقق من حالة الجلسة'), findsOneWidget);
        expect(
          (await store.commandByLocalId('account', root))!.status,
          CommandStatus.review,
        );
        expect(resolved, 0);
        expect(transport.requests, isEmpty);
      },
    );
    testWidgets(
      'temporary route loss retains a checked result without another read',
      (t) async {
        transport.barrier = Completer<void>();
        await openGuided(
          t,
          recovery,
          root,
          onResolved: () async {
            resolved++;
          },
        );
        await t.tap(find.text('التحقق من حالة الجلسة'));
        await t.pump();
        final navigator = t.state<NavigatorState>(find.byType(Navigator).first);
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(
              builder: (context) => const Scaffold(body: Text('صفحة مؤقتة')),
            ),
          ),
        );
        await t.pumpAndSettle();
        transport.barrier!.complete();
        await t.pumpAndSettle();
        navigator.pop();
        await t.pumpAndSettle();
        expect(
          find.text('تم العثور على الجلسة المطابقة على الخادم.'),
          findsOneWidget,
        );
        expect(transport.reads, 1);
        expect(transport.requests, isEmpty);
        expect(resolved, 0);
      },
    );
    testWidgets(
      'projection refresh failure preserves accepted result and explicit return',
      (t) async {
        await openGuided(
          t,
          recovery,
          root,
          onResolved: () async {
            resolved++;
            throw StateError('refresh failure');
          },
        );
        await t.tap(find.text('التحقق من حالة الجلسة'));
        await t.pumpAndSettle();
        await t.tap(find.text('اعتماد الجلسة والمتابعة'));
        await t.pumpAndSettle();
        expect(find.text('العودة إلى التشغيل'), findsOneWidget);
        expect(resolved, 1);
        expect(
          (await store.commandByLocalId('account', root))!.status,
          CommandStatus.confirmed,
        );
        expect(transport.requests, isEmpty);
        expect(find.text('refresh failure'), findsNothing);
      },
    );
    testWidgets(
      'departure during read discards late result without navigation or mutation',
      (t) async {
        transport.barrier = Completer<void>();
        await openGuided(
          t,
          recovery,
          root,
          onResolved: () async {
            resolved++;
          },
        );
        await t.tap(find.text('التحقق من حالة الجلسة'));
        await t.pump();
        await t.binding.handlePopRoute();
        await t.pumpAndSettle();
        transport.barrier!.complete();
        await t.pumpAndSettle();
        expect(find.text('فتح'), findsOneWidget);
        expect(resolved, 0);
        expect(t.takeException(), isNull);
        expect(
          (await store.commandByLocalId('account', root))!.status,
          CommandStatus.review,
        );
        expect(transport.requests, isEmpty);
      },
    );
  });

  testWidgets('uncertain operational start offers guided recovery on its card', (
    t,
  ) async {
    final store = InMemoryOutboxStore();
    final coordinator = OfflineSessionCoordinator(store: store);
    final root = await coordinator.startSession(
      accountId: 'account',
      wellId: 'well',
      pumpId: 'pump',
      farmId: 'farm',
      farmerAccountId: 'farmer',
      energySource: 'solar',
    );
    await ManualStopRequestStore(store).recordHumanStopRequest(
      accountId: 'account',
      wellId: 'well',
      sessionLocalId: root.localId,
      requestedAt: DateTime.now(),
    );
    await store.markNeedsReview(
      'account',
      root.localId,
      error: 'operational_start_review_required',
      attemptedAt: DateTime.now(),
    );
    await t.pumpWidget(
      MaterialApp(
        home: OperationsScreen(
          identity: testIdentity(
            accountId: 'account',
            wells: [
              testWell(id: 'well', roles: ['operator']),
            ],
          ),
          coordinator: coordinator,
          repository: EmptyFieldOperations(),
          priceRepository: EmptyFieldPrices(),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('متوقف محليًا'), findsWidgets);
    expect(find.text('إصلاح الحالة'), findsOneWidget);
    await t.tap(find.text('إصلاح الحالة'));
    await t.pumpAndSettle();
    expect(
      find.text(
        'سنراجع حالة الجلسة على الخادم. لن يتم إنشاء جلسة جديدة أثناء التحقق.',
      ),
      findsOneWidget,
    );
    expect(await store.allCommands('account'), hasLength(1));
    await t.pumpWidget(const SizedBox());
    coordinator.dispose();
  });
}

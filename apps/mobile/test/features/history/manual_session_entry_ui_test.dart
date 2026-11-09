import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/api/manual_session_entry_capability.dart';
import 'package:well_irrigation_mobile/features/history/session_history_screen.dart';
import 'package:well_irrigation_mobile/features/history/manual_session_entry_screen.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/manual_session_entry.dart';

import '../../core/sync/manual_session_entry_test.dart' as f;
import '../../support/identity_fixture.dart';

class EntryRepository extends OperationsRepository {
  bool completed = true, active = true, failCapability = false;
  int historyReads = 0;
  Completer<void>? capabilityGate;
  @override
  Future<ManualSessionEntryCapability> fetchManualSessionEntryCapability({
    required String accountId,
    required String wellId,
  }) async {
    await capabilityGate?.future;
    if (failCapability) {
      throw const ManualSessionEntryCapabilityUnavailable(
        ManualSessionEntryCapabilityFailure.network,
      );
    }
    return ManualSessionEntryCapability.fromContract({
      'contract': 'manual_session_entry_capability',
      'version': 1,
      'well_id': wellId,
      'can_record_historical_session': completed,
      'can_adopt_external_session': active,
    }, wellId: wellId);
  }

  @override
  Future<List<SessionHistoryItem>> fetchSessionHistory({
    required String wellId,
    String? farmerAccountId,
    String? filter,
  }) async {
    historyReads++;
    return [];
  }

  @override
  Future<List<FarmerAccount>> fetchFarmers(
    String wellId, {
    String? query,
  }) async => const [
    FarmerAccount(id: f.farmer, fullName: 'المزارع الأول', publicCode: ''),
    FarmerAccount(id: f.farm, fullName: 'المزارع الثاني', publicCode: ''),
  ];
  @override
  Future<FarmSearchPage> searchFarmPage(
    String wellId, {
    required String farmerAccountId,
    String query = '',
    int limit = 50,
    Map<String, Object?>? after,
  }) async => FarmSearchPage(
    await searchFarms(
      wellId,
      farmerAccountId: farmerAccountId,
      query: query,
      limit: limit,
    ),
    null,
  );
  @override
  Future<List<Farm>> searchFarms(
    String wellId, {
    required String farmerAccountId,
    String query = '',
    int limit = 50,
  }) async => [
    Farm(
      id: f.farm,
      wellId: wellId,
      farmerAccountId: farmerAccountId,
      name: 'أرض المزارع',
    ),
  ];
  @override
  Future<List<Pump>> fetchPumps(String wellId) async => [
    Pump(id: f.pump, wellId: wellId, name: 'المضخة الرئيسية', publicCode: ''),
  ];
}

class UiTransport
    implements CommandTransport, ManualSessionEntryReceiptTransport {
  String outcome = 'accepted';
  final writes = <DispatchRequest>[];
  @override
  Future<DispatchResult> dispatch(DispatchRequest r) async {
    writes.add(r);
    if (outcome == 'ambiguous' ||
        outcome == 'processing' ||
        outcome == 'not_found' ||
        outcome == 'unresolved') {
      throw StateError('private network failure SQLSTATE');
    }
    final request = r.arguments['p_request'] as Map;
    return DispatchAccepted(
      entityId: null,
      response: {
        'contract': 'manual_session_entry',
        'version': 1,
        'status': outcome,
        'well_id': r.arguments['p_well_id'],
        'command_id': r.commandId,
        'entry_type': r.type == CommandType.recordHistoricalSession
            ? 'manual_historical_completed'
            : 'manual_external_active',
        if (outcome == 'accepted') ...{
          'tenant_id': f.account,
          'session_id': f.session,
          'started_at': request['started_at'],
          'ended_at': request['ended_at'],
          'session_charge_id': r.type == CommandType.recordHistoricalSession
              ? f.farm
              : null,
          'amount_minor': r.type == CommandType.recordHistoricalSession
              ? 500
              : null,
        },
      },
    );
  }

  @override
  Future<ManualSessionEntryRead> readManualSessionEntryReceipt(
    ManualSessionEntryReceiptRequest r,
  ) async => parseManualSessionEntryReceipt(r, {
    'contract': 'get_manual_session_entry_receipt',
    'version': 1,
    'well_id': r.command.wellId,
    'command_id': r.command.commandId,
    'retry_authorized': false,
    'status': outcome == 'ambiguous' ? 'processing' : outcome,
    'result': null,
  });
}

Future<void> select(WidgetTester tester, Finder field, String text) async {
  await reveal(tester, field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

Future<void> pickTime(WidgetTester tester, String field, String hour) async {
  final target = find.byKey(ValueKey(field));
  await reveal(tester, target);
  await tester.tap(target);
  await tester.pumpAndSettle();
  await tester.enterText(
    find
        .descendant(
          of: find.byType(DatePickerDialog),
          matching: find.byType(TextField),
        )
        .first,
    '1/1/2001',
  );
  await tester.tap(find.text('اختيار'));
  await tester.pumpAndSettle();
  final inputs = find.descendant(
    of: find.byType(TimePickerDialog),
    matching: find.byType(TextField),
  );
  await tester.enterText(inputs.at(0), hour);
  await tester.enterText(inputs.at(1), '00');
  await tester.tap(find.text('اختيار'));
  await tester.pumpAndSettle();
}

Future<void> fill(WidgetTester tester, {bool completed = true}) async {
  if (!completed && find.text('جلسة ما زالت جارية').evaluate().isNotEmpty) {
    await tester.tap(find.text('جلسة ما زالت جارية'));
    await tester.pumpAndSettle();
  }
  await select(tester, find.byKey(const ValueKey('farmer')), 'المزارع الأول');
  await select(
    tester,
    find.byKey(const ValueKey('farm-${f.farmer}')),
    'أرض المزارع',
  );
  await select(tester, find.byKey(const ValueKey('pump')), 'المضخة الرئيسية');
  await pickTime(tester, 'startedAt', '5');
  if (completed) await pickTime(tester, 'endedAt', '6');
  await select(tester, find.byKey(const ValueKey('energy')), 'طاقة شمسية');
  await reveal(tester, find.byKey(const ValueKey('reason')));
  await tester.enterText(
    find.byKey(const ValueKey('reason')),
    'تسجيل عمل سابق',
  );
  tester.testTextInput.hide();
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      180,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder);
}

void main() {
  late InMemoryOutboxStore store;
  late OutboxRepository outbox;
  late OfflineSessionCoordinator coordinator;
  late EntryRepository repo;
  var openedOperations = 0;
  void reset({UiTransport? transport}) {
    store = InMemoryOutboxStore();
    outbox = OutboxRepository(store: store);
    coordinator = OfflineSessionCoordinator(
      store: store,
      commandTransport: transport,
    );
    repo = EntryRepository();
    openedOperations = 0;
  }

  Future<void> history(WidgetTester tester, {bool settle = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: SessionHistoryScreen(
            identity: testIdentity(
              accountId: f.account,
              wells: [testWell(id: f.well)],
            ),
            repository: repo,
            coordinator: coordinator,
            manualOutbox: outbox,
            onOpenOperations: () {
              openedOperations++;
              coordinator.freshProjectActiveSession(
                accountId: f.account,
                wellId: f.well,
              );
            },
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester) async {
    await history(tester);
    await tester.tap(find.text('إضافة جلسة سقي سابقة'));
    await tester.pumpAndSettle();
  }

  void uiTest(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (tester) async {
        try {
          await body(tester);
        } finally {
          coordinator.dispose();
          await tester.pumpWidget(const SizedBox.shrink());
        }
      });
  setUp(reset);
  tearDown(() => coordinator.dispose());
  uiTest('server capability exposes manual entry from history', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: SessionHistoryScreen(
            identity: testIdentity(),
            repository: EntryRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('إضافة جلسة سقي سابقة'), findsOneWidget);
  });
  uiTest('saved requests keep history usable on a small screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (var i = 0; i < 6; i++) {
      await f.enqueue(store, true);
    }
    await history(tester);
    expect(tester.takeException(), isNull);
  });
  for (final flags in [
    (true, true),
    (true, false),
    (false, true),
    (false, false),
  ]) {
    uiTest('independent entry and mode permissions $flags', (tester) async {
      repo.completed = flags.$1;
      repo.active = flags.$2;
      await history(tester);
      if (!flags.$1 && !flags.$2) {
        expect(find.text('إضافة جلسة سقي سابقة'), findsNothing);
        return;
      }
      await tester.tap(find.text('إضافة جلسة سقي سابقة'));
      await tester.pumpAndSettle();
      expect(find.byType(ManualSessionEntryScreen), findsOneWidget);
      expect(
        find.text('جلسة منتهية'),
        flags.$1 ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('جلسة ما زالت جارية'),
        flags.$2 ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const ValueKey('endedAt')),
        flags.$1 ? findsOneWidget : findsNothing,
      );
    });
  }
  uiTest('capability unavailable stays distinct and read retry works', (
    tester,
  ) async {
    repo.failCapability = true;
    await history(tester);
    expect(find.text('تعذر التحقق من إمكانية إضافة جلسة.'), findsOneWidget);
    expect(find.text('إضافة جلسة سقي سابقة'), findsNothing);
    repo.failCapability = false;
    await tester.tap(find.text('إعادة التحقق من الإضافة'));
    await tester.pumpAndSettle();
    expect(find.text('إضافة جلسة سقي سابقة'), findsOneWidget);
  });
  uiTest('capability loading does not become denial', (tester) async {
    repo.capabilityGate = Completer<void>();
    await history(tester, settle: false);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('تعذر التحقق من إمكانية إضافة جلسة.'), findsNothing);
    expect(find.text('إضافة جلسة سقي سابقة'), findsNothing);
    repo.capabilityGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('إضافة جلسة سقي سابقة'), findsOneWidget);
  });
  uiTest('existing saved intent is offered before creating a different entry', (
    tester,
  ) async {
    final c = await f.enqueue(store, false);
    await history(tester);
    await tester.tap(find.text('إضافة جلسة سقي سابقة'));
    await tester.pumpAndSettle();
    expect(find.text('لديك طلب إضافة محفوظ'), findsOneWidget);
    await tester.tap(find.text('متابعة الطلب المحفوظ'));
    await tester.pumpAndSettle();
    expect(find.text('حفظ الجلسة'), findsNothing);
    expect((await store.allCommands(f.account)).single.commandId, c.commandId);
  });
  uiTest('changing farmer clears the previously selected land', (tester) async {
    await open(tester);
    await select(tester, find.byKey(const ValueKey('farmer')), 'المزارع الأول');
    await select(
      tester,
      find.byKey(const ValueKey('farm-${f.farmer}')),
      'أرض المزارع',
    );
    await tester.drag(find.byType(ListView).last, const Offset(0, 800));
    await tester.pumpAndSettle();
    await select(
      tester,
      find.byKey(const ValueKey('farmer')),
      'المزارع الثاني',
    );
    final field = tester.widget<TextFormField>(
      find.byKey(const ValueKey('farm-${f.farm}')),
    );
    expect(field.controller!.text, isEmpty);
  });
  uiTest('small RTL form scrolls with large text and keeps fields accessible', (
    tester,
  ) async {
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final cap = await repo.fetchManualSessionEntryCapability(
      accountId: f.account,
      wellId: f.well,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: ManualSessionEntryScreen(
            identity: testIdentity(
              accountId: f.account,
              wells: [testWell(id: f.well)],
            ),
            capability: cap,
            repository: repo,
            coordinator: coordinator,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('notes')));
    expect(
      Directionality.of(tester.element(find.byKey(const ValueKey('notes')))),
      TextDirection.rtl,
    );
    expect(tester.takeException(), isNull);
  });
  uiTest('switching modes hides end and validation preserves reason', (
    tester,
  ) async {
    await open(tester);
    await reveal(tester, find.byKey(const ValueKey('reason')));
    await tester.enterText(find.byKey(const ValueKey('reason')), '   ');
    await reveal(tester, find.text('حفظ الجلسة'));
    await tester.tap(find.text('حفظ الجلسة'));
    await tester.pump();
    expect(find.text('اكتب سبب إضافة الجلسة لاحقًا'), findsOneWidget);
    expect((await store.allCommands(f.account)), isEmpty);
    await tester.drag(find.byType(ListView).last, const Offset(0, 1400));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('جلسة ما زالت جارية'));
    await tester.tap(find.text('جلسة ما زالت جارية'));
    await tester.pump();
    expect(find.byKey(const ValueKey('endedAt')), findsNothing);
  });
  uiTest('reason and notes stay visible after scrolling away and validating', (
    tester,
  ) async {
    await open(tester);
    await reveal(tester, find.byKey(const ValueKey('reason')));
    await tester.enterText(find.byKey(const ValueKey('reason')), 'سبب محفوظ');
    await reveal(tester, find.byKey(const ValueKey('notes')));
    await tester.enterText(
      find.byKey(const ValueKey('notes')),
      'ملاحظات محفوظة',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.drag(find.byType(ListView).last, const Offset(0, 1800));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('حفظ الجلسة'));
    await tester.tap(find.text('حفظ الجلسة'));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('reason')));
    expect(find.text('سبب محفوظ'), findsOneWidget);
    await reveal(tester, find.byKey(const ValueKey('notes')));
    expect(find.text('ملاحظات محفوظة'), findsOneWidget);
    expect(await store.allCommands(f.account), isEmpty);
  });
  for (final completed in [true, false]) {
    uiTest(
      '${completed ? 'completed' : 'active'} durable offline handoff and double tap',
      (tester) async {
        await open(tester);
        await fill(tester, completed: completed);
        await reveal(tester, find.text('حفظ الجلسة'));
        await tester.tap(find.text('حفظ الجلسة'));
        await tester.tap(find.text('حفظ الجلسة'));
        await tester.pumpAndSettle();
        final rows = await store.allCommands(f.account);
        expect(rows, hasLength(1));
        expect(
          rows.single.type,
          completed
              ? CommandType.recordHistoricalSession
              : CommandType.adoptExternalSession,
        );
        expect(
          rows.single.payload.keys,
          unorderedEquals(['p_well_id', 'p_request']),
        );
        expect(
          find.text(
            'تم حفظ الجلسة على الجهاز، وسيتم إكمال إضافتها عند توفر الاتصال.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('العودة للسجل'));
        await tester.pumpAndSettle();
        expect(find.text('متابعة الطلب'), findsOneWidget);
        await tester.ensureVisible(
          find.widgetWithText(TextButton, 'متابعة الطلب'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('متابعة الطلب'));
        await tester.pumpAndSettle();
        expect(find.byType(ManualSessionEntryScreen), findsOneWidget);
        expect(find.text('حفظ الجلسة'), findsNothing);
        expect(
          (await store.allCommands(f.account)).single.commandId,
          rows.single.commandId,
        );
      },
    );
  }
  for (final completed in [true, false]) {
    uiTest(
      '${completed ? 'completed' : 'active'} canonical accepted navigation',
      (tester) async {
        coordinator.dispose();
        final transport = UiTransport();
        reset(transport: transport);
        await open(tester);
        await fill(tester, completed: completed);
        await reveal(tester, find.text('حفظ الجلسة'));
        await tester.tap(find.text('حفظ الجلسة'));
        await tester.pumpAndSettle();
        if (find.text('تحديث الحالة').evaluate().isNotEmpty) {
          await tester.tap(find.text('تحديث الحالة'));
          await tester.pumpAndSettle();
        }
        expect(transport.writes, hasLength(1));
        expect(find.byType(ManualSessionEntryScreen), findsNothing);
        if (completed) {
          expect(repo.historyReads, greaterThan(1));
          expect(find.text('تمت إضافة الجلسة بنجاح.'), findsOneWidget);
          expect(find.text('لا توجد جلسات مطابقة'), findsOneWidget);
        } else {
          expect(openedOperations, 1);
          expect(coordinator.currentActiveSession!.serverSessionId, f.session);
        }
      },
    );
  }
  for (final status in [
    'conflict_overlap',
    'conflict_active_resource',
    'validation_error',
    'needs_review',
    'processing',
    'not_found',
    'unresolved',
    'ambiguous',
  ]) {
    uiTest('$status maps to safe Arabic without a second command', (
      tester,
    ) async {
      coordinator.dispose();
      final transport = UiTransport()..outcome = status;
      reset(transport: transport);
      await open(tester);
      await fill(tester, completed: false);
      await reveal(tester, find.text('حفظ الجلسة'));
      await tester.tap(find.text('حفظ الجلسة'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تحديث الحالة'));
      await tester.pumpAndSettle();
      expect(transport.writes, hasLength(1));
      expect(await store.allCommands(f.account), hasLength(1));
      expect(find.text('حفظ الجلسة'), findsNothing);
      expect(find.textContaining('SQLSTATE'), findsNothing);
      expect(find.textContaining('not_found'), findsNothing);
      if (status == 'conflict_overlap') {
        expect(find.textContaining('راجع وقت البداية'), findsOneWidget);
      }
      if (status == 'conflict_active_resource') {
        expect(find.textContaining('أنهِ الجلسة الحالية'), findsOneWidget);
      }
      if (status == 'validation_error') {
        final ordinary = OfflineSessionCoordinator(store: store);
        try {
          expect(
            (await ordinary.startSession(
              accountId: f.account,
              wellId: f.well,
              pumpId: f.pump,
              farmId: f.farm,
              farmerAccountId: f.farmer,
              energySource: 'solar',
            )).type,
            CommandType.startOperationalSession,
          );
        } finally {
          ordinary.dispose();
        }
      }
    });
  }
}

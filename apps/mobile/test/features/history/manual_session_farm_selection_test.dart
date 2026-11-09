import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/manual_session_entry.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/sync_engine.dart';
import 'package:well_irrigation_mobile/features/history/manual_session_entry_screen.dart';

import '../../core/sync/manual_session_entry_test.dart' as f;
import '../../support/identity_fixture.dart';
import 'manual_session_entry_ui_test.dart' as ui;

String farmId(int i) =>
    '70000000-0000-4000-8000-${i.toString().padLeft(12, '0')}';

class PagedFarms extends ui.EntryRepository {
  final reads = <(String, String, String, int)>[];
  Completer<FarmSearchPage>? delayedA;
  final pendingQueries = <String, Completer<FarmSearchPage>>{};
  bool wrongScope = false;
  bool missingFarmer = false;
  @override
  Future<List<FarmerAccount>> fetchFarmers(
    String wellId, {
    String? query,
  }) async => (await super.fetchFarmers(
    wellId,
    query: query,
  )).where((f1) => !missingFarmer || f1.id != f.farmer).toList();
  bool fail = false, missing = false;
  @override
  Future<FarmSearchPage> searchFarmPage(
    String wellId, {
    required String farmerAccountId,
    String query = '',
    int limit = 50,
    Map<String, Object?>? after,
  }) async {
    final page = after?['page'] as int? ?? 0;
    reads.add((wellId, farmerAccountId, query, page));
    if (fail) throw StateError('private RPC failure');
    if (missingFarmer && farmerAccountId == f.farmer) {
      throw StateError('unavailable original farmer');
    }
    if (pendingQueries.containsKey(query)) return pendingQueries[query]!.future;
    if (wrongScope) {
      return FarmSearchPage([
        Farm(
          id: farmId(100),
          wellId: f.pump,
          farmerAccountId: f.farm,
          name: 'أرض غير مخولة',
        ),
      ], null);
    }
    if (delayedA != null && farmerAccountId == f.farmer) {
      return delayedA!.future;
    }
    final items = List.generate(
      51,
      (i) => Farm(
        id: farmId(i),
        wellId: wellId,
        farmerAccountId: farmerAccountId,
        name: i == 50 ? 'الأرض البعيدة' : 'أرض $i',
      ),
    );
    final matches = items.where((x) => x.displayName.contains(query)).toList();
    if (missing) return const FarmSearchPage([], null);
    final start = page * 50;
    final result = matches.skip(start).take(50).toList();
    if (page == 1 && query.isEmpty) {
      result.insert(
        0,
        items[49],
      ); // overlapping pages must not duplicate an item
    }
    return FarmSearchPage(
      result,
      matches.length > start + 50 ? {'page': page + 1} : null,
    );
  }

  @override
  Future<List<Farm>> searchFarms(
    String wellId, {
    required String farmerAccountId,
    String query = '',
    int limit = 50,
  }) async => (await searchFarmPage(
    wellId,
    farmerAccountId: farmerAccountId,
    query: query,
    limit: limit,
  )).items;
}

void main() {
  late InMemoryOutboxStore store;
  late OfflineSessionCoordinator coordinator;
  late PagedFarms repo;
  setUp(() {
    store = InMemoryOutboxStore();
    coordinator = OfflineSessionCoordinator(store: store);
    repo = PagedFarms();
  });
  void check(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (t) async {
        try {
          await body(t);
        } finally {
          coordinator.dispose();
          await t.pumpWidget(const SizedBox.shrink());
        }
      });
  Future<void> open(
    WidgetTester t, {
    bool completed = true,
    bool correction = false,
    double scale = 1,
  }) async {
    final cap = await repo.fetchManualSessionEntryCapability(
      accountId: f.account,
      wellId: f.well,
    );
    final identity = testIdentity(
      accountId: f.account,
      wells: [testWell(id: f.well)],
    );
    final facts = ManualSessionEntryFacts(
      wellId: f.well,
      farmerWellAccountId: f.farmer,
      farmId: farmId(50),
      pumpId: f.pump,
      startedAt: f.start,
      endedAt: completed ? f.end : null,
      energySource: 'solar',
      reason: 'سبب محفوظ',
      notes: 'تفاصيل محفوظة',
    );
    final outbox = OutboxRepository(store: store);
    final c = correction
        ? await outbox.prepareManualSessionEntry(
            accountId: f.account,
            facts: facts,
          )
        : null;
    if (c != null) {
      await outbox.saveManualSessionEntry(c);
      await SyncEngine(
        store: store,
        transport: ui.UiTransport()..outcome = 'validation_error',
      ).run(f.account);
    }
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ManualSessionEntryScreen(
          identity: identity,
          capability: cap,
          repository: repo,
          coordinator: coordinator,
          existingCommand: c,
        ),
      ),
    );
    await t.pumpAndSettle();
    if (correction) {
      await t.tap(find.text('تصحيح البيانات'));
      await t.pumpAndSettle();
    } else {
      if (!completed) {
        await t.tap(find.text('جلسة ما زالت جارية'));
        await t.pump();
      }
      await ui.select(t, find.byKey(const ValueKey('farmer')), 'المزارع الأول');
    }
  }

  Future<void> picker(WidgetTester t) async {
    final field = find.byKey(const ValueKey('farm-${f.farmer}'));
    await ui.reveal(t, field);
    await t.tap(field);
    await t.pumpAndSettle();
  }

  for (final completed in [true, false]) {
    check('$completed correction restores canonical farm beyond first 50', (
      t,
    ) async {
      await open(t, completed: completed, correction: true);
      expect(find.text('الأرض البعيدة'), findsOneWidget);
      expect(repo.reads.any((r) => r.$4 == 1), isTrue);
      expect(find.textContaining(farmId(50)), findsNothing);
    });
    check(
      '$completed new entry searches outside first page and persists exact farm',
      (t) async {
        await open(t, completed: completed);
        await picker(t);
        final search = find.byKey(const ValueKey('manual-farm-search'));
        expect(search, findsOneWidget);
        await t.enterText(search, 'الأرض البعيدة');
        await t.pump(const Duration(milliseconds: 350));
        await t.pumpAndSettle();
        await t.tap(find.byKey(ValueKey('farm-result-${farmId(50)}')));
        await t.pumpAndSettle();
        await ui.select(
          t,
          find.byKey(const ValueKey('pump')),
          'المضخة الرئيسية',
        );
        await ui.pickTime(t, 'startedAt', '5');
        if (completed) await ui.pickTime(t, 'endedAt', '6');
        await ui.select(t, find.byKey(const ValueKey('energy')), 'طاقة شمسية');
        await ui.reveal(t, find.byKey(const ValueKey('reason')));
        await t.enterText(find.byKey(const ValueKey('reason')), 'إضافة سابقة');
        final save = find.widgetWithText(FilledButton, 'حفظ الجلسة');
        await ui.reveal(t, save);
        await t.pumpAndSettle();
        await t.tap(save);
        await t.pumpAndSettle();
        final c = (await store.allCommands(f.account)).single;
        expect((c.payload['p_request'] as Map)['farm_id'], farmId(50));
        expect(
          repo.reads.every((r) => r.$1 == f.well && r.$2 == f.farmer),
          isTrue,
        );
        expect(find.textContaining(farmId(50)), findsNothing);
      },
    );
  }
  check('load more appends scoped deduplicated results and selects page two', (
    t,
  ) async {
    await open(t);
    await picker(t);
    expect(find.text('تحميل المزيد'), findsOneWidget);
    await t.tap(find.text('تحميل المزيد'));
    await t.pumpAndSettle();
    final target = find.text('الأرض البعيدة');
    await t.scrollUntilVisible(
      target,
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await t.pumpAndSettle();
    expect(find.text('أرض 49'), findsOneWidget);
    await t.tap(target);
    await t.pumpAndSettle();
    expect(find.text('الأرض البعيدة'), findsOneWidget);
    await picker(t);
    await t.tap(find.byTooltip('إغلاق'));
    await t.pumpAndSettle();
    expect(find.text('الأرض البعيدة'), findsOneWidget);
    expect(repo.reads.where((r) => r.$4 == 1), hasLength(1));
  });
  check('old farmer response cannot populate new farmer picker', (t) async {
    await open(t);
    repo.delayedA = Completer<FarmSearchPage>();
    final field = find.byKey(const ValueKey('farm-${f.farmer}'));
    await t.tap(field);
    await t.pump();
    // Complete the modal's entrance animation while the read remains unresolved.
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byTooltip('إغلاق'));
    await t.pumpAndSettle();
    await ui.select(t, find.byKey(const ValueKey('farmer')), 'المزارع الثاني');
    await t.tap(find.byKey(const ValueKey('farm-${f.farm}')));
    await t.pumpAndSettle();
    repo.delayedA!.complete(
      FarmSearchPage([
        Farm(
          id: farmId(99),
          wellId: f.well,
          farmerAccountId: f.farmer,
          name: 'نتيجة المزارع السابق',
        ),
      ], null),
    );
    await t.pumpAndSettle();
    expect(find.text('نتيجة المزارع السابق'), findsNothing);
    expect(repo.reads.last.$2, f.farm);
    expect(t.takeException(), isNull);
  });
  check('farm search remains usable with keyboard and scaled Arabic', (
    t,
  ) async {
    t.view.physicalSize = const Size(320, 568);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetViewInsets);
    await open(t, scale: 1.5);
    await picker(t);
    t.view.viewInsets = const FakeViewPadding(bottom: 300);
    await t.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('manual-farm-search')).hitTestable(),
      findsOneWidget,
    );
    expect(t.takeException(), isNull);
  });
  check('older query response cannot overwrite a newer search', (t) async {
    await open(t);
    await picker(t);
    repo.pendingQueries['بحث سابق'] = Completer<FarmSearchPage>();
    final search = find.byKey(const ValueKey('manual-farm-search'));
    await t.enterText(search, 'بحث سابق');
    await t.pump(const Duration(milliseconds: 350));
    await t.enterText(search, 'الأرض البعيدة');
    await t.pump(const Duration(milliseconds: 350));
    await t.pumpAndSettle();
    repo.pendingQueries['بحث سابق']!.complete(
      FarmSearchPage([
        Farm(
          id: farmId(99),
          wellId: f.well,
          farmerAccountId: f.farmer,
          name: 'نتيجة بحث قديمة',
        ),
      ], null),
    );
    await t.pumpAndSettle();
    expect(find.text('نتيجة بحث قديمة'), findsNothing);
    expect(find.byKey(ValueKey('farm-result-${farmId(50)}')), findsOneWidget);
    expect(repo.reads.where((r) => r.$3 == 'الأرض البعيدة'), hasLength(1));
  });
  check('page failure retains loaded items and retries the same cursor', (
    t,
  ) async {
    await open(t);
    await picker(t);
    repo.fail = true;
    await t.tap(find.text('تحميل المزيد'));
    await t.pumpAndSettle();
    expect(find.text('أرض 0'), findsOneWidget);
    expect(find.text('لا توجد أراضٍ مطابقة'), findsNothing);
    repo.fail = false;
    await t.tap(find.text('إعادة المحاولة'));
    await t.pumpAndSettle();
    expect(repo.reads.where((r) => r.$4 == 0), hasLength(1));
    expect(repo.reads.where((r) => r.$4 == 1), hasLength(2));
    expect(find.text('تحميل المزيد'), findsNothing);
  });
  check('well change never accepts the old pending farm results', (t) async {
    await open(t);
    repo.delayedA = Completer<FarmSearchPage>();
    await t.tap(find.byKey(const ValueKey('farm-${f.farmer}')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    final cap = await repo.fetchManualSessionEntryCapability(
      accountId: f.account,
      wellId: f.pump,
    );
    await t.pumpWidget(
      MaterialApp(
        home: ManualSessionEntryScreen(
          identity: testIdentity(
            accountId: f.account,
            wells: [testWell(id: f.pump)],
          ),
          capability: cap,
          repository: repo,
          coordinator: coordinator,
        ),
      ),
    );
    repo.delayedA!.complete(
      FarmSearchPage([
        Farm(
          id: farmId(99),
          wellId: f.well,
          farmerAccountId: f.farmer,
          name: 'نتيجة البئر السابق',
        ),
      ], null),
    );
    await t.pumpAndSettle();
    expect(find.text('نتيجة البئر السابق'), findsNothing);
    expect(await store.allCommands(f.account), isEmpty);
    expect(t.takeException(), isNull);
  });
  check('wrong-scope farm response is a failure rather than an option', (
    t,
  ) async {
    await open(t);
    repo.wrongScope = true;
    await picker(t);
    expect(find.text('أرض غير مخولة'), findsNothing);
    expect(find.textContaining('تعذر تحميل الأراضي'), findsOneWidget);
  });
  check('unavailable original farmer still permits choosing a current farmer', (
    t,
  ) async {
    repo.missingFarmer = true;
    await open(t, correction: true);
    expect(find.textContaining('المزارع السابق'), findsOneWidget);
    expect(find.textContaining('تعذر تحميل خيارات الجلسة'), findsNothing);
    expect(repo.reads, isEmpty);
    await ui.select(t, find.byKey(const ValueKey('farmer')), 'المزارع الثاني');
    await t.tap(find.byKey(const ValueKey('farm-${f.farm}')));
    await t.pumpAndSettle();
    expect(repo.reads.single.$2, f.farm);
  });
  check('failed prefill read does not claim the original farm disappeared', (
    t,
  ) async {
    repo.fail = true;
    await open(t, correction: true);
    expect(find.textContaining('تعذر تحميل خيارات الجلسة'), findsOneWidget);
    expect(find.textContaining('الأرض السابقة'), findsNothing);
    repo.fail = false;
    await t.tap(find.text('إعادة المحاولة'));
    await t.pumpAndSettle();
    expect(find.text('الأرض البعيدة'), findsOneWidget);
  });
  check(
    'missing original farm asks for a new selection without fabricating it',
    (t) async {
      repo.missing = true;
      await open(t, correction: true);
      expect(find.textContaining('الأرض السابقة'), findsOneWidget);
      expect(find.text('الأرض البعيدة'), findsNothing);
    },
  );
  check('read failure differs from successful empty search', (t) async {
    await open(t);
    repo.fail = true;
    await picker(t);
    expect(find.textContaining('تعذر تحميل الأراضي'), findsOneWidget);
    expect(find.text('لا توجد أراضٍ مطابقة'), findsNothing);
    repo.fail = false;
    await t.tap(find.text('إعادة المحاولة'));
    await t.pumpAndSettle();
    await t.enterText(
      find.byKey(const ValueKey('manual-farm-search')),
      'اسم غير موجود',
    );
    await t.pump(const Duration(milliseconds: 350));
    await t.pumpAndSettle();
    expect(find.text('لا توجد أراضٍ مطابقة'), findsOneWidget);
  });
}

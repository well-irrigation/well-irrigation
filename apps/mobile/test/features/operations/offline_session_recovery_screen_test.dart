import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/offline_session_recovery_screen.dart';

void main() {
  late InMemoryOutboxStore store;
  late OfflineSessionCoordinator coordinator;
  LocalAuthAccount? account;

  setUp(() async {
    store = InMemoryOutboxStore();
    coordinator = OfflineSessionCoordinator(store: store);
    await coordinator.initialize();
    account = const LocalAuthAccount('account-a', isExpired: false);
  });

  tearDown(() => coordinator.dispose());

  Future<String> start({String well = 'well-a'}) async {
    final command = await coordinator.startSession(
      accountId: 'account-a',
      wellId: well,
      pumpId: 'pump-a',
      farmId: 'farm-a',
      farmerAccountId: 'farmer-a',
      energySource: 'solar',
      startedAt: DateTime.now().subtract(const Duration(minutes: 2)),
    );
    return command.localId;
  }

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: OfflineSessionRecoveryScreen(
          accountId: 'account-a',
          sessions: await coordinator.unresolvedSessions('account-a'),
          coordinator: coordinator,
          localAuthAccount: () => account,
          onRetry: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('paused session permits resume after confirmation once', (
    tester,
  ) async {
    final localId = await start();
    await coordinator.pauseSession(
      accountId: 'account-a',
      sessionLocalId: localId,
      reason: 'operator_pause',
    );
    await show(tester);
    expect(find.textContaining('توقف مؤقت'), findsWidgets);
    await tester.tap(find.text('استئناف'));
    await tester.pumpAndSettle();
    expect((await store.allCommands('account-a')), hasLength(2));
    await tester.tap(find.text('تأكيد الاستئناف').last);
    await tester.pumpAndSettle();
    final rows = await store.allCommands('account-a');
    expect(rows, hasLength(3));
    expect(rows.last.type, CommandType.resumeIrrigationSession);
    expect(rows.last.aggregateLocalId, localId);
  });

  testWidgets('running session pauses only after confirmation', (tester) async {
    final localId = await start();
    await show(tester);
    await tester.tap(find.text('إيقاف مؤقت'));
    await tester.pumpAndSettle();
    expect((await store.allCommands('account-a')), hasLength(1));
    await tester.tap(find.text('تأكيد الإيقاف'));
    await tester.pumpAndSettle();
    final rows = await store.allCommands('account-a');
    expect(rows, hasLength(2));
    expect(rows.last.type, CommandType.pauseIrrigationSession);
    expect(rows.last.aggregateLocalId, localId);
  });

  testWidgets('complete writes once and becomes read only without payment', (
    tester,
  ) async {
    await start();
    await show(tester);
    await tester.tap(find.text('إنهاء الجلسة'));
    await tester.pumpAndSettle();
    expect((await store.allCommands('account-a')), hasLength(1));
    await tester.tap(find.text('تأكيد الإنهاء'));
    await tester.pumpAndSettle();
    final rows = await store.allCommands('account-a');
    expect(rows, hasLength(2));
    expect(rows.last.type, CommandType.completeIrrigationSession);
    expect(find.text('إنهاء الجلسة'), findsNothing);
    expect(find.text('تسجيل دفعة'), findsNothing);
    expect(find.text('بدء جلسة سقي جديدة'), findsNothing);
  });

  testWidgets('completed and conflict chains expose no action buttons', (
    tester,
  ) async {
    final localId = await start();
    await coordinator.completeSession(
      accountId: 'account-a',
      sessionLocalId: localId,
    );
    await show(tester);
    expect(find.text('إنهاء الجلسة'), findsNothing);
    expect(find.text('استئناف'), findsNothing);
    expect(find.text('إيقاف مؤقت'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    final other = await start(well: 'well-b');
    await store.markNeedsReview(
      'account-a',
      other,
      error: 'permission denied',
      attemptedAt: DateTime.now(),
    );
    await show(tester);
    await tester.tap(find.text('جلسة 2'));
    await tester.pumpAndSettle();
    expect(
      find.text('تحتاج الجلسة مراجعة — السجل المحلي محفوظ'),
      findsOneWidget,
    );
  });

  testWidgets('two sessions require explicit local choice', (tester) async {
    await start(well: 'well-a');
    await start(well: 'well-b');
    await show(tester);
    expect(find.text('إيقاف مؤقت'), findsNothing);
    expect(find.text('جلسة 1'), findsOneWidget);
    expect(find.text('جلسة 2'), findsOneWidget);
    await tester.tap(find.text('جلسة 2'));
    await tester.pumpAndSettle();
    expect(find.text('إيقاف مؤقت'), findsOneWidget);
  });

  testWidgets('a newly discovered second chain resets automatic selection', (
    tester,
  ) async {
    await start(well: 'well-a');
    await show(tester);
    expect(find.text('إيقاف مؤقت'), findsOneWidget);
    await start(well: 'well-b');
    await show(tester);
    expect(find.text('إيقاف مؤقت'), findsNothing);
    expect(find.text('جلسة 1'), findsOneWidget);
    expect(find.text('جلسة 2'), findsOneWidget);
  });

  testWidgets('expired auth is read only and no normal navigation exists', (
    tester,
  ) async {
    account = const LocalAuthAccount('account-a', isExpired: true);
    await start();
    await show(tester);
    for (final label in [
      'إيقاف مؤقت',
      'استئناف',
      'إنهاء الجلسة',
      'تحويل مصدر الطاقة',
      'تسجيل دفعة',
      'بدء جلسة سقي جديدة',
      'الرئيسية',
      'إدارة الفريق',
    ]) {
      expect(find.text(label), findsNothing);
    }
  });
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/app/identity_gate.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/offline_session_recovery_screen.dart';

import '../support/identity_fixture.dart';

void main() {
  late InMemoryOutboxStore store;
  late OfflineSessionCoordinator coordinator;
  late StreamController<void> authEvents;
  LocalAuthAccount? account;

  setUp(() async {
    store = InMemoryOutboxStore();
    coordinator = OfflineSessionCoordinator(store: store);
    await coordinator.initialize();
    authEvents = StreamController<void>.broadcast();
    account = const LocalAuthAccount('account-a', isExpired: false);
  });

  tearDown(() async {
    await authEvents.close();
    coordinator.dispose();
  });

  Future<void> start({
    String owner = 'account-a',
    String well = 'well-a',
  }) async {
    await coordinator.startSession(
      accountId: owner,
      wellId: well,
      pumpId: 'pump-a',
      farmId: 'farm-a',
      farmerAccountId: 'farmer-a',
      energySource: 'solar',
      startedAt: DateTime.now().subtract(const Duration(minutes: 3)),
    );
  }

  Widget gate(Future<BootstrapData> Function() bootstrap) => MaterialApp(
    home: IdentityGate(
      loadBootstrap: bootstrap,
      recoveryCoordinator: coordinator,
      localAuthAccount: () => account,
      authChanges: authEvents.stream,
      builder: (_, identity, _) =>
          Scaffold(body: Text('حقيقي: ${identity.accountId}')),
    ),
  );

  Future<BootstrapData> disconnected() async => throw const SocketException(
    'ClientException: Failed host lookup: https://example.supabase.co/',
  );

  testWidgets('successful bootstrap uses the real normal identity', (
    tester,
  ) async {
    await start();
    await tester.pumpWidget(
      gate(
        () async => BootstrapData(
          profile: testProfile(id: 'account-a'),
          wells: [testWell(id: 'well-a')],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('حقيقي: account-a'), findsOneWidget);
    expect(find.byType(OfflineSessionRecoveryScreen), findsNothing);
  });

  testWidgets('network without local chain stays sanitized unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(gate(disconnected));
    await tester.pumpAndSettle();
    expect(find.text('تعذر تحميل بيانات حسابك'), findsOneWidget);
    expect(find.byType(OfflineSessionRecoveryScreen), findsNothing);
    expect(find.textContaining('ClientException'), findsNothing);
    expect(find.textContaining('example.supabase.co'), findsNothing);
    expect(find.textContaining('https://'), findsNothing);
  });

  testWidgets(
    'field-shaped auth refresh failure opens expired read-only recovery',
    (tester) async {
      await start();
      account = const LocalAuthAccount('account-a', isExpired: true);
      final error = AuthRetryableFetchException(
        message:
            'ClientException with SocketException: Failed host lookup: '
            'example.supabase.co, uri=https://example.supabase.co/auth/v1/token',
      );
      await tester.pumpWidget(gate(() async => throw error));
      await tester.pumpAndSettle();
      expect(find.byType(OfflineSessionRecoveryScreen), findsOneWidget);
      expect(find.text('وضع استعادة محلي'), findsOneWidget);
      expect(find.textContaining('للقراءة فقط'), findsOneWidget);
      for (final action in [
        'إيقاف مؤقت',
        'استئناف',
        'إنهاء الجلسة',
        'تحويل مصدر الطاقة',
        'تسجيل دفعة',
        'بدء جلسة سقي جديدة',
      ]) {
        expect(find.text(action), findsNothing);
      }
      for (final sensitive in [
        'AuthRetryableFetchException',
        'ClientException',
        'example.supabase.co',
        'https://',
      ]) {
        expect(find.textContaining(sensitive), findsNothing);
      }
    },
  );

  testWidgets('field-shaped wrapper without local chain stays sanitized', (
    tester,
  ) async {
    final error = AuthRetryableFetchException(
      message:
          'ClientException with SocketException: Failed host lookup: '
          'example.supabase.co, uri=https://example.supabase.co/auth/v1/token',
    );
    await tester.pumpWidget(gate(() async => throw error));
    await tester.pumpAndSettle();
    expect(find.byType(OfflineSessionRecoveryScreen), findsNothing);
    expect(
      find.text(
        'تعذر الاتصال بالخادم. تحقق من اتصال الإنترنت ثم أعد المحاولة.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('example.supabase.co'), findsNothing);
  });

  testWidgets('field-shaped wrapper cannot expose another account chain', (
    tester,
  ) async {
    await start(owner: 'account-b');
    final error = AuthRetryableFetchException(
      message:
          'ClientException with SocketException: Failed host lookup: '
          'example.supabase.co',
    );
    await tester.pumpWidget(gate(() async => throw error));
    await tester.pumpAndSettle();
    expect(find.byType(OfflineSessionRecoveryScreen), findsNothing);
    expect(
      find.text(
        'تعذر الاتصال بالخادم. تحقق من اتصال الإنترنت ثم أعد المحاولة.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('retryable 5xx wrapper cannot open local recovery', (
    tester,
  ) async {
    await start();
    final error = AuthRetryableFetchException(
      message: 'ClientException with SocketException: Failed host lookup:',
      statusCode: '503',
    );
    await tester.pumpWidget(gate(() async => throw error));
    await tester.pumpAndSettle();
    expect(find.byType(OfflineSessionRecoveryScreen), findsNothing);
    expect(
      find.text('تعذر التحقق من بيانات حسابك. أعد المحاولة.'),
      findsOneWidget,
    );
  });

  testWidgets('matching local running chain opens restricted recovery', (
    tester,
  ) async {
    await start();
    await tester.pumpWidget(gate(disconnected));
    await tester.pumpAndSettle();
    expect(find.byType(OfflineSessionRecoveryScreen), findsOneWidget);
    expect(find.text('وضع استعادة محلي'), findsOneWidget);
    expect(find.text('إيقاف مؤقت'), findsOneWidget);
    expect(find.text('بدء جلسة سقي جديدة'), findsNothing);
    expect(find.text('تسجيل دفعة'), findsNothing);
    expect(find.textContaining('ClientException'), findsNothing);
  });

  testWidgets('other account and absent auth cannot view local chain', (
    tester,
  ) async {
    await start(owner: 'account-b');
    await tester.pumpWidget(gate(disconnected));
    await tester.pumpAndSettle();
    expect(find.byType(OfflineSessionRecoveryScreen), findsNothing);
    account = null;
    await tester.pumpWidget(gate(disconnected));
    await tester.pumpAndSettle();
    expect(find.byType(OfflineSessionRecoveryScreen), findsNothing);
  });

  testWidgets('unknown and authorization failures fail closed', (tester) async {
    await start();
    for (final error in [
      StateError('unknown'),
      const FormatException('bad payload'),
    ]) {
      await tester.pumpWidget(gate(() async => throw error));
      await tester.pumpAndSettle();
      expect(find.byType(OfflineSessionRecoveryScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('expired account sees recovery without write controls', (
    tester,
  ) async {
    account = const LocalAuthAccount('account-a', isExpired: true);
    await start();
    await tester.pumpWidget(gate(disconnected));
    await tester.pumpAndSettle();
    expect(find.byType(OfflineSessionRecoveryScreen), findsOneWidget);
    expect(find.text('إيقاف مؤقت'), findsNothing);
    expect(find.text('إنهاء الجلسة'), findsNothing);
    expect(find.text('تحويل مصدر الطاقة'), findsNothing);
  });

  testWidgets('auth switch invalidates visible A recovery immediately', (
    tester,
  ) async {
    await start();
    await tester.pumpWidget(gate(disconnected));
    await tester.pumpAndSettle();
    account = const LocalAuthAccount('account-b', isExpired: false);
    authEvents.add(null);
    await tester.pumpAndSettle();
    expect(find.byType(OfflineSessionRecoveryScreen), findsNothing);
  });

  testWidgets('retry success exits recovery into real identity', (
    tester,
  ) async {
    await start();
    var attempts = 0;
    await tester.pumpWidget(
      gate(() async {
        attempts++;
        if (attempts == 1) return disconnected();
        return BootstrapData(
          profile: testProfile(id: 'account-a'),
          wells: [testWell(id: 'well-a')],
        );
      }),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('إعادة التحقق'));
    await tester.pumpAndSettle();
    expect(find.text('حقيقي: account-a'), findsOneWidget);
    expect(find.byType(OfflineSessionRecoveryScreen), findsNothing);
  });
}

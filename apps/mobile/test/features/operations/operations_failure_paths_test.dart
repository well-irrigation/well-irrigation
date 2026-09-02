import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';

/// منسّق يفشل في كتابتَي الإيقاف والإنهاء فقط، ويترك البدء والاستعادة سليمين،
/// ليُقاس ما تعرضه الشاشة عندما لا تُسجَّل الكتابة أصلًا.
class _FailingWriteCoordinator extends OfflineSessionCoordinator {
  _FailingWriteCoordinator({super.store});

  @override
  Future<CommandEnvelope> pauseSession({
    required String accountId,
    required String sessionLocalId,
    required String reason,
    DateTime? pausedAt,
  }) async {
    throw StateError('outbox unavailable');
  }

  @override
  Future<CommandEnvelope> completeSession({
    required String accountId,
    required String sessionLocalId,
    DateTime? completedAt,
  }) async {
    throw StateError('outbox unavailable');
  }
}

/// مسارات الفشل الصريح في شاشة التشغيل (ق-113 / م-41B3B / م-41D4).
///
/// كانت كل كتابات الجلسة تُبتلع في مصيدة استثناء فارغة ثم تُغيَّر الحالة على
/// الشاشة، فيرى المشغّل إيقافًا أو إنهاءً لم يُسجَّل في أي مكان.
void main() {
  group('OperationsScreen — الفشل يُعرض ولا تُغيَّر الحالة', () {
    const well = WellSummary(
      id: 'well-1',
      tenantId: 'tenant-1',
      name: 'بئر الخير الرئيسي',
      status: 'active',
      roles: ['owner', 'operator'],
    );

    late _FailingWriteCoordinator coordinator;

    setUp(() async {
      coordinator = _FailingWriteCoordinator(store: InMemoryOutboxStore());
      await coordinator.initialize();
      // جلسة جارية فعلية في الطابور: البدء والاستعادة يعملان بلا تلفيق.
      await coordinator.startSession(
        accountId: OfflineSessionCoordinator.placeholderAccountKey,
        wellId: 'well-1',
        pumpId: 'pump-1',
        farmId: 'farm-1',
        farmerAccountId: 'farmer-1',
        energySource: 'طاقة شمسية',
        startedAt: DateTime.now().subtract(const Duration(minutes: 15)),
      );
    });

    tearDown(() {
      coordinator.dispose();
    });

    Future<void> pumpScreen(WidgetTester tester, {String? wellId}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: OperationsScreen(
            wellName: 'بئر الخير الرئيسي',
            wellId: wellId ?? 'well-1',
            wells: const [well],
            coordinator: coordinator,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('1. فشل الإيقاف المؤقت يُعلن والجلسة تبقى معروضة جارية',
        (tester) async {
      await pumpScreen(tester);
      expect(find.text('جلسة سقي جارية الآن'), findsOneWidget);

      final pauseFinder = find.text('إيقاف مؤقت');
      await tester.ensureVisible(pauseFinder);
      await tester.tap(pauseFinder);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('تعذر الإيقاف المؤقت — الجلسة ما زالت جارية'),
        findsOneWidget,
      );
      // الزر لم ينقلب إلى «استئناف السقي»: الحالة تتبع ما سُجِّل.
      expect(find.text('إيقاف مؤقت'), findsOneWidget);
      expect(find.text('استئناف السقي'), findsNothing);
    });

    testWidgets('2. فشل الإنهاء يُعلن ولا يُفتح سند قبض لجلسة لم تُنهَ',
        (tester) async {
      await pumpScreen(tester);

      final endFinder = find.text('إنهاء واحتساب');
      await tester.ensureVisible(endFinder);
      await tester.tap(endFinder);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('تعذر إنهاء الجلسة — لم يُسجَّل شيء ولا سند'),
        findsOneWidget,
      );
      expect(find.text('اعتماد الجلسة وسند السداد'), findsNothing);
      expect(find.text('جلسة سقي جارية الآن'), findsOneWidget);
    });

    testWidgets('3. بئر نشط خارج آبار المستخدم لا يُلفَّق في الشريط العلوي',
        (tester) async {
      await pumpScreen(tester, wellId: 'well-outside');

      // كان الشريط يبني `WellSummary` بمستأجر وأدوار مُفترضة، فيظهر البئر
      // كأنه مملوك للمستخدم.
      expect(find.text('لا بئر مختار'), findsOneWidget);
    });
  });
}

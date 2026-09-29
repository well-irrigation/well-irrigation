/// اختبارات ملكية الاتصالات ودورة حياة مخزن SQLite — ق-129.
///
/// تغطي:
/// 1. عزل اتصال العامل (singleInstance: false) عن المقدمة (singleInstance: true).
/// 2. إعادة إنتاج فشل إغلاق الاتصال المشترك والتعافي منه.
/// 3. الشفاء الذاتي للمخزن (self-healing) بعد الإغلاق.
/// 4. إعادة التحقق والشفاء في منسق الجلسات (OfflineSessionCoordinator).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tempDir;
  late String dbPath;
  final storesToClose = <SqliteOutboxStore>[];
  final coordinatorsToDispose = <OfflineSessionCoordinator>[];

  CommandEnvelope makeEnvelope({
    required String localId,
    required String commandId,
    required String accountId,
    int sequence = 1,
    CommandType type = CommandType.createFarmer,
    String? aggregateLocalId,
  }) {
    final now = DateTime.utc(2026, 9, 18, 10);
    final payload = switch (type) {
      CommandType.createFarmer => {
        'p_well_id': 'well-1',
        'p_full_name': 'مزارع تجريبي',
      },
      CommandType.startIrrigationSession => {
        'p_well_id': 'well-1',
        'p_pump_id': 'pump-1',
        'p_farm_id': 'farm-1',
        'p_farmer_well_account_id': 'farmer-1',
        'p_energy_source': 'solar',
      },
      CommandType.completeIrrigationSession => {
        'p_session_id': {'type': 'local', 'local_id': aggregateLocalId ?? 'start-1'},
      },
      _ => {'p_well_id': 'well-1'},
    };
    return CommandEnvelope(
      localId: localId,
      commandId: commandId,
      type: type,
      accountId: accountId,
      wellId: 'well-1',
      aggregateLocalId: aggregateLocalId,
      sequence: sequence,
      occurredAt: now,
      createdLocalAt: now,
      payload: payload,
      status: CommandStatus.pending,
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sqlite_lifecycle_test');
    dbPath = p.join(tempDir.path, 'outbox.db');
  });

  tearDown(() async {
    for (final coordinator in coordinatorsToDispose) {
      coordinator.dispose();
    }
    coordinatorsToDispose.clear();

    for (final store in storesToClose) {
      await store.close();
    }
    storesToClose.clear();

    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('SqliteOutboxStore Lifecycle & Connection Ownership (Q-129)', () {
    test(
      '1. عزل اتصال العامل: إغلاق اتصال العامل (singleInstance: false) لا يؤثر على اتصال المقدمة',
      () async {
        // اتصال المقدمة الافتراضي: singleInstance = true
        final storeForeground = SqliteOutboxStore(
          databasePath: dbPath,
          singleInstance: true,
          sqfliteFactory: databaseFactoryFfi,
        );
        storesToClose.add(storeForeground);
        await storeForeground.initialize();

        expect(storeForeground.singleInstance, isTrue);
        expect(storeForeground.isOpen, isTrue);

        // كتابة أولية من المقدمة
        await storeForeground.insert(
          makeEnvelope(
            localId: 'fg-1',
            commandId: 'cmd-fg-1',
            accountId: 'owner-1',
            sequence: 1,
          ),
        );

        // اتصال العامل الخلفي المستقل: singleInstance = false
        final storeWorker = SqliteOutboxStore(
          databasePath: dbPath,
          singleInstance: false,
          sqfliteFactory: databaseFactoryFfi,
        );
        storesToClose.add(storeWorker);
        await storeWorker.initialize();

        expect(storeWorker.singleInstance, isFalse);
        expect(storeWorker.isOpen, isTrue);

        // العامل يقرأ ويكتب
        final workerCommands = await storeWorker.allCommands('owner-1');
        expect(workerCommands.length, 1);
        expect(workerCommands.first.localId, 'fg-1');

        await storeWorker.insert(
          makeEnvelope(
            localId: 'wrk-1',
            commandId: 'cmd-wrk-1',
            accountId: 'owner-1',
            sequence: 2,
          ),
        );

        // محاكاة finally { await store?.close(); } في العامل الخلفي
        await storeWorker.close();
        expect(storeWorker.isOpen, isFalse);

        // التحقق الحاسم: اتصال المقدمة لا يزال مفتوحاً وصالحاً تماماً
        expect(storeForeground.isOpen, isTrue);
        final fgCommands = await storeForeground.allCommands('owner-1');
        expect(fgCommands.length, 2);

        // المقدمة تستطيع الإدخال بعد إغلاق العامل بنجاح وبلا database_closed
        await storeForeground.insert(
          makeEnvelope(
            localId: 'fg-2',
            commandId: 'cmd-fg-2',
            accountId: 'owner-1',
            sequence: 3,
            type: CommandType.completeIrrigationSession,
          ),
        );

        final updated = await storeForeground.allCommands('owner-1');
        expect(updated.length, 3);
      },
    );

    test(
      '2. إعادة إنتاج سلوك الاتصال المشترك القديم: إغلاق اتصال مشترك يبطل الآخر، والشفاء الذاتي يعيد فتحه',
      () async {
        // اتصالان بنفس الإعداد القديم (singleInstance = true) على نفس الملف
        final storeA = SqliteOutboxStore(
          databasePath: dbPath,
          singleInstance: true,
          sqfliteFactory: databaseFactoryFfi,
        );
        storesToClose.add(storeA);
        await storeA.initialize();

        final storeB = SqliteOutboxStore(
          databasePath: dbPath,
          singleInstance: true,
          sqfliteFactory: databaseFactoryFfi,
        );
        storesToClose.add(storeB);
        await storeB.initialize();

        await storeA.insert(
          makeEnvelope(
            localId: 'init-1',
            commandId: 'cmd-init-1',
            accountId: 'owner-1',
          ),
        );

        // في وضع singleInstance: true، إغلاق B يغلق المقبض المشترك في sqflite
        await storeB.close();
        expect(storeB.isOpen, isFalse);

        // storeA أصبح مقبضه مغلقاً بسبب المشاركة
        expect(storeA.isOpen, isFalse);
        expect(
          () => storeA.allCommands('owner-1'),
          throwsA(isA<StateError>()),
        );

        // الشفاء الذاتي: إعادة استدعاء initialize() على storeA تعيد فتحه بأمان
        await storeA.initialize();
        expect(storeA.isOpen, isTrue);

        final rows = await storeA.allCommands('owner-1');
        expect(rows.length, 1);
        expect(rows.first.localId, 'init-1');
      },
    );

    test(
      '3. الشفاء الذاتي للمخزن: إغلاق المخزن واستدعاء initialize() يعيد فتحه للعمليات بنجاح',
      () async {
        final store = SqliteOutboxStore(
          databasePath: dbPath,
          sqfliteFactory: databaseFactoryFfi,
        );
        storesToClose.add(store);
        await store.initialize();
        expect(store.isOpen, isTrue);

        await store.insert(
          makeEnvelope(
            localId: 'cmd-1',
            commandId: 'c-1',
            accountId: 'acc-1',
          ),
        );

        // إغلاق علني للمخزن
        await store.close();
        expect(store.isOpen, isFalse);

        // أي محاولة قراءة دون initialize ترمي StateError صريحاً
        expect(
          () => store.allCommands('acc-1'),
          throwsA(isA<StateError>()),
        );

        // إعادة التهيئة تشفي المخزن وتفتحه من جديد
        await store.initialize();
        expect(store.isOpen, isTrue);

        final commands = await store.allCommands('acc-1');
        expect(commands.length, 1);
        expect(commands.first.localId, 'cmd-1');

        final nextSeq1 = await store.nextSequence('acc-1');
        expect(nextSeq1, 1);
        final nextSeq2 = await store.nextSequence('acc-1');
        expect(nextSeq2, 2);
      },
    );

    test(
      'التهيئة المتزامنة لـ SqliteOutboxStore محمية بحارس ولا تسبب فتحاً مكرراً',
      () async {
        final store = SqliteOutboxStore(
          databasePath: dbPath,
          sqfliteFactory: databaseFactoryFfi,
        );
        storesToClose.add(store);

        // استدعاءان متزامنان لـ initialize
        await Future.wait([
          store.initialize(),
          store.initialize(),
          store.initialize(),
        ]);

        expect(store.isOpen, isTrue);
        await store.insert(
          makeEnvelope(
            localId: 'c1',
            commandId: 'cmd1',
            accountId: 'acc1',
          ),
        );
        expect((await store.allCommands('acc1')).length, 1);
      },
    );
  });
}

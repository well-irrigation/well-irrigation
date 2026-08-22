/// عقد الأوامر: ما يُرسل بالضبط، ونصوص الحالة، وصحة المعرّفات.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_id_generator.dart';
import 'package:well_irrigation_mobile/core/sync/command_reference.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

void main() {
  CommandEnvelope envelope({
    CommandType type = CommandType.startIrrigationSession,
    Map<String, Object?>? payload,
  }) => CommandEnvelope(
    localId: 'local-1',
    commandId: 'command-1',
    type: type,
    accountId: 'account-a',
    sequence: 1,
    occurredAt: DateTime.utc(2026, 8, 22, 5),
    createdLocalAt: DateTime.utc(2026, 8, 22, 5, 1),
    payload: payload ?? const {'p_well_id': 'well-1'},
  );

  group('حماية الحمولة من مصدرين لنفس القيمة', () {
    test('ترفض تمرير معرّف العملية في الحمولة', () {
      expect(
        () => envelope(
          payload: const {'p_well_id': 'well-1', 'p_command_id': 'other'},
        ),
        throwsArgumentError,
      );
    });

    test('ترفض تمرير وقت الحدث في الحمولة', () {
      expect(
        () => envelope(
          payload: const {'p_well_id': 'well-1', 'p_started_at': 'now'},
        ),
        throwsArgumentError,
      );
    });

    test('ترفض حمولة بلا وسيط الجهة', () {
      expect(
        () => envelope(payload: const {'p_pump_id': 'pump-1'}),
        throwsArgumentError,
      );
    });
  });

  group('وسائط الاستدعاء النهائية', () {
    test('تضيف معرّف العملية ووقت الحدث ولا تلمس غيرهما', () {
      final command = envelope();
      final arguments = buildRpcArguments(
        type: command.type,
        commandId: command.commandId,
        occurredAt: command.occurredAt,
        resolvedPayload: command.payload,
      );

      expect(arguments[commandIdArgument], 'command-1');
      expect(arguments['p_started_at'], '2026-08-22T05:00:00.000Z');
      expect(arguments['p_well_id'], 'well-1');
      expect(arguments.keys, hasLength(3));
    });

    test('لا تضيف وقت حدث لأمر لا يحمل وسيط وقت', () {
      final command = envelope(
        type: CommandType.createFarmer,
        payload: const {'p_well_id': 'well-1', 'p_full_name': 'محمد'},
      );
      final arguments = buildRpcArguments(
        type: command.type,
        commandId: command.commandId,
        occurredAt: command.occurredAt,
        resolvedPayload: command.payload,
      );

      expect(arguments.containsKey('p_started_at'), isFalse);
      expect(arguments[commandIdArgument], 'command-1');
    });
  });

  group('توحيد ردّ الخادم', () {
    test('ردّ uuid مجرد يصير معرّف الكيان', () {
      final result = normalizeAcceptedResponse(
        CommandType.startIrrigationSession,
        'session-uuid',
      );

      expect(result.entityId, 'session-uuid');
      expect(result.response['id'], 'session-uuid');
      expect(result.matchedExisting, isFalse);
    });

    test('ردّ jsonb يُستخرج منه المفتاح الصحيح لكل دالة', () {
      expect(
        normalizeAcceptedResponse(CommandType.completeIrrigationSession, {
          'session_id': 'session-uuid',
          'total_minor': 125000,
        }).entityId,
        'session-uuid',
      );
      expect(
        normalizeAcceptedResponse(CommandType.recordPayment, {
          'payment_id': 'payment-uuid',
          'receipt': {'number': 12},
        }).entityId,
        'payment-uuid',
      );
      expect(
        normalizeAcceptedResponse(CommandType.createFarm, {
          'farm_id': 'farm-uuid',
        }).entityId,
        'farm-uuid',
      );
    });

    test('already_exists يُقرأ كمطابقة كيان قائم', () {
      final result = normalizeAcceptedResponse(CommandType.createFarmer, {
        'farmer_well_account_id': 'fwa-uuid',
        'already_exists': true,
      });

      expect(result.entityId, 'fwa-uuid');
      expect(result.matchedExisting, isTrue);
    });

    test('شكل غير متوقَّع يُرفض بلا تخمين', () {
      expect(
        () => normalizeAcceptedResponse(CommandType.recordPayment, 'uuid'),
        throwsFormatException,
      );
    });
  });

  group('عقد الأنواع الثمانية', () {
    test('كل نوع يعرف جهته ووسيطها', () {
      for (final type in CommandType.values) {
        expect(
          type.scopeArgument,
          type.scope == CommandScope.session ? 'p_session_id' : 'p_well_id',
          reason: type.rpcName,
        );
      }
    });

    test('كل ردّ jsonb له مفتاح، وكل ردّ uuid بلا مفتاح', () {
      for (final type in CommandType.values) {
        expect(
          type.resultKey != null,
          type.returnsJson,
          reason: type.rpcName,
        );
      }
    });

    test('أحداث الجلسة كلها تحمل وسيط وقت حدث', () {
      expect(CommandType.startIrrigationSession.eventTimeArgument, 'p_started_at');
      expect(CommandType.pauseIrrigationSession.eventTimeArgument, 'p_paused_at');
      expect(
        CommandType.resumeIrrigationSession.eventTimeArgument,
        'p_resumed_at',
      );
      expect(
        CommandType.changeSessionEnergySource.eventTimeArgument,
        'p_changed_at',
      );
      expect(
        CommandType.completeIrrigationSession.eventTimeArgument,
        'p_ended_at',
      );
      expect(CommandType.recordPayment.eventTimeArgument, 'p_paid_at');
    });

    test('الكيانات المُنتَجة أربعة فقط', () {
      final producers = {
        for (final type in CommandType.values)
          if (type.produces != null) type: type.produces!,
      };

      expect(producers, {
        CommandType.createFarmer: EntityKind.farmerWellAccount,
        CommandType.createFarm: EntityKind.farm,
        CommandType.startIrrigationSession: EntityKind.session,
        CommandType.recordPayment: EntityKind.payment,
      });
    });

    test('التخزين يحفظ النوع ويستعيده كما هو', () {
      for (final type in CommandType.values) {
        expect(CommandType.fromStorage(type.storageValue), type);
      }
      for (final kind in EntityKind.values) {
        expect(EntityKind.fromStorage(kind.storageValue), kind);
      }
      for (final status in CommandStatus.values) {
        expect(CommandStatus.fromStorage(status.storageValue), status);
      }
    });
  });

  group('نصوص الحالة المعروضة (ق-108)', () {
    test('كل حالة ونصّها', () {
      expect(syncStatusText(CommandStatus.pending), 'بانتظار المزامنة');
      expect(
        syncStatusText(CommandStatus.pending, attempted: true),
        'فشل وستتم إعادة المحاولة',
      );
      expect(syncStatusText(CommandStatus.dispatching), 'جارٍ الإرسال');
      expect(syncStatusText(CommandStatus.confirmed), 'تمت المزامنة');
      expect(syncStatusText(CommandStatus.review), 'يحتاج مراجعة');
      expect(SyncStatusText.localDurable, 'محفوظ على الجهاز');
    });

    test('محاولة فاشلة واحدة لا ترفع الحالة إلى حرجة قبل وقوعها', () {
      final fresh = envelope();

      expect(fresh.wasAttempted, isFalse);
      expect(fresh.statusText, 'بانتظار المزامنة');

      final retried = fresh.copyWith(retryCount: 1, lastError: 'شبكة');

      expect(retried.statusText, 'فشل وستتم إعادة المحاولة');
      expect(retried.commandId, fresh.commandId);
    });
  });

  group('المراجع', () {
    test('تُجمع من أي عمق في الحمولة', () {
      final reference = const CommandReference(
        localId: 'local-9',
        kind: EntityKind.farm,
      );
      final payload = {
        'p_well_id': 'well-1',
        'p_farm_id': reference.toJson(),
        'p_extra': {
          'nested': [
            reference.toJson(),
            const CommandReference(
              localId: 'local-8',
              kind: EntityKind.payment,
            ).toJson(),
          ],
        },
      };

      expect(collectReferences(payload), hasLength(2));
      expect(collectReferences(payload), contains(reference));
    });

    test('مرجع غير محسوم يمنع البناء بلا صمت', () {
      final payload = {
        'p_well_id': 'well-1',
        'p_farm_id': const CommandReference(
          localId: 'local-9',
          kind: EntityKind.farm,
        ).toJson(),
      };

      expect(
        () => resolveReferences(payload, (_) => null),
        throwsA(isA<UnresolvedReferenceException>()),
      );
    });

    test('المرجع نفسه بنوع مختلف ليس نفس المرجع', () {
      expect(
        const CommandReference(localId: 'x', kind: EntityKind.farm),
        isNot(const CommandReference(localId: 'x', kind: EntityKind.session)),
      );
      expect(
        const CommandReference(localId: 'x', kind: EntityKind.farm),
        const CommandReference(localId: 'x', kind: EntityKind.farm),
      );
    });
  });

  group('مولّد المعرّفات', () {
    test('يُنتج UUID نسخة رابعة صحيح الصيغة', () {
      final generator = SecureIdGenerator(Random(7));
      final pattern = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );

      for (var index = 0; index < 50; index += 1) {
        final id = generator.newId();

        expect(id, hasLength(36));
        expect(pattern.hasMatch(id), isTrue, reason: id);
      }
    });

    test('لا يتكرر', () {
      final generator = SecureIdGenerator();
      final ids = {for (var index = 0; index < 500; index += 1) generator.newId()};

      expect(ids, hasLength(500));
    });
  });
}

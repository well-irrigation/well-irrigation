/// عقد الأوامر: ما يُرسل بالضبط، ونصوص الحالة، وصحة المعرّفات.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_id_generator.dart';
import 'package:well_irrigation_mobile/core/sync/command_reference.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

void main() {
  _sessionCorrectionCommandContractTests();
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
      ) as DispatchAccepted;

      expect(result.entityId, 'session-uuid');
      expect(result.response['id'], 'session-uuid');
      expect(result.matchedExisting, isFalse);
    });

    test('ردّ jsonb يُستخرج منه المفتاح الصحيح لكل دالة', () {
      expect(
        (normalizeAcceptedResponse(CommandType.completeIrrigationSession, {
          'session_id': 'session-uuid',
          'session_charge_id': 'charge-uuid',
          'total_minor': 125000,
        }) as DispatchAccepted).entityId,
        'charge-uuid',
      );
      expect(
        (normalizeAcceptedResponse(CommandType.recordPayment, {
          'payment_id': 'payment-uuid',
          'receipt': {'number': 12},
        }) as DispatchAccepted).entityId,
        'payment-uuid',
      );
      expect(
        (normalizeAcceptedResponse(CommandType.createFarm, {
          'farm_id': 'farm-uuid',
        }) as DispatchAccepted).entityId,
        'farm-uuid',
      );
    });

    test('already_exists يُقرأ كمطابقة كيان قائم', () {
      final result = normalizeAcceptedResponse(CommandType.createFarmer, {
        'farmer_well_account_id': 'fwa-uuid',
        'already_exists': true,
      }) as DispatchAccepted;

      expect(result.entityId, 'fwa-uuid');
      expect(result.matchedExisting, isTrue);
    });

    test('شكل غير متوقَّع يُرفض بلا تخمين', () {
      expect(
        () => normalizeAcceptedResponse(CommandType.recordPayment, 'uuid'),
        throwsFormatException,
      );
    });

    test('ردّ conflict لـ requires_resolution يتحول إلى DispatchFailed(review) ولا يقبل بـ entityId=null', () {
      final conflictJson = {
        'status': 'requires_resolution',
        'conflict_type': 'duplicate_candidate',
        'message':
            'توجد أرض أخرى بنفس الاسم والمزارع وتتطلب تحديد الصفة المميزة',
        'candidate_farm_id': '00000000-0000-0000-0000-000000000001',
        'name': 'الكوثة',
        'distinguishing_label': null,
      };

      final result = normalizeAcceptedResponse(
        CommandType.createFarm,
        conflictJson,
      );

      expect(result, isA<DispatchFailed>());
      final failed = result as DispatchFailed;
      expect(failed.disposition, FailureDisposition.review);
      expect(failed.serverResponse, equals(conflictJson));
      expect(failed.code, 'duplicate_candidate');
      expect(failed.message, contains('تتطلب تحديد الصفة المميزة'));
      expect(result is DispatchAccepted, isFalse);
    });

    test('ردّ conflict لـ requires_disambiguation يتحول إلى DispatchFailed(review) بهيكل الخادم الأصلي', () {
      final disambiguateJson = {
        'status': 'requires_disambiguation',
        'conflict_type': 'missing_distinguishing_label',
        'message':
            'توجد أرض بنفس الاسم الأساسي ويجب توفير صفة مميزة لإنشاء أرض جديدة',
        'existing_farm_id': '00000000-0000-0000-0000-000000000001',
        'name': 'الكوثة',
      };

      final result = normalizeAcceptedResponse(
        CommandType.createFarm,
        disambiguateJson,
      );

      expect(result, isA<DispatchFailed>());
      final failed = result as DispatchFailed;
      expect(failed.disposition, FailureDisposition.review);
      expect(failed.serverResponse, equals(disambiguateJson));
      expect(failed.code, 'missing_distinguishing_label');
      expect(failed.message, contains('توجد أرض بنفس الاسم الأساسي'));
      expect(result is DispatchAccepted, isFalse);
    });

    test('ردّ خالٍ من المفتاح الإلزامي يتحول إلى DispatchFailed(review) ولا يقبل بـ entityId=null', () {
      final incompleteJson = {'status': 'something_unexpected', 'other': 123};

      final result = normalizeAcceptedResponse(
        CommandType.createFarm,
        incompleteJson,
      );

      expect(result, isA<DispatchFailed>());
      final failed = result as DispatchFailed;
      expect(failed.disposition, FailureDisposition.review);
      expect(failed.serverResponse, equals(incompleteJson));
      expect(result is DispatchAccepted, isFalse);
    });
  });

  group('عقد أنواع الأوامر', () {
    test('كل نوع يعرف جهته ووسيطها', () {
      for (final type in CommandType.values) {
        expect(
          type.scopeArgument,
          type == CommandType.startBookingSession
              ? 'p_booking_id'
              : type == CommandType.recordBookingTransitionDecision ||
                    type == CommandType.executePendingBookingStart
              ? 'p_chain_id'
              : type.scope == CommandScope.session
              ? 'p_session_id'
              : 'p_well_id',
          reason: type.rpcName,
        );
      }
    });

    test('عقود JSON تتطلب مفتاح كيان إلا العقود المعروفة بلا مفتاح نتيجة', () {
      const jsonWithoutResultKey = {
        CommandType.recordBookingTransitionDecision,
        CommandType.executePendingBookingStart,
        CommandType.endBookingTransitionChain,
        CommandType.correctIrrigationSession,
      };
      for (final type in jsonWithoutResultKey) {
        expect(type.returnsJson, isTrue, reason: type.rpcName);
        expect(type.resultKey, isNull, reason: type.rpcName);
      }
      for (final type in CommandType.values) {
        expect(
          type.resultKey != null,
          type.returnsJson && !jsonWithoutResultKey.contains(type),
          reason: type.rpcName,
        );
      }
    });

    test('أحداث الجلسة كلها تحمل وسيط وقت حدث', () {
      expect(
        CommandType.startIrrigationSession.eventTimeArgument,
        'p_started_at',
      );
      expect(CommandType.startAdhocSession.eventTimeArgument, 'p_started_at');
      expect(
        CommandType.pauseIrrigationSession.eventTimeArgument,
        'p_paused_at',
      );
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

    test('الكيانات المُنتَجة تشمل تكلفة الجلسة الناتجة من الإنهاء', () {
      final producers = {
        for (final type in CommandType.values)
          if (type.produces != null) type: type.produces!,
      };

      expect(producers, {
        CommandType.adoptExternalSession: EntityKind.session,
        CommandType.createBooking: EntityKind.booking,
        CommandType.createFarmer: EntityKind.farmerWellAccount,
        CommandType.createFarm: EntityKind.farm,
        CommandType.startOperationalSession: EntityKind.session,
        CommandType.startIrrigationSession: EntityKind.session,
        CommandType.startAdhocSession: EntityKind.session,
        CommandType.startBookingSession: EntityKind.session,
        CommandType.executePendingBookingStart: EntityKind.session,
        CommandType.recordPayment: EntityKind.payment,
        CommandType.completeIrrigationSession: EntityKind.sessionCharge,
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
      final ids = {
        for (var index = 0; index < 500; index += 1) generator.newId(),
      };

      expect(ids, hasLength(500));
    });
  });
}

void _sessionCorrectionCommandContractTests() {
  // Compile-safe RED: do not substitute a legacy command for the missing type.
  CommandType correctionType() {
    final matches = CommandType.values.where(
      (type) => type.name == 'correctIrrigationSession',
    );
    expect(
      matches,
      hasLength(1),
      reason: 'Missing CommandType.correctIrrigationSession',
    );
    return matches.single;
  }

  const payload = <String, Object?>{
    'p_session_id': '11111111-1111-4111-8111-111111111111',
    'p_base_revision': 3,
    // Intent creation owns trim; the envelope must not canonicalize all text.
    'p_reason': 'تصحيح وقت التشغيل الفعلي',
    'p_desired_started_at': '2026-11-06T05:30:00.000Z',
    'p_desired_ended_at': '2026-11-06T07:45:00.000Z',
  };
  CommandEnvelope command({Map<String, Object?> body = payload}) =>
      CommandEnvelope(
        localId: 'local-correction-1',
        commandId: 'cmd-correction-1',
        type: correctionType(),
        accountId: 'account-a',
        wellId: 'well-a',
        sequence: 1,
        occurredAt: DateTime.utc(2026, 11, 6, 8, 15),
        createdLocalAt: DateTime.utc(2026, 11, 6, 8, 16),
        payload: body,
      );
  Map<String, Object?> arguments(CommandEnvelope value) => buildRpcArguments(
    type: value.type,
    commandId: value.commandId,
    occurredAt: value.occurredAt,
    resolvedPayload: value.payload,
  );

  group('R6C-4A correction command contract only', () {
    test(
      'new type has session scope, requested time and no produced entity',
      () {
        final type = correctionType();
        expect(type.rpcName, 'correct_irrigation_session');
        expect(type.scope, CommandScope.session);
        expect(type.scopeArgument, 'p_session_id');
        expect(type.eventTimeArgument, 'p_requested_at');
        expect(type.returnsJson, isTrue);
        expect(type.resultKey, isNull);
        expect(type.produces, isNull);
      },
    );

    test('new storage value round-trips by stable name', () {
      final type = correctionType();
      expect(type.storageValue, 'correctIrrigationSession');
      expect(CommandType.fromStorage('correctIrrigationSession'), type);
    });

    test('legacy stored command names retain their original identities', () {
      const legacy = {
        'startIrrigationSession': CommandType.startIrrigationSession,
        'startOperationalSession': CommandType.startOperationalSession,
        'startAdhocSession': CommandType.startAdhocSession,
        'startBookingSession': CommandType.startBookingSession,
        'pauseIrrigationSession': CommandType.pauseIrrigationSession,
        'resumeIrrigationSession': CommandType.resumeIrrigationSession,
        'completeIrrigationSession': CommandType.completeIrrigationSession,
        'createBooking': CommandType.createBooking,
        'recordPayment': CommandType.recordPayment,
      };
      for (final entry in legacy.entries) {
        expect(entry.value.storageValue, entry.key);
        expect(CommandType.fromStorage(entry.key), entry.value);
      }
    });

    test(
      'existing server session needs no local root or unresolved reference',
      () {
        final value = command();
        expect(value.aggregateLocalId, isNull);
        expect(value.prerequisites, isEmpty);
        expect(value.references, isEmpty);
        expect(value.payload['p_session_id'], payload['p_session_id']);
        expect(arguments(value)['p_session_id'], payload['p_session_id']);
      },
    );

    for (final reserved in ['p_command_id', 'p_requested_at']) {
      test('envelope rejects payload ownership of $reserved', () {
        // Resolve first so absence fails as the type contract, not ArgumentError.
        correctionType();
        expect(
          () => command(body: {...payload, reserved: 'forged'}),
          throwsArgumentError,
        );
      });
    }

    test('full desired pair and captured nonnegative integer revision pass through unchanged', () {
      final value = command();
      final args = arguments(value);
      expect(args['p_base_revision'], isA<int>());
      expect(args['p_base_revision'], greaterThanOrEqualTo(0));
      expect(args['p_base_revision'], 3);
      expect(args['p_desired_started_at'], '2026-11-06T05:30:00.000Z');
      expect(args['p_desired_ended_at'], '2026-11-06T07:45:00.000Z');
      expect(args['p_reason'], '  تصحيح وقت التشغيل الفعلي  '.trim());
      expect(value.payload.containsKey('p_command_id'), isFalse);
      expect(value.payload.containsKey('p_requested_at'), isFalse);
    });

    test('repeated argument construction preserves envelope identity and frozen request', () {
      final value = command();
      final first = arguments(value);
      final second = arguments(value);
      expect(second, first);
      expect(first, {
        ...payload,
        'p_command_id': 'cmd-correction-1',
        'p_requested_at': '2026-11-06T08:15:00.000Z',
      });
      // Bookkeeping must not replace base revision or request time. This only
      // tests construction; it does not authorize dispatch/retry of correction.
      final bookkeeping = value.copyWith(retryCount: 5);
      expect(arguments(bookkeeping), first);
      expect(value.commandId, 'cmd-correction-1');
      expect(value.occurredAt, DateTime.utc(2026, 11, 6, 8, 15));
      expect(value.payload, payload);
    });

    test('final RPC keys contain no client actor or financial authority', () {
      final args = arguments(command());
      expect(args.keys.toSet(), {
        'p_session_id',
        'p_base_revision',
        'p_reason',
        'p_desired_started_at',
        'p_desired_ended_at',
        'p_command_id',
        'p_requested_at',
      });
      for (final forbidden in [
        'amount',
        'rate',
        'price',
        'charge',
        'financial_status',
        'p_actor_id',
        'user_id',
        'operator_id',
        'role',
        'permission',
        'operational_revision',
      ]) {
        expect(
          args.keys.where((key) => key.contains(forbidden)),
          isEmpty,
          reason: forbidden,
        );
      }
    });
    // DISPATCH_LANE_CLASSIFICATION_DEFERRED.
    // DEFERRED_TO_CORRECTION_DISPATCH_RED: stale_revision is business review,
    // not blind retry even though generic SQLSTATE 40001 is retryable.
    // After ambiguous dispatch, recover by sessionId + original commandId via
    // get_session_correction_receipt before considering any further write.
  });
}

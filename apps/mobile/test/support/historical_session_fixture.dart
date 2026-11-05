import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';

/// أوامر محفوظة من نسخ سابقة؛ لا تُنشأ عبر مسار التشغيل الحالي ولا تمنح
/// دليل فعل بشري ضمنيًا لاختبارات الاستعادة أو المنشأ غير المحسوم.
Future<CommandEnvelope> persistHistoricalStart({
  required OutboxStore store,
  required CommandType type,
  required String accountId,
  required String wellId,
  required DateTime startedAt,
  required Map<String, Object?> payload,
  Map<String, Object?> localContext = const {},
  String localId = 'historical-start',
  String commandId = 'historical-command',
}) async {
  if (!const {
    CommandType.startIrrigationSession,
    CommandType.startAdhocSession,
    CommandType.startBookingSession,
  }.contains(type)) {
    throw ArgumentError.value(type, 'type', 'ليس أمر بدء تاريخيًا');
  }
  await store.initialize();
  return store.insert(
    CommandEnvelope(
      localId: localId,
      commandId: commandId,
      accountId: accountId,
      wellId: wellId,
      type: type,
      sequence: await store.nextSequence(accountId),
      occurredAt: startedAt,
      createdLocalAt: startedAt,
      payload: payload,
      localContext: localContext,
    ),
  );
}

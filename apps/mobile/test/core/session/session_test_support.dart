/// أدوات مشتركة لاختبارات الجلسة الجارية.
///
/// تبني أوامر جلسة كما يبنيها المُدخِل الحقيقي: نفس أسماء الوسائط في
/// Migration 084، ونفس ربط الأصل بـ`aggregateLocalId`.
library;

import 'package:well_irrigation_mobile/core/session/active_session_projector.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';

const String sessionAccount = 'account-session';
const String sessionWell = 'well-0000-0000-0009';

/// 3600 ريال للساعة = ريال واحد للثانية بالضبط.
///
/// يجعل كل توقّع مالي في الاختبار مقروءًا: 100 ثانية ⟹ 100 ريال، فأي
/// فرق يدل على خطأ في المنطق لا على حساب يدوي خاطئ في التوقّع.
const int ratePerSecond = 3600;

PricingResolver pricingAt(DateTime from, {int rate = ratePerSecond}) =>
    PricingResolver([
      PricingSnapshot(hourlyRateMinor: rate, effectiveFrom: from),
    ]);

/// يبدأ جلسة ويُعيد أمر بدئها — وهو أصل كل أحداثها التالية.
Future<CommandEnvelope> startSession(
  OutboxRepository repository, {
  required DateTime at,
  String energySource = 'diesel',
  String well = sessionWell,
  String account = sessionAccount,
}) => repository.enqueue(
  accountId: account,
  type: CommandType.startIrrigationSession,
  wellId: well,
  occurredAt: at,
  payload: {
    'p_well_id': well,
    'p_pump_id': 'pump-0000-0009',
    'p_farm_id': 'farm-0000-0009',
    'p_farmer_well_account_id': 'fwa-0000-0009',
    'p_energy_source': energySource,
  },
);

Future<CommandEnvelope> sessionEvent(
  OutboxRepository repository, {
  required CommandEnvelope session,
  required CommandType type,
  required DateTime at,
  Map<String, Object?> extra = const {},
  String account = sessionAccount,
}) => repository.enqueue(
  accountId: account,
  type: type,
  wellId: session.wellId,
  aggregateLocalId: session.localId,
  occurredAt: at,
  payload: {'p_session_id': session.localId, ...extra},
);

Future<CommandEnvelope> pause(
  OutboxRepository repository, {
  required CommandEnvelope session,
  required DateTime at,
  String reason = 'عطل بالمضخة',
}) => sessionEvent(
  repository,
  session: session,
  type: CommandType.pauseIrrigationSession,
  at: at,
  extra: {'p_reason': reason},
);

Future<CommandEnvelope> resume(
  OutboxRepository repository, {
  required CommandEnvelope session,
  required DateTime at,
}) => sessionEvent(
  repository,
  session: session,
  type: CommandType.resumeIrrigationSession,
  at: at,
);

Future<CommandEnvelope> changeEnergy(
  OutboxRepository repository, {
  required CommandEnvelope session,
  required DateTime at,
  required String newSource,
}) => sessionEvent(
  repository,
  session: session,
  type: CommandType.changeSessionEnergySource,
  at: at,
  extra: {'p_new_source': newSource},
);

Future<CommandEnvelope> complete(
  OutboxRepository repository, {
  required CommandEnvelope session,
  required DateTime at,
}) => sessionEvent(
  repository,
  session: session,
  type: CommandType.completeIrrigationSession,
  at: at,
);

/// دفعة في سياق الجلسة: معرَّفة ببئر (ق-99) ومربوطة بأصل الجلسة (ق-92).
Future<CommandEnvelope> payInSession(
  OutboxRepository repository, {
  required CommandEnvelope session,
  required DateTime at,
  required int amountMinor,
  String account = sessionAccount,
}) => repository.enqueue(
  accountId: account,
  type: CommandType.recordPayment,
  wellId: session.wellId,
  aggregateLocalId: session.localId,
  occurredAt: at,
  payload: {
    'p_well_id': session.wellId,
    'p_farmer_well_account_id': 'fwa-0000-0009',
    'p_amount_minor': amountMinor,
    'p_method': 'cash',
  },
);

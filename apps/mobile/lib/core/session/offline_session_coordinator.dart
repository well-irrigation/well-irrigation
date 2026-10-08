// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/operations_repository.dart';
import '../api/booking_local_ledger.dart';
import '../api/booking_repository.dart';
import '../sync/command_envelope.dart';
import '../sync/command_reference.dart';
import '../sync/command_transport.dart';
import '../sync/command_type.dart';
import '../sync/entity_reference.dart';
import '../sync/farmer_identity_review.dart';
import '../sync/outbox_repository.dart';
import '../sync/outbox_store.dart';
import '../sync/sqlite_outbox_store.dart';
import '../sync/supabase_command_transport.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_status.dart';
import 'active_session_projector.dart';
import 'active_session_record.dart';
import 'session_crop_snapshot.dart';

/// منسق جلسات السقي والعمل دون اتصال والمزامنة المتينة (ق-89 / ق-90 / ق-114)
///
/// يربط:
/// - الطابور المتين المحلي (`OutboxRepository` / SQLite / In-Memory).
/// - مُسقط الجلسة الحية الخالص (`ActiveSessionProjector`).
/// - محرك المزامنة المرتب مع الخادم (`SyncEngine` / `SupabaseCommandTransport`).
class OfflineSessionCoordinator {
  OfflineSessionCoordinator({
    OutboxStore? store,
    SupabaseClient? supabaseClient,
    CommandTransport? commandTransport,
    PricingResolver? pricingResolver,
    Future<bool> Function(String accountId)? commandQueuedScheduler,
    BookingLocalLedger? bookingLedger,
  }) : _store = store ?? SqliteOutboxStore(),
       _commandQueuedScheduler = commandQueuedScheduler,
       // لا سعر افتراضي في العميل (م-41D6): اللقطات تُغذّى من
       // `api.get_active_price_schedule` عبر `updatePricing`. حتى تُغذّى،
       // كل مقطع محتسب «بانتظار المزامنة» ولا يُسعَّر بصفر (القرار 341).
       _pricingResolver = pricingResolver ?? const PricingResolver.none() {
    _bookingLedger =
        bookingLedger ??
        (_store is SqliteOutboxStore ? BookingLocalLedger(_store) : null);
    _outbox = OutboxRepository(store: _store);
    _projector = ActiveSessionProjector(
      store: _store,
      pricing: _pricingResolver,
    );
    final transport =
        commandTransport ??
        (supabaseClient == null
            ? null
            : SupabaseCommandTransport(supabaseClient));
    if (transport != null) {
      _syncEngine = SyncEngine(store: _store, transport: transport);
    }
  }

  static OfflineSessionCoordinator? _instance;
  static SupabaseClient? _foregroundSupabaseClient;

  /// يربط النسخة العامة بعميل التطبيق الحقيقي قبل أن تستخدمها الشاشات.
  static void configureForegroundSync(SupabaseClient client) {
    if (_instance != null) {
      throw StateError('يجب ربط مزامنة المقدمة قبل إنشاء المنسق العام');
    }
    _foregroundSupabaseClient = client;
  }

  static OfflineSessionCoordinator get instance => _instance ??=
      OfflineSessionCoordinator(supabaseClient: _foregroundSupabaseClient);

  final OutboxStore _store;
  BookingLocalLedger? _bookingLedger;
  ServerBookingSessionLink? _serverBookingSession;
  ServerBookingSessionLink? get serverBookingSession => _serverBookingSession;

  Future<ServerBookingSessionLink?> restoreServerBookingSession({
    required String accountId,
    required String wellId,
  }) async {
    _serverBookingSession = await _bookingLedger?.loadServerSession(
      accountId,
      wellId,
    );
    return _serverBookingSession;
  }

  Future<ServerBookingSessionLink?> reconcileServerBookingSession({
    required String accountId,
    required String wellId,
    required CurrentBookingSession? current,
  }) async {
    final ledger = _bookingLedger;
    if (ledger == null) throw StateError('لا يوجد تخزين متين لربط الجلسة');
    if (current == null) {
      final prior = await ledger.loadServerSession(accountId, wellId);
      if (prior != null) {
        throw StateError('جلسة الخادم غابت عن القراءة؛ تحتاج مراجعة');
      }
      _serverBookingSession = null;
      return null;
    }
    if (current.wellId != wellId ||
        current.bookingId == null ||
        current.status != 'open') {
      throw StateError('جلسة خادم غير قابلة للمصالحة');
    }
    final local = currentActiveSession;
    if (local != null &&
        local.wellId == wellId &&
        local.serverSessionId != current.sessionId) {
      throw StateError('جلسة الخادم تختلف عن الجلسة المحلية');
    }
    _serverBookingSession = await ledger.importServerSession(
      accountId: accountId,
      wellId: wellId,
      sessionId: current.sessionId,
      bookingId: current.bookingId!,
      startedAt: current.startedAt,
    );
    return _serverBookingSession;
  }

  late final OutboxRepository _outbox;
  late ActiveSessionProjector _projector;
  SyncEngine? _syncEngine;
  PricingResolver _pricingResolver;
  Future<bool> Function(String accountId)? _commandQueuedScheduler;

  /// يربط جدولة الخلفية بعمر التطبيق؛ لا يغير ملكية أو حالة أي أمر.
  void setCommandQueuedScheduler(
    Future<bool> Function(String accountId)? scheduler,
  ) {
    _commandQueuedScheduler = scheduler;
  }

  /// إحلال لقطات التسعير المقروءة من العقد محلّ ما قبلها.
  ///
  /// تُنادى من الشاشة بعد نجاح `api.get_active_price_schedule`، وبقائمة
  /// فارغة إن فشلت القراءة — فيعود المستحق «بانتظار المزامنة» بدل أن يبقى
  /// معروضًا بسعر لم يُعده العقد (م-41D6).
  void updatePricing(List<PricingSnapshot> snapshots) {
    _pricingResolver = PricingResolver(List.unmodifiable(snapshots));
    _projector = ActiveSessionProjector(
      store: _store,
      pricing: _pricingResolver,
    );
  }

  bool _initialized = false;
  Timer? _tickerTimer;
  final _sessionController = StreamController<ActiveSessionRecord?>.broadcast();

  Stream<ActiveSessionRecord?> get activeSessionStream =>
      _sessionController.stream;

  Future<void> initialize() async {
    if (_initialized) {
      await _outbox.initialize();
      return;
    }
    await _outbox.initialize();
    _initialized = true;

    // تشغيل مؤقت تحديث العداد اللحظي
    _tickerTimer?.cancel();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_sessionController.isClosed) {
        _sessionController.add(_currentProjectedSession);
      }
    });
  }

  ActiveSessionRecord? _currentProjectedSession;
  int _syncProjectionGeneration = 0;
  int _freshProjectionGeneration = 0;
  ActiveSessionRecord? get currentActiveSession => _currentProjectedSession;

  Future<List<ActiveSessionRecord>> unresolvedSessions(String accountId) async {
    await initialize();
    return _projector.unresolvedSessions(accountId, now: DateTime.now());
  }

  Future<ActiveSessionRecord?> unresolvedSession(
    String accountId,
    String startCommandLocalId,
  ) async {
    await initialize();
    return _projector.unresolvedSession(
      accountId,
      startCommandLocalId,
      now: DateTime.now(),
    );
  }

  /// استرجاع وإسقاط الجلسة النشطة الحالية لبئر معين
  Future<ActiveSessionRecord?> projectActiveSession({
    required String accountId,
    String? wellId,
  }) async {
    await initialize();

    final now = DateTime.now();
    final activeSessions = await _projector.activeSessions(accountId, now: now);

    if (activeSessions.isEmpty) {
      _currentProjectedSession = null;
      _sessionController.add(null);
      return null;
    }

    // طلب بئر محدد لا يجوز أن يسقط إلى جلسة بئر آخر.
    final candidates = wellId == null
        ? activeSessions
        : activeSessions.where((session) => session.wellId == wellId).toList();
    final match = candidates.length == 1 ? candidates.single : null;

    _currentProjectedSession = match;
    _sessionController.add(_currentProjectedSession);
    return _currentProjectedSession;
  }

  /// إسقاط جديد من المخزن المتين — لا نتيجة مخبَّأة.
  ///
  /// يقرأ `allCommands` و`mappings` من SQLite مباشرة ويحمي النتيجة بجيل
  /// تصاعدي: إسقاط أقدم لا يكتب على أحدث.
  ///
  /// يُستخدم عند دخول شاشة التشغيل أو العودة إليها لالتقاط تأكيدات
  /// أجراها WorkManager عبر اتصال SQLite مستقل.
  Future<ActiveSessionRecord?> freshProjectActiveSession({
    required String accountId,
    String? wellId,
  }) async {
    final generation = ++_freshProjectionGeneration;
    await initialize();

    final now = DateTime.now();
    final activeSessions = await _projector.activeSessions(accountId, now: now);

    if (generation != _freshProjectionGeneration) {
      return _currentProjectedSession;
    }

    if (activeSessions.isEmpty) {
      _currentProjectedSession = null;
      _sessionController.add(null);
      return null;
    }

    final candidates = wellId == null
        ? activeSessions
        : activeSessions.where((s) => s.wellId == wellId).toList();
    final match = candidates.length == 1 ? candidates.single : null;

    if (generation != _freshProjectionGeneration) {
      return _currentProjectedSession;
    }

    _currentProjectedSession = match;
    _sessionController.add(_currentProjectedSession);
    return _currentProjectedSession;
  }

  final Map<String, Future<FarmerAccount>> _inFlightFarmerEnqueues = {};
  final Map<String, Future<Farm>> _inFlightFarmEnqueues = {};

  /// استرجاع المزارعين المعلقين في الطابور المتين لبئر وحساب محددين (UX-Honesty / م-21).
  Future<List<FarmerAccount>> pendingFarmers({
    required String accountId,
    required String wellId,
  }) async {
    await initialize();
    final commands = await _store.pendingCommands(accountId);
    final list = <FarmerAccount>[];
    for (final cmd in commands) {
      if (cmd.type == CommandType.createFarmer &&
          cmd.wellId == wellId &&
          cmd.status != CommandStatus.confirmed &&
          cmd.status != CommandStatus.review) {
        final mapping = await _store.mapping(
          accountId,
          cmd.localId,
          EntityKind.farmerWellAccount,
        );
        if (mapping != null) continue;

        final name = cmd.payload['p_full_name'] as String? ?? '';
        final phone = cmd.payload['p_phone'] as String?;
        if (name.isNotEmpty) {
          list.add(
            FarmerAccount.pending(
              reference: CommandReference(
                localId: cmd.localId,
                kind: EntityKind.farmerWellAccount,
              ),
              fullName: name,
              phone: phone,
            ),
          );
        }
      }
    }
    return list;
  }

  /// استرجاع الأراضي المعلقة في الطابور المتين لبئر ومزارع محددين (UX-Honesty / م-21).
  Future<List<Farm>> pendingFarms({
    required String accountId,
    required String wellId,
    EntityReference? farmerReference,
  }) async {
    await initialize();
    final commands = await _store.pendingCommands(accountId);
    final list = <Farm>[];
    for (final cmd in commands) {
      if (cmd.type == CommandType.createFarm &&
          cmd.wellId == wellId &&
          cmd.status != CommandStatus.confirmed &&
          cmd.status != CommandStatus.review) {
        final mapping = await _store.mapping(
          accountId,
          cmd.localId,
          EntityKind.farm,
        );
        if (mapping != null) continue;

        final name = cmd.payload['p_name'] as String? ?? '';
        final label = cmd.payload['p_distinguishing_label'] as String?;
        final rawFarmerRef = cmd.payload['p_farmer_well_account_id'];

        final EntityReference farmFarmerRef;
        if (rawFarmerRef is Map && CommandReference.isReference(rawFarmerRef)) {
          farmFarmerRef = PendingLocalEntityReference(
            CommandReference.fromJson(rawFarmerRef as Map<Object?, Object?>),
          );
        } else if (rawFarmerRef is String) {
          farmFarmerRef = ServerEntityReference(rawFarmerRef);
        } else {
          farmFarmerRef = const ServerEntityReference('');
        }

        if (farmerReference != null) {
          var matches = (farmFarmerRef == farmerReference);
          if (!matches && farmFarmerRef.isPending && farmerReference.isServer) {
            final fMapping = await _store.mapping(
              accountId,
              farmFarmerRef.localReference!.localId,
              EntityKind.farmerWellAccount,
            );
            if (fMapping?.serverId == farmerReference.serverId) {
              matches = true;
            }
          }
          if (!matches) continue;
        }

        if (name.isNotEmpty) {
          list.add(
            Farm.pending(
              reference: CommandReference(
                localId: cmd.localId,
                kind: EntityKind.farm,
              ),
              wellId: wellId,
              name: name,
              distinguishingLabel: label,
              farmerReference: farmFarmerRef,
            ),
          );
        }
      }
    }
    return list;
  }

  /// إنشاء مزارع جديد وحفظه متينًا في الطابور المحلي أولًا (ق-89 / ق-114 / م-21).
  Future<FarmerAccount> enqueueFarmer({
    required String accountId,
    required String wellId,
    required String fullName,
    String? phone,
    String? notes,
    String? actionToken,
  }) async {
    final cleanName = fullName.trim();
    if (cleanName.isEmpty) {
      throw ArgumentError('اسم المزارع مطلوب');
    }

    if (actionToken != null && actionToken.isNotEmpty) {
      final key = '$accountId:$wellId:$actionToken';
      final inFlight = _inFlightFarmerEnqueues[key];
      if (inFlight != null) {
        return inFlight;
      }

      final future = _doEnqueueFarmer(
        accountId: accountId,
        wellId: wellId,
        fullName: cleanName,
        phone: phone,
        notes: notes,
      );
      _inFlightFarmerEnqueues[key] = future;
      try {
        return await future;
      } finally {
        _inFlightFarmerEnqueues.remove(key);
      }
    }

    return _doEnqueueFarmer(
      accountId: accountId,
      wellId: wellId,
      fullName: cleanName,
      phone: phone,
      notes: notes,
    );
  }

  Future<FarmerAccount> _doEnqueueFarmer({
    required String accountId,
    required String wellId,
    required String fullName,
    String? phone,
    String? notes,
  }) async {
    await initialize();

    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: wellId,
      type: CommandType.createFarmer,
      occurredAt: DateTime.now(),
      payload: {
        'p_well_id': wellId,
        'p_full_name': fullName,
        if (phone != null && phone.trim().isNotEmpty) 'p_phone': phone.trim(),
        if (notes != null && notes.trim().isNotEmpty) 'p_notes': notes.trim(),
      },
    );

    await _triggerSync(accountId, wellId: wellId);

    return FarmerAccount.pending(
      reference: CommandReference(
        localId: envelope.localId,
        kind: EntityKind.farmerWellAccount,
      ),
      fullName: fullName,
      phone: phone?.trim(),
    );
  }

  /// إنشاء أرض جديدة وحفظها متينًا في الطابور المحلي أولًا (ق-89 / ق-114 / م-21).
  Future<Farm> enqueueFarm({
    required String accountId,
    required String wellId,
    required String name,
    String? distinguishingLabel,
    required EntityReference farmerReference,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw ArgumentError('اسم الأرض مطلوب');
    }

    final cleanLabel = distinguishingLabel?.trim();
    final key =
        '$accountId:$wellId:${farmerReference.toPayload()}:$cleanName:$cleanLabel';
    final inFlight = _inFlightFarmEnqueues[key];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _doEnqueueFarm(
      accountId: accountId,
      wellId: wellId,
      name: cleanName,
      distinguishingLabel: cleanLabel,
      farmerReference: farmerReference,
    );
    _inFlightFarmEnqueues[key] = future;
    try {
      return await future;
    } finally {
      _inFlightFarmEnqueues.remove(key);
    }
  }

  Future<Farm> _doEnqueueFarm({
    required String accountId,
    required String wellId,
    required String name,
    String? distinguishingLabel,
    required EntityReference farmerReference,
  }) async {
    await initialize();

    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: wellId,
      type: CommandType.createFarm,
      occurredAt: DateTime.now(),
      payload: {
        'p_well_id': wellId,
        'p_name': name,
        'p_farmer_well_account_id': farmerReference.toPayload(),
        if (distinguishingLabel != null && distinguishingLabel.isNotEmpty)
          'p_distinguishing_label': distinguishingLabel,
      },
    );

    await _triggerSync(accountId, wellId: wellId);

    return Farm.pending(
      reference: CommandReference(
        localId: envelope.localId,
        kind: EntityKind.farm,
      ),
      wellId: wellId,
      name: name,
      distinguishingLabel: distinguishingLabel,
      farmerReference: farmerReference,
    );
  }

  /// استرجاع مزارع إما بالمعرّف الخادمي أو عبر إعادة البناء من الطابور المحلي (UX-Honesty / م-21).
  Future<FarmerAccount?> resolveFarmer(
    String accountId,
    String identifier, {
    List<FarmerAccount>? cachedList,
  }) async {
    await initialize();

    if (cachedList != null) {
      for (final f in cachedList) {
        if (f.id == identifier || f.entityReference.serverId == identifier) {
          return f;
        }
      }
    }

    final command = await _outbox.byLocalId(accountId, identifier);
    if (command != null && command.type == CommandType.createFarmer) {
      final mapping = await _store.mapping(
        accountId,
        identifier,
        EntityKind.farmerWellAccount,
      );
      if (mapping != null && cachedList != null) {
        for (final f in cachedList) {
          if (f.id == mapping.serverId) return f;
        }
      }

      final name = command.payload['p_full_name'] as String? ?? 'مزارع محلي';
      final phone = command.payload['p_phone'] as String?;
      return FarmerAccount.pending(
        reference: CommandReference(
          localId: command.localId,
          kind: EntityKind.farmerWellAccount,
        ),
        fullName: name,
        phone: phone,
      );
    }

    final mappings = await _store.mappings(accountId);
    for (final m in mappings) {
      if (m.kind == EntityKind.farmerWellAccount &&
          (m.localId == identifier || m.serverId == identifier)) {
        if (cachedList != null) {
          for (final f in cachedList) {
            if (f.id == m.serverId) return f;
          }
        }
      }
    }

    return null;
  }

  /// استرجاع أرض إما بالمعرّف الخادمي أو عبر إعادة البناء من الطابور المحلي (UX-Honesty / م-21).
  Future<Farm?> resolveFarm(
    String accountId,
    String identifier, {
    List<Farm>? cachedList,
  }) async {
    await initialize();

    if (cachedList != null) {
      for (final f in cachedList) {
        if (f.id == identifier || f.entityReference.serverId == identifier) {
          return f;
        }
      }
    }

    final command = await _outbox.byLocalId(accountId, identifier);
    if (command != null && command.type == CommandType.createFarm) {
      final mapping = await _store.mapping(
        accountId,
        identifier,
        EntityKind.farm,
      );
      if (mapping != null && cachedList != null) {
        for (final f in cachedList) {
          if (f.id == mapping.serverId) return f;
        }
      }

      final name = command.payload['p_name'] as String? ?? 'أرض محلية';
      final label = command.payload['p_distinguishing_label'] as String?;
      final rawFarmerRef = command.payload['p_farmer_well_account_id'];
      final EntityReference farmerRef;
      if (rawFarmerRef is Map && CommandReference.isReference(rawFarmerRef)) {
        farmerRef = PendingLocalEntityReference(
          CommandReference.fromJson(rawFarmerRef as Map<Object?, Object?>),
        );
      } else if (rawFarmerRef is String) {
        farmerRef = ServerEntityReference(rawFarmerRef);
      } else {
        farmerRef = const ServerEntityReference('');
      }

      return Farm.pending(
        reference: CommandReference(
          localId: command.localId,
          kind: EntityKind.farm,
        ),
        wellId: command.wellId ?? '',
        name: name,
        distinguishingLabel: label,
        farmerReference: farmerRef,
      );
    }

    return null;
  }

  /// 1. بدء جلسة سقي جديدة وحفظها فوراً في الطابور المتين (ق-89 / ق-114)
  ///
  /// [crops] محاصيل هذه الجلسة (ق-131 البند 1): تسافر داخل أمر البدء
  /// نفسه في الطابور المتين، فتصل إلى الخادم مع المزامنة ولا تختفي
  /// بعدها، والفراغ مسموح ولا يمنع البدء.
  ///
  /// [plannedDurationMinutes] المدة المخطّطة (ق-132/750). `null` يعني
  /// «لم يحدد المستخدم مدة» فيسافر الأمر بالنوع القديم وحمولته الحرفية
  /// — لا مدة ضمنية ولا افتراض. بقيمة موجبة يسافر إلى عقد
  /// `start_adhoc_session` الحاكم. توفّر حجوزات قادمة لا يتحقق منه
  /// العميل إطلاقًا — الخادم وحده حاكم، والرفض يصير مراجعة بشرية.
  Future<CommandEnvelope> startSession({
    required String accountId,
    required String wellId,
    required String pumpId,
    required String farmId,
    required String farmerAccountId,
    required String energySource,
    List<String> crops = const [],
    EntityReference? farmReference,
    EntityReference? farmerReference,
    DateTime? startedAt,
    int? plannedDurationMinutes,
  }) async {
    await initialize();

    if (plannedDurationMinutes != null && plannedDurationMinutes <= 0) {
      throw ArgumentError.value(
        plannedDurationMinutes,
        'plannedDurationMinutes',
        'المدة المخطّطة يجب أن تكون دقائق موجبة',
      );
    }

    final eventTime = startedAt ?? DateTime.now();
    final effectiveFarm = farmReference != null
        ? farmReference.toPayload()
        : (farmId.isNotEmpty
              ? farmId
              : throw ArgumentError('معرف الأرض مطلوب'));
    final effectiveFarmer = farmerReference != null
        ? farmerReference.toPayload()
        : (farmerAccountId.isNotEmpty
              ? farmerAccountId
              : throw ArgumentError('معرف حساب المزارع مطلوب'));

    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: wellId,
      type: plannedDurationMinutes == null
          ? CommandType.startIrrigationSession
          : CommandType.startAdhocSession,
      occurredAt: eventTime,
      payload: {
        'p_well_id': wellId,
        'p_pump_id': pumpId,
        'p_farm_id': effectiveFarm,
        'p_farmer_well_account_id': effectiveFarmer,
        'p_energy_source': energySource,
        'p_planned_duration_minutes': ?plannedDurationMinutes,
        'p_crops': normalizeCropSnapshot(crops),
      },
    );

    await projectActiveSession(accountId: accountId, wellId: wellId);
    await _triggerSync(
      accountId,
      sessionLocalId: envelope.localId,
      wellId: wellId,
    );
    return envelope;
  }

  /// 2. إيقاف الجلسة مؤقتاً (ق-89 / ق-114)
  Future<CommandEnvelope> pauseSession({
    required String accountId,
    required String sessionLocalId,
    required String reason,
    DateTime? pausedAt,
  }) async {
    await initialize();
    if (reason != 'operator_pause' && reason != 'farmer_requested_pause') {
      throw ArgumentError.value(reason, 'reason', 'سبب إيقاف غير معتمد');
    }

    final eventTime = pausedAt ?? DateTime.now();
    final start = await _sessionStart(accountId, sessionLocalId);
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: start.wellId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.pauseIrrigationSession,
      occurredAt: eventTime,
      payload: {
        'p_session_id': _outbox.referenceTo(start).toJson(),
        'p_reason': reason,
      },
    );

    await _projectExactSession(accountId, sessionLocalId);
    await _triggerSync(accountId, sessionLocalId: sessionLocalId);
    return envelope;
  }

  /// 3. استئناف الجلسة (ق-89 / ق-114)
  Future<CommandEnvelope> resumeSession({
    required String accountId,
    required String sessionLocalId,
    DateTime? resumedAt,
  }) async {
    await initialize();

    final eventTime = resumedAt ?? DateTime.now();
    final start = await _sessionStart(accountId, sessionLocalId);
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: start.wellId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.resumeIrrigationSession,
      occurredAt: eventTime,
      payload: {'p_session_id': _outbox.referenceTo(start).toJson()},
    );

    await _projectExactSession(accountId, sessionLocalId);
    await _triggerSync(accountId, sessionLocalId: sessionLocalId);
    return envelope;
  }

  /// 4. تغيير مصدر الطاقة أثناء السقي (ق-81 / ق-114)
  Future<CommandEnvelope> changeEnergySource({
    required String accountId,
    required String sessionLocalId,
    required String newEnergySource,
    DateTime? changedAt,
  }) async {
    await initialize();

    final eventTime = changedAt ?? DateTime.now();
    final start = await _sessionStart(accountId, sessionLocalId);
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: start.wellId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.changeSessionEnergySource,
      occurredAt: eventTime,
      payload: {
        'p_session_id': _outbox.referenceTo(start).toJson(),
        'p_new_source': newEnergySource,
      },
    );

    await _projectExactSession(accountId, sessionLocalId);
    await _triggerSync(accountId, sessionLocalId: sessionLocalId);
    return envelope;
  }

  /// 5. إنهاء جلسة السقي واحتساب المستحق (ق-92 / ق-114)
  Future<CommandEnvelope> completeSession({
    required String accountId,
    required String sessionLocalId,
    DateTime? completedAt,
  }) async {
    await initialize();

    final eventTime = completedAt ?? DateTime.now();
    final start = await _sessionStart(accountId, sessionLocalId);
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: start.wellId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.completeIrrigationSession,
      occurredAt: eventTime,
      payload: {'p_session_id': _outbox.referenceTo(start).toJson()},
    );

    await _projectExactSession(accountId, sessionLocalId);
    await _triggerSync(accountId, sessionLocalId: sessionLocalId);
    return envelope;
  }

  /// 6. تسجيل دفعة مالية وسند قبض (UX-10 / ق-91)
  Future<CommandEnvelope> recordPayment({
    required String accountId,
    required String wellId,
    required String farmerAccountId,
    required int amountMinor,
    required String paymentMethod,
    String? note,
    String? sessionLocalId,
    String? sessionCompletionLocalId,
    DateTime? paidAt,
  }) async {
    await initialize();

    final eventTime = paidAt ?? DateTime.now();
    Map<String, Object?>? chargeReference;
    if (sessionCompletionLocalId != null) {
      if (sessionLocalId == null) {
        throw StateError('ربط تكلفة الجلسة يتطلب مرجع الجلسة المحلية');
      }
      final start = await _sessionStart(accountId, sessionLocalId);
      if (start.wellId != wellId) {
        throw StateError('بئر الدفعة لا يطابق بئر الجلسة');
      }
      final completion = await _outbox.byLocalId(
        accountId,
        sessionCompletionLocalId,
      );
      if (completion == null ||
          completion.type != CommandType.completeIrrigationSession ||
          completion.aggregateLocalId != sessionLocalId) {
        throw StateError('أمر إنهاء الجلسة غير صالح لربط الدفعة');
      }
      chargeReference = _outbox.referenceTo(completion).toJson();
    } else if (sessionLocalId != null) {
      throw StateError('دفعة الجلسة تتطلب مرجع أمر الإنهاء');
    }
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: wellId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.recordPayment,
      occurredAt: eventTime,
      payload: {
        'p_well_id': wellId,
        'p_farmer_well_account_id': farmerAccountId,
        'p_amount_minor': amountMinor,
        'p_method': paymentMethod,
        'p_session_charge_id': ?chargeReference,
        'p_note': ?note,
      },
    );

    if (sessionLocalId != null) {
      await _projectExactSession(accountId, sessionLocalId);
    } else {
      await projectActiveSession(accountId: accountId, wellId: wellId);
    }
    await _triggerSync(
      accountId,
      sessionLocalId: sessionLocalId,
      wellId: wellId,
    );
    return envelope;
  }

  Future<CommandEnvelope> _sessionStart(
    String accountId,
    String sessionLocalId,
  ) async {
    final start = await _outbox.byLocalId(accountId, sessionLocalId);
    if (start == null || !_isSessionStartType(start.type)) {
      throw StateError('مرجع جلسة محلي غير صالح: $sessionLocalId');
    }
    return start;
  }

  /// أمر البدء سواء بالعقد القديم أو بعقد المدة المخطّطة (ق-132/750).
  static bool _isSessionStartType(CommandType type) =>
      type == CommandType.startIrrigationSession ||
      type == CommandType.startAdhocSession;

  Future<ActiveSessionRecord?> _projectExactSession(
    String accountId,
    String sessionLocalId,
  ) async {
    final record = await _projector.projectSession(
      accountId,
      sessionLocalId,
      now: DateTime.now(),
    );
    _currentProjectedSession = record?.businessState.isActive == true
        ? record
        : null;
    _sessionController.add(_currentProjectedSession);
    return record;
  }

  Future<void> _triggerSync(
    String accountId, {
    String? sessionLocalId,
    String? wellId,
  }) async {
    try {
      await _commandQueuedScheduler?.call(accountId);
    } catch (_) {
      // الأمر محفوظ؛ تعطل جدولة النظام لا يحوّله إلى فشل حفظ.
    }
    if (_syncEngine == null) return;
    final projectionGeneration = ++_syncProjectionGeneration;
    _syncEngine!
        .run(accountId)
        .then((_) async {
          if (projectionGeneration != _syncProjectionGeneration) return;
          if (sessionLocalId != null) {
            await _projectExactSession(accountId, sessionLocalId);
          } else {
            await projectActiveSession(accountId: accountId, wellId: wellId);
          }
        })
        .catchError((_) {});
  }

  /// جلب عدد العمليات المعلقة في الطابور المتين (القرار 563 / القرار 578)
  ///
  /// [accountId] هوية صاحب الطابور كما أعادها العقد. كان اختياريًّا فيسقط إلى
  /// مفتاح ثابت، فيُقرأ الطابور بمفتاح ويُكتب بآخر ويظهر «لا معلّق» كذبًا.
  Future<int> getPendingOperationsCount(String accountId) async {
    await initialize();
    return _outbox.pendingCount(accountId);
  }

  /// المخزن الافتراضي يفتح ملف الطابور نفسه الذي يستخدمه العامل الخلفي.
  bool get usesDurableStore => _store is SqliteOutboxStore;

  /// هل يوجد ناقل مزامنة موصول بهذا المنسق؟ بلا ناقل لا يجوز الادعاء أن
  /// المزامنة جرت.
  bool get canSyncNow => _syncEngine != null;

  /// آخر مزامنة ناجحة مسجَّلة في الطابور؛ `null` تعني «لم تحدث بعد».
  Future<DateTime?> lastSuccessfulSyncAt(String accountId) async {
    await initialize();
    return _outbox.lastSuccessfulSyncAt(accountId);
  }

  /// تشغيل المزامنة الآن بطلب صريح من المستخدم. يفشل صريحًا إن لم يكن
  /// هناك ناقل موصول، ولا يُدَّعى إرسال لم يحدث.
  Future<SyncRunReport> syncNow(String accountId) async {
    final engine = _syncEngine;
    if (engine == null) {
      throw StateError('لا يوجد ناقل مزامنة موصول بهذا المنسق');
    }
    await initialize();
    return engine.run(accountId);
  }

  final _inFlightResolutions = <String>{};

  /// استعراض عمليات إنشاء المزارعين التي تحتاج مراجعة وحسمًا بشريًا (ق-88 / ق-114).
  Future<List<FarmerIdentityReview>> getFarmerIdentityReviews(
    String accountId, {
    String? wellId,
  }) async {
    await initialize();
    final commands = await _store.pendingCommands(accountId);
    final reviews = <FarmerIdentityReview>[];
    for (final cmd in commands) {
      if (cmd.type == CommandType.createFarmer &&
          cmd.status == CommandStatus.review) {
        if (wellId != null &&
            cmd.wellId != wellId &&
            cmd.payload['p_well_id'] != wellId) {
          continue;
        }
        final review = FarmerIdentityReview.fromCommand(cmd);
        if (review != null) {
          reviews.add(review);
        }
      }
    }
    return reviews;
  }

  /// هل هناك قرار حسم قيد الإرسال أو مسجل في الطابور لهذا المزارع؟
  /// يمنع تكرار النقر وتكرار إدراج أوامر الحسم في الطابور.
  Future<bool> hasPendingResolutionFor(
    String accountId,
    String originalCommandLocalId,
  ) async {
    if (_inFlightResolutions.contains(originalCommandLocalId)) return true;
    await initialize();
    final commands = await _store.pendingCommands(accountId);
    return commands.any(
      (c) =>
          c.type == CommandType.resolveFarmerIdentity &&
          c.aggregateLocalId == originalCommandLocalId &&
          c.status != CommandStatus.confirmed,
    );
  }

  /// إدراج أمر حسم هوية المزارع باستخدام شخص قائم (use_existing).
  Future<CommandEnvelope> resolveFarmerWithExisting({
    required String accountId,
    required FarmerIdentityReview review,
    required String selectedPersonId,
  }) async {
    await initialize();
    if (await hasPendingResolutionFor(accountId, review.commandLocalId)) {
      throw StateError('يوجد قرار حسم معلّق بالفعل لهذا المزارع');
    }
    _inFlightResolutions.add(review.commandLocalId);
    try {
      final envelope = await _outbox.enqueue(
        accountId: accountId,
        wellId: review.wellId,
        type: CommandType.resolveFarmerIdentity,
        occurredAt: DateTime.now(),
        aggregateLocalId: review.commandLocalId,
        payload: {
          'p_well_id': review.wellId,
          'p_original_command_id': review.commandId,
          'p_resolution_action': 'use_existing',
          'p_selected_person_id': selectedPersonId,
        },
      );
      await _triggerSync(accountId, wellId: review.wellId);
      return envelope;
    } finally {
      _inFlightResolutions.remove(review.commandLocalId);
    }
  }

  /// إدراج أمر حسم هوية المزارع كشخص مختلف (different_person).
  Future<CommandEnvelope> resolveFarmerAsDifferentPerson({
    required String accountId,
    required FarmerIdentityReview review,
    required String fullName,
    String? phone,
    String? preferredName,
    String? notes,
    int? creditLimitMinor,
  }) async {
    await initialize();
    if (await hasPendingResolutionFor(accountId, review.commandLocalId)) {
      throw StateError('يوجد قرار حسم معلّق بالفعل لهذا المزارع');
    }
    _inFlightResolutions.add(review.commandLocalId);
    try {
      final envelope = await _outbox.enqueue(
        accountId: accountId,
        wellId: review.wellId,
        type: CommandType.resolveFarmerIdentity,
        occurredAt: DateTime.now(),
        aggregateLocalId: review.commandLocalId,
        payload: {
          'p_well_id': review.wellId,
          'p_original_command_id': review.commandId,
          'p_resolution_action': 'different_person',
          'p_full_name': fullName.trim(),
          if (phone != null && phone.trim().isNotEmpty) 'p_phone': phone.trim(),
          if (preferredName != null && preferredName.trim().isNotEmpty)
            'p_preferred_name': preferredName.trim(),
          if (notes != null && notes.trim().isNotEmpty) 'p_notes': notes.trim(),
          'p_credit_limit_minor': ?creditLimitMinor,
        },
      );
      await _triggerSync(accountId, wellId: review.wellId);
      return envelope;
    } finally {
      _inFlightResolutions.remove(review.commandLocalId);
    }
  }

  void dispose() {
    _tickerTimer?.cancel();
    _tickerTimer = null;
    _initialized = false;
    if (!_sessionController.isClosed) {
      _sessionController.close();
    }
    _instance = null;
  }
}

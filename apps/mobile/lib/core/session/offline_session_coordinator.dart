// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../sync/command_envelope.dart';
import '../sync/command_transport.dart';
import '../sync/command_type.dart';
import '../sync/outbox_repository.dart';
import '../sync/outbox_store.dart';
import '../sync/sqlite_outbox_store.dart';
import '../sync/supabase_command_transport.dart';
import '../sync/sync_engine.dart';
import 'active_session_projector.dart';
import 'active_session_record.dart';

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
  }) : _store = store ?? SqliteOutboxStore(),
       _commandQueuedScheduler = commandQueuedScheduler,
       // لا سعر افتراضي في العميل (م-41D6): اللقطات تُغذّى من
       // `api.get_active_price_schedule` عبر `updatePricing`. حتى تُغذّى،
       // كل مقطع محتسب «بانتظار المزامنة» ولا يُسعَّر بصفر (القرار 341).
       _pricingResolver = pricingResolver ?? const PricingResolver.none() {
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
    final activeSessions = await _projector.activeSessions(
      accountId,
      now: now,
    );

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

  /// 1. بدء جلسة سقي جديدة وحفظها فوراً في الطابور المتين (ق-89 / ق-114)
  Future<CommandEnvelope> startSession({
    required String accountId,
    required String wellId,
    required String pumpId,
    required String farmId,
    required String farmerAccountId,
    required String energySource,
    DateTime? startedAt,
  }) async {
    await initialize();

    final eventTime = startedAt ?? DateTime.now();
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: wellId,
      type: CommandType.startIrrigationSession,
      occurredAt: eventTime,
      payload: {
        'p_well_id': wellId,
        'p_pump_id': pumpId,
        'p_farm_id': farmId,
        'p_farmer_well_account_id': farmerAccountId,
        'p_energy_source': energySource,
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
    if (start == null || start.type != CommandType.startIrrigationSession) {
      throw StateError('مرجع جلسة محلي غير صالح: $sessionLocalId');
    }
    return start;
  }

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

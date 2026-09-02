import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../sync/command_envelope.dart';
import '../sync/command_type.dart';
import '../sync/in_memory_outbox_store.dart';
import '../sync/outbox_repository.dart';
import '../sync/outbox_store.dart';
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
    PricingResolver? pricingResolver,
  })  : _store = store ?? InMemoryOutboxStore(),
        // لا سعر افتراضي في العميل (م-41D6): اللقطات تُغذّى من
        // `api.get_active_price_schedule` عبر `updatePricing`. حتى تُغذّى،
        // كل مقطع محتسب «بانتظار المزامنة» ولا يُسعَّر بصفر (القرار 341).
        _pricingResolver = pricingResolver ?? const PricingResolver.none() {
    _outbox = OutboxRepository(store: _store);
    _projector = ActiveSessionProjector(
      store: _store,
      pricing: _pricingResolver,
    );
    if (supabaseClient != null) {
      _syncEngine = SyncEngine(
        store: _store,
        transport: SupabaseCommandTransport(supabaseClient),
      );
    }
  }


  static OfflineSessionCoordinator? _instance;
  static OfflineSessionCoordinator get instance =>
      _instance ??= OfflineSessionCoordinator();

  final OutboxStore _store;
  late final OutboxRepository _outbox;
  late ActiveSessionProjector _projector;
  SyncEngine? _syncEngine;
  PricingResolver _pricingResolver;

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
    if (_initialized) return;
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
  ActiveSessionRecord? get currentActiveSession => _currentProjectedSession;

  /// استرجاع وإسقاط الجلسة النشطة الحالية لبئر معين
  Future<ActiveSessionRecord?> projectActiveSession({
    required String accountId,
    String? wellId,
  }) async {
    await initialize();

    final now = DateTime.now();
    final activeSessions = await _projector.activeSessions(
      accountId,
      now: now,
    );


    if (activeSessions.isEmpty) {
      _currentProjectedSession = null;
      _sessionController.add(null);
      return null;
    }

    // إذا تم تحديد البئر، نبحث عن الجلسة الخاصة به، وإلا نأخذ أول جلسة فعالة
    final match = wellId != null
        ? activeSessions.where((s) => s.wellId == wellId).firstOrNull ??
            activeSessions.first
        : activeSessions.first;

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
    _triggerSync(accountId);
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

    final eventTime = pausedAt ?? DateTime.now();
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.pauseIrrigationSession,
      occurredAt: eventTime,
      payload: {
        'p_session_id': sessionLocalId,
        'p_reason': reason,
      },
    );

    await projectActiveSession(accountId: accountId);
    _triggerSync(accountId);
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
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.resumeIrrigationSession,
      occurredAt: eventTime,
      payload: {
        'p_session_id': sessionLocalId,
      },
    );

    await projectActiveSession(accountId: accountId);
    _triggerSync(accountId);
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
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.changeSessionEnergySource,
      occurredAt: eventTime,
      payload: {
        'p_session_id': sessionLocalId,
        'p_new_source': newEnergySource,
      },

    );

    await projectActiveSession(accountId: accountId);
    _triggerSync(accountId);
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
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.completeIrrigationSession,
      occurredAt: eventTime,
      payload: {
        'p_session_id': sessionLocalId,
      },
    );

    await projectActiveSession(accountId: accountId);
    _triggerSync(accountId);
    return envelope;
  }

  /// 6. تسجيل دفعة مالية وسند قبض (UX-10 / ق-91)
  Future<CommandEnvelope> recordPayment({
    required String accountId,
    required String wellId,
    required String farmerAccountId,
    required int amountMinor,
    required String paymentMethod,
    String? reference,
    String? sessionLocalId,
    DateTime? paidAt,
  }) async {
    await initialize();

    final eventTime = paidAt ?? DateTime.now();
    final envelope = await _outbox.enqueue(
      accountId: accountId,
      wellId: wellId,
      aggregateLocalId: sessionLocalId,
      type: CommandType.recordPayment,
      occurredAt: eventTime,
      payload: {
        'p_well_id': wellId,
        'p_farmer_well_account_id': farmerAccountId,
        'p_amount': amountMinor,
        'p_payment_method': paymentMethod,
        'p_reference': ?reference,
      },
    );



    await projectActiveSession(accountId: accountId, wellId: wellId);
    _triggerSync(accountId);
    return envelope;
  }

  void _triggerSync(String accountId) {
    if (_syncEngine == null) return;
    _syncEngine!.run(accountId).then((_) {
      // بعد المزامنة، نعيد إسقاط الحالة لتحديث معرّفات الخادم
      if (_currentProjectedSession != null) {
        projectActiveSession(
          accountId: _currentProjectedSession!.accountId,
          wellId: _currentProjectedSession!.wellId,
        );
      }
    }).catchError((_) {});
  }


  /// جلب عدد العمليات المعلقة في الطابور المتين (القرار 563 / القرار 578)
  ///
  /// [accountId] هوية صاحب الطابور كما أعادها العقد. كان اختياريًّا فيسقط إلى
  /// مفتاح ثابت، فيُقرأ الطابور بمفتاح ويُكتب بآخر ويظهر «لا معلّق» كذبًا.
  Future<int> getPendingOperationsCount(String accountId) async {
    await initialize();
    return _outbox.pendingCount(accountId);
  }

  /// هل الطابور المستعمل مخزَّن على قرص الهاتف فعلًا؟ الافتراضي في هذا
  /// البناء طابور ذاكرة، فلا يجوز إعلان جاهزية تخزين محلي دائم للمستخدم
  /// قبل توصيل الطابور الدائم في واجهة التطبيق.
  bool get usesDurableStore => _store is! InMemoryOutboxStore;

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

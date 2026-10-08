import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api/app_bootstrap_repository.dart';
import '../../core/api/booking_repository.dart';
import '../../core/api/operations_repository.dart';
import '../../core/api/well_management_repository.dart';
import '../../core/identity/app_identity.dart';
import '../../core/session/active_session_projector.dart';
import '../../core/session/active_session_record.dart';
import '../../core/session/offline_session_coordinator.dart';
import '../../core/session/session_business_state.dart';
import '../../core/session/session_segment.dart';
import '../../core/sync/command_envelope.dart';
import '../../core/sync/farmer_identity_review.dart';
import '../../core/theme/app_colors.dart';
import '../farmers/farmer_identity_resolution_sheet.dart';
import '../../core/utils/currency_utils.dart';
import '../../core/utils/digit_utils.dart';
import '../../core/utils/tafqeet_utils.dart';
import '../../core/widgets/smart_lookup_field.dart';
import '../../core/widgets/top_well_selector.dart';
import 'widgets/compact_energy_selector.dart';
import 'widgets/payment_receipt_dialog.dart';
import 'widgets/session_confirmation_dialogs.dart';
import 'widgets/today_bookings_panel.dart';

/// شاشة تشغيل البئر وجلسات السقي الميدانية (UX-07 / UX-08 / ق-88 / ق-114 / ق-129)
class OperationsScreen extends StatefulWidget {
  const OperationsScreen({
    required this.identity,
    this.coordinator,
    this.repository,
    this.bookingRepository,
    this.priceRepository,
    this.clock,
    this.onWellChanged,
    this.onLogout,
    super.key,
  });

  /// هوية الجولة كما قرأها العقد: صاحب العملية، وآباره، وبئره النشط.
  final AppIdentity identity;
  final OfflineSessionCoordinator? coordinator;
  final OperationsRepository? repository;
  final BookingRepository? bookingRepository;

  /// مستودع قراءة جدول التسعير الساري.
  final WellManagementRepository? priceRepository;
  final DateTime Function()? clock;
  final ValueChanged<WellSummary>? onWellChanged;
  final VoidCallback? onLogout;

  @override
  State<OperationsScreen> createState() => _OperationsScreenState();
}

class _OperationsScreenState extends State<OperationsScreen>
    with WidgetsBindingObserver {
  late OperationsRepository _repo;
  late BookingRepository _bookingRepo;
  late OfflineSessionCoordinator _coordinator;
  late WellManagementRepository _priceRepo;

  late WellSummary _activeWell;

  String get _activeWellId => _activeWell.id;
  String get _accountId => widget.identity.accountId;
  DateTime _now() => (widget.clock ?? DateTime.now)();

  // خيارات الجلسة
  FarmerAccount? _selectedFarmer;
  Farm? _selectedFarm;
  Pump? _selectedPump;
  List<Pump> _pumps = [];
  List<FarmerIdentityReview> _activeWellReviews = const [];

  // محاصيل الجلسة (ق-131 البند 1): الاقتراحات من جلسات الأرض السابقة
  // حصرًا، والاختيار حر غير مانع، والبدء بلا محاصيل ممكن.
  List<String> _farmCropSuggestions = const [];
  List<String> _selectedCrops = const [];
  bool _isLoadingCrops = false;
  String? _cropsError;
  int _cropLoadGeneration = 0;
  final TextEditingController _newCropController = TextEditingController();

  // حالة المزارع عند اختياره (ق-131 البند 11): ملخص إخباري غير مانع —
  // الدين والمقدم وكمية ديزله من الخادم، ولا يحجب بدء السقي أبدًا.
  FarmerSelectionStatus? _farmerStatus;
  bool _isLoadingFarmerStatus = false;
  String? _farmerStatusError;
  bool _farmerStatusAwaitingSync = false;
  int _farmerStatusGeneration = 0;

  /// رمز مصدر الطاقة: يبدأ فارغًا (null) قبل كل جلسة جديدة وفق ق-129
  /// (لا اختيار افتراضي تلقائي ذو أثر تشغيلي أو مالي).
  String? _energySourceCode;

  PriceScheduleModel? _priceSchedule;
  bool _isLoadingSchedule = false;
  String? _scheduleError;
  bool _pricingForbidden = false;
  int _priceLoadGeneration = 0;

  // جدول اليوم وإعداد الانتقال التلقائي (ق-132 / ق-134 / P2 mobile).
  WellDaySchedule? _daySchedule;
  BookingAutomationState? _bookingAutomation;
  bool _isLoadingDaySchedule = false;
  bool _isLoadingBookingAutomation = false;
  bool _isUpdatingBookingAutomation = false;
  String? _dayScheduleError;
  String? _bookingAutomationError;
  int _dayScheduleGeneration = 0;
  int _bookingAutomationGeneration = 0;
  String? _pendingAutomationCommandId;
  bool? _pendingAutomationTarget;
  int? _pendingAutomationRevision;
  String? _startingBookingId;
  final Map<String, String> _pendingStartCommandIds = <String, String>{};

  List<PriceRuleModel> get _priceRules => _priceSchedule?.rules ?? const [];

  PriceRuleModel? _ruleFor(String? code) {
    if (code == null) return null;
    for (final rule in _priceRules) {
      if (rule.energySource == code) return rule;
    }
    return null;
  }

  // حالة الجلسة المباشرة
  Timer? _timer;
  StreamSubscription<ActiveSessionRecord?>? _activeSessionSubscription;
  ActiveSessionRecord? _activeSession;
  bool _isSessionActive = false;
  bool _isPaused = false;
  int _secondsElapsed = 0;
  String? _activeSessionId;
  bool _isLoadingPumps = false;
  String? _pumpsError;
  bool _isSubmitting = false;
  bool _isSessionActionInProgress = false;
  int _pumpLoadGeneration = 0;
  int _projectionGeneration = 0;

  /// اكتمال حقول النموذج الإلزامية لبدء السقي (ق-129 / A8)
  bool get _isFormComplete =>
      _selectedFarmer != null &&
      _selectedFarm != null &&
      _selectedPump != null &&
      _energySourceCode != null;

  /// إرشاد الحقل الناقص الفعلي (ق-129 / A8)
  String? get _missingFieldGuidance {
    if (_selectedFarmer == null) return 'يرجى تحديد المزارع المستفيد';
    if (_selectedFarm == null) return 'يرجى تحديد الأرض الزراعية';
    if (_selectedPump == null) return 'يرجى اختيار المضخة العاملة';
    if (_energySourceCode == null) return 'يرجى تحديد مصدر الطاقة';
    return null;
  }

  @override
  void initState() {
    super.initState();
    _activeWell = widget.identity.activeWell;
    _coordinator = widget.coordinator ?? OfflineSessionCoordinator.instance;
    _bookingRepo = widget.bookingRepository ?? BookingRepository();
    _priceRepo = widget.priceRepository ?? WellManagementRepository();

    final repository = widget.repository;
    if (repository != null) {
      _repo = repository;
    } else {
      try {
        _repo = OperationsRepository(Supabase.instance.client);
      } catch (_) {
        _repo = const OperationsRepository();
      }
    }

    WidgetsBinding.instance.addObserver(this);
    _activeSessionSubscription = _coordinator.activeSessionStream.listen(
      _handleActiveSessionUpdate,
    );
    _recoverActiveSession();
    _loadPumps();
    _loadPriceSchedule();
    _checkActiveWellReviews();
    _loadBookingOverview();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _activeWellId.isNotEmpty) {
      _recoverActiveSession();
      _loadBookingOverview();
    }
  }

  Future<void> _loadBookingOverview() async {
    await Future.wait([
      _loadDaySchedule(),
      _loadBookingAutomation(),
    ]);
  }

  Future<void> _loadDaySchedule() async {
    final requestedWellId = _activeWellId;
    final generation = ++_dayScheduleGeneration;
    if (mounted) {
      setState(() {
        _isLoadingDaySchedule = true;
        _dayScheduleError = null;
      });
    }

    try {
      final schedule = await _bookingRepo.fetchTodaySchedule(requestedWellId);
      if (!mounted ||
          generation != _dayScheduleGeneration ||
          requestedWellId != _activeWellId) {
        return;
      }
      setState(() {
        _daySchedule = schedule;
        _isLoadingDaySchedule = false;
      });
    } on PostgrestException catch (e) {
      if (!mounted ||
          generation != _dayScheduleGeneration ||
          requestedWellId != _activeWellId) {
        return;
      }
      setState(() {
        _isLoadingDaySchedule = false;
        _dayScheduleError = e.message;
      });
    } catch (_) {
      if (!mounted ||
          generation != _dayScheduleGeneration ||
          requestedWellId != _activeWellId) {
        return;
      }
      setState(() {
        _isLoadingDaySchedule = false;
        _dayScheduleError = 'تعذر تحميل حجوزات اليوم. حاول مرة أخرى.';
      });
    }
  }

  Future<void> _loadBookingAutomation() async {
    final requestedWellId = _activeWellId;
    final generation = ++_bookingAutomationGeneration;
    if (mounted) {
      setState(() {
        _isLoadingBookingAutomation = true;
        _bookingAutomationError = null;
      });
    }

    try {
      final state = await _bookingRepo.fetchAutomation(requestedWellId);
      if (!mounted ||
          generation != _bookingAutomationGeneration ||
          requestedWellId != _activeWellId) {
        return;
      }
      setState(() {
        _bookingAutomation = state;
        _isLoadingBookingAutomation = false;
      });
    } on PostgrestException catch (e) {
      if (!mounted ||
          generation != _bookingAutomationGeneration ||
          requestedWellId != _activeWellId) {
        return;
      }
      setState(() {
        _isLoadingBookingAutomation = false;
        _bookingAutomationError = e.message;
      });
    } catch (_) {
      if (!mounted ||
          generation != _bookingAutomationGeneration ||
          requestedWellId != _activeWellId) {
        return;
      }
      setState(() {
        _isLoadingBookingAutomation = false;
        _bookingAutomationError =
            'تعذر قراءة إعداد الانتقال التلقائي. حاول مرة أخرى.';
      });
    }
  }

  Future<void> _toggleBookingAutomation(bool enabled) async {
    final state = _bookingAutomation;
    if (state == null || _isUpdatingBookingAutomation) return;

    final requestedWellId = _activeWellId;
    final reusePending =
        _pendingAutomationCommandId != null &&
        _pendingAutomationTarget == enabled &&
        _pendingAutomationRevision == state.revision;
    final commandId = reusePending
        ? _pendingAutomationCommandId!
        : _bookingRepo.newCommandId();

    setState(() {
      _isUpdatingBookingAutomation = true;
      _bookingAutomationError = null;
      _pendingAutomationCommandId = commandId;
      _pendingAutomationTarget = enabled;
      _pendingAutomationRevision = state.revision;
    });

    try {
      final update = await _bookingRepo.setAutomation(
        wellId: requestedWellId,
        enabled: enabled,
        expectedRevision: state.revision,
        commandId: commandId,
      );
      if (!mounted || requestedWellId != _activeWellId) return;
      setState(() {
        _bookingAutomation = state.applyUpdate(update);
        _pendingAutomationCommandId = null;
        _pendingAutomationTarget = null;
        _pendingAutomationRevision = null;
        _bookingAutomationError = null;
      });
    } on PostgrestException catch (e) {
      if (!mounted || requestedWellId != _activeWellId) return;
      setState(() {
        _pendingAutomationCommandId = null;
        _pendingAutomationTarget = null;
        _pendingAutomationRevision = null;
        _bookingAutomationError = e.message;
      });
      if (e.code == '40001') {
        await _loadBookingAutomation();
      }
    } catch (_) {
      if (!mounted || requestedWellId != _activeWellId) return;
      setState(() {
        _bookingAutomationError =
            'تعذر تأكيد نتيجة تغيير الإعداد. إعادة المحاولة ستستخدم '
            'معرّف العملية نفسه حتى تُحسم النتيجة.';
      });
    } finally {
      if (mounted && requestedWellId == _activeWellId) {
        setState(() => _isUpdatingBookingAutomation = false);
      }
    }
  }

  Future<void> _startBookingFromSchedule(BookingDayItem booking) async {
    if (_startingBookingId != null) return;

    final requestedWellId = _activeWellId;
    final commandId = _pendingStartCommandIds[booking.id] ??
        _bookingRepo.newCommandId();

    setState(() {
      _startingBookingId = booking.id;
      _pendingStartCommandIds[booking.id] = commandId;
    });

    try {
      final result = await _bookingRepo.startBooking(
        bookingId: booking.id,
        startedAt: _now(),
        commandId: commandId,
      );
      if (!mounted || requestedWellId != _activeWellId) return;
      if (result.wellId != requestedWellId || result.bookingId != booking.id) {
        throw StateError('رد بدء الحجز لا يطابق البئر أو الحجز المطلوب');
      }
      _pendingStartCommandIds.remove(booking.id);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('بدأ الحجز بنجاح على الخادم.')),
      );
      await _loadBookingOverview();
    } on PostgrestException catch (e) {
      if (!mounted || requestedWellId != _activeWellId) return;
      _pendingStartCommandIds.remove(booking.id);
      _showActionFailure(e.message);
      await _loadDaySchedule();
    } catch (_) {
      if (!mounted || requestedWellId != _activeWellId) return;
      _showActionFailure(
        'تعذر معرفة نتيجة بدء الحجز. أعد المحاولة؛ سيستخدم التطبيق '
        'معرّف العملية نفسه لمنع بدء مكرر.',
      );
    } finally {
      if (mounted && requestedWellId == _activeWellId) {
        setState(() => _startingBookingId = null);
      }
    }
  }

  void _showActionFailure(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.error),
    );
  }

  Future<void> _loadPriceSchedule() async {
    final requestedWellId = _activeWellId;
    final requestGeneration = ++_priceLoadGeneration;
    setState(() {
      _isLoadingSchedule = true;
      _scheduleError = null;
      _pricingForbidden = false;
    });

    try {
      final schedule = await _priceRepo.fetchActivePriceSchedule(
        requestedWellId,
      );
      if (!_isCurrentPriceRequest(requestGeneration, requestedWellId)) return;
      setState(() {
        _priceSchedule = schedule;
        _isLoadingSchedule = false;
      });
      _coordinator.updatePricing(_snapshotsFrom(schedule));
      await _recoverActiveSession();
    } on PostgrestException catch (e) {
      if (!_isCurrentPriceRequest(requestGeneration, requestedWellId)) return;
      final forbidden = e.code == '42501';
      setState(() {
        _priceSchedule = null;
        _isLoadingSchedule = false;
        _pricingForbidden = forbidden;
        _scheduleError = forbidden ? null : e.message;
      });
      _coordinator.updatePricing(const []);
      await _recoverActiveSession();
    } catch (e) {
      if (!_isCurrentPriceRequest(requestGeneration, requestedWellId)) return;
      setState(() {
        _priceSchedule = null;
        _isLoadingSchedule = false;
        _scheduleError = '$e';
      });
      _coordinator.updatePricing(const []);
      await _recoverActiveSession();
    }
  }

  bool _isCurrentPriceRequest(int generation, String wellId) =>
      mounted && generation == _priceLoadGeneration && _activeWellId == wellId;

  static List<PricingSnapshot> _snapshotsFrom(PriceScheduleModel? schedule) {
    if (schedule == null) return const [];
    return schedule.rules
        .where((rule) => rule.hourlyRateMinor != null)
        .map(
          (rule) => PricingSnapshot(
            hourlyRateMinor: rule.hourlyRateMinor!,
            effectiveFrom: schedule.effectiveFrom,
            effectiveTo: schedule.effectiveTo,
            energySource: rule.energySource,
            ruleId: rule.id,
          ),
        )
        .toList(growable: false);
  }

  Future<void> _recoverActiveSession() async {
    final requestedWellId = _activeWellId;
    final generation = ++_projectionGeneration;
    final active = await _coordinator.freshProjectActiveSession(
      accountId: _accountId,
      wellId: requestedWellId,
    );

    if (!mounted ||
        generation != _projectionGeneration ||
        requestedWellId != _activeWellId) {
      return;
    }

    if (active == null) {
      _timer?.cancel();
      _timer = null;
      setState(() {
        _activeSession = null;
        _isSessionActive = false;
        _isPaused = false;
        _secondsElapsed = 0;
        _activeSessionId = null;
      });
      return;
    }

    if (active.accountId == _accountId && active.wellId == requestedWellId) {
      setState(() {
        _activeSession = active;
        _isSessionActive = true;
        _isPaused = active.businessState == SessionBusinessState.paused;
        _secondsElapsed = active.totals.billableSeconds;
        _activeSessionId = active.localId;
        _energySourceCode = active.currentEnergySource ?? _energySourceCode;
      });

      // استرجاع المزارع والأرض والمضخة بشكل مستقل ومتوازٍ.
      await Future.wait([
        _recoverFarmer(active, generation),
        _recoverFarm(active, generation),
        _recoverPump(active, generation),
      ]);

      _startLocalTicker();
    }
  }

  /// استرجاع بيانات المزارع من المعرّف في أمر البدء.
  ///
  /// يحميه جيل الإسقاط + الحساب + البئر + هوية الجلسة.
  Future<void> _recoverFarmer(
    ActiveSessionRecord active,
    int generation,
  ) async {
    if (_selectedFarmer != null || active.farmerReference == null) return;
    final wellId = _activeWellId;
    final accountId = _accountId;
    final farmerRef = active.farmerReference!;
    final sessionId = active.localId;
    try {
      final farmers = await _repo.fetchFarmers(wellId);
      final matched = await _coordinator.resolveFarmer(
        accountId,
        farmerRef,
        cachedList: farmers,
      );
      if (matched != null &&
          mounted &&
          generation == _projectionGeneration &&
          wellId == _activeWellId &&
          accountId == _accountId &&
          _activeSessionId == sessionId) {
        setState(() => _selectedFarmer = matched);
      }
    } catch (e) {
      if (mounted &&
          generation == _projectionGeneration &&
          wellId == _activeWellId &&
          accountId == _accountId) {
        _showActionFailure('تعذر تحميل بيانات المزارع للجلسة النشطة');
      }
    }
  }

  /// استرجاع بيانات الأرض من المعرّف في أمر البدء.
  ///
  /// مستقل عن نجاح أو فشل استرجاع المزارع — يُبحث بالمعرّف المباشر.
  Future<void> _recoverFarm(ActiveSessionRecord active, int generation) async {
    if (_selectedFarm != null || active.farmReference == null) return;
    final wellId = _activeWellId;
    final accountId = _accountId;
    final farmRef = active.farmReference!;
    final farmerRef = active.farmerReference;
    final sessionId = active.localId;
    try {
      final farms = await _repo.fetchFarms(wellId, farmerAccountId: farmerRef);
      final matched = await _coordinator.resolveFarm(
        accountId,
        farmRef,
        cachedList: farms,
      );
      if (matched != null &&
          mounted &&
          generation == _projectionGeneration &&
          wellId == _activeWellId &&
          accountId == _accountId &&
          _activeSessionId == sessionId) {
        setState(() => _selectedFarm = matched);
      }
    } catch (e) {
      // فشل البحث لا يمنع عرض الجلسة — الأرض تبقى غير محددة.
    }
  }

  /// استرجاع بيانات المضخة من المعرّف في أمر البدء.
  Future<void> _recoverPump(ActiveSessionRecord active, int generation) async {
    if (_selectedPump != null || active.pumpId == null) return;
    final wellId = _activeWellId;
    final accountId = _accountId;
    final pumpId = active.pumpId!;
    final sessionId = active.localId;
    try {
      final pumps = await _repo.fetchPumps(wellId);
      final matched = pumps.where((p) => p.id == pumpId).firstOrNull;
      if (matched != null &&
          mounted &&
          generation == _projectionGeneration &&
          wellId == _activeWellId &&
          accountId == _accountId &&
          _activeSessionId == sessionId) {
        setState(() => _selectedPump = matched);
      }
    } catch (e) {
      if (mounted &&
          generation == _projectionGeneration &&
          wellId == _activeWellId &&
          accountId == _accountId) {
        _showActionFailure('تعذر تحميل بيانات المضخة للجلسة النشطة');
      }
    }
  }

  void _handleActiveSessionUpdate(ActiveSessionRecord? active) {
    if (!mounted || active == null) return;
    if (active.accountId != _accountId || active.wellId != _activeWellId) {
      return;
    }

    setState(() {
      _activeSession = active;
      _isSessionActive = active.businessState != SessionBusinessState.completed;
      _isPaused = active.businessState == SessionBusinessState.paused;
      _secondsElapsed = active.totals.billableSeconds;
      _activeSessionId = active.localId;
      _energySourceCode = active.currentEnergySource ?? _energySourceCode;
    });
  }

  void _startLocalTicker() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && !_isPaused) {
        setState(() {
          _secondsElapsed++;
        });
      }
    });
  }

  @override
  void didUpdateWidget(covariant OperationsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.identity.activeWell;
    if (incoming.id != oldWidget.identity.activeWell.id) {
      setState(() {
        _activeWell = incoming;
        _selectedFarmer = null;
        _selectedFarm = null;
        _selectedPump = null;
        _pumps = [];
        _energySourceCode = null;
        _activeSession = null;
        _isSessionActive = false;
        _activeSessionId = null;
        _resetCropSelection();
        _resetFarmerStatus();
        _daySchedule = null;
        _bookingAutomation = null;
        _dayScheduleError = null;
        _bookingAutomationError = null;
        _pendingAutomationCommandId = null;
        _pendingAutomationTarget = null;
        _pendingAutomationRevision = null;
        _pendingStartCommandIds.clear();
        _startingBookingId = null;
      });
      _loadPumps();
      _loadPriceSchedule();
      _recoverActiveSession();
      _loadBookingOverview();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _activeSessionSubscription?.cancel();
    _newCropController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// تحميل اقتراحات محاصيل الأرض من عقد `api.list_farm_recent_crops`
  /// (ق-131 البند 1): الفشل صريح مع إعادة محاولة ولا يمنع بدء الجلسة.
  Future<void> _loadFarmCrops() async {
    final farmId = _selectedFarm?.id;
    if (farmId == null || farmId.isEmpty) return;
    final generation = ++_cropLoadGeneration;
    setState(() {
      _isLoadingCrops = true;
      _cropsError = null;
    });
    try {
      final crops = await _repo.fetchFarmRecentCrops(farmId: farmId);
      if (!mounted || generation != _cropLoadGeneration) return;
      setState(() {
        _farmCropSuggestions = crops;
        _isLoadingCrops = false;
      });
    } catch (e) {
      if (!mounted || generation != _cropLoadGeneration) return;
      setState(() {
        _cropsError = 'تعذر تحميل محاصيل الأرض السابقة: $e';
        _isLoadingCrops = false;
      });
    }
  }

  /// تحميل حالة المزارع المختار (ق-131 البند 11) عبر عقد
  /// `api.get_farmer_selection_status`: إخبارية غير مانعة، والفشل
  /// رسالة معلوماتية ولا يُمسّ زر البدء. ولا نداء بمعرّف مفلفق لمزارع
  /// محلي بلا مزامنة — فلا أصفار مخترعة.
  Future<void> _loadFarmerStatus() async {
    final farmer = _selectedFarmer;
    if (farmer == null) return;

    if (farmer.isPending || farmer.id.isEmpty) {
      setState(() {
        _farmerStatus = null;
        _isLoadingFarmerStatus = false;
        _farmerStatusError = null;
        _farmerStatusAwaitingSync = true;
      });
      return;
    }

    final generation = ++_farmerStatusGeneration;
    setState(() {
      _isLoadingFarmerStatus = true;
      _farmerStatusError = null;
      _farmerStatusAwaitingSync = false;
    });
    try {
      final status = await _repo.fetchFarmerSelectionStatus(
        farmerAccountId: farmer.id,
      );
      // ردّ قديم لمزارع سابق لا يُعرض فوق المزارع الحالي.
      if (!mounted || generation != _farmerStatusGeneration) return;
      setState(() {
        _farmerStatus = status;
        _isLoadingFarmerStatus = false;
      });
    } catch (_) {
      if (!mounted || generation != _farmerStatusGeneration) return;
      setState(() {
        _farmerStatus = null;
        _isLoadingFarmerStatus = false;
        _farmerStatusError = 'تعذر عرض حالة المزارع — يمكنك متابعة السقي';
      });
    }
  }

  /// تصفير الحالة فورًا عند مسح الاختيار أو تغييره أو تبديل البئر.
  void _resetFarmerStatus() {
    _farmerStatusGeneration++;
    _farmerStatus = null;
    _isLoadingFarmerStatus = false;
    _farmerStatusError = null;
    _farmerStatusAwaitingSync = false;
  }

  /// كمية الليتر للعرض وحدها من المللتر الخام المحفوظ في النموذج:
  /// كسور لتر ذات معنى تبقى ظاهرة (4.5) ولا تُقرَّب لعدد صحيح.
  String _formatLitres(int ml) {
    var text = (ml / 1000).toStringAsFixed(3);
    while (text.endsWith('0')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.endsWith('.')) text += '0';
    return text;
  }

  /// خيارات القسم: اقتراحات الأرض أولًا ثم ما أضافه المشغل حديثًا.
  List<String> get _cropChoices {
    final choices = List<String>.from(_farmCropSuggestions);
    for (final crop in _selectedCrops) {
      if (!choices.contains(crop)) choices.add(crop);
    }
    return choices;
  }

  void _toggleCrop(String crop) {
    setState(() {
      if (_selectedCrops.contains(crop)) {
        _selectedCrops = List<String>.from(_selectedCrops)..remove(crop);
      } else {
        _selectedCrops = List<String>.from(_selectedCrops)..add(crop);
      }
    });
  }

  void _addNewCrop() {
    final name = _newCropController.text.trim();
    _newCropController.clear();
    if (name.isEmpty || _selectedCrops.contains(name)) return;
    setState(() {
      _selectedCrops = List<String>.from(_selectedCrops)..add(name);
    });
  }

  void _resetCropSelection() {
    _cropLoadGeneration++;
    _farmCropSuggestions = const [];
    _selectedCrops = const [];
    _isLoadingCrops = false;
    _cropsError = null;
    _newCropController.clear();
  }

  Future<void> _loadPumps() async {
    final requestedWellId = _activeWellId;
    final requestGeneration = ++_pumpLoadGeneration;
    setState(() {
      _isLoadingPumps = true;
      _pumpsError = null;
    });

    try {
      final pumps = await _repo.fetchPumps(requestedWellId);
      if (mounted &&
          requestGeneration == _pumpLoadGeneration &&
          requestedWellId == _activeWellId) {
        setState(() {
          _pumps = pumps;
          // ق-129 / A4: مضخة وحيدة مؤهلة = اختيار تلقائي. أكثر من واحدة = لا خيار صامت.
          if (pumps.length == 1) {
            _selectedPump = pumps.single;
          } else {
            _selectedPump = null;
          }
          _isLoadingPumps = false;
        });
      }
    } catch (_) {
      if (mounted &&
          requestGeneration == _pumpLoadGeneration &&
          requestedWellId == _activeWellId) {
        setState(() {
          _pumps = [];
          _selectedPump = null;
          _isLoadingPumps = false;
          _pumpsError = 'تعذّر تحميل المضخات. تحقق من الاتصال ثم أعد المحاولة.';
        });
      }
    }
  }

  Future<void> _checkActiveWellReviews() async {
    try {
      final reviews = await _coordinator.getFarmerIdentityReviews(
        _accountId,
        wellId: _activeWellId,
      );
      if (!mounted) return;
      setState(() {
        _activeWellReviews = reviews;
      });
    } catch (_) {
      // تعذر استعلام المراجعات دون افتعال حالة أو تعطيل واجهة العمليات
    }
  }

  /// منطقة حالة المزارع المختار (ق-131 البند 11): ملخص مختصر غير مانع
  /// — المديونية ورصيد المقدم وكمية ديزل المزارع. الدلالات نصية صريحة
  /// لا +/- غامضة ولا لون وحده، والفشل أو انتظار المزامنة رسالة
  /// معلوماتية تخبر أن المتابعة ممكنة، ولا يُخترع رقم لغياب.
  Widget _buildFarmerStatusArea() {
    const textStyle = TextStyle(fontSize: 13, color: AppColors.textPrimary);

    Widget statusLine(String text, {IconData icon = Icons.info_outline}) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: AppColors.textSecondary),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: textStyle)),
        ],
      );
    }

    Widget body;
    if (_isLoadingFarmerStatus) {
      body = Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          const Text('جارٍ تحميل حالة المزارع...', style: textStyle),
        ],
      );
    } else if (_farmerStatusAwaitingSync) {
      body = statusLine('حالة المزارع ستظهر بعد مزامنته — يمكنك متابعة السقي');
    } else if (_farmerStatusError != null) {
      body = statusLine(_farmerStatusError!);
    } else if (_farmerStatus != null) {
      final s = _farmerStatus!;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // الدلالات نصية صريحة لا إشارات +/- ولا لون وحده (ق-131/11).
          statusLine(
            s.hasDebt
                ? 'عليه مديونية: '
                      '${CurrencyUtils.formatAmount(s.debtMinor)} ريال'
                : 'لا توجد مديونية',
            icon: Icons.payments_outlined,
          ),
          const SizedBox(height: 4),
          statusLine(
            s.hasAdvance
                ? 'له رصيد مقدم: '
                      '${CurrencyUtils.formatAmount(s.advanceMinor)} ريال'
                : 'لا يوجد رصيد مقدم',
            icon: Icons.savings_outlined,
          ),
          const SizedBox(height: 4),
          statusLine(
            'ديزل المزارع: '
            '${_formatLitres(s.farmerFuelBalanceMl)} لتر',
            icon: Icons.local_gas_station_outlined,
          ),
        ],
      );
    } else {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: body,
    );
  }

  Widget _buildFarmerReviewBanner() {
    final count = _activeWellReviews.length;
    final first = _activeWellReviews.first;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: AppColors.warning,
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  count == 1
                      ? 'مراجعة مطلوبة: ${first.fullName}'
                      : 'توجد $count عمليات تتطلب مراجعة هوية المزارع',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: AppColors.deepBlue,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'يوجد اشتباه تكرار مع مزارع مسجل. انقر لمراجعة وحسم الهوية.',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () {
              FarmerIdentityResolutionSheet.show(
                context,
                review: first,
                accountId: _accountId,
                coordinator: _coordinator,
                onResolved: _checkActiveWellReviews,
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.warning,
              foregroundColor: Colors.white,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
            child: const Text(
              'مراجعة',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Future<List<FarmerAccount>> _searchFarmers(String query) async {
    final durablePending = await _coordinator.pendingFarmers(
      accountId: _accountId,
      wellId: _activeWellId,
    );

    final q = query.trim();
    final matchingPending = durablePending.where((f) {
      if (q.isEmpty) return true;
      return f.fullName.contains(q) ||
          (f.phone != null && f.phone!.contains(q));
    }).toList();

    late final List<FarmerAccount> list;
    try {
      list = await _repo.fetchFarmers(_activeWellId, query: query);
    } catch (_) {
      throw SmartLookupSearchFailure<FarmerAccount>(
        availableLocalItems: matchingPending,
      );
    }

    matchingPending.removeWhere((f) {
      if (list.any((existing) => existing.id == f.entityReference.serverId)) {
        return true;
      }
      return false;
    });

    return [...matchingPending, ...list];
  }

  Future<List<Farm>> _searchFarms(String query) async {
    final selectedFarmer = _selectedFarmer;
    if (selectedFarmer == null) return [];

    final wellId = _activeWellId;
    final accountId = _accountId;
    final q = query.trim();

    final durablePending = await _coordinator.pendingFarms(
      accountId: accountId,
      wellId: wellId,
      farmerReference: selectedFarmer.entityReference,
    );

    final filteredPending = durablePending.where((f) {
      if (q.isEmpty) return true;
      return f.displayName.contains(q);
    }).toList();

    List<Farm> serverFarms = [];
    if (!selectedFarmer.isPending &&
        selectedFarmer.entityReference.serverId != null &&
        selectedFarmer.entityReference.serverId!.isNotEmpty) {
      try {
        serverFarms = await _repo.fetchFarms(
          wellId,
          farmerAccountId: selectedFarmer.entityReference.serverId,
        );
      } catch (_) {
        throw SmartLookupSearchFailure<Farm>(
          availableLocalItems: filteredPending,
        );
      }
    }

    final filteredServer = q.isEmpty
        ? serverFarms
        : serverFarms.where((f) => f.displayName.contains(q)).toList();

    filteredPending.removeWhere(
      (f) => serverFarms.any(
        (existing) => existing.id == f.entityReference.serverId,
      ),
    );

    return [...filteredPending, ...filteredServer];
  }

  Future<FarmerAccount?> _showAddFarmerDialog() async {
    final wellId = _activeWellId;
    final accountId = _accountId;

    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool isSubmitting = false;

    final created = await showDialog<FarmerAccount>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text(
            'إضافة مزارع جديد',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.deepBlue,
            ),
          ),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameController,
                  enabled: !isSubmitting,
                  decoration: const InputDecoration(
                    labelText: 'اسم المزارع الكامل *',
                    hintText: 'مثال: محمد صالح القاسمي',
                    prefixIcon: Icon(Icons.person),
                  ),
                  validator: (val) => (val == null || val.trim().isEmpty)
                      ? 'الاسم مطلوب'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: phoneController,
                  enabled: !isSubmitting,
                  keyboardType: TextInputType.phone,
                  inputFormatters: const [ArabicToEnglishDigitsFormatter()],
                  decoration: const InputDecoration(
                    labelText: 'رقم الهاتف (اختياري)',
                    hintText: '77XXXXXXX',
                    prefixIcon: Icon(Icons.phone),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSubmitting ? null : () => Navigator.of(ctx).pop(),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.waterBlue,
                foregroundColor: Colors.white,
              ),
              onPressed: isSubmitting
                  ? null
                  : () async {
                      if (!(formKey.currentState?.validate() ?? false)) return;

                      setDialogState(() => isSubmitting = true);
                      try {
                        final farmer = await _coordinator.enqueueFarmer(
                          accountId: accountId,
                          wellId: wellId,
                          fullName: nameController.text.trim(),
                          phone: phoneController.text.trim().isNotEmpty
                              ? phoneController.text.trim()
                              : null,
                        );
                        if (ctx.mounted) Navigator.of(ctx).pop(farmer);
                      } catch (e) {
                        setDialogState(() => isSubmitting = false);
                        _showActionFailure('تعذر إنشاء المزارع: $e');
                      }
                    },
              child: isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('حفظ وإضافة'),
            ),
          ],
        ),
      ),
    );

    await _checkActiveWellReviews();
    return created;
  }

  Future<Farm?> _showAddFarmDialog() async {
    if (_selectedFarmer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('يرجى اختيار المزارع أولاً لربط الأرض الزراعية به'),
          backgroundColor: AppColors.warning,
        ),
      );
      return null;
    }

    final wellId = _activeWellId;
    final accountId = _accountId;
    final selectedFarmer = _selectedFarmer!;

    final nameController = TextEditingController();
    final labelController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    bool isSubmitting = false;

    return showDialog<Farm>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            'إضافة أرض للمزارع: ${selectedFarmer.fullName}',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.deepBlue,
            ),
          ),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameController,
                  enabled: !isSubmitting,
                  decoration: const InputDecoration(
                    labelText: 'اسم الأرض الزراعية *',
                    hintText: 'مثال: الكوثة',
                    prefixIcon: Icon(Icons.landscape),
                  ),
                  validator: (val) => (val == null || val.trim().isEmpty)
                      ? 'اسم الأرض مطلوب'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: labelController,
                  enabled: !isSubmitting,
                  decoration: const InputDecoration(
                    labelText: 'صفة مميزة (اختياري)',
                    hintText: 'مثال: الشرقية أو الغربية',
                    prefixIcon: Icon(Icons.label_outline),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSubmitting ? null : () => Navigator.of(ctx).pop(),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.waterBlue,
                foregroundColor: Colors.white,
              ),
              onPressed: isSubmitting
                  ? null
                  : () async {
                      if (!(formKey.currentState?.validate() ?? false)) return;

                      setDialogState(() => isSubmitting = true);
                      try {
                        final farm = await _coordinator.enqueueFarm(
                          accountId: accountId,
                          wellId: wellId,
                          name: nameController.text.trim(),
                          distinguishingLabel:
                              labelController.text.trim().isNotEmpty
                              ? labelController.text.trim()
                              : null,
                          farmerReference: selectedFarmer.entityReference,
                        );
                        if (ctx.mounted) Navigator.of(ctx).pop(farm);
                      } catch (e) {
                        setDialogState(() => isSubmitting = false);
                        _showActionFailure('تعذر إنشاء الأرض: $e');
                      }
                    },
              child: isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('حفظ وإضافة'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startSession() async {
    if (_daySchedule?.currentSession != null) {
      _showActionFailure(
        'توجد جلسة محجوزة جارية على الخادم؛ لا يمكن بدء جلسة أخرى.',
      );
      return;
    }
    if (!_isFormComplete) {
      _showActionFailure(_missingFieldGuidance ?? 'يرجى إكمال الحقول المطلوبة');
      return;
    }

    final wellId = _activeWellId;
    final energySourceCode = _energySourceCode;
    if (energySourceCode == null) {
      _showActionFailure('يرجى تحديد مصدر الطاقة قبل بدء السقي');
      return;
    }

    setState(() => _isSubmitting = true);

    final String sessionLocalId;
    try {
      final envelope = await _coordinator.startSession(
        accountId: _accountId,
        wellId: wellId,
        pumpId: _selectedPump!.id,
        farmId: _selectedFarm!.id,
        farmerAccountId: _selectedFarmer!.id,
        farmReference: _selectedFarm!.entityReference,
        farmerReference: _selectedFarmer!.entityReference,
        energySource: energySourceCode,
        crops: List<String>.from(_selectedCrops),
        startedAt: _now(),
      );
      sessionLocalId = envelope.localId;
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showActionFailure('تعذر بدء الجلسة — لم يُسجَّل شيء: $e');
      return;
    }

    if (!mounted) return;

    _activeSessionId = sessionLocalId;
    _startLocalTicker();
    setState(() {
      _isSubmitting = false;
      _isSessionActive = true;
      _isPaused = false;
      _secondsElapsed = 0;
    });
  }

  Future<void> _togglePause() async {
    if (!_isSessionActive || !_beginSessionAction()) return;

    try {
      final sessionId = _activeSessionId;
      if (sessionId == null) {
        _showActionFailure('لا معرّف جلسة — تعذر تغيير حالة السقي');
        return;
      }

      final wasPaused = _isPaused;
      if (!wasPaused) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => const PauseConfirmationDialog(),
        );
        if (confirmed != true) return;

        try {
          await _coordinator.pauseSession(
            accountId: _accountId,
            sessionLocalId: sessionId,
            reason: 'operator_pause',
            pausedAt: _now(),
          );
        } catch (e) {
          _showActionFailure('تعذر الإيقاف المؤقت — الجلسة ما زالت جارية: $e');
          return;
        }
      } else {
        await _coordinator.resumeSession(
          accountId: _accountId,
          sessionLocalId: sessionId,
          resumedAt: _now(),
        );
      }

      if (!mounted) return;
      setState(() => _isPaused = !wasPaused);
    } catch (e) {
      _showActionFailure('تعذر الاستئناف — الجلسة ما زالت موقوفة: $e');
    } finally {
      _finishSessionAction();
    }
  }

  bool _beginSessionAction() {
    if (_isSessionActionInProgress || !mounted) return false;
    setState(() => _isSessionActionInProgress = true);
    return true;
  }

  void _finishSessionAction() {
    if (mounted) setState(() => _isSessionActionInProgress = false);
  }

  Future<void> _openActiveEnergySourcePicker() async {
    if (!_isSessionActive) return;
    if (!_beginSessionAction()) return;

    try {
      final selected = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => Material(
          color: Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const Text(
                    'تحويل مصدر الطاقة',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.deepBlue,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ...kSessionEnergySources.map((code) {
                    final isSelected = _energySourceCode == code;
                    final rate = _ruleFor(code)?.hourlyRateMinor;
                    final glyph = energySourceGlyph(code);
                    final label = energySourceLabel(code);

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: isSelected
                            ? AppColors.waterBlue.withValues(alpha: 0.08)
                            : AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => Navigator.of(sheetContext).pop(code),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected
                                    ? AppColors.waterBlue
                                    : AppColors.border,
                                width: isSelected ? 1.5 : 1,
                              ),
                            ),
                            child: ListTile(
                              leading: Text(
                                glyph,
                                style: const TextStyle(fontSize: 22),
                              ),
                              title: Text(
                                label,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                  color: AppColors.deepBlue,
                                ),
                              ),
                              subtitle: rate == null
                                  ? const Text(
                                      'التسعيرة غير متوفرة',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppColors.warning,
                                      ),
                                    )
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${CurrencyUtils.formatAmount(rate)} ريال / ساعة',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.textSecondary,
                                          ),
                                        ),
                                        Text(
                                          Tafqeet.format(rate),
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: AppColors.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                              trailing: isSelected
                                  ? const Icon(
                                      Icons.check_circle,
                                      color: AppColors.waterBlue,
                                      size: 20,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        ),
      );
      if (selected != null) await _changeEnergySource(selected);
    } finally {
      _finishSessionAction();
    }
  }

  Future<void> _changeEnergySource(String newSource) async {
    if (_energySourceCode == newSource) return;

    final sessionId = _activeSessionId;
    if (_isSessionActive && sessionId != null) {
      // ق-129 / C3 / C4: طلب التأكيد قبل التحويل الفعلي
      final rate = _ruleFor(newSource)?.hourlyRateMinor;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => EnergyChangeConfirmationDialog(
          currentSource: _energySourceCode ?? 'solar',
          newSource: newSource,
          newRateMinor: rate,
          isPaused: _isPaused,
        ),
      );

      if (confirmed != true) return;

      try {
        await _coordinator.changeEnergySource(
          accountId: _accountId,
          sessionLocalId: sessionId,
          newEnergySource: newSource,
          changedAt: _now(),
        );
      } catch (e) {
        _showActionFailure('تعذر تغيير مصدر الطاقة — لم يتغيّر شيء: $e');
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _energySourceCode = newSource;
    });
  }

  Future<void> _endSession() async {
    if (!_beginSessionAction()) return;
    try {
      final activeSession = _activeSession;
      final activeSessionId = _activeSessionId;

      if (activeSessionId == null || activeSession == null) {
        _showActionFailure('تعذر قراءة الجلسة — لم يُحسب مبلغ ولم يصدر سند');
        return;
      }

      final endedWellId = activeSession.wellId;
      final endedAccountId = activeSession.accountId;
      final paymentFarmerId = activeSession.farmerReference;
      final operatorDisplayName = widget.identity.displayName;
      final endedWell = widget.identity.wells
          .where((well) => well.id == endedWellId)
          .firstOrNull;
      final endedWellName = endedWell?.name ?? 'بئر غير محدد';

      // ق-129 / E3: لقطة زمنية موحدة لحساب المقاطع وأمر الإغلاق
      final completedAt = _now();
      final totals = summarize(activeSession.segments, completedAt);
      final totalSeconds = totals.billableSeconds;
      final totalAmount = totals.accruedMinor;
      final sourceSummaries = calculateSourceSummaries(
        activeSession.segments,
        completedAt,
      );

      final hours = (totalSeconds ~/ 3600).toString().padLeft(2, '0');
      final minutes = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
      final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
      final durationText = '$hours:$minutes:$seconds';

      final farmerDisplayName = _selectedFarmer?.fullName ?? 'مزارع غير محدد';
      final farmDisplayName = _selectedFarm?.name ?? 'أرض غير محددة';

      // ق-129 / E2: تأكيد صريح قبل استدعاء completeSession
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => EndSessionConfirmationDialog(
          farmerName: farmerDisplayName,
          farmName: farmDisplayName,
          totalDurationText: durationText,
          sourceSummaries: sourceSummaries,
          totalAmountMinor: totalAmount,
        ),
      );

      if (confirmed != true) {
        return;
      }

      _timer?.cancel();
      _timer = null;

      late final CommandEnvelope completionEnvelope;
      try {
        completionEnvelope = await _coordinator.completeSession(
          accountId: _accountId,
          sessionLocalId: activeSessionId,
          completedAt: completedAt,
        );
      } catch (e) {
        _showActionFailure('تعذر إنهاء الجلسة — لم يُسجَّل شيء ولا سند: $e');
        _startLocalTicker();
        return;
      }

      // ق-129 / E6: إعادة ضبط النموذج للعملية التالية
      final solePump = _pumps.length == 1 ? _pumps.single : null;

      setState(() {
        _isSessionActive = false;
        _isPaused = false;
        _secondsElapsed = 0;
        _activeSessionId = null;
        _activeSession = null;
        _selectedFarmer = null;
        _selectedFarm = null;
        _energySourceCode = null;
        _selectedPump = solePump;
        _resetCropSelection();
        _resetFarmerStatus();
      });

      if (!mounted) return;

      // ق-129 / E4: ملخص ما بعد الإنهاء منفصل عن السداد
      final wantsPayment = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PostEndSessionSummaryDialog(
          farmerName: farmerDisplayName,
          farmName: farmDisplayName,
          totalDurationText: durationText,
          sourceSummaries: sourceSummaries,
          totalAmountMinor: totalAmount,
          crops: activeSession.crops,
          canRecordPayment: endedWellId != null && paymentFarmerId != null,
        ),
      );

      // ق-129 / E5: تسجيل الدفعة اختياري وبطلب صريح
      if (wantsPayment == true &&
          mounted &&
          totalAmount != null &&
          totalAmount > 0) {
        final billableSegments = activeSession.segments
            .where((segment) => segment.kind == SegmentKind.running)
            .toList(growable: false);
        final sources = billableSegments
            .map((segment) => segment.energySource)
            .toSet();
        final rates = billableSegments
            .map((segment) => segment.hourlyRateMinor)
            .toSet();
        final usesCompositePricing = sources.length > 1 || rates.length > 1;
        final singleHourlyRate = usesCompositePricing
            ? null
            : billableSegments.firstOrNull?.hourlyRateMinor;
        final singleEnergySource = sources.length == 1 ? sources.single : null;

        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => PaymentReceiptDialog(
            wellName: endedWellName,
            operatorName: operatorDisplayName,
            farmerName: farmerDisplayName,
            farmName: farmDisplayName,
            energySource: usesCompositePricing
                ? 'مصادر متعددة'
                : energySourceLabel(singleEnergySource ?? _energySourceCode),
            hourlyRateYER: singleHourlyRate,
            billableSeconds: totalSeconds,
            // الفعلي من حصيلة المقاطع نفسها (كامل الخط الزمني قبل
            // الإنهاء) — عرضٌ فقط لا يدخل في أي حساب مالي (ق-131).
            actualSeconds: totals.wallClockSeconds,
            totalAmountYER: totalAmount,
            onConfirmPayment:
                ({
                  required int paidAmountYER,
                  required String paymentMethod,
                  required bool isFullySettled,
                }) async {
                  if (paidAmountYER <= 0) return;

                  if (endedWellId == null || paymentFarmerId == null) {
                    throw StateError(
                      'هوية الجلسة غير مكتملة — لم يُسجَّل السداد',
                    );
                  }

                  await _coordinator.recordPayment(
                    accountId: endedAccountId,
                    wellId: endedWellId,
                    farmerAccountId: paymentFarmerId,
                    amountMinor: paidAmountYER,
                    paymentMethod: paymentMethod,
                    sessionLocalId: activeSessionId,
                    sessionCompletionLocalId: completionEnvelope.localId,
                    note: 'سداد جلسة سقي',
                  );
                },
          ),
        );
      }
    } finally {
      _finishSessionAction();
    }
  }

  Widget? _buildPricingStateNotice() {
    if (_isLoadingSchedule) {
      return const Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'جاري قراءة التسعيرة السارية...',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
        ],
      );
    }

    if (_pricingForbidden) {
      return _buildPricingNotice(
        icon: Icons.lock_outline,
        color: AppColors.textSecondary,
        message:
            'التسعيرة السارية متاحة لمن يملك إدارة الأسعار — '
            'التشغيل متاح، وتُحتسب التكلفة عند المزامنة.',
      );
    }

    final error = _scheduleError;
    if (error != null) {
      return _buildPricingNotice(
        icon: Icons.error_outline,
        color: AppColors.error,
        message: 'تعذر قراءة التسعيرة السارية — لا تُعرض تسعيرة: $error',
        onRetry: _loadPriceSchedule,
      );
    }

    if (_priceRules.isEmpty) {
      return _buildPricingNotice(
        icon: Icons.info_outline,
        color: AppColors.warning,
        message:
            'لا جدول تسعير ساري لهذا البئر — لا تُعرض تسعيرة، '
            'وتُحتسب التكلفة عند المزامنة.',
        onRetry: _loadPriceSchedule,
      );
    }

    return null;
  }

  Widget _buildPricingNotice({
    required IconData icon,
    required Color color,
    required String message,
    VoidCallback? onRetry,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: const Text(
                'إعادة المحاولة',
                style: TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  bool _isPendingChangeWhilePaused(ActiveSessionRecord? activeSession) {
    if (!_isPaused || activeSession == null) return false;
    final segments = activeSession.segments;
    final openIndex = segments.lastIndexWhere((s) => s.isOpen);
    if (openIndex < 0) return false;
    final open = segments[openIndex];
    for (var i = openIndex - 1; i >= 0; i--) {
      if (segments[i].kind == SegmentKind.running) {
        return segments[i].energySource != open.energySource;
      }
    }
    return false;
  }

  String _energySourceContextText(ActiveSessionRecord? activeSession) {
    final code = _energySourceCode;
    final label = energySourceLabel(code);
    final glyph = energySourceGlyph(code);

    if (!_isSessionActive) return '$glyph $label';

    if (!_isPaused) {
      return '$glyph $label — الآن';
    }

    if (_isPendingChangeWhilePaused(activeSession)) {
      return 'عند الاستئناف: $label';
    }

    return 'آخر مصدر: $label';
  }

  String _energySourceDetailLabel(ActiveSessionRecord? activeSession) {
    if (!_isPaused) {
      return 'مصدر الطاقة الحالي:';
    }
    if (_isPendingChangeWhilePaused(activeSession)) {
      return 'مصدر الطاقة عند الاستئناف:';
    }
    return 'آخر مصدر طاقة مستخدم:';
  }

  String _pumpStatusText(String status) => switch (status) {
    'active' => 'نشطة',
    'inactive' => 'غير نشطة',
    'maintenance' => 'تحت الصيانة',
    'retired' => 'مسحوبة من الخدمة',
    _ => 'حالة غير معروفة',
  };

  Widget _buildReadOnlyDetailRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.waterBlue),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: AppColors.deepBlue,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeSession = _activeSession;
    final serverCurrentSession = _daySchedule?.currentSession;
    final hasServerOnlySession =
        !_isSessionActive && serverCurrentSession != null;
    final hasAnyActiveSession = _isSessionActive || hasServerOnlySession;
    final liveTotals = activeSession == null
        ? null
        : summarize(activeSession.segments, _now());
    final displaySeconds = liveTotals?.billableSeconds ?? _secondsElapsed;
    final accruedAmount = liveTotals?.accruedMinor;

    final hours = (displaySeconds ~/ 3600).toString().padLeft(2, '0');
    final minutes = ((displaySeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final seconds = (displaySeconds % 60).toString().padLeft(2, '0');

    // ق-129 / B5: حالة المزامنة الحقيقية
    final syncState = activeSession?.syncState ?? SessionSyncState.localOnly;
    final isSynced = syncState == SessionSyncState.synced;

    // ق-129 / C2: ملخص المصادر التراكمي للمقاطع المحتسبة
    final sourceSummaries = activeSession != null
        ? calculateSourceSummaries(activeSession.segments, _now())
        : const <SourceUsageSummary>[];

    final currentRate = _ruleFor(_energySourceCode)?.hourlyRateMinor;

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: TopWellSelector(
          wells: widget.identity.wells,
          activeWell: _activeWell,
          subtitle: 'لوحة تشغيل السقي والمناوبة',
          onWellChanged: (newWell) {
            setState(() {
              _activeWell = newWell;
              _selectedFarmer = null;
              _selectedFarm = null;
              _selectedPump = null;
              _pumps = [];
              _energySourceCode = null;
              _activeSession = null;
              _isSessionActive = false;
              _activeSessionId = null;
              _resetCropSelection();
              _resetFarmerStatus();
              _daySchedule = null;
              _bookingAutomation = null;
              _dayScheduleError = null;
              _bookingAutomationError = null;
              _pendingAutomationCommandId = null;
              _pendingAutomationTarget = null;
              _pendingAutomationRevision = null;
              _pendingStartCommandIds.clear();
              _startingBookingId = null;
            });
            _loadPumps();
            _loadPriceSchedule();
            _recoverActiveSession();
            _checkActiveWellReviews();
            _loadBookingOverview();
            if (widget.onWellChanged != null) {
              widget.onWellChanged!(newWell);
            }
          },
        ),
        actions: [
          if (widget.onLogout != null)
            IconButton(
              icon: const Icon(Icons.logout, color: AppColors.textSecondary),
              tooltip: 'تسجيل الخروج',
              onPressed: widget.onLogout,
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_activeWellReviews.isNotEmpty) ...[
                _buildFarmerReviewBanner(),
                const SizedBox(height: 16),
              ],
              // 1. كرت حالة الجلسة والعداد المباشر (استجابة مرنة بدون تجاوز ق-129 / B6)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: hasAnyActiveSession
                        ? (_isPaused
                              ? AppColors.warning
                              : AppColors.agriculturalGreen)
                        : AppColors.border,
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    // رأس الكرت (Wrap مرن يمنع الـ Overflow)
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: hasAnyActiveSession
                                    ? (_isPaused
                                          ? AppColors.warning
                                          : AppColors.agriculturalGreen)
                                    : AppColors.textMuted,
                              ),
                            ),
                            Text(
                              _isSessionActive
                                  ? (_isPaused
                                        ? SessionStateText.paused
                                        : SessionStateText.running)
                                  : hasServerOnlySession
                                  ? 'توجد جلسة محجوزة جارية على الخادم'
                                  : 'لا توجد جلسة سقي نشطة',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: hasAnyActiveSession
                                    ? (_isPaused
                                          ? AppColors.warning
                                          : AppColors.agriculturalGreen)
                                    : AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                        if (_isSessionActive)
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              // شارة المزامنة الحقيقية (ق-129 / B5)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: isSynced
                                      ? AppColors.agriculturalGreen.withValues(
                                          alpha: 0.08,
                                        )
                                      : AppColors.surface,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: isSynced
                                        ? AppColors.agriculturalGreen
                                              .withValues(alpha: 0.3)
                                        : AppColors.border,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      isSynced
                                          ? Icons.cloud_done_outlined
                                          : Icons.cloud_queue_outlined,
                                      size: 13,
                                      color: isSynced
                                          ? AppColors.agriculturalGreen
                                          : AppColors.textSecondary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      syncState.text,
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: isSynced
                                            ? AppColors.agriculturalGreen
                                            : AppColors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // شارة مصدر الطاقة الحالي (ق-129 / C1)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: AppColors.border),
                                ),
                                child: Text(
                                  _energySourceContextText(activeSession),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.deepBlue,
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // عداد الوقت المباشر
                    Text(
                      hasServerOnlySession ? '--:--:--' : '$hours:$minutes:$seconds',
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        color: _isSessionActive
                            ? (_isPaused
                                  ? AppColors.warning
                                  : AppColors.deepBlue)
                            : AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 10),

                    // المبلغ المالي اللحظي والتفقيط (ق-129 / B4 / A7)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        children: [
                          Wrap(
                            alignment: WrapAlignment.center,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              const Text(
                                'المبلغ: ',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (activeSession == null)
                                const Text(
                                  'لا مبلغ لجلسة نشطة',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.textSecondary,
                                  ),
                                )
                              else if (accruedAmount == null)
                                const Text(
                                  SessionStateText.pricingPending,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.warning,
                                  ),
                                )
                              else ...[
                                Text(
                                  CurrencyUtils.formatAmount(accruedAmount),
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.agriculturalGreen,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Text(
                                  'ريال',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.agriculturalGreen,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (accruedAmount != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              Tafqeet.format(accruedAmount),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    // تفصيل أوقات المصادر التراكمية للجلسة الجارية (ق-129 / C2)
                    if (_isSessionActive && sourceSummaries.isNotEmpty) ...[
                      if (hasServerOnlySession) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'هذه الجلسة بدأت من حجز عبر الخادم. التحكم الميداني المحلي بها سيُربط في جولة Offline التالية.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 12,
                          runSpacing: 4,
                          children: sourceSummaries
                              .map(
                                (s) => Text(
                                  '${s.shortLabel} ${s.formattedDuration}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    fontFamily: 'monospace',
                                    color: AppColors.deepBlue,
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ],

                    // لقطة المحاصيل المختارة عند بدء الجلسة، لا اقتراحات
                    // الأرض الحالية ولا قيمة مشتقة بعد ذلك.
                    if (_isSessionActive &&
                        activeSession != null &&
                        activeSession.crops.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.eco_outlined,
                              size: 18,
                              color: AppColors.agriculturalGreen,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'المحاصيل: ${activeSession.crops.join('، ')}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.deepBlue,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // زر تحويل الطاقة في الجلسة الجارية (ق-129 / C3 / C4)
                    if (_isSessionActive) ...[
                      const SizedBox(height: 6),
                      TextButton.icon(
                        onPressed: _isSessionActionInProgress
                            ? null
                            : _openActiveEnergySourcePicker,
                        icon: const Icon(
                          Icons.swap_horiz,
                          size: 16,
                          color: AppColors.waterBlue,
                        ),
                        label: const Text(
                          'تحويل مصدر الطاقة',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: AppColors.waterBlue,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // 2. نموذج الإدخال قبل الجلسة (A) أو التفاصيل للقراءة فقط أثناء الجلسة (B1)
              if (!hasAnyActiveSession)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'بيانات ومحددات السقي',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppColors.deepBlue,
                        ),
                      ),
                      const SizedBox(height: 16),

                      // أ) مكوّن البحث الذكي عن المزارع (A1, A2)
                      SmartLookupField<FarmerAccount>(
                        label: 'المزارع المستفيد *',
                        hintText: 'ابحث باسم المزارع أو رقم هاتفه...',
                        prefixIcon: Icons.person_outline,
                        enabled: true,
                        autofocusSearch: false,
                        selectedItem: _selectedFarmer,
                        itemLabel: (f) => f.fullName,
                        itemSecondaryLabel: (f) {
                          if (f.isPending) return 'محفوظ على الجهاز';
                          if (f.phone != null && f.phone!.isNotEmpty) {
                            return 'هاتف: ${f.phone}';
                          }
                          return null;
                        },
                        searchFunction: _searchFarmers,
                        onChanged: (farmer) {
                          setState(() {
                            _selectedFarmer = farmer;
                            _selectedFarm = null;
                            _resetCropSelection();
                            // حالة المزارع تُصفَّر فورًا مع كل تغيير
                            // (ق-131 البند 11) ثم تُحمَّل للاختيار الجديد.
                            _resetFarmerStatus();
                          });
                          if (farmer != null) _loadFarmerStatus();
                        },
                        onAddNew: _showAddFarmerDialog,
                        addNewLabel: 'إضافة مزارع جديد',
                      ),
                      const SizedBox(height: 14),

                      // حالة المزارع المختار (ق-131 البند 11): ملخص
                      // إخباري غير مانع أسفل منتقي المزارع وقبل منتقي
                      // الأرض — لا يحجب بدء السقي في أي حال.
                      if (_selectedFarmer != null) ...[
                        _buildFarmerStatusArea(),
                        const SizedBox(height: 14),
                      ],

                      // ب) مكوّن البحث الذكي عن الأرض الزراعية (A3)
                      SmartLookupField<Farm>(
                        label: 'الأرض الزراعية *',
                        hintText: _selectedFarmer != null
                            ? 'ابحث باسم الأرض...'
                            : 'يرجى اختيار المزارع أولاً',
                        prefixIcon: Icons.landscape_outlined,
                        enabled: _selectedFarmer != null,
                        autofocusSearch: false,
                        selectedItem: _selectedFarm,
                        itemLabel: (f) => f.displayName,
                        itemSecondaryLabel: (f) =>
                            f.isPending ? 'محفوظ على الجهاز' : null,
                        searchFunction: _searchFarms,
                        onChanged: (farm) {
                          setState(() {
                            _selectedFarm = farm;
                            _resetCropSelection();
                          });
                          if (farm != null) _loadFarmCrops();
                        },
                        onAddNew: _showAddFarmDialog,
                        addNewLabel: 'إضافة أرض جديدة',
                      ),

                      // د) المحاصيل (ق-131 البند 1): تظهر بعد اختيار الأرض.
                      // الاقتراحات محاصيل جلسات هذه الأرض السابقة، والاختيار
                      // حر غير مانع، والبدء بلا محاصيل ممكن.
                      if (_selectedFarm != null) ...[
                        const SizedBox(height: 14),
                        const Text(
                          'المحاصيل',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: AppColors.deepBlue,
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (_cropsError != null)
                          Row(
                            children: [
                              const Icon(
                                Icons.error_outline_rounded,
                                color: AppColors.error,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _cropsError!,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.error,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: _loadFarmCrops,
                                child: const Text('إعادة'),
                              ),
                            ],
                          )
                        else if (_isLoadingCrops)
                          const Center(
                            child: Padding(
                              padding: EdgeInsets.all(8),
                              child: CircularProgressIndicator(),
                            ),
                          )
                        else ...[
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final crop in _cropChoices)
                                FilterChip(
                                  label: Text(crop),
                                  selected: _selectedCrops.contains(crop),
                                  onSelected: (_) => _toggleCrop(crop),
                                ),
                            ],
                          ),
                          // ملخص ما قبل البدء: المختار صريحًا قبل زر البدء.
                          if (_selectedCrops.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                'المحاصيل المختارة: '
                                '${_selectedCrops.join('، ')}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.agriculturalGreen,
                                ),
                              ),
                            ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _newCropController,
                                  textInputAction: TextInputAction.done,
                                  onSubmitted: (_) => _addNewCrop(),
                                  decoration: InputDecoration(
                                    hintText: 'إضافة محصول جديد...',
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: const BorderSide(
                                        color: AppColors.border,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'إضافة المحصول',
                                onPressed: _addNewCrop,
                                icon: const Icon(Icons.add_circle_outline),
                                color: AppColors.agriculturalGreen,
                              ),
                            ],
                          ),
                        ],
                      ],
                      const SizedBox(height: 14),

                      // ج) اختيار المضخة العاملة (A4)
                      const Text(
                        'المضخة العاملة *',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppColors.deepBlue,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _isLoadingPumps
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(8),
                                child: CircularProgressIndicator(),
                              ),
                            )
                          : _pumpsError != null
                          ? Row(
                              children: [
                                const Icon(
                                  Icons.error_outline_rounded,
                                  color: AppColors.error,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _pumpsError!,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.error,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: _loadPumps,
                                  child: const Text('إعادة'),
                                ),
                              ],
                            )
                          : DropdownButtonFormField<Pump>(
                              initialValue: _selectedPump,
                              isExpanded: true,
                              hint: const Text(
                                'اختر المضخة...',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppColors.textMuted,
                                ),
                              ),
                              decoration: InputDecoration(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: const BorderSide(
                                    color: AppColors.border,
                                  ),
                                ),
                                prefixIcon: const Icon(
                                  Icons.water,
                                  color: AppColors.waterBlue,
                                ),
                              ),
                              items: _pumps
                                  .map(
                                    (p) => DropdownMenuItem(
                                      value: p,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              p.name,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                                color: AppColors.deepBlue,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            '— ${_pumpStatusText(p.status)}',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: AppColors.textSecondary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (val) =>
                                  setState(() => _selectedPump = val),
                            ),
                      const SizedBox(height: 14),

                      // د) محدد الطاقة والتسعير المدمج (A5, A6)
                      const Text(
                        'مصدر الطاقة والتسعيرة *',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppColors.deepBlue,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (_buildPricingStateNotice() != null) ...[
                        _buildPricingStateNotice()!,
                        const SizedBox(height: 8),
                      ],
                      CompactEnergySelector(
                        selectedSource: _energySourceCode,
                        priceRules: _priceRules,
                        onSourceSelected: (src) =>
                            setState(() => _energySourceCode = src),
                        enabled: true,
                      ),
                    ],
                  ),
                )
              else if (hasServerOnlySession)
                Container(
                  key: const Key('server-booking-session-notice'),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.agriculturalGreen.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppColors.agriculturalGreen.withValues(alpha: 0.25),
                    ),
                  ),
                  child: const Text(
                    'يوجد حجز جارٍ مثبت على الخادم، لذلك حُجب بدء أي جلسة أخرى. تفاصيل التحكم المحلي ستُستكمل في جولة Offline التالية.',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else
                // تفاصيل الجلسة الحالية للقراءة فقط (B1)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'تفاصيل الجلسة الحالية',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppColors.deepBlue,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _buildReadOnlyDetailRow(
                        icon: Icons.person_outline,
                        label: 'المزارع المستفيد:',
                        value: _selectedFarmer?.fullName ?? 'مزارع غير محدد',
                      ),
                      const Divider(height: 16),
                      _buildReadOnlyDetailRow(
                        icon: Icons.landscape_outlined,
                        label: 'الأرض الزراعية:',
                        value: _selectedFarm?.name ?? 'أرض غير محددة',
                      ),
                      const Divider(height: 16),
                      _buildReadOnlyDetailRow(
                        icon: Icons.water,
                        label: 'المضخة العاملة:',
                        value: _selectedPump?.name ?? 'مضخة غير محددة',
                      ),
                      const Divider(height: 16),
                      _buildReadOnlyDetailRow(
                        icon: Icons.bolt,
                        label: _energySourceDetailLabel(activeSession),
                        value:
                            '${energySourceLabel(_energySourceCode)} ${energySourceGlyph(_energySourceCode)}',
                      ),
                      if (currentRate != null) ...[
                        const Divider(height: 16),
                        _buildReadOnlyDetailRow(
                          icon: Icons.payments_outlined,
                          label: 'التعرفة السارية:',
                          value:
                              '${CurrencyUtils.formatAmount(currentRate)} ريال / ساعة\n${Tafqeet.format(currentRate)}',
                        ),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: 24),

              // 3. أزرار التحكم الرئيسية بالجلسة
              if (hasServerOnlySession)
                const Text(
                  'لا يمكن بدء جلسة جديدة أو إرسال أوامر محلية حتى تتم مصالحة الجلسة الجارية مع الهاتف.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.warning,
                    fontWeight: FontWeight.w700,
                  ),
                )
              else if (!_isSessionActive) ...[
                // إرشاد الحقل الناقص (A8)
                if (!_isFormComplete && _missingFieldGuidance != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _missingFieldGuidance!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: AppColors.warning,
                      ),
                    ),
                  ),
                ElevatedButton.icon(
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.play_arrow, size: 24),
                  label: Text(
                    _isSubmitting ? 'جاري بدء الجلسة...' : 'بدء جلسة سقي جديدة',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.agriculturalGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  onPressed: (!_isFormComplete || _isSubmitting)
                      ? null
                      : _startSession,
                ),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
                        label: Text(
                          _isPaused ? 'استئناف' : 'إيقاف مؤقت',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isPaused
                              ? AppColors.agriculturalGreen
                              : AppColors.warning,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _isSessionActionInProgress
                            ? null
                            : _togglePause,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.stop),
                        label: const Text(
                          'إنهاء الجلسة',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.error,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _isSessionActionInProgress
                            ? null
                            : _endSession,
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 24),
              TodayBookingsPanel(
                schedule: _daySchedule,
                automation: _bookingAutomation,
                isLoadingSchedule: _isLoadingDaySchedule,
                isLoadingAutomation: _isLoadingBookingAutomation,
                isUpdatingAutomation: _isUpdatingBookingAutomation,
                canManageAutomation: _activeWell.isOperator,
                hasLocalActiveSession: _isSessionActive,
                scheduleError: _dayScheduleError,
                automationError: _bookingAutomationError,
                startingBookingId: _startingBookingId,
                onRefresh: () {
                  _loadBookingOverview();
                },
                onToggleAutomation: (enabled) {
                  _toggleBookingAutomation(enabled);
                },
                onStartBooking: _startBookingFromSchedule,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

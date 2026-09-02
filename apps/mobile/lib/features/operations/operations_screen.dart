import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api/app_bootstrap_repository.dart';
import '../../core/api/operations_repository.dart';
import '../../core/api/well_management_repository.dart';
import '../../core/session/active_session_projector.dart';
import '../../core/session/offline_session_coordinator.dart';
import '../../core/session/session_business_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/currency_utils.dart';
import '../../core/utils/digit_utils.dart';
import '../../core/widgets/currency_display.dart';
import '../../core/widgets/smart_lookup_field.dart';
import '../../core/widgets/top_well_selector.dart';
import 'widgets/payment_receipt_dialog.dart';


/// شاشة تشغيل البئر وجلسات السقي الميدانية (UX-07 / UX-08 / ق-88 / ق-114)
class OperationsScreen extends StatefulWidget {
  const OperationsScreen({
    required this.wellName,
    this.wellId,
    this.wells = const [],
    this.operatorName = 'المشغل',
    this.coordinator,
    this.priceRepository,
    this.onWellChanged,
    this.onLogout,
    super.key,
  });

  final String wellName;
  final String? wellId;
  final List<WellSummary> wells;
  final String operatorName;
  final OfflineSessionCoordinator? coordinator;

  /// مستودع قراءة جدول التسعير الساري. يُمرَّر في الاختبار، وفي التشغيل
  /// يُبنى افتراضيًا — والعقد هو `api.get_active_price_schedule`.
  final WellManagementRepository? priceRepository;
  final ValueChanged<WellSummary>? onWellChanged;
  final VoidCallback? onLogout;

  @override
  State<OperationsScreen> createState() => _OperationsScreenState();
}

class _OperationsScreenState extends State<OperationsScreen> {
  late OperationsRepository _repo;
  late OfflineSessionCoordinator _coordinator;
  late WellManagementRepository _priceRepo;

  String? _activeWellId;
  String _activeWellName = '';

  // خيارات الجلسة
  FarmerAccount? _selectedFarmer;
  Farm? _selectedFarm;
  Pump? _selectedPump;
  List<Pump> _pumps = [];

  /// رمز مصدر الطاقة كما تعرّفه القاعدة: `solar` / `well_diesel` /
  /// `farmer_diesel` (م-41D6). كان نصًّا عربيًّا من قيمتين يُرسل حرفيًّا إلى
  /// `p_energy_source`، فـ«ديزل» واحدة تجمع مصدرين مختلفَي السعر ولا يقبلها
  /// قيد القاعدة أصلًا. الخيارات من `kSessionEnergySources` لا من قواعد
  /// السعر: المصدر قرار تشغيلي، والسعر وحده يأتي من العقد.
  String? _energySourceCode = kSessionEnergySources.first;

  /// جدول التسعير الساري لهذا البئر كما أعادته `api.get_active_price_schedule`.
  /// `null` يعني «لا جدول معروف»: لا تُعرض تسعيرة ولا يُخمَّن رقم (القرار 341).
  PriceScheduleModel? _priceSchedule;
  bool _isLoadingSchedule = false;
  String? _scheduleError;

  /// القراءة رُفضت بـ`42501`: حالة صلاحية مشروعة لا خطأ يُعاد. `price.manage`
  /// للمالك وحده (هجرة 091)، فالمشغل يشغّل ولا يرى التسعيرة، ويُحتسب المال
  /// خادميًّا عند المزامنة.
  bool _pricingForbidden = false;

  /// قواعد السعر السارية. مصدر السعر المعروض وحده، لا مصدر خيارات المصدر.
  List<PriceRuleModel> get _priceRules => _priceSchedule?.rules ?? const [];

  /// قاعدة سعر هذا المصدر إن وُجدت في الجدول الساري.
  PriceRuleModel? _ruleFor(String? code) {
    if (code == null) return null;
    for (final rule in _priceRules) {
      if (rule.energySource == code) return rule;
    }
    return null;
  }

  /// السعر الساعي للمصدر المختار، أو `null` إذا لم يُعده العقد.
  ///
  /// `null` حالة مشروعة معلنة، لا صفر ولا رقم افتراضي: قاعدة السعر قد تكون
  /// بلا `hourly_rate_minor` (تسعير ديزل بالوقود)، وقد لا يكون للبئر جدول
  /// ساري، وقد لا يملك المشغل صلاحية قراءة الأسعار أصلًا.
  int? get _hourlyRateYER => _ruleFor(_energySourceCode)?.hourlyRateMinor;

  // حالة الجلسة المباشرة
  Timer? _timer;
  bool _isSessionActive = false;
  bool _isPaused = false;
  int _secondsElapsed = 0;
  String? _activeSessionId;
  bool _isLoadingPumps = false;
  String? _pumpsError;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _activeWellName = widget.wellName;
    _activeWellId = widget.wellId ?? (widget.wells.isNotEmpty ? widget.wells.first.id : null);
    _coordinator = widget.coordinator ?? OfflineSessionCoordinator.instance;
    _priceRepo = widget.priceRepository ?? WellManagementRepository();

    try {
      _repo = OperationsRepository(Supabase.instance.client);
    } catch (_) {
      _repo = const OperationsRepository();
    }

    _recoverActiveSession();

    if (_activeWellId != null) {
      _loadPumps();
      _loadPriceSchedule();
    }
  }

  /// إظهار فشل إجراء **دون** تغيير الحالة المعروضة (ق-113 / م-41B3B).
  ///
  /// كل كتابات الجلسة كانت تُبتلع في مصيدة استثناء فارغة ثم تُغيَّر الحالة
  /// على الشاشة، فيرى المشغّل إيقافًا أو إنهاءً لم يُسجَّل في أي مكان.
  void _showActionFailure(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.error),
    );
  }

  /// إعلان حالة صريحة ليست فشلًا: العمل سُجِّل، وما لم يُنجز يُقال كما هو.
  void _showNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.warning),
    );
  }

  /// قراءة جدول التسعير الساري للبئر النشط — `api.get_active_price_schedule`.
  ///
  /// لا سعر افتراضي في العميل (م-41D6 / ق-99): إن غاب الجدول أو فشلت
  /// القراءة تبقى التسعيرة غير معلومة وتُعرض كذلك، ولا تُخمَّن. والقواعد
  /// نفسها تُغذّي مُسقط الجلسة الحية حتى يكون للمال مصدر واحد.
  ///
  /// القراءة لا تُغيّر مصدر الطاقة المختار: الاختيار قرار المشغل، وبيانات
  /// التسعير لا تُعيد توجيهه ولا تمحوه.
  Future<void> _loadPriceSchedule() async {
    final wellId = _activeWellId;
    if (wellId == null) return;

    setState(() {
      _isLoadingSchedule = true;
      _scheduleError = null;
      _pricingForbidden = false;
    });

    try {
      final schedule = await _priceRepo.fetchActivePriceSchedule(wellId);
      if (!mounted) return;
      setState(() {
        _priceSchedule = schedule;
        _isLoadingSchedule = false;
      });
      _coordinator.updatePricing(_snapshotsFrom(schedule));
    } on PostgrestException catch (e) {
      if (!mounted) return;
      // 42501 = المشغل لا يملك `price.manage`. لا تسعيرة تُعرض، والتشغيل
      // يستمر: الخادم هو من يُسعّر المقطع عند المزامنة (هجرة 066).
      final forbidden = e.code == '42501';
      setState(() {
        _priceSchedule = null;
        _isLoadingSchedule = false;
        _pricingForbidden = forbidden;
        _scheduleError = forbidden ? null : e.message;
      });
      _coordinator.updatePricing(const []);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _priceSchedule = null;
        _isLoadingSchedule = false;
        _scheduleError = '$e';
      });
      _coordinator.updatePricing(const []);
    }
  }

  /// تحويل قواعد الجدول إلى لقطات تسعير للمُسقط. القاعدة بلا سعر ساعي
  /// تُستبعد فيبقى المقطع «بانتظار المزامنة» بدل أن يُسعَّر بصفر.
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
    final active = await _coordinator.projectActiveSession(
      accountId: 'active-user',
      wellId: _activeWellId,
    );

    if (active != null && mounted) {
      setState(() {
        _isSessionActive = true;
        _isPaused = active.businessState == SessionBusinessState.paused;
        _secondsElapsed = active.totals.billableSeconds;
        _activeSessionId = active.localId;
        _energySourceCode = active.currentEnergySource ?? _energySourceCode;
      });

      _startLocalTicker();
    }
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
    if (widget.wellId != oldWidget.wellId || widget.wellName != oldWidget.wellName) {
      setState(() {
        _activeWellName = widget.wellName;
        _activeWellId = widget.wellId ?? (widget.wells.isNotEmpty ? widget.wells.first.id : null);
        _selectedFarmer = null;
        _selectedFarm = null;
      });
      if (_activeWellId != null) {
        _loadPumps();
        _loadPriceSchedule();
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadPumps() async {
    if (_activeWellId == null) return;
    setState(() {
      _isLoadingPumps = true;
      _pumpsError = null;
    });

    try {
      final pumps = await _repo.fetchPumps(_activeWellId!);
      if (mounted) {
        setState(() {
          _pumps = pumps;
          if (pumps.isNotEmpty && _selectedPump == null) {
            _selectedPump = pumps.first;
          }
          _isLoadingPumps = false;
        });
      }
    } catch (_) {
      // م-41C1: لا مضخة وهمية — الفشل يمنع بدء الجلسة ويظهر صريحًا.
      if (mounted) {
        setState(() {
          _pumps = [];
          _selectedPump = null;
          _isLoadingPumps = false;
          _pumpsError = 'تعذّر تحميل المضخات. تحقق من الاتصال ثم أعد المحاولة.';
        });
      }
    }
  }

  Future<List<FarmerAccount>> _searchFarmers(String query) async {
    if (_activeWellId == null) {
      throw StateError('لا يوجد بئر نشط لقراءة المزارعين');
    }
    return _repo.fetchFarmers(_activeWellId!, query: query);
  }

  Future<List<Farm>> _searchFarms(String query) async {
    if (_activeWellId == null) {
      throw StateError('لا يوجد بئر نشط لقراءة الأراضي');
    }
    final farms = await _repo.fetchFarms(
      _activeWellId!,
      farmerAccountId: _selectedFarmer?.id,
    );
    if (query.isEmpty) return farms;
    return farms.where((f) => f.name.contains(query)).toList();
  }

  Future<FarmerAccount?> _showAddFarmerDialog() async {
    final wellId = _activeWellId;
    if (wellId == null) {
      _showActionFailure('اختر البئر أولًا — لا يُنشأ مزارع بلا بئر');
      return null;
    }

    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final notesController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    return showDialog<FarmerAccount>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'إضافة مزارع جديد',
          style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.deepBlue),
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'اسم المزارع الكامل *',
                  hintText: 'مثال: محمد صالح القاسمي',
                  prefixIcon: Icon(Icons.person),
                ),
                validator: (val) =>
                    (val == null || val.trim().isEmpty) ? 'الاسم مطلوب' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                inputFormatters: const [ArabicToEnglishDigitsFormatter()],
                decoration: const InputDecoration(
                  labelText: 'رقم الهاتف (اختياري)',
                  hintText: '77XXXXXXX',
                  prefixIcon: Icon(Icons.phone),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: notesController,
                decoration: const InputDecoration(
                  labelText: 'ملاحظات (اختياري)',
                  prefixIcon: Icon(Icons.notes),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.waterBlue,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              if (!(formKey.currentState?.validate() ?? false)) return;

              try {
                final farmer = await _repo.createFarmer(
                  wellId: wellId,
                  fullName: nameController.text.trim(),
                  phone: phoneController.text.trim().isNotEmpty
                      ? phoneController.text.trim()
                      : null,
                  notes: notesController.text.trim().isNotEmpty
                      ? notesController.text.trim()
                      : null,
                );
                if (ctx.mounted) Navigator.of(ctx).pop(farmer);
              } catch (e) {
                // لا مزارع مُلفَّق (F-NEW) عند الفشل: النافذة تبقى مفتوحة
                // والخطأ يظهر، فلا يدخل الجلسة معرّف لا وجود له في القاعدة.
                _showActionFailure('تعذر إنشاء المزارع: $e');
              }
            },
            child: const Text('حفظ وإضافة'),
          ),
        ],
      ),
    );
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
    if (wellId == null) {
      _showActionFailure('اختر البئر أولًا — لا تُنشأ أرض بلا بئر');
      return null;
    }

    final nameController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    return showDialog<Farm>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'إضافة أرض للمزارع: ${_selectedFarmer!.fullName}',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppColors.deepBlue,
          ),
        ),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: 'اسم الأرض الزراعية *',
              hintText: 'مثال: مزرعة الوادي الشرقي',
              prefixIcon: Icon(Icons.landscape),
            ),
            validator: (val) =>
                (val == null || val.trim().isEmpty) ? 'اسم الأرض مطلوب' : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.waterBlue,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              if (!(formKey.currentState?.validate() ?? false)) return;

              try {
                final farm = await _repo.createFarm(
                  wellId: wellId,
                  name: nameController.text.trim(),
                  farmerAccountId: _selectedFarmer!.id,
                );
                if (ctx.mounted) Navigator.of(ctx).pop(farm);
              } catch (e) {
                // لا أرض مُلفَّقة على بئر افتراضي عند الفشل: النافذة تبقى
                // مفتوحة، فلا تدخل الجلسة أرضٌ لا وجود لها في القاعدة.
                _showActionFailure('تعذر إنشاء الأرض: $e');
              }
            },
            child: const Text('حفظ وإضافة'),
          ),
        ],
      ),
    );
  }

  Future<void> _startSession() async {
    if (_selectedFarmer == null || _selectedFarm == null || _selectedPump == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('يرجى تحديد المزارع والأرض والمضخة قبل بدء السقي'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    final wellId = _activeWellId;
    if (wellId == null) {
      _showActionFailure('لا بئر نشط — لا تُبدأ جلسة سقي بلا بئر');
      return;
    }

    // مصدر الطاقة رمز قاعدة صالح، لا نصّ عربي ترفضه هجرة 066 (م-41D6).
    // ولا يُشترط سعر معلوم لبدء الجلسة: `ops.start_irrigation_session` لا
    // تأخذ سعرًا وتفوّض على الدور لا على `price.manage`، فمنع البدء لغياب
    // التسعيرة منعٌ لعمل يقبله الخادم.
    final energySourceCode = _energySourceCode;
    if (energySourceCode == null) {
      _showActionFailure('يرجى تحديد مصدر الطاقة قبل بدء السقي');
      return;
    }

    setState(() => _isSubmitting = true);

    final String sessionLocalId;
    try {
      final envelope = await _coordinator.startSession(
        accountId: 'active-user',
        wellId: wellId,
        pumpId: _selectedPump!.id,
        farmId: _selectedFarm!.id,
        farmerAccountId: _selectedFarmer!.id,
        energySource: energySourceCode,
      );
      sessionLocalId = envelope.localId;
    } catch (e) {
      // جلسة لم تدخل الطابور لا تُعرض كجارية: العداد لا يبدأ (ق-113).
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
    if (!_isSessionActive) return;

    final sessionId = _activeSessionId;
    if (sessionId == null) {
      _showActionFailure('لا معرّف جلسة — تعذر تغيير حالة السقي');
      return;
    }

    final wasPaused = _isPaused;
    try {
      if (!wasPaused) {
        await _coordinator.pauseSession(
          accountId: 'active-user',
          sessionLocalId: sessionId,
          reason: 'إيقاف مؤقت من المشغل',
        );
      } else {
        await _coordinator.resumeSession(
          accountId: 'active-user',
          sessionLocalId: sessionId,
        );
      }
    } catch (e) {
      // الحالة المعروضة تتبع ما سُجِّل، لا ما نُقر عليه.
      _showActionFailure(
        wasPaused
            ? 'تعذر الاستئناف — الجلسة ما زالت موقوفة: $e'
            : 'تعذر الإيقاف المؤقت — الجلسة ما زالت جارية: $e',
      );
      return;
    }

    if (!mounted) return;
    setState(() => _isPaused = !wasPaused);
  }

  Future<void> _changeEnergySource(String newSource) async {
    if (_energySourceCode == newSource) return;

    final sessionId = _activeSessionId;
    if (_isSessionActive && sessionId != null) {
      try {
        await _coordinator.changeEnergySource(
          accountId: 'active-user',
          sessionLocalId: sessionId,
          newEnergySource: newSource,
        );
      } catch (e) {
        // تغيير لم يُسجَّل لا يُعرض كمُطبَّق: المصدر والتسعيرة يبقيان.
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
    _timer?.cancel();
    _timer = null;

    final totalSeconds = _secondsElapsed;
    final hourlyRate = _hourlyRateYER;
    final totalAmount =
        hourlyRate == null ? null : (hourlyRate * totalSeconds) ~/ 3600;
    final activeSessionId = _activeSessionId;

    if (activeSessionId == null) {
      // جلسة معروضة بلا معرّف: لا سند قبض لمجهول (ق-113).
      _showActionFailure('لا معرّف جلسة — تعذر الإنهاء وإصدار سند القبض');
      _startLocalTicker();
      return;
    }

    try {
      await _coordinator.completeSession(
        accountId: 'active-user',
        sessionLocalId: activeSessionId,
      );
    } catch (e) {
      // إنهاء لم يُسجَّل: الجلسة ما زالت جارية، فيعود العداد ولا يُصدر سند.
      _showActionFailure('تعذر إنهاء الجلسة — لم يُسجَّل شيء ولا سند: $e');
      _startLocalTicker();
      return;
    }

    setState(() {
      _isSessionActive = false;
      _isPaused = false;
      _secondsElapsed = 0;
      _activeSessionId = null;
    });

    if (mounted) {
      // سند قبض بلا سعر معلوم = مبلغ مُخترع. الجلسة انتهت وسُجِّلت، والمستحق
      // يحسمه الخادم بسعر وقت الحدث، فيُقال ذلك صريحًا بلا رقم (القرار 341).
      if (hourlyRate == null || totalAmount == null) {
        _showNotice(
          'انتهت الجلسة وسُجِّلت. لا تسعيرة سارية لهذا المصدر، '
          'فلا سند قبض من هنا — ${SessionStateText.pricingPending}',
        );
        return;
      }

      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PaymentReceiptDialog(
          wellName: _activeWellName,
          operatorName: widget.operatorName,
          farmerName: _selectedFarmer?.fullName ?? 'مزارع غير محدد',
          farmName: _selectedFarm?.name ?? 'أرض غير محددة',
          energySource: energySourceLabel(_energySourceCode),
          hourlyRateYER: hourlyRate,
          billableSeconds: totalSeconds,
          totalAmountYER: totalAmount,
          onConfirmPayment: ({
            required int paidAmountYER,
            required String paymentMethod,
            required bool isFullySettled,
          }) async {
            if (paidAmountYER <= 0) return;

            final paymentWellId = _activeWellId;
            final farmer = _selectedFarmer;
            if (paymentWellId == null || farmer == null) {
              // كان السداد يُتجاهل صامتًا فتُغلق النافذة كأنه سُجِّل.
              throw StateError('لا بئر أو مزارع محدد — لم يُسجَّل السداد');
            }

            await _coordinator.recordPayment(
              accountId: 'active-user',
              wellId: paymentWellId,
              farmerAccountId: farmer.id,
              amountMinor: paidAmountYER,
              paymentMethod: paymentMethod,
              sessionLocalId: activeSessionId,
              reference: 'سداد جلسة سقي',
            );
          },
        ),
      );
    }
  }


  /// خيارات مصدر الطاقة وسعرها.
  ///
  /// الخيارات هي مصادر القاعدة الثلاثة (`kSessionEnergySources`) لأن اختيار
  /// المصدر قرار تشغيلي يملكه المشغل، والسعر وحده من `api.get_active_price_schedule`:
  /// لا زرّين ثابتين ولا سعرين مكتوبين في العميل، وغياب السعر يُعرض كغياب
  /// لا كصفر (م-41D6 / ق-99 / القرار 341).
  Widget _buildEnergySourceSelector() {
    final options = Wrap(
      spacing: 10,
      runSpacing: 10,
      children: kSessionEnergySources
          .map(_buildEnergySourceOption)
          .toList(growable: false),
    );

    final notice = _buildPricingStateNotice();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (notice != null) ...[notice, const SizedBox(height: 10)],
        options,
      ],
    );
  }

  /// حالة قراءة التسعيرة: تُعلن ما جرى فوق الأزرار ولا تحجبها.
  ///
  /// `null` يعني «الجدول الساري مقروء»، فلا لافتة.
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
          Text(
            'جاري قراءة التسعيرة السارية...',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      );
    }

    if (_pricingForbidden) {
      // ليست فشلًا فلا زرّ إعادة محاولة: صلاحية الأسعار للمالك.
      return _buildPricingNotice(
        icon: Icons.lock_outline,
        color: AppColors.textSecondary,
        message: 'التسعيرة السارية متاحة لمن يملك إدارة الأسعار — '
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
        message: 'لا جدول تسعير ساري لهذا البئر — لا تُعرض تسعيرة، '
            'وتُحتسب التكلفة عند المزامنة.',
        onRetry: _loadPriceSchedule,
      );
    }

    return null;
  }

  /// صندوق حالة التسعيرة: يقول ما جرى، ويعرض «إعادة المحاولة» للفشل وحده.
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
              child:
                  const Text('إعادة المحاولة', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  /// خيار واحد = مصدر طاقة تقبله القاعدة. الاسم من الخريطة المعتمدة
  /// `kEnergySourceLabels` (لا Blind Remap: الرمز المجهول يُعرض كما هو)،
  /// والسعر من قاعدة الجدول الساري أو «غير متوفرة» إن لم تُعرف.
  Widget _buildEnergySourceOption(String code) {
    final isSelected = _energySourceCode == code;
    final rate = _ruleFor(code)?.hourlyRateMinor;
    final glyph = code == 'solar' ? '☀️' : '⛽';

    return SizedBox(
      width: 160,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: isSelected
              ? AppColors.waterBlue.withValues(alpha: 0.1)
              : Colors.white,
          side: BorderSide(
            color: isSelected ? AppColors.waterBlue : AppColors.border,
            width: isSelected ? 2 : 1,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        onPressed: () => _changeEnergySource(code),
        child: Column(
          children: [
            Text(
              '${energySourceLabel(code)} $glyph',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: AppColors.deepBlue,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              rate == null
                  ? 'التسعيرة غير متوفرة'
                  : '${CurrencyUtils.formatAmount(rate)} ريال / ساعة',
              style: TextStyle(
                fontSize: 11,
                color:
                    rate == null ? AppColors.warning : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hourlyRate = _hourlyRateYER;
    final accruedAmount =
        hourlyRate == null ? null : (hourlyRate * _secondsElapsed) ~/ 3600;

    final hours = (_secondsElapsed ~/ 3600).toString().padLeft(2, '0');
    final minutes = ((_secondsElapsed % 3600) ~/ 60).toString().padLeft(2, '0');
    final seconds = (_secondsElapsed % 60).toString().padLeft(2, '0');

    // لا بئر مُلفَّق (معرّف افتراضي ومستأجر وأدوار مُفترضة): إن لم يكن البئر
    // النشط داخل آبار المستخدم فلا بئر، والشريط العلوي يقول ذلك صراحةً.
    final matchingWells = widget.wells.where((w) => w.id == _activeWellId);
    final WellSummary? activeWellSummary =
        matchingWells.isEmpty ? null : matchingWells.first;

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: TopWellSelector(
          wells: widget.wells,
          activeWell: activeWellSummary,
          subtitle: 'لوحة تشغيل السقي والمناوبة',
          onWellChanged: (newWell) {
            setState(() {
              _activeWellId = newWell.id;
              _activeWellName = newWell.name;
              _selectedFarmer = null;
              _selectedFarm = null;
            });
            _loadPumps();
            _loadPriceSchedule();
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
              // 1. كرت حالة الجلسة والعداد المباشر
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _isSessionActive
                        ? (_isPaused ? AppColors.warning : AppColors.agriculturalGreen)
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _isSessionActive
                                    ? (_isPaused ? AppColors.warning : AppColors.agriculturalGreen)
                                    : AppColors.textMuted,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _isSessionActive
                                  ? (_isPaused ? 'جلسة سقي متوقفة مؤقتاً' : 'جلسة سقي جارية الآن')
                                  : 'لا توجد جلسة سقي نشطة',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: _isSessionActive
                                    ? (_isPaused ? AppColors.warning : AppColors.agriculturalGreen)
                                    : AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            if (_isSessionActive) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppColors.agriculturalGreen.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.cloud_done_outlined, size: 13, color: AppColors.agriculturalGreen),
                                    SizedBox(width: 4),
                                    Text(
                                      'مزامن',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.agriculturalGreen,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  energySourceLabel(_energySourceCode),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.deepBlue,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // عداد الوقت المباشر
                    Text(
                      '$hours:$minutes:$seconds',
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        color: _isSessionActive
                            ? (_isPaused ? AppColors.warning : AppColors.deepBlue)
                            : AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 10),

                    // المستحق المالي اللحظي
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            'المستحق اللحظي: ',
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          // لا «0 ريال» ولا رقم مخمَّن حين يغيب السعر:
                          // النصّ المعتمد وحده (القرار 341 / م-41D6).
                          if (accruedAmount == null)
                            const Text(
                              SessionStateText.pricingPending,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: AppColors.warning,
                              ),
                            )
                          else
                            CurrencyDisplay(
                              amount: accruedAmount,
                              amountStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: AppColors.agriculturalGreen,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // 2. محددات الجلسة (المزارع والأرض والمضخة ومصدر الطاقة)
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

                    // أ) مكوّن البحث الذكي عن المزارع (SmartLookupField)
                    SmartLookupField<FarmerAccount>(
                      label: 'المزارع المستفيد *',
                      hintText: 'ابحث باسم المزارع أو رقم هاتفه...',
                      prefixIcon: Icons.person_outline,
                      enabled: !_isSessionActive,
                      selectedItem: _selectedFarmer,
                      itemLabel: (f) => f.fullName,
                      itemSecondaryLabel: (f) =>
                          'كود: ${f.publicCode}${f.phone != null ? " • هاتف: ${f.phone}" : ""}',
                      searchFunction: _searchFarmers,
                      onChanged: (farmer) {
                        setState(() {
                          _selectedFarmer = farmer;
                          _selectedFarm = null; // إعادة تعيين الأرض لتوافقها مع المزارع
                        });
                      },
                      onAddNew: _showAddFarmerDialog,
                      addNewLabel: 'إضافة مزارع جديد',
                    ),
                    const SizedBox(height: 14),

                    // ب) مكوّن البحث الذكي عن الأرض الزراعية (SmartLookupField)
                    SmartLookupField<Farm>(
                      label: 'الأرض الزراعية *',
                      hintText: _selectedFarmer != null
                          ? 'اختر أرض المزارع...'
                          : 'يرجى اختيار المزارع أولاً',
                      prefixIcon: Icons.landscape_outlined,
                      enabled: !_isSessionActive && _selectedFarmer != null,
                      selectedItem: _selectedFarm,
                      itemLabel: (f) => f.name,
                      searchFunction: _searchFarms,
                      onChanged: (farm) => setState(() => _selectedFarm = farm),
                      onAddNew: _showAddFarmDialog,
                      addNewLabel: 'إضافة أرض جديدة',
                    ),
                    const SizedBox(height: 14),

                    // ج) اختيار المضخة
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
                            decoration: InputDecoration(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: AppColors.border),
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
                                    child: Text(
                                      '${p.name} (${p.publicCode})',
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.deepBlue,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: _isSessionActive
                                ? null
                                : (val) => setState(() => _selectedPump = val),
                          ),
                    const SizedBox(height: 14),

                    // د) مصدر الطاقة والتسعير اللحظي
                    const Text(
                      'مصدر الطاقة والتسعيرة',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: AppColors.deepBlue,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildEnergySourceSelector(),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // 3. أزرار التحكم الرئيسية بالجلسة
              if (!_isSessionActive)
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
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
                  onPressed: _isSubmitting ? null : _startSession,
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
                        label: Text(
                          _isPaused ? 'استئناف السقي' : 'إيقاف مؤقت',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              _isPaused ? AppColors.agriculturalGreen : AppColors.warning,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _togglePause,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.stop),
                        label: const Text(
                          'إنهاء واحتساب',
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
                        onPressed: _endSession,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

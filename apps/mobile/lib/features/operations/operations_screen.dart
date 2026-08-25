import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api/app_bootstrap_repository.dart';
import '../../core/api/operations_repository.dart';
import '../../core/session/offline_session_coordinator.dart';
import '../../core/session/session_business_state.dart';
import '../../core/theme/app_colors.dart';
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
    this.onWellChanged,
    this.onLogout,
    super.key,
  });

  final String wellName;
  final String? wellId;
  final List<WellSummary> wells;
  final String operatorName;
  final OfflineSessionCoordinator? coordinator;
  final ValueChanged<WellSummary>? onWellChanged;
  final VoidCallback? onLogout;

  @override
  State<OperationsScreen> createState() => _OperationsScreenState();
}

class _OperationsScreenState extends State<OperationsScreen> {
  late OperationsRepository _repo;
  late OfflineSessionCoordinator _coordinator;

  String? _activeWellId;
  String _activeWellName = '';

  // خيارات الجلسة
  FarmerAccount? _selectedFarmer;
  Farm? _selectedFarm;
  Pump? _selectedPump;
  List<Pump> _pumps = [];
  String _currentEnergySource = 'طاقة شمسية';
  int _hourlyRate = 3500;

  // حالة الجلسة المباشرة
  Timer? _timer;
  bool _isSessionActive = false;
  bool _isPaused = false;
  int _secondsElapsed = 0;
  String? _activeSessionId;
  bool _isLoadingPumps = false;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _activeWellName = widget.wellName;
    _activeWellId = widget.wellId ?? (widget.wells.isNotEmpty ? widget.wells.first.id : null);
    _coordinator = widget.coordinator ?? OfflineSessionCoordinator.instance;

    try {
      _repo = OperationsRepository(Supabase.instance.client);
    } catch (_) {
      _repo = const OperationsRepository();
    }

    _recoverActiveSession();

    if (_activeWellId != null) {
      _loadPumps();
    }
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
        _currentEnergySource = active.currentEnergySource ?? _currentEnergySource;
        _hourlyRate = _currentEnergySource == 'طاقة شمسية' ? 3500 : 5000;
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
    setState(() => _isLoadingPumps = true);

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
      if (mounted) {
        setState(() {
          _pumps = [
            const Pump(
              id: 'mock-pump-1',
              wellId: 'well-1',
              name: 'المضخة الرئيسية 1',
              publicCode: 'P-01',
            ),
          ];
          _selectedPump = _pumps.first;
          _isLoadingPumps = false;
        });
      }
    }
  }

  Future<List<FarmerAccount>> _searchFarmers(String query) async {
    if (_activeWellId == null) {
      return [
        const FarmerAccount(
          id: 'mock-farmer-1',
          fullName: 'محمد علي الحبيشي',
          publicCode: 'F-001',
          phone: '771234567',
        ),
        const FarmerAccount(
          id: 'mock-farmer-2',
          fullName: 'صالح أحمد الشامي',
          publicCode: 'F-002',
          phone: '772345678',
        ),
      ];
    }

    try {
      return await _repo.fetchFarmers(_activeWellId!, query: query);
    } catch (_) {
      return [
        const FarmerAccount(
          id: 'mock-farmer-1',
          fullName: 'محمد علي الحبيشي',
          publicCode: 'F-001',
          phone: '771234567',
        ),
        const FarmerAccount(
          id: 'mock-farmer-2',
          fullName: 'صالح أحمد الشامي',
          publicCode: 'F-002',
          phone: '772345678',
        ),
      ];
    }
  }

  Future<List<Farm>> _searchFarms(String query) async {
    if (_activeWellId == null) {
      return [
        const Farm(
          id: 'mock-farm-1',
          wellId: 'well-1',
          name: 'مزرعة الوادي الكبير',
        ),
      ];
    }

    try {
      final farms = await _repo.fetchFarms(
        _activeWellId!,
        farmerAccountId: _selectedFarmer?.id,
      );
      if (query.isEmpty) return farms;
      return farms.where((f) => f.name.contains(query)).toList();
    } catch (_) {
      return [
        const Farm(
          id: 'mock-farm-1',
          wellId: 'well-1',
          name: 'مزرعة الوادي الكبير',
        ),
      ];
    }
  }

  Future<FarmerAccount?> _showAddFarmerDialog() async {
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
              if (formKey.currentState?.validate() ?? false) {
                if (_activeWellId != null) {
                  try {
                    final farmer = await _repo.createFarmer(
                      wellId: _activeWellId!,
                      fullName: nameController.text.trim(),
                      phone: phoneController.text.trim().isNotEmpty
                          ? phoneController.text.trim()
                          : null,
                      notes: notesController.text.trim().isNotEmpty
                          ? notesController.text.trim()
                          : null,
                    );
                    if (ctx.mounted) Navigator.of(ctx).pop(farmer);
                    return;
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('تعذر إنشاء المزارع: $e')),
                      );
                    }
                  }
                } else {
                  final mock = FarmerAccount(
                    id: 'new-${DateTime.now().millisecondsSinceEpoch}',
                    fullName: nameController.text.trim(),
                    publicCode: 'F-NEW',
                    phone: phoneController.text.trim(),
                  );
                  Navigator.of(ctx).pop(mock);
                }
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
              if (formKey.currentState?.validate() ?? false) {
                if (_activeWellId != null) {
                  try {
                    final farm = await _repo.createFarm(
                      wellId: _activeWellId!,
                      name: nameController.text.trim(),
                      farmerAccountId: _selectedFarmer!.id,
                    );
                    if (ctx.mounted) Navigator.of(ctx).pop(farm);
                    return;
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('تعذر إنشاء الأرض: $e')),
                      );
                    }
                  }
                } else {
                  final mock = Farm(
                    id: 'new-farm-${DateTime.now().millisecondsSinceEpoch}',
                    wellId: 'well-1',
                    name: nameController.text.trim(),
                    farmerAccountId: _selectedFarmer!.id,
                  );
                  Navigator.of(ctx).pop(mock);
                }
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

    setState(() => _isSubmitting = true);

    try {
      if (_activeWellId != null) {
        final envelope = await _coordinator.startSession(
          accountId: 'active-user',
          wellId: _activeWellId!,
          pumpId: _selectedPump!.id,
          farmId: _selectedFarm!.id,
          farmerAccountId: _selectedFarmer!.id,
          energySource: _currentEnergySource,
        );
        _activeSessionId = envelope.localId;
      }
    } catch (_) {
      // Fallback
    }

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

    if (!_isPaused) {
      // إيقاف مؤقت
      if (_activeSessionId != null) {
        try {
          await _coordinator.pauseSession(
            accountId: 'active-user',
            sessionLocalId: _activeSessionId!,
            reason: 'إيقاف مؤقت من المشغل',
          );
        } catch (_) {}
      }
      setState(() => _isPaused = true);
    } else {
      // استئناف
      if (_activeSessionId != null) {
        try {
          await _coordinator.resumeSession(
            accountId: 'active-user',
            sessionLocalId: _activeSessionId!,
          );
        } catch (_) {}
      }
      setState(() => _isPaused = false);
    }
  }

  Future<void> _changeEnergySource(String newSource) async {
    if (_currentEnergySource == newSource) return;

    if (_isSessionActive && _activeSessionId != null) {
      try {
        await _coordinator.changeEnergySource(
          accountId: 'active-user',
          sessionLocalId: _activeSessionId!,
          newEnergySource: newSource,
        );
      } catch (_) {}
    }

    setState(() {
      _currentEnergySource = newSource;
      _hourlyRate = newSource == 'طاقة شمسية' ? 3500 : 5000;
    });
  }

  Future<void> _endSession() async {
    _timer?.cancel();
    _timer = null;

    final totalSeconds = _secondsElapsed;
    final totalAmount = (_hourlyRate * totalSeconds) ~/ 3600;
    final activeSessionId = _activeSessionId;

    if (activeSessionId != null) {
      try {
        await _coordinator.completeSession(
          accountId: 'active-user',
          sessionLocalId: activeSessionId,
        );
      } catch (_) {}
    }

    setState(() {
      _isSessionActive = false;
      _isPaused = false;
      _secondsElapsed = 0;
      _activeSessionId = null;
    });

    if (mounted) {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PaymentReceiptDialog(
          wellName: _activeWellName,
          operatorName: widget.operatorName,
          farmerName: _selectedFarmer?.fullName ?? 'المزارع',
          farmName: _selectedFarm?.name ?? 'الأرض الزراعية',
          energySource: _currentEnergySource,
          hourlyRateYER: _hourlyRate,
          billableSeconds: totalSeconds,
          totalAmountYER: totalAmount,
          onConfirmPayment: ({
            required int paidAmountYER,
            required String paymentMethod,
            required bool isFullySettled,
          }) async {
            if (paidAmountYER > 0 && _activeWellId != null && _selectedFarmer != null) {
              await _coordinator.recordPayment(
                accountId: 'active-user',
                wellId: _activeWellId!,
                farmerAccountId: _selectedFarmer!.id,
                amountMinor: paidAmountYER,
                paymentMethod: paymentMethod,
                sessionLocalId: activeSessionId,
                reference: 'سداد جلسة سقي',
              );
            }
          },
        ),
      );
    }
  }


  @override
  Widget build(BuildContext context) {
    final accruedAmount = (_hourlyRate * _secondsElapsed) ~/ 3600;

    final hours = (_secondsElapsed ~/ 3600).toString().padLeft(2, '0');
    final minutes = ((_secondsElapsed % 3600) ~/ 60).toString().padLeft(2, '0');
    final seconds = (_secondsElapsed % 60).toString().padLeft(2, '0');

    final activeWellSummary = widget.wells.firstWhere(
      (w) => w.id == _activeWellId,
      orElse: () => WellSummary(
        id: _activeWellId ?? 'well-1',
        tenantId: 'tenant-1',
        name: _activeWellName,
        status: 'active',
        roles: const ['owner', 'operator'],
      ),
    );

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: TopWellSelector(
          wells: widget.wells.isNotEmpty ? widget.wells : [activeWellSummary],
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
                                  _currentEnergySource,
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
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              backgroundColor: _currentEnergySource == 'طاقة شمسية'
                                  ? AppColors.waterBlue.withValues(alpha: 0.1)
                                  : Colors.white,
                              side: BorderSide(
                                color: _currentEnergySource == 'طاقة شمسية'
                                    ? AppColors.waterBlue
                                    : AppColors.border,
                                width: _currentEnergySource == 'طاقة شمسية' ? 2 : 1,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: () => _changeEnergySource('طاقة شمسية'),
                            child: const Column(
                              children: [
                                Text(
                                  'طاقة شمسية ☀️',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.deepBlue,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  '3,500 ريال / ساعة',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              backgroundColor: _currentEnergySource == 'ديزل'
                                  ? AppColors.waterBlue.withValues(alpha: 0.1)
                                  : Colors.white,
                              side: BorderSide(
                                color: _currentEnergySource == 'ديزل'
                                    ? AppColors.waterBlue
                                    : AppColors.border,
                                width: _currentEnergySource == 'ديزل' ? 2 : 1,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: () => _changeEnergySource('ديزل'),
                            child: const Column(
                              children: [
                                Text(
                                  'ديزل شامل ⛽',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.deepBlue,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  '5,000 ريال / ساعة',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/api/app_bootstrap_repository.dart';
import '../../core/api/auth_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/currency_utils.dart';
import '../../core/utils/digit_utils.dart';
import '../../core/widgets/currency_text_form_field.dart';

/// نموذج بيانات معالج إنشاء البئر وإعداده (UX-03)
class WellSetupData {
  // 1. حساب المالك
  String ownerFullName = '';
  String ownerPhone = '';
  String ownerPassword = '';

  // 2. بيانات البئر الأساسية
  String wellName = '';
  String governorate = 'صنعاء';
  String district = '';
  String village = '';

  // 3. الشركاء والملكيات
  double ownerEquityShare = 100.0;
  double ownerProfitShare = 100.0;
  List<PartnerData> partners = [];

  // 4. المشغلون
  List<OperatorData> operators = [];

  // 5. المضخة ومصادر الطاقة
  String pumpName = 'المضخة الرئيسية';
  bool enableSolar = true;
  int solarHourlyRate = 3500;

  bool enableWellDiesel = false;
  int wellDieselHourlyRate = 7000;

  bool enableFarmerDiesel = false;
  int farmerDieselHourlyRate = 6000;
}

class PartnerData {
  PartnerData({
    required this.fullName,
    required this.phone,
    required this.equityShare,
    required this.profitShare,
    this.initialPassword = '',
  });

  String fullName;
  String phone;
  double equityShare;
  double profitShare;
  String initialPassword;
}

class OperatorData {
  OperatorData({
    required this.fullName,
    required this.phone,
    this.initialPassword = '',
  });

  String fullName;
  String phone;
  String initialPassword;
}

Map<String, int> buildWellSetupPricing({
  required bool enableSolar,
  required int solarHourlyRate,
  required bool enableWellDiesel,
  required int wellDieselHourlyRate,
  required bool enableFarmerDiesel,
  required int farmerDieselHourlyRate,
}) {
  return {
    'solar_rate_minor': enableSolar ? solarHourlyRate : 0,
    'well_diesel_rate_minor': enableWellDiesel ? wellDieselHourlyRate : 0,
    'farmer_diesel_rate_minor': enableFarmerDiesel ? farmerDieselHourlyRate : 0,
  };
}

typedef WellSetupBackendSubmission = Future<void> Function(WellSetupData data);

class WellSetupSubmissionResult {
  const WellSetupSubmissionResult._({
    required this.succeeded,
    required this.message,
  });

  static const success = WellSetupSubmissionResult._(
    succeeded: true,
    message: 'تم إنشاء البئر وحساب المالك في قاعدة البيانات بنجاح!',
  );

  static const failure = WellSetupSubmissionResult._(
    succeeded: false,
    message: 'تعذر إنشاء البئر. تحقق من الاتصال وحاول مرة أخرى.',
  );

  /// فشل بسبب **يعرفه الخادم**، فيُعرض كما هو بدل «تحقق من الاتصال».
  ///
  /// أُضيف في 2026-09-04 بعد أول تسجيل حقيقي على الإنتاج: الخادم رفض
  /// بسببين مختلفين (نطاق بريد الهوية غير صالح، ثم كلمة مرور غير مقبولة)
  /// والشاشة قالت في الحالتين «تحقق من الاتصال» — والاتصال قائم. رسالةٌ
  /// تُخفي السبب الحقيقي تُوجّه المستخدم إلى إصلاح ما ليس معطوبًا، وهي وجهٌ
  /// من عائلة النجاح الكاذب: نصٌّ لا يطابق الحقيقة التي يعرفها النظام.
  factory WellSetupSubmissionResult.serverRejected(String reason) {
    return WellSetupSubmissionResult._(
      succeeded: false,
      message: 'تعذر إنشاء البئر: $reason',
    );
  }

  final bool succeeded;
  final String message;
}

class WellSetupSubmissionFlow {
  const WellSetupSubmissionFlow(this._submitToBackend);

  final WellSetupBackendSubmission _submitToBackend;

  Future<WellSetupSubmissionResult> submit(
    WellSetupData data, {
    required VoidCallback onCompleted,
    required VoidCallback close,
  }) async {
    try {
      await _submitToBackend(data);
      onCompleted();
      close();
      return WellSetupSubmissionResult.success;
    } catch (error) {
      debugPrint('Setup error: $error');
      // خطأ من نظام المصادقة أو من عقد القاعدة يحمل سببًا صريحًا كتبه
      // الخادم: يُعرض للإنسان بدل تعميمٍ يرسله إلى إصلاح الاتصال السليم.
      if (error is AuthException) {
        return WellSetupSubmissionResult.serverRejected(error.message);
      }
      if (error is PostgrestException) {
        return WellSetupSubmissionResult.serverRejected(error.message);
      }
      return WellSetupSubmissionResult.failure;
    }
  }
}

/// شاشة معالج إنشاء بئر جديد وإعداده (UX-03)
///
/// المراحل الخمس المعتمدة:
/// 1. حساب المالك والتحقق (القرارات 158–164).
/// 2. بيانات البئر الأساسية (القرار 166).
/// 3. الشركاء والملكيات (القرار 167).
/// 4. فريق التشغيل (القرار 168).
/// 5. تجهيز التشغيل - المضخة ومصادر الطاقة (القرارات 169–171).
class CreateWellWizardScreen extends StatefulWidget {
  const CreateWellWizardScreen({
    this.onCompleted,
    this.submissionFlow,
    super.key,
  });

  final VoidCallback? onCompleted;
  final WellSetupSubmissionFlow? submissionFlow;

  @override
  State<CreateWellWizardScreen> createState() => _CreateWellWizardScreenState();
}

class _CreateWellWizardScreenState extends State<CreateWellWizardScreen> {
  final _setupData = WellSetupData();
  int _currentStep = 0;
  bool _isLoading = false;

  // مفاتيح النماذج لكل مرحلة
  final _formKeyStep1 = GlobalKey<FormState>();
  final _formKeyStep2 = GlobalKey<FormState>();

  // وحدات التحكم للمرحلة 1
  final _ownerNameController = TextEditingController();
  final _ownerPhoneController = TextEditingController();
  final _ownerPasswordController = TextEditingController();
  final _ownerPasswordConfirmController = TextEditingController();
  bool _obscureOwnerPassword = true;

  // وحدات التحكم للمرحلة 2
  final _wellNameController = TextEditingController();
  final _districtController = TextEditingController();
  final _villageController = TextEditingController();

  // وحدات التحكم للمرحلة 5
  final _pumpNameController = TextEditingController(text: 'المضخة الرئيسية');
  final _solarRateController = TextEditingController();
  final _dieselRateController = TextEditingController();
  final _farmerDieselRateController = TextEditingController();

  final List<String> _governorates = [
    'صنعاء',
    'عمران',
    'ذمار',
    'إب',
    'تعز',
    'الحديدة',
    'مأرب',
    'صعدة',
    'حجة',
    'لحج',
    'أبين',
    'شبوة',
    'حضرموت',
    'المهرة',
    'الجوف',
    'البيضاء',
    'الضالع',
    'ريمة',
    'المحويت',
    'عدن',
  ];

  @override
  void dispose() {
    _ownerNameController.dispose();
    _ownerPhoneController.dispose();
    _ownerPasswordController.dispose();
    _ownerPasswordConfirmController.dispose();
    _wellNameController.dispose();
    _districtController.dispose();
    _villageController.dispose();
    _pumpNameController.dispose();
    _solarRateController.dispose();
    _dieselRateController.dispose();
    _farmerDieselRateController.dispose();
    super.dispose();
  }

  void _nextStep() {
    if (_currentStep == 0) {
      if (!_formKeyStep1.currentState!.validate()) return;
      _setupData.ownerFullName = _ownerNameController.text.trim();
      _setupData.ownerPhone = _ownerPhoneController.text.trim();
      _setupData.ownerPassword = _ownerPasswordController.text;
    } else if (_currentStep == 1) {
      if (!_formKeyStep2.currentState!.validate()) return;
      _setupData.wellName = _wellNameController.text.trim();
      _setupData.district = _districtController.text.trim();
      _setupData.village = _villageController.text.trim();
    } else if (_currentStep == 2) {
      final totalPartnersEquity = _setupData.partners
          .fold<double>(0, (sum, p) => sum + p.equityShare);
      if (totalPartnersEquity > 100.0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.error,
            content: Text(
              'مجموع نسب ملكية الشركاء (${totalPartnersEquity.toStringAsFixed(1)}%) يتجاوز 100%! يرجى تعديل النسب للمتابعة.',
            ),
          ),
        );
        return;
      }
      final remaining = (100.0 - totalPartnersEquity).clamp(0.0, 100.0);
      _setupData.ownerEquityShare = remaining;
      _setupData.ownerProfitShare = remaining;
    }

    if (_currentStep < 4) {
      setState(() {
        _currentStep++;
      });
    } else {
      _finishSetup();
    }
  }

  void _previousStep() {
    if (_currentStep > 0) {
      setState(() {
        _currentStep--;
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _finishSetup() async {
    setState(() {
      _isLoading = true;
    });

    try {
      _setupData.pumpName = _pumpNameController.text.trim();
      _setupData.solarHourlyRate = CurrencyUtils.parseRawInt(
        _solarRateController.text.trim(),
      );
      _setupData.wellDieselHourlyRate = CurrencyUtils.parseRawInt(
        _dieselRateController.text.trim(),
      );
      _setupData.farmerDieselHourlyRate = CurrencyUtils.parseRawInt(
        _farmerDieselRateController.text.trim(),
      );

      final flow =
          widget.submissionFlow ??
          WellSetupSubmissionFlow(_submitWellSetupToBackend);
      final result = await flow.submit(
        _setupData,
        onCompleted: () => widget.onCompleted?.call(),
        close: () => Navigator.of(context).pop(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: result.succeeded
                ? AppColors.success
                : AppColors.error,
            content: Text(
              result.message,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        );
      }
    } finally {
      // ضمان تنظيف كلمة المرور دائماً
      _setupData.ownerPassword = '';
      _ownerPasswordController.clear();
      _ownerPasswordConfirmController.clear();
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _submitWellSetupToBackend(WellSetupData data) async {
    final client = Supabase.instance.client;
    final authRepo = AuthRepository(client);
    final bootstrapRepo = AppBootstrapRepository(client);

    if (client.auth.currentSession == null) {
      final authRes = await authRepo.signUpOwner(
        phone: data.ownerPhone,
        password: data.ownerPassword,
        fullName: data.ownerFullName,
      );

      if (client.auth.currentSession == null && authRes.session == null) {
        await authRepo.signIn(
          phoneOrEmail: data.ownerPhone,
          password: data.ownerPassword,
        );
      }
    }

    if (client.auth.currentSession == null) {
      throw StateError('Owner authentication did not create a session');
    }

    final locationParts = [
      'محافظة ${data.governorate}',
      if (data.district.isNotEmpty) 'مديرية ${data.district}',
      if (data.village.isNotEmpty) 'قرية ${data.village}',
    ];

    await bootstrapRepo.setupWellFull(
      setupData: {
        'well_name': data.wellName,
        'location': locationParts.join(' - '),
        'pump_name': data.pumpName,
        'pump_power_source': data.enableSolar ? 'solar' : 'diesel',
        'pricing': buildWellSetupPricing(
          enableSolar: data.enableSolar,
          solarHourlyRate: data.solarHourlyRate,
          enableWellDiesel: data.enableWellDiesel,
          wellDieselHourlyRate: data.wellDieselHourlyRate,
          enableFarmerDiesel: data.enableFarmerDiesel,
          farmerDieselHourlyRate: data.farmerDieselHourlyRate,
        ),
        'owner_equity_share': data.ownerEquityShare,
        'owner_profit_share': data.ownerProfitShare,
        'partners': data.partners
            .map(
              (partner) => {
                'full_name': partner.fullName,
                'phone': partner.phone.startsWith('+')
                    ? partner.phone
                    : '+967${partner.phone}',
                'equity_share': partner.equityShare,
                'profit_share': partner.profitShare,
              },
            )
            .toList(),
        'operators': data.operators
            .map(
              (operator) => {
                'full_name': operator.fullName,
                'phone': operator.phone.startsWith('+')
                    ? operator.phone
                    : '+967${operator.phone}',
              },
            )
            .toList(),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: _previousStep,
        ),
        title: const Text(
          'إنشاء بئر جديد',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.deepBlue,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // شريط التقدم بين المراحل الخمس
            _buildStepIndicator(),
            const Divider(height: 1, color: AppColors.surfaceSubtle),

            // محتوى المرحلة الحالية
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: _buildCurrentStepContent(),
              ),
            ),

            // أزرار التنقل السفلية
            _buildBottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildStepIndicator() {
    final stepTitles = [
      'المالك',
      'بيانات البئر',
      'الشركاء',
      'التشغيل',
      'التجهيز',
    ];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      color: AppColors.surface,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(5, (index) {
          final isPassed = index < _currentStep;
          final isCurrent = index == _currentStep;

          return Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isPassed || isCurrent
                              ? AppColors.waterBlue
                              : AppColors.border,
                        ),
                        child: Center(
                          child: isPassed
                              ? const Icon(Icons.check,
                                  size: 16, color: Colors.white)
                              : Text(
                                  '${index + 1}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: isCurrent
                                        ? Colors.white
                                        : AppColors.textSecondary,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        stepTitles[index],
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight:
                              isCurrent ? FontWeight.bold : FontWeight.normal,
                          color: isCurrent
                              ? AppColors.deepBlue
                              : AppColors.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (index < 4)
                  Container(
                    width: 12,
                    height: 2,
                    color: isPassed ? AppColors.waterBlue : AppColors.border,
                  ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildCurrentStepContent() {
    switch (_currentStep) {
      case 0:
        return _buildStep1OwnerAccount();
      case 1:
        return _buildStep2WellDetails();
      case 2:
        return _buildStep3Partners();
      case 3:
        return _buildStep4Operators();
      case 4:
        return _buildStep5EquipmentAndPricing();
      default:
        return const SizedBox.shrink();
    }
  }

  // المرحلة 1: حساب المالك
  Widget _buildStep1OwnerAccount() {
    return Form(
      key: _formKeyStep1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '1. حساب مالك البئر',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.deepBlue,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'المالك هو المسؤول الأساسي والمشرف العام على إدارة البئر وتشغيله.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 24),

          // الاسم الكامل
          const Text(
            'الاسم الكامل',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _ownerNameController,
            decoration: _inputDecoration('أدخل الاسم كاملاً (الرباعي أو الثلاثي)'),
            validator: (val) =>
                val == null || val.trim().isEmpty ? 'يرجى إدخال الاسم الكامل' : null,
          ),
          const SizedBox(height: 18),

          // رقم الهاتف
          const Text(
            'رقم الهاتف (اسم المستخدم)',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Directionality(
            textDirection: TextDirection.ltr,
            child: TextFormField(
              controller: _ownerPhoneController,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                const ArabicToEnglishDigitsFormatter(),
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(9),
              ],
              decoration: _inputDecoration('7XXXXXXXX', prefixText: '+967 '),
              validator: (val) {
                if (val == null || val.trim().isEmpty) {
                  return 'يرجى إدخال رقم الهاتف';
                }
                if (val.trim().length < 9) {
                  return 'رقم الهاتف يجب أن يتكون من 9 أرقام';
                }
                return null;
              },
            ),
          ),
          const SizedBox(height: 18),

          // كلمة المرور
          const Text(
            'كلمة المرور',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _ownerPasswordController,
            obscureText: _obscureOwnerPassword,
            inputFormatters: const [
              ArabicToEnglishDigitsFormatter(),
            ],
            decoration: _inputDecoration('••••••••',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureOwnerPassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () {
                    setState(() {
                      _obscureOwnerPassword = !_obscureOwnerPassword;
                    });
                  },
                )),
            validator: (val) {
              if (val == null || val.isEmpty) return 'يرجى إدخال كلمة المرور';
              if (val.length < 6) return 'كلمة المرور يجب أن لا تقل عن 6 خانات';
              return null;
            },
          ),
          const SizedBox(height: 18),

          // تأكيد كلمة المرور
          const Text(
            'تأكيد كلمة المرور',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _ownerPasswordConfirmController,
            obscureText: true,
            inputFormatters: const [
              ArabicToEnglishDigitsFormatter(),
            ],
            decoration: _inputDecoration('••••••••'),
            validator: (val) {
              if (val != _ownerPasswordController.text) {
                return 'كلمة المرور غير متطابقة';
              }
              return null;
            },
          ),
        ],
      ),
    );
  }

  // المرحلة 2: بيانات البئر الأساسية
  Widget _buildStep2WellDetails() {
    return Form(
      key: _formKeyStep2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '2. بيانات البئر الأساسية',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.deepBlue,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'أدخل اسم البئر والموقع الجغرافي العام.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 24),

          // اسم البئر
          const Text(
            'اسم البئر (إلزامي)',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _wellNameController,
            decoration: _inputDecoration('مثال: بئر الخير - المزرعة الشمالية'),
            validator: (val) =>
                val == null || val.trim().isEmpty ? 'يرجى إدخال اسم البئر' : null,
          ),
          const SizedBox(height: 18),

          // المحافظة
          const Text(
            'المحافظة',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _setupData.governorate,
            decoration: _inputDecoration('اختر المحافظة'),
            items: _governorates.map((gov) {
              return DropdownMenuItem(value: gov, child: Text(gov));
            }).toList(),
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _setupData.governorate = val;
                });
              }
            },
          ),
          const SizedBox(height: 18),

          // المديرية (اختياري)
          const Text(
            'المديرية (اختياري)',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _districtController,
            decoration: _inputDecoration('مثال: همدان'),
          ),
          const SizedBox(height: 18),

          // القرية أو المنطقة (اختياري)
          const Text(
            'القرية / المنطقة (اختياري)',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _villageController,
            decoration: _inputDecoration('مثال: وادي ظهر'),
          ),
        ],
      ),
    );
  }

  // المرحلة 3: الشركاء والملكيات
  Widget _buildStep3Partners() {
    final otherEquityTotal = _setupData.partners
        .fold<double>(0, (sum, p) => sum + p.equityShare);
    final remainingEquity = 100.0 - otherEquityTotal;
    final ownerEquityCalculated = remainingEquity.clamp(0.0, 100.0);
    final isOverAllocated = otherEquityTotal > 100.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '3. هيكل الشركاء والملكيات',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.deepBlue,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'إذا كان للبئر شركاء في الملكية أو الأرباح يمكنك إضافتهم هنا، أو الاكتفاء بالمالك بنسبة 100%.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 20),

        if (isOverAllocated) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppColors.error.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: AppColors.error, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'تنبيه: مجموع نسب الشركاء (${otherEquityTotal.toStringAsFixed(1)}%) يتجاوز 100%! يرجى تعديل أو حذف بعض الشركاء للمتابعة.',
                    style: const TextStyle(
                      color: AppColors.error,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        // كرت المالك الحالي
        Card(
          color: AppColors.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppColors.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: AppColors.deepBlue,
                  child: Icon(Icons.person, color: Colors.white),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _setupData.ownerFullName.isEmpty
                            ? 'مالك البئر'
                            : _setupData.ownerFullName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppColors.deepBlue,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'نسبة المالك المتبقية: ${ownerEquityCalculated.toStringAsFixed(1)}% | الأرباح: ${ownerEquityCalculated.toStringAsFixed(1)}%',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isOverAllocated
                              ? AppColors.error
                              : AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // قائمة الشركاء المضافين
        if (_setupData.partners.isNotEmpty) ...[
          const Text(
            'الشركاء المضافون:',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          ...List.generate(_setupData.partners.length, (idx) {
            final partner = _setupData.partners[idx];
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: AppColors.border),
              ),
              child: ListTile(
                title: Text(partner.fullName,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(
                    'الهاتف: +967 ${partner.phone} | الملكية: ${partner.equityShare.toStringAsFixed(1)}%'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, color: AppColors.error),
                  onPressed: () {
                    setState(() {
                      _setupData.partners.removeAt(idx);
                    });
                  },
                ),
              ),
            );
          }),
          const SizedBox(height: 12),
        ],

        // زر إضافة شريك جديد
        OutlinedButton.icon(
          onPressed: _showAddPartnerDialog,
          icon: const Icon(Icons.add, color: AppColors.waterBlue),
          label: Text(
            remainingEquity <= 0
                ? 'تم استنفاد النسبة (100% موزعة)'
                : 'إضافة شريك آخر (المتبقي: ${remainingEquity.toStringAsFixed(1)}%)',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.waterBlue,
            ),
          ),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppColors.waterBlue),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ],
    );
  }

  // المرحلة 4: فريق التشغيل
  Widget _buildStep4Operators() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '4. فريق التشغيل (المشغلون)',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.deepBlue,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'المالك هو المشغل الافتراضي الأول. يمكنك إضافة عمال ومشغلين آخرين لبدء الجلسات والتحصيل.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 20),

        Card(
          color: AppColors.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppColors.border),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: AppColors.agriculturalGreen,
                  child: Icon(Icons.engineering, color: Colors.white),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_setupData.ownerFullName.isEmpty ? "المالك" : _setupData.ownerFullName} (المناوب الافتراضي)',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: AppColors.deepBlue,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'صلاحية تشغيل كاملة ومباشرة على البئر',
                        style: TextStyle(
                            fontSize: 13, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // قائمة المشغلين المضافين
        if (_setupData.operators.isNotEmpty) ...[
          const Text(
            'المشغلون الإضافيون:',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          ...List.generate(_setupData.operators.length, (idx) {
            final op = _setupData.operators[idx];
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: AppColors.border),
              ),
              child: ListTile(
                title: Text(op.fullName,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('الهاتف: +967 ${op.phone}'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, color: AppColors.error),
                  onPressed: () {
                    setState(() {
                      _setupData.operators.removeAt(idx);
                    });
                  },
                ),
              ),
            );
          }),
          const SizedBox(height: 12),
        ],

        // زر إضافة مشغل آخر
        OutlinedButton.icon(
          onPressed: _showAddOperatorDialog,
          icon: const Icon(Icons.person_add_alt_1, color: AppColors.waterBlue),
          label: const Text(
            'إضافة مشغل آخر',
            style: TextStyle(
                fontWeight: FontWeight.bold, color: AppColors.waterBlue),
          ),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: AppColors.waterBlue),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ],
    );
  }

  // المرحلة 5: تجهيز التشغيل والمضخة ومصادر الطاقة
  Widget _buildStep5EquipmentAndPricing() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '5. تجهيز التشغيل والأسعار',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.deepBlue,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'حدد المضخة ومصادر الطاقة المستخدمة وسعر الساعة لكل مصدر بالريال اليمني.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 24),

        // اسم المضخة
        const Text(
          'اسم المضخة الأساسية',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _pumpNameController,
          decoration: _inputDecoration('مثال: المضخة الرئيسية 1'),
        ),
        const SizedBox(height: 24),

        const Text(
          'مصادر الطاقة والأسعار (بالريال/ساعة):',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: AppColors.deepBlue,
          ),
        ),
        const SizedBox(height: 12),

        // 1. طاقة شمسية
        _buildEnergySourceCard(
          title: 'طاقة شمسية (Solar)',
          subtitle: 'تشغيل نهاري عبر الألواح الشمسية',
          icon: Icons.wb_sunny_outlined,
          iconColor: Colors.amber[700]!,
          isEnabled: _setupData.enableSolar,
          onChanged: (val) {
            setState(() {
              _setupData.enableSolar = val;
            });
          },
          controller: _solarRateController,
        ),
        const SizedBox(height: 12),

        // 2. ديزل البئر (شامل)
        _buildEnergySourceCard(
          title: 'ديزل البئر (Well Diesel)',
          subtitle: 'سعر الساعة الشامل للتشغيل بالديزل (ق-17)',
          icon: Icons.local_gas_station_outlined,
          iconColor: AppColors.waterBlue,
          isEnabled: _setupData.enableWellDiesel,
          onChanged: (val) {
            setState(() {
              _setupData.enableWellDiesel = val;
            });
          },
          controller: _dieselRateController,
        ),
        const SizedBox(height: 12),

        // 3. ديزل المزارع
        _buildEnergySourceCard(
          title: 'ديزل المزارع (Farmer Diesel)',
          subtitle: 'أجرة تشغيل المضخة عند إحضار المزارع لديزله',
          icon: Icons.agriculture_outlined,
          iconColor: AppColors.agriculturalGreen,
          isEnabled: _setupData.enableFarmerDiesel,
          onChanged: (val) {
            setState(() {
              _setupData.enableFarmerDiesel = val;
            });
          },
          controller: _farmerDieselRateController,
        ),
      ],
    );
  }

  Widget _buildEnergySourceCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required bool isEnabled,
    required ValueChanged<bool> onChanged,
    required TextEditingController controller,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: isEnabled ? AppColors.waterBlue : AppColors.border,
          width: isEnabled ? 1.5 : 1.0,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                Icon(icon, color: iconColor, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold)),
                      Text(subtitle,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                Switch(
                  value: isEnabled,
                  activeTrackColor: AppColors.waterBlue,
                  onChanged: onChanged,
                ),
              ],
            ),
            if (isEnabled) ...[
              const Divider(height: 20),
              CurrencyTextFormField(
                controller: controller,
                hintText: 'أدخل سعر الساعة بالريال (مثال: 3,500)',
                labelText: 'سعر الساعة:',
                unitSuffix: 'ريال / ساعة',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final isLastStep = _currentStep == 4;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.surfaceSubtle)),
      ),
      child: Row(
        children: [
          if (_currentStep > 0)
            Expanded(
              flex: 1,
              child: OutlinedButton(
                onPressed: _isLoading ? null : _previousStep,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('السابق',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          if (_currentStep > 0) const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _nextStep,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.waterBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Text(
                      isLastStep ? 'حفظ وجاهز للتشغيل' : 'التالي',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddPartnerDialog() {
    final otherEquityTotal = _setupData.partners
        .fold<double>(0, (sum, p) => sum + p.equityShare);
    final maxAvailable = 100.0 - otherEquityTotal;

    if (maxAvailable <= 0) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('اكتمال توزيع الحصص',
              style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.deepBlue)),
          content: const Text(
            'تم توزيع 100% من ملكية البئر بالكامل. لا يمكن إضافة شركاء إضافيين بنسب ملكية جديدة إلا بعد تعديل أو حذف أحد الشركاء الحاليين.',
            style: TextStyle(fontSize: 14),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.waterBlue,
                foregroundColor: Colors.white,
              ),
              child: const Text('حسناً'),
            ),
          ],
        ),
      );
      return;
    }

    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final equityCtrl = TextEditingController();
    String? dialogError;
    String? suggestedName;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void checkPhone(String rawPhone) {
              final clean = normalizeArabicDigits(rawPhone.trim());
              final ownerPhone = normalizeArabicDigits(_ownerPhoneController.text.trim());

              if (clean.length == 9) {
                if (clean == ownerPhone) {
                  setDialogState(() {
                    dialogError = 'رقم الهاتف هذا هو رقم هاتف المالك نفسه، ولا يمكن إضافته كشريك إضافي.';
                    suggestedName = null;
                  });
                  return;
                }
                final duplicatePartner = _setupData.partners.where((p) => normalizeArabicDigits(p.phone) == clean).firstOrNull;
                if (duplicatePartner != null) {
                  setDialogState(() {
                    dialogError = 'رقم الهاتف هذا مضاف بالفعل للشريك (${duplicatePartner.fullName}).';
                    suggestedName = null;
                  });
                  return;
                }

                // فحص إذا كان الرقم موجوداً لمشغل في القائمة لاقتراح الاسم
                final existingOp = _setupData.operators.where((o) => normalizeArabicDigits(o.phone) == clean).firstOrNull;
                if (existingOp != null && nameCtrl.text.trim().isEmpty) {
                  setDialogState(() {
                    suggestedName = existingOp.fullName;
                    dialogError = null;
                  });
                  return;
                }
              }
              if (dialogError != null) {
                setDialogState(() => dialogError = null);
              }
            }

            return AlertDialog(
              title: const Text('إضافة شريك جديد',
                  style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.deepBlue)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'النسبة المتاحة المتبقية: ${maxAvailable.toStringAsFixed(1)}%',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.waterBlue,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: TextField(
                        controller: phoneCtrl,
                        keyboardType: TextInputType.phone,
                        inputFormatters: [
                          const ArabicToEnglishDigitsFormatter(),
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(9),
                        ],
                        decoration: _inputDecoration('7XXXXXXXX', prefixText: '+967 '),
                        onChanged: checkPhone,
                      ),
                    ),
                    if (suggestedName != null) ...[
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: () {
                          setDialogState(() {
                            nameCtrl.text = suggestedName!;
                            suggestedName = null;
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.waterBlue.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: AppColors.waterBlue.withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.person_outline, size: 16, color: AppColors.waterBlue),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'استيراد الاسم المقترح: $suggestedName',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                                ),
                              ),
                              const Text('استيراد', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.waterBlue)),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      decoration: _inputDecoration('الاسم الكامل للشريك'),
                      onChanged: (_) {
                        if (dialogError != null) {
                          setDialogState(() => dialogError = null);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: equityCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: const [
                        ArabicToEnglishDigitsFormatter(),
                      ],
                      decoration: _inputDecoration(
                          'أدخل نسبة الملكية % (أقصى حد: ${maxAvailable.toStringAsFixed(1)}%)'),
                      onChanged: (_) {
                        if (dialogError != null) {
                          setDialogState(() => dialogError = null);
                        }
                      },
                    ),
                    if (dialogError != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        dialogError!,
                        style: const TextStyle(
                          color: AppColors.error,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('إلغاء'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final name = nameCtrl.text.trim();
                    final phone = normalizeArabicDigits(phoneCtrl.text.trim());
                    final ownerPhone = normalizeArabicDigits(_ownerPhoneController.text.trim());
                    final equity = double.tryParse(normalizeArabicDigits(equityCtrl.text.trim()));

                    if (phone.isEmpty || phone.length < 9) {
                      setDialogState(
                          () => dialogError = 'يرجى إدخال رقم هاتف صحيح (9 أرقام)');
                      return;
                    }
                    if (phone == ownerPhone) {
                      setDialogState(
                          () => dialogError = 'رقم الهاتف يطابق رقم هاتف المالك نفسه');
                      return;
                    }
                    if (_setupData.partners.any((p) => normalizeArabicDigits(p.phone) == phone)) {
                      setDialogState(
                          () => dialogError = 'رقم الهاتف مضاف مسبقاً لشريك آخر في القائمة');
                      return;
                    }
                    if (name.isEmpty) {
                      setDialogState(() => dialogError = 'يرجى إدخال اسم الشريك الكامل');
                      return;
                    }
                    if (equity == null || equity <= 0) {
                      setDialogState(() => dialogError = 'يرجى إدخال نسبة ملكية أكبر من 0%');
                      return;
                    }
                    if (equity > maxAvailable) {
                      setDialogState(() => dialogError =
                          'النسبة تتجاوز المتاح (${maxAvailable.toStringAsFixed(1)}%)');
                      return;
                    }

                    setState(() {
                      _setupData.partners.add(PartnerData(
                        fullName: name,
                        phone: phone,
                        equityShare: equity,
                        profitShare: equity,
                      ));
                    });
                    Navigator.of(ctx).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.waterBlue,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('إضافة'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showAddOperatorDialog() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    String? dialogError;
    String? suggestedName;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            void checkPhone(String rawPhone) {
              final clean = normalizeArabicDigits(rawPhone.trim());
              final ownerPhone = normalizeArabicDigits(_ownerPhoneController.text.trim());

              if (clean.length == 9) {
                if (clean == ownerPhone) {
                  setDialogState(() {
                    dialogError = 'المالك هو المشغل الافتراضي الأول ولديه صلاحية تشغيل كاملة تلقائياً.';
                    suggestedName = null;
                  });
                  return;
                }
                final duplicateOp = _setupData.operators.where((o) => normalizeArabicDigits(o.phone) == clean).firstOrNull;
                if (duplicateOp != null) {
                  setDialogState(() {
                    dialogError = 'رقم الهاتف هذا مضاف بالفعل للمشغل (${duplicateOp.fullName}).';
                    suggestedName = null;
                  });
                  return;
                }

                // فحص إذا كان الرقم موجوداً لشريك في القائمة لاقتراح الاسم
                final existingPartner = _setupData.partners.where((p) => normalizeArabicDigits(p.phone) == clean).firstOrNull;
                if (existingPartner != null && nameCtrl.text.trim().isEmpty) {
                  setDialogState(() {
                    suggestedName = existingPartner.fullName;
                    dialogError = null;
                  });
                  return;
                }
              }
              if (dialogError != null) {
                setDialogState(() => dialogError = null);
              }
            }

            return AlertDialog(
              title: const Text('إضافة مشغل جديد',
                  style: TextStyle(fontWeight: FontWeight.bold, color: AppColors.deepBlue)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: TextField(
                        controller: phoneCtrl,
                        keyboardType: TextInputType.phone,
                        inputFormatters: [
                          const ArabicToEnglishDigitsFormatter(),
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(9),
                        ],
                        decoration: _inputDecoration('7XXXXXXXX', prefixText: '+967 '),
                        onChanged: checkPhone,
                      ),
                    ),
                    if (suggestedName != null) ...[
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: () {
                          setDialogState(() {
                            nameCtrl.text = suggestedName!;
                            suggestedName = null;
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.waterBlue.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: AppColors.waterBlue.withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.person_outline, size: 16, color: AppColors.waterBlue),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'استيراد الاسم المقترح: $suggestedName',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                                ),
                              ),
                              const Text('استيراد', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.waterBlue)),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameCtrl,
                      decoration: _inputDecoration('اسم المشغل الكامل'),
                      onChanged: (_) {
                        if (dialogError != null) {
                          setDialogState(() => dialogError = null);
                        }
                      },
                    ),
                    if (dialogError != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        dialogError!,
                        style: const TextStyle(
                          color: AppColors.error,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('إلغاء'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final name = nameCtrl.text.trim();
                    final phone = normalizeArabicDigits(phoneCtrl.text.trim());
                    final ownerPhone = normalizeArabicDigits(_ownerPhoneController.text.trim());

                    if (phone.isEmpty || phone.length < 9) {
                      setDialogState(
                          () => dialogError = 'يرجى إدخال رقم هاتف صحيح (9 أرقام)');
                      return;
                    }
                    if (phone == ownerPhone) {
                      setDialogState(
                          () => dialogError = 'المالك هو المشغل الافتراضي الأول ولديه صلاحية تشغيل كاملة تلقائياً');
                      return;
                    }
                    if (_setupData.operators.any((o) => normalizeArabicDigits(o.phone) == phone)) {
                      setDialogState(
                          () => dialogError = 'رقم الهاتف مضاف مسبقاً لمشغل آخر في القائمة');
                      return;
                    }
                    if (name.isEmpty) {
                      setDialogState(() => dialogError = 'يرجى إدخال اسم المشغل');
                      return;
                    }

                    setState(() {
                      _setupData.operators.add(OperatorData(
                        fullName: name,
                        phone: phone,
                      ));
                    });
                    Navigator.of(ctx).pop();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.waterBlue,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('إضافة'),
                ),
              ],
            );
          },
        );
      },
    );
  }


  InputDecoration _inputDecoration(String hint,
      {String? prefixText, Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 14),
      prefixText: prefixText,
      prefixStyle: const TextStyle(
        fontWeight: FontWeight.bold,
        color: AppColors.textPrimary,
      ),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.borderFocused, width: 1.5),
      ),
    );
  }
}

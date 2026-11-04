import '../../core/errors/user_facing_error.dart';
import '../../core/widgets/farmer_create_dialog.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/api/booking_repository.dart';
import '../../core/api/operations_repository.dart';
import '../../core/booking/local_booking_request.dart';
import '../../core/identity/app_identity.dart';
import '../../core/theme/app_colors.dart';
import '../../core/session/offline_session_coordinator.dart';
import '../../core/widgets/farm_create_dialog.dart';
import '../../core/widgets/smart_lookup_field.dart';
import 'bookings_screen.dart';

/// يحفظ طلب الحجز على الهاتف قبل الاتصال؛ تثبيت الموعد من إيصال الخادم.
/// المزارع محسوم، والأرض موجودة أو محفوظة على الهاتف؛ الطلب الأصلي ثابت.
class BookingFormScreen extends StatefulWidget {
  const BookingFormScreen({
    required this.identity,
    this.bookingRepository,
    this.operationsRepository,
    this.initialDate,
    this.online = true,
    this.localRequestId,
    this.replaces,
    this.coordinator,
    super.key,
  });

  final AppIdentity identity;
  final BookingRepository? bookingRepository;
  final OperationsRepository? operationsRepository;

  /// اليوم الذي فُتح منه النموذج: التاريخ الافتراضي للحجز الجديد يرثه،
  /// فلا يُفترض دائمًا تاريخ الجهاز الحالي.
  final DateTime? initialDate;
  final bool online;
  final String? localRequestId;
  final LocalBookingRequest? replaces;
  final OfflineSessionCoordinator? coordinator;


  @override
  State<BookingFormScreen> createState() => _BookingFormScreenState();
}

class _BookingFormScreenState extends State<BookingFormScreen> {
  late final BookingRepository _bookingRepo;
  late final OperationsRepository _opsRepo;
  late final String _wellId;
  late final String _accountId;
  late final DateTime _initialStart;
  late final int _initialDurationMinutes;

  OfflineSessionCoordinator get _coordinator => widget.coordinator ?? _bookingRepo.farmCoordinator;
  FarmerAccount? _farmer;
  Farm? _farm;

  // مصدر الحقيقة الوحيد للموعد: (البداية، المدة بالدقائق). النهاية مشتقّة.
  late DateTime _start;
  late int _durationMinutes;
  bool _scheduleValid = true;

  final _notesController = TextEditingController();
  String? _energySource;
  String? _alternativeEnergySource;
  String? _energyError;
  late String _requestId;
  bool _busy = false;
  bool _prefilling = false;
  int _priority = 0;
  String? _validationError;

  /// تقييم الطاقة الشمسية للموعد الحالي من قيمه الاسمية (دقيقة البداية
  /// والمدة) — لا منطقة جهاز ولا ساعة حائط. (أو ok إن لم تُختَر الشمسية.)
  SolarAssessment get _solarState => _energySource == 'solar'
      ? assessSolarWindow(
          startMinuteOfDay: solarStartMinuteOfDay(_start),
          durationMinutes: _durationMinutes,
        )
      : SolarAssessment.ok;

  @override
  void initState() {
    super.initState();
    _bookingRepo = widget.bookingRepository ?? BookingRepository();
    _opsRepo = widget.operationsRepository ?? OperationsRepository();
    _wellId = widget.identity.activeWell.id;
    _accountId = widget.identity.accountId;
    _requestId = widget.localRequestId ?? _bookingRepo.newCommandId();
    final original = widget.replaces;
    _initialStart = original == null ? _defaultStart(widget.initialDate)
        : DateTime.parse(original.payload['p_scheduled_start'] as String).toLocal();
    _initialDurationMinutes = original == null ? 60
        : DateTime.parse(original.payload['p_scheduled_end'] as String).difference(_initialStart).inMinutes;
    _start = _initialStart;
    _durationMinutes = _initialDurationMinutes;
    if (original != null) {
      _energySource = original.payload['p_expected_energy_source'] as String?;
      _alternativeEnergySource = original.payload['p_alternative_energy_source'] as String?;
      _priority = original.payload['p_priority'] as int? ?? 0;
      _notesController.text = original.payload['p_notes'] as String? ?? '';
      _prefilling = true;
      unawaited(_prefillCorrectionChoices(original));
    }
  }

  Future<void> _prefillCorrectionChoices(LocalBookingRequest original) async {
    try {
      if (original.accountId != _accountId || original.wellId != _wellId || !original.needsCorrection) return;
      final farmerId = original.payload['p_farmer_well_account_id'];
      final context = jsonDecode(original.contextJson) as Map;
      String query = context['farmer_name'] as String? ?? '';
      try {
        final cached = await _bookingRepo.cachedBookingChoices(_accountId, _wellId, 'farmers');
        final known = cached.where((f) => f['id'] == farmerId).firstOrNull;
        query = known?['public_code'] as String? ?? query;
      } catch (_) { /* البحث المعتاد قد ينجح ولو تعذرت قراءة المخبأ. */ }
      // نص البحث ليس هوية؛ لا نختار إلا تطابق المعرّف الأصلي نفسه.
      final farmers = await _searchFarmers(query);
      if (!mounted || !_isCurrentScope) return;
      _farmer = farmers.where((f) => f.id == farmerId).firstOrNull;
      if (_farmer != null) {
        final farms = await _searchFarms('');
        if (!mounted || !_isCurrentScope) return;
        _farm = farms.where((f) => f.id == original.payload['p_farm_id']).firstOrNull;
      }
    } catch (_) {
      // لا نستبدل هوية غير متاحة باختيار آخر ولا نخمن صلاحيتها.
    } finally {
      if (mounted) {
        setState(() {
          _prefilling = false;
          if (_farmer == null || _farm == null) {
            _validationError = 'اختر مزارعًا وأرضًا محفوظين مسبقًا.';
          }
        });
      }
    }
  }

  /// وقت ابتدائي معقول: إن حمل التاريخ وقتًا صريحًا فهو البداية؛ وعلى يوم
  /// بلا وقت نبدأ 08:00؛ وعلى اليوم الحالي نبدأ الساعة التالية (مُقرَّبة)
  /// لتفادي موعد في الماضي القريب.
  DateTime _defaultStart(DateTime? date) {
    final now = DateTime.now();
    if (date == null) {
      final hour = (now.hour + 1).clamp(0, 23);
      return DateTime(now.year, now.month, now.day, hour);
    }
    if (date.hour != 0 || date.minute != 0) return date;
    final isToday =
        date.year == now.year && date.month == now.month && date.day == now.day;
    final hour = isToday ? (now.hour + 1).clamp(0, 23) : 8;
    return DateTime(date.year, date.month, date.day, hour);
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  DateTime get _end => bookingEndFromDuration(_start, _durationMinutes);

  void _onScheduleChanged(DateTime start, int durationMinutes, bool isValid) {
    setState(() {
      _start = start;
      _durationMinutes = durationMinutes;
      _scheduleValid = isValid;
      if (isValid) _validationError = null;
    });
  }

  bool get _isCurrentScope =>
      widget.identity.accountId == _accountId &&
      widget.identity.activeWell.id == _wellId;

  Future<void> _submit() async {
    if (_prefilling) return;
    if (!_isCurrentScope) {
      _notify('أعد فتح الحجز للبئر المطلوب.');
      return;
    }
    setState(() {
      _validationError = null;
      _energyError = null;
    });
    if (_farmer == null) {
      setState(() => _validationError = 'اختر المزارع.');
      return;
    }
    if (_farm == null) {
      setState(() => _validationError = 'اختر الأرض.');
      return;
    }
    if (!_scheduleValid || _durationMinutes <= 0) {
      setState(
        () =>
            _validationError = 'راجع الموعد: يجب أن تكون النهاية بعد البداية.',
      );
      return;
    }
    final original = widget.replaces;
    if (original?.response?['status'] == 'conflict' &&
        _start.toUtc() == DateTime.parse(original!.payload['p_scheduled_start'] as String) &&
        _end.toUtc() == DateTime.parse(original.payload['p_scheduled_end'] as String)) {
      setState(() => _validationError = 'اختر موعدًا آخر للحجز.');
      return;
    }
    // الطاقة مطلوبة لحجز مؤكّد جاهز للتنفيذ (ق-132) — ليست اختيارية.
    if (_energySource == null) {
      setState(() => _energyError = 'اختر مصدر الطاقة لهذا الحجز.');
      return;
    }
    // تحقّق الطاقة الشمسية محليًّا قبل أي نداء شبكة (مرآة عقد الخادم).
    if (_energySource == 'solar') {
      final s = _solarState;
      if (s == SolarAssessment.startOutsideWindow) {
        setState(
          () => _energyError =
              'لا يمكن استخدام الطاقة الشمسية في وقت بداية هذا الحجز.',
        );
        return;
      }
      if (s == SolarAssessment.requiresAlternative &&
          _alternativeEnergySource == null) {
        setState(
          () => _energyError = 'يمتد الحجز بعد انتهاء وقت الطاقة الشمسية. اختر مصدر الطاقة البديل.',
        );
        return;
      }
    }
    if (_farmer!.isPending ||

        _farmer!.status != 'active' ||
        (!_farm!.isPending && _farm!.status != 'active') ||
        _farm!.wellId != _wellId ||
        _farm!.farmerAccountId != _farmer!.id) {
      _notify('اختر مزارعًا وأرضًا محفوظين مسبقًا.');
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final request = await _bookingRepo.saveLocalBooking(
        accountId: _accountId,
        wellId: _wellId,
        requestId: _requestId,
        replaces: original,
        farmer: _farmer!,
        farm: _farm!,
        scheduledStart: _start,
        scheduledEnd: _end,
        expectedEnergySource: _energySource!,
        priority: _priority,
        alternativeEnergySource: _energySource == 'solar'
            ? _alternativeEnergySource
            : null,
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
      );
      if (!mounted || !_isCurrentScope) return;
      unawaited(_bookingRepo.requestBookingConfirmation(request.accountId));
      _finishSaved(request);
    } catch (error) {
      if (mounted) setState(() => _busy = false);
      _notify(UserFacingError.from(error).message);
      return;
    }
    if (mounted) setState(() => _busy = false);
  }

  void _finishSaved(LocalBookingRequest request) {
    if (!mounted || !_isCurrentScope) return;
    _notify('تم حفظ الحجز');
    if (Navigator.of(context).canPop()) {
      if (widget.replaces == null) {
        Navigator.of(context).pop(true);
      } else {
        Navigator.of(context).pop(request);
      }
    }
  }

  Future<FarmerAccount?> _addFarmer() async {
    if (!(widget.identity.isOwner || widget.identity.isOperator)) return null;
    final farmer = await showFarmerCreateDialog(context: context, save: (name, phone) =>
      _coordinator.enqueueFarmer(accountId: _accountId, wellId: _wellId,
        fullName: name, phone: phone, waitForCanonical: true));
    if (!mounted || !_isCurrentScope || farmer == null) return null;
    final message = farmer.status == 'requires_resolution'
        ? 'تحتاج بيانات المزارع إلى مراجعة.'
        : farmer.isPending ? 'تم حفظ المزارع وسيصبح متاحًا للحجز بعد تثبيته.' : 'تم حفظ المزارع';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    return farmer.isPending ? null : farmer;
  }

  Future<List<FarmerAccount>> _searchFarmers(String query) async {
    final account = _accountId;
    if (widget.online) {
      try {
        final values = await _opsRepo.fetchFarmers(_wellId, query: query);
        final canonical = values
            .where((f) => !f.isPending && f.status == 'active')
            .toList();
        await _bookingRepo.cacheBookingChoices(account, _wellId, 'farmers', [
          for (final f in canonical)
            {
              'id': f.id,
              'full_name': f.fullName,
              'public_code': f.publicCode,
              'phone': f.phone,
              'status': f.status,
            },
        ]);
        return canonical;
      } catch (_) {
        // البحث المحلي المحدود يظل متاحًا عند انقطاع النقل.
      }
    }
    final cached = await _bookingRepo.cachedBookingChoices(
      account,
      _wellId,
      'farmers',
    );
    return cached
        .map(FarmerAccount.fromJson)
        .where(
          (f) =>
              !f.isPending &&
              f.status == 'active' &&
              (f.fullName.contains(query.trim()) ||
                  f.publicCode.contains(query.trim())),
        )
        .toList();
  }

  Future<List<Farm>> _searchFarms(String query) async {
    final farmer=_farmer;if(farmer==null||farmer.isPending)return [];
    final key='farms.${farmer.id}';List<Farm> canonical=[];bool loaded=false;
    if(widget.online) {
      try {
        canonical=await _opsRepo.searchFarms(_wellId,farmerAccountId:farmer.id,query:query);
        loaded=true;
        await _bookingRepo.cacheBookingChoices(_accountId,_wellId,key,[for(final f in canonical){'id':f.id,'well_id':f.wellId,'name':f.name,'distinguishing_label':f.distinguishingLabel,'farmer_well_account_id':f.farmerAccountId,'status':f.status}]);
      }catch(_) {}
    }
    if(!loaded) canonical=(await _bookingRepo.cachedBookingChoices(_accountId,_wellId,key)).map(Farm.fromJson).where((f)=>f.displayName.contains(query.trim())).toList();
    return _coordinator.farmChoices(accountId:_accountId,wellId:_wellId,farmerReference:farmer.entityReference,canonical:canonical,query:query);
  }
  Future<Farm?> _addFarm() async {
    final farmer=_farmer;
    if(farmer==null||farmer.isPending||farmer.status!='active'||!(widget.identity.isOwner||widget.identity.isOperator))return null;
    final saved=await showFarmCreateDialog(context:context,farmerName:farmer.fullName,save:(name,label)=>_coordinator.enqueueFarm(accountId:_accountId,wellId:_wellId,name:name,distinguishingLabel:label,farmerReference:farmer.entityReference));
    if(!mounted||!_isCurrentScope||_farmer?.id!=farmer.id)return null;
    return saved;
  }

  Widget _buildEnergyChild() {
    final solar = _solarState;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _EnergyChips(
          value: _energySource,
          onChanged: (v) => setState(() {
            _energySource = v;
            if (v != 'solar') _alternativeEnergySource = null;
            _energyError = null;
          }),
        ),
        if (_energySource == 'solar' &&
            solar == SolarAssessment.startOutsideWindow) ...[
          const SizedBox(height: 10),
          const _EnergyNotice(
            error: true,
            lines: [
              'لا يمكن استخدام الطاقة الشمسية في وقت بداية هذا الحجز.',
              'اختر مصدر طاقة مناسبًا لهذا الموعد.',
              'نافذة الطاقة الشمسية: $kSolarWindowLabel',
            ],
          ),
        ] else if (_energySource == 'solar' &&
            solar == SolarAssessment.requiresAlternative) ...[
          const SizedBox(height: 10),
          const _EnergyNotice(
            error: false,
            lines: [
              'يمتد الحجز بعد انتهاء وقت الطاقة الشمسية. اختر مصدر الطاقة البديل.',
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'المصدر البديل *',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.bold,
              color: AppColors.deepBlue,
            ),
          ),
          const SizedBox(height: 8),
          _EnergyChips(
            value: _alternativeEnergySource,
            options: const ['well_diesel', 'farmer_diesel'],
            onChanged: (v) => setState(() {
              _alternativeEnergySource = v;
              _energyError = null;
            }),
          ),
        ],
        if (_energyError != null) ...[
          const SizedBox(height: 10),
          _InlineError(message: _energyError!),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        title: Text(
          widget.replaces?.correctionAction ?? 'إضافة حجز',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: AppColors.deepBlue,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            if (!widget.online) ...[
              const _OfflineNotice(),
              const SizedBox(height: 14),
            ],
            _FormSection(
              title: 'المزارع والأرض',
              icon: Icons.person_pin_circle_rounded,
              child: Column(
                children: [
                  SmartLookupField<FarmerAccount>(
                    label: 'المزارع *',
                    hintText: 'ابحث بالاسم أو الرمز',
                    itemLabel: (f) => f.fullName,
                    itemSecondaryLabel: (f) => f.publicCode,
                    selectedItem: _farmer,
                    enabled: !_prefilling,
                    searchFunction: _searchFarmers,
                    onAddNew: widget.identity.isOwner || widget.identity.isOperator ? _addFarmer : null,
                    addNewLabel: 'إضافة مزارع جديد',
                    onChanged: (f) => setState(() {
                      _farmer = f;
                      _farm = null;
                    }),
                  ),
                  const SizedBox(height: 12),
                  SmartLookupField<Farm>(
                    label: 'الأرض *',
                    hintText: 'ابحث عن الأرض',
                    itemLabel: (f) => f.displayName,
                    selectedItem: _farm,
                    enabled: _farmer != null && !_prefilling,
                    searchFunction: _searchFarms,
                    onChanged: (f) => setState(() => _farm = f),
                    onAddNew: _farmer!=null && !_farmer!.isPending && _farmer!.status=='active' && (widget.identity.isOwner||widget.identity.isOperator) ? _addFarm : null,
                    addNewLabel: 'إضافة أرض جديدة',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _FormSection(
              title: 'موعد السقي',
              icon: Icons.event_rounded,
              child: BookingScheduleEditor(
                initialStart: _initialStart,
                initialDurationMinutes: _initialDurationMinutes,
                onChanged: _onScheduleChanged,
              ),
            ),
            const SizedBox(height: 14),
            _FormSection(
              title: 'مصدر الطاقة *',
              icon: Icons.bolt_rounded,
              child: _buildEnergyChild(),
            ),
            const SizedBox(height: 14),
            _FormSection(
              title: 'ملاحظات',
              subtitle: 'اختياري',
              icon: Icons.sticky_note_2_outlined,
              child: TextField(
                controller: _notesController,
                maxLines: 3,
                minLines: 2,
                decoration: const InputDecoration(
                  hintText: 'ملاحظة قصيرة تظهر مع الحجز',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            if (_validationError != null) ...[
              const SizedBox(height: 14),
              _InlineError(message: _validationError!),
            ],
            const SizedBox(height: 22),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: _busy || _prefilling ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.waterBlue,
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_circle_outline),
                label: Text(_busy ? 'جارٍ الحفظ...' : 'حفظ الحجز'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// بطاقة قسم موجّه: رأس (أيقونة + عنوان + تلميح اختياري) ثم محتواه.
class _FormSection extends StatelessWidget {
  const _FormSection({
    required this.title,
    required this.icon,
    required this.child,
    this.subtitle,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: AppColors.waterBlue),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepBlue,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(width: 8),
                Text(
                  subtitle!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _OfflineNotice extends StatelessWidget {
  const _OfflineNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 18,
            color: AppColors.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'يمكنك حفظ الحجز على الهاتف دون اتصال.',
              style: TextStyle(
                fontSize: 12.5,
                color: AppColors.warning.withValues(alpha: 0.9),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(
          Icons.error_outline_rounded,
          size: 18,
          color: AppColors.error,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              color: AppColors.error,
              fontWeight: FontWeight.bold,
              fontSize: 13.5,
            ),
          ),
        ),
      ],
    );
  }
}

/// اختيار مصدر الطاقة بشرائح — إظهار المعروف منها فقط، والنقر على المحدّد
/// يلغيه (اختياري). القيمة المُرسلة كود كنوني، والعرض عربي.
class _EnergyChips extends StatelessWidget {
  const _EnergyChips({
    required this.value,
    required this.onChanged,
    this.options = kSessionEnergySources,
  });
  final String? value;
  final ValueChanged<String?> onChanged;
  final List<String> options;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((code) {
        final selected = value == code;
        return ChoiceChip(
          label: Text(energySourceLabel(code)),
          selected: selected,
          onSelected: (_) => onChanged(selected ? null : code),
          labelStyle: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppColors.textSecondary,
          ),
          selectedColor: AppColors.waterBlue,
          backgroundColor: AppColors.surface,
          showCheckmark: false,
          side: BorderSide(
            color: selected ? AppColors.waterBlue : AppColors.border,
          ),
        );
      }).toList(),
    );
  }
}

/// نمط إدخال الموعد: بالمدة (تُحسب النهاية) أو بوقت النهاية (تُحسب المدة).
enum ScheduleInputMode { byDuration, byEndTime }

/// محرّر الموعد القابل لإعادة الاستخدام (النموذج + إعادة الجدولة).
///
/// مصدر الحقيقة الوحيد داخليًّا هو (البداية، المدة بالدقائق)؛ النهاية مشتقّة
/// دائمًا. في وضع «بوقت النهاية» يُشتَقّ منها المدةُ لحظة الاختيار ثم تبقى
/// المدةُ هي المصدر — فلا قيمتان متعارضتان. يبلّغ الأب عبر [onChanged].
class BookingScheduleEditor extends StatefulWidget {
  const BookingScheduleEditor({
    required this.initialStart,
    required this.initialDurationMinutes,
    required this.onChanged,
    super.key,
  });

  final DateTime initialStart;
  final int initialDurationMinutes;
  final void Function(DateTime start, int durationMinutes, bool isValid)
  onChanged;

  @override
  State<BookingScheduleEditor> createState() => _BookingScheduleEditorState();
}

class _BookingScheduleEditorState extends State<BookingScheduleEditor> {
  late DateTime _start;
  late int _durationMinutes;
  ScheduleInputMode _mode = ScheduleInputMode.byDuration;
  bool _endInvalid = false;

  @override
  void initState() {
    super.initState();
    _start = widget.initialStart;
    _durationMinutes = widget.initialDurationMinutes;
  }

  bool get _isValid => !_endInvalid && _durationMinutes > 0;
  DateTime get _end => bookingEndFromDuration(_start, _durationMinutes);

  void _emit() => widget.onChanged(_start, _durationMinutes, _isValid);

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      helpText: 'اختر تاريخ الحجز',
    );
    if (picked == null) return;
    setState(() {
      _start = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _start.hour,
        _start.minute,
      );
      _endInvalid = false;
    });
    _emit();
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_start),
      helpText: 'وقت البداية',
    );
    if (picked == null) return;
    setState(() {
      _start = DateTime(
        _start.year,
        _start.month,
        _start.day,
        picked.hour,
        picked.minute,
      );
      _endInvalid = false;
    });
    _emit();
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_end),
      helpText: 'وقت النهاية',
    );
    if (picked == null) return;
    final endDt = DateTime(
      _start.year,
      _start.month,
      _start.day,
      picked.hour,
      picked.minute,
    );
    final diff = bookingDurationMinutes(_start, endDt);
    setState(() {
      if (diff > 0) {
        _durationMinutes = diff;
        _endInvalid = false;
      } else {
        _endInvalid = true;
      }
    });
    _emit();
  }

  void _setDuration(int minutes) {
    setState(() {
      _durationMinutes = minutes.clamp(0, 24 * 60);
      _endInvalid = false;
    });
    _emit();
  }

  void _setMode(ScheduleInputMode mode) {
    setState(() {
      _mode = mode;
      _endInvalid = false;
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final byDuration = _mode == ScheduleInputMode.byDuration;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ScheduleFieldRow(
          icon: Icons.calendar_month_rounded,
          label: 'التاريخ',
          value: bookingFullArabicDate(_start),
          onTap: _pickDate,
        ),
        const SizedBox(height: 10),
        _ScheduleFieldRow(
          icon: Icons.schedule_rounded,
          label: 'وقت البداية',
          value: _hm(_start),
          onTap: _pickStartTime,
        ),
        const SizedBox(height: 16),
        _ModeSwitch(mode: _mode, onChanged: _setMode),
        const SizedBox(height: 12),
        if (byDuration) ...[
          _DurationStepper(minutes: _durationMinutes, onChanged: _setDuration),
          const SizedBox(height: 10),
          _CalcLine(
            icon: Icons.flag_rounded,
            label: 'وقت النهاية',
            value: _hm(_end),
          ),
        ] else ...[
          _ScheduleFieldRow(
            icon: Icons.flag_rounded,
            label: 'وقت النهاية',
            value: _hm(_end),
            onTap: _pickEndTime,
          ),
          const SizedBox(height: 10),
          if (_endInvalid)
            const _InlineError(message: 'يجب أن تكون النهاية بعد وقت البداية.')
          else
            _CalcLine(
              icon: Icons.timelapse_rounded,
              label: 'مدة السقي',
              value: formatBookingDuration(_durationMinutes),
            ),
        ],
        if (_isValid) ...[
          const SizedBox(height: 14),
          _ScheduleSummary(start: _start, end: _end, minutes: _durationMinutes),
        ],
      ],
    );
  }
}

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// صف قيمة قابل للنقر (تاريخ/وقت) بمساحة لمس مريحة وأيقونة تحرير واضحة.
class _ScheduleFieldRow extends StatelessWidget {
  const _ScheduleFieldRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.waterBlue),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepBlue,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.edit_rounded,
              size: 16,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// مُبدّل نمط إدخال الموعد — بوضوح أيّ قيمة تُحرَّر وأيّها محسوبة.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});
  final ScheduleInputMode mode;
  final ValueChanged<ScheduleInputMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<ScheduleInputMode>(
        segments: const [
          ButtonSegment(
            value: ScheduleInputMode.byDuration,
            label: Text('بالمدة'),
            icon: Icon(Icons.timelapse_rounded, size: 18),
          ),
          ButtonSegment(
            value: ScheduleInputMode.byEndTime,
            label: Text('بوقت النهاية'),
            icon: Icon(Icons.flag_rounded, size: 18),
          ),
        ],
        selected: {mode},
        onSelectionChanged: (s) => onChanged(s.first),
        showSelectedIcon: false,
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(
            TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? AppColors.waterBlue
                : Colors.white,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? Colors.white
                : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// منتقي المدة الميداني: شرائح سريعة + ضبط دقيق (ساعة / ربع ساعة).
class _DurationStepper extends StatelessWidget {
  const _DurationStepper({required this.minutes, required this.onChanged});
  final int minutes;
  final ValueChanged<int> onChanged;

  static const _quick = [30, 60, 120, 180];

  @override
  Widget build(BuildContext context) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _quick.map((q) {
            final selected = minutes == q;
            return ChoiceChip(
              label: Text(formatBookingDuration(q)),
              selected: selected,
              onSelected: (_) => onChanged(q),
              labelStyle: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppColors.textSecondary,
              ),
              selectedColor: AppColors.waterBlue,
              backgroundColor: AppColors.surface,
              showCheckmark: false,
              side: BorderSide(
                color: selected ? AppColors.waterBlue : AppColors.border,
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _AdjustGroup(
                title: 'ساعات',
                value: '$h',
                onMinus: h > 0 ? () => onChanged(minutes - 60) : null,
                onPlus: () => onChanged(minutes + 60),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _AdjustGroup(
                title: 'دقائق',
                value: '$m',
                onMinus: minutes >= 15 ? () => onChanged(minutes - 15) : null,
                onPlus: () => onChanged(minutes + 15),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _AdjustGroup extends StatelessWidget {
  const _AdjustGroup({
    required this.title,
    required this.value,
    required this.onMinus,
    required this.onPlus,
  });

  final String title;
  final String value;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                onPressed: onMinus,
                icon: const Icon(Icons.remove_rounded),
                color: AppColors.waterBlue,
                visualDensity: VisualDensity.compact,
              ),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepBlue,
                ),
              ),
              IconButton(
                onPressed: onPlus,
                icon: const Icon(Icons.add_rounded),
                color: AppColors.waterBlue,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// سطر قيمة محسوبة (للقراءة) مع وسم «محسوب» حتى لا يُظنّ قابلًا للتحرير.
class _CalcLine extends StatelessWidget {
  const _CalcLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.textMuted),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: const TextStyle(
            fontSize: 13.5,
            color: AppColors.textSecondary,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppColors.deepBlue,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            'محسوب',
            style: TextStyle(fontSize: 10.5, color: AppColors.textMuted),
          ),
        ),
      ],
    );
  }
}

/// ملخّص الموعد قبل الحفظ — يرفع الثقة دون زحام.
class _ScheduleSummary extends StatelessWidget {
  const _ScheduleSummary({
    required this.start,
    required this.end,
    required this.minutes,
  });

  final DateTime start;
  final DateTime end;
  final int minutes;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.waterBlue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.waterBlue.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.event_available_rounded,
            size: 20,
            color: AppColors.waterBlue,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bookingShortArabicDate(start),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: AppColors.deepBlue,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_hm(start)} — ${_hm(end)}  ·  ${formatBookingDuration(minutes)}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ترجمة سبب رفض الأعمال المنظّم إلى رسالة عربية مفهومة (لا رمز تقني).
String? bookingRejectionMessage(String? reasonCode) {
  switch (reasonCode) {
    case 'solar_start_outside_window':
      return 'لا يمكن استخدام الطاقة الشمسية في وقت بداية هذا الحجز.';
    case 'missing_alternative_energy_source':
      return 'يمتد الحجز بعد انتهاء وقت الطاقة الشمسية. اختر مصدر الطاقة البديل.';
    case 'missing_energy_source':
      return 'اختر مصدر الطاقة لهذا الحجز.';
    case 'unsupported_energy_source':
      return 'مصدر الطاقة المختار غير مدعوم لهذا الحجز.';
    case 'invalid_alternative_energy_source':
      return 'المصدر البديل غير صالح لهذا الحجز.';
    case 'invalid_period':
      return 'الموعد غير صالح — يجب أن تكون النهاية بعد البداية.';
    case 'active_pump_missing':
      return 'لا توجد مضخة فعّالة لهذا البئر. راجع إعداد البئر أولًا.';
    case 'active_pump_ambiguous':
      return 'إعداد المضخات غير واضح لهذا البئر. راجع إعداد البئر أولًا.';
    default:
      return null;
  }
}

/// تنبيه بجوار قسم الطاقة: أحمر للخطأ، كهرماني للإرشاد. سطر أو أكثر.
class _EnergyNotice extends StatelessWidget {
  const _EnergyNotice({required this.error, required this.lines});
  final bool error;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final color = error ? AppColors.error : AppColors.warning;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            error ? Icons.error_outline_rounded : Icons.wb_sunny_outlined,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < lines.length; i++) ...[
                  if (i > 0) const SizedBox(height: 3),
                  Text(
                    lines[i],
                    style: TextStyle(
                      fontSize: i == 0 ? 13.5 : 12.5,
                      fontWeight: i == 0 ? FontWeight.bold : FontWeight.w500,
                      color: i == 0 ? color : AppColors.textSecondary,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../core/api/manual_session_entry_capability.dart';
import '../../core/api/operations_repository.dart';
import '../../core/identity/app_identity.dart';
import '../../core/session/offline_session_coordinator.dart';
import '../../core/sync/command_envelope.dart';
import '../../core/sync/command_type.dart';
import '../../core/sync/manual_session_entry.dart';
import '../../core/sync/sync_status.dart';
import 'manual_session_entry_form.dart';
import 'manual_session_entry_summary.dart';
import 'manual_session_farm_picker.dart';

class ManualSessionEntryScreen extends StatefulWidget {
  const ManualSessionEntryScreen({
    super.key,
    required this.identity,
    this.capability,
    required this.repository,
    this.coordinator,
    this.existingCommand,
    this.existingLocalId,
    this.initialFacts,
    this.correctionSourceLocalId,
  });
  final AppIdentity identity;
  final ManualSessionEntryCapability? capability;
  final OperationsRepository repository;
  final OfflineSessionCoordinator? coordinator;
  final CommandEnvelope? existingCommand;
  final String? existingLocalId;
  final ManualSessionEntryFacts? initialFacts;
  final String? correctionSourceLocalId;
  @override
  State<ManualSessionEntryScreen> createState() =>
      _ManualSessionEntryScreenState();
}

class _ManualSessionEntryScreenState extends State<ManualSessionEntryScreen> {
  late final ManualSessionEntryForm _form;
  final _startText = TextEditingController(text: 'اختيار التاريخ والوقت');
  final _endText = TextEditingController(text: 'اختيار التاريخ والوقت');
  final _scroll = ScrollController();
  final _farmText = TextEditingController();
  late final String _initialAccount;
  int _loadGeneration = 0;
  final _reasonText = TextEditingController();
  final _notesText = TextEditingController();
  ManualSessionEntryFollowUp? _followUp;
  String? _savedLocalId;
  bool _departureStarted = false, _acceptNavigationConsumed = false;
  bool _initialObservationPending = false;
  int _readGeneration = 0;
  ModalRoute<dynamic>? _ownerRoute;
  NavigatorState? _ownerNavigator;
  bool get _mayMutate =>
      mounted && !_departureStarted && !_acceptNavigationConsumed;
  bool get _routeIsCurrent =>
      _mayMutate &&
      (_ownerRoute?.isCurrent ?? false) &&
      (_ownerNavigator?.mounted ?? false) &&
      !(_ownerNavigator?.userGestureInProgress ?? false);
  bool get _mayApply => _routeIsCurrent && _sameScope;
  bool _currentRead(int generation) =>
      _mayMutate && _sameScope && generation == _readGeneration;
  bool _ownsRead(int generation) => _currentRead(generation) && _routeIsCurrent;

  void _beginDeparture() {
    if (_departureStarted) return;
    _departureStarted = true;
    _readGeneration++;
  }

  void _leave([ManualSessionEntryOutcome? outcome]) {
    if (!_routeIsCurrent) return;
    if (outcome?.state == ManualSessionEntryState.accepted) {
      _acceptNavigationConsumed = true;
    }
    _beginDeparture();
    _ownerNavigator!.pop(outcome);
  }

  bool get _isCorrection => widget.correctionSourceLocalId != null;
  OfflineSessionCoordinator get _coordinator =>
      widget.coordinator ?? OfflineSessionCoordinator.instance;
  List<FarmerAccount> _farmers = [];
  List<Pump> _pumps = [];
  Map<String, String> _errors = {};
  bool _loading = true, _busy = false, _saved = false;
  CommandEnvelope? _intent;
  String? _loadError, _message;
  bool get _locked => _busy || _intent != null;
  bool get _sameScope =>
      widget.identity.accountId == _initialAccount &&
      widget.identity.activeWell.id == _form.wellId;
  bool get _scopeValid =>
      _sameScope && widget.capability?.wellId == _form.wellId;

  @override
  void initState() {
    super.initState();
    _initialAccount = widget.identity.accountId;
    _form = ManualSessionEntryForm(
      wellId: widget.identity.activeWell.id,
      completed: widget.initialFacts != null
          ? widget.initialFacts!.endedAt != null
          : widget.capability?.canRecordHistoricalSession ??
                widget.existingCommand?.type ==
                    CommandType.recordHistoricalSession,
    );
    _intent = widget.existingCommand;
    _savedLocalId = widget.existingLocalId ?? widget.existingCommand?.localId;
    if (_savedLocalId != null) {
      _saved = true;
      _loading = false;
      _message = 'جارٍ التحقق من إضافة الجلسة. بياناتك محفوظة.';
      _initialObservationPending = true;
    } else {
      _load();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_ownerRoute != null && _ownerRoute != route) _readGeneration++;
    _ownerRoute = route;
    _ownerNavigator = Navigator.of(context);
    if (_initialObservationPending) {
      _initialObservationPending = false;
      _observe();
    }
  }

  @override
  void didUpdateWidget(covariant ManualSessionEntryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity.accountId != widget.identity.accountId ||
        oldWidget.identity.activeWell.id != widget.identity.activeWell.id) {
      _loadGeneration++;
      _readGeneration++;
    }
  }

  @override
  void dispose() {
    _beginDeparture();
    _loadGeneration++;
    _farmText.dispose();
    _startText.dispose();
    _endText.dispose();
    _scroll.dispose();
    _reasonText.dispose();
    _notesText.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    bool current() => _mayMutate && generation == _loadGeneration && _sameScope;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      if (!_scopeValid) throw StateError('scope_changed');
      final farmers = await widget.repository.fetchFarmers(_form.wellId);
      final pumps = await widget.repository.fetchPumps(_form.wellId);
      final original = widget.initialFacts;
      Farm? originalFarm;
      if (original != null &&
          farmers.any(
            (f) =>
                f.id == original.farmerWellAccountId &&
                f.status == 'active' &&
                !f.isPending,
          )) {
        originalFarm = await resolveManualSessionFarm(
          repository: widget.repository,
          wellId: _form.wellId,
          farmerAccountId: original.farmerWellAccountId,
          farmId: original.farmId,
          isCurrent: current,
        );
      }
      if (!current()) return;
      setState(() {
        _farmers = farmers
            .where((f) => f.status == 'active' && !f.isPending)
            .toList();
        _pumps = pumps
            .where((p) => p.wellId == _form.wellId && p.status == 'active')
            .toList();
        if (original != null) {
          _form.startedAt = original.startedAt;
          _form.endedAt = original.endedAt;
          _form.energy = original.energySource;
          _form.reason = original.reason;
          _form.notes = original.notes ?? '';
          _reasonText.text = _form.reason;
          _notesText.text = _form.notes;
          _startText.text = _timeText(original.startedAt);
          _endText.text = _timeText(original.endedAt);
          for (final farmer in _farmers) {
            if (farmer.id == original.farmerWellAccountId) {
              _form.farmer = farmer;
            }
          }
          _form.farm = _form.farmer != null ? originalFarm : null;
          _farmText.text = _form.farm?.displayName ?? '';
          if (_form.farmer == null) {
            _message = 'المزارع السابق لم يعد متاحًا. اختر المزارع ثم الأرض.';
            _errors['farmer'] = 'اختر المزارع / الحساب';
          } else if (_form.farm == null) {
            _message =
                'الأرض السابقة لم تعد متاحة لهذا المزارع. اختر أرضًا أخرى.';
            _errors['farm'] = 'اختر أرضًا أخرى';
          }
          for (final pump in _pumps) {
            if (pump.id == original.pumpId) _form.pump = pump;
          }
        }
        _loading = false;
      });
    } catch (_) {
      if (current()) {
        setState(() {
          _loading = false;
          _loadError =
              'تعذر تحميل خيارات الجلسة. تحقق من الاتصال وأعد المحاولة.';
        });
      }
    }
  }

  void _selectFarmer(FarmerAccount? farmer) {
    setState(() {
      _form.selectFarmer(farmer);
      _farmText.clear();
    });
  }

  Future<void> _pickFarm() async {
    final farmer = _form.farmer;
    if (_locked || !_sameScope || farmer == null) return;
    FocusScope.of(context).unfocus();
    final well = _form.wellId;
    bool current() =>
        _mayMutate &&
        _sameScope &&
        _form.wellId == well &&
        _form.farmer?.id == farmer.id;
    final selected = await showModalBottomSheet<Farm>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: MediaQuery.viewInsetsOf(context),
        child: FractionallySizedBox(
          heightFactor: 0.85,
          child: ManualSessionFarmPicker(
            repository: widget.repository,
            wellId: well,
            farmerAccountId: farmer.id,
            selectedFarm: _form.farm,
            isCurrent: current,
          ),
        ),
      ),
    );
    if (!current() || selected == null) return;
    if (selected.wellId != well ||
        selected.farmerAccountId != farmer.id ||
        selected.status != 'active' ||
        selected.isPending) {
      return;
    }
    setState(() {
      _form.farm = selected;
      _farmText.text = selected.displayName;
      _errors.remove('farm');
    });
  }

  String _timeText(DateTime? value) {
    if (value == null) return 'اختيار التاريخ والوقت';
    final v = value.toLocal();
    return '${v.year}/${v.month}/${v.day}  ${v.hour.toString().padLeft(2, '0')}:${v.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _pickTime(bool start) async {
    FocusScope.of(context).unfocus();
    final current =
        (start ? _form.startedAt : _form.endedAt)?.toLocal() ?? DateTime.now();
    final today = DateUtils.dateOnly(DateTime.now());
    final date = await showDatePicker(
      context: context,
      initialDate: DateUtils.dateOnly(current),
      firstDate: DateTime(1),
      lastDate: today,
      initialEntryMode: DatePickerEntryMode.input,
      helpText: start ? 'تاريخ البداية الفعلية' : 'تاريخ النهاية الفعلية',
      confirmText: 'اختيار',
      cancelText: 'إلغاء',
    );
    if (!mounted || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      initialEntryMode: TimePickerEntryMode.input,
      confirmText: 'اختيار',
      cancelText: 'إلغاء',
    );
    if (!mounted || time == null) return;
    final value = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    setState(() {
      if (start) {
        _form.startedAt = value;
        _startText.text = _timeText(value);
      } else {
        _form.endedAt = value;
        _endText.text = _timeText(value);
      }
    });
  }

  Future<void> _submit() async {
    if (_busy || _saved || !_scopeValid || !_routeIsCurrent) return;
    FocusScope.of(context).unfocus();
    if (_intent == null) {
      final errors = _form.validate(DateTime.now());
      setState(() => _errors = errors);
      if (errors.isNotEmpty) return;
      if (_form.completed
          ? widget.capability?.canRecordHistoricalSession != true
          : widget.capability?.canAdoptExternalSession != true) {
        return;
      }
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (_isCorrection && _intent == null) {
        if (!await _checkCorrectionAuthority(widget.correctionSourceLocalId!)) {
          return;
        }
        if (!mounted || !_mayApply) return;
        var answered = false;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('حفظ البيانات المصححة'),
            content: const Text(
              'سيتم حفظ البيانات المصححة كطلب جديد. سيبقى الطلب السابق محفوظًا في السجل.',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  if (answered) return;
                  answered = true;
                  Navigator.pop(dialog, false);
                },
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () {
                  if (answered) return;
                  answered = true;
                  Navigator.pop(dialog, true);
                },
                child: const Text('حفظ الطلب المصحح'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted || !_mayApply) return;
        if (!await _checkCorrectionAuthority(widget.correctionSourceLocalId!)) {
          return;
        }
      }
      _intent ??= await _coordinator.prepareManualSessionEntry(
        accountId: widget.identity.accountId,
        facts: _form.facts(DateTime.now()),
      );
      await _coordinator.submitManualSessionEntry(_intent!);
      if (!_mayApply) return;
      _saved = true;
      _savedLocalId = _intent!.localId;
      await _observe();
    } catch (_) {
      if (!_mayApply) return;
      if (_intent != null) {
        try {
          final found = await _coordinator.observeManualSessionEntry(
            accountId: widget.identity.accountId,
            wellId: _form.wellId,
            localId: _intent!.localId,
          );
          if (!_mayApply) return;
          _saved = found != null;
        } catch (_) {
          /* لا نولد هوية بديلة عند تعذر قراءة الحفظ. */
        }
      }
      if (_mayApply) {
        setState(
          () => _message = _saved
              ? 'جارٍ التحقق من إضافة الجلسة. بياناتك محفوظة.'
              : 'تعذر حفظ البيانات الآن. حاول حفظ الطلب مرة أخرى.',
        );
      }
    } finally {
      if (_mayMutate) setState(() => _busy = false);
    }
  }

  Future<void> _observe({int? generation}) async {
    final token = generation ?? ++_readGeneration;
    if (!_ownsRead(token)) return;
    final localId = _savedLocalId ?? _intent?.localId;
    if (localId == null) return;
    try {
      final view = await _coordinator.observeManualSessionEntry(
        accountId: widget.identity.accountId,
        wellId: _form.wellId,
        localId: localId,
      );
      if (!_ownsRead(token)) return;
      final followUp = await _coordinator.readManualSessionEntryFollowUp(
        accountId: widget.identity.accountId,
        wellId: _form.wellId,
        localId: localId,
      );
      if (!_ownsRead(token) || view == null || followUp == null) return;
      _followUp = followUp;
      final outcome = view.outcome;
      if (view.command.status == CommandStatus.confirmed &&
          outcome is ManualSessionEntryOutcome &&
          outcome.state == ManualSessionEntryState.accepted &&
          followUp.eligibility ==
              ManualEntryCorrectionEligibility.ineligibleSessionExists &&
          followUp.canonicalSessionId == outcome.sessionId) {
        _leave(outcome);
        return;
      }
      final eligible =
          followUp.eligibility ==
          ManualEntryCorrectionEligibility.eligibleTerminalNoSession;
      setState(
        () => _message = eligible
            ? switch (followUp.outcome) {
                ManualSessionEntryState.conflictOverlap =>
                  followUp.facts.endedAt != null
                      ? 'يوجد سجل جلسة أخرى في هذا الوقت. راجع وقت البداية أو النهاية ثم اختر «تصحيح البيانات».'
                      : 'يوجد سجل جلسة أخرى يتعارض مع وقت البداية. راجع وقت البداية ثم اختر «تصحيح البيانات».',
                ManualSessionEntryState.conflictActiveResource => 'توجد جلسة جارية بالفعل. أنهِ الجلسة الحالية أو راجع وقت الجلسة ثم اختر «تصحيح البيانات».',
                _ => 'لم تتم إضافة الجلسة. راجع البيانات ثم اختر «تصحيح البيانات».',
              }
            : view.isQueued && followUp.outcome == null
            ? 'تم حفظ الجلسة على الجهاز، وسيتم إكمال إضافتها عند توفر الاتصال.'
            : 'جارٍ التحقق من إضافة الجلسة. بياناتك محفوظة.',
      );
    } catch (_) {
      if (_ownsRead(token)) {
        setState(() {
          _followUp = null;
          _message = 'تعذر إكمال الإضافة الآن. بياناتك محفوظة. يمكنك التحقق من حالتها لاحقًا.';
        });
      }
    }
  }

  void _notice(String message) {
    if (!_mayApply) return;
    setState(() => _message = message);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_mayApply && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  Future<bool> _checkCorrectionAuthority(String localId) async {
    try {
      final capability = await widget.repository
          .fetchManualSessionEntryCapability(
            accountId: widget.identity.accountId,
            wellId: _form.wellId,
          );
      if (!_mayApply) return false;
      final mode =
          widget.initialFacts?.endedAt != null ||
          (!_isCorrection && _followUp?.facts.endedAt != null);
      if (capability.wellId != _form.wellId) throw StateError('scope_changed');
      if (mode
          ? !capability.canRecordHistoricalSession
          : !capability.canAdoptExternalSession) {
        _notice('لا تتوفر لك إمكانية إضافة هذا النوع من الجلسات حاليًا.');
        return false;
      }
      final current = await _coordinator.readManualSessionEntryFollowUp(
        accountId: widget.identity.accountId,
        wellId: _form.wellId,
        localId: localId,
      );
      if (!_mayApply) return false;
      if (current?.eligibility !=
          ManualEntryCorrectionEligibility.eligibleTerminalNoSession) {
        _notice('تعذر تأكيد إمكانية تصحيح هذا الطلب الآن. تابع حالته لاحقًا.');
        return false;
      }
      return true;
    } catch (_) {
      if (_mayApply) {
        _notice(
          'تعذر التحقق من إمكانية تصحيح البيانات. تحقق من الاتصال وحاول مجددًا.',
        );
      }
      return false;
    }
  }

  Future<void> _correct() async {
    final source = _followUp;
    if (_busy ||
        !_mayApply ||
        source?.eligibility !=
            ManualEntryCorrectionEligibility.eligibleTerminalNoSession) {
      return;
    }
    setState(() => _busy = true);
    try {
      final capability = await widget.repository
          .fetchManualSessionEntryCapability(
            accountId: widget.identity.accountId,
            wellId: _form.wellId,
          );
      if (!_mayApply) return;
      if (capability.wellId != _form.wellId) throw StateError('scope_changed');
      final completed = source!.facts.endedAt != null;
      if (completed
          ? !capability.canRecordHistoricalSession
          : !capability.canAdoptExternalSession) {
        _notice('لا تتوفر لك إمكانية إضافة هذا النوع من الجلسات حاليًا.');
        return;
      }
      final current = await _coordinator.readManualSessionEntryFollowUp(
        accountId: widget.identity.accountId,
        wellId: _form.wellId,
        localId: source.localId,
      );
      if (!_mayApply) return;
      if (current?.eligibility !=
          ManualEntryCorrectionEligibility.eligibleTerminalNoSession) {
        await _observe();
        return;
      }
      _readGeneration++; // لا تحمل القراءة السابقة سلطة التنقل إلى شاشة التصحيح.
      final outcome = await _ownerNavigator!
          .push<ManualSessionEntryOutcome>(
            MaterialPageRoute(
              builder: (_) => ManualSessionEntryScreen(
                identity: widget.identity,
                capability: capability,
                repository: widget.repository,
                coordinator: widget.coordinator,
                initialFacts: current!.facts,
                correctionSourceLocalId: current.localId,
              ),
            ),
          );
      if (_mayApply) _leave(outcome);
    } catch (_) {
      if (_mayApply) {
        _notice(
          'تعذر التحقق من إمكانية تصحيح البيانات. تحقق من الاتصال وحاول مجددًا.',
        );
      }
    } finally {
      if (_mayMutate) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    if (_busy || !_mayApply) return;
    final generation = ++_readGeneration;
    setState(() => _busy = true);
    try {
      if (_coordinator.canSyncNow) {
        await _coordinator.syncNow(widget.identity.accountId);
      }
      if (!_ownsRead(generation)) return;
      await _observe(generation: generation);
    } catch (_) {
      if (_ownsRead(generation)) {
        setState(
          () => _message = 'تعذر التحقق الآن. بياناتك محفوظة، تحقق من الاتصال وأعد تحديث الحالة.',
        );
      }
    } finally {
      // تنظيف الجيل الحالي آمن حتى لو غطت الصفحة نافذة أخرى مؤقتًا.
      if (_currentRead(generation)) setState(() => _busy = false);
    }
  }

  Widget _dateField(String key, String label, bool start) => TextFormField(
    key: ValueKey(key),
    readOnly: true,
    enabled: !_locked,
    controller: start ? _startText : _endText,
    decoration: InputDecoration(
      labelText: label,
      errorText: _errors[key],
      suffixIcon: const Icon(Icons.calendar_month_rounded),
    ),
    onTap: () => _pickTime(start),
  );

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: PopScope<ManualSessionEntryOutcome>(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _beginDeparture();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('إضافة جلسة سقي سابقة')),
        body: SafeArea(
          child: !_sameScope
              ? const Center(
                  child: Text(
                    'تغير البئر أو الحساب. ارجع إلى السجل وافتح إضافة الجلسة مجددًا.',
                  ),
                )
              : _loading
              ? const Center(child: CircularProgressIndicator())
              : _loadError != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_loadError!, textAlign: TextAlign.center),
                      TextButton(
                        onPressed: _load,
                        child: const Text('إعادة المحاولة'),
                      ),
                    ],
                  ),
                )
              : ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(16),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  children: [
                    if (_saved && _followUp != null) ...[
                      ManualSessionEntrySummary(
                        key: const ValueKey('manual-follow-up-summary'),
                        facts: _followUp!.facts,
                        farmerName: _form.farmer?.fullName,
                        farmName: _form.farm?.displayName,
                        pumpName: _form.pump?.name,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_message != null)
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _message!,
                          key: const ValueKey('manual-entry-message'),
                        ),
                      ),
                    if (!_saved) ...[
                      if (_isCorrection) ...[
                        const Text('تصحيح بيانات الجلسة التي لم تتم إضافتها'),
                        const Text(
                          'سيبقى الطلب السابق محفوظًا، وسيُحفظ التصحيح كطلب جديد بعد تأكيدك.',
                        ),
                      ] else
                        const Text('هل انتهت الجلسة؟'),
                      Wrap(
                        spacing: 8,
                        children: [
                          if (widget.capability?.canRecordHistoricalSession ==
                                  true &&
                              (!_isCorrection || _form.completed))
                            ChoiceChip(
                              label: const Text('جلسة منتهية'),
                              selected: _form.completed,
                              onSelected: _locked || _isCorrection
                                  ? null
                                  : (_) => setState(
                                      () => _form.setCompleted(true),
                                    ),
                            ),
                          if (widget.capability?.canAdoptExternalSession ==
                                  true &&
                              (!_isCorrection || !_form.completed))
                            ChoiceChip(
                              label: const Text('جلسة ما زالت جارية'),
                              selected: !_form.completed,
                              onSelected: _locked || _isCorrection
                                  ? null
                                  : (_) => setState(() {
                                      _form.setCompleted(false);
                                      _endText.text = 'اختيار التاريخ والوقت';
                                    }),
                            ),
                        ],
                      ),
                      DropdownButtonFormField<FarmerAccount>(
                        key: const ValueKey('farmer'),
                        initialValue: _form.farmer,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: 'المزارع / الحساب',
                          errorText: _errors['farmer'],
                        ),
                        items: [
                          for (final f in _farmers)
                            DropdownMenuItem(value: f, child: Text(f.fullName)),
                        ],
                        onChanged: _locked ? null : _selectFarmer,
                      ),
                      TextFormField(
                        key: ValueKey('farm-${_form.farmer?.id}'),
                        controller: _farmText,
                        readOnly: true,
                        enabled: !_locked && _form.farmer != null,
                        decoration: InputDecoration(
                          labelText: 'الأرض / المزرعة',
                          hintText: 'اختر الأرض',
                          errorText: _errors['farm'],
                          suffixIcon: const Icon(Icons.search),
                        ),
                        onTap: _pickFarm,
                      ),
                      DropdownButtonFormField<Pump>(
                        key: const ValueKey('pump'),
                        initialValue: _form.pump,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: 'المضخة',
                          errorText: _errors['pump'],
                        ),
                        items: [
                          for (final p in _pumps)
                            DropdownMenuItem(value: p, child: Text(p.name)),
                        ],
                        onChanged: _locked
                            ? null
                            : (v) => setState(() => _form.pump = v),
                      ),
                      _dateField('startedAt', 'وقت البداية الفعلي', true),
                      if (_form.completed)
                        _dateField('endedAt', 'وقت النهاية الفعلي', false),
                      DropdownButtonFormField<String>(
                        key: const ValueKey('energy'),
                        initialValue: _form.energy,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: 'مصدر الطاقة',
                          errorText: _errors['energy'],
                        ),
                        items: [
                          for (final e in kEnergySourceLabels.entries)
                            DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ),
                        ],
                        onChanged: _locked
                            ? null
                            : (v) => setState(() => _form.energy = v),
                      ),
                      TextFormField(
                        key: const ValueKey('reason'),
                        controller: _reasonText,
                        enabled: !_locked,
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: 'سبب إضافة الجلسة لاحقًا',
                          helperText: 'لتوثيق سبب تسجيلها بعد حدوثها',
                          errorText: _errors['reason'],
                        ),
                        onChanged: (v) => _form.reason = v,
                      ),
                      TextFormField(
                        key: const ValueKey('notes'),
                        controller: _notesText,
                        enabled: !_locked,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'ملاحظات (اختياري)',
                        ),
                        onChanged: (v) => _form.notes = v,
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: Text(_busy ? 'جارٍ الحفظ…' : 'حفظ الجلسة'),
                      ),
                    ] else ...[
                      if (_followUp?.eligibility ==
                          ManualEntryCorrectionEligibility
                              .eligibleTerminalNoSession)
                        FilledButton(
                          onPressed: _busy ? null : _correct,
                          child: const Text('تصحيح البيانات'),
                        ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _busy ? null : _refresh,
                        child: Text(_busy ? 'جارٍ التحقق…' : 'تحديث الحالة'),
                      ),
                      TextButton(
                        onPressed: () => _leave(),
                        child: const Text('العودة للسجل'),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    ),
  );
}

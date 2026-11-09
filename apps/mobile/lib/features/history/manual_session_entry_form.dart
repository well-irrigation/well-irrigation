import '../../core/api/operations_repository.dart';
import '../../core/sync/manual_session_entry.dart';

/// حالة نموذج غير محفوظ فقط؛ بعد الإرسال يكون الطابور مصدر الحقيقة.
class ManualSessionEntryForm {
  ManualSessionEntryForm({required this.wellId, required this.completed});
  final String wellId;
  bool completed;
  FarmerAccount? farmer;
  Farm? farm;
  Pump? pump;
  String? energy;
  DateTime? startedAt, endedAt;
  String reason = '', notes = '';

  void selectFarmer(FarmerAccount? value) {
    farmer = value;
    farm = null;
  }

  void setCompleted(bool value) {
    completed = value;
    if (!value) endedAt = null;
  }

  Map<String, String> validate(DateTime now) => {
    if (farmer == null || farmer!.id.isEmpty || farmer!.isPending)
      'farmer': 'اختر المزارع / الحساب',
    if (farm == null ||
        farm!.id.isEmpty ||
        farm!.wellId != wellId ||
        farm!.farmerAccountId != farmer?.id)
      'farm': 'اختر أرضًا لهذا المزارع',
    if (pump == null || pump!.id.isEmpty || pump!.wellId != wellId)
      'pump': 'اختر المضخة',
    if (!kSessionEnergySources.contains(energy)) 'energy': 'اختر مصدر الطاقة',
    if (startedAt == null)
      'startedAt': 'اختر وقت البداية الفعلي'
    else if (startedAt!.isAfter(now))
      'startedAt': 'لا يمكن أن تكون البداية في المستقبل',
    if (completed && endedAt == null)
      'endedAt': 'اختر وقت النهاية الفعلي'
    else if (completed && endedAt!.isAfter(now))
      'endedAt': 'لا يمكن أن تكون النهاية في المستقبل'
    else if (completed && startedAt != null && !startedAt!.isBefore(endedAt!))
      'endedAt': 'يجب أن تكون النهاية بعد البداية',
    if (reason.trim().isEmpty) 'reason': 'اكتب سبب إضافة الجلسة لاحقًا',
  };

  ManualSessionEntryFacts facts(DateTime now) {
    if (validate(now).isNotEmpty) throw StateError('invalid_manual_entry_form');
    return ManualSessionEntryFacts(
      wellId: wellId,
      farmerWellAccountId: farmer!.id,
      farmId: farm!.id,
      pumpId: pump!.id,
      startedAt: startedAt!,
      endedAt: completed ? endedAt : null,
      energySource: energy!,
      reason: reason,
      notes: notes.trim().isEmpty ? null : notes.trim(),
    );
  }
}

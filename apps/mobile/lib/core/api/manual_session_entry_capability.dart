/// أسباب تعذر القراءة منفصلة عن رفض الصلاحية الصحيح القادم من الخادم.
enum ManualSessionEntryCapabilityFailure {
  unavailable,
  authentication,
  forbidden,
  network,
  malformed,
  unsupportedVersion,
  scopeMismatch,
  identityChanged,
}

class ManualSessionEntryCapabilityUnavailable implements Exception {
  const ManualSessionEntryCapabilityUnavailable(this.kind);
  final ManualSessionEntryCapabilityFailure kind;
}

/// صلاحية مقروءة للبئر المطلوب؛ لا دور محلي ولا بيانات JSON في سطح العرض.
class ManualSessionEntryCapability {
  const ManualSessionEntryCapability._({
    required this.wellId,
    required this.canRecordHistoricalSession,
    required this.canAdoptExternalSession,
  });

  factory ManualSessionEntryCapability.fromContract(
    Object? raw, {
    required String wellId,
  }) {
    const malformed = ManualSessionEntryCapabilityUnavailable(
      ManualSessionEntryCapabilityFailure.malformed,
    );
    if (wellId.isEmpty || wellId.trim() != wellId || raw is! Map ||
        raw['contract'] != 'manual_session_entry_capability' ||
        raw['version'] is! int || raw['well_id'] is! String ||
        (raw['well_id'] as String).isEmpty ||
        raw['can_record_historical_session'] is! bool ||
        raw['can_adopt_external_session'] is! bool) {
      throw malformed;
    }
    if (raw['version'] != 1) {
      throw const ManualSessionEntryCapabilityUnavailable(
        ManualSessionEntryCapabilityFailure.unsupportedVersion,
      );
    }
    if (raw['well_id'] != wellId) {
      throw const ManualSessionEntryCapabilityUnavailable(
        ManualSessionEntryCapabilityFailure.scopeMismatch,
      );
    }
    return ManualSessionEntryCapability._(
      wellId: wellId,
      canRecordHistoricalSession: raw['can_record_historical_session'] as bool,
      canAdoptExternalSession: raw['can_adopt_external_session'] as bool,
    );
  }

  String get contract => 'manual_session_entry_capability';
  int get version => 1;
  final String wellId;
  final bool canRecordHistoricalSession;
  final bool canAdoptExternalSession;
}

/// المستقبل المنتظر يمثل التحميل، والنجاح بيانات، والفشل استثناء نوعي.
abstract interface class ManualSessionEntryCapabilityReader {
  Future<ManualSessionEntryCapability> fetchManualSessionEntryCapability({
    required String accountId,
    required String wellId,
  });
}

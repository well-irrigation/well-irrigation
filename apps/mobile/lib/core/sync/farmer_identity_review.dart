import 'command_envelope.dart';
import 'command_type.dart';
import 'sync_status.dart';

/// مرشح مطابق أو مشتبه به من الخادم (ق-84 / ق-88).
///
/// لا يحتوي إلا البيانات الآمنة التي تعيدها الهجرة 102 (`core.find_person_duplicates`):
/// المعرّف والكود العام والاسم ودرجة التطابق ومجال التطابق.
/// لا يخترع بيانات هاتف أو أرقامًا غير مرسلة من الخادم.
class FarmerDuplicateCandidate {
  const FarmerDuplicateCandidate({
    required this.personId,
    required this.publicCode,
    required this.fullName,
    required this.matchLevel,
    required this.matchedOn,
  });

  final String personId;
  final String publicCode;
  final String fullName;
  final String matchLevel;
  final String matchedOn;

  /// وصف سبب التطابق بالعربية للعرض في الواجهة
  String get matchedOnDescription {
    switch (matchedOn) {
      case 'name+phone':
        return 'تطابق في الاسم ورقم الهاتف';
      case 'phone':
        return 'تطابق في رقم الهاتف';
      case 'name':
        return 'تشابه في الاسم';
      default:
        return matchedOn;
    }
  }

  /// درجة التطابق بالعربية
  String get matchLevelDescription {
    switch (matchLevel) {
      case 'match':
        return 'مطابقة تامة';
      case 'suspect':
        return 'اشتباه تكرار';
      default:
        return matchLevel;
    }
  }

  static FarmerDuplicateCandidate? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final personId = raw['person_id']?.toString();
    final publicCode = raw['public_code']?.toString();
    final fullName = raw['full_name']?.toString();
    final matchLevel = raw['match_level']?.toString();
    final matchedOn = raw['matched_on']?.toString();

    if (personId == null ||
        personId.isEmpty ||
        publicCode == null ||
        fullName == null ||
        matchLevel == null ||
        matchedOn == null) {
      return null;
    }

    return FarmerDuplicateCandidate(
      personId: personId,
      publicCode: publicCode,
      fullName: fullName,
      matchLevel: matchLevel,
      matchedOn: matchedOn,
    );
  }
}

/// تمثيل مهيكل لعملية إنشاء مزارع تحتاج مراجعة وحسمًا بشريًا (ق-88 / ق-114).
///
/// يستخرج البيانات الأصلية المدخلة وقائمة المرشحين من الرد المهيكل بأمان،
/// ويفشل مغلقًا إن كانت الحمولة معطوبة أو مشوهة.
class FarmerIdentityReview {
  const FarmerIdentityReview({
    required this.commandLocalId,
    required this.commandId,
    required this.wellId,
    required this.fullName,
    this.phone,
    this.preferredName,
    this.notes,
    this.creditLimitMinor,
    required this.candidates,
    required this.occurredAt,
  });

  final String commandLocalId;
  final String commandId;
  final String wellId;
  final String fullName;
  final String? phone;
  final String? preferredName;
  final String? notes;
  final int? creditLimitMinor;
  final List<FarmerDuplicateCandidate> candidates;
  final DateTime occurredAt;

  static FarmerIdentityReview? fromCommand(CommandEnvelope envelope) {
    if (envelope.type != CommandType.createFarmer ||
        envelope.status != CommandStatus.review) {
      return null;
    }

    final serverResponse = envelope.serverResponse;
    if (serverResponse == null ||
        serverResponse['status'] != 'requires_resolution') {
      return null;
    }

    final rawCandidates = serverResponse['duplicate_candidates'];
    if (rawCandidates is! List) {
      return null;
    }

    final candidates = <FarmerDuplicateCandidate>[];
    for (final item in rawCandidates) {
      final candidate = FarmerDuplicateCandidate.fromJson(item);
      if (candidate != null) {
        candidates.add(candidate);
      }
    }

    final payload = envelope.payload;
    final fullName = payload['p_full_name']?.toString();
    if (fullName == null || fullName.trim().isEmpty) {
      return null;
    }

    final wellId = envelope.wellId ?? payload['p_well_id']?.toString() ?? '';

    final creditLimitRaw = payload['p_credit_limit_minor'];
    final creditLimit = creditLimitRaw is num ? creditLimitRaw.toInt() : null;

    return FarmerIdentityReview(
      commandLocalId: envelope.localId,
      commandId: envelope.commandId,
      wellId: wellId,
      fullName: fullName.trim(),
      phone: payload['p_phone']?.toString().trim(),
      preferredName: payload['p_preferred_name']?.toString().trim(),
      notes: payload['p_notes']?.toString().trim(),
      creditLimitMinor: creditLimit,
      candidates: List.unmodifiable(candidates),
      occurredAt: envelope.occurredAt,
    );
  }
}

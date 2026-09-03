import 'package:flutter/foundation.dart';

import '../api/app_bootstrap_repository.dart';

/// هوية الجولة الحالية كما يعيدها عقد `api.app_bootstrap` وحده (ق-82 / ق-113).
///
/// لا حقل هنا له قيمة افتراضية، ولا يُشتق أي حقل في العميل:
/// - `accountId` هو `iam.profiles.id` = `auth.uid()` كما يعيده العقد، وهو
///   نفسه مفتاح الطابور المحلي — فلا يُقرأ الطابور بمفتاح ويُكتب بآخر.
/// - `activeWell` بئر حقيقي من `wells`، لا بئر مُلفَّق باسم ثابت.
///
/// غياب أي منهما ليس فراغًا يُملأ، بل حالة تُعلَن: انظر [resolveIdentity].
@immutable
class AppIdentity {
  const AppIdentity({
    required this.profile,
    required this.wells,
    required this.activeWell,
  });

  final UserProfile profile;
  final List<WellSummary> wells;
  final WellSummary activeWell;

  /// هوية صاحب العملية ومفتاح الطابور المحلي. مصدره العقد لا العميل.
  String get accountId => profile.id;

  /// الاسم كما سجّله الخادم. فارغ = لا اسم مسجَّل، ولا يُخترع بديل هنا.
  String get displayName => profile.fullName;

  /// دور المستخدم على البئر النشط وحده — لا دور افتراضي، ويتغيّر بالتبديل.
  bool get isOwner => activeWell.isOwner;

  /// شريكٌ بلا دور تشغيلي على البئر النشط. شاشته اطلاع فقط (ق-123 §8).
  bool get isPartnerOnly => activeWell.isPartnerOnly;

  AppIdentity withActiveWell(WellSummary well) => AppIdentity(
    profile: profile,
    wells: wells,
    activeWell: well,
  );
}

/// نتيجة قراءة الهوية: ثلاث حالات صريحة لا رابعة، ولا واحدة منها تُعبَّأ
/// بقيمة مُختلَقة عند النقص.
sealed class IdentityResolution {
  const IdentityResolution();
}

/// هوية كاملة صالحة للعمل.
final class IdentityReady extends IdentityResolution {
  const IdentityReady(this.identity);

  final AppIdentity identity;
}

/// الحساب مصدَّق، لكن لا بئر مرتبط به بعد. حالة مشروعة لا فشل.
final class IdentityWithoutWell extends IdentityResolution {
  const IdentityWithoutWell();
}

/// تعذّرت قراءة الهوية، أو وصلت الحمولة ناقصة. لا تُكمَّل في العميل.
final class IdentityUnavailable extends IdentityResolution {
  const IdentityUnavailable(this.reason);

  final String reason;
}

/// يحوّل حمولة العقد إلى حالة واحدة من الثلاث. دالة خالصة قابلة للقياس.
IdentityResolution resolveIdentity(BootstrapData data) {
  if (data.profile.id.isEmpty) {
    return const IdentityUnavailable('استجابة الحساب وصلت بلا هوية مستخدم');
  }

  final wells = data.wells
      .where((well) => well.id.isNotEmpty)
      .toList(growable: false);

  if (wells.isEmpty) {
    return const IdentityWithoutWell();
  }

  return IdentityReady(
    AppIdentity(
      profile: data.profile,
      wells: wells,
      activeWell: wells.first,
    ),
  );
}

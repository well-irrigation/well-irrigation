import 'package:well_irrigation_mobile/core/api/app_bootstrap_repository.dart';
import 'package:well_irrigation_mobile/core/identity/app_identity.dart';

/// هوية جولة صريحة للاختبارات وحدها (ق-113).
///
/// كل قيمة جاهزة يحتاجها اختبار تُكتب هنا، لا في `lib/`: التطبيق يبني هويته من
/// `api.app_bootstrap()` فقط، والاختبار يبني هويته من هذه الدالة فقط. فصلهما
/// هو ما يمنع رجوع «بئر الخير الرئيسي» و`well-1` و`active-user` إلى الشاشات
/// بحجة أن الاختبارات تحتاجها.
WellSummary testWell({
  String id = 'well-1',
  String tenantId = 'tenant-1',
  String name = 'بئر الخير الرئيسي',
  String? location,
  String status = 'active',
  List<String> roles = const ['owner'],
}) {
  return WellSummary(
    id: id,
    tenantId: tenantId,
    name: name,
    location: location,
    status: status,
    roles: roles,
  );
}

UserProfile testProfile({
  String id = 'user-test-1',
  String fullName = 'مستخدم الاختبار',
  String phone = '770000000',
  bool isPlatformAdmin = false,
}) {
  return UserProfile(
    id: id,
    fullName: fullName,
    phone: phone,
    isPlatformAdmin: isPlatformAdmin,
  );
}

/// [wells] فارغة تعني «بئر واحد افتراضي»، و[activeWell] غيابه يعني أول بئر.
/// لا هوية بلا بئر نشط: تلك حالة `IdentityWithoutWell` وتُختبر عبر البوابة.
AppIdentity testIdentity({
  String accountId = 'user-test-1',
  String fullName = 'مستخدم الاختبار',
  String phone = '770000000',
  bool isPlatformAdmin = false,
  List<WellSummary>? wells,
  WellSummary? activeWell,
}) {
  final list = (wells == null || wells.isEmpty) ? [testWell()] : wells;
  return AppIdentity(
    profile: testProfile(
      id: accountId,
      fullName: fullName,
      phone: phone,
      isPlatformAdmin: isPlatformAdmin,
    ),
    wells: list,
    activeWell: activeWell ?? list.first,
  );
}

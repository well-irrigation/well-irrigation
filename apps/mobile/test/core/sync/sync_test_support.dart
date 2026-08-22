/// أدوات مشتركة لاختبارات المزامنة.
///
/// حمولات الأوامر هنا تطابق توقيعات أغلفة `api` في Migration 084
/// حرفيًا، حتى يكون فشل الاختبار دليلًا على خطأ في التطبيق لا على
/// حمولة مخترعة.
library;

import 'package:well_irrigation_mobile/core/sync/command_id_generator.dart';

/// ساعة الاختبار. تُقرأ من كل مكوّن عبر `clock`، فلا شيء ينادي
/// `DateTime.now()` مباشرة داخل الاختبار.
DateTime testNow = DateTime.utc(2026, 8, 22, 6);

DateTime clock() => testNow;

void advanceClock(Duration duration) {
  testNow = testNow.add(duration);
}

const String accountA = 'account-a';
const String accountB = 'account-b';
const String wellOne = 'well-0000-0000-0001';
const String wellTwo = 'well-0000-0000-0002';

/// مولّد متسلسل حتمي — يجعل رسائل فشل الاختبار مقروءة.
class SequentialIdGenerator implements IdGenerator {
  SequentialIdGenerator({this.prefix = 'id'});

  final String prefix;
  int _counter = 0;

  @override
  String newId() => '$prefix-${++_counter}';
}

Map<String, Object?> createFarmerPayload({
  String well = wellOne,
  String fullName = 'محمد بن سالم',
}) => {'p_well_id': well, 'p_full_name': fullName};

Map<String, Object?> createFarmPayload({
  required Object farmerWellAccount,
  String well = wellOne,
  String name = 'الأرض الشرقية',
}) => {
  'p_well_id': well,
  'p_name': name,
  'p_farmer_well_account_id': farmerWellAccount,
};

Map<String, Object?> startSessionPayload({
  required Object farm,
  required Object farmerWellAccount,
  String well = wellOne,
  String pump = 'pump-0000-0001',
  String energySource = 'diesel',
}) => {
  'p_well_id': well,
  'p_pump_id': pump,
  'p_farm_id': farm,
  'p_farmer_well_account_id': farmerWellAccount,
  'p_energy_source': energySource,
};

Map<String, Object?> sessionEventPayload({
  required Object session,
  Map<String, Object?> extra = const {},
}) => {'p_session_id': session, ...extra};

Map<String, Object?> recordPaymentPayload({
  required Object farmerWellAccount,
  String well = wellOne,
  int amountMinor = 250000,
  String method = 'cash',
}) => {
  'p_well_id': well,
  'p_farmer_well_account_id': farmerWellAccount,
  'p_amount_minor': amountMinor,
  'p_method': method,
};

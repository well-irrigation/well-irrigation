import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

List<File> _sourceFiles() {
  final lib = Directory('lib');

  if (!lib.existsSync()) {
    throw StateError('Run this test from the apps/mobile package directory.');
  }

  return lib
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

String _normalizedPath(File file) => file.path.replaceAll('\\', '/');

List<String> _collectMatches(RegExp pattern, {required int captureGroup}) {
  final hits = <String>[];

  for (final file in _sourceFiles()) {
    final source = file.readAsStringSync();

    for (final match in pattern.allMatches(source)) {
      final value = match.group(captureGroup);
      if (value != null) {
        hits.add('${_normalizedPath(file)}|$value');
      }
    }
  }

  hits.sort();
  return hits;
}

void _expectKnownDebt({
  required String label,
  required List<String> actual,
  required List<String> expected,
}) {
  final sortedExpected = [...expected]..sort();

  expect(
    actual,
    sortedExpected,
    reason:
        '$label changed.\n'
        'Known debt may only shrink intentionally. '
        'Any new Data API boundary violation must fail this test.',
  );
}

void main() {
  test('internal schemas are never addressed from Flutter', () {
    final actual = _collectMatches(
      RegExp(
        r'''\.schema\s*\(\s*['"](core|iam|ops|billing|finance|inventory|audit|sync|reporting|public)['"]\s*\)''',
      ),
      captureGroup: 1,
    );

    // لا دين هنا: كل النداءات تمر عبر مخطط api وحده (ق-82).
    const expected = <String>[];

    _expectKnownDebt(
      label: 'Internal-schema debt',
      actual: actual,
      expected: expected,
    );
  });

  test('operations reads use the official api read contracts', () {
    final source = File(
      'lib/core/api/operations_repository.dart',
    ).readAsStringSync();

    final start = source.indexOf(
      'Future<List<FarmerAccount>> fetchFarmers',
    );
    final end = source.indexOf(
      '/// إنشاء مزارع جديد في البئر',
      start,
    );

    expect(start, isNonNegative);
    expect(end, greaterThan(start));

    final section = source.substring(start, end);

    for (final contract in const [
      'list_well_farmers',
      'list_well_farms',
      'list_well_pumps',
    ]) {
      expect(
        RegExp(
          '''\\.schema\\s*\\(\\s*['"]api['"]\\s*\\)\\s*\\.rpc\\s*\\(\\s*\\n?\\s*['"]$contract['"]''',
        ).hasMatch(section),
        isTrue,
        reason: 'Read contract not routed through api: $contract',
      );
    }

    expect(section.contains("'p_well_id': wellId"), isTrue);
    expect(section.contains(".schema('ops')"), isFalse);
    expect(section.contains(".schema('core')"), isFalse);
    expect(section.contains('catch ('), isFalse);
  });

  test('operations mock fallbacks are gone', () {
    final repositorySource = File(
      'lib/core/api/operations_repository.dart',
    ).readAsStringSync();

    for (final legacyName in const [
      '_getMockFarmers',
      '_getMockFarms',
      'F-NEW',
    ]) {
      expect(
        repositorySource.contains(legacyName),
        isFalse,
        reason: 'Production mock fallback still present: $legacyName',
      );
    }

    // ملفّ المزارع لم يعد يصطنع حسابًا عند غياب المزارع في البئر.
    // (بقايا mock الجلسات تُغلق في م-41C2.)
    final detailStart = repositorySource.indexOf(
      'Future<FarmerDetailData> fetchFarmerDetail',
    );
    expect(detailStart, isNonNegative);
    expect(
      repositorySource.substring(detailStart).contains('mock-farmer-1'),
      isFalse,
    );

    final operationsScreen = File(
      'lib/features/operations/operations_screen.dart',
    ).readAsStringSync();

    for (final legacyName in const [
      'mock-pump-1',
      'mock-farmer-1',
      'mock-farm-1',
    ]) {
      expect(
        operationsScreen.contains(legacyName),
        isFalse,
        reason: 'Screen still fabricates data: $legacyName',
      );
    }
  });

  test('account profile read uses the official bootstrap contract', () {
    final source = File(
      'lib/core/api/account_repository.dart',
    ).readAsStringSync();

    final start = source.indexOf(
      'Future<UserProfileData> fetchUserProfile',
    );
    final end = source.indexOf(
      '/// 2. تحديث الاسم الشخصي',
      start,
    );

    expect(start, isNonNegative);
    expect(end, greaterThan(start));

    final section = source.substring(start, end);

    expect(
      section.contains(
        'AppBootstrapRepository(client).fetchBootstrap()',
      ),
      isTrue,
    );
    expect(section.contains(".schema('iam')"), isFalse);
    expect(section.contains('_getMockUserProfile'), isFalse);
    expect(section.contains('catch ('), isFalse);
  });

  test('account profile name write uses the official api contract', () {
    final source = File(
      'lib/core/api/account_repository.dart',
    ).readAsStringSync();

    final start = source.indexOf(
      'Future<void> updateUserName',
    );
    final end = source.indexOf(
      '/// 3. تغيير كلمة المرور بأمان',
      start,
    );

    expect(start, isNonNegative);
    expect(end, greaterThan(start));

    final section = source.substring(start, end);

    expect(
      RegExp(
        r'''\.schema\s*\(\s*['"]api['"]\s*\)\s*\.rpc\s*\(\s*['"]update_profile_name['"]''',
      ).hasMatch(section),
      isTrue,
    );

    expect(
      section.contains("'p_full_name': cleanName"),
      isTrue,
    );

    expect(section.contains(".schema('iam')"), isFalse);
    expect(section.contains('catch ('), isFalse);
  });

  test('unsupported team contracts are not simulated in production', () {
    final repositorySource = File(
      'lib/core/api/account_repository.dart',
    ).readAsStringSync();

    final screenSource = File(
      'lib/features/settings/team_permissions_screen.dart',
    ).readAsStringSync();

    for (final legacyName in const [
      'get_well_team',
      'add_team_member',
      'set_team_member_status',
      '_getMockTeam',
    ]) {
      expect(
        repositorySource.contains(legacyName),
        isFalse,
        reason: 'Legacy team contract returned: $legacyName',
      );
    }

    expect(
      screenSource.contains(
        'إدارة الفريق غير متاحة في هذه النسخة',
      ),
      isTrue,
    );

    expect(
      screenSource.contains('تمت إضافة عضو الفريق بنجاح'),
      isFalse,
    );

    expect(
      screenSource.contains('تم تعطيل تعيين العضو'),
      isFalse,
    );
  });

  test('known bare-RPC debt does not grow', () {
    final actual = _collectMatches(
      RegExp(
        r'''\b[_A-Za-z][_A-Za-z0-9]*\s*\.\s*rpc\s*\(\s*['"]([^'"]+)['"]''',
      ),
      captureGroup: 1,
    );

    // انكمش الدين من تسعة نداءات إلى نداء واحد بعد هجرة 091: كل عقود
    // إدارة البئر صارت تمر عبر api، ولم يبقَ إلا مؤشرات التقارير التي
    // لا عقد لها بعد (م-41D2).
    const expected = [
      'lib/core/api/well_management_repository.dart|get_reports_summary',
    ];

    _expectKnownDebt(
      label: 'Bare-RPC debt',
      actual: actual,
      expected: expected,
    );
  });

  test('well management contracts are routed through api', () {
    final source = File(
      'lib/core/api/well_management_repository.dart',
    ).readAsStringSync();

    for (final contract in const [
      'get_well_details',
      'update_well_details',
      'list_well_pumps_detail',
      'save_well_pump',
      'get_active_price_schedule',
      'create_price_schedule',
      'list_well_fuel_tanks',
      'purchase_fuel',
      'record_physical_fuel_count',
    ]) {
      expect(
        RegExp(
          '''\\.schema\\s*\\(\\s*['"]api['"]\\s*\\)\\s*\\.rpc\\s*\\(\\s*\\n?\\s*['"]$contract['"]''',
        ).hasMatch(source),
        isTrue,
        reason: 'Contract not routed through api: $contract',
      );
    }

    // البيانات التجريبية المحلية لإدارة البئر أُزيلت؛ لم يبقَ إلا مؤشرات
    // التقارير المعلَّمة كدين م-41D2.
    for (final legacyName in const [
      '_getMockWellDetails',
      '_getMockPumps',
      '_getMockPriceSchedule',
      '_getMockFuelTanks',
    ]) {
      expect(
        source.contains(legacyName),
        isFalse,
        reason: 'Production mock fallback still present: $legacyName',
      );
    }
  });

  test('physical fuel count uses the approved api contract', () {
    final source = File(
      'lib/core/api/well_management_repository.dart',
    ).readAsStringSync();

    final start = source.indexOf(
      'Future<void> recordPhysicalFuelCount',
    );
    final end = source.indexOf(
      '/// 10.',
      start,
    );

    expect(start, isNonNegative);
    expect(end, greaterThan(start));

    final section = source.substring(start, end);

    expect(
      RegExp(
        r'''\.schema\s*\(\s*['"]api['"]\s*\)\s*\.rpc\s*\(\s*['"]record_physical_fuel_count['"]''',
      ).hasMatch(section),
      isTrue,
    );
    expect(section.contains("'p_well_id': wellId"), isTrue);
    expect(
      section.contains("'p_fuel_tank_id': tankId"),
      isTrue,
    );
    // الوحدة صارت مليلترًا في كل الطبقة: العقد يستلم القياس كما هو،
    // والتحويل من اللتر يجري في الشاشة وحدها.
    expect(
      section.contains(
        "'p_measured_balance_ml': measuredBalanceMl",
      ),
      isTrue,
    );
    expect(
      section.contains("'p_notes': notes"),
      isTrue,
    );
    expect(
      section.contains("rpc('record_fuel_physical_count'"),
      isFalse,
    );
    expect(section.contains('catch ('), isFalse);
  });

  test('known dotted-from debt does not grow', () {
    final actual = _collectMatches(
      RegExp(
        r'''\.from\s*\(\s*['"]([A-Za-z_][A-Za-z0-9_]*\.[^'"]+)['"]\s*\)''',
      ),
      captureGroup: 1,
    );

    const expected = [
      'lib/core/api/finance_repository.dart|finance.expenses',
      'lib/core/api/finance_repository.dart|iam.well_memberships',
      'lib/core/api/finance_repository.dart|finance.profit_distribution_cycles',
      'lib/core/api/finance_repository.dart|billing.invoices',
      'lib/core/api/finance_repository.dart|billing.payments',
    ];

    _expectKnownDebt(
      label: 'Dotted-from debt',
      actual: actual,
      expected: expected,
    );
  });
}

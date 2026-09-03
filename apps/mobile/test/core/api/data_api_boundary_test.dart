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

    // انكمش الدين من تسعة نداءات إلى صفر: get_reports_summary صار عقدًا
    // حقيقيًا في هجرة 092، فلم يبقَ نداء RPC مجرّد واحد في التطبيق.
    const expected = <String>[];

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
      'get_reports_summary',
    ]) {
      expect(
        RegExp(
          '''\\.schema\\s*\\(\\s*['"]api['"]\\s*\\)\\s*\\.rpc\\s*\\(\\s*\\n?\\s*['"]$contract['"]''',
        ).hasMatch(source),
        isTrue,
        reason: 'Contract not routed through api: $contract',
      );
    }

    // البيانات التجريبية المحلية لإدارة البئر أُزيلت كلها، ومعها أرقام
    // التقارير المُلفَّقة (24 جلسة و945000 و720000 و285000 و460 لترًا).
    for (final legacyName in const [
      '_getMockWellDetails',
      '_getMockPumps',
      '_getMockPriceSchedule',
      '_getMockFuelTanks',
      '_getMockReportSummary',
      '945000',
      '720000',
      '285000',
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

    // صفر: القراءات المالية الخمس صارت عقود api في هجرة 092. وكان اثنان
    // منها يخاطبان ما لا وجود له أصلًا (iam.well_memberships وpublic.farms).
    const expected = <String>[];

    _expectKnownDebt(
      label: 'Dotted-from debt',
      actual: actual,
      expected: expected,
    );
  });

  test('finance reads use the official api read contracts', () {
    final source = File(
      'lib/core/api/finance_repository.dart',
    ).readAsStringSync();

    for (final contract in const [
      'list_well_expenses',
      'list_well_partners',
      'list_well_profit_cycles',
      'get_farmer_account',
    ]) {
      expect(
        RegExp(
          '''\\.schema\\s*\\(\\s*['"]api['"]\\s*\\)\\s*\\.rpc\\s*\\(\\s*\\n?\\s*['"]$contract['"]''',
        ).hasMatch(source),
        isTrue,
        reason: 'Read contract not routed through api: $contract',
      );
    }

    expect(source.contains("'p_well_id': wellId"), isTrue);
    expect(
      source.contains("'p_farmer_well_account_id': farmerAccountId"),
      isTrue,
    );

    // كشف حساب الشريك الواحد تصفية محلية لقائمة الشركاء نفسها، فلا عقد
    // ثانيًا له ولا نداء لكل شريك.
    expect(
      source.contains('final partners = await fetchPartners(wellId);'),
      isTrue,
    );

    for (final internalSchema in const [
      ".schema('finance')",
      ".schema('billing')",
      ".schema('iam')",
      ".schema('reporting')",
    ]) {
      expect(source.contains(internalSchema), isFalse);
    }

    // لا التقاط للخطأ في المستودع: الشاشة هي من يعرض الفشل.
    expect(source.contains('catch ('), isFalse);
  });

  test('finance mock fallbacks and fabricated money are gone', () {
    final source = File(
      'lib/core/api/finance_repository.dart',
    ).readAsStringSync();

    for (final legacyName in const [
      '_getMockExpenses',
      '_getMockPartners',
      '_getMockCycles',
      '_getMockFarmerFinancialAccount',
      // هوية المزارع ورصيده المقدَّم كانت ثوابت في العميل لأي حساب يُفتح.
      "'محمد علي الحبيشي'",
      "'F-001'",
      "'771234567'",
      'advanceBalanceYER: 15000',
      // ومال الشركاء كان محشورًا في كل صف بلا مصدر.
      'totalEarningsYER: 180000',
      'irrigationDeductionYER: 35000',
      'totalPaidYER: 100000',
    ]) {
      expect(
        source.contains(legacyName),
        isFalse,
        reason: 'Production mock fallback still present: $legacyName',
      );
    }
  });

  test('finance screens surface contract failures instead of hiding them', () {
    for (final entry in const {
      'lib/features/finance/expenses_screen.dart':
          'تعذر تحميل المصروفات',
      'lib/features/finance/partners_screen.dart':
          'تعذر تحميل بيانات الشركاء',
      'lib/features/finance/profit_distribution_screen.dart':
          'تعذر تحميل دورات الأرباح',
      'lib/features/finance/partner_detail_financial_screen.dart':
          'تعذر تحميل حساب الشريك',
      'lib/features/finance/farmer_financial_account_screen.dart':
          'تعذر تحميل الحساب المالي للمزارع',
      'lib/features/well_management/reports_analytics_screen.dart':
          'تعذر تحميل التقارير',
    }.entries) {
      final source = File(entry.key).readAsStringSync();
      expect(
        source.contains(entry.value),
        isTrue,
        reason: 'Screen swallows contract failure: ${entry.key}',
      );
    }
  });

  // المقياس الرابع (م-41D3): عائلة «النجاح الكاذب» لا تخاطب القاعدة أصلًا،
  // فلا تراها المقاييس الثلاثة الأولى. تُقاس هنا وتُثبَّت لتنكمش فقط.
  test('known false-success fabricated-id debt does not grow', () {
    final actual = _collectMatches(
      RegExp(r'''['"](mock-[a-z-]*|F-NEW)'''),
      captureGroup: 1,
    );

    // أُغلق الدين كاملًا: ثلاثة مواضع ← واحد في م-41D4 ← صفر في م-41D5.
    // معرّف الجلسة المُلفَّق والمزارع المُلفَّق صارا فشلًا صريحًا، وشاشة
    // الحساب المالي لم تبق ترسل دفعة بمعرّف ثابت إلى عقد كتابة.
    const expected = <String>[];

    _expectKnownDebt(
      label: 'False-success fabricated-id debt',
      actual: actual,
      expected: expected,
    );
  });

  test('known placeholder well-id debt does not grow', () {
    final actual = _collectMatches(
      RegExp(r'''['"](well-1)['"]'''),
      captureGroup: 1,
    );

    // أُغلق الدين كاملًا في جولة الهوية الحقيقية: 47 موضعًا في 15 ملفًا ←
    // 45 في 14 بعد م-41D4 ← صفر الآن. كل شاشة تستقبل `AppIdentity` واحدة
    // من `api.app_bootstrap()`، فلم يبق موضع يُكتب فيه معرّف بئر بيد أحد.
    _expectKnownDebt(
      label: 'Placeholder well-id debt',
      actual: actual,
      expected: const <String>[],
    );
  });

  // المقياس السابع (جولة الهوية): الهوية تُقرأ مرة واحدة من العقد وتُمرَّر
  // وحدةً واحدة. القيم الجاهزة هنا لا تُقاس بالنقصان بل يجب أن تكون صفرًا:
  // وجود واحدة منها يعني أن شاشةً عادت تُخمّن صاحبها أو بئره أو دوره.
  test('identity literals are absent: no fabricated account, tenant or well',
      () {
    for (final fabricated in const [
      "'well-1'",
      "'tenant-1'",
      "'active-user'",
      "'بئر الخير الرئيسي'",
      "'777123456'",
      'placeholderAccountKey',
    ]) {
      final hits = _collectMatches(
        RegExp(RegExp.escape(fabricated)),
        captureGroup: 0,
      );
      expect(
        hits,
        isEmpty,
        reason: 'Fabricated identity value returned to lib/: $fabricated',
      );
    }
  });

  test('identity is one unit read from the contract, not guessed per screen',
      () {
    final identity = File(
      'lib/core/identity/app_identity.dart',
    ).readAsStringSync();

    // مفتاح الطابور هو `profile.id` = `auth.uid()` كما يعيده العقد: لا يُشتق
    // في العميل ولا يُكتب بمفتاح ويُقرأ بآخر.
    expect(identity.contains('String get accountId => profile.id;'), isTrue);
    expect(identity.contains('final WellSummary activeWell;'), isTrue);
    expect(identity.contains('WellSummary? activeWell'), isFalse);

    // الحالات الثلاث معلنة ومغلقة على نفسها: لا حالة رابعة تُملأ بقيمة.
    for (final state in const [
      'sealed class IdentityResolution',
      'final class IdentityReady',
      'final class IdentityWithoutWell',
      'final class IdentityUnavailable',
      'IdentityResolution resolveIdentity(BootstrapData data)',
    ]) {
      expect(identity.contains(state), isTrue, reason: 'Missing: $state');
    }

    final gate = File('lib/app/identity_gate.dart').readAsStringSync();

    // البوابة لا تبني محتوى إلا من هوية جاهزة، والفشل يُقال مع إعادة محاولة.
    expect(gate.contains('تعذر تحميل بيانات حسابك'), isTrue);
    expect(gate.contains('لا يوجد بئر مرتبط بحسابك'), isTrue);
    expect(gate.contains('إعادة المحاولة'), isTrue);
    expect(gate.contains('catch (_) {}'), isFalse);
    // ولا تخزين محلي للهوية: ذلك عمل مؤجَّل بقرار بوابة التثبيت (ق-120).
    expect(gate.contains('SharedPreferences'), isFalse);

    // كل شاشة في الغلاف تُبنى بهوية مُمرَّرة لا بقيم تُكتب عندها.
    final shell = File('lib/app/authenticated_shell.dart').readAsStringSync();
    expect(shell.contains('final AppIdentity identity;'), isTrue);
    expect(RegExp(r"wellId: '").allMatches(shell), isEmpty);
    expect(RegExp(r"wellName: '").allMatches(shell), isEmpty);
  });


  test('account repository reports measured device state, never constants', () {
    final source = File(
      'lib/core/api/account_repository.dart',
    ).readAsStringSync();

    // ابتلاع الخطأ بطبع رسالة كان هو ما حوّل الفشل إلى نجاح صامت.
    expect(source.contains('debugPrint'), isFalse);

    final passwordStart = source.indexOf('Future<void> updatePassword');
    final passwordEnd = source.indexOf(
      '/// 7. جلب حالة الجهاز والمزامنة',
      passwordStart,
    );
    expect(passwordStart, isNonNegative);
    expect(passwordEnd, greaterThan(passwordStart));

    final passwordSection = source.substring(passwordStart, passwordEnd);
    expect(passwordSection.contains('catch ('), isFalse);
    expect(passwordSection.contains('client.auth.updateUser('), isTrue);

    // إعادة المصادقة على بريد الجلسة نفسه قبل أي تغيير: الخانة كانت تُعرض
    // ولا تُقرأ، فيغيّرها من يمسك الهاتف مفتوحًا بلا معرفة القديمة (ق-105).
    expect(passwordSection.contains('signInWithPassword('), isTrue);
    expect(
      passwordSection.contains('throw const WrongCurrentPasswordException()'),
      isTrue,
    );
    expect(passwordSection.contains('currentPassword'), isTrue);

    for (final fabricated in const [
      'isOnline: true',
      'backgroundSyncActive: true',
      'localStorageReady: true',
      'DateTime.now().subtract',
      'Future.delayed',
    ]) {
      expect(
        source.contains(fabricated),
        isFalse,
        reason: 'Fabricated device/sync state returned: $fabricated',
      );
    }

    for (final measured in const [
      'coordinator.getPendingOperationsCount(accountId)',
      'coordinator.lastSuccessfulSyncAt(accountId)',
      'coordinator.usesDurableStore',
      'if (!coordinator.canSyncNow)',
      'ManualSyncUnavailableException',
    ]) {
      expect(
        source.contains(measured),
        isTrue,
        reason: 'Measured signal missing: $measured',
      );
    }

    // مفتاح الطابور يأتي من المُنادي — أي من هوية العقد — لا من ثابت في
    // المستودع. القراءة بمفتاح غير مفتاح الكتابة تُظهر «لا معلَّق» كذبًا.
    for (final keyed in const [
      'fetchDeviceSyncStatus(String accountId)',
      'triggerManualSync(String accountId)',
      'checkPendingOperationsBeforeLogout(String accountId)',
    ]) {
      expect(
        source.contains(keyed),
        isTrue,
        reason: 'Queue read is not keyed by the contract account: $keyed',
      );
    }
  });

  // المقياس الثامن (م-41E المرحلة 1): باب المصادقة نفسه. لا يقيسه أي مقياس
  // سابق لأنه لا يخاطب القاعدة، وهو أخطرها: دخول يُعلن بلا جلسة، وتغيير
  // هوية حساب يُعلن بلا أن يجري.
  test('login never announces a session that was not created', () {
    final source = File(
      'lib/features/auth/login_screen.dart',
    ).readAsStringSync();

    // المصيدة التي كانت تُعلن دخولًا عند انقطاع الشبكة: انتظار ثم نجاح.
    for (final faked in const [
      'Future.delayed',
      'المحاكاة الآمنة',
      'authErr is! AuthException',
      'PostgrestException',
    ]) {
      expect(
        source.contains(faked),
        isFalse,
        reason: 'Login still fakes a session on non-auth failure: $faked',
      );
    }

    // الجلسة تُقاس قبل الإعلان، والرفض يُفرَّق عن انقطاع الشبكة.
    for (final honest in const [
      'authRepo.isAuthenticated',
      'لم تُنشأ جلسة دخول',
      'on AuthException',
      'رقم الهاتف أو كلمة المرور غير صحيحة.',
      'تعذر الاتصال بالخادم — لم يتم التحقق من بياناتك.',
    ]) {
      expect(
        source.contains(honest),
        isTrue,
        reason: 'Login is missing an explicit state: $honest',
      );
    }
  });

  test('phone change is announced unavailable instead of being simulated', () {
    final source = File(
      'lib/features/settings/profile_security_screen.dart',
    ).readAsStringSync();

    // تمثيل كامل: رسالة لم تُرسل، ورمز لا يُقرأ، ونجاح لتغيير لم يحدث،
    // وشارة تحقّق لا وجود له في المنظومة كلها. الفحص على ما **يُبنى** في
    // شجرة العرض، فذكر النصّ في تعليق شرحٌ لتاريخ أُغلق لا ادّعاء.
    for (final claimed in const [
      r"Text('تم إرسال رمز التحقق",
      r"Text('تم تأكيد وتحديث رقم الهاتف",
      r"Text('إرسال رمز التحقق')",
      r"Text('رمز التحقق OTP'",
      r"'معتمد وموثق ✅' :",
      '_showOtpVerificationDialog',
    ]) {
      expect(
        source.contains(claimed),
        isFalse,
        reason: 'Screen still simulates phone verification: $claimed',
      );
    }

    for (final honest in const [
      'class _PhoneChangeUnavailableDialog extends StatelessWidget',
      'تغيير رقم الهاتف غير متاح في هذا الإصدار',
      'تغيير رقم الهاتف (غير متاح)',
      'ولا يوجد تحقّق برسالة نصية في هذا الإصدار',
      'لا رقم هاتف في بيانات الحساب',
    ]) {
      expect(
        source.contains(honest),
        isTrue,
        reason: 'Explicit unavailable-phone state missing: $honest',
      );
    }

    // النافذة بلا مستودع ولا انتظار، فلا مسار كتابة منها أصلًا.
    final dialogStart = source.indexOf('class _PhoneChangeUnavailableDialog');
    expect(dialogStart, isNonNegative);
    final dialog = source.substring(dialogStart);
    expect(dialog.contains('AccountRepository'), isFalse);
    expect(dialog.contains('await '), isFalse);

    // وكلمة المرور الحالية تُقرأ وتُرسل، ورفضها يُفرَّق عن تعذر الاتصال.
    expect(source.contains('currentPassword: currentPass'), isTrue);
    expect(source.contains('WrongCurrentPasswordException'), isTrue);
    expect(source.contains('أدخل كلمة المرور الحالية أولًا'), isTrue);
  });

  // المقياس التاسع (م-41E المرحلة 3): عقود الفريق ومسار التنشيط.
  test('team contracts go through api and the code is shown once only', () {
    final repository = File(
      'lib/core/api/team_repository.dart',
    ).readAsStringSync();

    for (final contract in const [
      "'list_well_team'",
      "'invite_well_member'",
      "'revoke_well_member'",
      "'claim_well_invitation'",
    ]) {
      expect(
        repository.contains("schema('api')"),
        isTrue,
        reason: 'Team repository must call api schema only',
      );
      expect(
        repository.contains(contract),
        isTrue,
        reason: 'Missing team contract: $contract',
      );
    }

    // لا قراءة مباشرة من جدول ولا مخطط داخلي من مستودع الفريق.
    expect(repository.contains('.from('), isFalse);
    expect(repository.contains("schema('core')"), isFalse);

    final screen = File(
      'lib/features/settings/team_permissions_screen.dart',
    ).readAsStringSync();

    // ادعاء الإصدار السابق زال لأن العقد صار موجودًا (هجرة 094). والفحص
    // على ما يُبنى في شجرة العرض: ذكره في تعليق شرحٌ لتاريخ أُغلق.
    expect(
      RegExp(r"Text\(\s*'إدارة الفريق غير متاحة").allMatches(screen),
      isEmpty,
    );

    for (final honest in const [
      'class _InviteConfirmDialog extends StatelessWidget',
      'class _InvitationCodeDialog extends StatelessWidget',
      'اقرأ الرقم حرفًا حرفًا',
      'الرمز يُعرض مرة واحدة',
      'تعذر قراءة فريق البئر',
      'لم يُضف أحد',
      'ولم يُحذف أي سجل',
    ]) {
      expect(
        screen.contains(honest),
        isTrue,
        reason: 'Team screen is missing an explicit state: $honest',
      );
    }

    // ولا اسم عضو مكتوب في الشاشة: الأعضاء من العقد وحده.
    expect(screen.contains('محمد عبدالله الشامي'), isFalse);
    expect(screen.contains('أحمد علي الريمي'), isFalse);

    final activation = File(
      'lib/features/auth/member_activation_screen.dart',
    ).readAsStringSync();

    for (final honest in const [
      'widget.onActivated?.call()',
      'result.isSuccess',
      '_auth.isAuthenticated',
      'لم تُنشأ جلسة دخول',
      'يوجد حساب بهذا الرقم وكلمة المرور غير مطابقة',
      'لا توجد دعوة سارية لرقمك',
    ]) {
      expect(
        activation.contains(honest),
        isTrue,
        reason: 'Activation screen is missing an explicit state: $honest',
      );
    }

    // التنشيط يُعلن **بعد** نتيجة المطالبة لا بعد إنشاء الحساب: النداء
    // الوحيد لـonActivated يقع داخل فرع النجاح.
    expect(
      activation.split('widget.onActivated?.call()').length - 1,
      1,
      reason: 'onActivated must be called from exactly one place',
    );
    expect(activation.contains('Future.delayed'), isFalse);
  });

  test('settings screens surface failure instead of claiming success', () {    final deviceSync = File(
      'lib/features/settings/device_sync_screen.dart',
    ).readAsStringSync();

    expect(
      deviceSync.contains('حالة الاتصال غير مقيسة في هذا الإصدار'),
      isTrue,
    );
    expect(deviceSync.contains('تعذر قراءة حالة الجهاز والمزامنة'), isTrue);
    expect(
      deviceSync.contains('المزامنة اليدوية غير متاحة في هذا الإصدار'),
      isTrue,
    );
    // ادعاءات الإصدار السابق: نجاح لمحاولة لم تُرسل، ووقت مزامنة ثابت.
    expect(deviceSync.contains('اكتملت محاولة المزامنة'), isFalse);
    expect(deviceSync.contains('منذ دقيقتين'), isFalse);
    expect(deviceSync.contains('مفعلة وتعمل تلقائياً'), isFalse);

    final moreSettings = File(
      'lib/features/settings/more_settings_screen.dart',
    ).readAsStringSync();

    // الخروج على عدد معلَّق مجهول يفشل مغلقًا (القرار 578).
    expect(moreSettings.contains('تعذر التحقق قبل الخروج'), isTrue);
    expect(
      moreSettings.contains('_showUnknownPendingLogoutDialog'),
      isTrue,
    );

    final security = File(
      'lib/features/settings/profile_security_screen.dart',
    ).readAsStringSync();

    expect(security.contains('تعذر تغيير كلمة المرور'), isTrue);
    // تفريغ الحقول يبقى في كل الحالات (ق-118 / القرار 541).
    expect(
      security.contains('oldPasswordController.clear();'),
      isTrue,
    );
  });

  // المقياس الخامس (م-41D4): كتابات التشغيل. كانت تعود بنجاح صامت — أو
  // بفاتورة مُلفَّقة — عند غياب العميل، وتبتلعها الشاشة في مصيدة فارغة.
  test('operations write contracts fail loudly without a client', () {
    final source = File(
      'lib/core/api/operations_repository.dart',
    ).readAsStringSync();

    expect(
      source.contains('if (client == null) return'),
      isFalse,
      reason: 'A write still returns silently when the client is missing.',
    );

    for (final fabricated in const [
      'mock-session-',
      "'total_amount_minor': 10500",
    ]) {
      expect(
        source.contains(fabricated),
        isFalse,
        reason: 'Fabricated write result still present: $fabricated',
      );
    }

    // كل فرع «لا عميل» يرفع نفس الاستثناء الذي ترفعه القراءات: لا استثناء
    // لكتابة على حساب المستخدم.
    final guarded = RegExp(
      r'if \(client == null\) \{',
    ).allMatches(source).length;
    final throwing = RegExp(
      r"throw StateError\('Supabase client is unavailable'\)",
    ).allMatches(source).length;

    expect(guarded, throwing);
    expect(throwing, greaterThanOrEqualTo(12));

    for (final method in const [
      'Future<String> startIrrigationSession',
      'Future<void> pauseIrrigationSession',
      'Future<void> resumeIrrigationSession',
      'Future<void> changeEnergySource',
      'Future<Map<String, dynamic>> completeIrrigationSession',
    ]) {
      expect(
        source.contains(method),
        isTrue,
        reason: 'Session write contract missing: $method',
      );
    }
  });

  test('operations screen surfaces write failures instead of faking state', () {
    final source = File(
      'lib/features/operations/operations_screen.dart',
    ).readAsStringSync();

    for (final swallowed in const [
      'catch (_) {}',
      '// Fallback',
      "publicCode: 'F-NEW'",
      "tenantId: 'tenant-1'",
      "roles: const ['owner', 'operator']",
    ]) {
      expect(
        source.contains(swallowed),
        isFalse,
        reason: 'Screen still hides failure or fabricates identity: $swallowed',
      );
    }

    for (final honest in const [
      'void _showActionFailure(String message)',
      'تعذر بدء الجلسة — لم يُسجَّل شيء',
      'تعذر الإيقاف المؤقت — الجلسة ما زالت جارية',
      'تعذر إنهاء الجلسة — لم يُسجَّل شيء ولا سند',
      'لم يُسجَّل السداد',
    ]) {
      expect(
        source.contains(honest),
        isTrue,
        reason: 'Explicit failure path missing: $honest',
      );
    }

    // «اختر البئر أولًا» و«لا بئر نشط» زالت لأنها صارت غير قابلة للتمثيل:
    // الشاشة تستقبل `AppIdentity` ببئر نشط إلزامي، فلا حالة بلا بئر تُحرَس.
    // البديل أقوى من الرسالة: بنية تمنع الحالة أصلًا (جولة الهوية).
    for (final structural in const [
      'required this.identity',
      'final AppIdentity identity;',
      'late WellSummary _activeWell;',
      'String get _activeWellId => _activeWell.id;',
      'String get _accountId => widget.identity.accountId;',
      '_activeWell = widget.identity.activeWell;',
    ]) {
      expect(
        source.contains(structural),
        isTrue,
        reason: 'Screen no longer receives its identity as one unit: '
            '$structural',
      );
    }

    // ولا يُشتق مفتاح الحساب ولا معرّف البئر في الشاشة بأي شكل آخر.
    expect(RegExp(r"wellId: '").allMatches(source), isEmpty);
    expect(RegExp(r'String\?\s+_activeWellId').allMatches(source), isEmpty);

    // الدين أُغلق (م-41D6): لا سعر مكتوب في العميل ولا دالة تختاره. التسعيرة
    // تُقرأ من `api.get_active_price_schedule` وتُعرض كغياب حين تغيب، فلا
    // «0 ريال» ولا سند بمبلغ لم يُسعّره جدول البئر.
    for (final removed in const [
      '_clientSideRateFor',
      '_clientSideSolarRateYER',
      '_clientSideDieselRateYER',
      'طاقة شمسية',
    ]) {
      expect(
        source.contains(removed),
        isFalse,
        reason: 'Client-side pricing still present: $removed',
      );
    }

    expect(RegExp(r'\b3500\b').allMatches(source), isEmpty);
    expect(RegExp(r'\b5000\b').allMatches(source), isEmpty);

    for (final priced in const [
      'fetchActivePriceSchedule',
      'SessionStateText.pricingPending',
      'تعذر قراءة التسعيرة السارية — لا تُعرض تسعيرة',
      'energySourceLabel(',
    ]) {
      expect(
        source.contains(priced),
        isTrue,
        reason: 'Contract-driven pricing path missing: $priced',
      );
    }

    // التسعيرة لا تحجب التشغيل (م-41D6): `price.manage` للمالك وحده بينما
    // `session.start` للمشغل، و`ops.start_irrigation_session` لا تأخذ سعرًا.
    // فخيارات المصدر مصادر القاعدة الثلاثة، ورفض 42501 حالة معلنة لا منع بدء.
    for (final unblocked in const [
      'kSessionEnergySources',
      '_pricingForbidden',
      "e.code == '42501'",
      'التسعيرة السارية متاحة لمن يملك إدارة الأسعار',
    ]) {
      expect(
        source.contains(unblocked),
        isTrue,
        reason: 'Pricing must not gate session start: $unblocked',
      );
    }

    expect(
      source.contains('لا مصدر طاقة مُسعَّر لهذا البئر — تعذر بدء الجلسة'),
      isFalse,
      reason: 'Missing price must not block a start the server accepts',
    );
  });

  test('payment receipt never claims a print that did not happen', () {
    final source = File(
      'lib/features/operations/widgets/payment_receipt_dialog.dart',
    ).readAsStringSync();

    for (final claimed in const [
      'تم إرسال أمر الطباعة',
      'محاكاة اتصال البلوتوث',
      'Future.delayed',
      'تمت الطباعة',
    ]) {
      expect(
        source.contains(claimed),
        isFalse,
        reason: 'Receipt still claims an unperformed print: $claimed',
      );
    }

    expect(
      source.contains('الطباعة الحرارية غير متاحة في هذا الإصدار'),
      isTrue,
    );
  });

  test('top well selector never names a well the user does not have', () {
    final source = File(
      'lib/core/widgets/top_well_selector.dart',
    ).readAsStringSync();

    // البئر النشط صار إلزاميًّا وحقيقيًّا: لا `null` يُملأ باسم جاهز، ولا
    // «لا بئر مختار» يُطبع لبئر لُفِّق خارج آبار المستخدم. الحالة التي كان
    // النصّان يحرسانها لم تبق قابلة للتمثيل.
    expect(source.contains('final WellSummary activeWell;'), isTrue);
    expect(source.contains('required this.activeWell'), isTrue);
    expect(source.contains('WellSummary? activeWell'), isFalse);
    expect(source.contains("?? 'بئر الخير الرئيسي'"), isFalse);
    expect(source.contains("?? 'لا بئر مختار'"), isFalse);
    // النصّ لا يُبنى في أي شجرة عرض هنا؛ ذكره في التوثيق شرح لتاريخ أُغلق.
    expect(RegExp(r"Text\(\s*'لا بئر مختار'").allMatches(source), isEmpty);

    // الأدوار المعروضة أدوار البئر نفسه من العقد، لا شارات ثابتة.
    expect(source.contains('well.roles.map'), isTrue);
    expect(RegExp(r"roles: (const )?\['").allMatches(source), isEmpty);
  });

  // المقياس السادس (م-41D5): آخر مسار كتابة كان يرسل معرّفًا لم يعده عقد.
  test('advance allocation never sends an id the contract did not return', () {
    final source = File(
      'lib/features/finance/farmer_financial_account_screen.dart',
    ).readAsStringSync();

    for (final claimed in const [
      'mock-advance-pay',
      'allocateAdvance(',
      'تم استخدام الرصيد المقدم في تسديد الفواتير بنجاح',
      'تأكيد التسديد من المقدم',
      'سيتم استخدام الرصيد لتسديد أقدم الفواتير',
      'الرصيد المقدم المتاح:',
    ]) {
      expect(
        source.contains(claimed),
        isFalse,
        reason: 'Screen still fakes an advance allocation: $claimed',
      );
    }

    for (final honest in const [
      'الرصيد المقدم (غير متاح)',
      'الرصيد المقدم — التسديد منه غير متاح',
      'غير متاح في هذا الإصدار — لم يُرسل أي أمر تسديد',
      'عرض فقط — لا تُسدَّد من هذه النافذة',
      'class _AdvanceUnavailableDialog extends StatelessWidget',
    ]) {
      expect(
        source.contains(honest),
        isTrue,
        reason: 'Explicit unavailable-advance state missing: $honest',
      );
    }

    // النافذة لا تحمل مستودعًا أصلًا، فلا كتابة ممكنة منها لا نجاحًا ولا فشلًا.
    final dialogStart = source.indexOf('class _AdvanceUnavailableDialog');
    expect(dialogStart, isNonNegative);
    final dialog = source.substring(dialogStart);
    expect(dialog.contains('FinanceRepository'), isFalse);
    expect(dialog.contains('await '), isFalse);

    // المنفذ الصادق باقٍ في المستودع بلا نداء حتى يوجد العقد.
    final repository = File(
      'lib/core/api/finance_repository.dart',
    ).readAsStringSync();
    expect(repository.contains("rpc('allocate_payment'"), isTrue);
  });

  // المقياس الثامن والعشرون (م-41E/4): الشريك صار يدخل فعلًا بعد المرحلة 3،
  // وكان يُوجَّه إلى شاشة العمليات — أزرار كتابة يرفضها الخادم، وأرقام جلسة
  // جارية خارج نطاقه المُقرَّر (§26 / الثابت 713).
  test('partner-only access lands on a read-only screen, never operations', () {
    final shell = File('lib/app/authenticated_shell.dart').readAsStringSync();

    // الشريك يُفحص **قبل** فرع «ليس مالكًا»، وإلا سقط في شاشة العمليات.
    final partnerBranch = shell.indexOf('identity.isPartnerOnly');
    final operatorBranch = shell.indexOf('!identity.isOwner');
    expect(partnerBranch, isNonNegative);
    expect(operatorBranch, isNonNegative);
    expect(partnerBranch < operatorBranch, isTrue);
    expect(shell.contains('PartnerOverviewScreen('), isTrue);

    // الدور من العقد لا من نصّ في الشاشة، ويقابل iam.is_partner_only.
    final bootstrap = File(
      'lib/core/api/app_bootstrap_repository.dart',
    ).readAsStringSync();
    expect(
      bootstrap.contains(
        'isPartner && !isOwner && !isManager && !isOperator',
      ),
      isTrue,
    );

    final screen = File(
      'lib/features/finance/partner_overview_screen.dart',
    ).readAsStringSync();

    // العقود عبر مخطط api وحده، ولا جدول ولا مخطط داخلي.
    expect(screen.contains('.from('), isFalse);
    for (final internal in const ['ops.', 'billing.', 'finance.', 'core.']) {
      expect(
        screen.contains("'$internal"),
        isFalse,
        reason: 'Partner screen addresses an internal schema: $internal',
      );
    }

    // لا مسار كتابة واحد: الشريك بلا صلاحية كتابة في هذه الجولة.
    for (final write in const [
      'record_expense',
      'record_payment',
      'decide_expense',
      'pay_partner_distribution',
      'start_irrigation_session',
      'invite_well_member',
      'recordExpense(',
      'recordGeneralPayment(',
      'payPartnerDistribution(',
    ]) {
      expect(
        screen.contains(write),
        isFalse,
        reason: 'Partner screen carries a write path: $write',
      );
    }

    // أرقام الجلسة الجارية لا تُقرأ ولا تُبنى هنا: الحضور وعدده فقط.
    for (final sessionNumber in const [
      'total_amount_minor',
      'billable_seconds',
      'list_well_sessions',
      'get_session_detail',
      'pump_name',
    ]) {
      expect(
        screen.contains(sessionNumber),
        isFalse,
        reason: 'Partner screen reads a live-session number: $sessionNumber',
      );
    }

    // والوسم صريح: فترة غير مقفلة موسومة في شجرة العرض نفسها، وسبب حجب
    // أرقام الجارية مكتوب. الفحص على شكل البناء لا على النصّ مجرّدًا — وهو
    // الدرس المتكرر من «لا بئر مختار» و«تم إرسال رمز التحقق».
    expect(
      RegExp(r"Text\(\s*'غير مُقفلة — أرقام غير نهائية'").hasMatch(screen),
      isTrue,
    );
    for (final honest in const [
      'أرقام الجلسة الجارية — المستحق والمدة والمضخة',
      'هذه الشاشة اطلاع فقط',
      'نسبتك في هذه الفترة',
    ]) {
      expect(
        screen.contains(honest),
        isTrue,
        reason: 'Partner scope is hidden instead of declared: $honest',
      );
    }

    // المستودع يمر بالعقدين الجديدين وحدهما.
    final repo = File(
      'lib/core/api/partner_repository.dart',
    ).readAsStringSync();
    expect(repo.contains("schema('api')"), isTrue);
    expect(RegExp(r"rpc\(\s*'read_partner_overview'").hasMatch(repo), isTrue);
    expect(
      RegExp(r"rpc\(\s*'list_well_farmer_balances'").hasMatch(repo),
      isTrue,
    );
    expect(repo.contains('.from('), isFalse);
  });

  // المقياس التاسع والعشرون (م-41F): الاستعادة تحدث قبل الدخول، فلا عقد في
  // القاعدة يخدمها ولا يكتب أحدٌ كلمة مرور لأحد (الثابت 706).
  test('password reset is owner-proofed and never written by the owner', () {
    final screen = File(
      'lib/features/auth/password_reset_screen.dart',
    ).readAsStringSync();
    final auth = File(
      'lib/core/api/auth_repository.dart',
    ).readAsStringSync();
    final team = File(
      'lib/features/settings/team_permissions_screen.dart',
    ).readAsStringSync();
    final login = File(
      'lib/features/auth/login_screen.dart',
    ).readAsStringSync();
    final edge = File('../../supabase/functions/reset-password/index.ts');

    // المسار الوحيد إلى إعادة التعيين هو الطرف الخادمي: لا عقد قاعدة هنا.
    expect(auth.contains("functions.invoke(\n        'reset-password'"), isTrue);
    expect(screen.contains('.rpc('), isFalse);
    expect(screen.contains('.from('), isFalse);

    // المالك يُصدر رمزًا ولا يكتب كلمة مرور: لا حقل ولا وسيط لها عنده.
    expect(team.contains('password'), isFalse);
    expect(team.contains('كلمة المرور الجديدة'), isFalse);
    expect(RegExp(r"rpc\(\s*'request_member_password_reset'").hasMatch(
      File('lib/core/api/team_repository.dart').readAsStringSync(),
    ), isTrue);

    // الشاشة تقول الحقيقة: الرمز باليد، ولا رسائل في هذا الإصدار.
    for (final honest in const [
      'الرمز يعطيك إياه مالك البئر',
      'رسائل نصية في هذا الإصدار',
      'كلمة مرورك القديمة لم تتغيّر',
      'نسيت كلمة المرور؟',
    ]) {
      expect(
        screen.contains(honest) || login.contains(honest),
        isTrue,
        reason: 'Reset path hides a declared state: $honest',
      );
    }

    // الطرف الخادمي موجود، وينادي العقد المخصَّص لمفتاح الخدمة، ولا يسجّل
    // رمزًا ولا كلمة مرور في أي سجل.
    expect(edge.existsSync(), isTrue);
    final edgeSource = edge.readAsStringSync();
    expect(edgeSource.contains("'consume_password_reset'"), isTrue);
    expect(edgeSource.contains('updateUserById'), isTrue);
    expect(edgeSource.contains('console.log'), isFalse);
    expect(RegExp(r'console\.(log|info|debug)\(.*code').hasMatch(edgeSource),
        isFalse);
    expect(RegExp(r'console\.\w+\(.*newPassword').hasMatch(edgeSource), isFalse);
  });
}

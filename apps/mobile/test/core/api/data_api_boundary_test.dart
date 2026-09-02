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

    final files = actual.map((hit) => hit.split('|').first).toSet();

    // قياس 2026-09-02 بعد م-41D4: 45 موضعًا في 14 ملفًا (كانت 47 في 15).
    // شاشة التشغيل خرجت من القائمة كلها. دين مُعلَن يُغلق في جولة الهوية
    // الحقيقية، ولا يُسمح له بالنمو.
    expect(
      actual.length,
      45,
      reason: 'Placeholder well-id debt changed; it may only shrink.',
    );
    expect(files.length, 14);
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
      'coordinator.getPendingOperationsCount()',
      'coordinator.lastSuccessfulSyncAt()',
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
  });

  test('settings screens surface failure instead of claiming success', () {
    final deviceSync = File(
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
      'اختر البئر أولًا — لا يُنشأ مزارع بلا بئر',
      'اختر البئر أولًا — لا تُنشأ أرض بلا بئر',
      'لا بئر نشط — لا تُبدأ جلسة سقي بلا بئر',
      'لم يُسجَّل السداد',
    ]) {
      expect(
        source.contains(honest),
        isTrue,
        reason: 'Explicit failure path missing: $honest',
      );
    }

    // دين مُعلَن: التسعيرة ما زالت محسوبة في العميل، لكنها في موضع واحد
    // مُسمّى يُقاس ويُغلق في جولة التسعيرة الحقيقية — لا ثلاثة متفرقة.
    expect(source.contains('_clientSideRateFor'), isTrue);
    expect(RegExp(r'\b3500\b').allMatches(source).length, 1);
    expect(RegExp(r'\b5000\b').allMatches(source).length, 1);
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

    expect(source.contains("?? 'بئر الخير الرئيسي'"), isFalse);
    expect(source.contains("?? 'لا بئر مختار'"), isTrue);
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
}

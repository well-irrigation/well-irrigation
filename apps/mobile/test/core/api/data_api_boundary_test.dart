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
  test('known internal-schema debt does not grow', () {
    final actual = _collectMatches(
      RegExp(
        r'''\.schema\s*\(\s*['"](core|iam|ops|billing|finance|inventory|audit|sync|reporting|public)['"]\s*\)''',
      ),
      captureGroup: 1,
    );

    const expected = [
      'lib/core/api/account_repository.dart|iam',
      'lib/core/api/account_repository.dart|iam',
      'lib/core/api/operations_repository.dart|ops',
      'lib/core/api/operations_repository.dart|ops',
      'lib/core/api/operations_repository.dart|core',
      'lib/core/api/operations_repository.dart|ops',
      'lib/core/api/operations_repository.dart|ops',
      'lib/core/api/operations_repository.dart|ops',
      'lib/core/api/operations_repository.dart|billing',
    ];

    _expectKnownDebt(
      label: 'Internal-schema debt',
      actual: actual,
      expected: expected,
    );
  });

  test('known bare-RPC debt does not grow', () {
    final actual = _collectMatches(
      RegExp(
        r'''\b[_A-Za-z][_A-Za-z0-9]*\s*\.\s*rpc\s*\(\s*['"]([^'"]+)['"]''',
      ),
      captureGroup: 1,
    );

    const expected = [
      'lib/core/api/account_repository.dart|get_well_team',
      'lib/core/api/account_repository.dart|add_team_member',
      'lib/core/api/account_repository.dart|set_team_member_status',

      'lib/core/api/finance_repository.dart|record_expense',
      'lib/core/api/finance_repository.dart|decide_expense',
      'lib/core/api/finance_repository.dart|calculate_profit_distribution',
      'lib/core/api/finance_repository.dart|approve_profit_distribution',
      'lib/core/api/finance_repository.dart|pay_partner_distribution',
      'lib/core/api/finance_repository.dart|record_payment',
      'lib/core/api/finance_repository.dart|allocate_payment',

      'lib/core/api/well_management_repository.dart|get_well_details',
      'lib/core/api/well_management_repository.dart|update_well_details',
      'lib/core/api/well_management_repository.dart|get_well_pumps',
      'lib/core/api/well_management_repository.dart|save_pump',
      'lib/core/api/well_management_repository.dart|get_active_price_schedule',
      'lib/core/api/well_management_repository.dart|create_price_schedule',
      'lib/core/api/well_management_repository.dart|get_fuel_tanks',
      'lib/core/api/well_management_repository.dart|record_fuel_purchase',
      'lib/core/api/well_management_repository.dart|record_fuel_physical_count',
      'lib/core/api/well_management_repository.dart|get_reports_summary',
    ];

    _expectKnownDebt(
      label: 'Bare-RPC debt',
      actual: actual,
      expected: expected,
    );
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

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// حرس عقد إثباتات المصروفات (هجرة 111) على مستوى المصدر:
///   1. skipReason يُرسل في p_attachment_skip_reason ولا يُطوى في
///      p_note (الاصطلاح القديم للطي انتهى).
///   2. الدلو الخاص ومرجع storage:// المستقر هما مرجع الإثبات.
///   3. لا أذونات تخزين أندرويد واسعة أُضيفت لجولة المرفقات — منتقي
///      النظام لا يحتاجها.
void main() {
  final repoSource = File(
    'lib/core/api/finance_repository.dart',
  ).readAsStringSync();

  group('ExpenseEvidence source contract (هجرة 111)', () {
    test(
      '1. recordExpense يرسل skipReason في p_attachment_skip_reason',
      () {
        expect(
          repoSource,
          contains("'p_attachment_skip_reason': skipReason"),
        );
      },
    );

    test('2. لا طي للسبب في الملاحظة — الاصطلاح القديم مُقتلع', () {
      expect(repoSource, isNot(contains("'تخطي المرفق: \$skipReason")));
      expect(repoSource, contains("'p_note': note"));
    });

    test('3. الدلو الخاص ومرجع storage:// المستقر هما المرجع المخزَّن', () {
      expect(repoSource, contains("expenseEvidenceBucket = 'expense-evidence'"));
      expect(repoSource, contains("'storage://\$expenseEvidenceBucket/"));
    });

    test('4. لا أذونات تخزين أندرويد واسعة في المانيفست', () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, isNot(contains('READ_EXTERNAL_STORAGE')));
      expect(manifest, isNot(contains('WRITE_EXTERNAL_STORAGE')));
      expect(manifest, isNot(contains('MANAGE_EXTERNAL_STORAGE')));
    });
  });
}

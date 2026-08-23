/// تصنيف الفشل: ما يُعاد تلقائيًا وما يحتاج مراجعة (القسم 20، ق-90 بند 20).
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';

void main() {
  group('أخطاء يُعاد إرسالها تلقائيًا', () {
    test('انقطاع الاتصال بأي من رموزه', () {
      for (final code in ['08000', '08003', '08006', '08001', '08004']) {
        expect(
          classifySqlFailure(code, 'connection failure'),
          FailureDisposition.retry,
          reason: code,
        );
      }
    });

    test('تعارض معاملات وموارد ومهلة', () {
      for (final code in ['40001', '40P01', '53300', '57014', '57P03']) {
        expect(
          classifySqlFailure(code, 'transient'),
          FailureDisposition.retry,
          reason: code,
        );
      }
    });

    test('انتهاء صلاحية الجلسة يُعاد بعد تجديدها', () {
      expect(
        classifySqlFailure('PGRST301', 'JWT expired'),
        FailureDisposition.retry,
      );
    });

    test('رسالة شبكة بلا رمز', () {
      expect(
        classifySqlFailure(null, 'SocketException: Failed host lookup'),
        FailureDisposition.retry,
      );
      expect(
        classifySqlFailure('', 'Connection refused'),
        FailureDisposition.retry,
      );
    });

    test('استثناءات الشبكة والمهلة المرفوعة من طبقة النقل', () {
      expect(
        classifyThrownFailure(TimeoutException('لا ردّ')),
        FailureDisposition.retry,
      );
      expect(
        classifyThrownFailure(
          Exception('SocketException: Failed host lookup: db.example'),
        ),
        FailureDisposition.retry,
      );
      expect(
        classifyThrownFailure(
          Exception('Connection closed before full header'),
        ),
        FailureDisposition.retry,
      );
    });
  });

  group('أخطاء تحتاج مراجعة بشرية', () {
    test('رفض عملي من الخادم', () {
      expect(
        classifySqlFailure('P0001', 'الجلسة مغلقة أصلًا'),
        FailureDisposition.review,
      );
    });

    test('صلاحية غير كافية', () {
      expect(
        classifySqlFailure('42501', 'permission denied'),
        FailureDisposition.review,
      );
    });

    test('خرق قيد سلامة أو بيانات', () {
      expect(
        classifySqlFailure('23505', 'duplicate key'),
        FailureDisposition.review,
      );
      expect(
        classifySqlFailure('23503', 'foreign key violation'),
        FailureDisposition.review,
      );
      expect(
        classifySqlFailure('22P02', 'invalid input syntax'),
        FailureDisposition.review,
      );
    });

    test('رمز مجهول لا يدخل حلقة إعادة لا نهائية', () {
      expect(
        classifySqlFailure('XX000', 'internal error'),
        FailureDisposition.review,
      );
    });

    test('رسالة عمل تحوي كلمة عابرة لا تُصنَّف عابرة', () {
      expect(
        classifySqlFailure('P0001', 'الدفعة تجاوزت الحد timeout'),
        FailureDisposition.review,
      );
    });

    test('خطأ برمجي ليس خطأ شبكة', () {
      expect(
        classifyThrownFailure(StateError('bad state')),
        FailureDisposition.review,
      );
      expect(
        classifyThrownFailure(const FormatException('ردّ غير متوقَّع')),
        FailureDisposition.review,
      );
    });
  });
}

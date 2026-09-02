import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';

/// حرس كتابات الجلسة: بلا عميل لا نجاح، ولا معرّف جلسة، ولا فاتورة
/// (ق-113 / ق-114 / م-41D4 — البنود 5–7 من قائمة النجاح الكاذب).
///
/// بلا `Supabase.initialize` في بيئة الاختبار يعود `_effectiveClient` بـ null،
/// وهي نفس حالة الجهاز الميداني قبل الإقلاع أو بعد فقد التهيئة.
void main() {
  group('OperationsRepository — كتابات الجلسة ترفض العمل بلا عميل', () {
    const repository = OperationsRepository();

    final noClient = throwsA(
      isA<StateError>().having(
        (e) => e.message,
        'message',
        'Supabase client is unavailable',
      ),
    );

    test('1. بدء الجلسة يفشل ولا يعود بمعرّف جلسة مُلفَّق', () async {
      await expectLater(
        repository.startIrrigationSession(
          wellId: 'well-x',
          pumpId: 'pump-x',
          farmId: 'farm-x',
          farmerAccountId: 'farmer-x',
          energySource: 'طاقة شمسية',
        ),
        noClient,
      );
    });

    test('2. الإيقاف المؤقت يفشل ولا يعود بنجاح صامت', () async {
      await expectLater(
        repository.pauseIrrigationSession(
          sessionId: 'session-x',
          reason: 'إيقاف مؤقت من المشغل',
        ),
        noClient,
      );
    });

    test('3. الاستئناف يفشل ولا يعود بنجاح صامت', () async {
      await expectLater(
        repository.resumeIrrigationSession(sessionId: 'session-x'),
        noClient,
      );
    });

    test('4. تغيير مصدر الطاقة يفشل ولا يعود بنجاح صامت', () async {
      await expectLater(
        repository.changeEnergySource(
          sessionId: 'session-x',
          newEnergySource: 'مولد ديزل',
        ),
        noClient,
      );
    });

    test('5. الإنهاء يفشل ولا يعود بفاتورة محسوبة في العميل', () async {
      await expectLater(
        repository.completeIrrigationSession(sessionId: 'session-x'),
        noClient,
      );
    });

    test('6. الكتابات تفشل بنفس رسالة القراءات — عقد واحد لا استثناء', () async {
      // القراءات كانت ترفع هذا الاستثناء أصلًا؛ الكتابات كانت وحدها تكذب.
      await expectLater(repository.fetchPumps('well-x'), noClient);
    });
  });
}

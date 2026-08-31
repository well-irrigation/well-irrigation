import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';

/// اختبارات عقد قراءة الجلسات (م-41C2 / ق-98 / ق-99)
///
/// الغرض: تثبيت أن طبقة النماذج تقرأ ما تعيده القاعدة كما هو —
/// لا حساب مال محلي، ولا ترجمة بالتخمين، ولا تحويل الجلسة غير المفوترة
/// إلى «مدفوعة» أو «صفر مستحق».
void main() {
  group('historyWindow', () {
    final now = DateTime(2026, 8, 31, 14, 30);

    test('all → نافذة مفتوحة الطرفين', () {
      final (from, to) = OperationsRepository.historyWindow('all', now: now);
      expect(from, isNull);
      expect(to, isNull);
    });

    test('today → من منتصف الليل المحلي إلى منتصف الليل التالي', () {
      final (from, to) = OperationsRepository.historyWindow('today', now: now);
      expect(from, DateTime(2026, 8, 31));
      expect(to, DateTime(2026, 9, 1));
      // الحد الأعلى مقصور (نصف مفتوح) في العقد: p_to حصري.
      expect(to!.difference(from!), const Duration(days: 1));
    });

    test('week / month → مدة رجعية بلا حد أعلى', () {
      final (weekFrom, weekTo) =
          OperationsRepository.historyWindow('week', now: now);
      expect(weekFrom, now.subtract(const Duration(days: 7)));
      expect(weekTo, isNull);

      final (monthFrom, monthTo) =
          OperationsRepository.historyWindow('month', now: now);
      expect(monthFrom, now.subtract(const Duration(days: 30)));
      expect(monthTo, isNull);
    });

    test('unpaid → لا نافذة زمنية (الترشيح على السداد لا على الوقت)', () {
      final (from, to) = OperationsRepository.historyWindow('unpaid', now: now);
      expect(from, isNull);
      expect(to, isNull);
    });
  });

  group('تخطيط الرموز الصريح', () {
    test('مصدر الطاقة يُترجم للرموز المعروفة فقط', () {
      expect(energySourceLabel('solar'), 'طاقة شمسية');
      expect(energySourceLabel('well_diesel'), 'ديزل البئر');
      expect(energySourceLabel('farmer_diesel'), 'ديزل المزارع');
    });

    test('رمز مجهول يُعاد كما هو بلا Blind Remap', () {
      expect(energySourceLabel('grid_power'), 'grid_power');
      expect(segmentTypeLabel('future_type'), 'future_type');
    });

    test('الغائب يظهر كغير محدد لا كقيمة مخترعة', () {
      expect(energySourceLabel(null), 'غير محدد');
      expect(energySourceLabel(''), 'غير محدد');
      expect(segmentTypeLabel(null), 'مقطع غير محدد');
    });

    test('أنواع المقاطع التسعة كلها مخطَّطة', () {
      expect(kSegmentTypeLabels.length, 9);
      for (final code in const [
        'solar_run',
        'well_diesel_run',
        'farmer_diesel_run',
        'billable_stop',
        'non_billable_stop',
        'breakdown',
        'operator_pause',
        'farmer_requested_pause',
        'source_change_pause',
      ]) {
        expect(kSegmentTypeLabels.containsKey(code), isTrue, reason: code);
        expect(segmentTypeLabel(code), isNot(code));
      }
    });
  });

  group('SessionHistoryItem.fromContract', () {
    test('جلسة مسدَّدة بالكامل', () {
      final item = SessionHistoryItem.fromContract(const {
        'id': 'ses-1',
        'well_id': 'well-1',
        'status': 'closed',
        'started_at': '2026-08-31T09:00:00+00:00',
        'ended_at': '2026-08-31T10:00:00+00:00',
        'farmer_well_account_id': 'fa-1',
        'farmer_public_code': 'FA-090-A',
        'farmer_name': 'سالم',
        'farm_id': 'farm-1',
        'farm_name': 'أرض سالم',
        'pump_id': 'pump-1',
        'pump_name': 'P-090-1',
        'operator_name': 'المشغل',
        'energy_source': 'solar',
        'billable_seconds': 3600,
        'total_amount_minor': 3500,
        'paid_amount_minor': 3500,
        'payment_status': 'settled',
        'has_charge': true,
        'has_invoice': true,
      });

      expect(item.id, 'ses-1');
      expect(item.farmerCode, 'FA-090-A');
      expect(item.energySourceCode, 'solar');
      expect(item.energySource, 'طاقة شمسية');
      expect(item.billableSeconds, 3600);
      expect(item.totalAmountYER, 3500);
      expect(item.paidAmountYER, 3500);
      expect(item.remainingAmountYER, 0);
      expect(item.isBilled, isTrue);
      expect(item.isFullySettled, isTrue);
      expect(item.startedAt, DateTime.utc(2026, 8, 31, 9).toLocal());
    });

    test('جلسة بدفعة جزئية تُبقي المتبقي كما تحسمه القاعدة', () {
      final item = SessionHistoryItem.fromContract(const {
        'id': 'ses-2',
        'started_at': '2026-08-31T07:00:00+00:00',
        'total_amount_minor': 7000,
        'paid_amount_minor': 3000,
        'payment_status': 'partial',
        'has_charge': true,
        'has_invoice': true,
      });

      expect(item.paymentStatus, 'partial');
      expect(item.remainingAmountYER, 4000);
      expect(item.isFullySettled, isFalse);
      expect(item.isBilled, isTrue);
    });

    test('جلسة غير مفوترة لا تصبح مسدَّدة ولا مستحقة (ق-99)', () {
      final item = SessionHistoryItem.fromContract(const {
        'id': 'ses-4',
        'started_at': '2026-08-21T07:00:00+00:00',
        'total_amount_minor': null,
        'paid_amount_minor': null,
        'payment_status': 'not_billed',
        'has_charge': false,
        'has_invoice': false,
      });

      expect(item.paymentStatus, 'not_billed');
      expect(item.hasCharge, isFalse);
      expect(item.hasInvoice, isFalse);
      expect(item.isBilled, isFalse);
      expect(item.isFullySettled, isFalse);
      expect(item.remainingAmountYER, 0);
    });

    test('الحقول الناقصة تظهر كغير محددة بلا اختلاق هوية', () {
      final item = SessionHistoryItem.fromContract(const {
        'id': 'ses-5',
        'started_at': '2026-08-31T07:00:00+00:00',
      });

      expect(item.farmerName, 'غير محدد');
      expect(item.farmerCode, '');
      expect(item.farmName, 'غير محددة');
      expect(item.energySourceCode, isNull);
      expect(item.energySource, 'غير محدد');
      expect(item.paymentStatus, 'not_billed');
    });
  });

  group('SessionSegmentItem.fromContract', () {
    test('مقطع تشغيل يقرأ الأعمدة الحقيقية بلا حساب محلي', () {
      final seg = SessionSegmentItem.fromContract(const {
        'sequence_number': 1,
        'segment_type': 'solar_run',
        'is_stop': false,
        'is_billable': true,
        'energy_source': 'solar',
        'started_at': '2026-08-31T09:00:00+00:00',
        'ended_at': '2026-08-31T09:50:00+00:00',
        'actual_seconds': 3000,
        'billable_seconds': 3000,
        'applied_rate_minor': 3500,
        'time_charge_minor': 2917,
        'fuel_charge_minor': 0,
        'total_charge_minor': 2917,
      });

      expect(seg.sequenceNumber, 1);
      expect(seg.isStop, isFalse);
      expect(seg.isBillable, isTrue);
      expect(seg.typeLabel, 'تشغيل بالطاقة الشمسية');
      expect(seg.energySource, 'طاقة شمسية');
      expect(seg.actualSeconds, 3000);
      expect(seg.billableSeconds, 3000);
      expect(seg.appliedRateYER, 3500);
      // المبلغ كما خُزّن: لا (rate * seconds / 3600) محليًا.
      expect(seg.totalChargeYER, 2917);
      expect(seg.timeChargeYER + seg.fuelChargeYER, seg.totalChargeYER);
    });

    test('مقطع توقف غير محسوب', () {
      final seg = SessionSegmentItem.fromContract(const {
        'sequence_number': 2,
        'segment_type': 'operator_pause',
        'is_stop': true,
        'is_billable': false,
        'energy_source': null,
        'started_at': '2026-08-31T09:50:00+00:00',
        'ended_at': '2026-08-31T10:00:00+00:00',
        'actual_seconds': 600,
        'billable_seconds': 0,
        'applied_rate_minor': null,
        'time_charge_minor': 0,
        'fuel_charge_minor': 0,
        'total_charge_minor': 0,
        'notes': 'operator_pause',
      });

      expect(seg.isStop, isTrue);
      expect(seg.isBillable, isFalse);
      expect(seg.typeLabel, 'إيقاف من المشغل');
      expect(seg.energySourceCode, isNull);
      expect(seg.actualSeconds, 600);
      expect(seg.billableSeconds, 0);
      expect(seg.appliedRateYER, 0);
      expect(seg.totalChargeYER, 0);
      expect(seg.notes, 'operator_pause');
    });
  });
}

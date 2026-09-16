import 'package:flutter/material.dart';

import '../../../core/api/operations_repository.dart';
import '../../../core/session/session_business_state.dart';
import '../../../core/session/session_segment.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/currency_utils.dart';
import '../../../core/utils/tafqeet_utils.dart';
import '../../../core/widgets/currency_display.dart';

/// ملخص استخدام مصدر طاقة محدد مشتق من مقاطع الجلسة (ق-129 / FIN-001)
class SourceUsageSummary {
  const SourceUsageSummary({
    required this.energySource,
    required this.billableSeconds,
    required this.accruedMinor,
  });

  final String energySource;
  final int billableSeconds;
  final int? accruedMinor;

  String get glyph => energySourceGlyph(energySource);
  String get label => energySourceLabel(energySource);
  String get shortLabel => energySourceShortLabel(energySource);

  String get formattedDuration {
    final h = (billableSeconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((billableSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (billableSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

/// اشتقاق ملخص المصادر من المقاطع الفعلية للجلسة (تجميع المقاطع المحتسبة فقط)
List<SourceUsageSummary> calculateSourceSummaries(
  List<SessionSegment> segments,
  DateTime now,
) {
  final billable = segments.where((s) => s.kind == SegmentKind.running);
  final grouped = <String, List<SessionSegment>>{};
  for (final s in billable) {
    final src = s.energySource ?? 'solar';
    grouped.putIfAbsent(src, () => []).add(s);
  }

  final results = <SourceUsageSummary>[];
  for (final entry in grouped.entries) {
    final src = entry.key;
    final segs = entry.value;
    int totalSec = 0;
    int? totalAccrued = 0;
    for (final seg in segs) {
      final sec = seg.billableSeconds(now);
      totalSec += sec;
      final acc = seg.timeChargeMinor(now);
      if (acc == null) {
        totalAccrued = null;
      } else if (totalAccrued != null) {
        totalAccrued += acc;
      }
    }
    results.add(
      SourceUsageSummary(
        energySource: src,
        billableSeconds: totalSec,
        accruedMinor: totalAccrued,
      ),
    );
  }
  return results;
}

/// نافذة تأكيد الإيقاف المؤقت (ق-129 / D1)
class PauseConfirmationDialog extends StatelessWidget {
  const PauseConfirmationDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.pause_circle_outline, color: AppColors.warning),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'إيقاف السقي مؤقتًا؟',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: AppColors.deepBlue,
              ),
            ),
          ),
        ],
      ),
      content: const Text(
        'سيتوقف الوقت واحتساب المبلغ حتى الاستئناف.',
        style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.warning,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('تأكيد'),
        ),
      ],
    );
  }
}

/// نافذة تأكيد تغيير مصدر الطاقة (ق-129 / C3 / C4)
class EnergyChangeConfirmationDialog extends StatelessWidget {
  const EnergyChangeConfirmationDialog({
    required this.currentSource,
    required this.newSource,
    this.newRateMinor,
    this.isPaused = false,
    super.key,
  });

  final String currentSource;
  final String newSource;
  final int? newRateMinor;
  final bool isPaused;

  @override
  Widget build(BuildContext context) {
    final currentGlyph = energySourceGlyph(currentSource);
    final currentLabel = energySourceLabel(currentSource);
    final newGlyph = energySourceGlyph(newSource);
    final newLabel = energySourceLabel(newSource);

    final String rateTitle;
    final String rateText;
    final String explanationText;

    if (isPaused) {
      rateTitle = 'التعرفة المتاحة (تأشيرية):';
      rateText = newRateMinor != null
          ? '${CurrencyUtils.formatAmount(newRateMinor!)} ريال / ساعة\n(${Tafqeet.format(newRateMinor!)})'
          : 'التسعيرة غير متوفرة حالياً';
      explanationText = 'ستبقى الجلسة متوقفة مؤقتًا ولن يُحتسب وقت التوقف. سيتم تطبيق المصدر واحتساب السعر المعتمد للمقطع الجديد عند استئناف السقي فقط.';
    } else {
      rateTitle = 'التعرفة الجديدة:';
      rateText = newRateMinor != null
          ? '${CurrencyUtils.formatAmount(newRateMinor!)} ريال / ساعة\n(${Tafqeet.format(newRateMinor!)})'
          : 'التسعيرة غير متوفرة';
      explanationText = 'سيستمر عداد الجلسة والوقت دون انقطاع. سيتم احتساب التعرفة الجديدة ابتداءً من لحظة التحويل فقط.';
    }

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'تأكيد تغيير مصدر الطاقة',
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.bold,
          color: AppColors.deepBlue,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'المصدر الحالي:',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Text(
                      '$currentLabel $currentGlyph',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: AppColors.deepBlue,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'المصدر الجديد:',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Text(
                      '$newLabel $newGlyph',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: AppColors.waterBlue,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      rateTitle,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        rateText,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: newRateMinor != null
                              ? AppColors.agriculturalGreen
                              : AppColors.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            explanationText,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.waterBlue,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('تأكيد التحويل'),
        ),
      ],
    );
  }
}

/// نافذة تأكيد إنهاء الجلسة واحتساب المستحق (ق-129 / E2)
class EndSessionConfirmationDialog extends StatelessWidget {
  const EndSessionConfirmationDialog({
    required this.farmerName,
    required this.farmName,
    required this.totalDurationText,
    required this.sourceSummaries,
    required this.totalAmountMinor,
    super.key,
  });

  final String farmerName;
  final String farmName;
  final String totalDurationText;
  final List<SourceUsageSummary> sourceSummaries;
  final int? totalAmountMinor;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.stop_circle_outlined, color: AppColors.error),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'تأكيد إنهاء الجلسة',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: AppColors.deepBlue,
              ),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // بيانات المزارع والأرض
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      const Text(
                        'المزارع:',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      Text(
                        farmerName,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.deepBlue,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      const Text(
                        'الأرض:',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      Text(
                        farmName,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.deepBlue,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      const Text(
                        'إجمالي مدة السقي:',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      Text(
                        totalDurationText,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                          color: AppColors.deepBlue,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // تفصيل المصادر المستخدمة
            if (sourceSummaries.isNotEmpty) ...[
              const Text(
                'تفصيل المصادر المستخدمة:',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: AppColors.deepBlue,
                ),
              ),
              const SizedBox(height: 6),
              ...sourceSummaries.map((s) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          '${s.glyph} ${s.label} (${s.formattedDuration}):',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                      if (s.accruedMinor == null)
                        const Text(
                          'بانتظار المزامنة',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: AppColors.warning,
                          ),
                        )
                      else
                        Flexible(
                          child: CurrencyDisplay(
                            amount: s.accruedMinor!,
                            unit: 'ريال',
                            alignment: CrossAxisAlignment.end,
                            amountStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: AppColors.deepBlue,
                            ),
                            tafqeetStyle: const TextStyle(fontSize: 10),
                          ),
                        ),
                    ],
                  ),
                );
              }),
              const Divider(height: 16),
            ],

            // المبلغ الإجمالي والتفقيط
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.agriculturalGreen.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppColors.agriculturalGreen.withValues(alpha: 0.3),
                ),
              ),
              child: Column(
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        'المبلغ الإجمالي:',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppColors.deepBlue,
                        ),
                      ),
                      if (totalAmountMinor != null)
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              CurrencyUtils.formatAmount(totalAmountMinor!),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: AppColors.agriculturalGreen,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              'ريال',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: AppColors.agriculturalGreen,
                              ),
                            ),
                          ],
                        )
                      else
                        const Text(
                          SessionStateText.pricingPending,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: AppColors.warning,
                          ),
                        ),
                    ],
                  ),
                  if (totalAmountMinor != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      Tafqeet.format(totalAmountMinor!),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.error,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('تأكيد الإنهاء'),
        ),
      ],
    );
  }
}

/// نافذة ملخص ما بعد إنهاء الجلسة مع خيار تسجيل دفعة منفصل (ق-129 / E4 / E5)
class PostEndSessionSummaryDialog extends StatelessWidget {
  const PostEndSessionSummaryDialog({
    required this.farmerName,
    required this.farmName,
    required this.totalDurationText,
    required this.sourceSummaries,
    required this.totalAmountMinor,
    this.canRecordPayment = true,
    super.key,
  });

  final String farmerName;
  final String farmName;
  final String totalDurationText;
  final List<SourceUsageSummary> sourceSummaries;
  final int? totalAmountMinor;
  final bool canRecordPayment;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        padding: const EdgeInsets.all(20),
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // رأس الملخص مع شارة "منتهي"
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  const Text(
                    'ملخص الجلسة',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.deepBlue,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: const Text(
                      SessionStateText.completed,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(height: 24),

              // التفاصيل
              Text(
                'المزارع: $farmerName',
                style: const TextStyle(fontSize: 14, color: AppColors.deepBlue),
              ),
              const SizedBox(height: 4),
              Text(
                'الأرض: $farmName',
                style: const TextStyle(fontSize: 14, color: AppColors.deepBlue),
              ),
              const SizedBox(height: 4),
              Text(
                'مدة السقي: $totalDurationText',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  color: AppColors.deepBlue,
                ),
              ),
              const SizedBox(height: 14),

              // تفصيل المصادر
              if (sourceSummaries.isNotEmpty) ...[
                const Text(
                  'تفصيل المصادر المستخدمة:',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.deepBlue,
                  ),
                ),
                const SizedBox(height: 6),
                ...sourceSummaries.map((s) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            '${s.glyph} ${s.label} (${s.formattedDuration})',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                        if (s.accruedMinor == null)
                          const Text(
                            'بانتظار المزامنة',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: AppColors.warning,
                            ),
                          )
                        else
                          Flexible(
                            child: CurrencyDisplay(
                              amount: s.accruedMinor!,
                              unit: 'ريال',
                              alignment: CrossAxisAlignment.end,
                              amountStyle: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: AppColors.deepBlue,
                              ),
                              tafqeetStyle: const TextStyle(fontSize: 10),
                            ),
                          ),
                      ],
                    ),
                  );
                }),
                const Divider(height: 20),
              ],

              // إجمالي المبلغ والتفقيط
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.agriculturalGreen.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppColors.agriculturalGreen.withValues(alpha: 0.25),
                  ),
                ),
                child: Column(
                  children: [
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text(
                          'المبلغ الإجمالي:',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: AppColors.deepBlue,
                          ),
                        ),
                        if (totalAmountMinor != null)
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                CurrencyUtils.formatAmount(totalAmountMinor!),
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.agriculturalGreen,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Text(
                                'ريال',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.agriculturalGreen,
                                ),
                              ),
                            ],
                          )
                        else
                          const Text(
                            SessionStateText.pricingPending,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppColors.warning,
                            ),
                          ),
                      ],
                    ),
                    if (totalAmountMinor != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        Tafqeet.format(totalAmountMinor!),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // الأزرار: تسجيل دفعة أو إغلاق (لا سداد)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (canRecordPayment &&
                      totalAmountMinor != null &&
                      totalAmountMinor! > 0) ...[
                    ElevatedButton.icon(
                      icon: const Icon(Icons.payment, size: 18),
                      label: const Text(
                        'تسجيل دفعة',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.agriculturalGreen,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () => Navigator.of(context).pop(true),
                    ),
                    const SizedBox(height: 8),
                  ],
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text('إغلاق'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../../core/api/operations_repository.dart';
import '../../../core/session/active_session_record.dart';
import '../../../core/sync/sync_status.dart';
import '../../../core/widgets/currency_display.dart';
import '../../../core/utils/tafqeet_utils.dart';

/// نتيجة عرض فقط؛ لا تنفذ دفعًا أو انتقالًا تشغيليًا.
class SessionCompletionResult extends StatelessWidget {
  const SessionCompletionResult({
    required this.record,
    this.onLater,
    this.showReceipts = true,
    this.detail,
    this.onPayment,
    this.onDetails,
    super.key,
  });

  final ActiveSessionRecord record;
  final SessionDetailData? detail;
  final VoidCallback? onLater;
  final bool showReceipts;
  final VoidCallback? onPayment;
  final VoidCallback? onDetails;

  static String paymentLabel(String? status) => switch (status) {
    'unpaid' => 'غير مسدد',
    'partial' => 'مدفوع جزئيًا',
    'settled' => 'خالص',
    'not_billed' => 'الحالة المالية لم تُعتمد بعد',
    _ => 'حالة السداد غير متاحة',
  };

  String time(DateTime value) {
    final local = value.toLocal();
    return '${local.year}/${local.month}/${local.day} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
  }

  /// تنسيق خاص بعرض E1؛ لا يغيّر التفقيط العام أو أي قيمة مالية.
  static String amountWords(int amount) {
    final text = Tafqeet.format(amount);
    final remainder = amount % 100;
    if (text.endsWith(' ريال') && remainder >= 11) {
      return '${text.substring(0, text.length - 5)} ريالًا';
    }
    if (text.endsWith(' ريال') && remainder >= 3 && remainder <= 10) {
      return '${text.substring(0, text.length - 5)} ريالات';
    }
    return text;
  }

  static String methodLabel(String method) => switch (method) {
    'cash' => 'نقدًا',
    'bank_transfer' => 'حوالة مصرفية',
    'mobile_wallet' => 'محفظة إلكترونية',
    _ => method,
  };

  static String dateTimeLabel(BuildContext context, DateTime value) {
    final local = value.toLocal();
    final labels = MaterialLocalizations.of(context);
    return '${labels.formatFullDate(local)}، '
        '${labels.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
  }

  static String receiptTimeLabel(BuildContext context, String value) {
    final parsed = DateTime.tryParse(value);
    return parsed == null ? 'وقت غير متاح' : dateTimeLabel(context, parsed);
  }

  Widget _fact(String label, String value, {bool ltr = false}) {
    if (ltr) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label:', style: const TextStyle(fontSize: 12)),
          Text(
            value,
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      );
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '$label: ', style: const TextStyle(fontSize: 12)),
          TextSpan(
            text: value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final approved = record.approvedAmountMinor;
    final amount = approved ?? record.totals.accruedMinor;
    final seconds = record.completedAt!.difference(record.startedAt).inSeconds;
    final sources = record.segments
        .map((s) => s.energySource)
        .whereType<String>()
        .toSet();
    final energy = sources
        .map(
          (s) => switch (s) {
            'solar' => 'طاقة شمسية',
            'diesel' || 'well_diesel' => 'ديزل البئر',
            'farmer_diesel' => 'ديزل المزارع',
            _ => s,
          },
        )
        .join('، ');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'انتهت الجلسة',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
                Text(
                  record.syncState == SessionSyncState.localOnly
                      ? 'بانتظار المزامنة'
                      : record.syncState.text,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final stacked = MediaQuery.textScalerOf(context).scale(13) > 20;
                final width = stacked
                    ? constraints.maxWidth
                    : (constraints.maxWidth - 12) / 2;
                return Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (record.farmerName != null)
                      SizedBox(
                        width: width,
                        child: _fact('المزارع', record.farmerName!),
                      ),
                    if (record.farmName != null)
                      SizedBox(
                        width: width,
                        child: _fact('الأرض', record.farmName!),
                      ),
                    if (record.pumpName != null || energy.isNotEmpty)
                      SizedBox(
                        width: constraints.maxWidth,
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            if (record.pumpName != null)
                              _fact('المضخة', record.pumpName!),
                            if (energy.isNotEmpty) _fact('الطاقة', energy),
                          ],
                        ),
                      ),
                    SizedBox(
                      width: width,
                      child: _fact(
                        'البداية',
                        time(record.startedAt),
                        ltr: true,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _fact(
                        'النهاية',
                        time(record.completedAt!),
                        ltr: true,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            Text(
              'مدة التنفيذ الفعلية: ${seconds ~/ 3600} س و ${(seconds % 3600) ~/ 60} د و ${seconds % 60} ث',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            if (amount == null)
              const Text('المبلغ النهائي سيظهر بعد المزامنة')
            else ...[
              Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    approved == null ? 'المبلغ التقديري' : 'المبلغ المعتمد',
                    style: const TextStyle(fontSize: 12),
                  ),
                  CurrencyDisplay(
                    amount: amount,
                    unit: 'ريال',
                    showTafqeet: false,
                  ),
                ],
              ),
              Text(
                '${amountWords(amount)} فقط',
                style: const TextStyle(fontSize: 12),
              ),
            ],
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: [
                const Text(
                  'السداد لدى الخادم:',
                  style: TextStyle(fontSize: 12),
                ),
                Text(
                  paymentLabel(detail?.session.paymentStatus),
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
            for (final payment in record.payments) ...[
              if (payment.status == CommandStatus.review)
                const Text(
                  'دفعة تحتاج مراجعة — يحتاج مراجعة',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                )
              else if (!payment.isPosted)
                const Text(
                  'دفعة معلقة — بانتظار المزامنة',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                )
              else ...[
                const Text(
                  'دفعة مقبولة من الخادم',
                  style: TextStyle(fontSize: 13),
                ),
                if (showReceipts && payment.acceptedReceipt != null) ...[
                  // تفاصيل السند تبقى في مسار التفاصيل عند اختصار الملخص.
                  ..._receiptFacts(context, payment.acceptedReceipt!),
                ],
              ],
            ],
            Wrap(
              spacing: 8,
              children: [
                if (onPayment != null)
                  TextButton(
                    onPressed: onPayment,
                    child: const Text('تسجيل دفعة'),
                  ),
                if (onDetails != null)
                  TextButton(
                    onPressed: onDetails,
                    child: const Text('عرض التفاصيل'),
                  ),
                if (onLater != null)
                  TextButton(onPressed: onLater, child: const Text('لاحقًا')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _receiptFacts(
    BuildContext context,
    Map<String, dynamic> receipt,
  ) => [
    if (receipt['public_code'] case final String code)
      Text(
        'سند القبض: $code',
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (receipt['amount_minor'] case final num received)
          CurrencyDisplay(
            amount: received.toInt(),
            unit: 'ريال',
            showTafqeet: false,
            amountStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        if (receipt['method'] case final String method)
          Text(
            'طريقة الدفع: ${methodLabel(method)}',
            style: const TextStyle(fontSize: 12),
          ),
      ],
    ),
    if (receipt['amount_minor'] case final num received)
      Text(amountWords(received.toInt()), style: const TextStyle(fontSize: 12)),
    if (receipt['paid_at'] case final String paidAt)
      Text(
        'وقت الدفعة: ${receiptTimeLabel(context, paidAt)}',
        style: const TextStyle(fontSize: 12),
      ),
  ];
}

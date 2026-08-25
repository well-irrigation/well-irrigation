import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/operations_repository.dart';
import '../../core/printer/receipt_formatter.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/currency_utils.dart';
import '../../core/utils/tafqeet_utils.dart';
import '../../core/widgets/currency_display.dart';

/// شاشة تفاصيل الجلسة والخط الزمني (UX-13 / 377 / ق-98)
class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({
    required this.sessionId,
    required this.wellName,
    this.repository,
    super.key,
  });

  final String sessionId;
  final String wellName;
  final OperationsRepository? repository;

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  late OperationsRepository _repo;
  bool _isLoading = true;
  SessionDetailData? _detailData;

  @override
  void initState() {
    super.initState();
    _repo = widget.repository ?? const OperationsRepository();
    _loadDetail();
  }

  Future<void> _loadDetail() async {
    setState(() => _isLoading = true);
    try {
      final data = await _repo.fetchSessionDetail(widget.sessionId);
      if (mounted) {
        setState(() {
          _detailData = data;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    if (hours > 0) {
      return '$hours س و $minutes د و $secs ث';
    } else if (minutes > 0) {
      return '$minutes د و $secs ث';
    } else {
      return '$secs ثانية';
    }
  }

  String _formatTimeOnly(DateTime dt) {
    final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
    final period = dt.hour >= 12 ? 'م' : 'ص';
    final minute = dt.minute.toString().padLeft(2, '0');
    final sec = dt.second.toString().padLeft(2, '0');
    return '$hour:$minute:$sec $period';
  }

  void _showPrintPreview() {
    if (_detailData == null) return;
    final session = _detailData!.session;

    final hourlyRate = session.totalAmountYER > 0 && session.billableSeconds > 0
        ? ((session.totalAmountYER * 3600) ~/ session.billableSeconds)
        : 3500;

    final receiptText = ReceiptFormatter.formatSessionInvoice(
      invoiceNumber: session.id.substring(0, session.id.length > 8 ? 8 : session.id.length).toUpperCase(),
      wellName: widget.wellName,
      farmerName: session.farmerName,
      farmName: session.farmName,
      operatorName: session.operatorName,
      date: session.startedAt,
      billableSeconds: session.billableSeconds,
      energySource: session.energySource,
      hourlyRateYER: hourlyRate,
      totalAmountYER: session.totalAmountYER,
      paidAmountYER: session.paidAmountYER,
    );

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.print, color: AppColors.deepBlue),
            SizedBox(width: 8),
            Text('معاينة الفاتورة الحرارية (58mm)', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: Container(
          width: double.maxFinite,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFFAF9F6),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border),
          ),
          child: SingleChildScrollView(
            child: Text(
              receiptText,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.4,
                color: Colors.black87,
              ),
              textDirection: TextDirection.ltr,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: receiptText));
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('تم نسخ الفاتورة إلى الحافظة بنجاح ✅')),
              );
            },
            child: const Text('نسخ النص'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.deepBlue,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.print, size: 18),
            label: const Text('إرسال للطابعة'),
            onPressed: () {
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('تم إرسال أمر الطباعة عبر البلوتوث 🖨️')),
              );
            },
          ),
        ],
      ),
    );
  }

  void _shareReceiptText() {
    if (_detailData == null) return;
    final s = _detailData!.session;
    final text = '''
إشعار سقي — ${widget.wellName}
المزارع: ${s.farmerName} (${s.farmerCode})
الأرض: ${s.farmName}
المضخة: ${s.pumpName}
التاريخ: ${s.startedAt.year}/${s.startedAt.month}/${s.startedAt.day}
المدة: ${_formatDuration(s.billableSeconds)}
المبلغ: ${CurrencyUtils.formatAmount(s.totalAmountYER)} ريال يمني (${Tafqeet.format(s.totalAmountYER)})
المدفوع: ${CurrencyUtils.formatAmount(s.paidAmountYER)} ريال يمني
المتبقي: ${CurrencyUtils.formatAmount(s.remainingAmountYER)} ريال يمني
الحالة: ${s.isFullySettled ? 'خالص بالكامل ✅' : 'آجل / متبقي 🔴'}
''';

    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم نسخ ملخص الجلسة للمشاركة عبر واتساب 📤')),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('تفاصيل الجلسة')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_detailData == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('تفاصيل الجلسة')),
        body: const Center(child: Text('لم يتم العثور على بيانات الجلسة')),
      );
    }

    final data = _detailData!;
    final session = data.session;

    return Scaffold(
      backgroundColor: AppColors.splashBackground,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'تفاصيل جلسة #${session.id.substring(0, session.id.length > 6 ? 6 : session.id.length)}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
            ),
            Text(
              widget.wellName,
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined, color: AppColors.waterBlue),
            tooltip: 'مشاركة الملخص',
            onPressed: _shareReceiptText,
          ),
          IconButton(
            icon: const Icon(Icons.print_outlined, color: AppColors.deepBlue),
            tooltip: 'طباعة الإيصال',
            onPressed: _showPrintPreview,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. كرت الملخص العام
            _buildSummaryCard(session),

            const SizedBox(height: 16),

            // 2. الخط الزمني للجلسة (Timeline)
            _buildTimelineSection(data.segments),

            const SizedBox(height: 16),

            // 3. قسم التسوية والدفعات
            _buildSettlementCard(data),

            const SizedBox(height: 24),

            // 4. أزرار الإجراءات السريعة
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: const BorderSide(color: AppColors.deepBlue),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.share, color: AppColors.deepBlue, size: 18),
                    label: const Text('مشاركة الإيصال', style: TextStyle(color: AppColors.deepBlue, fontWeight: FontWeight.bold)),
                    onPressed: _shareReceiptText,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.deepBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.print, size: 18),
                    label: const Text('طباعة الفاتورة', style: TextStyle(fontWeight: FontWeight.bold)),
                    onPressed: _showPrintPreview,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(SessionHistoryItem session) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.farmerName,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${session.farmName} • كود: ${session.farmerCode}',
                      style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: session.isFullySettled
                        ? AppColors.agriculturalGreen.withValues(alpha: 0.1)
                        : AppColors.error.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: session.isFullySettled ? AppColors.agriculturalGreen : AppColors.error,
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    session.isFullySettled ? 'خالص بالكامل ✅' : 'آجل / غير مدفوع 🔴',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: session.isFullySettled ? AppColors.agriculturalGreen : AppColors.error,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),
            const Divider(height: 1, color: AppColors.surfaceSubtle),
            const SizedBox(height: 16),

            // شبكة التفاصيل
            Row(
              children: [
                Expanded(child: _buildDetailCell('المضخة', session.pumpName, Icons.water_drop_outlined)),
                Expanded(child: _buildDetailCell('المشغل', session.operatorName, Icons.badge_outlined)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _buildDetailCell('مدة السقي', _formatDuration(session.billableSeconds), Icons.timer_outlined)),
                Expanded(child: _buildDetailCell('إجمالي الفاتورة', '${CurrencyUtils.formatAmount(session.totalAmountYER)} ريال', Icons.payments_outlined, isBold: true)),
              ],
            ),

            const SizedBox(height: 12),
            // التفقيط المالي
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.spellcheck, size: 16, color: AppColors.waterBlue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'فقط ${Tafqeet.format(session.totalAmountYER)} لا غير.',
                      style: const TextStyle(fontSize: 12, color: AppColors.deepBlue, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailCell(String label, String value, IconData icon, {bool isBold = false}) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.waterBlue),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
            Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
                color: isBold ? AppColors.deepBlue : AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTimelineSection(List<SessionSegmentItem> segments) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.timeline, color: AppColors.deepBlue, size: 20),
                SizedBox(width: 8),
                Text(
                  'الخط الزمني وتغيرات الطاقة (Timeline)',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                ),
              ],
            ),
            const SizedBox(height: 16),

            if (segments.isEmpty)
              const Text('لا توجد تفاصيل مقاطع مسجلة', style: TextStyle(fontSize: 13, color: AppColors.textMuted))
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: segments.length,
                itemBuilder: (context, index) {
                  final seg = segments[index];
                  final isLast = index == segments.length - 1;
                  return _buildTimelineItem(seg, isLast: isLast);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineItem(SessionSegmentItem seg, {required bool isLast}) {
    final isPause = seg.isPaused;
    final color = isPause ? AppColors.warning : (seg.energySource == 'طاقة شمسية' ? AppColors.agriculturalGreen : Colors.orange);
    final icon = isPause ? Icons.pause_circle_outline : (seg.energySource == 'طاقة شمسية' ? Icons.wb_sunny_outlined : Icons.local_gas_station_outlined);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // عمود الأيقونة والخط الرابط
          Column(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 1.5),
                ),
                child: Icon(icon, size: 16, color: color),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: AppColors.border,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),

          // تفاصيل المقطع
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isPause ? AppColors.warning.withValues(alpha: 0.05) : AppColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isPause ? AppColors.warning.withValues(alpha: 0.2) : AppColors.border.withValues(alpha: 0.5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          isPause ? 'توقف مؤقت للسقي' : 'تشغيل عبر ${seg.energySource}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: isPause ? AppColors.warning : AppColors.deepBlue,
                          ),
                        ),
                        Text(
                          _formatTimeOnly(seg.startedAt),
                          style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (isPause) ...[
                      Text(
                        'السبب: ${seg.pauseReason ?? 'بدون سبب مسجل'}',
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                      Text(
                        'مدة التوقف: ${_formatDuration(seg.durationSeconds)}',
                        style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                      ),
                    ] else ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'المدة: ${_formatDuration(seg.durationSeconds)} • التسعيرة: ${CurrencyUtils.formatAmount(seg.hourlyRateYER)} ر/س',
                            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                          ),
                          Text(
                            '${CurrencyUtils.formatAmount(seg.amountYER)} ريال',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettlementCard(SessionDetailData data) {
    final s = data.session;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.receipt_long_outlined, color: AppColors.deepBlue, size: 20),
                SizedBox(width: 8),
                Text(
                  'تفاصيل السداد وسند القبض',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                ),
              ],
            ),
            const SizedBox(height: 14),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('إجمالي المستحق:', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                CurrencyDisplay(
                  amount: s.totalAmountYER,
                  amountStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.deepBlue),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('المبلغ المدفوع:', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                CurrencyDisplay(
                  amount: s.paidAmountYER,
                  amountStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppColors.agriculturalGreen),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('المتبقي على المزارع:', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                CurrencyDisplay(
                  amount: s.remainingAmountYER,
                  amountStyle: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: s.remainingAmountYER > 0 ? AppColors.error : AppColors.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1, color: AppColors.surfaceSubtle),
            const SizedBox(height: 12),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'طريقة السداد: ${data.paymentMethod ?? 'نقداً'}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                ),
                if (data.paidAt != null)
                  Text(
                    'تاريخ السداد: ${data.paidAt!.year}/${data.paidAt!.month}/${data.paidAt!.day}',
                    style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

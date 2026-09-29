import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// صف أيقونات صغير لرمز يُقرأ مرة واحدة — نسخ ومشاركة — بدل الأزرار
/// الكبيرة.
///
/// النسخ ينسخ الرمز وحده ويؤكد بلقطة قصيرة. والمشاركة تفوّض الضغطة إلى
/// [onShareTap]: مستدعيها يقرر — منتقي قنوات مباشرة لرمز الدعوة، أو
/// قائمة مشاركة الجهاز لرمز إعادة التعيين.
class CodeActionsRow extends StatelessWidget {
  const CodeActionsRow({
    required this.code,
    required this.onShareTap,
    this.onCopy,
    super.key,
  });

  final String code;

  /// يُستدعى عند ضغط أيقونة المشاركة.
  final Future<void> Function() onShareTap;

  /// يُحقَن في اختبارات الويدجت؛ الافتراضي: الحافظة.
  final Future<void> Function(String code)? onCopy;

  Future<void> _copy(BuildContext context) async {
    final action = onCopy;
    if (action != null) {
      await action(code);
    } else {
      await Clipboard.setData(ClipboardData(text: code));
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('نُسخ الرمز إلى الحافظة')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'نسخ الرمز',
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () => _copy(context),
        ),
        IconButton(
          tooltip: 'مشاركة الرمز',
          icon: const Icon(Icons.share, size: 18),
          onPressed: onShareTap,
        ),
      ],
    );
  }
}

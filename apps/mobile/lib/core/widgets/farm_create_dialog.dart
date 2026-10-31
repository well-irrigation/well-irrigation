import 'package:flutter/material.dart';

import '../api/operations_repository.dart';

Future<Farm?> showFarmCreateDialog({
  required BuildContext context,
  required String farmerName,
  required Future<Farm> Function(String name, String? label) save,
}) async {
  final farm = await showDialog<Farm>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _FarmCreateDialog(farmerName: farmerName, save: save),
  );
  if (farm != null && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('تم حفظ الأرض')));
  }
  return farm;
}

class _FarmCreateDialog extends StatefulWidget {
  const _FarmCreateDialog({required this.farmerName, required this.save});
  final String farmerName;
  final Future<Farm> Function(String, String?) save;
  @override
  State<_FarmCreateDialog> createState() => _FarmCreateDialogState();
}

class _FarmCreateDialogState extends State<_FarmCreateDialog> {
  final name = TextEditingController();
  final label = TextEditingController();
  final form = GlobalKey<FormState>();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    label.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (busy || !(form.currentState?.validate() ?? false)) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final farm = await widget.save(
        name.text.trim(),
        label.text.trim().isEmpty ? null : label.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(farm);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = 'تعذر حفظ الأرض. حاول مرة أخرى.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('إضافة أرض جديدة'),
    content: SingleChildScrollView(
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('للمزارع: ${widget.farmerName}'),
            const SizedBox(height: 12),
            TextFormField(
              controller: name,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: 'اسم الأرض أو القطعة الزراعية *',
              ),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'اسم الأرض مطلوب' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: label,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: 'صفة مميزة (اختياري)',
                helperText: 'مثال: الشرقية أو جوار الطريق',
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(error!),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.of(context).pop(),
        child: const Text('إلغاء'),
      ),
      FilledButton(onPressed: busy ? null : _save, child: const Text('حفظ')),
    ],
  );
}

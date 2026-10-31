import 'package:flutter/material.dart';

import '../api/operations_repository.dart';
import '../utils/contact_picker.dart';
import '../utils/digit_utils.dart';

Future<FarmerAccount?> showFarmerCreateDialog({
  required BuildContext context,
  required Future<FarmerAccount> Function(String name, String? phone) save,
  Future<ContactPickResult> Function()? contactPicker,
}) => showDialog<FarmerAccount>(
  context: context,
  barrierDismissible: false,
  builder: (_) => FarmerCreateDialog(save: save, contactPicker: contactPicker),
);

class FarmerCreateDialog extends StatefulWidget {
  const FarmerCreateDialog({required this.save, this.contactPicker, super.key});
  final Future<FarmerAccount> Function(String name, String? phone) save;
  final Future<ContactPickResult> Function()? contactPicker;
  @override
  State<FarmerCreateDialog> createState() => _FarmerCreateDialogState();
}

class _FarmerCreateDialogState extends State<FarmerCreateDialog> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _saving = false, _picking = false;
  String? _message;
  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    setState(() => _picking = true);
    ContactPickResult result;
    try {
      result = await (widget.contactPicker ?? pickContactPhone)();
    } catch (_) {
      result = const ContactPickResult(ContactPickStatus.failed);
    }
    if (!mounted) return;
    setState(() {
      _picking = false;
      switch (result.status) {
        case ContactPickStatus.picked:
          final phone = result.phone == null
              ? null
              : normalizeContactPhone(result.phone!);
          if (phone == null) {
            _message = 'تعذر اختيار الرقم — يمكنك إدخاله يدويًا.';
          } else {
            _phone.text = phone;
            _message = null;
          }
        case ContactPickStatus.cancelled:
          break;
        case ContactPickStatus.permissionDenied:
          _message =
              'لم يُمنح الوصول لجهات الاتصال — يمكنك إدخال الرقم يدويًا.';
        case ContactPickStatus.failed:
          _message = 'تعذر اختيار الرقم — يمكنك إدخاله يدويًا.';
      }
    });
  }

  Future<void> _save() async {
    if (_saving || _picking || !(_form.currentState?.validate() ?? false))
      { return; }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final phone = normalizeContactPhone(normalizeArabicDigits(_phone.text));
      final farmer = await widget.save(_name.text.trim(), phone);
      if (mounted) { Navigator.of(context).pop(farmer); }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _message = 'تعذر حفظ المزارع. حاول مرة أخرى.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving && !_picking,
    child: AlertDialog(
      title: const Text('إضافة مزارع جديد'),
      content: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                key: const Key('farmer_name'),
                controller: _name,
                enabled: !_saving,
                decoration: const InputDecoration(labelText: 'اسم المزارع', hintText: 'الاسم الثلاثي'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'اسم المزارع مطلوب'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('farmer_phone'),
                controller: _phone,
                enabled: !_saving,
                keyboardType: TextInputType.phone,
                textDirection: TextDirection.ltr,
                inputFormatters: const [ArabicToEnglishDigitsFormatter()],
                decoration: InputDecoration(
                  labelText: 'رقم الهاتف',
                  helperText: 'اختياري',
                  suffixIcon: IconButton(
                    tooltip: 'اختيار من جهات الاتصال',
                    onPressed: _saving || _picking ? null : _pick,
                    icon: const Icon(Icons.contact_phone_outlined),
                  ),
                ),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_message!, semanticsLabel: _message),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving || _picking
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: _saving || _picking ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('حفظ'),
        ),
      ],
    ),
  );
}

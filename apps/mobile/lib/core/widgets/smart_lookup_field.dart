import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../utils/digit_utils.dart';

/// مكوّن البحث الذكي الموحد (Smart Lookup Component - ق-88 / ق-119)
///
/// يدعم:
/// - اختيار الكيانات (مزارع، أرض، شريك، مشغل) بمعرّف ثابت UUID.
/// - الاقتراحات السياقية الأخيرة (Recent choices) عند التركيز بدون كتابة.
/// - الفلترة اللحظية بالبادئة والتطبيع العربي الصارم.
/// - العرض التمييزي الثانوي (Disambiguation label).
/// - زر الإضافة السريع المدمج (+ إضافة جديد) دون مغادرة الشاشة.
class SmartLookupField<T> extends StatelessWidget {
  const SmartLookupField({
    required this.label,
    required this.hintText,
    required this.itemLabel,
    required this.searchFunction,
    required this.onChanged,
    this.selectedItem,
    this.itemSecondaryLabel,
    this.onAddNew,
    this.addNewLabel,
    this.emptyMessage = 'لا توجد نتائج مطابقة',
    this.prefixIcon = Icons.search,
    this.enabled = true,
    super.key,
  });

  final String label;
  final String hintText;
  final T? selectedItem;
  final String Function(T item) itemLabel;
  final String? Function(T item)? itemSecondaryLabel;
  final Future<List<T>> Function(String query) searchFunction;
  final ValueChanged<T?> onChanged;
  final Future<T?> Function()? onAddNew;
  final String? addNewLabel;
  final String emptyMessage;
  final IconData prefixIcon;
  final bool enabled;

  void _openSearchSheet(BuildContext context) {
    if (!enabled) return;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _SmartLookupBottomSheet<T>(
        title: label,
        hintText: hintText,
        itemLabel: itemLabel,
        itemSecondaryLabel: itemSecondaryLabel,
        searchFunction: searchFunction,
        onSelected: (item) {
          onChanged(item);
          Navigator.of(sheetContext).pop();
        },
        onAddNew: onAddNew != null
            ? () async {
                final newItem = await onAddNew!();
                if (newItem != null && sheetContext.mounted) {
                  onChanged(newItem);
                  Navigator.of(sheetContext).pop();
                }
              }
            : null,
        addNewLabel: addNewLabel,
        emptyMessage: emptyMessage,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasSelection = selectedItem != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: AppColors.deepBlue,
          ),
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: enabled ? () => _openSearchSheet(context) : null,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: enabled ? Colors.white : AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: hasSelection ? AppColors.waterBlue : AppColors.border,
                width: hasSelection ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  prefixIcon,
                  size: 20,
                  color: hasSelection ? AppColors.waterBlue : AppColors.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: hasSelection
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              itemLabel(selectedItem as T),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: AppColors.deepBlue,
                              ),
                            ),
                            if (itemSecondaryLabel != null &&
                                itemSecondaryLabel!(selectedItem as T) != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                itemSecondaryLabel!(selectedItem as T)!,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ],
                        )
                      : Text(
                          hintText,
                          style: const TextStyle(
                            fontSize: 14,
                            color: AppColors.textMuted,
                          ),
                        ),
                ),
                if (hasSelection && enabled)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18, color: AppColors.textMuted),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => onChanged(null),
                  )
                else
                  const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SmartLookupBottomSheet<T> extends StatefulWidget {
  const _SmartLookupBottomSheet({
    required this.title,
    required this.hintText,
    required this.itemLabel,
    required this.searchFunction,
    required this.onSelected,
    this.itemSecondaryLabel,
    this.onAddNew,
    this.addNewLabel,
    this.emptyMessage = 'لا توجد نتائج مطابقة',
  });

  final String title;
  final String hintText;
  final String Function(T item) itemLabel;
  final String? Function(T item)? itemSecondaryLabel;
  final Future<List<T>> Function(String query) searchFunction;
  final ValueChanged<T> onSelected;
  final Future<void> Function()? onAddNew;
  final String? addNewLabel;
  final String emptyMessage;

  @override
  State<_SmartLookupBottomSheet<T>> createState() =>
      _SmartLookupBottomSheetState<T>();
}

class _SmartLookupBottomSheetState<T> extends State<_SmartLookupBottomSheet<T>> {
  final TextEditingController _searchController = TextEditingController();
  List<T> _results = [];
  bool _isLoading = true;
  String? _searchError;
  String _currentQuery = '';

  @override
  void initState() {
    super.initState();
    _performSearch('');
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _performSearch(String query) async {
    setState(() => _isLoading = true);
    _currentQuery = query;

    try {
      final items = await widget.searchFunction(query);
      if (mounted && _currentQuery == query) {
        setState(() {
          _results = items;
          _searchError = null;
          _isLoading = false;
        });
      }
    } catch (_) {
      // م-41C1: فشل عقد القراءة يظهر صريحًا بدل قائمة فارغة مضلِّلة.
      if (mounted) {
        setState(() {
          _results = [];
          _searchError = 'تعذّر تحميل النتائج. تحقق من الاتصال ثم أعد المحاولة.';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: Container(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [

              // 1. مقبض السحب والعنوان
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'اختيار ${widget.title}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.deepBlue,
                    ),
                  ),
                  if (widget.onAddNew != null)
                    TextButton.icon(
                      onPressed: () => widget.onAddNew!(),
                      icon: const Icon(Icons.add, size: 18, color: AppColors.waterBlue),
                      label: Text(
                        widget.addNewLabel ?? 'إضافة جديد',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.waterBlue,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),

              // 2. حقل البحث اللحظي مع توحيد الأرقام
              TextField(
                controller: _searchController,
                autofocus: true,
                inputFormatters: const [
                  ArabicToEnglishDigitsFormatter(),
                ],
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: const TextStyle(fontSize: 13, color: AppColors.textMuted),
                  prefixIcon: const Icon(Icons.search, size: 20, color: AppColors.waterBlue),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18, color: AppColors.textMuted),
                          onPressed: () {
                            _searchController.clear();
                            _performSearch('');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: AppColors.surface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (val) => _performSearch(val.trim()),
              ),
              const SizedBox(height: 12),

              // 3. قائمة النتائج
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.45,
                ),
                child: _isLoading
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    : _searchError != null
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.cloud_off_rounded,
                                    size: 48, color: AppColors.error),
                                const SizedBox(height: 10),
                                Text(
                                  _searchError!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.error,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  onPressed: () => _performSearch(_currentQuery),
                                  icon: const Icon(Icons.refresh_rounded, size: 18),
                                  label: const Text('إعادة المحاولة'),
                                ),
                              ],
                            ),
                          )
                        : _results.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.person_search_outlined,
                                    size: 48, color: AppColors.textMuted),
                                const SizedBox(height: 10),
                                Text(
                                  widget.emptyMessage,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                                if (widget.onAddNew != null) ...[
                                  const SizedBox(height: 12),
                                  ElevatedButton.icon(
                                    onPressed: () => widget.onAddNew!(),
                                    icon: const Icon(Icons.add, size: 18),
                                    label: Text(
                                      widget.addNewLabel ?? 'إضافة جديد الآن',
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.waterBlue,
                                      foregroundColor: Colors.white,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            itemCount: _results.length,
                            separatorBuilder: (context, index) => const Divider(height: 1),
                            itemBuilder: (context, index) {

                              final item = _results[index];
                              final primary = widget.itemLabel(item);
                              final secondary = widget.itemSecondaryLabel != null
                                  ? widget.itemSecondaryLabel!(item)
                                  : null;

                              return ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                leading: CircleAvatar(
                                  radius: 18,
                                  backgroundColor:
                                      AppColors.waterBlue.withValues(alpha: 0.1),
                                  child: Text(
                                    primary.isNotEmpty ? primary[0] : '؟',
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: AppColors.waterBlue,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  primary,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.deepBlue,
                                  ),
                                ),
                                subtitle: secondary != null
                                    ? Text(
                                        secondary,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: AppColors.textSecondary,
                                        ),
                                      )
                                    : null,
                                trailing: const Icon(
                                  Icons.chevron_left,
                                  size: 20,
                                  color: AppColors.textMuted,
                                ),
                                onTap: () => widget.onSelected(item),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
}



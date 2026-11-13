import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/api/operations_repository.dart';

bool _selectable(Farm farm, String well, String farmer) =>
    farm.id.isNotEmpty &&
    farm.wellId == well &&
    farm.farmerAccountId == farmer &&
    farm.status == 'active' &&
    !farm.isPending;
String _cursorKey(Map<String, Object?> cursor) {
  final keys = cursor.keys.toList()..sort();
  return jsonEncode({for (final key in keys) key: cursor[key]});
}

Future<FarmSearchPage> _page(
  OperationsRepository repository,
  String well,
  String farmer,
  String query,
  Map<String, Object?>? after,
) async {
  final page = await repository.searchFarmPage(
    well,
    farmerAccountId: farmer,
    query: query,
    limit: 50,
    after: after,
  );
  if (page.items.any((f) => !_selectable(f, well, farmer))) {
    throw StateError('invalid_farm_scope');
  }
  return page;
}

/// لا يوجد lookup بالمعرّف في القراءة القائمة. نفحص صفحات محدودة الحجم،
/// ونحتفظ بصفحة واحدة فقط حتى إيجاد الهوية الدقيقة أو انتهاء النتائج.
Future<Farm?> resolveManualSessionFarm({
  required OperationsRepository repository,
  required String wellId,
  required String farmerAccountId,
  required String farmId,
  required bool Function() isCurrent,
}) async {
  Map<String, Object?>? cursor;
  final seen = <String>{};
  do {
    if (!isCurrent()) return null;
    final page = await _page(repository, wellId, farmerAccountId, '', cursor);
    if (!isCurrent()) return null;
    for (final farm in page.items) {
      if (farm.id == farmId) return farm;
    }
    cursor = page.nextCursor;
    if (cursor != null && !seen.add(_cursorKey(cursor))) {
      throw StateError('farm_cursor_repeated');
    }
  } while (cursor != null);
  return null;
}

/// اختيار أرض محدود النطاق؛ البحث والصفحات من عقد القراءة المعتمد.
class ManualSessionFarmPicker extends StatefulWidget {
  const ManualSessionFarmPicker({
    super.key,
    required this.repository,
    required this.wellId,
    required this.farmerAccountId,
    required this.isCurrent,
    this.selectedFarm,
  });
  final OperationsRepository repository;
  final String wellId, farmerAccountId;
  final bool Function() isCurrent;
  final Farm? selectedFarm;
  @override
  State<ManualSessionFarmPicker> createState() =>
      _ManualSessionFarmPickerState();
}

class _ManualSessionFarmPickerState extends State<ManualSessionFarmPicker> {
  final _search = TextEditingController();
  final _seenCursors = <String>{};
  Timer? _debounce;
  int _generation = 0;
  bool _loading = true, _fetching = false;
  String _query = '';
  String? _error;
  List<Farm> _items = [];
  Map<String, Object?>? _next;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _generation++;
    _search.dispose();
    super.dispose();
  }

  void _changed(String value) {
    final query = value.trim();
    if (query == _query) return;
    _debounce?.cancel();
    _generation++;
    setState(() {
      _query = query;
      _items = [];
      _next = null;
      _seenCursors.clear();
      _error = null;
      _loading = true;
      _fetching = false;
    });
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  Future<void> _load() async {
    if (_fetching || !widget.isCurrent()) return;
    final generation = _generation;
    final query = _query, cursor = _next;
    setState(() {
      _fetching = true;
      _loading = true;
      _error = null;
    });
    try {
      final page = await _page(
        widget.repository,
        widget.wellId,
        widget.farmerAccountId,
        query,
        cursor,
      );
      if (!mounted || generation != _generation) return;
      if (!widget.isCurrent()) {
        setState(() {
          _items = [];
          _loading = false;
          _fetching = false;
          _error = 'تغير المزارع أو البئر. أغلق القائمة واختر الأرض مجددًا.';
        });
        return;
      }
      final next = page.nextCursor;
      if (next != null && !_seenCursors.add(_cursorKey(next))) {
        throw StateError('farm_cursor_repeated');
      }
      setState(() {
        _items = {
          for (final farm in _items) farm.id: farm,
          for (final farm in page.items)
            if (!_items.any((f) => f.id == farm.id)) farm.id: farm,
        }.values.toList();
        _next = next;
        _loading = false;
        _fetching = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _fetching = false;
        _error = 'تعذر تحميل الأراضي. تحقق من الاتصال وأعد المحاولة.';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: Material(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('اختر الأرض')),
                  IconButton(
                    tooltip: 'إغلاق',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              TextField(
                key: const ValueKey('manual-farm-search'),
                controller: _search,
                onChanged: _changed,
                decoration: const InputDecoration(
                  labelText: 'ابحث عن أرض',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              if (widget.selectedFarm case final farm?
                  when _selectable(farm, widget.wellId, widget.farmerAccountId))
                Text(
                  'الأرض المختارة: ${farm.displayName}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              if (_loading)
                const LinearProgressIndicator(
                  semanticsLabel: 'جارٍ تحميل الأراضي',
                ),
              Expanded(
                child: _items.isEmpty
                    ? Center(
                        child: Text(
                          _error ??
                              (_loading
                                  ? 'جارٍ تحميل الأراضي…'
                                  : 'لا توجد أراضٍ مطابقة'),
                        ),
                      )
                    : ListView.builder(
                        key: const ValueKey('manual-farm-results'),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount: _items.length,
                        itemBuilder: (context, index) {
                          final farm = _items[index];
                          return ListTile(
                            key: ValueKey('farm-result-${farm.id}'),
                            title: Text(farm.displayName),
                            selected: widget.selectedFarm?.id == farm.id,
                            onTap: () {
                              if (widget.isCurrent()) {
                                Navigator.pop(context, farm);
                              }
                            },
                          );
                        },
                      ),
              ),
              if (_error != null && _items.isNotEmpty) Text(_error!),
              if (_error != null)
                TextButton(
                  onPressed: _loading ? null : _load,
                  child: const Text('إعادة المحاولة'),
                )
              else if (_next != null)
                TextButton(
                  onPressed: _loading ? null : _load,
                  child: const Text('تحميل المزيد'),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

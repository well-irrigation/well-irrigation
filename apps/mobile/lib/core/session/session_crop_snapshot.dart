/// التطبيع المشترك للقائمة التي تُحفظ كلقطة محاصيل للجلسة.
library;

/// يحافظ على أول ظهور بالترتيب، ويزيل الفراغات والعناصر الفارغة والتكرار.
/// هذا يطابق تطبيع عقد بدء الجلسة قبل تخزين اللقطة في الخادم.
List<String> normalizeCropSnapshot(Iterable<Object?> rawCrops) {
  final result = <String>[];
  final seen = <String>{};

  for (final rawCrop in rawCrops) {
    final crop = rawCrop?.toString().trim() ?? '';
    if (crop.isEmpty || !seen.add(crop)) continue;
    result.add(crop);
  }

  return List.unmodifiable(result);
}

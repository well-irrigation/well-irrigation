/// مراجع الكيانات غير المحسومة داخل حمولة الأمر.
///
/// عملية ميدانية كاملة بلا شبكة تُنشئ مزارعًا ثم أرضًا ثم جلسة، ولا
/// أحد منها يملك معرّفًا خادميًا بعد. فالحمولة تحمل **مرجعًا** إلى
/// المعرّف المحلي، ويُستبدل بالمعرّف الخادمي لحظة الإرسال بعد أن
/// يُحسم الأصل — القسم 22 من `ANDROID_OFFLINE_BACKGROUND_SYNC.md`:
/// «Worker لا يرسل Child Command قبل حسم Parent IDs».
library;

import 'command_type.dart';

/// مرجع إلى كيان أُنشئ محليًا ولم يُحسم معرّفه الخادمي بعد.
class CommandReference {
  const CommandReference({required this.localId, required this.kind});

  /// المعرّف المحلي للأمر الذي يُنتج هذا الكيان.
  final String localId;

  /// نوع الكيان المتوقَّع — يمنع ربط أرض بمعرّف جلسة بالخطأ.
  final EntityKind kind;

  static const String refKey = r'$ref';
  static const String kindKey = r'$kind';

  Map<String, Object?> toJson() => {
    refKey: localId,
    kindKey: kind.storageValue,
  };

  /// هل هذه الخريطة مرجعًا وليست قيمة عادية؟
  static bool isReference(Object? value) =>
      value is Map && value.containsKey(refKey);

  static CommandReference fromJson(Map<Object?, Object?> json) {
    final localId = json[refKey];
    final kind = json[kindKey];

    if (localId is! String || kind is! String) {
      throw FormatException('مرجع غير صالح داخل حمولة الأمر: $json');
    }

    return CommandReference(
      localId: localId,
      kind: EntityKind.fromStorage(kind),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CommandReference &&
      other.localId == localId &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(localId, kind);

  @override
  String toString() => 'CommandReference(${kind.storageValue}:$localId)';
}

/// يُرفع عندما يُطلب إرسال أمر ما زال يحمل مرجعًا غير محسوم.
///
/// وجوده يعني خطأً في ترتيب الإرسال، لا خطأ شبكة: المحرك يجب أن
/// يتخطى الأمر لا أن يحاول إرساله.
class UnresolvedReferenceException implements Exception {
  const UnresolvedReferenceException(this.reference);

  final CommandReference reference;

  @override
  String toString() =>
      'مرجع غير محسوم: ${reference.kind.storageValue}:${reference.localId}';
}

/// يجمع كل المراجع الموجودة في حمولة، بأي عمق.
Set<CommandReference> collectReferences(Object? payload) {
  final found = <CommandReference>{};
  _walk(payload, found.add);
  return found;
}

/// يستبدل كل مرجع بمعرّفه الخادمي عبر [resolve].
///
/// [resolve] تُعيد `null` إذا لم يُحسم المرجع بعد، فيُرفع
/// [UnresolvedReferenceException] — لا يُرسل أمر بمرجع ناقص أبدًا.
Object? resolveReferences(
  Object? payload,
  String? Function(CommandReference reference) resolve,
) {
  if (CommandReference.isReference(payload)) {
    final reference = CommandReference.fromJson(
      (payload as Map).cast<Object?, Object?>(),
    );
    final serverId = resolve(reference);

    if (serverId == null) {
      throw UnresolvedReferenceException(reference);
    }

    return serverId;
  }

  if (payload is Map) {
    return {
      for (final entry in payload.entries)
        entry.key.toString(): resolveReferences(entry.value, resolve),
    };
  }

  if (payload is List) {
    return [for (final item in payload) resolveReferences(item, resolve)];
  }

  return payload;
}

void _walk(Object? value, void Function(CommandReference) onFound) {
  if (CommandReference.isReference(value)) {
    onFound(CommandReference.fromJson((value as Map).cast<Object?, Object?>()));
    return;
  }

  if (value is Map) {
    for (final item in value.values) {
      _walk(item, onFound);
    }
    return;
  }

  if (value is List) {
    for (final item in value) {
      _walk(item, onFound);
    }
  }
}

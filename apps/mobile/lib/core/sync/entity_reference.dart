/// تجريد نوعي لهوية الكيان: محسومة على الخادم أم محلية معلقة في الطابور.
///
/// يحل مشكلة خلط المعرفات المحلية (localId) مع المعرفات الخادمية (UUID)
/// ويمنع كشف المعرفات الداخلية في واجهة المستخدم (UX-Honesty / ق-89 / ق-114).
library;

import 'command_reference.dart';
import 'command_type.dart';

sealed class EntityReference {
  const EntityReference();

  /// هل الكيان ما زال معلقاً محلياً في الطابور ولم يُحسم معرّفه الخادمي بعد؟
  bool get isPending;

  /// هل الكيان محسوم على الخادم؟
  bool get isServer => !isPending;

  /// معرّف الكيان على الخادم (UUID)، أو `null` إذا كان معلقاً.
  String? get serverId;

  /// المرجع المحلي، أو `null` إذا كان محسوماً على الخادم.
  CommandReference? get localReference;

  /// تمثيل الهوية داخل حمولة الأمر:
  /// - إذا كان محسوماً: نص المعرف الخادمي (String UUID).
  /// - إذا كان معلقاً: خريطة المرجع ({$ref: localId, $kind: kind}).
  Object toPayload();
}

/// هوية كيان محسومة ومعتمدة على الخادم بمعرّف UUID.
final class ServerEntityReference extends EntityReference {
  const ServerEntityReference(this.id);

  final String id;

  @override
  bool get isPending => false;

  @override
  String? get serverId => id;

  @override
  CommandReference? get localReference => null;

  @override
  Object toPayload() => id;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerEntityReference && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'ServerEntityReference($id)';
}

/// هوية كيان محلية معلقة محفوظة في الطابور المتين ولم تُؤكَّد بعد من الخادم.
final class PendingLocalEntityReference extends EntityReference {
  const PendingLocalEntityReference(this.reference);

  PendingLocalEntityReference.create({
    required String localId,
    required EntityKind kind,
  }) : reference = CommandReference(localId: localId, kind: kind);

  final CommandReference reference;

  @override
  bool get isPending => true;

  @override
  String? get serverId => null;

  @override
  CommandReference? get localReference => reference;

  @override
  Object toPayload() => reference.toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PendingLocalEntityReference && other.reference == reference;

  @override
  int get hashCode => reference.hashCode;

  @override
  String toString() => 'PendingLocalEntityReference($reference)';
}

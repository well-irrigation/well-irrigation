import '../api/operations_repository.dart';
import '../sync/command_reference.dart';
import '../sync/command_type.dart';
import '../sync/entity_reference.dart';
import '../sync/outbox_store.dart';
import '../sync/sync_status.dart';

/// الربط يحوّل المفتاح المحلي إلى هوية الأرض المعتمدة دون تغيير الأصل.
List<Farm> projectFarmSelection({
  required List<Farm> canonical,
  required List<FarmCommandRow> local,
  required String wellId,
  required String farmerId,
  int limit = 50,
  String query = '',
}) {
  if (limit < 1 || limit > 100) throw ArgumentError('حد الأراضي غير صالح');
  final result = <EntityReference, Farm>{};
  for (final row in local) {
    final c = row.command;
    if (c.wellId != wellId ||
        c.type != CommandType.createFarm ||
        c.status == CommandStatus.review ||
        row.farmerId != farmerId) {
      continue;
    }
    final name = c.payload['p_name'] as String?;
    if (name == null || name.isEmpty) continue;
    final farm = row.serverId != null
        ? Farm(
            id: row.serverId!,
            wellId: wellId,
            name: name,
            distinguishingLabel: c.payload['p_distinguishing_label'] as String?,
            farmerAccountId: farmerId,
          )
        : Farm.pending(
            reference: CommandReference(
              localId: c.localId,
              kind: EntityKind.farm,
            ),
            wellId: wellId,
            name: name,
            distinguishingLabel: c.payload['p_distinguishing_label'] as String?,
            farmerReference: c.payload['p_farmer_well_account_id'] is Map
                ? PendingLocalEntityReference(
                    CommandReference.fromJson(
                      (c.payload['p_farmer_well_account_id'] as Map)
                          .cast<Object?, Object?>(),
                    ),
                  )
                : ServerEntityReference(farmerId),
          );
    result.putIfAbsent(farm.entityReference, () => farm);
  }
  for (final farm in canonical) {
    if (!farm.isPending &&
        farm.status == 'active' &&
        farm.wellId == wellId &&
        farm.farmerAccountId == farmerId) {
      result[farm.entityReference] = farm;
    }
  }
  final q = normalizeFarmSearch(query);
  int rank(Farm f) {
    final n = normalizeFarmSearch(f.name);
    return n == q
        ? 0
        : n.startsWith(q)
        ? 1
        : 2;
  }

  final sorted =
      result.values
          .where(
            (f) => q.isEmpty || normalizeFarmSearch(f.displayName).contains(q),
          )
          .toList()
        ..sort((a, b) {
          final r = rank(a).compareTo(rank(b));
          if (r != 0) return r;
          final n = normalizeFarmSearch(a.name)
              .compareTo(normalizeFarmSearch(b.name));
          return n != 0
              ? n
              : a.entityReference.toPayload().toString().compareTo(
                  b.entityReference.toPayload().toString(),
                );
        });
  return sorted.take(limit).toList();
}

/// تطبيع للبحث والعرض فقط؛ لا يقرر هوية أرض أو يدمجها بالاسم.
String normalizeFarmSearch(String value) {
  var s = value
      .toLowerCase()
      .replaceAll(RegExp('[ً-ٰـ]'), '')
      .replaceAll('ء', '');
  const from = 'أإآٱئؤىة';
  const to = 'ااااييوه';
  for (var i = 0; i < from.length; i++) {
    s = s.replaceAll(from[i], to[i]);
  }
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

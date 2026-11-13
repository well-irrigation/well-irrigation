import '../../core/sync/command_envelope.dart';
import '../../core/sync/manual_session_entry.dart';
import '../../core/sync/outbox_repository.dart';
import '../../core/sync/sqlite_outbox_store.dart';
import '../../core/sync/sync_status.dart';

/// قراءة الطابور القائم فقط لاستئناف العرض؛ لا حفظ أو إعادة إنشاء للطلبات.
Future<List<CommandEnvelope>> savedManualSessionEntries({
  required String accountId,
  required String wellId,
  OutboxRepository? outbox,
}) async {
  final store = outbox == null
      ? SqliteOutboxStore(singleInstance: false)
      : null;
  final repository = outbox ?? OutboxRepository(store: store!);
  try {
    await repository.initialize();
    final commands = await repository.all(accountId);
    return commands
        .where(
          (c) =>
              c.accountId == accountId &&
              c.wellId == wellId &&
              c.status != CommandStatus.confirmed &&
              ManualSessionEntryReceiptRequest.fromCommand(c) != null,
        )
        .toList()
      ..sort((a, b) => b.sequence.compareTo(a.sequence));
  } finally {
    await store?.close();
  }
}

/// كل عنصر يُقرأ بعقد النواة المتسق؛ لا تصنيف أهلية داخل العرض.
Future<List<ManualSessionEntryFollowUp>> savedManualSessionEntryFollowUps({
  required String accountId,
  required String wellId,
  OutboxRepository? outbox,
}) async {
  final store = outbox == null
      ? SqliteOutboxStore(singleInstance: false)
      : null;
  final repository = outbox ?? OutboxRepository(store: store!);
  try {
    final commands = await savedManualSessionEntries(
      accountId: accountId,
      wellId: wellId,
      outbox: repository,
    );
    final snapshots = <ManualSessionEntryFollowUp>[];
    for (final c in commands) {
      final view = await repository.readManualSessionEntryFollowUp(
        accountId: accountId,
        wellId: wellId,
        localId: c.localId,
      );
      if (view != null) snapshots.add(view);
    }
    return snapshots;
  } finally {
    await store?.close();
  }
}

/// تنفيذ الطابور في الذاكرة — للاختبار فقط.
///
/// يطابق سلوك `SqliteOutboxStore` بنفس القيود: فرادة `commandId`،
/// وحجز شرطي، وعزل بالحساب. وجوده يجعل كل منطق المزامنة قابلًا
/// للاختبار بلا هاتف وبلا قاعدة بيانات.
library;

import 'command_envelope.dart';
import 'command_type.dart';
import 'outbox_store.dart';
import 'sync_status.dart';

class InMemoryOutboxStore implements OutboxStore {
  final Map<String, List<CommandEnvelope>> _commands = {};
  final Map<String, Map<String, IdMapping>> _mappings = {};
  final Map<String, int> _sequences = {};
  final Map<String, DateTime> _lastSync = {};
  final Set<String> _usedCommandIds = {};
  bool _closed = false;

  @override
  Future<void> initialize() async {}

  @override
  Future<CommandEnvelope> insert(CommandEnvelope envelope) async {
    _assertOpen();

    if (!_usedCommandIds.add(envelope.commandId)) {
      throw DuplicateCommandIdException(envelope.commandId);
    }

    _commands.putIfAbsent(envelope.accountId, () => []).add(envelope);

    return envelope;
  }

  @override
  Future<int> nextSequence(String accountId) async {
    _assertOpen();

    final next = (_sequences[accountId] ?? 0) + 1;
    _sequences[accountId] = next;

    return next;
  }

  @override
  Future<List<CommandEnvelope>> pendingCommands(String accountId) async {
    _assertOpen();

    final rows = (_commands[accountId] ?? const <CommandEnvelope>[])
        .where((row) => row.status != CommandStatus.confirmed)
        .toList();

    rows.sort((a, b) => a.sequence.compareTo(b.sequence));

    return rows;
  }

  @override
  Future<CommandEnvelope?> commandByLocalId(
    String accountId,
    String localId,
  ) async {
    _assertOpen();

    for (final row in _commands[accountId] ?? const <CommandEnvelope>[]) {
      if (row.localId == localId) {
        return row;
      }
    }

    return null;
  }

  @override
  Future<List<CommandEnvelope>> allCommands(String accountId) async {
    _assertOpen();

    final rows = [...?_commands[accountId]];
    rows.sort((a, b) => a.sequence.compareTo(b.sequence));

    return rows;
  }

  @override
  Future<bool> claim(
    String accountId,
    String localId, {
    required DateTime attemptedAt,
  }) async {
    _assertOpen();

    final index = _indexOf(accountId, localId);

    if (index == null) {
      return false;
    }

    final rows = _commands[accountId]!;

    if (rows[index].status != CommandStatus.pending) {
      return false;
    }

    rows[index] = rows[index].copyWith(
      status: CommandStatus.dispatching,
      lastAttemptAt: attemptedAt,
    );

    return true;
  }

  @override
  Future<void> releaseForRetry(
    String accountId,
    String localId, {
    required String error,
    required DateTime attemptedAt,
  }) async {
    _update(
      accountId,
      localId,
      (row) => row.copyWith(
        status: CommandStatus.pending,
        retryCount: row.retryCount + 1,
        lastError: error,
        lastAttemptAt: attemptedAt,
      ),
    );
  }

  @override
  Future<void> markConfirmed(
    String accountId,
    String localId, {
    required Map<String, Object?> serverResponse,
    required DateTime attemptedAt,
  }) async {
    _update(
      accountId,
      localId,
      (row) => row.copyWith(
        status: CommandStatus.confirmed,
        clearLastError: true,
        lastAttemptAt: attemptedAt,
        serverResponse: serverResponse,
      ),
    );
  }

  @override
  Future<void> markNeedsReview(
    String accountId,
    String localId, {
    required String error,
    required DateTime attemptedAt,
  }) async {
    _update(
      accountId,
      localId,
      (row) => row.copyWith(
        status: CommandStatus.review,
        lastError: error,
        lastAttemptAt: attemptedAt,
      ),
    );
  }

  @override
  Future<void> putMapping(String accountId, IdMapping mapping) async {
    _assertOpen();

    _mappings.putIfAbsent(accountId, () => {})[_mappingKey(
      mapping.localId,
      mapping.kind,
    )] = mapping;
  }

  @override
  Future<IdMapping?> mapping(
    String accountId,
    String localId,
    EntityKind kind,
  ) async {
    _assertOpen();

    return _mappings[accountId]?[_mappingKey(localId, kind)];
  }

  @override
  Future<List<IdMapping>> mappings(String accountId) async {
    _assertOpen();

    return [...?_mappings[accountId]?.values];
  }

  @override
  Future<DateTime?> lastSuccessfulSyncAt(String accountId) async {
    _assertOpen();

    return _lastSync[accountId];
  }

  @override
  Future<void> setLastSuccessfulSyncAt(String accountId, DateTime at) async {
    _assertOpen();

    _lastSync[accountId] = at;
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  /// يُعيد فتح نفس البيانات — يحاكي تشغيل التطبيق من جديد بعد موته.
  ///
  /// البيانات هي نفسها لأن هذا المخزن نفسه هو «القرص» في الاختبار.
  Future<void> reopen() async {
    _closed = false;
  }

  int? _indexOf(String accountId, String localId) {
    final rows = _commands[accountId];

    if (rows == null) {
      return null;
    }

    for (var index = 0; index < rows.length; index += 1) {
      if (rows[index].localId == localId) {
        return index;
      }
    }

    return null;
  }

  void _update(
    String accountId,
    String localId,
    CommandEnvelope Function(CommandEnvelope row) transform,
  ) {
    _assertOpen();

    final index = _indexOf(accountId, localId);

    if (index == null) {
      return;
    }

    final rows = _commands[accountId]!;
    rows[index] = transform(rows[index]);
  }

  void _assertOpen() {
    if (_closed) {
      throw StateError('المخزن مغلق');
    }
  }

  static String _mappingKey(String localId, EntityKind kind) =>
      '$localId::${kind.storageValue}';
}

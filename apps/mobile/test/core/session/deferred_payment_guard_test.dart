import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

final at = DateTime.utc(2026, 10, 14);
Future<(CommandEnvelope, CommandEnvelope)> closedSession(
  OfflineSessionCoordinator c,
  OutboxStore store, {
  String account = 'a',
  String well = 'w',
  String server = 'server',
}) async {
  final start = await c.startSession(
    accountId: account,
    wellId: well,
    pumpId: 'p',
    farmId: 'f',
    farmerAccountId: 'farmer',
    energySource: 'solar',
    startedAt: at,
  );
  final end = await c.completeSession(
    accountId: account,
    sessionLocalId: start.localId,
    completedAt: at.add(const Duration(minutes: 2)),
  );
  await store.putMapping(
    account,
    IdMapping(
      localId: start.localId,
      kind: EntityKind.session,
      serverId: server,
      resolvedAt: at,
    ),
  );
  await store.markConfirmed(
    account,
    end.localId,
    serverResponse: {
      'session_charge_id': 'charge-$server',
      'amount_minor': 100,
    },
    attemptedAt: at,
  );
  return (start, end);
}

Future<CommandEnvelope> pay(
  OfflineSessionCoordinator c,
  (CommandEnvelope, CommandEnvelope) session,
) => c.recordPayment(
  accountId: session.$1.accountId,
  wellId: session.$1.wellId!,
  farmerAccountId: 'farmer',
  amountMinor: 100,
  paymentMethod: 'cash',
  sessionLocalId: session.$1.localId,
  sessionCompletionLocalId: session.$2.localId,
);
SessionDetailData finance(
  String server, {
  String status = 'partial',
  int paid = 40,
}) => SessionDetailData(
  session: SessionHistoryItem(
    id: server,
    wellId: 'w',
    farmerName: 'مزارع',
    farmerCode: 'F1',
    farmerAccountId: 'farmer',
    farmName: 'أرض',
    pumpName: 'مضخة',
    operatorName: 'مشغل',
    startedAt: at,
    endedAt: at.add(const Duration(minutes: 2)),
    hasCharge: true,
    totalAmountYER: 100,
    paidAmountYER: paid,
    paymentStatus: status,
  ),
  segments: const [],
);

class _BoundedStore extends InMemoryOutboxStore {
  bool forbidScans = false;
  String? gatedSession;
  Completer<void>? entered;
  Completer<void>? release;
  @override
  Future<List<CommandEnvelope>> allCommands(String accountId) {
    if (forbidScans) throw StateError('global_scan');
    return super.allCommands(accountId);
  }

  @override
  Future<List<CommandEnvelope>> commandsForWell(
    String accountId,
    String wellId,
  ) {
    if (forbidScans) throw StateError('well_scan');
    return super.commandsForWell(accountId, wellId);
  }

  @override
  Future<SessionOutboxSnapshot?> sessionSnapshot({
    required String accountId,
    required String wellId,
    String? localSessionId,
    String? serverSessionId,
  }) async {
    if (gatedSession != null && localSessionId == gatedSession) {
      gatedSession = null;
      entered!.complete();
      await release!.future;
    }
    return super.sessionSnapshot(
      accountId: accountId,
      wellId: wellId,
      localSessionId: localSessionId,
      serverSessionId: serverSessionId,
    );
  }
}

void main() {
  test('same-session concurrent calls persist exactly one command; pending and review block', () async {
    final store = _BoundedStore();
    final c = OfflineSessionCoordinator(store: store);
    addTearDown(c.dispose);
    final s = await closedSession(c, store);
    final results = await Future.wait([
      for (var i = 0; i < 8; i++)
        pay(c, s).then<Object>((v) => v, onError: (Object e) => e),
    ]);
    expect(results.whereType<CommandEnvelope>(), hasLength(1));
    final payment = results.whereType<CommandEnvelope>().single;
    expect(
      (await store.allCommands('a'))
          .where((v) => v.type == CommandType.recordPayment),
      hasLength(1),
    );
    await expectLater(pay(c, s), throwsStateError);
    await store.markNeedsReview(
      'a',
      payment.localId,
      error: 'conflict',
      attemptedAt: at,
    );
    await expectLater(pay(c, s), throwsStateError);
  });
  for (final status in ['partial', 'settled']) {
    test(
      'accepted $status uses canonical read, never submitted full amount',
      () async {
        final store = InMemoryOutboxStore();
        final c = OfflineSessionCoordinator(store: store);
        addTearDown(c.dispose);
        final s = await closedSession(c, store);
        final p = await pay(c, s);
        await store.putMapping(
          'a',
          IdMapping(
            localId: p.localId,
            kind: EntityKind.payment,
            serverId: 'payment',
            resolvedAt: at,
          ),
        );
        await store.markConfirmed(
          'a',
          p.localId,
          serverResponse: {
            'payment_id': 'payment',
            'settled_minor': 40,
            'receipt': {'public_code': 'PMT-1'},
          },
          attemptedAt: at,
        );
        var restored = (await c.restoreCompletedSession(
          accountId: 'a',
          wellId: 'w',
          serverSessionId: 'server',
        ))!;
        // الإقرار لا يحمل الحالة الإجمالية؛ تبقى مجهولة حتى قراءة الخادم.
        expect(restored.canRecordPayment, isFalse);
        await c.rememberSessionPaymentRead(
          accountId: 'a',
          wellId: 'w',
          detail: finance(
            'server',
            status: status,
            paid: status == 'partial' ? 40 : 100,
          ),
          revision: restored.revision,
        );
        restored = (await c.restoreCompletedSession(
          accountId: 'a',
          wellId: 'w',
          serverSessionId: 'server',
        ))!;
        expect(restored.canRecordPayment, status == 'partial');
        expect(
          restored.record.payments.single.acceptedReceipt?['public_code'],
          'PMT-1',
        );
        if (status == 'partial') {
          await pay(c, s);
        } else {
          await expectLater(pay(c, s), throwsStateError);
        }
      },
    );
  }
  test(
    'one blocked session never blocks another; restore never scans a well',
    () async {
      final store = _BoundedStore();
      final c = OfflineSessionCoordinator(store: store);
      addTearDown(c.dispose);
      final a = await closedSession(c, store);
      final b = await closedSession(c, store, server: 'server-b');
      store.forbidScans = true;
      final restored = await c.restoreCompletedSession(
        accountId: 'a',
        wellId: 'w',
        serverSessionId: 'server',
      );
      expect(restored!.record.localId, a.$1.localId);
      expect(
        await c.restoreCompletedSession(
          accountId: 'other',
          wellId: 'w',
          serverSessionId: 'server',
        ),
        isNull,
      );
      expect(
        await c.restoreCompletedSession(
          accountId: 'a',
          wellId: 'other',
          serverSessionId: 'server',
        ),
        isNull,
      );
      store.gatedSession = a.$1.localId;
      store.entered = Completer<void>();
      store.release = Completer<void>();
      final slow = pay(c, a);
      await store.entered!.future;
      final other = await pay(c, b).timeout(const Duration(seconds: 2));
      expect(other.aggregateLocalId, b.$1.localId);
      store.release!.complete();
      await slow;
    },
  );
  test('SQLite pending survives restart with indexed targeted reads', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('deferred-payment-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/outbox.db';
    var store = SqliteOutboxStore(
      databasePath: path,
      sqfliteFactory: databaseFactoryFfi,
    );
    var c = OfflineSessionCoordinator(store: store);
    final s = await closedSession(c, store);
    final p = await pay(c, s);
    c.dispose();
    await store.close();
    store = SqliteOutboxStore(
      databasePath: path,
      sqfliteFactory: databaseFactoryFfi,
    );
    c = OfflineSessionCoordinator(store: store);
    addTearDown(c.dispose);
    addTearDown(store.close);
    final restored = (await c.restoreCompletedSession(
      accountId: 'a',
      wellId: 'w',
      serverSessionId: 'server',
    ))!;
    expect(restored.record.payments.single.localId, p.localId);
    expect(restored.hasPendingPayment, isTrue);
    await expectLater(pay(c, s), throwsStateError);
    final db = await databaseFactoryFfi.openDatabase(path);
    final plan = await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT * FROM outbox_commands WHERE account_id = ? AND aggregate_local_id = ? ORDER BY sequence',
      ['a', s.$1.localId],
    );
    expect(
      plan.map((v) => v['detail']).join(' '),
      contains('outbox_commands_session_idx'),
    );
    expect(
      plan.map((v) => v['detail']).join(' '),
      isNot(contains('SCAN outbox_commands')),
    );
    final mappingPlan = await db.rawQuery(
      "EXPLAIN QUERY PLAN SELECT local_id FROM id_mappings WHERE account_id = ? AND entity_kind = 'session' AND server_id = ?",
      ['a', 'server'],
    );
    expect(
      mappingPlan.map((v) => v['detail']).join(' '),
      contains('id_mappings_server_idx'),
    );
    final rootPlan = await db.rawQuery(
      "EXPLAIN QUERY PLAN select c.* from outbox_commands c join id_mappings m on m.account_id = c.account_id and m.local_id = c.local_id and m.entity_kind = 'session' where c.account_id = ? and m.server_id = ? and coalesce(c.well_id, json_extract(c.payload, '\$.p_well_id')) = ? limit 2",
      ['a', 'server', 'w'],
    );
    final rootDetails = rootPlan.map((row) => row['detail']).join(' ');
    expect(rootDetails, contains('id_mappings_server_idx'));
    expect(rootDetails, contains('sqlite_autoindex_outbox_commands_1'));
    expect(rootDetails, isNot(contains('SCAN')));
  });
  for (final version in [1, 2]) {
    test(
      'SQLite v$version upgrades without losing legacy rows or pending identities',
      () async {
        sqfliteFfiInit();
        final dir = await Directory.systemTemp.createTemp('e1-legacy-');
        addTearDown(() => dir.delete(recursive: true));
        final path = '${dir.path}/legacy.db';
        final db = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: version,
            onCreate: (db, _) async {
              await db.execute(
                'create table outbox_commands (local_id text primary key, command_id text not null unique, command_type text not null, account_id text not null, well_id text, aggregate_local_id text, sequence integer not null, occurred_at text not null, created_local_at text not null, payload text not null, status text not null, retry_count integer not null default 0, last_error text, last_attempt_at text, server_response text${version == 2 ? ", prerequisites text not null default '[]', local_context text not null default '{}'" : ''})',
              );
              await db.execute(
                'create index outbox_commands_dispatch_idx on outbox_commands (account_id, status, sequence)',
              );
              if (version == 2) {
                await db.execute(
                  'create index outbox_commands_well_idx on outbox_commands (account_id, well_id, sequence)',
                );
              }
              await db.execute(
                'create table id_mappings (account_id text not null, local_id text not null, entity_kind text not null, server_id text not null, resolved_at text not null, matched_existing integer not null default 0, primary key(account_id, local_id, entity_kind))',
              );
              await db.execute(
                'create table sync_meta (account_id text not null, key text not null, value text not null, primary key(account_id,key))',
              );
            },
          ),
        );
        for (final row in [
          {
            'local_id': 'old-start',
            'command_id': 'stable-start',
            'command_type': CommandType.startIrrigationSession.storageValue,
            'aggregate_local_id': null,
            'sequence': 1,
            'payload': '{"p_well_id":"w","p_farmer_well_account_id":"farmer","p_energy_source":"solar"}',
            'status': 'confirmed',
          },
          {
            'local_id': 'old-end',
            'command_id': 'stable-end',
            'command_type': CommandType.completeIrrigationSession.storageValue,
            'aggregate_local_id': 'old-start',
            'sequence': 2,
            'payload': '{"p_session_id":"server"}',
            'status': 'confirmed',
            'server_response':
                '{"session_charge_id":"charge","amount_minor":100}',
          },
          {
            'local_id': 'old-pay',
            'command_id': 'stable-pay',
            'command_type': CommandType.recordPayment.storageValue,
            'aggregate_local_id': 'old-start',
            'sequence': 3,
            'payload':
                '{"p_well_id":"w","p_amount_minor":30,"p_method":"cash"}',
            'status': 'pending',
          },
        ]) {
          await db.insert('outbox_commands', {
            'account_id': 'a',
            'well_id': null,
            'occurred_at': at.toIso8601String(),
            'created_local_at': at.toIso8601String(),
            ...row,
          });
        }
        await db.insert('id_mappings', {
          'account_id': 'a',
          'local_id': 'old-start',
          'entity_kind': 'session',
          'server_id': 'server',
          'resolved_at': at.toIso8601String(),
        });
        await db.close();
        for (var reopen = 0; reopen < 2; reopen++) {
          final store = SqliteOutboxStore(
            databasePath: path,
            sqfliteFactory: databaseFactoryFfi,
          );
          final c = OfflineSessionCoordinator(store: store);
          final state = (await c.restoreCompletedSession(
            accountId: 'a',
            wellId: 'w',
            serverSessionId: 'server',
          ))!;
          expect(state.record.localId, 'old-start');
          expect(state.record.payments.single.localId, 'old-pay');
          expect(state.hasPendingPayment, isTrue);
          expect(
            (await store.commandByLocalId('a', 'old-pay'))!.commandId,
            'stable-pay',
          );
          expect(
            await c.restoreCompletedSession(
              accountId: 'b',
              wellId: 'w',
              serverSessionId: 'server',
            ),
            isNull,
          );
          expect(
            await c.restoreCompletedSession(
              accountId: 'a',
              wellId: 'other',
              serverSessionId: 'server',
            ),
            isNull,
          );
          c.dispose();
          await store.close();
        }
      },
    );
  }
  test(
    'stale pre-ACK canonical read cannot authorize another payment',
    () async {
      final store = InMemoryOutboxStore();
      final c = OfflineSessionCoordinator(store: store);
      addTearDown(c.dispose);
      final session = await closedSession(c, store);
      final before = (await c.restoreCompletedSession(
        accountId: 'a',
        wellId: 'w',
        serverSessionId: 'server',
      ))!;
      final p = await pay(c, session);
      await c.rememberSessionPaymentRead(
        accountId: 'a',
        wellId: 'w',
        detail: finance('server'),
        revision: before.revision,
      );
      final pending = (await c.restoreCompletedSession(
        accountId: 'a',
        wellId: 'w',
        serverSessionId: 'server',
      ))!;
      expect(pending.paymentRead, isNull);
      expect(pending.canRecordPayment, isFalse);
      await store.putMapping(
        'a',
        IdMapping(
          localId: p.localId,
          kind: EntityKind.payment,
          serverId: 'payment',
          resolvedAt: at,
        ),
      );
      await store.markConfirmed(
        'a',
        p.localId,
        serverResponse: {'payment_id': 'payment', 'settled_minor': 100},
        attemptedAt: at,
      );
      await c.rememberSessionPaymentRead(
        accountId: 'a',
        wellId: 'w',
        detail: finance('server'),
        revision: pending.revision,
      );
      expect(
        (await c.restoreCompletedSession(
          accountId: 'a',
          wellId: 'w',
          serverSessionId: 'server',
        ))!.canRecordPayment,
        isFalse,
      );
    },
  );

  test('SQLite atomic insert prevents two coordinator instances creating two session payments', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('e1-atomic-');
    addTearDown(() => dir.delete(recursive: true));
    final store = SqliteOutboxStore(
      databasePath: '${dir.path}/outbox.db',
      sqfliteFactory: databaseFactoryFfi,
    );
    addTearDown(store.close);
    final a = OfflineSessionCoordinator(store: store);
    final b = OfflineSessionCoordinator(store: store);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final session = await closedSession(a, store);
    final results = await Future.wait([
      pay(a, session).then<Object>((v) => v, onError: (Object e) => e),
      pay(b, session).then<Object>((v) => v, onError: (Object e) => e),
    ]);
    expect(results.whereType<CommandEnvelope>(), hasLength(1));
    expect(
      (await store.allCommands('a'))
          .where((c) => c.type == CommandType.recordPayment),
      hasLength(1),
    );
  });
  for (final status in ['partial', 'settled']) {
    test(
      'canonical $status read and ACK remain truthful after SQLite restart',
      () async {
        sqfliteFfiInit();
        final dir = await Directory.systemTemp.createTemp('e1-accepted-');
        addTearDown(() => dir.delete(recursive: true));
        final path = '${dir.path}/outbox.db';
        var store = SqliteOutboxStore(
          databasePath: path,
          sqfliteFactory: databaseFactoryFfi,
        );
        var c = OfflineSessionCoordinator(store: store);
        final session = await closedSession(c, store);
        final p = await pay(c, session);
        await store.putMapping(
          'a',
          IdMapping(
            localId: p.localId,
            kind: EntityKind.payment,
            serverId: 'accepted',
            resolvedAt: at,
          ),
        );
        await store.markConfirmed(
          'a',
          p.localId,
          serverResponse: {
            'payment_id': 'accepted',
            'receipt': {'public_code': 'PMT-ACCEPTED'},
          },
          attemptedAt: at,
        );
        final current = (await c.restoreCompletedSession(
          accountId: 'a',
          wellId: 'w',
          serverSessionId: 'server',
        ))!;
        await c.rememberSessionPaymentRead(
          accountId: 'a',
          wellId: 'w',
          detail: finance(
            'server',
            status: status,
            paid: status == 'partial' ? 40 : 100,
          ),
          revision: current.revision,
        );
        c.dispose();
        await store.close();
        store = SqliteOutboxStore(
          databasePath: path,
          sqfliteFactory: databaseFactoryFfi,
        );
        c = OfflineSessionCoordinator(store: store);
        addTearDown(c.dispose);
        addTearDown(store.close);
        final restored = (await c.restoreCompletedSession(
          accountId: 'a',
          wellId: 'w',
          serverSessionId: 'server',
        ))!;
        expect(restored.paymentStatus, status);
        expect(restored.canRecordPayment, status == 'partial');
        expect(restored.cachedDetail!.session.paymentStatus, status);
        expect(
          restored.record.payments.single.acceptedReceipt?['public_code'],
          'PMT-ACCEPTED',
        );
      },
    );
  }
}

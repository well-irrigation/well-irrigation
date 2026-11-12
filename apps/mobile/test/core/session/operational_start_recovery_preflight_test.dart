import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/operational_start_recovery.dart';
import 'package:well_irrigation_mobile/core/sync/start_recovery_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';

import 'operational_start_guided_recovery_test.dart';

class PreflightStore extends InMemoryOutboxStore {
  int writes = 0;
  @override
  Future<CommandEnvelope> insert(CommandEnvelope c) {
    writes++;
    return super.insert(c);
  }

  @override
  Future<String> insertBundle({
    required String accountId,
    required String key,
    required String value,
    required List<CommandEnvelope> commands,
    Map<String, String> localValues = const {},
    bool Function()? isCurrent,
  }) {
    writes++;
    return super.insertBundle(
      accountId: accountId,
      key: key,
      value: value,
      commands: commands,
      localValues: localValues,
      isCurrent: isCurrent,
    );
  }

  @override
  Future<void> putMapping(String accountId, IdMapping mapping) {
    writes++;
    return super.putMapping(accountId, mapping);
  }

  @override
  Future<T> startRecoveryTransaction<T>(
    String accountId,
    StartRecoveryWrite<T> Function(StartRecoverySnapshot) decide,
  ) {
    writes++;
    return super.startRecoveryTransaction(accountId, decide);
  }

  CommandEnvelope? Function(CommandEnvelope?)? alter;
  @override
  Future<CommandEnvelope?> commandByLocalId(
    String accountId,
    String localId,
  ) async =>
      alter?.call(await super.commandByLocalId(accountId, localId)) ??
      await super.commandByLocalId(accountId, localId);
}

CommandEnvelope altered(
  CommandEnvelope c, {
  String? account,
  String? well,
  bool withoutWell = false,
  Map<String, Object?>? payload,
  CommandType? type,
}) => CommandEnvelope(
  localId: c.localId,
  commandId: c.commandId,
  accountId: account ?? c.accountId,
  type: type ?? c.type,
  wellId: withoutWell ? null : well ?? c.wellId,
  sequence: c.sequence,
  occurredAt: c.occurredAt,
  createdLocalAt: c.createdLocalAt,
  payload: payload ?? c.payload,
  status: c.status,
  lastError: c.lastError,
  lastAttemptAt: c.lastAttemptAt,
);

void main() {
  for (final scenario in {
    'auth': 'auth_scope_mismatch',
    'auth_and_empty': 'auth_scope_mismatch',
    'account_and_type': 'saved_account_mismatch',
    'missing_well_and_type': 'saved_well_mismatch',
    'empty_well': 'empty_well',
    'empty_root': 'empty_session_local_id',
    'missing': 'saved_root_missing',
    'account': 'saved_account_mismatch',
    'well': 'saved_well_mismatch',
    'payload': 'payload_well_mismatch',
    'historical': 'unsupported_start_type',
    'valid': 'server_session_found',
  }.entries) {
    test(
      '${scenario.key}: scope guards preserve result, no writes/dispatch',
      () async {
        final store = PreflightStore();
        final root = await reviewStart(store);
        final transport = GuidedReceiptTransport();
        final repository = GuidedRepository();
        String? account = 'account';
        String well = 'well', local = root.localId;
        if (scenario.key == 'auth') account = 'other-account-secret';
        if (scenario.key == 'auth_and_empty') {
          account = 'other-account-secret';
          well = '';
        }
        if (scenario.key == 'account_and_type') {
          store.alter = (c) => altered(
            c!,
            account: 'other-account-secret',
            type: CommandType.startAdhocSession,
          );
        }
        if (scenario.key == 'missing_well_and_type') {
          store.alter = (c) => altered(
            c!,
            withoutWell: true,
            type: CommandType.startAdhocSession,
          );
        }
        if (scenario.key == 'empty_well') well = ' ';
        if (scenario.key == 'empty_root') local = ' ';
        if (scenario.key == 'missing') local = 'missing-root-secret';
        if (scenario.key == 'account') {
          store.alter = (c) => altered(c!, account: 'other-account-secret');
        }
        if (scenario.key == 'well') {
          store.alter = (c) => altered(c!, well: 'other-well-secret');
        }
        if (scenario.key == 'payload') {
          store.alter = (c) => altered(
            c!,
            payload: {...c.payload, 'p_well_id': 'payload-well-secret'},
          );
        }
        if (scenario.key == 'historical') {
          store.alter = (c) => altered(c!, type: CommandType.startAdhocSession);
        }
        final before = (await store.allCommands('account'))
            .map(dispatchCommandFingerprint)
            .toList();
        final recordsBefore = Map<String, String>.from(
          (await store.readStartRecovery('account')).records,
        );
        store.writes = 0;
        final recovery = OperationalStartRecovery(
          store: store,
          transport: transport,
          repository: repository,
          currentAccountId: () => account,
        );
        final result = await recovery.check(
          accountId: 'account',
          wellId: well,
          sessionLocalId: local,
        );
        expect(
          result.state,
          scenario.key == 'valid'
              ? OperationalStartRecoveryState.serverSessionFound
              : OperationalStartRecoveryState.unresolvedManualReview,
        );
        expect(transport.reads, scenario.key == 'valid' ? 1 : 0);
        expect(repository.reads, scenario.key == 'valid' ? 1 : 0);
        expect(transport.requests, isEmpty);
        expect(store.writes, 0);
        expect(
          (await store.readStartRecovery('account')).records,
          recordsBefore,
        );
        expect(
          (await store.allCommands('account')).map(dispatchCommandFingerprint),
          before,
        );
        expect(await store.mappings('account'), isEmpty);
        await store.close();
      },
    );
  }
}

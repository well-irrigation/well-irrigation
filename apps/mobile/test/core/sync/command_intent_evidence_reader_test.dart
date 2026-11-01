import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_evidence_reader.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';

import 'command_intent_policy_test.dart' as f;

class ExactReadStore extends InMemoryOutboxStore {
  final reads = <String>[];
  bool failRead = false;

  @override
  Future<String?> readBundle(String accountId, String key) {
    reads.add('$accountId:$key');
    if (failRead) throw StateError('unavailable');
    return super.readBundle(accountId, key);
  }

  @override
  Future<List<CommandEnvelope>> allCommands(String accountId) =>
      throw StateError('global scan forbidden');

  @override
  Future<List<String>> readLocalValuesByPrefix(
    String accountId,
    String prefix,
  ) => throw StateError('prefix scan forbidden');
}

void main() {
  late ExactReadStore store;
  late CommandIntentEvidenceReader reader;
  setUp(() async {
    store = ExactReadStore();
    await store.initialize();
    reader = CommandIntentEvidenceReader(store);
  });
  tearDown(() => store.close());

  Future<void> saveManual() async {
    final command = f.command(
      context: {'manual_start': true, 'booking_id': 'booking'},
    );
    await store.insertBundle(
      accountId: 'account',
      key: f.manualStartKey,
      value: jsonEncode({
        'start_local_id': 'local',
        'start_command_id': 'command',
      }),
      commands: [command],
    );
  }

  test(
    'reader fetches exact stored command and original manual bundle',
    () async {
      await saveManual();
      final result = await reader.read(
        accountId: 'account',
        wellId: 'well',
        localId: 'local',
      );
      expect(result.origin, CommandIntentOrigin.provenHuman);
      expect(store.reads, ['account:${f.manualStartKey}']);
    },
  );

  test('wrong account or well cannot borrow a valid original bundle', () async {
    await saveManual();
    for (final (account, well) in [('other', 'well'), ('account', 'other')]) {
      expect(
        (await reader.read(
          accountId: account,
          wellId: well,
          localId: 'local',
        )).origin,
        CommandIntentOrigin.unresolved,
      );
    }
    expect(store.reads, isEmpty);
  });

  test('missing original evidence leaves marker unresolved', () async {
    await store.insert(
      f.command(context: {'manual_start': true, 'booking_id': 'booking'}),
    );
    expect(
      (await reader.read(
        accountId: 'account',
        wellId: 'well',
        localId: 'local',
      )).origin,
      CommandIntentOrigin.unresolved,
    );
  });

  test(
    'second command for same booking cannot inherit original human evidence',
    () async {
      await saveManual();
      await store.insert(
        f.command(
          localId: 'copy',
          commandId: 'copy-command',
          context: {'manual_start': true, 'booking_id': 'booking'},
        ),
      );
      expect(
        (await reader.read(
          accountId: 'account',
          wellId: 'well',
          localId: 'copy',
        )).origin,
        CommandIntentOrigin.unresolved,
      );
      expect(
        (await reader.read(
          accountId: 'account',
          wellId: 'well',
          localId: 'local',
        )).origin,
        CommandIntentOrigin.provenHuman,
      );
    },
  );

  test(
    'old free command stays unresolved and receives no retroactive evidence',
    () async {
      final old = f.command(
        type: CommandType.startIrrigationSession,
        payload: {'p_well_id': 'well'},
      );
      await store.insert(old);
      expect(
        (await reader.read(
          accountId: 'account',
          wellId: 'well',
          localId: 'local',
        )).origin,
        CommandIntentOrigin.unresolved,
      );
      expect(
        await store.readBundle('account', 'command.human_intent.v1.local'),
        isNull,
      );
    },
  );

  test(
    'completion record naming another command never proves source',
    () async {
      await store.insert(
        f.command(type: CommandType.completeIrrigationSession),
      );
      await store.insertBundle(
        accountId: 'account',
        key: f.completionKey,
        value: jsonEncode({
          ...f.completion('manual_stop'),
          'completion_command_id': 'other',
        }),
        commands: [],
      );
      expect(
        (await reader.read(
          accountId: 'account',
          wellId: 'well',
          localId: 'local',
        )).origin,
        CommandIntentOrigin.unresolved,
      );
    },
  );

  test(
    'failed evidence read leaves stored command and status unchanged',
    () async {
      await saveManual();
      final before = await store.commandByLocalId('account', 'local');
      store.failRead = true;
      final result = await reader.read(
        accountId: 'account',
        wellId: 'well',
        localId: 'local',
      );
      expect(result.origin, CommandIntentOrigin.unresolved);
      expect(result.reason, 'intent_evidence_unavailable');
      expect(await store.commandByLocalId('account', 'local'), same(before));
    },
  );

  test('repeated reads neither create commands nor alter bundles', () async {
    await saveManual();
    final before = await store.readBundle('account', f.manualStartKey);
    for (var i = 0; i < 3; i++) {
      expect(
        (await reader.read(
          accountId: 'account',
          wellId: 'well',
          localId: 'local',
        )).origin,
        CommandIntentOrigin.provenHuman,
      );
    }
    expect(await store.readBundle('account', f.manualStartKey), before);
    expect(await store.commandsForWell('account', 'well'), hasLength(1));
  });
}

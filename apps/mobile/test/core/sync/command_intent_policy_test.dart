import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';


final at = DateTime.utc(2026, 10, 1, 10);
const completionKey = 'session.completion.v1.well.root';
const successorKey = 'session.successor.v1.well.root';
const manualStartKey = 'booking.manual_start.v1.well.booking';

Map<String, Object?> manualStartRecords() => {
  manualStartKey: jsonEncode({
    'start_local_id': 'local',
    'start_command_id': 'command',
  }),
};

CommandEnvelope command({
  CommandType type = CommandType.startBookingSession,
  Map<String, Object?>? payload,
  Map<String, Object?> context = const {},
  CommandStatus status = CommandStatus.pending,
  List<String>? prerequisites,
  String localId = 'local',
  String commandId = 'command',
}) => CommandEnvelope(
  localId: localId,
  commandId: commandId,
  accountId: 'account',
  wellId: 'well',
  sequence: 2,
  occurredAt: at,
  createdLocalAt: at,
  type: type,
  aggregateLocalId: type == CommandType.completeIrrigationSession
      ? 'root'
      : null,
  payload:
      payload ??
      (type == CommandType.completeIrrigationSession
          ? {
              r'p_session_id': {r'$ref': 'root', r'$kind': 'session'},
            }
          : {'p_booking_id': 'booking'}),
  localContext: context,
  status: status,
  prerequisites:
      prerequisites ??
      (context.containsKey('previous_session_local_id')
          ? ['complete-local']
          : const []),
);

Map<String, Object?> completion(String trigger) => {
  'version': 1,
  'provenance': 'session_completion_effect',
  'account_id': 'account',
  'well_id': 'well',
  'session_local_id': 'root',
  'completion_local_id': 'local',
  'completion_command_id': 'command',
  'completed_at': at.toIso8601String(),
  'trigger': trigger,
  'due_at': at.toIso8601String(),
};

Map<String, Object?> successorRecords() => {
  completionKey: {
    ...completion('auto_due'),
    'completion_local_id': 'complete-local',
    'completion_command_id': 'complete-command',
  },
  successorKey: {
    'version': 1,
    'provenance': 'session_successor_effect',
    'account_id': 'account',
    'well_id': 'well',
    'session_local_id': 'root',
    'completion_command_id': 'complete-command',
    'effect_id': 'effect',
    'state': 'starting',
    'start_local_id': 'local',
    'start_command_id': 'command',
    'candidate': {'booking_id': 'booking'},
  },
};

void main() {
  test(
    'manual booking marker requires the persisted original command identity',
    () {
      final valid = command(
        context: {'manual_start': true, 'booking_id': 'booking'},
      );
      final result = classifyCommandIntent(
        valid,
        records: manualStartRecords(),
      );
      expect(result.origin, CommandIntentOrigin.provenHuman);
      expect(result.evidence, isNotEmpty);
      expect(
        classifyCommandIntent(
          command(context: {'manual_start': true, 'booking_id': 'other'}),
        ).origin,
        CommandIntentOrigin.unresolved,
      );
    },
  );

  test('copying a manual marker to another command for the same booking is not proof', () {
    final original = command(
      context: {'manual_start': true, 'booking_id': 'booking'},
    );
    for (final (localId, commandId) in [
      ('other-local', 'other-command'),
      ('local', 'other-command'),
      ('other-local', 'command'),
    ]) {
      final copied = command(
        localId: localId,
        commandId: commandId,
        context: Map.of(original.localContext),
      );
      expect(
        classifyCommandIntent(copied).origin,
        CommandIntentOrigin.unresolved,
      );
      expect(
        classifyCommandIntent(copied, records: manualStartRecords()).origin,
        CommandIntentOrigin.unresolved,
      );
    }
    expect(
      classifyCommandIntent(original, records: manualStartRecords()).origin,
      CommandIntentOrigin.provenHuman,
    );
  });

  test(
    'legacy marker alone or incomplete original identity remains unresolved',
    () {
      final c = command(
        context: {'manual_start': true, 'booking_id': 'booking'},
      );
      for (final records in <Map<String, Object?>>[
        {},
        {manualStartKey: null},
        {manualStartKey: '{'},
        {
          manualStartKey: {'start_local_id': 'local'},
        },
        {
          manualStartKey: {'start_command_id': 'command'},
        },
        {
          manualStartKey: {'start_local_id': 'local', 'start_command_id': ''},
        },
        {
          'booking.manual_start.v1.other.booking':
              manualStartRecords()[manualStartKey],
        },
        {
          'booking.manual_start.v1.well.other':
              manualStartRecords()[manualStartKey],
        },
      ]) {
        expect(
          classifyCommandIntent(c, records: records).origin,
          CommandIntentOrigin.unresolved,
        );
      }
    },
  );

  test(
    'extra records cannot manufacture human intent without the original marker',
    () {
      for (final context in <Map<String, Object?>>[
        {},
        {'manual_start': false, 'booking_id': 'booking'},
      ]) {
        expect(
          classifyCommandIntent(
            command(context: context),
            records: manualStartRecords(),
          ).origin,
          CommandIntentOrigin.unresolved,
        );
      }
      final c = command(
        context: {'manual_start': true, 'booking_id': 'booking'},
      );
      expect(
        classifyCommandIntent(
          c,
          records: {
            ...manualStartRecords(),
            'unrelated': {'manual_start': true},
          },
        ).origin,
        CommandIntentOrigin.unresolved,
      );
    },
  );

  for (final (trigger, expected) in [
    ('manual_stop', CommandIntentOrigin.provenHuman),
    ('auto_due', CommandIntentOrigin.provenAutomatic),
    ('late_recovery', CommandIntentOrigin.provenAutomatic),
    ('existing_completion', CommandIntentOrigin.unresolved),
  ]) {
    test('completion reads linked effect trigger $trigger', () {
      final result = classifyCommandIntent(
        command(type: CommandType.completeIrrigationSession),
        records: {completionKey: jsonEncode(completion(trigger))},
      );
      expect(result.origin, expected);
      expect(result.reason, isNotEmpty);
    });
  }

  test(
    'successor needs command, candidate, completion and prerequisite linkage',
    () {
      final c = command(
        context: {'booking_id': 'booking', 'previous_session_local_id': 'root'},
      );
      expect(
        classifyCommandIntent(c, records: successorRecords()).origin,
        CommandIntentOrigin.provenAutomatic,
      );
      for (final field in [
        'start_local_id',
        'start_command_id',
        'completion_command_id',
        'account_id',
        'well_id',
        'session_local_id',
      ]) {
        final records = successorRecords();
        records[successorKey] = {
          ...records[successorKey] as Map,
          field: 'other',
        };
        expect(
          classifyCommandIntent(c, records: records).origin,
          CommandIntentOrigin.unresolved,
          reason: field,
        );
      }
      final records = successorRecords()..remove(completionKey);
      expect(
        classifyCommandIntent(c, records: records).origin,
        CommandIntentOrigin.unresolved,
      );
    },
  );

  test(
    'opposing linked human and automatic evidence never wins by priority',
    () {
      final c = command(
        context: {
          'manual_start': true,
          'booking_id': 'booking',
          'previous_session_local_id': 'root',
        },
      );
      final result = classifyCommandIntent(
        c,
        records: {...successorRecords(), ...manualStartRecords()},
      );
      expect(result.origin, CommandIntentOrigin.unresolved);
      expect(result.reason, 'conflicting_evidence');
    },
  );

  test(
    'unbound external evidence cannot be silently ignored beside human marker',
    () {
      final c = command(
        context: {'manual_start': true, 'booking_id': 'booking'},
      );
      expect(
        classifyCommandIntent(
          c,
          records: {'session.completion.v1.other.root': completion('auto_due')},
        ).origin,
        CommandIntentOrigin.unresolved,
      );
    },
  );

  test('successor candidate and prerequisite cannot refer to other work', () {
    final c = command(
      context: {'booking_id': 'booking', 'previous_session_local_id': 'root'},
    );
    final records = successorRecords();
    records[successorKey] = {
      ...records[successorKey] as Map,
      'candidate': {'booking_id': 'other'},
    };
    expect(
      classifyCommandIntent(c, records: records).origin,
      CommandIntentOrigin.unresolved,
    );
    expect(
      classifyCommandIntent(
        command(context: c.localContext, prerequisites: ['unrelated']),
        records: successorRecords(),
      ).origin,
      CommandIntentOrigin.unresolved,
    );
  });

  for (final field in [
    'completion_local_id',
    'completion_command_id',
    'account_id',
    'well_id',
    'session_local_id',
    'completed_at',
    'version',
    'provenance',
  ]) {
    test('completion rejects mismatched evidence $field', () {
      final record = completion('manual_stop')..[field] = 'wrong';
      expect(
        classifyCommandIntent(
          command(type: CommandType.completeIrrigationSession),
          records: {completionKey: record},
        ).origin,
        CommandIntentOrigin.unresolved,
      );
    });
  }

  test(
    'manual start does not grant human authority to later auto completion',
    () {
      expect(
        classifyCommandIntent(
          command(context: {'manual_start': true, 'booking_id': 'booking'}),
          records: manualStartRecords(),
        ).origin,
        CommandIntentOrigin.provenHuman,
      );
      expect(
        classifyCommandIntent(
          command(type: CommandType.completeIrrigationSession),
          records: {completionKey: completion('auto_due')},
        ).origin,
        CommandIntentOrigin.provenAutomatic,
      );
    },
  );

  for (final status in CommandStatus.values) {
    test(
      'delivery status $status cannot prove origin or change linked evidence',
      () {
        expect(
          classifyCommandIntent(command(status: status)).origin,
          CommandIntentOrigin.unresolved,
        );
        expect(
          classifyCommandIntent(
            command(
              status: status,
              context: {'manual_start': true, 'booking_id': 'booking'},
            ),
            records: manualStartRecords(),
          ).origin,
          CommandIntentOrigin.provenHuman,
        );
      },
    );
  }

  test('absence, false marker, malformed marker and unrelated trigger are not proof', () {
    for (final context in <Map<String, Object?>>[
      {},
      {'manual_start': false},
      {'manual_start': 'true', 'booking_id': 'booking'},
      {'trigger': 'manual_stop'},
      {'manual_start': true},
    ]) {
      expect(
        classifyCommandIntent(command(context: context)).origin,
        CommandIntentOrigin.unresolved,
      );
    }
  });

  test('a supported type and a successful response are not human evidence', () {
    final c = command().copyWith(
      status: CommandStatus.confirmed,
      serverResponse: {'status': 'accepted', 'session_id': 'server'},
    );
    expect(classifyCommandIntent(c).origin, CommandIntentOrigin.unresolved);
    expect(
      classifyCommandIntent(
        command(
          type: CommandType.startAdhocSession,
          payload: {'p_well_id': 'well'},
          context: {'manual_start': true},
        ),
      ).origin,
      CommandIntentOrigin.unresolved,
    );
  });

  test('false manual marker does not negate a linked automatic successor', () {
    final c = command(
      context: {
        'manual_start': false,
        'booking_id': 'booking',
        'previous_session_local_id': 'root',
      },
    );
    expect(
      classifyCommandIntent(c, records: successorRecords()).origin,
      CommandIntentOrigin.provenAutomatic,
    );
  });

  test(
    'completion cannot borrow evidence for a different session reference',
    () {
      for (final session in <Object>[
        'server-session',
        {r'$ref': 'other', r'$kind': 'session'},
        {r'$ref': 'root', r'$kind': 'farm'},
      ]) {
        expect(
          classifyCommandIntent(
            command(
              type: CommandType.completeIrrigationSession,
              payload: {'p_session_id': session},
            ),
            records: {completionKey: completion('manual_stop')},
          ).origin,
          CommandIntentOrigin.unresolved,
        );
      }
    },
  );

  test(
    'invalid JSON, missing fields and future record versions fail closed',
    () {
      for (final record in <Object?>[
        '{',
        '[]',
        null,
        {},
        {...completion('manual_stop'), 'version': 2},
        {...completion('manual_stop')}..remove('completion_command_id'),
      ]) {
        expect(
          classifyCommandIntent(
            command(type: CommandType.completeIrrigationSession),
            records: {completionKey: record},
          ).origin,
          CommandIntentOrigin.unresolved,
        );
      }
    },
  );

  test('repeat classification is deterministic and mutates no input', () {
    final c = command(
      context: {'booking_id': 'booking', 'previous_session_local_id': 'root'},
    );
    final records = successorRecords();
    final before = jsonEncode([c.payload, c.localContext, records]);
    final a = classifyCommandIntent(c, records: records);
    final b = classifyCommandIntent(c, records: records);
    expect(a.origin, b.origin);
    expect(a.reason, b.reason);
    expect(a.evidence, b.evidence);
    expect(jsonEncode([c.payload, c.localContext, records]), before);
    expect(c.localId, 'local');
    expect(c.commandId, 'command');
    expect(() => a.evidence.add('fake'), throwsUnsupportedError);
  });

  test(
    'new free-session evidence binds action, scope, both ids and session',
    () {
      final c = command(
        type: CommandType.startIrrigationSession,
        payload: {'p_well_id': 'well'},
      );
      const key = 'command.human_intent.v1.local';
      final proof = <String, Object?>{
        'version': 1,
        'provenance': 'human_command_intent',
        'account_id': 'account',
        'well_id': 'well',
        'command_local_id': 'local',
        'command_id': 'command',
        'command_type': 'startIrrigationSession',
        'action': 'start_session',
        'session_local_id': 'local',
        'occurred_at': at.toIso8601String(),
      };
      expect(
        classifyCommandIntent(c, records: {key: proof}).origin,
        CommandIntentOrigin.provenHuman,
      );
      for (final field in proof.keys) {
        expect(
          classifyCommandIntent(
            c,
            records: {
              key: {...proof, field: 'wrong'},
            },
          ).origin,
          CommandIntentOrigin.unresolved,
          reason: field,
        );
      }
      expect(classifyCommandIntent(c).origin, CommandIntentOrigin.unresolved);
    },
  );

  test(
    'human direct stop evidence cannot override automatic completion effect',
    () {
      final c = command(type: CommandType.completeIrrigationSession);
      final proof = {
        'version': 1,
        'provenance': 'human_command_intent',
        'account_id': 'account',
        'well_id': 'well',
        'command_local_id': 'local',
        'command_id': 'command',
        'command_type': 'completeIrrigationSession',
        'action': 'complete_session',
        'session_local_id': 'root',
        'occurred_at': at.toIso8601String(),
      };
      expect(
        classifyCommandIntent(
          c,
          records: {'command.human_intent.v1.local': proof},
        ).origin,
        CommandIntentOrigin.provenHuman,
      );
      expect(
        classifyCommandIntent(
          c,
          records: {
            'command.human_intent.v1.local': proof,
            completionKey: completion('auto_due'),
          },
        ).origin,
        CommandIntentOrigin.unresolved,
      );
    },
  );
}

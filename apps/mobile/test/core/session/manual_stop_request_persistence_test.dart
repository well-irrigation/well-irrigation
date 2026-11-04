import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/manual_stop_request_store.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_intent_policy.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

final startedAt = DateTime.utc(2026, 10, 20, 8);
final requestedAt = DateTime.utc(2026, 10, 20, 9, 7, 13);

CommandEnvelope start({
  String account = 'account',
  String local = 'session',
  CommandType type = CommandType.startIrrigationSession,
}) => CommandEnvelope(
  accountId: account,
  wellId: 'well',
  localId: local,
  commandId: '$account-$local-command',
  type: type,
  sequence: 1,
  occurredAt: startedAt,
  createdLocalAt: startedAt,
  payload: switch (type) {
    CommandType.startBookingSession => {'p_booking_id': 'booking'},
    CommandType.executePendingBookingStart => {'p_chain_id': 'chain'},
    _ => {'p_well_id': 'well'},
  },
);

Future<ManualStopRequest> record(
  ManualStopRequestStore requests, {
  String account = 'account',
  String well = 'well',
  String session = 'session',
  DateTime? at,
}) => requests.recordHumanStopRequest(
  accountId: account,
  wellId: well,
  sessionLocalId: session,
  requestedAt: at ?? requestedAt,
);

Future<ManualStopRequest?> read(ManualStopRequestStore requests) => requests
    .read(accountId: 'account', wellId: 'well', sessionLocalId: 'session');

// Fail at the transaction's final currency check, AFTER its metadata insert.
// The production SQLite transaction must roll back the entire request.
class RollbackStore extends SqliteOutboxStore {
  RollbackStore(String path)
    : super(databasePath: path, sqfliteFactory: databaseFactoryFfi);

  @override
  Future<String> insertBundle({
    required String accountId,
    required String key,
    required String value,
    required List<CommandEnvelope> commands,
    Map<String, String> localValues = const {},
    bool Function()? isCurrent,
  }) {
    var checks = 0;
    return super.insertBundle(
      accountId: accountId,
      key: key,
      value: value,
      commands: commands,
      localValues: localValues,
      isCurrent: () => ++checks == 1,
    );
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite' : 'memory', () {
      late OutboxStore store;
      late ManualStopRequestStore requests;
      Directory? dir;

      setUp(() async {
        if (sqlite) {
          dir = await Directory.systemTemp.createTemp('q137-stop-');
          store = SqliteOutboxStore(
            databasePath: '${dir!.path}/db',
            sqfliteFactory: databaseFactoryFfi,
            singleInstance: false,
          );
        } else {
          store = InMemoryOutboxStore();
        }
        await store.initialize();
        await store.insert(start());
        requests = ManualStopRequestStore(store);
      });

      tearDown(() async {
        await store.close();
        if (dir != null) await dir!.delete(recursive: true);
      });

      test('records only the explicit human event, not a completion', () async {
        final before = (await store.allCommands('account')).single;
        final result = await record(requests);
        expect(result.accountId, 'account');
        expect(result.wellId, 'well');
        expect(result.sessionLocalId, 'session');
        expect(result.sessionCommandId, 'account-session-command');
        expect(result.serverSessionId, isNull);
        expect(result.requestedAt, requestedAt);
        expect(result.requestId, matches(RegExp(r'^[0-9a-f-]{36}$')));
        expect(result.toJson()['source'], 'operator_stop_action');
        expect(result.toJson()['state'], 'recorded');
        expect(result.toJson()['version'], 1);
        expect(result.toJson(), isNot(contains('completed_at')));
        final after = (await store.allCommands('account')).single;
        expect(after.commandId, before.commandId);
        expect(after.payload, before.payload);
        expect(after.status, before.status);
        expect(await store.mappings('account'), isEmpty);
      });

      test(
        'first committed request wins even if second event time is earlier',
        () async {
          final first = await record(requests);
          final second = await record(
            requests,
            at: requestedAt.subtract(const Duration(minutes: 3)),
          );
          final recreated = ManualStopRequestStore(store);
          final third = await record(
            recreated,
            at: requestedAt.add(const Duration(hours: 1)),
          );
          expect(second.toJson(), first.toJson());
          expect(third.toJson(), first.toJson());
          expect((await read(recreated))!.toJson(), first.toJson());
          expect(await store.allCommands('account'), hasLength(1));
        },
      );

      test('server reference comes only from exact session mapping', () async {
        await store.putMapping(
          'account',
          IdMapping(
            localId: 'session',
            kind: EntityKind.session,
            serverId: 'server-session',
            resolvedAt: requestedAt,
          ),
        );
        final first = await record(requests);
        expect(first.serverSessionId, 'server-session');
        expect((await read(requests))!.toJson(), first.toJson());
      });

      test(
        'another account mapping is not used as a server session reference',
        () async {
          await store.putMapping(
            'other-account',
            IdMapping(
              localId: 'session',
              kind: EntityKind.session,
              serverId: 'foreign-session',
              resolvedAt: requestedAt,
            ),
          );
          expect((await record(requests)).serverSessionId, isNull);
        },
      );

      test(
        'event time is normalized to UTC without using a planned end',
        () async {
          final localEvent = DateTime.parse('2026-10-20T12:07:13+03:00');
          expect(
            (await record(requests, at: localEvent)).requestedAt,
            requestedAt,
          );
        },
      );

      test(
        'mapping arriving later does not rewrite the first request',
        () async {
          final first = await record(requests);
          await store.putMapping(
            'account',
            IdMapping(
              localId: 'session',
              kind: EntityKind.session,
              serverId: 'later-session',
              resolvedAt: requestedAt,
            ),
          );
          expect((await record(requests)).toJson(), first.toJson());
          expect((await read(requests))!.serverSessionId, isNull);
        },
      );

      for (final type in [
        CommandType.startAdhocSession,
        CommandType.startBookingSession,
        CommandType.executePendingBookingStart,
      ]) {
        test(
          'accepts the stored session-producing identity ${type.name}',
          () async {
            await store.insert(start(local: 'other', type: type));
            expect(
              (await record(requests, session: 'other')).sessionLocalId,
              'other',
            );
          },
        );
      }

      test(
        'rejects invalid, missing, or non-session identity without writes',
        () async {
          for (final session in ['', ' ', 'missing']) {
            await expectLater(
              record(requests, session: session),
              throwsA(anyOf(isArgumentError, isStateError)),
            );
          }
          await store.insert(
            start(local: 'not-session', type: CommandType.createFarm),
          );
          await expectLater(
            record(requests, session: 'not-session'),
            throwsStateError,
          );
          expect(await read(requests), isNull);
          expect(
            await store.readLocalValuesByPrefix(
              'account',
              'session.manual_stop.request.',
            ),
            isEmpty,
          );
        },
      );

      test('account and well cannot borrow another session identity', () async {
        final first = await record(requests);
        await expectLater(
          record(requests, account: 'other-account'),
          throwsStateError,
        );
        await expectLater(
          record(requests, well: 'other-well'),
          throwsStateError,
        );
        expect(
          await requests.read(
            accountId: 'other-account',
            wellId: 'well',
            sessionLocalId: 'session',
          ),
          isNull,
        );
        expect(
          await requests.read(
            accountId: 'account',
            wellId: 'other-well',
            sessionLocalId: 'session',
          ),
          isNull,
        );
        expect((await read(requests))!.toJson(), first.toJson());
      });

      test('separate session requests do not merge', () async {
        await store.insert(start(local: 'second'));
        final first = await record(requests);
        final second = await record(requests, session: 'second');
        expect(second.requestId, isNot(first.requestId));
        expect(second.sessionLocalId, 'second');
      });

      test(
        'malformed stored request is rejected without replacement',
        () async {
          final key = ManualStopRequestStore.keyFor('well', 'session');
          await store.insertBundle(
            accountId: 'account',
            key: key,
            value: '{broken',
            commands: [],
          );
          await expectLater(read(requests), throwsFormatException);
          await expectLater(record(requests), throwsFormatException);
          expect(await store.readBundle('account', key), '{broken');
          expect(await store.allCommands('account'), hasLength(1));
        },
      );

      test('wrong or incomplete record identity is never accepted', () async {
        final valid = (await record(requests)).toJson();
        for (final field in [
          'version',
          'account_id',
          'well_id',
          'session_local_id',
          'session_command_id',
          'request_id',
          'requested_at',
          'source',
          'state',
        ]) {
          final altered = {...valid, field: field == 'version' ? 2 : 'wrong'};
          final key = ManualStopRequestStore.keyFor('well', 'session');
          await store.insertBundle(
            accountId: 'account',
            key: 'test-corruption-$field',
            value: '{}',
            commands: [],
            localValues: {key: jsonEncode(altered)},
          );
          await expectLater(read(requests), throwsFormatException);
          await expectLater(record(requests), throwsFormatException);
          expect(await store.readBundle('account', key), jsonEncode(altered));
        }
        final incomplete = {...valid}..remove('requested_at');
        await store.insertBundle(
          accountId: 'account',
          key: 'test-incomplete',
          value: '{}',
          commands: [],
          localValues: {
            ManualStopRequestStore.keyFor('well', 'session'): jsonEncode(
              incomplete,
            ),
          },
        );
        await expectLater(read(requests), throwsFormatException);
        final key = ManualStopRequestStore.keyFor('well', 'other');
        await store.insert(start(local: 'other'));
        await store.insertBundle(
          accountId: 'account',
          key: key,
          value: jsonEncode(valid),
          commands: [],
        );
        await expectLater(
          record(requests, session: 'other'),
          throwsFormatException,
        );
      });

      test(
        'malformed record fields and foreign server reference fail closed',
        () async {
          final valid = (await record(requests)).toJson();
          final key = ManualStopRequestStore.keyFor('well', 'session');
          final malformed = <Map<String, Object?>>[
            {...valid, 'version': 1.0},
            {...valid, 'requested_at': '2026-02-31T09:07:13.000Z'},
            {...valid, 'requested_at': '2026-10-20T09:07:13'},
            {...valid, 'server_session_id': 'unproven-server-session'},
            {...valid, 'request_id': null},
            {...valid}..remove('provenance'),
          ];
          for (var i = 0; i < malformed.length; i++) {
            final raw = jsonEncode(malformed[i]);
            await store.insertBundle(
              accountId: 'account',
              key: 'malformed-$i',
              value: '{}',
              commands: [],
              localValues: {key: raw},
            );
            await expectLater(read(requests), throwsFormatException);
            await expectLater(record(requests), throwsFormatException);
            expect(await store.readBundle('account', key), raw);
          }
        },
      );

      for (final scenario in [
        'pending',
        'late',
        'unknown',
        'confirmed',
        'incomplete',
        'conflicting',
      ]) {
        test(
          'preserves $scenario previous automatic completion and effect',
          () async {
            final completion = CommandEnvelope(
              accountId: 'account',
              wellId: 'well',
              localId: 'completion',
              commandId: 'completion-command',
              type: CommandType.completeIrrigationSession,
              sequence: 2,
              occurredAt: requestedAt.subtract(const Duration(minutes: 1)),
              createdLocalAt: requestedAt,
              aggregateLocalId: 'session',
              payload: {
                'p_session_id': {r'$ref': 'session', r'$kind': 'session'},
              },
              status: scenario == 'unknown'
                  ? CommandStatus.dispatching
                  : scenario == 'confirmed'
                  ? CommandStatus.confirmed
                  : CommandStatus.pending,
              retryCount: scenario == 'unknown' ? 1 : 0,
              lastAttemptAt: scenario == 'unknown' ? requestedAt : null,
              serverResponse: scenario == 'confirmed'
                  ? {'session_id': 'server-session', 'charge_minor': 8123}
                  : null,
            );
            final effectKey = 'session.completion.v1.well.session';
            final effect = jsonEncode(
              scenario == 'incomplete'
                  ? {'trigger': 'auto_due'}
                  : {
                      'version': 1,
                      'provenance': 'session_completion_effect',
                      'account_id': 'account',
                      'well_id': 'well',
                      'session_local_id': 'session',
                      'completion_local_id': 'completion',
                      'completion_command_id': scenario == 'conflicting'
                          ? 'other-command'
                          : 'completion-command',
                      'completed_at': completion.occurredAt.toIso8601String(),
                      'trigger': scenario == 'late'
                          ? 'late_recovery'
                          : 'auto_due',
                    },
            );
            await store.insertBundle(
              accountId: 'account',
              key: effectKey,
              value: effect,
              commands: [completion],
            );
            final before = await store.commandByLocalId(
              'account',
              'completion',
            );
            final classifiedBefore = classifyCommandIntent(
              before!,
              records: {effectKey: jsonDecode(effect)},
            );
            await record(requests);
            await read(requests);
            final after = (await store.commandByLocalId(
              'account',
              'completion',
            ))!;
            expect(after.commandId, before.commandId);
            expect(after.localId, before.localId);
            expect(after.payload, before.payload);
            expect(after.occurredAt, before.occurredAt);
            expect(after.status, before.status);
            expect(after.retryCount, before.retryCount);
            expect(after.lastAttemptAt, before.lastAttemptAt);
            expect(after.serverResponse, before.serverResponse);
            expect(await store.readBundle('account', effectKey), effect);
            expect(
              classifyCommandIntent(
                after,
                records: {effectKey: jsonDecode(effect)},
              ).origin,
              classifiedBefore.origin,
            );
            if (scenario != 'incomplete' && scenario != 'conflicting') {
              expect(
                classifiedBefore.origin,
                CommandIntentOrigin.provenAutomatic,
              );
            }
            if (scenario == 'incomplete' || scenario == 'conflicting') {
              expect(classifiedBefore.origin, CommandIntentOrigin.unresolved);
            }
            expect(await store.allCommands('account'), hasLength(2));
            expect((await read(requests))!.toJson()['state'], 'recorded');
          },
        );
      }

      test('reading repeatedly has no storage side effects', () async {
        final request = await record(requests);
        final before = await store.readLocalValuesByPrefix('account', '');
        for (var i = 0; i < 3; i++) {
          expect((await read(requests))!.toJson(), request.toJson());
        }
        expect(await store.readLocalValuesByPrefix('account', ''), before);
        expect(await store.allCommands('account'), hasLength(1));
      });

      test(
        'unresolved dispatch attempt ownership survives a human stop request',
        () async {
          await store.markConfirmed(
            'account',
            'session',
            serverResponse: {'session_id': 'server-session'},
            attemptedAt: startedAt,
          );
          await store.putMapping(
            'account',
            IdMapping(
              localId: 'session',
              kind: EntityKind.session,
              serverId: 'server-session',
              resolvedAt: startedAt,
            ),
          );
          await store.insert(
            CommandEnvelope(
              accountId: 'account',
              wellId: 'well',
              localId: 'in-flight-completion',
              commandId: 'in-flight-command',
              aggregateLocalId: 'session',
              type: CommandType.completeIrrigationSession,
              sequence: 2,
              occurredAt: requestedAt,
              createdLocalAt: requestedAt,
              payload: {
                'p_session_id': {r'$ref': 'session', r'$kind': 'session'},
              },
            ),
          );
          final claimed = await (store as AtomicCommandDispatchStore)
              .claimDispatch(
                accountId: 'account',
                wellId: 'well',
                localId: 'in-flight-completion',
                commandId: 'in-flight-command',
                attemptedAt: requestedAt,
                policy: (_) => DispatchClaimDecision.allow,
              );
          expect(claimed.isClaimed, isTrue);
          final before = await store.readLocalValuesByPrefix(
            'account',
            'command.dispatch.',
          );
          await record(requests);
          await read(requests);
          expect(
            await store.readLocalValuesByPrefix('account', 'command.dispatch.'),
            before,
          );
          final row = (await store.commandByLocalId(
            'account',
            'in-flight-completion',
          ))!;
          expect(row.status, CommandStatus.dispatching);
          expect(row.serverResponse, isNull);
          expect(row.commandId, 'in-flight-command');
          expect(await store.allCommands('account'), hasLength(2));
        },
      );
    });
  }

  test(
    'SQLite reopen preserves first request without a callback or network',
    () async {
      final dir = await Directory.systemTemp.createTemp('q137-stop-reopen-');
      final path = '${dir.path}/db';
      SqliteOutboxStore open() => SqliteOutboxStore(
        databasePath: path,
        sqfliteFactory: databaseFactoryFfi,
        singleInstance: false,
      );
      var store = open();
      try {
        await store.initialize();
        await store.insert(start());
        final first = await record(ManualStopRequestStore(store));
        await store.close();
        store = open();
        await store.initialize();
        final requests = ManualStopRequestStore(store);
        expect((await read(requests))!.toJson(), first.toJson());
        expect(
          (await record(
            requests,
            at: requestedAt.add(const Duration(days: 1)),
          )).toJson(),
          first.toJson(),
        );
        expect(await store.allCommands('account'), hasLength(1));
      } finally {
        await store.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'SQLite write failing after insert rolls back the whole request',
    () async {
      final dir = await Directory.systemTemp.createTemp('q137-stop-rollback-');
      final store = RollbackStore('${dir.path}/db');
      try {
        await store.initialize();
        await store.insert(start());
        final requests = ManualStopRequestStore(store);
        await expectLater(record(requests), throwsStateError);
        expect(await read(requests), isNull);
        expect(await store.allCommands('account'), hasLength(1));
        expect(
          await store.readLocalValuesByPrefix(
            'account',
            'session.manual_stop.request.',
          ),
          isEmpty,
        );
      } finally {
        await store.close();
        await dir.delete(recursive: true);
      }
    },
  );
}

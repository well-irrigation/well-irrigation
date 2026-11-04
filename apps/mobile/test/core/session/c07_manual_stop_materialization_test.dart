import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/manual_stop_request_store.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

final _startAt = DateTime.utc(2026, 11, 1, 8);
final _stopAt = DateTime.utc(2026, 11, 1, 9, 1, 2, 3, 456);
CommandEnvelope _start({
  String account = 'a',
  String well = 'w',
  String local = 'root',
}) => CommandEnvelope(
  accountId: account,
  wellId: well,
  localId: local,
  commandId: 'start-$local',
  type: CommandType.startIrrigationSession,
  sequence: 1,
  occurredAt: _startAt,
  createdLocalAt: _startAt,
  payload: {'p_well_id': well},
);
CommandEnvelope _event(
  String local, {
  CommandType type = CommandType.completeIrrigationSession,
  DateTime? at,
  Object? target,
  String root = 'root',
}) => CommandEnvelope(
  accountId: 'a',
  wellId: 'w',
  localId: local,
  commandId: 'command-$local',
  type: type,
  aggregateLocalId: root,
  sequence: 2,
  occurredAt: at ?? _stopAt.subtract(const Duration(minutes: 1)),
  createdLocalAt: _startAt,
  payload: {
    'p_session_id': target ?? const {r'$ref': 'root', r'$kind': 'session'},
  },
  localContext: const {'preserved_origin': 'existing'},
);

class _Fixture {
  _Fixture(this.sqlite);
  final bool sqlite;
  Directory? dir;
  late OutboxStore store;
  ManualStopRequestStore get requests => ManualStopRequestStore(store);
  SqliteOutboxStore get sql => store as SqliteOutboxStore;
  Future<void> open() async {
    if (sqlite) {
      dir ??= await Directory.systemTemp.createTemp('c07c_materialization_');
      store = SqliteOutboxStore(
        databasePath: '${dir!.path}/db',
        sqfliteFactory: databaseFactoryFfi,
        singleInstance: false,
      );
    } else {
      store = InMemoryOutboxStore();
    }
    await store.initialize();
  }

  Future<void> reopen() async {
    await store.close();
    await open();
  }

  Future<void> close() async {
    await store.close();
    await dir?.delete(recursive: true);
  }

  Future<ManualStopRequest> record({DateTime? at}) =>
      requests.recordHumanStopRequest(
        accountId: 'a',
        wellId: 'w',
        sessionLocalId: 'root',
        requestedAt: at ?? _stopAt,
      );
  Future<ManualStopRequest?> read() =>
      requests.read(accountId: 'a', wellId: 'w', sessionLocalId: 'root');
  Future<Map<String, Object?>> snapshot() async => {
    'commands': [
      for (final c in await store.allCommands('a'))
        dispatchCommandFingerprint(c),
    ],
    // Sequence reservation happens in prepare, outside materialization, as in SOURCE.
    'session_records': await store.readLocalValuesByPrefix('a', 'session.'),
    'mappings': [
      for (final m in await store.mappings('a'))
        [m.localId, m.kind, m.serverId, m.resolvedAt],
    ],
    if (sqlite)
      'notifications': await sql.notificationEvents.db.query(
        'notification_events',
      ),
  };
}

void main() {
  setUpAll(sqfliteFfiInit);
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite durable stop' : 'memory durable stop', () {
      late _Fixture f;
      setUp(() async {
        f = _Fixture(sqlite);
        await f.open();
        await f.store.insert(_start());
      });
      tearDown(() => f.close());
      test('first request wins; materialization uses original human time and evidence once', () async {
        final first = await f.record();
        final second = await f.record(
          at: _stopAt.subtract(const Duration(minutes: 10)),
        );
        expect(second.toJson(), first.toJson());
        expect((await f.read())!.toJson(), first.toJson());
        final result = await f.requests.materializeRecordedRequest(first);
        expect(result.type, CommandType.completeIrrigationSession);
        expect(result.commandId, isNot(first.requestId));
        expect(result.localId, isNot(first.requestId));
        expect(result.occurredAt, first.requestedAt);
        expect(result.aggregateLocalId, 'root');
        expect(result.payload['p_session_id'], const {
          r'$ref': 'root',
          r'$kind': 'session',
        });
        final effect = jsonDecode(
          (await f.store.readBundle('a', 'session.completion.v1.w.root'))!,
        ) as Map;
        expect(effect['trigger'], 'manual_stop');
        expect(effect['request_id'], first.requestId);
        expect(effect['completion_command_id'], result.commandId);
        expect(effect['completed_at'], first.requestedAt.toIso8601String());
        expect(
          await f.store.readBundle(
            'a',
            manualStopMaterializationKey('w', 'root'),
          ),
          first.requestId,
        );
        final saved = await f.snapshot();
        expect(
          (await f.requests.materializeRecordedRequest(first)).commandId,
          result.commandId,
        );
        expect(await f.snapshot(), saved);
        expect(await f.store.allCommands('a'), hasLength(2));
      });
      test('one compatible completion is reused with identity, time and origin intact', () async {
        final existing = await f.store.insert(_event('existing'));
        final before = dispatchCommandFingerprint(existing);
        final request = await f.record();
        final result = await f.requests.materializeRecordedRequest(request);
        expect(dispatchCommandFingerprint(result), before);
        expect(
          dispatchCommandFingerprint(
            await f.store.commandByLocalId('a', 'existing'),
          ),
          before,
        );
        expect(await f.store.allCommands('a'), hasLength(2));
        expect(
          await f.store.readBundle('a', 'session.completion.v1.w.root'),
          isNull,
        );
        expect(
          await f.store.readBundle(
            'a',
            manualStopMaterializationKey('w', 'root'),
          ),
          request.requestId,
        );
      });
      test('exact mapped literal completion is reused', () async {
        await f.store.putMapping(
          'a',
          IdMapping(
            localId: 'root',
            kind: EntityKind.session,
            serverId: 'server',
            resolvedAt: _startAt,
          ),
        );
        final existing = await f.store.insert(
          _event('mapped', target: 'server'),
        );
        final request = await f.record();
        expect(request.serverSessionId, 'server');
        expect(
          (await f.requests.materializeRecordedRequest(request)).commandId,
          existing.commandId,
        );
        expect(await f.store.allCommands('a'), hasLength(2));
      });
      test('incompatible completion is not relabeled or replaced', () async {
        await f.store.insert(_event('foreign', target: 'other-session'));
        final request = await f.record();
        final before = await f.snapshot();
        await expectLater(
          f.requests.materializeRecordedRequest(request),
          throwsStateError,
        );
        expect(await f.snapshot(), before);
      });
      test(
        'multiple completions require review without arbitrary selection',
        () async {
          await f.store.insert(_event('one'));
          await f.store.insert(_event('two'));
          final request = await f.record();
          final before = await f.snapshot();
          await expectLater(
            f.requests.materializeRecordedRequest(request),
            throwsStateError,
          );
          expect(await f.snapshot(), before);
        },
      );
      for (final conflict in ['before-start', 'later-event']) {
        test('timing conflict $conflict creates no completion', () async {
          if (conflict == 'later-event') {
            await f.store.insert(
              _event(
                'pause',
                type: CommandType.pauseIrrigationSession,
                at: _stopAt.add(const Duration(seconds: 1)),
              ),
            );
          }
          final request = await f.record(
            at: conflict == 'before-start'
                ? _startAt.subtract(const Duration(seconds: 1))
                : _stopAt,
          );
          final before = await f.snapshot();
          await expectLater(
            f.requests.materializeRecordedRequest(request),
            throwsStateError,
          );
          expect(await f.snapshot(), before);
        });
      }
      for (final scope in [
        ('other', 'w', 'root'),
        ('a', 'other', 'root'),
        ('a', 'w', 'other'),
      ]) {
        test(
          'unproven request scope $scope cannot create completion',
          () async {
            final before = await f.snapshot();
            await expectLater(
              f.requests.recordHumanStopRequest(
                accountId: scope.$1,
                wellId: scope.$2,
                sessionLocalId: scope.$3,
                requestedAt: _stopAt,
              ),
              throwsStateError,
            );
            expect(await f.snapshot(), before);
          },
        );
      }
      for (final scope in [
        ('other', 'w', 'root'),
        ('a', 'other', 'root'),
        ('a', 'w', 'other'),
      ]) {
        test(
          'stored foreign request $scope cannot materialize in this store',
          () async {
            final foreign = InMemoryOutboxStore();
            await foreign.initialize();
            try {
              await foreign.insert(
                _start(account: scope.$1, well: scope.$2, local: scope.$3),
              );
              final request = await ManualStopRequestStore(foreign)
                  .recordHumanStopRequest(
                    accountId: scope.$1,
                    wellId: scope.$2,
                    sessionLocalId: scope.$3,
                    requestedAt: _stopAt,
                  );
              final before = await f.snapshot();
              await expectLater(
                f.requests.materializeRecordedRequest(request),
                throwsStateError,
              );
              expect(await f.snapshot(), before);
            } finally {
              await foreign.close();
            }
          },
        );
      }
      test(
        'request removed or changed after read cannot materialize',
        () async {
          final request = await f.record();
          await f.store.insertBundle(
            accountId: 'a',
            key: 'test-only-tamper',
            value: 'test',
            commands: const [],
            localValues: {
              ManualStopRequestStore.keyFor('w', 'root'): jsonEncode({
                ...request.toJson(),
                'request_id': 'replacement',
              }),
            },
          );
          final before = await f.snapshot();
          await expectLater(
            f.requests.materializeRecordedRequest(request),
            throwsStateError,
          );
          expect(await f.snapshot(), before);
        },
      );
      test(
        'original mapped identity cannot be replaced by a newer mapping',
        () async {
          await f.store.putMapping(
            'a',
            IdMapping(
              localId: 'root',
              kind: EntityKind.session,
              serverId: 'original',
              resolvedAt: _startAt,
            ),
          );
          final request = await f.record();
          await f.store.putMapping(
            'a',
            IdMapping(
              localId: 'root',
              kind: EntityKind.session,
              serverId: 'other',
              resolvedAt: _startAt,
            ),
          );
          final before = await f.snapshot();
          await expectLater(
            f.requests.materializeRecordedRequest(request),
            throwsStateError,
          );
          expect(await f.snapshot(), before);
        },
      );
      test(
        'missing required saved server mapping does not guess a session',
        () async {
          await f.store.putMapping(
            'a',
            IdMapping(
              localId: 'root',
              kind: EntityKind.session,
              serverId: 'original',
              resolvedAt: _startAt,
            ),
          );
          final request = await f.record();
          if (sqlite) {
            await f.sql.notificationEvents.db.delete(
              'id_mappings',
              where: 'account_id=?',
              whereArgs: ['a'],
            );
          } else {
            await f.store.close();
            f.store = InMemoryOutboxStore();
            await f.store.initialize();
            await f.store.insert(_start());
            await f.store.insertBundle(
              accountId: 'a',
              key: ManualStopRequestStore.keyFor('w', 'root'),
              value: jsonEncode(request.toJson()),
              commands: const [],
            );
          }
          final before = await f.snapshot();
          await expectLater(
            f.requests.materializeRecordedRequest(request),
            throwsStateError,
          );
          expect(await f.snapshot(), before);
        },
      );
      test(
        'racing materializations return one durable completion identity',
        () async {
          final request = await f.record();
          final results = await Future.wait(
            List.generate(
              5,
              (_) => f.requests.materializeRecordedRequest(request),
            ),
          );
          expect(results.map((c) => c.commandId).toSet(), hasLength(1));
          expect(await f.store.allCommands('a'), hasLength(2));
        },
      );
      if (sqlite) {
        test('death after request persistence: reopen recovers original request and materializes once', () async {
          final request = await f.record();
          final saved = request.toJson();
          expect(await f.store.allCommands('a'), hasLength(1));
          await f.reopen();
          final recovered = (await f.read())!;
          expect(recovered.toJson(), saved);
          final result = await f.requests.materializeRecordedRequest(recovered);
          final state = await f.snapshot();
          await f.reopen();
          expect(await f.snapshot(), state);
          expect((await f.read())!.toJson(), saved);
          expect(
            (await f.requests.materializeRecordedRequest((await f.read())!))
                .commandId,
            result.commandId,
          );
          expect(await f.store.allCommands('a'), hasLength(2));
        });
        for (final stage in ['effect', 'link']) {
          test(
            '$stage failure rolls back command, evidence and link through reopen',
            () async {
              final request = await f.record();
              final key = stage == 'effect'
                  ? 'session.completion.v1.w.root'
                  : manualStopMaterializationKey('w', 'root');
              await f.sql.notificationEvents.db.execute(
                "create trigger stop_fault before insert on sync_meta when new.key='$key' begin select raise(abort,'injected'); end",
              );
              final before = await f.snapshot();
              await expectLater(
                f.requests.materializeRecordedRequest(request),
                throwsA(isA<DatabaseException>()),
              );
              expect(await f.snapshot(), before);
              await f.reopen();
              expect(await f.snapshot(), before);
              expect(
                await f.store.readBundle('a', 'session.completion.v1.w.root'),
                isNull,
              );
              expect(
                await f.store.readBundle(
                  'a',
                  manualStopMaterializationKey('w', 'root'),
                ),
                isNull,
              );
              await f.sql.notificationEvents.db.execute(
                'drop trigger stop_fault',
              );
              final result = await f.requests.materializeRecordedRequest(
                (await f.read())!,
              );
              expect(await f.store.allCommands('a'), hasLength(2));
              expect(
                await f.store.readBundle(
                  'a',
                  manualStopMaterializationKey('w', 'root'),
                ),
                request.requestId,
              );
              final effect = jsonDecode(
                (await f.store.readBundle(
                  'a',
                  'session.completion.v1.w.root',
                ))!,
              ) as Map;
              expect(effect['completion_command_id'], result.commandId);
              final saved = await f.snapshot();
              await f.reopen();
              expect(await f.snapshot(), saved);
            },
          );
        }
      }
    });
  }
}

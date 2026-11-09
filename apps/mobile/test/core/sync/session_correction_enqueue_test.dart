import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_id_generator.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

final _at = DateTime.utc(2026, 11, 9, 9);
final _start = DateTime.parse('2026-11-08T05:30:00+03:00');
final _end = DateTime.parse('2026-11-08T07:45:00+03:00');
const _reason = 'تصحيح وقت التشغيل الفعلي';
const _payload = <String, Object?>{
  'p_session_id': 'server-session-1',
  'p_base_revision': 3,
  'p_reason': _reason,
  'p_desired_started_at': '2026-11-08T02:30:00.000Z',
  'p_desired_ended_at': '2026-11-08T04:45:00.000Z',
};

class _Ids implements IdGenerator {
  _Ids([this.prefix = '']);
  final String prefix;
  int calls = 0;
  @override
  String newId() {
    final n = calls++;
    return '$prefix${n.isEven ? 'local-correction' : 'correction-command'}-${n ~/ 2 + 1}';
  }
}

// وقت الطلب من الساعة المحقونة فقط، لا وسيط عام يمكن أن يعيد بناء الهوية.
Future<CommandEnvelope> _enqueue(
  OutboxRepository repository, {
  String account = 'account-a',
  String well = 'well-a',
  String session = 'server-session-1',
  int revision = 3,
  String reason = '  $_reason  ',
  DateTime? start,
  DateTime? end,
}) => repository.enqueueSessionCorrection(
  accountId: account,
  wellId: well,
  sessionId: session,
  baseRevision: revision,
  reason: reason,
  desiredStartedAt: start ?? _start,
  desiredEndedAt: end ?? _end,
);

void _sameIntent(CommandEnvelope actual, CommandEnvelope original) {
  expect(actual.localId, original.localId);
  expect(actual.commandId, original.commandId);
  expect(actual.occurredAt, original.occurredAt);
  expect(actual.payload, original.payload);
}

SqliteOutboxStore _disk(String path) => SqliteOutboxStore(
  databasePath: path,
  sqfliteFactory: databaseFactoryFfi,
  singleInstance: false,
);

void main() {
  sqfliteFfiInit();
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite durable enqueue' : 'InMemory durable enqueue', () {
      late OutboxStore store;
      late OutboxRepository repository;
      late DateTime now;
      Directory? directory;
      setUp(() async {
        now = _at;
        if (sqlite) {
          directory = await Directory.systemTemp.createTemp(
            'correction-enqueue-',
          );
          store = _disk('${directory!.path}/outbox.db');
        } else {
          store = InMemoryOutboxStore();
        }
        repository = OutboxRepository(
          store: store,
          idGenerator: _Ids(),
          clock: () => now,
        );
        await repository.initialize();
      });
      tearDown(() async {
        await store.close();
        await directory?.delete(recursive: true);
        directory = null;
      });

      test(
        'canonical snapshot is durable before return and owns RPC identity',
        () async {
          final command = await _enqueue(repository);
          final saved = (await store.allCommands('account-a')).single;
          _sameIntent(saved, command);
          expect(saved.type, CommandType.correctIrrigationSession);
          expect(saved.accountId, 'account-a');
          expect(saved.wellId, 'well-a');
          expect(saved.status, CommandStatus.pending);
          expect(saved.localId, 'local-correction-1');
          expect(saved.commandId, 'correction-command-1');
          expect(saved.occurredAt, _at);
          expect(saved.occurredAt.isUtc, isTrue);
          expect(saved.aggregateLocalId, isNull);
          expect(saved.prerequisites, isEmpty);
          expect(saved.references, isEmpty);
          expect(
            saved.payload,
            _payload,
          ); // Exact keys exclude actor/financial authority.
          final arguments = buildRpcArguments(
            type: saved.type,
            commandId: saved.commandId,
            occurredAt: saved.occurredAt,
            resolvedPayload: saved.payload,
          );
          expect(arguments, {
            ..._payload,
            'p_command_id': saved.commandId,
            'p_requested_at': '2026-11-09T09:00:00.000Z',
          });
          now = now.add(const Duration(hours: 1));
          expect(
            buildRpcArguments(
              type: saved.type,
              commandId: saved.commandId,
              occurredAt: saved.occurredAt,
              resolvedPayload: saved.payload,
            ),
            arguments,
          );
        },
      );

      final invalid = <String, Map<String, Object>>{
        'empty account': {'account': ''},
        'empty well': {'well': ''},
        'empty session': {'session': ''},
        'negative revision': {'revision': -1},
        'revision exceeds largest correctable base': {
          'revision': 9223372036854775807,
        },
        'blank reason': {'reason': '   '},
        'equal timestamps': {'start': _end},
        'reversed timestamps': {'start': _end.add(const Duration(minutes: 1))},
        'future end': {'end': _at.add(const Duration(seconds: 1))},
      };
      for (final entry in invalid.entries) {
        test('rejects ${entry.key} without a durable row', () async {
          final v = entry.value;
          await expectLater(
            _enqueue(
              repository,
              account: v['account'] as String? ?? 'account-a',
              well: v['well'] as String? ?? 'well-a',
              session: v['session'] as String? ?? 'server-session-1',
              revision: v['revision'] as int? ?? 3,
              reason: v['reason'] as String? ?? _reason,
              start: v['start'] as DateTime?,
              end: v['end'] as DateTime?,
            ),
            throwsArgumentError,
          );
          expect(await store.allCommands('account-a'), isEmpty);
          expect(await store.allCommands(''), isEmpty);
        });
      }

      test('largest correctable base revision remains valid', () async {
        final c = await _enqueue(repository, revision: 9223372036854775806);
        expect(c.payload['p_base_revision'], 9223372036854775806);
        expect(await store.allCommands('account-a'), hasLength(1));
      });

      for (final status in [
        CommandStatus.pending,
        CommandStatus.dispatching,
        CommandStatus.review,
      ]) {
        test(
          'exact canonical duplicate reuses $status intent despite a later clock',
          () async {
            final original = await _enqueue(repository, reason: _reason);
            if (status != CommandStatus.pending) {
              expect(
                await store.claim(
                  'account-a',
                  original.localId,
                  attemptedAt: now,
                ),
                isTrue,
              );
            }
            if (status == CommandStatus.review) {
              await store.markNeedsReview(
                'account-a',
                original.localId,
                error: 'fixture_review',
                attemptedAt: now,
              );
            }
            now = now.add(const Duration(minutes: 1));
            final duplicate = await _enqueue(repository);
            _sameIntent(duplicate, original);
            expect(duplicate.status, status);
            expect(await store.allCommands('account-a'), hasLength(1));
          },
        );

        for (final difference in ['end', 'reason', 'revision', 'well']) {
          test(
            '$status rejects differing $difference without overwrite',
            () async {
              final original = await _enqueue(repository);
              if (status != CommandStatus.pending) {
                expect(
                  await store.claim(
                    'account-a',
                    original.localId,
                    attemptedAt: now,
                  ),
                  isTrue,
                );
              }
              if (status == CommandStatus.review) {
                await store.markNeedsReview(
                  'account-a',
                  original.localId,
                  error: 'fixture_review',
                  attemptedAt: now,
                );
              }
              await expectLater(
                _enqueue(
                  repository,
                  end: difference == 'end'
                      ? _end.add(const Duration(minutes: 1))
                      : null,
                  reason: difference == 'reason' ? 'سبب مختلف' : _reason,
                  revision: difference == 'revision' ? 4 : 3,
                  well: difference == 'well' ? 'well-b' : 'well-a',
                ),
                throwsA(isA<SessionCorrectionConflict>()),
              );
              final saved = (await store.allCommands('account-a')).single;
              _sameIntent(saved, original);
              expect(saved.status, status);
            },
          );
        }
      }

      test(
        'confirmed history permits a new revision with new identity',
        () async {
          final original = await _enqueue(repository);
          expect(
            await store.claim('account-a', original.localId, attemptedAt: now),
            isTrue,
          );
          await store.markConfirmed(
            'account-a',
            original.localId,
            serverResponse: const {'fixture': 'accepted'},
            attemptedAt: now,
          );
          final historical = (await store.allCommands('account-a')).single;
          now = now.add(const Duration(minutes: 1));
          final next = await _enqueue(repository, revision: 4);
          expect(next.localId, isNot(original.localId));
          expect(next.commandId, isNot(original.commandId));
          expect(next.occurredAt, now);
          expect(next.occurredAt, isNot(original.occurredAt));
          expect(await store.allCommands('account-a'), hasLength(2));
          final saved = (await store.commandByLocalId(
            'account-a',
            original.localId,
          ))!;
          _sameIntent(saved, historical);
          expect(saved.status, historical.status);
          expect(saved.serverResponse, historical.serverResponse);
          expect(saved.lastAttemptAt, historical.lastAttemptAt);
        },
      );

      test('different sessions and accounts remain independent', () async {
        final a = await _enqueue(repository);
        final b = await _enqueue(repository, session: 'server-session-2');
        final c = await _enqueue(repository, account: 'account-b');
        expect({a.localId, b.localId, c.localId}, hasLength(3));
        expect(await store.allCommands('account-a'), hasLength(2));
        expect(
          (await store.allCommands('account-b')).single.accountId,
          'account-b',
        );
        expect(c.commandId, isNot(a.commandId));
      });

      test('store itself enforces duplicate and conflict atomically', () async {
        Future<CommandEnvelope> candidate(Map<String, Object?> payload) =>
            repository.prepare(
              accountId: 'account-a',
              wellId: 'well-a',
              type: CommandType.correctIrrigationSession,
              occurredAt: now,
              payload: payload,
            );
        final a = await candidate(_payload);
        final b = await candidate(_payload);
        final results = await Future.wait<CommandEnvelope>([
          store.insertSessionCorrection(a),
          store.insertSessionCorrection(b),
        ]);
        _sameIntent(results[1], results[0]);
        await expectLater(
          store.insertSessionCorrection(
            await candidate({..._payload, 'p_reason': 'سبب مختلف'}),
          ),
          throwsA(isA<SessionCorrectionConflict>()),
        );
        expect(await store.allCommands('account-a'), hasLength(1));
      });
    });
  }

  // R6C-5A-T2B: فساد هوية جلسة محفوظة لا يعني أنها جلسة أخرى.
  for (final sqlite in [false, true]) {
    group(sqlite ? 'SQLite persisted corruption' : 'InMemory corruption', () {
      late OutboxStore store;
      Directory? directory;
      setUp(() async {
        if (sqlite) {
          directory = await Directory.systemTemp.createTemp(
            'correction-corrupt-identity-',
          );
          store = _disk('${directory!.path}/outbox.db');
        } else {
          store = InMemoryOutboxStore();
        }
        await store.initialize();
      });
      tearDown(() async {
        await store.close();
        await directory?.delete(recursive: true);
        directory = null;
      });

      Future<CommandEnvelope> seed(
        Object? session, {
        CommandStatus status = CommandStatus.pending,
        String account = 'account-a',
      }) async {
        final corrupt = CommandEnvelope(
          localId: 'legacy-correction-local',
          commandId: 'legacy-correction-command',
          accountId: account,
          wellId: 'well-a',
          sequence: await store.nextSequence(account),
          type: CommandType.correctIrrigationSession,
          occurredAt: _at,
          createdLocalAt: _at,
          status: status,
          payload: {..._payload, 'p_session_id': session},
        );
        // مسار الحفظ العام يحاكي بيانات قديمة، دون تخفيف الحارس المتخصص.
        await store.insert(corrupt);
        if (sqlite) {
          await store.close();
          store = _disk('${directory!.path}/outbox.db');
          await store.initialize();
        }
        final persisted = (await store.allCommands(account)).single;
        _sameIntent(persisted, corrupt);
        expect(persisted.status, status);
        expect(persisted.payload['p_session_id'], session);
        return persisted;
      }

      Future<CommandEnvelope> candidate() => OutboxRepository(
        store: store,
        idGenerator: _Ids('new-'),
        clock: () => _at,
      ).prepare(
        accountId: 'account-a',
        wellId: 'well-a',
        type: CommandType.correctIrrigationSession,
        occurredAt: _at,
        payload: _payload,
      );

      final corruptIdentities = <String, Object?>{
        'null': null,
        'non-string': 123,
        'empty': '',
        'whitespace': '   ',
      };
      for (final identity in corruptIdentities.entries) {
        for (final status in [
          CommandStatus.pending,
          CommandStatus.dispatching,
          CommandStatus.review,
        ]) {
          test('${identity.key} $status blocks with original corrupt evidence', () async {
            final existing = await seed(identity.value, status: status);
            final valid = await candidate();
            await expectLater(
              store.insertSessionCorrection(valid),
              throwsA(
                isA<SessionCorrectionConflict>()
                    .having((e) => e.existing.localId, 'existing.localId', existing.localId)
                    .having((e) => e.existing.commandId, 'existing.commandId', existing.commandId)
                    .having((e) => e.existing.accountId, 'existing.accountId', existing.accountId)
                    .having((e) => e.existing.occurredAt, 'existing.occurredAt', existing.occurredAt)
                    .having((e) => e.existing.payload, 'existing.payload', existing.payload)
                    .having((e) => e.existing.status, 'existing.status', status),
              ),
            );
            final rows = await store.allCommands('account-a');
            expect(rows, hasLength(1));
            _sameIntent(rows.single, existing);
            expect(rows.single.status, status);
            expect(await store.commandByLocalId('account-a', valid.localId), isNull);
          });
        }

        test('${identity.key} confirmed historical corruption does not block', () async {
          final existing = await seed(identity.value, status: CommandStatus.confirmed);
          final valid = await candidate();
          final inserted = await store.insertSessionCorrection(valid);
          _sameIntent(inserted, valid);
          expect(inserted.status, CommandStatus.pending);
          expect(await store.allCommands('account-a'), hasLength(2));
          final historical = (await store.commandByLocalId('account-a', existing.localId))!;
          _sameIntent(historical, existing);
          expect(historical.status, CommandStatus.confirmed);
        });

        test('${identity.key} unresolved corruption in another account is isolated', () async {
          final existing = await seed(identity.value, account: 'account-b');
          final valid = await candidate();
          _sameIntent(await store.insertSessionCorrection(valid), valid);
          _sameIntent((await store.allCommands('account-a')).single, valid);
          _sameIntent((await store.allCommands('account-b')).single, existing);
        });
      }

      test('valid unrelated unresolved session remains independent', () async {
        final existing = await seed('server-session-2');
        final valid = await candidate();
        _sameIntent(await store.insertSessionCorrection(valid), valid);
        expect(await store.allCommands('account-a'), hasLength(2));
        _sameIntent((await store.commandByLocalId('account-a', existing.localId))!, existing);
      });
    });
  }

  group('SQLite independent connections', () {
    late Directory directory;
    late SqliteOutboxStore first;
    late SqliteOutboxStore second;
    late OutboxRepository a;
    late OutboxRepository b;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'correction-enqueue-race-',
      );
      first = _disk('${directory.path}/outbox.db');
      second = _disk('${directory.path}/outbox.db');
      await first.initialize();
      await second.initialize();
      a = OutboxRepository(
        store: first,
        idGenerator: _Ids('a-'),
        clock: () => _at,
      );
      b = OutboxRepository(
        store: second,
        idGenerator: _Ids('b-'),
        clock: () => _at.add(const Duration(minutes: 1)),
      );
    });
    tearDown(() async {
      await first.close();
      await second.close();
      await directory.delete(recursive: true);
    });

    test('restart returns the original durable intent', () async {
      final original = await _enqueue(a);
      await first.close();
      first = _disk('${directory.path}/outbox.db');
      await first.initialize();
      final reopened = OutboxRepository(
        store: first,
        idGenerator: _Ids('reopened-'),
        clock: () => _at.add(const Duration(hours: 1)),
      );
      _sameIntent(await _enqueue(reopened), original);
      _sameIntent((await first.allCommands('account-a')).single, original);
    });

    Future<CommandEnvelope> candidate(
      OutboxRepository repository, {
      bool different = false,
    }) => repository.prepare(
      accountId: 'account-a',
      wellId: 'well-a',
      type: CommandType.correctIrrigationSession,
      occurredAt: _at,
      payload: {..._payload, if (different) 'p_reason': 'سبب مختلف'},
    );

    test(
      'exact duplicate race at store boundary has one durable winner',
      () async {
        final one = await candidate(a);
        final two = await candidate(b);
        final results = await Future.wait<CommandEnvelope>([
          first.insertSessionCorrection(one),
          second.insertSessionCorrection(two),
        ]);
        _sameIntent(results[0], results[1]);
        _sameIntent((await first.allCommands('account-a')).single, results[0]);
        expect(await second.allCommands('account-a'), hasLength(1));
      },
    );

    test(
      'differing intent race yields one winner and one typed conflict',
      () async {
        final one = await candidate(a);
        final two = await candidate(b, different: true);
        Future<Object> outcome(Future<CommandEnvelope> work) async {
          try {
            return await work;
          } catch (error) {
            return error;
          }
        }

        final results = await Future.wait([
          outcome(first.insertSessionCorrection(one)),
          outcome(second.insertSessionCorrection(two)),
        ]);
        expect(results.whereType<CommandEnvelope>(), hasLength(1));
        expect(results.whereType<SessionCorrectionConflict>(), hasLength(1));
        final winner = results.whereType<CommandEnvelope>().single;
        _sameIntent((await first.allCommands('account-a')).single, winner);
        expect(await second.allCommands('account-a'), hasLength(1));
      },
    );
  });
}

import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/manual_stop_request_store.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

CommandEnvelope root() => CommandEnvelope(
  accountId: 'account',
  wellId: 'well',
  localId: 'session',
  commandId: 'start-command',
  type: CommandType.startBookingSession,
  sequence: 1,
  occurredAt: DateTime.utc(2026, 10, 20, 8),
  createdLocalAt: DateTime.utc(2026, 10, 20, 8),
  payload: {'p_booking_id': 'booking'},
);

// Both independent worker connections reach the persistence boundary before
// either may enter insertBundle's REAL SQLite transaction.
class GatedStore extends SqliteOutboxStore {
  GatedStore(String path, this.ready)
    : super(
        databasePath: path,
        sqfliteFactory: databaseFactoryFfi,
        singleInstance: false,
      );
  final SendPort ready;
  bool gated = false;

  @override
  Future<String> insertBundle({
    required String accountId,
    required String key,
    required String value,
    required List<CommandEnvelope> commands,
    Map<String, String> localValues = const {},
    bool Function()? isCurrent,
  }) async {
    if (!gated) {
      gated = true;
      final gate = ReceivePort();
      try {
        ready.send(gate.sendPort);
        await gate.first;
      } finally {
        gate.close();
      }
    }
    return super.insertBundle(
      accountId: accountId,
      key: key,
      value: value,
      commands: commands,
      localValues: localValues,
      isCurrent: isCurrent,
    );
  }
}

Future<Map<String, Object?>> worker(
  String path,
  SendPort ready,
  int minute,
) async {
  sqfliteFfiInit();
  final store = GatedStore(path, ready);
  try {
    await store.initialize();
    final request = await ManualStopRequestStore(store).recordHumanStopRequest(
      accountId: 'account',
      wellId: 'well',
      sessionLocalId: 'session',
      requestedAt: DateTime.utc(2026, 10, 20, 9, minute),
    );
    return request.toJson();
  } finally {
    await store.close();
  }
}

Future<Map<String, Object?>> isolated(
  String path,
  SendPort ready,
  int minute,
) => Isolate.run(() => worker(path, ready, minute));

void main() {
  setUpAll(sqfliteFfiInit);

  test('concurrent memory calls persist one whole first request', () async {
    final store = InMemoryOutboxStore();
    await store.initialize();
    await store.insert(root());
    try {
      final requests = ManualStopRequestStore(store);
      final results = await Future.wait(
        List.generate(
          12,
          (minute) => requests.recordHumanStopRequest(
            accountId: 'account',
            wellId: 'well',
            sessionLocalId: 'session',
            requestedAt: DateTime.utc(2026, 10, 20, 9, minute),
          ),
        ),
      );
      for (final result in results) {
        expect(result.toJson(), results.first.toJson());
      }
      expect(await store.allCommands('account'), hasLength(1));
      expect(
        await store.readLocalValuesByPrefix(
          'account',
          'session.manual_stop.request.',
        ),
        hasLength(1),
      );
    } finally {
      await store.close();
    }
  });

  test('independent SQLite worker connections preserve the winning ID and event time', () async {
    final dir = await Directory.systemTemp.createTemp('q137-stop-race-');
    final path = '${dir.path}/db';
    final setup = SqliteOutboxStore(
      databasePath: path,
      sqfliteFactory: databaseFactoryFfi,
      singleInstance: false,
    );
    await setup.initialize();
    await setup.insert(root());
    await setup.close();
    final ready = ReceivePort();
    try {
      final first = isolated(path, ready.sendPort, 1);
      final second = isolated(path, ready.sendPort, 2);
      final gates = await ready.take(2).toList();
      for (final gate in gates) {
        (gate as SendPort).send('go');
      }
      final results = await Future.wait([first, second]);
      expect(results[0], results[1]);
      expect(
        results[0]['requested_at'],
        anyOf('2026-10-20T09:01:00.000Z', '2026-10-20T09:02:00.000Z'),
      );
      final reopened = SqliteOutboxStore(
        databasePath: path,
        sqfliteFactory: databaseFactoryFfi,
        singleInstance: false,
      );
      try {
        await reopened.initialize();
        final saved = await ManualStopRequestStore(
          reopened,
        ).read(accountId: 'account', wellId: 'well', sessionLocalId: 'session');
        expect(saved!.toJson(), results[0]);
        expect(await reopened.allCommands('account'), hasLength(1));
        expect(
          await reopened.readLocalValuesByPrefix(
            'account',
            'session.manual_stop.request.',
          ),
          hasLength(1),
        );
      } finally {
        await reopened.close();
      }
    } finally {
      ready.close();
      await dir.delete(recursive: true);
    }
  });
}

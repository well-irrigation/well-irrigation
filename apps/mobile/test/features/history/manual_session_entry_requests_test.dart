import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_repository.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/features/history/manual_session_entry_requests.dart';

import '../../core/sync/manual_session_entry_test.dart' as f;

void main() {
  setUpAll(sqfliteFfiInit);
  test('history restores the exact pending request after disk reopen without creating another', () async {
    final dir = await Directory.systemTemp.createTemp(
      'manual_entry_ui_restore_',
    );
    final path = '${dir.path}/db';
    var store = SqliteOutboxStore(
      databasePath: path,
      sqfliteFactory: databaseFactoryFfi,
      singleInstance: false,
    );
    await store.initialize();
    final command = await f.enqueue(store, false);
    await store.close();
    store = SqliteOutboxStore(
      databasePath: path,
      sqfliteFactory: databaseFactoryFfi,
      singleInstance: false,
    );
    final repository = OutboxRepository(store: store);
    try {
      final restored = await savedManualSessionEntries(
        accountId: f.account,
        wellId: f.well,
        outbox: repository,
      );
      expect(restored.single.commandId, command.commandId);
      expect(restored.single.localId, command.localId);
      expect(restored.single.payload, command.payload);
      expect(
        await savedManualSessionEntries(
          accountId: f.farmer,
          wellId: f.well,
          outbox: repository,
        ),
        isEmpty,
      );
      expect(
        await savedManualSessionEntries(
          accountId: f.account,
          wellId: f.farm,
          outbox: repository,
        ),
        isEmpty,
      );
      expect(await repository.all(f.account), hasLength(1));
    } finally {
      await store.close();
      await dir.delete(recursive: true);
    }
  });
}

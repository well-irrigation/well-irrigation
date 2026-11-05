import 'dart:io';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import '../../support/accepted_completion_fixture.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  test('confirmed completion permits a later independent start', () async {
    final dir = await Directory.systemTemp.createTemp('r6ab-next-start-');
    final store = SqliteOutboxStore(databasePath:'${dir.path}/db',sqfliteFactory:databaseFactoryFfi,singleInstance:false);
    final c = OfflineSessionCoordinator(store:store);
    try {
      final first = await c.startSession(accountId:'a',wellId:'w',pumpId:'p',farmId:'f',farmerAccountId:'farmer',energySource:'solar',startedAt:DateTime.utc(2026));
      await store.markConfirmed('a',first.localId,serverResponse:{'id':'server'},attemptedAt:DateTime.utc(2026));
      await c.completeSession(accountId:'a',sessionLocalId:first.localId,completedAt:DateTime.utc(2026,1,1,1));
      await acceptTestCompletion(store:store,coordinator:c,accountId:'a',wellId:'w');
      final second = await c.startSession(accountId:'a',wellId:'w',pumpId:'p',farmId:'f',farmerAccountId:'farmer',energySource:'solar',startedAt:DateTime.utc(2026,1,1,2));
      expect(second.commandId,isNot(first.commandId));
      expect((await store.allCommands('a')).where((x)=>x.type==CommandType.startOperationalSession),hasLength(2));
      expect((await store.commandByLocalId('a',first.localId))!.status,CommandStatus.confirmed);
    } finally { c.dispose(); await store.close(); await dir.delete(recursive:true); }
  });
  test('different facts concurrent starts yield one winner and explicit conflict', () async {
    final dir = await Directory.systemTemp.createTemp('r6ab-different-');
    final a = SqliteOutboxStore(databasePath:'${dir.path}/db',sqfliteFactory:databaseFactoryFfi,singleInstance:false);
    final b = SqliteOutboxStore(databasePath:'${dir.path}/db',sqfliteFactory:databaseFactoryFfi,singleInstance:false);
    final ca = OfflineSessionCoordinator(store:a), cb = OfflineSessionCoordinator(store:b);
    try {
      await ca.initialize(); await cb.initialize();
      Future<Object> run(OfflineSessionCoordinator c,String pump) async {
        try { return await c.startSession(accountId:'a',wellId:'w',pumpId:pump,farmId:'f',farmerAccountId:'farmer',energySource:'solar'); }
        on OperationalStartConflict catch(e) { return e; }
      }
      final results = await Future.wait([run(ca,'p1'),run(cb,'p2')]);
      expect(results.whereType<OperationalStartConflict>(),hasLength(1));
      expect((await a.allCommands('a')).where((c)=>c.type==CommandType.startOperationalSession),hasLength(1));
      expect(await a.readLocalValuesByPrefix('a','command.human_intent.v1.'),hasLength(1));
    } finally { ca.dispose(); cb.dispose(); await a.close(); await b.close(); await dir.delete(recursive:true); }
  });
  test('two coordinators concurrently create at most one operational start', () async {
    final dir = await Directory.systemTemp.createTemp('r6ab-start-race-');
    final a = SqliteOutboxStore(databasePath:'${dir.path}/db',sqfliteFactory:databaseFactoryFfi,singleInstance:false);
    final b = SqliteOutboxStore(databasePath:'${dir.path}/db',sqfliteFactory:databaseFactoryFfi,singleInstance:false);
    final ca = OfflineSessionCoordinator(store:a);
    final cb = OfflineSessionCoordinator(store:b);
    try {
      await ca.initialize(); await cb.initialize();
      Future<Object?> start(OfflineSessionCoordinator c) async {
        try { return await c.startSession(accountId:'a',wellId:'w',pumpId:'p',farmId:'f',farmerAccountId:'farmer',energySource:'solar'); } on Object catch (e) { return e; }
      }
      final results = await Future.wait([start(ca),start(cb)]);
      expect(results.whereType<Exception>(),isEmpty,reason: '$results');
      expect(results.whereType<Error>(),isEmpty,reason: '$results');
      final rows = (await a.allCommands('a')).where((c)=>c.type==CommandType.startOperationalSession).toList();
      expect(rows,hasLength(1));
      final id = rows.single.commandId;
      final intents = await a.readLocalValuesByPrefix('a','command.human_intent.v1.');
      expect(intents,hasLength(1));
      await a.close(); await b.close();
      final reopened = SqliteOutboxStore(databasePath:'${dir.path}/db',sqfliteFactory:databaseFactoryFfi,singleInstance:false);
      try {
        await reopened.initialize();
        final saved = (await reopened.allCommands('a')).where((c)=>c.type==CommandType.startOperationalSession).toList();
        expect(saved,hasLength(1)); expect(saved.single.commandId,id);
      } finally { await reopened.close(); }

    } finally { ca.dispose(); cb.dispose(); await a.close(); await b.close(); await dir.delete(recursive:true); }
  });
}

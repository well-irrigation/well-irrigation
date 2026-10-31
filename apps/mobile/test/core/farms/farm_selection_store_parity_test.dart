import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/farms/farm_selection_projection.dart';
import 'package:well_irrigation_mobile/core/sync/command_envelope.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

final at=DateTime.utc(2027);
CommandEnvelope farm(String id,int sequence,{String account='a',String well='w',
  Object parent='f',String name='نفس الاسم',CommandStatus status=CommandStatus.pending}) => CommandEnvelope(
  localId:id,commandId:'command-$id',accountId:account,wellId:well,sequence:sequence,
  type:CommandType.createFarm,occurredAt:at,createdLocalAt:at,status:status,
  payload:{'p_well_id':well,'p_farmer_well_account_id':parent,'p_name':name});

void main(){
 setUpAll(sqfliteFfiInit);
 for(final sqlite in [false,true]){
  group(sqlite?'SQLite':'memory',(){
   late OutboxStore store;late FarmSelectionStore reader;Directory? dir;
   setUp(()async{
    if(sqlite){dir=await Directory.systemTemp.createTemp('farm_parity');store=SqliteOutboxStore(databasePath:'${dir!.path}/db',sqfliteFactory:databaseFactoryFfi,singleInstance:false);}
    else{store=InMemoryOutboxStore();}
    await store.initialize();reader=store as FarmSelectionStore;
   });
   tearDown(()async{await store.close();await dir?.delete(recursive:true);});
   test('account well parent and review scope precede selection',()async{
    for(final c in [farm('first',10),farm('second',20),farm('review',40,status:CommandStatus.review),
      farm('other-account',50,account:'b'),farm('other-well',60,well:'else'),farm('other-parent',70,parent:'else')]){await store.insert(c);}
    final rows=await reader.farmCommands(accountId:'a',wellId:'w',farmer:'f');
    expect(rows.map((r)=>r.command.localId),['second','first']);
    expect(rows.every((r)=>r.farmerId=='f'),isTrue);
   });
   test('local parent remains selectable and mapped parent resolves within account only',()async{
    final parent={r'$ref':'local-parent',r'$kind':'farmerWellAccount'};
    await store.insert(farm('local-child',1,parent:parent));
    expect(await reader.farmCommands(accountId:'a',wellId:'w',farmer:parent),hasLength(1));
    expect(await reader.farmCommands(accountId:'a',wellId:'w',farmer:'f'),isEmpty);
    await store.putMapping('b',IdMapping(localId:'local-parent',kind:EntityKind.farmerWellAccount,serverId:'f',resolvedAt:at));
    expect(await reader.farmCommands(accountId:'a',wellId:'w',farmer:'f'),isEmpty);
    await store.putMapping('a',IdMapping(localId:'local-parent',kind:EntityKind.farmerWellAccount,serverId:'f',resolvedAt:at));
    final rows=await reader.farmCommands(accountId:'a',wellId:'w',farmer:'f');
    expect(rows.single.command.localId,'local-child');expect(rows.single.farmerId,'f');
    expect(rows.single.command.payload['p_farmer_well_account_id'],parent);
   });
   test('mapping visible and canonical identity wins without collapsing unmapped equal names',()async{
    for(final c in [farm('mapped',1),farm('one',2),farm('two',3)]){await store.insert(c);}
    await store.putMapping('a',IdMapping(localId:'mapped',kind:EntityKind.farm,serverId:'canonical',resolvedAt:at));
    final rows=await reader.farmCommands(accountId:'a',wellId:'w',farmer:'f');
    expect(rows.singleWhere((r)=>r.command.localId=='mapped').serverId,'canonical');
    final projected=projectFarmSelection(canonical:const[Farm(id:'canonical',wellId:'w',name:'قانونية',farmerAccountId:'f')],local:rows,wellId:'w',farmerId:'f');
    expect(projected,hasLength(3));expect(projected.where((f)=>f.isPending),hasLength(2));
    expect(projected.singleWhere((f)=>f.id=='canonical').name,'قانونية');
    expect(projected.map((f)=>f.entityReference).toSet(),hasLength(3));
   });
   test('default 50 max 100 and descending unique sequence ordering',()async{
    for(var i=0;i<120;i++){await store.insert(farm('land-$i',i));}
    final normal=await reader.farmCommands(accountId:'a',wellId:'w',farmer:'f');
    expect(normal,hasLength(50));expect(normal.first.command.sequence,119);expect(normal.last.command.sequence,70);
    final max=await reader.farmCommands(accountId:'a',wellId:'w',farmer:'f',limit:100);
    expect(max,hasLength(100));expect(max.last.command.sequence,20);
    for(final limit in [0,101]){await expectLater(reader.farmCommands(accountId:'a',wellId:'w',farmer:'f',limit:limit),throwsArgumentError);}
   });
   test('query filters before limit and empty query is a valid page',()async{
    await store.insert(farm('match',1,name:'القطعة المطلوبة'));
    for(var i=2;i<70;i++){await store.insert(farm('noise-$i',i,name:'أخرى'));}
    expect((await reader.farmCommands(accountId:'a',wellId:'w',farmer:'f',query:'المطلوبة',limit:1)).single.command.localId,'match');
    expect(await reader.farmCommands(accountId:'a',wellId:'w',farmer:'f',query:'غير موجودة'),isEmpty);
    expect(await reader.farmCommands(accountId:'a',wellId:'w',farmer:'f',query:'',limit:1),hasLength(1));
   });
   test('selection reads do not mutate payload status mappings or sequence',()async{
    await store.insert(farm('original',1));
    final before=jsonEncode((await store.allCommands('a')).single.payload);
    expect(await store.nextSequence('a'),1);
    await reader.farmCommands(accountId:'a',wellId:'w',farmer:'f');
    final after=(await store.allCommands('a')).single;
    expect(jsonEncode(after.payload),before);expect(after.status,CommandStatus.pending);
    expect(await store.mappings('a'),isEmpty);expect(await store.nextSequence('a'),2);
   });
  });
 }
}

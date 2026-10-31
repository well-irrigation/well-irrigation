import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/entity_reference.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/widgets/smart_lookup_field.dart';
import 'package:well_irrigation_mobile/features/operations/operations_screen.dart';

import '../../support/identity_fixture.dart';

const farmer=FarmerAccount(id:'f',fullName:'المزارع',publicCode:'F');
const other=FarmerAccount(id:'other',fullName:'مزارع آخر',publicCode:'O');
class Ops extends OperationsRepository{
 final farmerCalls=<(String,String?)>[];
 final farmCalls=<(String,String,String)>[];
 Completer<List<FarmerAccount>>? farmerGate;
 Completer<List<Farm>>? farmGate;
 Object? farmerError,farmError;
 @override Future<List<Pump>> fetchPumps(String w)async=>[];
 @override Future<List<FarmerAccount>> fetchFarmers(String w,{String? query})async{
  farmerCalls.add((w,query));if(farmerError!=null)throw farmerError!;
  return farmerGate?.future??Future.value([farmer]);
 }
 @override Future<List<Farm>> searchFarms(String w,{required String farmerAccountId,String query='',int limit=50})async{
  farmCalls.add((w,farmerAccountId,query));if(farmError!=null)throw farmError!;
  return farmGate?.future??Future.value([]);
 }
 @override Future<FarmerSelectionStatus> fetchFarmerSelectionStatus({required String farmerAccountId})async=>
  FarmerSelectionStatus(farmerWellAccountId:farmerAccountId,wellId:'w',debtMinor:0,advanceMinor:0,farmerFuelBalanceMl:0);
}

void main(){
 late InMemoryOutboxStore store;late OfflineSessionCoordinator coordinator;late Ops repo;
 late StateSetter rebuild;late String well;
 setUp((){store=InMemoryOutboxStore();coordinator=OfflineSessionCoordinator(store:store);repo=Ops();well='w';});
 tearDown(()async{coordinator.dispose();await store.close();});
 Future<void> mount(WidgetTester tester,{String role='owner'})async{
  tester.view.physicalSize=const Size(1000,2200);tester.view.devicePixelRatio=1;
  addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home:StatefulBuilder(builder:(context,setState){
   rebuild=setState;
   return Directionality(textDirection:TextDirection.rtl,child:OperationsScreen(
    identity:testIdentity(accountId:'a',activeWell:testWell(id:well,roles:[role])),
    coordinator:coordinator,repository:repo));
  })));
  await tester.pumpAndSettle();
 }
 SmartLookupField<FarmerAccount> farmers(WidgetTester t)=>t.widget<SmartLookupField<FarmerAccount>>(find.byType(SmartLookupField<FarmerAccount>));
 SmartLookupField<Farm> farms(WidgetTester t)=>t.widget<SmartLookupField<Farm>>(find.byType(SmartLookupField<Farm>));
 Future<void> choose(WidgetTester t,FarmerAccount f)async{farmers(t).onChanged(f);await t.pumpAndSettle();}
 Future<void> unmount(WidgetTester t)async{await t.pumpWidget(const SizedBox.shrink());await t.pump();coordinator.dispose();await t.pump();}

 testWidgets('farmer and farm searches preserve scope and successful empty result',(tester)async{
  await mount(tester);
  expect((await farmers(tester).searchFunction('بحث')).single.id,'f');
  expect(repo.farmerCalls.last,('w','بحث'));
  await choose(tester,farmer);
  expect(await farms(tester).searchFunction('أرض'),isEmpty);
  expect(repo.farmCalls.last,('w','f','أرض'));
  expect(await store.allCommands('a'),isEmpty);
  await unmount(tester);
 });
 testWidgets('failed search exposes safe cause while retaining available local items',(tester)async{
  await mount(tester);await choose(tester,farmer);
  await coordinator.enqueueFarm(accountId:'a',wellId:'w',name:'المحفوظة',farmerReference:const ServerEntityReference('f'));
  repo.farmError=StateError('private transport detail');
  await expectLater(farms(tester).searchFunction(''),throwsA(isA<SmartLookupSearchFailure<Farm>>()
    .having((e)=>e.cause,'cause',same(repo.farmError))
    .having((e)=>e.availableLocalItems.single.name,'local','المحفوظة')));
  repo.farmerError=StateError('private farmer error');
  await expectLater(farmers(tester).searchFunction(''),throwsA(isA<SmartLookupSearchFailure<FarmerAccount>>()
    .having((e)=>e.cause,'cause',same(repo.farmerError))));
  expect(find.textContaining('private'),findsNothing);
  await unmount(tester);
 });
 for(final role in ['owner','operator']){
  testWidgets('$role farmer and farm dialogs save typed local choices without starting session',(tester)async{
   await mount(tester,role:role);
   final creating= farmers(tester).onAddNew!();await tester.pumpAndSettle();
   await tester.enterText(find.byKey(const Key('farmer_name')),'محلي');
   await tester.tap(find.text('حفظ'));await tester.pumpAndSettle();
   final selected=await creating;expect(selected,isNotNull);expect(selected!.isPending,isTrue);
   await choose(tester,selected);expect(farmers(tester).selectedItem!.entityReference,selected.entityReference);
   final createFarm=farms(tester).onAddNew!();await tester.pumpAndSettle();
   await tester.enterText(find.byType(TextFormField).at(0),'قطعة');
   await tester.tap(find.text('حفظ'));await tester.pumpAndSettle();
   final land=await createFarm;expect(land,isNotNull);expect(land!.isPending,isTrue);
   farms(tester).onChanged(land);await tester.pumpAndSettle();
   expect(farms(tester).selectedItem!.entityReference,land.entityReference);
   expect((await farms(tester).searchFunction('قطعة')).single.entityReference,land.entityReference);
   final commands=await store.allCommands('a');expect(commands.map((c)=>c.type),[CommandType.createFarmer,CommandType.createFarm]);
   expect(commands.last.payload['p_farmer_well_account_id'],selected.entityReference.toPayload());
   await unmount(tester);
  });
 }
 for(final role in ['manager','partner','viewer','farmer']){
  testWidgets('$role creation guards open no dialog and save no command',(tester)async{
   await mount(tester,role:role);await choose(tester,farmer);
   expect(await farmers(tester).onAddNew?.call(),isNull);
   expect(await farms(tester).onAddNew?.call(),isNull);
   await tester.pump();expect(find.byType(AlertDialog),findsNothing);
   expect(await store.allCommands('a'),isEmpty);await unmount(tester);
  });
 }
 testWidgets('farmer search result from previous well is discarded',(tester)async{
  await mount(tester);repo.farmerGate=Completer<List<FarmerAccount>>();
  final request=farmers(tester).searchFunction('old');await tester.pump();
  rebuild(()=>well='elsewhere');await tester.pumpAndSettle();
  repo.farmerGate!.complete([farmer]);expect(await request,isEmpty);
  expect(farmers(tester).selectedItem,isNull);await unmount(tester);
 });
 for(final changeWell in [false,true]){
  testWidgets('farm search discards changed ${changeWell?'well':'farmer'} scope',(tester)async{
   await mount(tester);await choose(tester,farmer);repo.farmGate=Completer<List<Farm>>();
   final request=farms(tester).searchFunction('old');await tester.pump();
   if(changeWell){rebuild(()=>well='elsewhere');await tester.pumpAndSettle();}else{await choose(tester,other);}
   repo.farmGate!.complete([const Farm(id:'old',wellId:'w',name:'قديمة',farmerAccountId:'f')]);
   expect(await request,isEmpty);expect(farms(tester).selectedItem,isNull);await unmount(tester);
  });
  testWidgets('farm dialog return discarded after changed ${changeWell?'well':'farmer'} scope',(tester)async{
   await mount(tester);await choose(tester,farmer);
   final creating=farms(tester).onAddNew!();await tester.pumpAndSettle();
   if(changeWell){rebuild(()=>well='elsewhere');await tester.pumpAndSettle();}else{await choose(tester,other);}
   await tester.enterText(find.byType(TextFormField).at(0),'أصل النية');
   await tester.tap(find.text('حفظ'));await tester.pumpAndSettle();
   expect(await creating,isNull);expect(farms(tester).selectedItem,isNull);
   final command=(await store.allCommands('a')).single;
   expect(command.type,CommandType.createFarm);expect(command.wellId,'w');expect(command.payload['p_farmer_well_account_id'],'f');
   await unmount(tester);
  });
 }
}

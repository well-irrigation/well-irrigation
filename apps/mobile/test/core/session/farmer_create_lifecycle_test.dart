import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/command_transport.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/in_memory_outbox_store.dart';
import 'package:well_irrigation_mobile/core/sync/retry_classification.dart';
import 'package:well_irrigation_mobile/core/sync/sync_status.dart';

import '../sync/fake_command_transport.dart';

class GatedFarmerTransport implements CommandTransport{
 final gate=Completer<DispatchResult>();int calls=0;
 @override Future<DispatchResult> dispatch(DispatchRequest request){calls++;return gate.future;}
}

void main(){
 for(final status in ['created','matched_existing','requires_resolution']){
  test('waitForCanonical resolves $status after one opportunity and never creates a farm',()async{
   final store=InMemoryOutboxStore();final transport=FakeCommandTransport();
   transport.scheduleRawResponse(CommandType.createFarmer,{
    'status':status,
    if(status!='requires_resolution') 'farmer_well_account_id':'server-farmer',
    if(status=='requires_resolution') 'duplicate_candidates':<Object>[],
   });
   final coordinator=OfflineSessionCoordinator(store:store,commandTransport:transport);
   addTearDown(coordinator.dispose);
   final farmer=await coordinator.enqueueFarmer(accountId:'a',wellId:'w',fullName:'علي',waitForCanonical:true);
   expect(transport.requests,hasLength(1));
   final command=(await store.allCommands('a')).single;
   expect(command.type,CommandType.createFarmer);
   if(status=='requires_resolution'){
    expect(farmer.id,isEmpty);expect(farmer.isPending,isTrue);expect(farmer.status,'requires_resolution');
    expect(command.status,CommandStatus.review);
    expect(await store.mapping('a',command.localId,EntityKind.farmerWellAccount),isNull);
   }else{
    expect(farmer.id,'server-farmer');expect(farmer.isPending,isFalse);
    expect(command.status,CommandStatus.confirmed);
    expect((await store.mapping('a',command.localId,EntityKind.farmerWellAccount))!.serverId,farmer.id);
   }
  });
 }
 test('offline requested wait returns saved pending identity without inventing legal farmer',()async{
  final store=InMemoryOutboxStore();final coordinator=OfflineSessionCoordinator(store:store);
  addTearDown(coordinator.dispose);
  final farmer=await coordinator.enqueueFarmer(accountId:'a',wellId:'w',fullName:'علي',waitForCanonical:true);
  expect(farmer.isPending,isTrue);expect(farmer.id,isEmpty);
  final command=(await store.allCommands('a')).single;
  expect(command.type,CommandType.createFarmer);expect(command.status,CommandStatus.pending);
  expect(farmer.entityReference.localReference!.localId,command.localId);
 });
 test('retryable transport failure preserves original saved farmer command',()async{
  final store=InMemoryOutboxStore();final transport=FakeCommandTransport();
  transport.scheduleFailure(CommandType.createFarmer, const DispatchFailed(disposition:FailureDisposition.retry,message:'offline'));
  final coordinator=OfflineSessionCoordinator(store:store,commandTransport:transport);
  addTearDown(coordinator.dispose);
  final farmer=await coordinator.enqueueFarmer(accountId:'a',wellId:'w',fullName:'علي',waitForCanonical:true);
  expect(farmer.isPending,isTrue);expect(transport.requests,hasLength(1));
  final command=(await store.allCommands('a')).single;
  expect(command.status,CommandStatus.pending);expect(command.payload['p_full_name'],'علي');
  expect(command.commandId,transport.requests.single.commandId);
 });
 testWidgets('eight second wait bound preserves the pending command after hung sync', (tester)async{
  final store=InMemoryOutboxStore();final transport=GatedFarmerTransport();
  final coordinator=OfflineSessionCoordinator(store:store,commandTransport:transport);
  await coordinator.initialize();
  final future=coordinator.enqueueFarmer(accountId:'a',wellId:'w',fullName:'علي',waitForCanonical:true);
  await tester.pump();await tester.pump(const Duration(seconds:7));
  var done=false;unawaited(future.then((_)=>done=true));
  await tester.pump();expect(done,isFalse);
  await tester.pump(const Duration(seconds:2));
  final farmer=await future;expect(farmer.isPending,isTrue);expect(transport.calls,1);
  final command=(await store.allCommands('a')).single;
  expect(command.type,CommandType.createFarmer);expect(command.payload['p_full_name'],'علي');
  transport.gate.complete(const DispatchFailed(disposition:FailureDisposition.retry,message:'offline'));
  await tester.pump();coordinator.dispose();await tester.pump();
 });
 testWidgets('same action token coalesces concurrent requests into one command and opportunity',(tester)async{
  final store=InMemoryOutboxStore();final transport=GatedFarmerTransport();
  final coordinator=OfflineSessionCoordinator(store:store,commandTransport:transport);
  await coordinator.initialize();
  final first=coordinator.enqueueFarmer(accountId:'a',wellId:'w',fullName:'الأصل',actionToken:'tap',waitForCanonical:true);
  final replay=coordinator.enqueueFarmer(accountId:'a',wellId:'w',fullName:'لا يستبدل الأصل',actionToken:'tap',waitForCanonical:true);
  await tester.pump();expect(transport.calls,1);expect(await store.allCommands('a'),hasLength(1));
  transport.gate.complete(const DispatchAccepted(response:{'status':'created','farmer_well_account_id':'f'},entityId:'f'));
  await tester.pump();final values=await Future.wait([first,replay]);
  expect(values.map((f)=>f.id),['f','f']);expect(values.map((f)=>f.fullName),['الأصل','الأصل']);
  expect((await store.allCommands('a')).single.type,CommandType.createFarmer);
  coordinator.dispose();await tester.pump();
 });
}

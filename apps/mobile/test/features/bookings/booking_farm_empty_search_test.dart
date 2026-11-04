import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/widgets/smart_lookup_field.dart';
import 'package:well_irrigation_mobile/features/bookings/booking_form_screen.dart';
import '../farmers/inline_farm_flow_test.dart' show Ops,Bookings,wrap,farmer;
import '../../support/identity_fixture.dart';
void main(){
 setUpAll(sqfliteFfiInit);
 testWidgets('successful empty search does not resurrect an old cached canonical farm',(tester)async{
 final dir=Directory.systemTemp.createTempSync('empty_farm');final store=SqliteOutboxStore(databasePath:'${dir.path}/db',sqfliteFactory:databaseFactoryFfiNoIsolate);await tester.runAsync(()=>store.initialize());final coordinator=OfflineSessionCoordinator(store:store);final repo=Bookings(store);
 await tester.runAsync(()=>repo.cacheBookingChoices('a','w','farms.f',[{'id':'old','well_id':'w','farmer_well_account_id':'f','name':'قديمة','status':'active'}]));
 await tester.pumpWidget(wrap(BookingFormScreen(identity:testIdentity(accountId:'a',activeWell:testWell(id:'w')),bookingRepository:repo,operationsRepository:Ops(),coordinator:coordinator)));
 await tester.pumpAndSettle();tester.widget<SmartLookupField<FarmerAccount>>(find.byType(SmartLookupField<FarmerAccount>)).onChanged(farmer);await tester.pumpAndSettle();
 final values=await tester.widget<SmartLookupField<Farm>>(find.byType(SmartLookupField<Farm>)).searchFunction('');expect(values,isEmpty);
 await tester.pumpWidget(const SizedBox());coordinator.dispose();await store.close();dir.deleteSync(recursive:true);
 });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/api/booking_repository.dart';
import 'package:well_irrigation_mobile/core/api/booking_local_ledger.dart';
import 'package:well_irrigation_mobile/core/session/offline_session_coordinator.dart';
import 'package:well_irrigation_mobile/core/sync/entity_reference.dart';
import 'package:well_irrigation_mobile/core/sync/command_type.dart';
import 'package:well_irrigation_mobile/core/sync/sqlite_outbox_store.dart';
import 'package:well_irrigation_mobile/core/widgets/smart_lookup_field.dart';
import 'package:well_irrigation_mobile/features/bookings/booking_form_screen.dart';
import 'package:well_irrigation_mobile/features/farmers/farmer_detail_screen.dart';

import '../../support/identity_fixture.dart';

const farmer = FarmerAccount(id: 'f', fullName: 'أحمد', publicCode: 'F');

class Ops extends OperationsRepository {
  @override
  Future<List<FarmerAccount>> fetchFarmers(String w, {String? query}) async => [
    farmer,
  ];
  @override
  Future<List<Farm>> fetchFarms(String w, {String? farmerAccountId}) =>
      throw StateError('unbounded');
  @override
  Future<List<Farm>> searchFarms(
    String w, {
    required String farmerAccountId,
    String query = '',
    int limit = 50,
  }) async => [];
  @override
  Future<FarmerDetailData> fetchFarmerDetail({
    required String wellId,
    required String farmerAccountId,
  }) => throw StateError('offline');
}

class Bookings extends BookingRepository {
  Bookings(SqliteOutboxStore store)
    : super(null, null, BookingLocalLedger(store));
  @override
  Future<void> requestBookingConfirmation(String a) async {}
}

Widget wrap(Widget child) => MaterialApp(
  locale: const Locale('ar'),
  supportedLocales: const [Locale('ar')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: Directionality(textDirection: TextDirection.rtl, child: child),
);
void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late SqliteOutboxStore store;
  late OfflineSessionCoordinator coordinator;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('farm_ui');
    store = SqliteOutboxStore(
      databasePath: '${dir.path}/db',
      sqfliteFactory: databaseFactoryFfiNoIsolate,
      singleInstance: false,
    );
    await store.initialize();
    coordinator = OfflineSessionCoordinator(store: store);
  });
  tearDown(() async {
    coordinator.dispose();
    await store.close();
    dir.deleteSync(recursive: true);
  });
  for (final role in [
    'owner',
    'operator',
    'manager',
    'partner',
    'viewer',
    'farmer',
  ]) {
    testWidgets(
      'booking inline action gated by selected farmer and role $role',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            BookingFormScreen(
              identity: testIdentity(
                accountId: 'a',
                activeWell: testWell(id: 'w', roles: [role]),
              ),
              bookingRepository: Bookings(store),
              operationsRepository: Ops(),
              coordinator: coordinator,
              initialDate: DateTime(2027, 1, 1),
            ),
          ),
        );
        await tester.pumpAndSettle();
        SmartLookupField<Farm> field() => tester.widget<SmartLookupField<Farm>>(
          find.byType(SmartLookupField<Farm>),
        );
        expect(field().onAddNew, isNull);
        final select = tester.widget<SmartLookupField<FarmerAccount>>(
          find.byType(SmartLookupField<FarmerAccount>),
        );
        select.onChanged(farmer);
        await tester.pumpAndSettle();
        if (role != 'owner' && role != 'operator') {
          expect(field().onAddNew, isNull);
          return;
        }
        expect(field().onAddNew, isNotNull);
        final saved = field().onAddNew!();
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField).at(0), 'الوادي');
        await tester.enterText(find.byType(TextFormField).at(1), 'الشرقية');
        await tester.tap(find.text('حفظ'));
        await tester.pumpAndSettle();
        final farm = await saved;
        expect(farm, isNotNull);
        field().onChanged(farm);
        await tester.pumpAndSettle();
        expect(field().selectedItem!.isPending, true);
        expect(find.text('تم حفظ الأرض'), findsOneWidget);
        final commands = await store.allCommands('a');
        expect(commands, hasLength(1));
        expect(commands.single.type, CommandType.createFarm);
        expect(commands.single.payload['p_farmer_well_account_id'], 'f');
        expect(commands.single.wellId, 'w');
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'farmer detail reopens offline with known cached identity and local farm',
    (tester) async {
      await coordinator.farmFarmerIdentity(
        accountId: 'a',
        wellId: 'w',
        farmerId: 'f',
        current: farmer,
      );
      final farm = await coordinator.enqueueFarm(
        accountId: 'a',
        wellId: 'w',
        name: 'الوادي',
        farmerReference: const ServerEntityReference('f'),
      );
      final again = await coordinator.enqueueFarm(
        accountId: 'a',
        wellId: 'w',
        name: 'الوادي',
        farmerReference: const ServerEntityReference('f'),
      );
      expect(again.entityReference, farm.entityReference);
      expect(await store.allCommands('a'), hasLength(1));
      coordinator.dispose();
      await store.close();
      store = SqliteOutboxStore(
        databasePath: '${dir.path}/db',
        sqfliteFactory: databaseFactoryFfiNoIsolate,
        singleInstance: false,
      );
      coordinator = OfflineSessionCoordinator(store: store);
      await tester.runAsync(() => store.initialize());
      await tester.pumpWidget(
        wrap(
          FarmerDetailScreen(
            wellId: 'w',
            farmerAccountId: 'f',
            wellName: 'البئر',
            canCreateFarm: true,
            accountId: 'a',
            repository: Ops(),
            coordinator: coordinator,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('أحمد'), findsOneWidget);
      expect(find.textContaining('الوادي'), findsOneWidget);
      expect(find.text('إضافة أرض جديدة'), findsOneWidget);
      await tester.tap(find.text('إضافة أرض جديدة'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'قطعة أخرى');
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();
      expect(find.textContaining('قطعة أخرى'), findsOneWidget);
      expect(
        (await store.allCommands('a')).every(
          (c) =>
              c.type == CommandType.createFarm &&
              c.payload['p_farmer_well_account_id'] == 'f',
        ),
        true,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}

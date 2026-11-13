import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';
import 'package:well_irrigation_mobile/core/api/manual_session_entry_capability.dart';

Map<String,Object?> capabilityJson({String well = 'well-a',bool completed = false,bool active = false}) => {
  'contract':'manual_session_entry_capability','version':1,'well_id':well,
  'can_record_historical_session':completed,'can_adopt_external_session':active,
};

Matcher failure(ManualSessionEntryCapabilityFailure kind) =>
  isA<ManualSessionEntryCapabilityUnavailable>().having((e) => e.kind,'kind',kind);

void main() {
  group('strict capability contract', () {
    for (final completed in [false,true]) {
      for (final active in [false,true]) {
        test('independent flags $completed / $active', () {
          final capability = ManualSessionEntryCapability.fromContract(
            capabilityJson(completed:completed,active:active),wellId:'well-a');
          expect(capability.wellId,'well-a');
          expect(capability.contract,'manual_session_entry_capability');
          expect(capability.version,1);
          expect(capability.canRecordHistoricalSession,completed);
          expect(capability.canAdoptExternalSession,active);
        });
      }
    }
    for (final field in ['contract','version','well_id',
      'can_record_historical_session','can_adopt_external_session']) {
      test('missing $field is unavailable, never denied', () {
        final raw = capabilityJson()..remove(field);
        expect(() => ManualSessionEntryCapability.fromContract(raw,wellId:'well-a'),
          throwsA(failure(ManualSessionEntryCapabilityFailure.malformed)));
      });
    }
    for (final field in ['can_record_historical_session','can_adopt_external_session']) {
      for (final value in [null,0,1,'false',<Object?>[],<String,Object?>{}]) {
        test('non-boolean $field $value is rejected', () {
          expect(() => ManualSessionEntryCapability.fromContract(
            capabilityJson()..[field] = value,wellId:'well-a'),
            throwsA(failure(ManualSessionEntryCapabilityFailure.malformed)));
        });
      }
    }
    for (final raw in [null,1,'text',<Object?>[],<String,Object?>{}]) {
      test('malformed envelope $raw is rejected', () {
        expect(() => ManualSessionEntryCapability.fromContract(raw,wellId:'well-a'),
          throwsA(failure(ManualSessionEntryCapabilityFailure.malformed)));
      });
    }
    test('wrong contract is rejected', () {
      expect(() => ManualSessionEntryCapability.fromContract(
        capabilityJson()..['contract'] = 'other',wellId:'well-a'),
        throwsA(failure(ManualSessionEntryCapabilityFailure.malformed)));
    });
    for (final version in [0,2,-1]) {
      test('unsupported version $version is unavailable', () {
        expect(() => ManualSessionEntryCapability.fromContract(
          capabilityJson()..['version'] = version,wellId:'well-a'),
          throwsA(failure(ManualSessionEntryCapabilityFailure.unsupportedVersion)));
      });
    }
    for (final version in ['1',1.0,true]) {
      test('version type $version is rejected', () {
        expect(() => ManualSessionEntryCapability.fromContract(
          capabilityJson()..['version'] = version,wellId:'well-a'),
          throwsA(failure(ManualSessionEntryCapabilityFailure.malformed)));
      });
    }
    test('well A cannot authorize well B', () {
      expect(() => ManualSessionEntryCapability.fromContract(
        capabilityJson(well:'well-b',completed:true,active:true),wellId:'well-a'),
        throwsA(failure(ManualSessionEntryCapabilityFailure.scopeMismatch)));
    });
    for (final well in ['',null,3,' well-a ']) {
      test('invalid response well $well cannot authorize', () {
        expect(() => ManualSessionEntryCapability.fromContract(
          capabilityJson()..['well_id'] = well,wellId:'well-a'),throwsA(isA<ManualSessionEntryCapabilityUnavailable>()));
      });
    }
  });

  test('a loaded denial completes as capability data rather than unavailable', () async {
    final client = SupabaseClient('https://capability.invalid','test-key',
      authOptions:const AuthClientOptions(autoRefreshToken:false),
      httpClient:MockClient((request) async => http.Response(jsonEncode({
        'contract':'manual_session_entry_capability','version':1,'well_id':'well-a',
        'can_record_historical_session':false,'can_adopt_external_session':false,
      }),200,headers:{'content-type':'application/json'},request:request)));
    try {
      await client.auth.recoverSession(jsonEncode({
        'access_token':'test-token','token_type':'bearer','refresh_token':'refresh-token',
        'user':{'id':'account-a','aud':'authenticated','created_at':''},
      }));
      final ManualSessionEntryCapabilityReader reader = OperationsRepository(client);
      await expectLater(reader.fetchManualSessionEntryCapability(accountId:'account-a',wellId:'well-a'),
        completion(isA<ManualSessionEntryCapability>()
          .having((v) => v.canRecordHistoricalSession,'completed',false)
          .having((v) => v.canAdoptExternalSession,'active',false)));
    } finally {
      await client.dispose();
    }
  });

  group('typed read boundary', () {
    late SupabaseClient client;
    late ManualSessionEntryCapabilityReader reader;
    final requests = <http.Request>[];
    Object? reply;
    var status = 200;
    var networkFailure = false;
    Completer<void>? gate;
    late Completer<void> entered;
    Future<void> authenticate(String account) async {
      await client.auth.recoverSession(jsonEncode({
        'access_token':'test-token','token_type':'bearer','refresh_token':'refresh-token',
        'user':{'id':account,'aud':'authenticated','created_at':''},
      }));
    }
    Future<ManualSessionEntryCapability> read({String account = 'account-a',String well = 'well-a'}) =>
      reader.fetchManualSessionEntryCapability(accountId:account,wellId:well);
    setUp(() async {
      reply = capabilityJson(completed:true,active:true);
      status = 200;
      networkFailure = false;
      gate = null;
      entered = Completer<void>();
      requests.clear();
      client = SupabaseClient('https://capability.invalid','test-key',
        authOptions:const AuthClientOptions(autoRefreshToken:false),
        httpClient:MockClient((request) async {
          requests.add(request);
          if (!entered.isCompleted) entered.complete();
          await gate?.future;
          if (networkFailure) throw http.ClientException('internal transport diagnostic');
          return http.Response(jsonEncode(reply),status,
            headers:{'content-type':'application/json'},request:request);
        }));
      reader = OperationsRepository(client);
      await authenticate('account-a');
    });
    tearDown(() async => client.dispose());

    test('exact public read RPC and requested well, without role authority', () async {
      final capability = await read();
      expect(capability.canRecordHistoricalSession,isTrue);
      expect(capability.canAdoptExternalSession,isTrue);
      expect(requests.single.url.path,'/rest/v1/rpc/get_manual_session_entry_capability');
      expect(requests.single.headers['content-profile'],'api');
      expect(jsonDecode(requests.single.body),{'p_well_id':'well-a'});
    });
    test('transport failure remains unavailable rather than false/false', () async {
      networkFailure = true;
      await expectLater(read(),throwsA(failure(ManualSessionEntryCapabilityFailure.network)));
    });
    test('malformed response remains unavailable', () async {
      reply = {'status':'success'};
      await expectLater(read(),throwsA(failure(ManualSessionEntryCapabilityFailure.malformed)));
    });
    test('wrong response well remains unavailable', () async {
      reply = capabilityJson(well:'well-b',completed:true,active:true);
      await expectLater(read(),throwsA(failure(ManualSessionEntryCapabilityFailure.scopeMismatch)));
    });
    test('unsupported version remains unavailable', () async {
      reply = capabilityJson()..['version'] = 2;
      await expectLater(read(),throwsA(failure(ManualSessionEntryCapabilityFailure.unsupportedVersion)));
    });
    test('loading is pending until the typed result arrives', () async {
      gate = Completer<void>();
      var completed = false;
      final pending = read().then((v) { completed = true; return v; });
      await entered.future;
      expect(completed,isFalse);
      gate!.complete();
      expect((await pending).canAdoptExternalSession,isTrue);
    });
    test('reload does not retain stale permission or cache failure as denial', () async {
      expect((await read()).canAdoptExternalSession,isTrue);
      networkFailure = true;
      await expectLater(read(),throwsA(failure(ManualSessionEntryCapabilityFailure.network)));
      networkFailure = false;
      reply = capabilityJson();
      final denied = await read();
      expect(denied.canRecordHistoricalSession,isFalse);
      expect(denied.canAdoptExternalSession,isFalse);
      expect(requests,hasLength(3));
    });
    test('well change causes a fresh scoped read', () async {
      await read();
      reply = capabilityJson(well:'well-b',active:true);
      final second = await read(well:'well-b');
      expect(second.wellId,'well-b');
      expect(second.canRecordHistoricalSession,isFalse);
      expect(second.canAdoptExternalSession,isTrue);
      expect(requests.map((r) => jsonDecode(r.body)['p_well_id']),['well-a','well-b']);
    });
    test('wrong authenticated account sends no RPC', () async {
      await expectLater(read(account:'account-b'),throwsA(failure(ManualSessionEntryCapabilityFailure.authentication)));
      expect(requests,isEmpty);
    });
    test('missing authenticated session sends no RPC', () async {
      final unauthenticated = SupabaseClient('https://capability.invalid','test-key',
        authOptions:const AuthClientOptions(autoRefreshToken:false),
        httpClient:MockClient((request) async {
          requests.add(request);
          return http.Response('{}',200,request:request);
        }));
      try {
        await expectLater(OperationsRepository(unauthenticated)
          .fetchManualSessionEntryCapability(accountId:'account-a',wellId:'well-a'),
          throwsA(failure(ManualSessionEntryCapabilityFailure.authentication)));
        expect(requests,isEmpty);
      } finally {
        await unauthenticated.dispose();
      }
    });
    for (final well in ['', ' well-a ']) {
      test('invalid requested well [$well] sends no RPC', () async {
        await expectLater(read(well:well),throwsA(failure(ManualSessionEntryCapabilityFailure.malformed)));
        expect(requests,isEmpty);
      });
    }
    test('identity change during read invalidates the result', () async {
      gate = Completer<void>();
      final pending = read();
      final assertion = expectLater(pending,throwsA(failure(ManualSessionEntryCapabilityFailure.identityChanged)));
      await entered.future;
      await authenticate('account-b');
      gate!.complete();
      await assertion;
    });
    test('new identity reads anew instead of receiving old authority', () async {
      await read();
      await authenticate('account-b');
      reply = capabilityJson();
      expect((await read(account:'account-b')).canAdoptExternalSession,isFalse);
      expect(requests,hasLength(2));
    });
    for (final code in ['42501','28000','PGRST301','PGRST302','XX000']) {
      test('RPC error $code is a typed read failure', () async {
        status = 400;
        reply = {'code':code,'message':'private SQL/RPC diagnostic'};
        await expectLater(read(),throwsA(failure(switch(code) {
          '42501' => ManualSessionEntryCapabilityFailure.forbidden,
          '28000' || 'PGRST301' || 'PGRST302' => ManualSessionEntryCapabilityFailure.authentication,
          _ => ManualSessionEntryCapabilityFailure.network,
        })));
      });
    }
  });
  test('no client is unavailable, never a loaded denial', () async {
    await expectLater(const OperationsRepository().fetchManualSessionEntryCapability(
      accountId:'account-a',wellId:'well-a'),
      throwsA(failure(ManualSessionEntryCapabilityFailure.unavailable)));
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';

void main() {
  test(
    'bounded typed search passes scope/query/cursor and preserves label',
    () async {
      final calls = <http.Request>[];
      final client = SupabaseClient(
        'https://example.test',
        'test-key',
        httpClient: MockClient((r) async {
          calls.add(r);
          return http.Response(
            jsonEncode({
              'contract': 'search_well_farms',
              'version': 1,
              'items': [
                {
                  'id': 'farm',
                  'well_id': 'well',
                  'farmer_well_account_id': 'farmer',
                  'name': 'الوادي',
                  'distinguishing_label': 'الشرقية',
                  'status': 'active',
                },
              ],
              'next_cursor': {'id': 'farm'},
            }),
            200,
            request: r,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final page = await OperationsRepository(client).searchFarmPage(
        'well',
        farmerAccountId: 'farmer',
        query: 'الوادي',
        limit: 50,
        after: {'id': 'before'},
      );
      expect(page.items.single.displayName, 'الوادي — الشرقية');
      expect(page.nextCursor, {'id': 'farm'});
      expect(calls.single.url.path, '/rest/v1/rpc/search_well_farms');
      expect(jsonDecode(calls.single.body), {
        'p_well_id': 'well',
        'p_farmer_well_account_id': 'farmer',
        'p_query': 'الوادي',
        'p_limit': 50,
        'p_after': {'id': 'before'},
      });
      expect(calls.single.headers['Content-Profile'], 'api');
      await client.dispose();
    },
  );
  for (final invalid in ['well', 'farmer', 'inactive', 'limit']) {
    test('search rejects $invalid scope/response violation', () async {
      final client = SupabaseClient(
        'https://example.test',
        'key',
        httpClient: MockClient(
          (r) async => http.Response(
            jsonEncode({
              'contract': 'search_well_farms',
              'version': 1,
              'items': [
                for (var i = 0; i < (invalid == 'limit' ? 2 : 1); i++)
                  {
                    'id': 'farm-$i',
                    'well_id': invalid == 'well' ? 'other' : 'w',
                    'farmer_well_account_id': invalid == 'farmer'
                        ? 'other'
                        : 'f',
                    'status': invalid == 'inactive' ? 'inactive' : 'active',
                    'name': 'أرض',
                  },
              ],
            }),
            200,
            request: r,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      await expectLater(
        OperationsRepository(client)
            .searchFarmPage('w', farmerAccountId: 'f', limit: 1),
        throwsStateError,
      );
      await client.dispose();
    });
  }
}

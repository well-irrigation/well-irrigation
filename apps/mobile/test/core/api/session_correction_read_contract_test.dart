import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/api/operations_repository.dart';

const _session = '11111111-1111-4111-8111-111111111111';

Map<String, Object?> _item(int revision, {String financial = 'pending'}) => {
  'correction_id': 'correction-$revision',
  'session_id': _session,
  'previous_revision': revision - 1,
  'new_revision': revision,
  'operational_revision': revision,
  'before_started_at': '2026-11-01T08:00:00Z',
  'before_ended_at': '2026-11-01T10:00:00Z',
  'after_started_at': '2026-11-01T08:15:00Z',
  'after_ended_at': '2026-11-01T10:30:00Z',
  'reason': 'تصحيح وقت التنفيذ الفعلي',
  'requested_at': '2026-11-02T09:00:00Z',
  'accepted_at': '2026-11-02T09:00:01Z',
  'financial_status': financial,
  'financial_review_required': financial == 'financial_review_required',
  'financial_review_reason': financial == 'financial_review_required'
      ? 'يحتاج الأثر المالي إلى مراجعة'
      : null,
};

Map<String, Object?> _history(List<Map<String, Object?>> items) => {
  'contract': 'get_session_corrections',
  'version': 1,
  'session_id': _session,
  'items': items,
};

Map<String, Object?> _status({
  int revision = 1,
  String financial = 'pending',
}) => {
  'contract': 'get_session_correction_status',
  'version': 1,
  'session_id': _session,
  'operational_revision': revision,
  'status': revision == 0 ? 'not_corrected' : financial,
  'financial_status': revision == 0 ? 'not_applicable' : financial,
  if (revision > 0) ...{
    'correction_id': 'correction-$revision',
    'financial_review_required': financial == 'financial_review_required',
    'financial_review_reason': financial == 'financial_review_required'
        ? 'يحتاج الأثر المالي إلى مراجعة'
        : null,
  },
};

// Deliberately dynamic until the read methods/models are implemented. Missing
// members fail with an explicit RED assertion, without a compilation failure.
T _field<T>(String name, T Function() read) {
  try {
    return read();
  } on NoSuchMethodError {
    fail('Missing correction read model property: $name');
  }
}

void main() {
  late SupabaseClient client;
  late dynamic repository;
  late Object? response;
  late int httpStatus;
  late bool networkFailure;
  late List<http.Request> requests;

  setUp(() {
    response = _history([]);
    httpStatus = 200;
    networkFailure = false;
    requests = [];
    client = SupabaseClient(
      'https://example.test',
      'test-anon-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (networkFailure) {
          throw http.ClientException('connection unavailable');
        }
        return http.Response(
          jsonEncode(response),
          httpStatus,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    repository = OperationsRepository(client);
  });
  tearDown(() async => client.dispose());

  Future<dynamic> read({bool status = false}) async {
    try {
      return status
          ? await repository.fetchSessionCorrectionStatus(_session)
          : await repository.fetchSessionCorrections(_session);
    } on NoSuchMethodError {
      fail(
        'Missing OperationsRepository.${status ? 'fetchSessionCorrectionStatus' : 'fetchSessionCorrections'} or correction read model',
      );
    }
  }

  void expectRpc(String rpc) {
    expect(requests, hasLength(1));
    expect(requests.single.method, 'POST');
    expect(requests.single.url.path, '/rest/v1/rpc/$rpc');
    expect(requests.single.headers['content-profile'], 'api');
    expect(jsonDecode(requests.single.body), {'p_session_id': _session});
  }

  group('R6C-3B correction history read', () {
    test(
      'empty success is a validated envelope, not an authorization decision',
      () async {
        final dynamic result = await read();
        expectRpc('get_session_corrections');
        expect(
          _field('contract', () => result.contract),
          'get_session_corrections',
        );
        expect(_field('version', () => result.version), 1);
        expect(_field('sessionId', () => result.sessionId), _session);
        expect(_field('items', () => result.items), isEmpty);
      },
    );

    test(
      'one correction retains before/after, reason, identity and timestamps',
      () async {
        response = _history([_item(1)]);
        final dynamic result = await read();
        final dynamic item = _field('items', () => result.items).single;
        expect(_field('correctionId', () => item.correctionId), 'correction-1');
        expect(_field('sessionId', () => item.sessionId), _session);
        expect(_field('previousRevision', () => item.previousRevision), 0);
        expect(_field('newRevision', () => item.newRevision), 1);
        expect(
          _field('operationalRevision', () => item.operationalRevision),
          1,
        );
        expect(
          _field('beforeStartedAt', () => item.beforeStartedAt),
          DateTime.parse('2026-11-01T08:00:00Z').toLocal(),
        );
        expect(
          _field('beforeEndedAt', () => item.beforeEndedAt),
          DateTime.parse('2026-11-01T10:00:00Z').toLocal(),
        );
        expect(
          _field('afterStartedAt', () => item.afterStartedAt),
          DateTime.parse('2026-11-01T08:15:00Z').toLocal(),
        );
        expect(
          _field('afterEndedAt', () => item.afterEndedAt),
          DateTime.parse('2026-11-01T10:30:00Z').toLocal(),
        );
        expect(_field('reason', () => item.reason), 'تصحيح وقت التنفيذ الفعلي');
        expect(
          _field('requestedAt', () => item.requestedAt),
          DateTime.parse('2026-11-02T09:00:00Z').toLocal(),
        );
        expect(
          _field('acceptedAt', () => item.acceptedAt),
          DateTime.parse('2026-11-02T09:00:01Z').toLocal(),
        );
        expect(
          _field('financialStatus', () => item.financialStatus),
          'pending',
        );
        expect(
          _field('financialReviewRequired', () => item.financialReviewRequired),
          isFalse,
        );
        expect(
          _field('financialReviewReason', () => item.financialReviewReason),
          isNull,
        );
      },
    );

    test('preserves the server revision order', () async {
      response = _history([_item(1), _item(2), _item(3)]);
      final dynamic result = await read();
      expect(
        [for (final dynamic item in result.items) item.newRevision],
        [1, 2, 3],
      );
    });
    test('retains safe financial review reason', () async {
      response = _history([_item(1, financial: 'financial_review_required')]);
      final dynamic result = await read();
      final dynamic item = result.items.single;
      expect(
        _field('financialStatus', () => item.financialStatus),
        'financial_review_required',
      );
      expect(
        _field('financialReviewRequired', () => item.financialReviewRequired),
        isTrue,
      );
      expect(
        _field('financialReviewReason', () => item.financialReviewReason),
        'يحتاج الأثر المالي إلى مراجعة',
      );
    });
    for (final field in ['contract', 'version', 'session_id', 'items']) {
      test('rejects missing envelope $field', () async {
        response = _history([])..remove(field);
        await expectLater(read(), throwsA(isA<FormatException>()));
      });
    }
    for (final entry in <String, Object?>{
      'contract': 'other_contract',
      'version': 2,
      'session_id': 'foreign-session',
      'items': {},
    }.entries) {
      test('rejects invalid envelope ${entry.key}', () async {
        response = _history([])..[entry.key] = entry.value;
        await expectLater(read(), throwsA(isA<FormatException>()));
      });
    }
    for (final field in [
      'correction_id',
      'session_id',
      'previous_revision',
      'new_revision',
      'operational_revision',
      'reason',
      'financial_status',
    ]) {
      test('rejects missing required history $field', () async {
        response = _history([_item(1)..remove(field)]);
        await expectLater(read(), throwsA(isA<FormatException>()));
      });
    }
    for (final field in [
      'before_started_at',
      'before_ended_at',
      'after_started_at',
      'after_ended_at',
      'requested_at',
      'accepted_at',
    ]) {
      for (final missing in [false, true]) {
        test(
          'rejects ${missing ? 'missing' : 'malformed'} history $field',
          () async {
            final item = _item(1);
            if (missing) {
              item.remove(field);
            } else {
              item[field] = 'invalid-time';
            }
            response = _history([item]);
            await expectLater(read(), throwsA(isA<FormatException>()));
          },
        );
      }
    }
    for (final entry in <String, Object?>{
      'reason': '   ',
      'financial_status': 'success',
      'previous_revision': -1,
      'new_revision': '1',
      'session_id': 'foreign-session',
    }.entries) {
      test('rejects malformed history ${entry.key}', () async {
        response = _history([_item(1)..[entry.key] = entry.value]);
        await expectLater(read(), throwsA(isA<FormatException>()));
      });
    }
  });

  group('R6C-3B strict history timestamps', () {
    const fields = [
      'before_started_at',
      'before_ended_at',
      'after_started_at',
      'after_ended_at',
      'requested_at',
      'accepted_at',
    ];
    for (final value in ['2026-11-31T08:00:00Z', '2026-11-06T08:15:00']) {
      for (final field in fields) {
        test('history rejects $field = $value', () async {
          response = _history([_item(1)..[field] = value]);
          await expectLater(read(), throwsA(isA<FormatException>()));
        });
      }
    }
    final valid = <String, DateTime>{
      '2026-11-06T08:15:00Z': DateTime.utc(2026, 11, 6, 8, 15),
      '2026-11-06T11:15:00+03:00': DateTime.utc(2026, 11, 6, 8, 15),
      '2026-11-06T02:45:00-05:30': DateTime.utc(2026, 11, 6, 8, 15),
      '2026-11-06T08:15:00.100Z': DateTime.utc(2026, 11, 6, 8, 15, 0, 100),
      '2026-11-06T11:15:00.123456+03:00': DateTime.utc(
        2026,
        11,
        6,
        8,
        15,
        0,
        123,
        456,
      ),
      '2028-02-29T08:00:00Z': DateTime.utc(2028, 2, 29, 8),
    };
    for (final entry in valid.entries) {
      test('history accepts absolute instant ${entry.key}', () async {
        final end = entry.value.add(const Duration(hours: 2));
        final item = _item(1)
          ..['before_started_at'] = entry.key
          ..['before_ended_at'] = end.toIso8601String()
          ..['after_started_at'] = entry.key
          ..['after_ended_at'] = end.toIso8601String()
          ..['requested_at'] = end
              .add(const Duration(hours: 1))
              .toIso8601String()
          ..['accepted_at'] = end
              .add(const Duration(hours: 1, seconds: 1))
              .toIso8601String();
        response = _history([item]);
        final dynamic result = await read();
        final dynamic parsed = result.items.single;
        final actual = <String, DateTime>{
          'before_started_at': parsed.beforeStartedAt as DateTime,
          'before_ended_at': parsed.beforeEndedAt as DateTime,
          'after_started_at': parsed.afterStartedAt as DateTime,
          'after_ended_at': parsed.afterEndedAt as DateTime,
          'requested_at': parsed.requestedAt as DateTime,
          'accepted_at': parsed.acceptedAt as DateTime,
        };
        for (final field in fields) {
          final expected = field.endsWith('started_at')
              ? entry.value
              : field == 'requested_at'
              ? end.add(const Duration(hours: 1))
              : field == 'accepted_at'
              ? end.add(const Duration(hours: 1, seconds: 1))
              : end;
          expect(
            actual[field]!.toUtc().microsecondsSinceEpoch,
            expected.microsecondsSinceEpoch,
            reason: field,
          );
        }
        expectRpc('get_session_corrections');
      });
    }
  });

  group('R6C-3B correction status read', () {
    test('revision zero preserves not_corrected / not_applicable', () async {
      response = _status(revision: 0);
      final dynamic result = await read(status: true);
      expectRpc('get_session_correction_status');
      expect(
        _field('contract', () => result.contract),
        'get_session_correction_status',
      );
      expect(_field('version', () => result.version), 1);
      expect(_field('sessionId', () => result.sessionId), _session);
      expect(
        _field('operationalRevision', () => result.operationalRevision),
        0,
      );
      expect(_field('status', () => result.status), 'not_corrected');
      expect(
        _field('financialStatus', () => result.financialStatus),
        'not_applicable',
      );
      expect(_field('correctionId', () => result.correctionId), isNull);
    });
    for (final state in ['pending', 'applied', 'financial_review_required']) {
      test(
        'explicit corrected state $state is not inferred from history',
        () async {
          response = _status(financial: state);
          final dynamic result = await read(status: true);
          expectRpc('get_session_correction_status');
          expect(
            _field('correctionId', () => result.correctionId),
            'correction-1',
          );
          expect(
            _field('operationalRevision', () => result.operationalRevision),
            1,
          );
          expect(_field('status', () => result.status), state);
          expect(
            _field('financialStatus', () => result.financialStatus),
            state,
          );
          expect(
            _field(
              'financialReviewRequired',
              () => result.financialReviewRequired,
            ),
            state == 'financial_review_required',
          );
          expect(
            _field('financialReviewReason', () => result.financialReviewReason),
            state == 'financial_review_required'
                ? 'يحتاج الأثر المالي إلى مراجعة'
                : null,
          );
        },
      );
    }
    for (final entry in <String, Object?>{
      'contract': 'other',
      'version': 2,
      'session_id': 'foreign-session',
      'operational_revision': -1,
      'status': 'success',
      'financial_status': 'unknown',
      'correction_id': null,
    }.entries) {
      test('rejects invalid status ${entry.key}', () async {
        response = _status()..[entry.key] = entry.value;
        await expectLater(read(status: true), throwsA(isA<FormatException>()));
      });
    }
  });

  for (final status in [false, true]) {
    group(
      status ? 'status authorization/errors' : 'history authorization/errors',
      () {
        test('forbidden remains an error, never empty success', () async {
          httpStatus = 403;
          response = {
            'code': '42501',
            'message': 'permission denied',
            'details': null,
            'hint': null,
          };
          await expectLater(
            read(status: status),
            throwsA(
              isA<PostgrestException>().having((e) => e.code, 'code', '42501'),
            ),
          );
        });
        test(
          'network failure stays distinct from empty and forbidden',
          () async {
            networkFailure = true;
            await expectLater(
              read(status: status),
              throwsA(isA<http.ClientException>()),
            );
          },
        );
      },
    );
  }
}

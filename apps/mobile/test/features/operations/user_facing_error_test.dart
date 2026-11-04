import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:well_irrigation_mobile/core/errors/user_facing_error.dart';

class StorageFailure implements DatabaseException {
  @override
  String toString() =>
      'DatabaseException(SQLITE_ERROR SELECT json_extract CREATE INDEX create index)';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('typed local, network, server and unknown failures have safe Arabic messages', () {
    final cases = <Object, UserFacingErrorCategory>{
      StorageFailure(): UserFacingErrorCategory.localStorage,
      const SocketException('SELECT secret'): UserFacingErrorCategory.network,
      TimeoutException('CREATE INDEX'): UserFacingErrorCategory.network,
      const PostgrestException(message: 'raw SELECT rejected', code: '42501'):
          UserFacingErrorCategory.serverRejection,
      StateError('DatabaseException(fake SQL)'):
          UserFacingErrorCategory.unknown,
    };
    for (final entry in cases.entries) {
      final result = UserFacingError.from(entry.key);
      expect(result.category, entry.value);
      expect(
        result.message,
        isNot(
          contains(
            RegExp(
              r'DatabaseException|SQLITE_ERROR|create index|json_extract|SELECT|CREATE INDEX',
            ),
          ),
        ),
      );
    }
    expect(
      UserFacingError.from(StorageFailure()).message,
      UserFacingError.localStorageMessage,
    );
    expect(
      UserFacingError.from(const SocketException('offline')).message,
      UserFacingError.networkMessage,
    );
  });
}

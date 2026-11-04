import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// Native transport interception must include callbacks and generated batch SQL.
// This test-only adapter uses sqflite's existing locked transitive implementation.
// ignore: depend_on_referenced_packages
import 'package:sqflite_common/src/factory.dart';
// ignore: depend_on_referenced_packages
import 'package:sqflite_common/src/mixin/factory.dart';

/// Intercept native SQL from callbacks, executors, transactions and batches.
/// Bind arguments remain data, never SQL.
DatabaseFactory noJsonSqliteFactory(
  DatabaseFactory delegate, {
  void Function(String)? onSql,
}) {
  final backend = delegate as SqfliteDatabaseFactory;
  return buildDatabaseFactory(
    invokeMethod: (method, [arguments]) async {
      void inspect(Object? value) {
        if (value is! Map) return;
        final sql = value['sql'];
        if (sql is String) {
          rejectJsonSql(sql);
          onSql?.call(sql);
        }
        final operations = value['operations'];
        if (operations is List) {
          for (final operation in operations) {
            inspect(operation);
          }
        }
      }

      inspect(arguments);
      return backend.invokeMethod<Object?>(method, arguments);
    },
  );
}

void rejectJsonSql(String sql) {
  if (RegExp(
    r'\bjson(?:b)?(?:_[a-z_]+)?\s*\(|->',
    caseSensitive: false,
  ).hasMatch(sql)) {
    throw UnsupportedError('Optional SQLite JSON SQL forbidden: $sql');
  }
}

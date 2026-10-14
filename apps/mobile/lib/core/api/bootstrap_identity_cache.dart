import 'dart:convert';

import '../sync/sqlite_outbox_store.dart';
import '../auth/local_auth_account.dart';
import 'app_bootstrap_repository.dart';

/// لقطة قراءة فقط؛ لا تُستخدم لإجازة أي أمر أو اشتقاق صلاحيات جديدة.
class CachedBootstrapIdentity {
  const CachedBootstrapIdentity(this.data, this.fetchedAt, this.sessionId);
  final BootstrapData data;
  final DateTime fetchedAt;
  final String sessionId;
}

class BootstrapIdentityCache {
  BootstrapIdentityCache(this.store);
  final SqliteOutboxStore store;
  static const key = 'bootstrap_identity:v1';

  Future<void> save(LocalAuthAccount auth, BootstrapData data) async {
    if (!auth.canUseOfflineIdentity || data.profile.id != auth.id) {
      throw const FormatException('bootstrap_identity_scope_invalid');
    }
    final payload = {
      'version': 1,
      'account_id': auth.id,
      'session_id': auth.sessionId,
      'fetched_at': DateTime.now().toUtc().toIso8601String(),
      'bootstrap': {
        'profile': {
          'id': data.profile.id,
          'full_name': data.profile.fullName,
          'phone': data.profile.phone,
          'is_platform_admin': data.profile.isPlatformAdmin,
        },
        'wells': [
          for (final well in data.wells)
            {
              'id': well.id,
              'tenant_id': well.tenantId,
              'name': well.name,
              'location': well.location,
              'status': well.status,
              'roles': well.roles,
            },
        ],
      },
    };
    _decode(payload, auth);
    await store.writeLocalValue(auth.id, key, jsonEncode(payload));
  }

  Future<CachedBootstrapIdentity?> load(LocalAuthAccount auth) async {
    if (!auth.canUseOfflineIdentity) return null;
    final raw = await store.readLocalValue(auth.id, key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return _decode(jsonDecode(raw), auth);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> invalidate(String accountId) =>
      store.writeLocalValue(accountId, key, '');

  CachedBootstrapIdentity _decode(Object? raw, LocalAuthAccount auth) {
    if (raw is! Map<String, dynamic> ||
        raw['version'] != 1 ||
        raw['account_id'] != auth.id ||
        raw['session_id'] != auth.sessionId ||
        raw['fetched_at'] is! String ||
        raw['bootstrap'] is! Map<String, dynamic>) {
      throw const FormatException('bootstrap_cache_invalid');
    }
    final data = BootstrapData.fromJson(
      raw['bootstrap'] as Map<String, dynamic>,
    );
    if (data.profile.id != auth.id ||
        data.wells.any(
          (w) =>
              w.id.isEmpty ||
              w.tenantId.isEmpty ||
              w.status.isEmpty ||
              w.roles.isEmpty,
        ) ||
        data.wells.map((w) => w.id).toSet().length != data.wells.length) {
      throw const FormatException('bootstrap_cache_scope_invalid');
    }
    return CachedBootstrapIdentity(
      data,
      DateTime.parse(raw['fetched_at'] as String).toUtc(),
      auth.sessionId!,
    );
  }
}

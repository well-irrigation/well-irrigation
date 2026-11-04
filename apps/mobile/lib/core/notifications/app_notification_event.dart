import 'dart:convert';

/// حدث تسليم محلي مستقل عن مصدره؛ يستطيع مصدر بعيد لاحقًا استخدام الهوية نفسها.
class AppNotificationEvent {
  AppNotificationEvent({
    required this.eventKey,
    required this.accountId,
    this.wellId,
    required this.category,
    required this.eventType,
    required this.entityType,
    this.entityId,
    required this.routeType,
    required Map<String, Object?> routePayload,
    required this.createdAt,
    this.privacyClass = 'private',
    this.presentationPolicy = 'always_silent',
  }) : _routeJson = jsonEncode(routePayload) {
    if (eventKey.isEmpty || accountId.isEmpty) {
      throw ArgumentError('Missing event identity');
    }
  }
  final String eventKey, accountId, category, eventType, entityType, routeType;
  final String? wellId, entityId;
  final String privacyClass, presentationPolicy;
  final DateTime createdAt;
  final String _routeJson;
  Map<String, Object?> get routePayload =>
      Map.unmodifiable(jsonDecode(_routeJson) as Map<String, dynamic>);
  Map<String, Object?> toRow() => {
    'event_key': eventKey,
    'account_id': accountId,
    'well_id': wellId,
    'category': category,
    'event_type': eventType,
    'entity_type': entityType,
    'entity_id': entityId,
    'route_type': routeType,
    'route_payload_json': _routeJson,
    'privacy_class': privacyClass,
    'presentation_policy': presentationPolicy,
    'created_at': createdAt.toUtc().toIso8601String(),
  };
  factory AppNotificationEvent.fromRow(Map<String, Object?> row) =>
      AppNotificationEvent(
        eventKey: row['event_key'] as String,
        accountId: row['account_id'] as String,
        wellId: row['well_id'] as String?,
        category: row['category'] as String,
        eventType: row['event_type'] as String,
        entityType: row['entity_type'] as String,
        entityId: row['entity_id'] as String?,
        routeType: row['route_type'] as String,
        routePayload: Map<String, Object?>.from(
          jsonDecode(row['route_payload_json'] as String) as Map,
        ),
        createdAt: DateTime.parse(row['created_at'] as String),
        privacyClass: row['privacy_class'] as String,
        presentationPolicy: row['presentation_policy'] as String,
      );
}

class NotificationDelivery {
  NotificationDelivery.fromRow(Map<String, Object?> row)
    : localId = row['local_id'] as int,
      event = AppNotificationEvent.fromRow(row),
      attempts = row['attempt_count'] as int;
  final int localId, attempts;
  final AppNotificationEvent event;
}

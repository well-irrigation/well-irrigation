import '../api/operations_repository.dart';

/// لقطة تشغيل مقروءة من الخادم، وليست أحداث pause/complete محلية مصطنعة.
class ServerControlSnapshot {
  ServerControlSnapshot(
    this.sessionId,
    this.wellId,
    this.farmerId,
    this.startedAt,
    this.endedAt,
    this.status,
    this.revision,
    this.segments,
  );
  final String sessionId, wellId, farmerId, status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int revision;
  final List<SessionSegmentItem> segments;

  factory ServerControlSnapshot.fromDetail(SessionDetailData detail) {
    final s = detail.session;
    return ServerControlSnapshot.fromJson({
      'session_id': s.id,
      'well_id': s.wellId,
      'farmer_id': s.farmerAccountId,
      'started_at': s.startedAt.toUtc().toIso8601String(),
      'ended_at': s.endedAt?.toUtc().toIso8601String(),
      'status': s.status,
      'revision': s.operationalRevision,
      'segments': [
        for (final x in detail.segments)
          {
            'sequence': x.sequenceNumber,
            'type': x.segmentType,
            'is_stop': x.isStop,
            'is_billable': x.isBillable,
            'started_at': x.startedAt.toUtc().toIso8601String(),
            'ended_at': x.endedAt?.toUtc().toIso8601String(),
            'energy': x.energySourceCode,
            'rate': x.appliedRateYER,
          },
      ],
    });
  }

  factory ServerControlSnapshot.fromJson(Map<String, dynamic> value) {
    String id(String key) {
      final x = value[key];
      if (x is! String || x.isEmpty || x.trim() != x) {
        throw const FormatException('invalid_control_scope');
      }
      return x;
    }

    DateTime time(Object? raw) {
      if (raw is! String) throw const FormatException('invalid_control_time');
      final t = DateTime.parse(raw);
      if (!t.isUtc || t.toIso8601String() != raw) {
        throw const FormatException('invalid_control_time');
      }
      return t;
    }

    final started = time(value['started_at']);
    final ended = value['ended_at'] == null ? null : time(value['ended_at']);
    if (value['revision'] is! int ||
        (value['revision'] as int) < 0 ||
        !const {'open', 'closed', 'forgotten'}.contains(value['status']) ||
        (value['status'] == 'open') != (ended == null) ||
        ended != null && !ended.isAfter(started) ||
        value['segments'] is! List) {
      throw const FormatException('invalid_control_snapshot');
    }
    final segments = <SessionSegmentItem>[];
    for (final raw in value['segments'] as List) {
      if (raw is! Map<String, dynamic> ||
          raw['sequence'] != segments.length + 1 ||
          raw['is_stop'] is! bool ||
          raw['is_billable'] is! bool ||
          raw['rate'] is! int ||
          (raw['rate'] as int) < 0 ||
          !kSegmentTypeLabels.containsKey(raw['type']) ||
          !const {
            'solar',
            'well_diesel',
            'farmer_diesel',
          }.contains(raw['energy'])) {
        throw const FormatException('invalid_control_segment');
      }
      final at = time(raw['started_at']);
      final end = raw['ended_at'] == null ? null : time(raw['ended_at']);
      if (at != (segments.isEmpty ? started : segments.last.endedAt) ||
          end != null && !end.isAfter(at) ||
          ((raw['type'] as String).endsWith('_run') &&
              (raw['is_stop'] != false || raw['is_billable'] != true)) ||
          (!(raw['type'] as String).endsWith('_run') &&
              raw['is_stop'] != true)) {
        throw const FormatException('invalid_control_timeline');
      }
      segments.add(
        SessionSegmentItem(
          sequenceNumber: raw['sequence'] as int,
          segmentType: raw['type'] as String,
          isStop: raw['is_stop'] as bool,
          isBillable: raw['is_billable'] as bool,
          startedAt: at,
          endedAt: end,
          energySourceCode: raw['energy'] as String,
          appliedRateYER: raw['rate'] as int,
        ),
      );
    }
    if (segments.isEmpty || segments.last.endedAt != ended) {
      throw const FormatException('incomplete_control_timeline');
    }
    return ServerControlSnapshot(
      id('session_id'),
      id('well_id'),
      id('farmer_id'),
      started,
      ended,
      value['status'] as String,
      value['revision'] as int,
      List.unmodifiable(segments),
    );
  }

  Map<String, Object?> toJson() => {
    'session_id': sessionId,
    'well_id': wellId,
    'farmer_id': farmerId,
    'started_at': startedAt.toIso8601String(),
    'ended_at': endedAt?.toIso8601String(),
    'status': status,
    'revision': revision,
    'segments': [
      for (final s in segments)
        {
          'sequence': s.sequenceNumber,
          'type': s.segmentType,
          'is_stop': s.isStop,
          'is_billable': s.isBillable,
          'started_at': s.startedAt.toIso8601String(),
          'ended_at': s.endedAt?.toIso8601String(),
          'energy': s.energySourceCode,
          'rate': s.appliedRateYER,
        },
    ],
  };
}

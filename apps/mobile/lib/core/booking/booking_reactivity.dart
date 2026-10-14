import 'package:flutter/foundation.dart';

import '../session/active_session_record.dart';

/// نطاق عرض واحد. لا مؤقتات ولا قراءات مخزن أو شبكة داخل الإشعار.
class BookingScope extends ChangeNotifier {
  final Map<String, ActiveSessionRecord> sessions = {};
  final Set<String> closedSessionIds = {};
  final Map<String, DateTime> completedBookings = {};
  final Map<String, SessionSyncState> completionSync = {};
  String? nextBookingId;
  bool hasLocalChain = false;
  Set<String>? changedDays;
  bool refreshRequired = false;
  int presentationRevision = 0;
  bool get isMounted => hasListeners;
  int _revision = 0;
  final Map<String, Future<Object?>> _reads = {};

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _revision++;
      _reads.clear();
    }
  }

  static String dayKey(DateTime day) =>
      '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  bool affects(DateTime day) =>
      changedDays == null || changedDays!.contains(dayKey(day));

  /// جميع المستهلكين يشتركون بالطلب نفسه، حتى بعد انتهاء الطلب الأول.
  /// إبطال أثناء الجلب يعيد أحدث جيل؛ لا تُثبّت نتيجة سبقت التعديل.
  Future<T> read<T>(String key, Future<T> Function() fetch) async {
    final revision = _revision;
    if (_reads.length > 8 && !_reads.containsKey(key)) _reads.clear();
    final future = _reads.putIfAbsent(key, () => fetch());
    try {
      final result = await future;
      if (revision != _revision) return await read(key, fetch);
      return result as T;
    } catch (_) {
      if (identical(_reads[key], future)) _reads.remove(key);
      rethrow;
    }
  }

  void mutation({Set<String>? days}) {
    _revision++;
    _reads.clear();
    changedDays = days;
    refreshRequired = true;
    presentationRevision++;
    notifyListeners();
    refreshRequired = false;
  }

  void project(
    Iterable<ActiveSessionRecord> records, {
    String? next,
    bool localChain = false,
    Iterable<String> closed = const [],
  }) {
    final days = <String>{};
    void recordDays(ActiveSessionRecord record) {
      final scheduled = DateTime.tryParse(
        record.bookingContext['scheduled_start']?.toString() ?? '',
      );
      for (final at in [
        scheduled ?? record.startedAt,
        record.startedAt,
        ?record.completedAt,
      ]) {
        days.add(dayKey(at.toUtc().add(const Duration(hours: 3))));
      }
    }

    var changed = hasLocalChain != localChain || nextBookingId != next;
    hasLocalChain = localChain;
    nextBookingId = next;
    for (final id in closed) {
      if (closedSessionIds.add(id)) changed = true;
    }
    for (final record in records) {
      for (final id
          in (record.bookingContext['consumed_booking_ids'] as List? ??
                  const [])
              .whereType<String>()) {
        if (!completedBookings.containsKey(id)) {
          recordDays(record);
          completedBookings[id] = record.startedAt;
          changed = true;
        }
        if (completionSync[id] != record.syncState) {
          recordDays(record);
          completionSync[id] = record.syncState;
          changed = true;
        }
      }
      final id = record.bookingId;
      if (id == null) continue;
      final previous = sessions[id];
      // إكمال مثبت لا يُلغى بإسقاط متأخر أو ACK لبدء الجلسة.
      if (previous?.completedAt != null && record.completedAt == null) continue;
      if (previous == null ||
          previous.businessState != record.businessState ||
          previous.syncState != record.syncState ||
          previous.completedAt != record.completedAt ||
          previous.serverSessionId != record.serverSessionId) {
        recordDays(record);
        sessions[id] = record;
        changed = true;
      }
    }
    if (!changed) return;
    changedDays = days.isEmpty ? null : days;
    refreshRequired = false;
    presentationRevision++;
    notifyListeners();
  }
}

/// الحساب جزء من المفتاح: لا يتسرب عرض جهاز التشغيل لحساب آخر.
class BookingReactivity {
  BookingReactivity._();
  static final instance = BookingReactivity._();
  final Map<(String, String), BookingScope> _scopes = {};
  BookingScope scope(String accountId, String wellId) =>
      _scopes.putIfAbsent((accountId, wellId), BookingScope.new);
}

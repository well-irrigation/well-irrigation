/// جدولة مزيَّفة تسجّل ما طُلب منها.
///
/// وجودها هو ما يجعل سلوك الإرسال الخلفي قابلًا للإثبات على الحاسب: كل
/// ما يهمّنا هو *ماذا طُلب من نظام التشغيل ومتى*، وهذا نصٌّ يُقارَن.
library;

import 'package:well_irrigation_mobile/core/sync/background_sync_scheduler.dart';

class ScheduledSync {
  const ScheduledSync({
    required this.accountId,
    required this.delay,
    required this.attempt,
    required this.replaceExisting,
  });

  final String accountId;
  final Duration? delay;
  final int attempt;
  final bool replaceExisting;

  @override
  String toString() =>
      'ScheduledSync($accountId delay=$delay attempt=$attempt '
      'replace=$replaceExisting)';
}

class FakeBackgroundSyncScheduler implements BackgroundSyncScheduler {
  final List<ScheduledSync> scheduled = [];
  final List<String> cancelled = [];

  @override
  Future<void> scheduleSync(
    String accountId, {
    Duration? delay,
    int attempt = 1,
    bool replaceExisting = false,
  }) async {
    scheduled.add(
      ScheduledSync(
        accountId: accountId,
        delay: delay,
        attempt: attempt,
        replaceExisting: replaceExisting,
      ),
    );
  }

  @override
  Future<void> cancelSync(String accountId) async => cancelled.add(accountId);

  ScheduledSync get last => scheduled.last;

  int get count => scheduled.length;
}

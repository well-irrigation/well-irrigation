import 'core/sync/sqlite_outbox_store.dart';
import 'core/notifications/notification_services.dart';
import 'core/notifications/notification_router.dart';
import 'core/notifications/notification_permission_coordinator.dart';
import 'core/notifications/notification_delivery_coordinator.dart';
import 'core/notifications/operational_notification_event_factory.dart';
import 'core/notifications/local_notification_presenter.dart';
import 'core/api/booking_repository.dart';
import 'core/notifications/operational_notification_scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';
import 'core/session/offline_session_coordinator.dart';
import 'core/sync/background_sync_worker.dart';
import 'core/sync/workmanager_sync_scheduler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    final config = AppConfig.fromEnvironment();

    await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.supabasePublishableKey,
    );

    OfflineSessionCoordinator.configureForegroundSync(Supabase.instance.client);

    // تسجيل نقطة الدخول الخلفية قبل أي جدولة. بلا هذا النداء لا يعرف
    // نظام التشغيل ماذا ينفّذ حين يحلّ موعد الإرسال، فيصمت الإرسال
    // الخلفي بلا خطأ ظاهر (ق-117).
    await WorkmanagerSyncScheduler().initialize(
      backgroundSyncCallbackDispatcher,
    );

    // تهيئة العرض لا تطلب الصلاحية، وفشلها لا يمنع تشغيل التطبيق.
    try {
      final notificationStore = SqliteOutboxStore();
      await notificationStore.initialize();
      final events=notificationStore.notificationEvents;
      final router=NotificationRouter(load:events.eventById);
      final presenter=LocalNotificationPresenter(onTap:router.acceptPayload);
      final scheduling=OperationalNotificationScheduler(store:events,presenter:presenter,isAccountActive:(account)=>Supabase.instance.client.auth.currentSession?.user.id==account,requestOpportunity:(account)=>WorkmanagerSyncScheduler().scheduleSync(account,delay:const Duration(minutes:1)));
      NotificationServices.current=NotificationServices(
        delivery:NotificationDeliveryCoordinator(store:events,presenter:presenter,policies:appNotificationPolicies,scheduledCleanup:scheduling.cancelPending,isAccountActive:(account)=>Supabase.instance.client.auth.currentSession?.user.id==account),
        scheduling:scheduling,
        recoverSchedules:(account,well)=>BookingRepository().recoverNotificationSchedules(account,well),
        permission:NotificationPermissionCoordinator(gateway:presenter,wasExplained:events.rationaleSeen,markExplained:events.markRationaleSeen),
        router:router,
      );
      await presenter.initialize();
      router.acceptPayload(await presenter.launchPayload());
    } catch (_) {
      // الأحداث محفوظة؛ العامل/الفرصة التالية يعيدان محاولة العرض فقط.
    }
    runApp(WellIrrigationApp(config: config));
  } catch (error) {
    runApp(ConfigurationFailureApp(message: error.toString()));
  }
}

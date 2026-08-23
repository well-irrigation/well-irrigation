import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';
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

    // تسجيل نقطة الدخول الخلفية قبل أي جدولة. بلا هذا النداء لا يعرف
    // نظام التشغيل ماذا ينفّذ حين يحلّ موعد الإرسال، فيصمت الإرسال
    // الخلفي بلا خطأ ظاهر (ق-117).
    await WorkmanagerSyncScheduler().initialize(
      backgroundSyncCallbackDispatcher,
    );

    runApp(WellIrrigationApp(config: config));
  } catch (error) {
    runApp(ConfigurationFailureApp(message: error.toString()));
  }
}

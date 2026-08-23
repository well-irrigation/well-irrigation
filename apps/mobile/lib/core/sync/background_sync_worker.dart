/// نقطة الدخول التي ينادِيها نظام التشغيل بلا فتح التطبيق.
///
/// هذه الدالة تعمل في عملية (isolate) مستقلّة تمامًا: لا شاشة، ولا
/// حالة تطبيق، ولا شيء مما هُيِّئ في `main()`. لذلك تُبنى الاعتماديات
/// كلها من الصفر هنا — إعداد، ثم جلسة Supabase من التخزين الدائم، ثم
/// **نفس ملف** الطابور الذي يكتب فيه التطبيق.
///
/// `@pragma('vm:entry-point')` إلزامي: بلا هذه العلامة يحذف مُحسِّن
/// البناء في وضع الإصدار دالةً لا ينادِيها كود Dart ظاهريًا، فيعمل
/// التطبيق في التطوير ويصمت الإرسال الخلفي في يد المستخدم.
///
/// قيمة الإرجاع هي كل الحوار مع النظام:
/// - `true` = انتهيت، لا تُعِد إيقاظي.
/// - `false` = أعِد جدولتي بالتراجع الأُسّي المسجَّل مع العمل.
library;

import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:workmanager/workmanager.dart';

import '../config/app_config.dart';
import 'background_sync_coordinator.dart';
import 'background_sync_policy.dart';
import 'background_sync_scheduler.dart';
import 'outbox_database.dart';
import 'sqlite_outbox_store.dart';
import 'supabase_command_transport.dart';
import 'sync_engine.dart';
import 'workmanager_sync_scheduler.dart';

/// هل هُيِّئ Supabase في *هذه* العملية؟
///
/// المتغيّر ساكن داخل العملية، والعملية الخلفية جديدة في كل استدعاء
/// تقريبًا. النداء الثاني لـ`Supabase.initialize` يرمي، فيُحفظ الحال هنا
/// بدل الاعتماد على `assert` يُلغى في وضع الإصدار.
bool _supabaseReady = false;

@pragma('vm:entry-point')
void backgroundSyncCallbackDispatcher() {
  Workmanager().executeTask(runBackgroundSyncTask);
}

/// المعالج نفسه، مكشوفًا كي يُقرأ ويُراجع مستقلًّا عن الغلاف.
@pragma('vm:entry-point')
Future<bool> runBackgroundSyncTask(
  String taskName,
  Map<String, dynamic>? inputData,
) async {
  if (taskName != backgroundSyncTaskName) {
    // مهمة لا نعرفها. إعادة جدولتها إلى الأبد بلا معالج لن تُنجز شيئًا.
    return true;
  }

  final accountId = (inputData?[backgroundSyncAccountKey] as String?)?.trim();

  if (accountId == null || accountId.isEmpty) {
    // طلبٌ بلا حساب: عيب برمجي لا يصلحه تكرار. نُنهيه بهدوء، والإرسال
    // يجري في المرة القادمة التي يفتح فيها المستخدم التطبيق.
    return true;
  }

  final attempt = switch (inputData?[backgroundSyncAttemptKey]) {
    final int value when value > 0 => value,
    _ => 1,
  };

  SqliteOutboxStore? store;

  try {
    if (!_supabaseReady) {
      final config = AppConfig.fromEnvironment();

      await Supabase.initialize(
        url: config.supabaseUrl,
        publishableKey: config.supabasePublishableKey,
      );

      _supabaseReady = true;
    }

    store = SqliteOutboxStore(databasePath: await resolveOutboxDatabasePath());
    await store.initialize();

    final coordinator = BackgroundSyncCoordinator(
      engine: SyncEngine(
        store: store,
        transport: SupabaseCommandTransport(Supabase.instance.client),
      ),
      scheduler: WorkmanagerSyncScheduler(),
    );

    final decision = await coordinator.runFromWorker(
      accountId,
      attempt: attempt,
    );

    return !decision.shouldRetry;
  } on DatabaseException {
    // الملف مقفول لأن التطبيق يكتب فيه الآن، أو القرص ممتلئ. عابر:
    // العمليات كلها ما زالت على القرص، والمحاولة القادمة تجدها.
    return false;
  } catch (_) {
    // سببٌ غير متوقَّع. القاعدة هنا مقصودة: **نُعيد المحاولة** لا نستسلم.
    // في الطابور مبالغ سقيٍ فعلية لمزارعين؛ إسقاطها بصمت خسارة نقدية،
    // وتكرارها بتراجع أُسّي أسوأ ما فيه تأخير.
    return false;
  } finally {
    await store?.close();
  }
}

/// السياسة المستخدمة في العامل — مكشوفة للاختبار والتوثيق.
const BackgroundSyncPolicy backgroundSyncWorkerPolicy = BackgroundSyncPolicy();

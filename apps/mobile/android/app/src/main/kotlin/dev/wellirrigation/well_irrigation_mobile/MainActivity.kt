package dev.wellirrigation.well_irrigation_mobile

import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "well_irrigation/time_integrity")
      .setMethodCallHandler { call, result ->
        if (call.method != "readTimeIntegrity") {
          result.notImplemented()
          return@setMethodCallHandler
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
          result.error("unsupported", "BOOT_COUNT requires Android API 24", null)
          return@setMethodCallHandler
        }
        val bootCount = try {
          Settings.Global.getInt(contentResolver, Settings.Global.BOOT_COUNT)
        } catch (e: Exception) {
          result.error("unavailable", "BOOT_COUNT read failed: ${e.javaClass.simpleName}", null)
          return@setMethodCallHandler
        }
        if (bootCount < 0) {
          result.error("unavailable", "BOOT_COUNT unavailable", null)
          return@setMethodCallHandler
        }
        // القراءة الثلاث في invocation واحدة: فجوة بينها أجزاء من الثانية،
        // وفصلها يفتح باب نافذة زمنية بين ساعة وعداد.
        result.success(mapOf(
          "wall_clock_ms" to System.currentTimeMillis(),
          "elapsed_realtime_ms" to SystemClock.elapsedRealtime(),
          "boot_count" to bootCount,
        ))
      }
  }
}

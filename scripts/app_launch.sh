#!/bin/sh
# =====================================================================
# تشغيل التطبيق على جهاز حقيقي، أو بناء ملف تثبيت للتوزيع
#
#   sh scripts/app_launch.sh run   ← جهاز موصول بكبل، وسجل حيّ للأخطاء
#   sh scripts/app_launch.sh apk   ← ملف تثبيت يُنقل إلى أي هاتف
#
# القيمتان تُقرآن من apps/mobile/.env (غير متعقَّب). قالبه `.env.example`.
# ولا تُطبعان في أي مخرَج.
#
# لماذا `run` أولًا: أول تشغيل لتطبيق على جهاز يكشف ما لا يكشفه اختبار،
# وبلا سجل حيّ يظهر الفشل شاشةً بيضاء بلا سبب. وملف التثبيت هو ما يُوزَّع
# على المشغّلين فعلًا، فتجربته تجربة لطريقة التوزيع نفسها.
#
# و`run` يكتب سجله في `.wi-live/app-run.log` داخل المستودع ويعرضه على
# الشاشة معًا: المالك يرى ما يجري، والمساعد يقرأ الملف بلا أن يُلصق أحد
# سطرًا — وهذا ما يجعل جلسة الفحص المشتركة ممكنة.
# =====================================================================

set -u

mode=${1:-run}
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_dir="$root/apps/mobile"
env_file="$app_dir/.env"

[ -d "$app_dir" ] || { echo "ERROR: لا يوجد $app_dir" >&2; exit 2; }

if [ ! -f "$env_file" ]; then
  echo "ERROR: الملف غير موجود: apps/mobile/.env" >&2
  echo "انسخ apps/mobile/.env.example إليه ثم عبّئ القيمتين." >&2
  exit 2
fi

# القراءة سطرًا سطرًا بلا تنفيذ للملف: ملف قيم لا سكربت.
SUPABASE_URL=$(sed -n 's/^SUPABASE_URL=//p' "$env_file" | head -n 1)
SUPABASE_PUBLISHABLE_KEY=$(sed -n 's/^SUPABASE_PUBLISHABLE_KEY=//p' "$env_file" | head -n 1)

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_PUBLISHABLE_KEY" ]; then
  echo "ERROR: قيمة ناقصة في apps/mobile/.env" >&2
  echo "URL_SET=$([ -n "$SUPABASE_URL" ] && echo yes || echo no)" >&2
  echo "KEY_SET=$([ -n "$SUPABASE_PUBLISHABLE_KEY" ] && echo yes || echo no)" >&2
  exit 2
fi

# العنوان يُطبع لأنه ليس سرًّا وخطأُ توجيهٍ صامت أغلى: أن يعمل التطبيق على
# قاعدة غير المقصودة أسوأ من ألّا يعمل. والمفتاح لا يُطبع.
echo "TARGET=$SUPABASE_URL"
echo "KEY=SET (لا يُطبع)"
echo "MODE=$mode"

defines="--dart-define=SUPABASE_URL=$SUPABASE_URL"
defines="$defines --dart-define=SUPABASE_PUBLISHABLE_KEY=$SUPABASE_PUBLISHABLE_KEY"

case "$mode" in
  run)
    # السجل يُكتب داخل المستودع في `.wi-live/` (غير متعقَّب) لا في مجلد
    # مؤقت: `${TMPDIR}` يختلف بين المالك والمساعد — فمجلد `/tmp` الذي يكتب
    # فيه المالك **غير مرئي** للمساعد في بيئته المعزولة. مُقيس في
    # 2026-09-04، ولولا قياسه لكانت القناة «تعمل» في الوصف وفارغةً فعلًا:
    # مساعدٌ يقرأ ملفًا غير موجود يستنتج «لا جديد» — غياب كاذب (ق-113).
    log_dir="$root/.wi-live"
    mkdir -p "$log_dir" || exit 2
    run_log="$log_dir/app-run.log"
    : > "$run_log"
    echo "LOG=$run_log"

    # الأجهزة الموصولة تُعرض أولًا: بلا جهاز يفشل الأمر برسالة غامضة.
    (cd "$app_dir" && flutter --no-version-check devices) 2>&1 | tee -a "$run_log"
    echo "===== يبدأ التشغيل. أوقفه بحرف q في هذه النافذة ====="
    # shellcheck disable=SC2086
    (cd "$app_dir" && flutter --no-version-check run $defines) 2>&1 | tee -a "$run_log"
    ;;
  apk)
    # shellcheck disable=SC2086
    (cd "$app_dir" && flutter --no-version-check build apk --release $defines)
    status=$?
    apk="$app_dir/build/app/outputs/flutter-apk/app-release.apk"
    if [ "$status" -eq 0 ] && [ -f "$apk" ]; then
      echo "APK=$apk"
      echo "SIZE=$(du -h "$apk" | cut -f1)"
      echo "RESULT=SUCCESS"
    else
      echo "RESULT=FAILED" >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: الوضع غير معروف: $mode (المتاح: run أو apk)" >&2
    exit 2
    ;;
esac

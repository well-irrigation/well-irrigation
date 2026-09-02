#!/bin/sh
# c:app — فحص كود التطبيق: analyze ثم test، وملخّص قصير في النهاية.
# لا يلمس قاعدة البيانات ولا الشبكة ولا تاريخ المستودع.
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_dir="$root/apps/mobile"
log_dir="${TMPDIR:-/tmp}/wi-checks"
mkdir -p "$log_dir" || exit 2
analyze_log="$log_dir/app-analyze.log"
test_log="$log_dir/app-test.log"
pubget_log="$log_dir/app-pubget.log"

[ -d "$app_dir" ] || { printf 'RESULT=FAILED missing=%s\n' "$app_dir"; exit 2; }

# اختيار طريقة النداء: الأمر العادي إن عمل، وإلا صورة الأداة مباشرة.
# البيئة المقيَّدة لا تسمح بالكتابة في bin/cache، فتفشل الطريقة العادية.
flutter_root=${FLUTTER_ROOT:-}
if [ -z "$flutter_root" ]; then
  fbin=$(command -v flutter 2>/dev/null || true)
  if [ -n "$fbin" ]; then
    flutter_root=$(CDPATH= cd -- "$(dirname -- "$fbin")/.." && pwd)
  fi
fi
[ -z "$flutter_root" ] && flutter_root=/home/kali/development/flutter

mode=direct
if command -v flutter >/dev/null 2>&1; then
  if (cd "$app_dir" && flutter --version) >/dev/null 2>&1; then
    mode=cli
  fi
fi

run_flutter() {
  # `--no-version-check` عالمي ويسبق الأمر. بدونه تحاول الأداة كتابة
  # `flutter_version_check.stamp` داخل SDK للقراءة فقط فتسقط بانهيار،
  # فيُقرأ الانهيار كأنه فشل تحليل. الفشل المُلفَّق في أداة التحقق نفسه
  # ممنوع كالفشل المُلفَّق في الشاشة (ق-113).
  if [ "$mode" = cli ]; then
    (cd "$app_dir" && flutter --no-version-check "$@")
  else
    (
      cd "$app_dir" || exit 2
      HOME="$log_dir/fakehome"
      export HOME
      mkdir -p "$HOME" || exit 2
      PUB_CACHE=${PUB_CACHE:-/home/kali/.pub-cache}
      export PUB_CACHE
      FLUTTER_ROOT=$flutter_root
      export FLUTTER_ROOT
      FLUTTER_ALREADY_LOCKED=true
      export FLUTTER_ALREADY_LOCKED
      "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" --disable-dart-dev \
        "$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot" \
        --no-version-check "$@"
    )
  fi
}

# ---------- 0) تهيئة الحزم عند الحاجة ----------
# مجلد عمل جديد لا يحمل .dart_tool لأنه غير متعقَّب، فتُبنى مرة واحدة
# من الحزم المحلية بلا شبكة. وجودها يعني تخطّي الخطوة كلها.
pubget_state=SKIPPED
pubget_detail='package-config-present'
if [ ! -f "$app_dir/.dart_tool/package_config.json" ]; then
  run_flutter pub get --offline > "$pubget_log" 2>&1
  if [ -f "$app_dir/.dart_tool/package_config.json" ]; then
    pubget_state=OK
    pubget_detail='offline-resolve'
  else
    pubget_state=FAIL
    pubget_detail='offline-resolve-failed'
  fi
fi

if [ "$pubget_state" = FAIL ]; then
  printf 'MODE=%s\n' "$mode"
  printf 'STEP 0 pub get  %-8s %s\n' "$pubget_state" "$pubget_detail"
  first=$(grep -m1 -E 'Error|error:|Failed' "$pubget_log" | cut -c1-160)
  [ -n "$first" ] && printf '       first-error: %s\n' "$first"
  printf 'LOGS=%s\n' "$log_dir"
  printf 'RESULT=FAILED_AT=0\n'
  exit 1
fi

# ---------- 0ب) بذر أصل sqlite3 المبني ----------
# حزمة sqlite3 تُنزّل مكتبة مبنية من GitHub عند أول بناء. مجلد العمل الجديد
# لا يحمل مخزنها، وبيئة بلا وصول إلى GitHub تعجز عن بنائه، فلا تُشتق أي
# نتيجة اختبار أصلًا. النسخة المبنية في المستودع الأصلي مخزَّنة بمخزن
# مُعنون بالمصدر، فإن وُجدت تُنسخ وإلا بقيت الحالة معلنة كما هي (ق-113).
seed_state=SKIPPED
seed_detail='shared-cache-present'
shared_dir="$app_dir/.dart_tool/hooks_runner/shared"
if [ ! -d "$shared_dir" ]; then
  main_root=$(git -C "$root" rev-parse --path-format=absolute \
    --git-common-dir 2>/dev/null || true)
  main_shared=''
  if [ -n "$main_root" ]; then
    main_shared="$(dirname -- "$main_root")/apps/mobile/.dart_tool/hooks_runner/shared"
  fi
  if [ -n "$main_shared" ] && [ -d "$main_shared" ]; then
    mkdir -p "$(dirname -- "$shared_dir")" 2>/dev/null || true
    if cp -a "$main_shared" "$shared_dir" 2>/dev/null; then
      seed_state=OK
      seed_detail='copied-from-main-checkout'
    else
      seed_state=FAIL
      seed_detail='copy-failed'
    fi
  else
    seed_state=MISSING
    seed_detail='no-main-checkout-cache'
  fi
fi

# ---------- 1) analyze ----------
run_flutter analyze --no-pub > "$analyze_log" 2>&1
analyze_status=$?

if grep -q 'No issues found' "$analyze_log"; then
  analyze_state=OK
  analyze_detail='issues=0'
else
  found=$(sed -n 's/^\([0-9]\{1,\}\) issue[s]* found.*/\1/p' "$analyze_log" | tail -n 1)
  if [ -n "$found" ]; then
    analyze_state=FAIL
    analyze_detail="issues=$found"
  elif [ "$analyze_status" -ne 0 ]; then
    analyze_state=FAIL
    analyze_detail='issues=? tool-error'
  else
    analyze_state=UNKNOWN
    analyze_detail='no-summary-line'
  fi
fi

# ---------- 2) test ----------
has_errors=no
grep -q ' error • ' "$analyze_log" && has_errors=yes

test_hint=''
if [ "$has_errors" = yes ]; then
  test_state=SKIPPED
  test_detail='analyze-has-errors'
  test_status=0
else
  run_flutter test --no-pub > "$test_log" 2>&1
  test_status=$?

  # حالة معروفة ومنفصلة عن جودة الكود: حزمة sqlite3 تبني أصلًا أصيلًا
  # بتنزيل ملف من GitHub. مجلد عمل جديد لا يحمله، وبيئة بلا وصول إلى
  # GitHub تعجز عن بنائه. ليست نتيجة اختبار، فلا تُقرأ كفشل اختبار.
  if grep -q 'Building native assets failed' "$test_log"; then
    test_state=BLOCKED
    test_detail='native-assets-need-network'
    test_hint='run c:app once where GitHub is reachable, then it is cached here'
  else
    sum_line=$(grep -E 'All tests passed!|Some tests failed' "$test_log" | tail -n 1)
    pass=$(printf '%s\n' "$sum_line" | sed -n 's/.*+\([0-9]\{1,\}\).*/\1/p')
    fail=$(printf '%s\n' "$sum_line" | sed -n 's/.* -\([0-9]\{1,\}\).*/\1/p')
    [ -z "$pass" ] && pass='?'
    [ -z "$fail" ] && fail=0
    test_detail="PASS=$pass FAIL=$fail"

    if [ "$test_status" -eq 0 ] && printf '%s' "$sum_line" | grep -q 'All tests passed!'; then
      test_state=OK
    elif [ "$test_status" -ne 0 ]; then
      test_state=FAIL
    else
      test_state=UNKNOWN
      test_detail="$test_detail no-summary-line"
    fi
  fi
fi

# ---------- 3) الملخّص ----------
printf 'MODE=%s\n' "$mode"
printf 'STEP 0 pub get  %-8s %s\n' "$pubget_state" "$pubget_detail"
printf 'STEP 0 sqlite3  %-8s %s\n' "$seed_state" "$seed_detail"
printf 'STEP 1 analyze  %-8s %s\n' "$analyze_state" "$analyze_detail"
printf 'STEP 2 test     %-8s %s\n' "$test_state" "$test_detail"

if [ "$analyze_state" != OK ]; then
  first=$(grep -m1 -E '^[[:space:]]*(error|warning|info) • ' "$analyze_log" | cut -c1-160)
  [ -n "$first" ] && printf '       first-issue: %s\n' "$first"
fi

if [ "$test_state" = BLOCKED ]; then
  printf '       cause: sqlite3 downloads a prebuilt library on first build\n'
  [ -n "$test_hint" ] && printf '       fix:   %s\n' "$test_hint"
fi

if [ "$test_state" = FAIL ] || [ "$test_state" = UNKNOWN ]; then
  first=$(grep -m1 '\[E\]' "$test_log" | cut -c1-160)
  [ -n "$first" ] && printf '       first-fail: %s\n' "$first"
  first=$(grep -m1 -E '^(Error|Exception|Unhandled)' "$test_log" | cut -c1-160)
  [ -n "$first" ] && printf '       tool-error: %s\n' "$first"
fi

printf 'LOGS=%s\n' "$log_dir"

if [ "$analyze_state" = OK ] && [ "$test_state" = OK ]; then
  printf 'RESULT=SUCCESS\n'
  exit 0
fi
if [ "$analyze_state" != OK ]; then
  printf 'RESULT=FAILED_AT=1\n'
  exit 1
fi
if [ "$test_state" = BLOCKED ]; then
  printf 'RESULT=BLOCKED_AT=2\n'
  exit 3
fi
printf 'RESULT=FAILED_AT=2\n'
exit 1

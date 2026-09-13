#!/usr/bin/env bash
# تشغيل التطبيق على هاتف Android حقيقي، أو بناء ملف التثبيت.
# القيم تُقرأ من apps/mobile/.env بلا تنفيذ الملف أو طباعة المفتاح.

set -u

mode=${1:-run}
case "$mode" in
  run|apk) ;;
  *)
    printf 'ERROR: الوضع غير معروف: %s (المتاح: run أو apk)\n' "$mode" >&2
    exit 2
    ;;
esac

script_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
root=${WI_ROOT:-$script_root}
app_dir="$root/apps/mobile"
env_file="$app_dir/.env"
flutter_bin=${FLUTTER_BIN:-flutter}
adb_bin=${ADB_BIN:-adb}
python_bin=${PYTHON_BIN:-python3}

blocked_config() {
  printf 'STEP 0 config  BLOCKED  %s\n' "$1" >&2
  printf 'RESULT=BLOCKED_AT=0\n' >&2
  exit 3
}

[ -d "$app_dir" ] || blocked_config "missing=$app_dir"
[ -f "$env_file" ] || blocked_config 'missing=apps/mobile/.env'
command -v "$flutter_bin" >/dev/null 2>&1 \
  || blocked_config 'flutter-not-found'

SUPABASE_URL=$(sed -n 's/^SUPABASE_URL=//p' "$env_file" | head -n 1)
SUPABASE_PUBLISHABLE_KEY=$(
  sed -n 's/^SUPABASE_PUBLISHABLE_KEY=//p' "$env_file" | head -n 1
)

if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_PUBLISHABLE_KEY" ]; then
  printf 'URL_SET=%s\n' "$([ -n "$SUPABASE_URL" ] && printf yes || printf no)" >&2
  printf 'KEY_SET=%s\n' "$([ -n "$SUPABASE_PUBLISHABLE_KEY" ] && printf yes || printf no)" >&2
  blocked_config 'missing-env-value'
fi

defines=(
  "--dart-define=SUPABASE_URL=$SUPABASE_URL"
  "--dart-define=SUPABASE_PUBLISHABLE_KEY=$SUPABASE_PUBLISHABLE_KEY"
)

if [ "$mode" = apk ]; then
  printf 'TARGET=%s\n' "$SUPABASE_URL"
  printf 'KEY=SET (لا يُطبع)\n'
  printf 'MODE=apk\n'
  if (cd "$app_dir" && "$flutter_bin" --no-version-check \
      build apk --release "${defines[@]}"); then
    apk="$app_dir/build/app/outputs/flutter-apk/app-release.apk"
    if [ -f "$apk" ]; then
      printf 'APK=%s\n' "$apk"
      printf 'SIZE=%s\n' "$(du -h "$apk" | cut -f1)"
      printf 'RESULT=SUCCESS\n'
      exit 0
    fi
  fi
  printf 'RESULT=FAILED_AT=BUILD\n' >&2
  exit 1
fi

log_dir="$root/.wi-live"
mkdir -p "$log_dir" || blocked_config 'log-directory-unavailable'
chmod 700 "$log_dir" 2>/dev/null || true
run_log="$log_dir/app-run.log"
: > "$run_log" || blocked_config 'log-file-unavailable'
chmod 600 "$run_log" 2>/dev/null || true

log_line() {
  printf '%s\n' "$1" | tee -a "$run_log"
}

finish() {
  local status=$1
  local result=$2
  log_line "RESULT=$result"
  exit "$status"
}

log_line "STARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log_line "TARGET=$SUPABASE_URL"
log_line 'KEY=SET (لا يُطبع)'
log_line 'MODE=run'
log_line "LOG=$run_log"

if ! command -v "$adb_bin" >/dev/null 2>&1; then
  log_line 'STEP 1 device  BLOCKED  adb-not-found'
  finish 3 'BLOCKED_AT=1'
fi

adb_output=$($adb_bin devices -l 2>&1)
adb_status=$?
printf '%s\n' "$adb_output" >> "$run_log"
if [ "$adb_status" -ne 0 ]; then
  log_line 'STEP 1 device  BLOCKED  adb-failed'
  finish 3 'BLOCKED_AT=1'
fi

selection=$(
  printf '%s\n' "$adb_output" | "$python_bin" -c '
import re
import sys

ready = []
blocked = []
for raw in sys.stdin:
    line = raw.strip()
    if not line or line.startswith("List of devices") or line.startswith("*"):
        continue
    fields = line.split()
    if len(fields) < 2:
        continue
    serial, state = fields[0], fields[1]
    if serial.startswith("emulator-") or re.fullmatch(r"[0-9.]+:[0-9]+", serial):
        continue
    if state == "device":
        ready.append(serial)
    elif state in {"unauthorized", "offline"}:
        blocked.append(state)
if len(ready) == 1 and not blocked:
    print("READY", ready[0])
elif len(ready) > 1:
    print("BLOCKED multiple-real-devices")
elif blocked:
    print("BLOCKED device-" + blocked[0])
else:
    print("BLOCKED no-real-device")
'
)
selection_status=$?
if [ "$selection_status" -ne 0 ]; then
  log_line 'STEP 1 device  BLOCKED  device-parser-failed'
  finish 3 'BLOCKED_AT=1'
fi

selection_state=${selection%% *}
selection_value=${selection#* }
if [ "$selection_state" != READY ]; then
  log_line "STEP 1 device  BLOCKED  $selection_value"
  finish 3 'BLOCKED_AT=1'
fi
device_serial=$selection_value
log_line "STEP 1 device  OK       serial=$device_serial"

devices_log=$(mktemp "${TMPDIR:-/tmp}/wi-devices.XXXXXX") \
  || blocked_config 'temporary-log-unavailable'
trap 'rm -f "$devices_log"' EXIT
if ! (cd "$app_dir" && "$flutter_bin" --no-version-check devices \
    > "$devices_log" 2>&1); then
  tee -a "$run_log" < "$devices_log"
  log_line 'STEP 2 flutter BLOCKED  device-discovery-failed'
  finish 3 'BLOCKED_AT=2'
fi
tee -a "$run_log" < "$devices_log"
if ! grep -Fq "$device_serial" "$devices_log"; then
  log_line 'STEP 2 flutter BLOCKED  selected-device-not-visible'
  finish 3 'BLOCKED_AT=2'
fi
log_line 'STEP 2 flutter OK       selected-device-visible'
log_line 'STEP 3 run     STARTED  أوقفه بحرف q في هذه النافذة'

set +e
(cd "$app_dir" && "$flutter_bin" --no-version-check run \
  -d "$device_serial" "${defines[@]}") 2>&1 | tee -a "$run_log"
run_status=${PIPESTATUS[0]}
set -e

if [ "$run_status" -eq 0 ]; then
  log_line 'STEP 3 run     OK       session-ended'
  finish 0 'SUCCESS'
fi
log_line "STEP 3 run     FAILED   exit=$run_status"
finish 1 'FAILED_AT=3'

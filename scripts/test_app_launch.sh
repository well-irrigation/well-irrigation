#!/usr/bin/env bash
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script="$root/scripts/app_launch.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/wi-app-launch-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

new_case() {
  case_dir="$tmp/$1"
  mkdir -p "$case_dir/apps/mobile" "$case_dir/bin"
  printf '%s\n' \
    'SUPABASE_URL=https://test.invalid' \
    'SUPABASE_PUBLISHABLE_KEY=test-key-do-not-print' \
    > "$case_dir/apps/mobile/.env"
  args_file="$case_dir/flutter.args"
  output_file="$case_dir/output.log"
}

write_mocks() {
  cat > "$case_dir/bin/adb" <<'MOCK'
#!/usr/bin/env bash
printf 'List of devices attached\n'
printf '%b' "${MOCK_ADB_LINES:-}"
exit "${MOCK_ADB_EXIT:-0}"
MOCK
  cat > "$case_dir/bin/flutter" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_ARGS_FILE"
if [[ " $* " == *" devices "* ]]; then
  printf '%b' "${MOCK_FLUTTER_DEVICES:-}"
  exit "${MOCK_DEVICES_EXIT:-0}"
fi
if [[ " $* " == *" run "* ]]; then
  exit "${MOCK_RUN_EXIT:-0}"
fi
if [[ " $* " == *" build apk "* ]]; then
  mkdir -p build/app/outputs/flutter-apk
  : > build/app/outputs/flutter-apk/app-release.apk
  exit "${MOCK_BUILD_EXIT:-0}"
fi
exit 0
MOCK
  chmod +x "$case_dir/bin/adb" "$case_dir/bin/flutter"
}

run_case() {
  local expected_status=$1
  shift
  set +e
  env PATH="$case_dir/bin:$PATH" \
    WI_ROOT="$case_dir" \
    FLUTTER_BIN=flutter \
    ADB_BIN=adb \
    MOCK_ARGS_FILE="$args_file" \
    "$@" \
    bash "$script" run > "$output_file" 2>&1
  actual_status=$?
  set -e
  if [ "$actual_status" -ne "$expected_status" ]; then
    printf 'FAIL %-24s status=%s expected=%s\n' \
      "$(basename "$case_dir")" "$actual_status" "$expected_status"
    fail=$((fail + 1))
    return 1
  fi
}

run_apk_case() {
  local expected_status=$1
  shift
  set +e
  env PATH="$case_dir/bin:$PATH" \
    WI_ROOT="$case_dir" \
    FLUTTER_BIN=flutter \
    ADB_BIN=adb \
    MOCK_ARGS_FILE="$args_file" \
    "$@" \
    bash "$script" apk > "$output_file" 2>&1
  actual_status=$?
  set -e
  if [ "$actual_status" -ne "$expected_status" ]; then
    printf 'FAIL %-24s status=%s expected=%s\n' \
      "$(basename "$case_dir")" "$actual_status" "$expected_status"
    fail=$((fail + 1))
    return 1
  fi
}

assert_output() {
  local expected=$1
  if grep -Fq -- "$expected" "$output_file"; then
    return 0
  fi
  printf 'FAIL %-24s missing-output=%s\n' \
    "$(basename "$case_dir")" "$expected"
  fail=$((fail + 1))
  return 1
}

assert_args() {
  local expected=$1
  if grep -Fq -- "$expected" "$args_file"; then
    return 0
  fi
  printf 'FAIL %-24s missing-arg=%s\n' \
    "$(basename "$case_dir")" "$expected"
  fail=$((fail + 1))
  return 1
}

complete_case() {
  printf 'PASS %s\n' "$(basename "$case_dir")"
  pass=$((pass + 1))
}

new_case one-real-device
write_mocks
run_case 0 \
  MOCK_ADB_LINES=$'phone-123 device product:p model:Test transport_id:1\n' \
  MOCK_FLUTTER_DEVICES=$'Test (mobile) • phone-123 • android-arm64 • Android 14\n' \
  || true
if [ "$actual_status" -eq 0 ] \
  && assert_output 'RESULT=SUCCESS' \
  && assert_args 'run -d phone-123' \
  && ! grep -Fq 'test-key-do-not-print' "$output_file"; then
  complete_case
fi

new_case no-real-device
write_mocks
run_case 3 \
  MOCK_ADB_LINES='' \
  || true
if [ "$actual_status" -eq 3 ] \
  && assert_output 'BLOCKED  no-real-device' \
  && assert_output 'RESULT=BLOCKED_AT=1'; then
  complete_case
fi

new_case unauthorized-device
write_mocks
run_case 3 \
  MOCK_ADB_LINES=$'phone-123 unauthorized usb:1-1 transport_id:1\n' \
  || true
if [ "$actual_status" -eq 3 ] \
  && assert_output 'BLOCKED  device-unauthorized'; then
  complete_case
fi

new_case multiple-devices
write_mocks
run_case 3 \
  MOCK_ADB_LINES=$'phone-1 device model:One\nphone-2 device model:Two\n' \
  || true
if [ "$actual_status" -eq 3 ] \
  && assert_output 'BLOCKED  multiple-real-devices'; then
  complete_case
fi

new_case run-failure
write_mocks
run_case 1 \
  MOCK_ADB_LINES=$'phone-123 device model:Test\n' \
  MOCK_FLUTTER_DEVICES=$'Test • phone-123 • android-arm64 • Android 14\n' \
  MOCK_RUN_EXIT=17 \
  || true
if [ "$actual_status" -eq 1 ] \
  && assert_output 'STEP 3 run     FAILED   exit=17' \
  && assert_output 'RESULT=FAILED_AT=3'; then
  complete_case
fi

new_case apk-success
write_mocks
run_apk_case 0 || true
if [ "$actual_status" -eq 0 ] \
  && assert_output 'RESULT=SUCCESS' \
  && assert_args 'build apk --release' \
  && ! grep -Fq 'test-key-do-not-print' "$output_file"; then
  complete_case
fi

printf 'PASS_COUNT=%s FAIL_COUNT=%s\n' "$pass" "$fail"
if [ "$fail" -eq 0 ] && [ "$pass" -eq 6 ]; then
  printf 'RESULT=SUCCESS\n'
  exit 0
fi
printf 'RESULT=FAILED\n'
exit 1

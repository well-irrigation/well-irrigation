#!/bin/sh
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
script="$root/scripts/cloud_deploy.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/wi-cloud-deploy-test.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

mkdir -p "$tmp/bin"
cat > "$tmp/bin/psql" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_ARGS_FILE"
case "$*" in
  *"select 1"*) exit 0 ;;
  *"to_regclass"*)
    printf 'supabase_migrations.schema_migrations\n'
    exit 0
    ;;
  *"select version from supabase_migrations.schema_migrations"*)
    exit "${MOCK_HISTORY_EXIT:-0}"
    ;;
esac
exit 99
MOCK
chmod +x "$tmp/bin/psql"

output="$tmp/output.log"
args="$tmp/psql.args"
: > "$args"

set +e
PATH="$tmp/bin:$PATH" \
  MOCK_ARGS_FILE="$args" \
  MOCK_HISTORY_EXIT=17 \
  SUPABASE_DB_PASSWORD=test-password \
  sh "$script" > "$output" 2>&1
actual=$?
set -e

if [ "$actual" -eq 1 ] \
  && grep -Fq 'RESULT=FAILED_AT=2' "$output" \
  && grep -Fq 'تعذرت قراءة سجل الترحيلات' "$output" \
  && ! grep -Fq 'STEP 2 migrate STARTED' "$output" \
  && ! grep -Fq 'RESULT=SUCCESS' "$output"; then
  printf 'PASS history-read-failure-stops-deploy\n'
  printf 'PASS_COUNT=1 FAIL_COUNT=0\n'
  printf 'RESULT=SUCCESS\n'
  exit 0
fi

printf 'FAIL history-read-failure-stops-deploy status=%s\n' "$actual"
printf 'PASS_COUNT=0 FAIL_COUNT=1\n'
printf 'RESULT=FAILED\n'
exit 1

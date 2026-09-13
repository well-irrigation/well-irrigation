#!/bin/sh
# نشر ترحيلات القرص الناقصة إلى Supabase عبر القناة المثبتة فقط.
# لا يشغّل اختبارات supabase/tests سحابيًا، ولا يطبع كلمة المرور.
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
migrations_dir="$root/supabase/migrations"

PROJECT_REF=${SUPABASE_PROJECT_ID:-hxfhczpfrfdpzsobfbab}
PGHOST=${SUPABASE_DB_HOST:-aws-0-ap-south-1.pooler.supabase.com}
PGPORT=${SUPABASE_DB_PORT:-6543}
PGUSER=${SUPABASE_DB_USER:-postgres.$PROJECT_REF}
PGDATABASE=${SUPABASE_DB_NAME:-postgres}

if [ -z "${SUPABASE_DB_PASSWORD:-}" ]; then
  printf 'ERROR: SUPABASE_DB_PASSWORD غير مضبوط.\n' >&2
  exit 2
fi

command -v psql >/dev/null 2>&1 || {
  printf 'ERROR: psql غير متوفر.\n' >&2
  exit 2
}

PGPASSWORD=$SUPABASE_DB_PASSWORD
export PGPASSWORD PGHOST PGPORT PGUSER PGDATABASE

PSQL='psql -X -q -v ON_ERROR_STOP=1'
PSQL_VAL='psql -X -A -t -v ON_ERROR_STOP=1'

printf 'STEP 1 connect STARTED host=%s port=%s\n' "$PGHOST" "$PGPORT"
if ! $PSQL -c 'select 1' >/dev/null; then
  printf 'RESULT=FAILED_AT=1\n' >&2
  exit 1
fi
printf 'STEP 1 connect OK\n'

if [ "$($PSQL_VAL -c "select coalesce(to_regclass('supabase_migrations.schema_migrations')::text, 'MISSING')")" = MISSING ]; then
  printf 'ERROR: جدول سجل الترحيلات غير موجود سحابيًا.\n' >&2
  printf 'RESULT=FAILED_AT=2\n' >&2
  exit 1
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/wi-cloud-deploy.XXXXXX") || exit 2
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

if ! $PSQL_VAL \
  -c 'select version from supabase_migrations.schema_migrations' \
  > "$work_dir/applied-raw.txt"; then
  printf 'ERROR: تعذرت قراءة سجل الترحيلات السحابي.\n' >&2
  printf 'RESULT=FAILED_AT=2\n' >&2
  exit 1
fi
if ! sort "$work_dir/applied-raw.txt" > "$work_dir/applied.txt"; then
  printf 'ERROR: تعذر ترتيب سجل الترحيلات السحابي.\n' >&2
  printf 'RESULT=FAILED_AT=2\n' >&2
  exit 1
fi

applied=0
skipped=0
for path in "$migrations_dir"/*.sql; do
  name=$(basename "$path")
  version=${name%%_*}

  case "$name" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_*.sql) ;;
    *)
      printf 'ERROR: اسم ترحيل غير صالح: %s\n' "$name" >&2
      exit 1
      ;;
  esac
  suffix=${name#*_}
  case "$suffix" in
    ''|*[!A-Za-z0-9_.-]*)
      printf 'ERROR: لاحقة ترحيل غير آمنة: %s\n' "$name" >&2
      exit 1
      ;;
  esac

  if grep -Fxq "$version" "$work_dir/applied.txt"; then
    skipped=$((skipped + 1))
    continue
  fi

  printf 'STEP 2 migrate STARTED file=%s\n' "$name"
  transaction="$work_dir/$name"
  {
    printf 'begin;\n'
    begin_line=$(grep -n -m1 '^begin;$' "$path" | cut -d: -f1)
    commit_line=$(grep -n '^commit;$' "$path" | tail -n 1 | cut -d: -f1)
    if [ -n "$begin_line" ] && [ -n "$commit_line" ]; then
      awk -v first="$begin_line" -v last="$commit_line" \
        'NR != first && NR != last' "$path"
    else
      cat "$path"
    fi
    printf "insert into supabase_migrations.schema_migrations (version, name) values ('%s', '%s') on conflict (version) do nothing;\n" "$version" "$name"
    printf 'commit;\n'
  } > "$transaction"

  if ! $PSQL -f "$transaction"; then
    printf 'RESULT=FAILED_AT=2 file=%s\n' "$name" >&2
    exit 1
  fi
  printf '%s\n' "$version" >> "$work_dir/applied.txt"
  applied=$((applied + 1))
  printf 'STEP 2 migrate OK file=%s\n' "$name"
done

printf 'STEP 2 migrate DONE applied=%s skipped=%s\n' "$applied" "$skipped"

if ! PGPASSWORD=$SUPABASE_DB_PASSWORD sh "$root/scripts/cloud_verify.sh"; then
  printf 'RESULT=FAILED_AT=3\n' >&2
  exit 1
fi

printf 'STEP 3 verify OK\n'
printf 'RESULT=SUCCESS\n'

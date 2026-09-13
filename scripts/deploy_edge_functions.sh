#!/bin/sh
# نشر دوال الحافة المتعقبة من المصدر بعد نجاح نشر القاعدة.
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
functions_dir="$root/supabase/functions"
project_ref=${SUPABASE_PROJECT_ID:-hxfhczpfrfdpzsobfbab}

if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  printf 'ERROR: SUPABASE_ACCESS_TOKEN غير مضبوط.\n' >&2
  exit 2
fi

command -v npx >/dev/null 2>&1 || {
  printf 'ERROR: npx غير متوفر.\n' >&2
  exit 2
}

if [ ! -d "$functions_dir" ]; then
  printf 'STEP 4 edge SKIPPED no-functions-directory\n'
  exit 0
fi

count=0
for path in "$functions_dir"/*; do
  [ -d "$path" ] || continue
  name=$(basename "$path")
  printf 'STEP 4 edge STARTED function=%s\n' "$name"
  if ! (cd "$root" && npx --no-install supabase functions deploy "$name" \
    --project-ref "$project_ref"); then
    printf 'STEP 4 edge FAILED function=%s\n' "$name" >&2
    printf 'RESULT=FAILED_AT=4 function=%s\n' "$name" >&2
    exit 1
  fi
  count=$((count + 1))
  printf 'STEP 4 edge OK function=%s\n' "$name"
done

printf 'STEP 4 edge DONE count=%s\n' "$count"
printf 'RESULT=SUCCESS\n'

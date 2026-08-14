#!/bin/sh

set -u

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tests_dir="$project_root/supabase/tests"
db_container=$(docker ps --filter name=supabase_db -q | head -n 1)

if [ -z "$db_container" ]; then
  echo "ERROR: لم تُعثر على حاوية Supabase PostgreSQL العاملة." >&2
  exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/well-irrigation-db-test.XXXXXX") || exit 2
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

test_list="$tmp_dir/tests.list"
find "$tests_dir" -maxdepth 1 -type f -name '*.test.sql' -print | LC_ALL=C sort > "$test_list"

if [ ! -s "$test_list" ]; then
  echo "ERROR: لا توجد ملفات اختبار في $tests_dir" >&2
  exit 2
fi

total_pass=0
total_files=0

while IFS= read -r test_file; do
  test_name=$(basename "$test_file" .sql)
  output_file="$tmp_dir/$test_name.log"
  total_files=$((total_files + 1))

  echo "===== $test_name ====="
  docker exec -i "$db_container" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 \
    < "$test_file" > "$output_file" 2>&1
  psql_status=$?
  cat "$output_file"

  pass_count=$(grep -c 'NOTICE:  PASS ' "$output_file" 2>/dev/null || true)
  fail_count=$(grep -c 'NOTICE:  FAIL ' "$output_file" 2>/dev/null || true)
  error_count=$(grep -c '^ERROR:' "$output_file" 2>/dev/null || true)
  total_pass=$((total_pass + pass_count))

  echo "$test_name => PASS=$pass_count FAIL=$fail_count ERROR=$error_count"

  if [ "$psql_status" -ne 0 ] || [ "$fail_count" -ne 0 ] || [ "$error_count" -ne 0 ]; then
    echo "توقف db:test عند أول ملف فاشل: $test_name" >&2
    exit 1
  fi
done < "$test_list"

echo "===== نجحت حزمة قاعدة البيانات: FILES=$total_files PASS=$total_pass FAIL=0 ERROR=0 ====="

#!/bin/sh
# c:db — إعادة بناء القاعدة المحلية، ثم فحوصها، ثم تحديث الفهرس.
# ثلاث خطوات متسلسلة: ما بعد الفاشلة لا يُشغَّل.
# لا يلمس السحابة ولا تاريخ المستودع.
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root" || exit 2

log_dir="${TMPDIR:-/tmp}/wi-checks"
mkdir -p "$log_dir" || exit 2
reset_log="$log_dir/db-reset.log"
test_log="$log_dir/db-test.log"
index_log="$log_dir/db-index.log"

reset_state=SKIPPED; reset_detail=''
test_state=SKIPPED;  test_detail=''
index_state=SKIPPED; index_detail=''
failed_at=0

lines_of() {
  if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else printf '?'; fi
}

# أوامر القاعدة تنادي أداة supabase المثبَّتة محليًا عبر npx.
# ومجلد العمل المعزول لا يحمل node_modules خاصًا به، فنبحث عن أقرب
# node_modules/.bin في المجلدات الأعلى ونضعه في PATH — فتُنفَّذ الأداة
# المثبَّتة أصلًا بلا أي محاولة تنزيل من الشبكة.
node_bin=''
probe=$root
while [ "$probe" != / ] && [ -n "$probe" ]; do
  if [ -d "$probe/node_modules/.bin" ]; then
    node_bin="$probe/node_modules/.bin"
    break
  fi
  probe=$(dirname "$probe")
done
if [ -n "$node_bin" ]; then
  PATH="$node_bin:$PATH"
  export PATH
fi

# ---------- 0) حاوية القاعدة المحلية ----------
if ! command -v docker >/dev/null 2>&1; then
  printf 'STEP 0 docker   FAIL     docker-not-found\n'
  printf 'HINT=هذه الخطوة تحتاج Docker يعمل على جهازك\n'
  printf 'RESULT=FAILED_AT=0\n'
  exit 2
fi
if [ -z "$(docker ps --filter name=supabase_db -q 2>/dev/null | head -n 1)" ]; then
  printf 'STEP 0 docker   FAIL     supabase_db-not-running\n'
  printf 'HINT=شغّل أولًا: npm run supabase:start\n'
  printf 'RESULT=FAILED_AT=0\n'
  exit 2
fi
if [ -z "$node_bin" ]; then
  printf 'STEP 0 nodebin  FAIL     node_modules/.bin-not-found\n'
  printf 'HINT=شغّل أولًا: npm install في جذر المشروع\n'
  printf 'RESULT=FAILED_AT=0\n'
  exit 2
fi

# ---------- 1) db:reset ----------
npm run --silent db:reset > "$reset_log" 2>&1
if [ $? -eq 0 ]; then
  reset_state=OK
else
  reset_state=FAIL
  failed_at=1
fi

# ---------- 2) db:test ----------
if [ "$failed_at" -eq 0 ]; then
  npm run --silent db:test > "$test_log" 2>&1
  test_status=$?
  totals=$(grep -o 'FILES=[0-9]* PASS=[0-9]* FAIL=[0-9]* ERROR=[0-9]*' "$test_log" | tail -n 1)
  if [ "$test_status" -eq 0 ] && [ -n "$totals" ]; then
    test_state=OK
    test_detail="$totals"
  elif [ "$test_status" -ne 0 ]; then
    test_state=FAIL
    test_detail=$(grep -E '=> PASS=[0-9]+ FAIL=[0-9]+ ERROR=[0-9]+$' "$test_log" | tail -n 1 | cut -c1-120)
    [ -z "$test_detail" ] && test_detail='no-file-summary'
    failed_at=2
  else
    test_state=UNKNOWN
    test_detail='exit-0-without-totals-line'
    failed_at=2
  fi
fi

# ---------- 3) db:index ----------
if [ "$failed_at" -eq 0 ]; then
  npm run --silent db:index > "$index_log" 2>&1
  if [ $? -eq 0 ]; then
    index_state=OK
    index_detail=$(printf 'columns:%s constraints:%s functions:%s triggers:%s' \
      "$(lines_of docs/technical/db/columns.txt)" \
      "$(lines_of docs/technical/db/constraints.txt)" \
      "$(lines_of docs/technical/db/functions.txt)" \
      "$(lines_of docs/technical/db/triggers.txt)")
  else
    index_state=FAIL
    index_detail='index-script-failed'
    failed_at=3
  fi
fi

# ---------- 4) الملخّص ----------
printf 'NODE_BIN=%s\n' "${node_bin:-MISSING}"
printf 'STEP 1 db:reset %-8s %s\n' "$reset_state" "$reset_detail"
printf 'STEP 2 db:test  %-8s %s\n' "$test_state" "$test_detail"
printf 'STEP 3 db:index %-8s %s\n' "$index_state" "$index_detail"

if [ "$reset_state" = FAIL ]; then
  first=$(grep -m1 -E 'ERROR|error:|failed' "$reset_log" | cut -c1-160)
  [ -n "$first" ] && printf '       first-error: %s\n' "$first"
fi
if [ "$test_state" = FAIL ] || [ "$test_state" = UNKNOWN ]; then
  first=$(grep -m1 'NOTICE:  FAIL ' "$test_log" | cut -c1-160)
  [ -n "$first" ] && printf '       first-fail: %s\n' "$first"
  first=$(grep -m1 '^ERROR:' "$test_log" | cut -c1-160)
  [ -n "$first" ] && printf '       sql-error: %s\n' "$first"
fi
if [ "$index_state" = FAIL ]; then
  first=$(grep -m1 -E 'ERROR|error:|failed' "$index_log" | cut -c1-160)
  [ -n "$first" ] && printf '       first-error: %s\n' "$first"
fi

printf 'LOGS=%s\n' "$log_dir"

if [ "$failed_at" -eq 0 ]; then
  printf 'RESULT=SUCCESS\n'
  exit 0
fi
printf 'RESULT=FAILED_AT=%s\n' "$failed_at"
exit 1

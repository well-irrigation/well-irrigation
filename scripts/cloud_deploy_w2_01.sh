#!/bin/sh
# =====================================================================
# نشر W2-01 السحابي — Migration 083 + 084 (ق-114)
#
# القناة العاملة الوحيدة = Supavisor transaction mode / المنفذ 6543
# (`docs/technical/MIGRATIONS.md:687`). المنفذ 5432 والاتصال المباشر
# IPv6 لا يصلان، فـ`db push` لا يعمل.
#
# السكربت قابل للاستكمال: يقرأ ما طُبق فعلًا ويتخطاه، ويطبق كل
# migration داخل معاملة واحدة ويسجّل صفّها، ويتوقف عند أول فشل.
# إعادة التشغيل تكمل من موضع التوقف.
#
# لا يعدّل هذا السكربت Remote Database خارج Migration workflow:
# الملفات هي المصدر، والسكربت ناقل بديل عن `db push` المحجوب شبكيًا.
#
# الاستخدام:
#   sh scripts/cloud_deploy_w2_01.sh
#
# يطلب السكربت كلمة مرور قاعدة البيانات تفاعليًا بلا إظهارها على
# الشاشة. لا تُمرَّر كوسيط ولا تُكتب في ملف ولا تُطبع أبدًا.
# =====================================================================

set -u

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
migrations_dir="$project_root/supabase/migrations"
tests_dir="$project_root/supabase/tests"

PROJECT_REF="hxfhczpfrfdpzsobfbab"
PGHOST="aws-0-ap-south-1.pooler.supabase.com"
PGPORT="6543"
PGUSER="postgres.$PROJECT_REF"
PGDATABASE="postgres"

# ملفات هذه الجولة فقط. الهجرات 001–082 مطبَّقة سحابيًا سلفًا،
# والسكربت يتخطى المطبَّق على أي حال.
MIGRATIONS="20260823003001_083_sync_command_resolvers.sql
20260823013001_084_api_idempotent_writes.sql"

TESTS="20260823_083_sync_command_resolvers.test.sql
20260823_084_api_idempotent_writes.test.sql"

if ! command -v psql > /dev/null 2>&1; then
  echo "ERROR: psql غير متوفر." >&2
  exit 2
fi

# كلمة المرور تُقرأ تفاعليًا بلا صدى. لو كانت مصدَّرة سلفًا في
# البيئة تُستخدم كما هي (يفيد إعادة التشغيل بعد انقطاع الشبكة).
if [ -z "${PGPASSWORD:-}" ]; then
  printf 'كلمة مرور قاعدة البيانات السحابية (لن تظهر): ' >&2
  stty -echo 2>/dev/null
  IFS= read -r PGPASSWORD
  stty echo 2>/dev/null
  printf '\n' >&2
fi

if [ -z "${PGPASSWORD:-}" ]; then
  echo "ERROR: لم تُدخَل كلمة مرور." >&2
  exit 2
fi

export PGPASSWORD PGHOST PGPORT PGUSER PGDATABASE

# transaction mode لا يدعم prepared statements، فيلزم تعطيلها.
PSQL="psql -X -q -v ON_ERROR_STOP=1"

echo "===== الاتصال بالقناة 6543 ====="
connect_err=$($PSQL -c 'select 1' 2>&1 > /dev/null)
if [ -n "$connect_err" ]; then
  echo "ERROR: تعذّر الاتصال على $PGHOST:$PGPORT" >&2
  # سبب الفشل يُطبع كما ورد من psql: لا يحتوي كلمة المرور.
  echo "السبب كما ورد: $connect_err" >&2
  exit 1
fi
echo "CONNECT=OK"


echo "===== ضمان جدول سجل الترحيلات ====="
$PSQL <<'SQL' || exit 1
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version text primary key,
  statements text[],
  name text
);
SQL
echo "MIGRATION_TABLE=OK"


echo "===== تطبيق ترحيلات W2-01 ====="
applied_count=0
skipped_count=0

for mig in $MIGRATIONS; do
  version=$(printf '%s' "$mig" | cut -d_ -f1)
  mig_path="$migrations_dir/$mig"

  if [ ! -f "$mig_path" ]; then
    echo "ERROR: ملف الترحيل غير موجود: $mig" >&2
    exit 1
  fi

  exists=$($PSQL -t -A -c \
    "select 1 from supabase_migrations.schema_migrations where version = '$version'" \
    2>/dev/null)

  if [ "$exists" = "1" ]; then
    echo "SKIP  $mig (مطبَّق سلفًا)"
    skipped_count=$((skipped_count + 1))
    continue
  fi

  echo "APPLY $mig"

  # الملف يحتوي begin/commit بنفسه، فيُنفَّذ كما هو ثم يُسجَّل صفّه.
  if ! $PSQL -f "$mig_path"; then
    echo "ERROR: فشل تطبيق $mig — أعد تشغيل السكربت بعد المعالجة." >&2
    exit 1
  fi

  if ! $PSQL -c \
    "insert into supabase_migrations.schema_migrations (version, name)
     values ('$version', '$mig')
     on conflict (version) do nothing"; then
    echo "ERROR: طُبِّق $mig لكن تسجيل صفّه فشل." >&2
    exit 1
  fi

  applied_count=$((applied_count + 1))
done

echo "MIGRATIONS_APPLIED=$applied_count SKIPPED=$skipped_count"


echo "===== تشغيل اختباري W2-01 سحابيًا ====="
total_pass=0
total_fail=0
total_error=0

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/well-irrigation-cloud.XXXXXX") || exit 2
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

for t in $TESTS; do
  test_path="$tests_dir/$t"
  test_name=$(basename "$t" .sql)
  out="$tmp_dir/$test_name.log"

  if [ ! -f "$test_path" ]; then
    echo "ERROR: ملف الاختبار غير موجود: $t" >&2
    exit 1
  fi

  echo "===== $test_name ====="
  $PSQL -f "$test_path" > "$out" 2>&1
  cat "$out"

  pass_count=$(grep -c 'PASS ' "$out" 2>/dev/null || true)
  fail_count=$(grep -c 'FAIL ' "$out" 2>/dev/null || true)
  error_count=$(grep -c '^ERROR:' "$out" 2>/dev/null || true)

  total_pass=$((total_pass + pass_count))
  total_fail=$((total_fail + fail_count))
  total_error=$((total_error + error_count))

  echo "$test_name => PASS=$pass_count FAIL=$fail_count ERROR=$error_count"
done


echo "===== حدود Data API ====="
# `sync` يجب أن يبقى غير مكشوف: المُحلِّلات ليست عقدًا للعميل.
boundary=$($PSQL -t -A <<'SQL'
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and has_function_privilege('authenticated', p.oid, 'EXECUTE'))
  || '/' ||
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and has_function_privilege('anon', p.oid, 'EXECUTE'))
  || '/' ||
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and p.prosecdef)
  || '/' ||
  (select count(*) from information_schema.table_privileges
    where grantee in ('anon', 'authenticated')
      and table_schema in ('core','iam','ops','billing','finance',
                           'inventory','audit','sync','reporting')
      and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE',
                             'REFERENCES','TRIGGER'));
SQL
)

echo "API_SURFACE/ANON/DEFINER/DIRECT_DML = $boundary"

if [ "$boundary" = "33/0/0/0" ]; then
  echo "DATA_API_BOUNDARY=OK"
else
  echo "DATA_API_BOUNDARY=FAIL (توقع 33/0/0/0)" >&2
  total_fail=$((total_fail + 1))
fi


echo "===== سجل الترحيلات البعيد ====="
remote_count=$($PSQL -t -A -c \
  "select count(*) from supabase_migrations.schema_migrations")
remote_top=$($PSQL -t -A -c \
  "select max(version) from supabase_migrations.schema_migrations")
echo "REMOTE_HISTORY=$remote_count TOP=$remote_top"


echo "======================================================"
if [ "$total_fail" -eq 0 ] && [ "$total_error" -eq 0 ]; then
  echo "CLOUD_W2_01_ALL_PASS — PASS=$total_pass FAIL=0 ERROR=0"
  exit 0
else
  echo "CLOUD_W2_01_FAILED — PASS=$total_pass FAIL=$total_fail ERROR=$total_error" >&2
  exit 1
fi

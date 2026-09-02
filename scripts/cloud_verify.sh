#!/bin/sh
# =====================================================================
# تحقق سحابي للقراءة فقط — لا يكتب ولا ينشئ ولا يحذف شيئًا
#
# الغرض: إثبات ما هو موجود فعلًا على قاعدة الإنتاج، لا افتراضه.
# يقارن ملفات supabase/migrations بصفوف schema_migrations السحابية،
# ثم يتحقق من وجود عقود api الخمسة التي أضافتها هجرة 092.
#
# القناة العاملة الوحيدة = Supavisor transaction mode / المنفذ 6543.
# المنفذ 5432 والاتصال المباشر IPv6 لا يصلان.
#
# الاستخدام:
#   sh scripts/cloud_verify.sh
#
# كلمة المرور تُقرأ تفاعليًا بلا صدى، ويُطبع بعدها حكم صريح:
# PASSWORD=OK أو PASSWORD=WRONG. لا تُطبع الكلمة ولا رابط الاتصال.
# =====================================================================

set -u

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
migrations_dir="$project_root/supabase/migrations"

PROJECT_REF="hxfhczpfrfdpzsobfbab"
PGHOST="aws-0-ap-south-1.pooler.supabase.com"
PGPORT="6543"
PGUSER="postgres.$PROJECT_REF"
PGDATABASE="postgres"

# عقود هجرة 092 الخمسة كما هي معرَّفة في ملفها.
CONTRACTS="list_well_expenses
list_well_partners
list_well_profit_cycles
get_farmer_account
get_reports_summary"

if ! command -v psql > /dev/null 2>&1; then
  echo "ERROR: psql غير متوفر." >&2
  exit 2
fi

work_dir=$(mktemp -d) || exit 2
trap 'rm -rf "$work_dir"' EXIT INT TERM

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

# transaction mode لا يدعم prepared statements.
PSQL="psql -X -q -v ON_ERROR_STOP=1"
PSQL_VAL="psql -X -A -t -v ON_ERROR_STOP=1"

echo "===== كلمة المرور والاتصال ====="
connect_err=$($PSQL -c 'select 1' 2>&1 > /dev/null)

if [ -n "$connect_err" ]; then
  case "$connect_err" in
    *28P01* | *"password authentication failed"* | *"Wrong password"*)
      echo "PASSWORD=WRONG — كلمة المرور غير صحيحة، لم يُفتح أي اتصال." >&2
      echo "أعد تشغيل السكربت وأدخلها من جديد." >&2
      exit 1
      ;;
    *)
      echo "PASSWORD=UNTESTED — الاتصال نفسه فشل قبل فحصها." >&2
      echo "السبب كما ورد من psql: $connect_err" >&2
      exit 1
      ;;
  esac
fi

echo "PASSWORD=OK — كلمة المرور صحيحة والاتصال قائم على المنفذ $PGPORT."

echo "===== مقارنة الترحيلات: القرص مقابل السحابة ====="
reg=$($PSQL_VAL -c "select coalesce(
  to_regclass('supabase_migrations.schema_migrations')::text, 'MISSING')")

if [ "$reg" = "MISSING" ]; then
  echo "ERROR: جدول schema_migrations غير موجود سحابيًا." >&2
  exit 1
fi

for path in "$migrations_dir"/*.sql; do
  basename "$path" | cut -d_ -f1
done | sort > "$work_dir/local.txt"

$PSQL_VAL -c "select version from supabase_migrations.schema_migrations" \
  | sort > "$work_dir/cloud.txt" || exit 1

local_count=$(grep -c '' < "$work_dir/local.txt")
cloud_count=$(grep -c '' < "$work_dir/cloud.txt")
missing=$(comm -23 "$work_dir/local.txt" "$work_dir/cloud.txt")
missing_count=$(printf '%s' "$missing" | grep -c '.')

echo "MIGRATIONS_LOCAL=$local_count"
echo "MIGRATIONS_CLOUD=$cloud_count"
echo "MISSING_IN_CLOUD=$missing_count"

status=0

if [ "$missing_count" -ne 0 ]; then
  echo "الناقص سحابيًا بالاسم:"
  printf '%s\n' "$missing"
  status=1
fi

echo "===== عقود هجرة 092 في مخطط api ====="
for fn in $CONTRACTS; do
  found=$($PSQL_VAL -c "select count(*) from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and p.proname = '$fn'") || exit 1

  if [ "$found" -ge 1 ]; then
    echo "CONTRACT_OK: api.$fn"
  else
    echo "CONTRACT_MISSING: api.$fn" >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo "===== فشل التحقق السحابي ====="
  exit 1
fi

echo "===== نجح التحقق السحابي: القرص والسحابة متطابقان ====="

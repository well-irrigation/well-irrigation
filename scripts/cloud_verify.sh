#!/bin/sh
# =====================================================================
# تحقق سحابي للقراءة فقط — لا يكتب ولا ينشئ ولا يحذف شيئًا
#
# الغرض: إثبات ما هو موجود فعلًا على قاعدة الإنتاج، لا افتراضه.
# يقارن ملفات supabase/migrations بصفوف schema_migrations السحابية،
# ثم يقارن **كل** دوال مخططات التطبيق كما يعرفها الفهرس المولَّد
# docs/technical/db/functions.txt بما هو موجود سحابيًا في pg_proc.
#
# لماذا الفهرس لا قائمة مكتوبة يدويًا: النسخة الأولى من هذا السكربت
# ثبّتت عقود هجرة 092 الخمسة بالاسم، فبقيت تفحصها بعد هجرة 093 وتعلن
# النجاح بلا أن تنظر إلى شيء من الجولة الجديدة — نجاح كاذب في أداة
# التحقق نفسها (ق-113). الفهرس يُعاد توليده كل جولة بـnpm run db:index،
# فيتوسّع الفحص تلقائيًا ولا يتقادم.
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
functions_index="$project_root/docs/technical/db/functions.txt"

PROJECT_REF="hxfhczpfrfdpzsobfbab"
PGHOST="aws-0-ap-south-1.pooler.supabase.com"
PGPORT="6543"
PGUSER="postgres.$PROJECT_REF"
PGDATABASE="postgres"

# نفس مُرشِّح مخططات التطبيق المستخدَم في scripts/db_index.sh، لتكون
# المقارنة بين مجموعتين مُعرَّفتين بنفس الحد لا بحدَّين مختلفين.
APP_SCHEMAS="left(n.nspname, 3) <> 'pg_'
  and n.nspname not in (
    'information_schema', 'auth', 'storage', 'realtime', '_realtime',
    '_analytics', 'vault', 'extensions', 'supabase_functions',
    'supabase_migrations', 'graphql', 'graphql_public', 'pgbouncer',
    'net', 'cron', 'pgsodium', 'pgsodium_masks'
  )"

if ! command -v psql > /dev/null 2>&1; then
  echo "ERROR: psql غير متوفر." >&2
  exit 2
fi

if [ ! -f "$functions_index" ]; then
  echo "ERROR: فهرس الدوال غير موجود: docs/technical/db/functions.txt" >&2
  echo "شغّل npm run db:index بعد npm run db:reset ثم أعِد المحاولة." >&2
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

echo "===== دوال المخطط: الفهرس المولَّد مقابل السحابة ====="

# الفهرس يحمل السطر: schema.function(args)|returns|volatility|security|config
# والمقارنة على مستوى schema.function: كافية لإثبات وصول أهداف الهجرة،
# وأمتن من مطابقة نص الوسائط الذي يختلف تنسيقه بين الإصدارات.
grep -v '^#' "$functions_index" \
  | cut -d'(' -f1 \
  | sed '/^[[:space:]]*$/d' \
  | sort -u > "$work_dir/local_fn.txt"

$PSQL_VAL -c "select n.nspname || '.' || p.proname
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where $APP_SCHEMAS" \
  | sed '/^[[:space:]]*$/d' \
  | sort -u > "$work_dir/cloud_fn.txt" || exit 1

index_fn_count=$(grep -c '' < "$work_dir/local_fn.txt")
cloud_fn_count=$(grep -c '' < "$work_dir/cloud_fn.txt")
fn_missing=$(comm -23 "$work_dir/local_fn.txt" "$work_dir/cloud_fn.txt")
fn_extra=$(comm -13 "$work_dir/local_fn.txt" "$work_dir/cloud_fn.txt")
fn_missing_count=$(printf '%s' "$fn_missing" | grep -c '.')
fn_extra_count=$(printf '%s' "$fn_extra" | grep -c '.')

echo "FUNCTIONS_INDEX=$index_fn_count"
echo "FUNCTIONS_CLOUD=$cloud_fn_count"
echo "FUNCTIONS_MISSING_IN_CLOUD=$fn_missing_count"
echo "FUNCTIONS_EXTRA_IN_CLOUD=$fn_extra_count"

if [ "$fn_missing_count" -ne 0 ]; then
  echo "الناقص سحابيًا بالاسم:"
  printf '%s\n' "$fn_missing"
  status=1
fi

# الزائد سحابيًا لا يُفشِل الفحص: الفهرس يُولَّد محليًا وقد يتقادم جولةً
# إن نُسي npm run db:index. لكنه يُطبع دائمًا لأنه انحرافٌ يستحق النظر.
if [ "$fn_extra_count" -ne 0 ]; then
  echo "زائد سحابيًا (انحراف للفحص لا فشل):"
  printf '%s\n' "$fn_extra"
fi

echo "===== أرقام كتالوج الصلاحيات سحابيًا ====="

# تُطبع كقياس لا كحُكم: مقارنتها بأرقام الحرس المحلي (اختبارا 080/081)
# قرارُ قارئ، وتثبيتها هنا بالرقم كان سيُعيد تقادم القائمة اليدوية.
perm_count=$($PSQL_VAL -c "select count(*) from iam.permissions") || exit 1
grant_count=$($PSQL_VAL -c \
  "select count(*) from iam.role_permissions") || exit 1

echo "IAM_PERMISSIONS=$perm_count"
echo "IAM_ROLE_PERMISSIONS=$grant_count"

if [ "$status" -ne 0 ]; then
  echo "===== فشل التحقق السحابي ====="
  exit 1
fi

echo "===== نجح التحقق السحابي: كل ترحيلات القرص ودوال الفهرس موجودة سحابيًا ====="

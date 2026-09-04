#!/bin/sh
# =====================================================================
# حالة بيانات الإنتاج — للقراءة فقط، لا يكتب ولا ينشئ ولا يحذف
#
# الغرض: معرفة **ما في قاعدة الإنتاج فعلًا** قبل أي تجربة ميدانية وبعدها.
# فرقُ القياسين هو الدليل المستقل على ما أنشأته الرحلة — لا ما قالته
# الشاشة. وشاشةٌ تقول «تم» ليست إثباتًا أن صفًّا كُتب (ق-113).
#
# القناة والاتصال نسخة من scripts/cloud_verify.sh: نفس PROJECT_REF ونفس
# منفذ Supavisor 6543 (المنفذ 5432 والاتصال المباشر IPv6 لا يصلان).
# واستخراجهما إلى ملف مشترك دَينٌ صغير مسجَّل: تعدّد المصدر هنا مقصود
# مؤقتًا ومكتوب، لا منسيّ.
#
# الاستخدام:
#   sh scripts/cloud_state.sh
#
# كلمة المرور تُقرأ تفاعليًا بلا صدى، ولا تُطبع هي ولا رابط الاتصال.
# =====================================================================

set -u

PROJECT_REF="hxfhczpfrfdpzsobfbab"
PGHOST="aws-0-ap-south-1.pooler.supabase.com"
PGPORT="6543"
PGUSER="postgres.$PROJECT_REF"
PGDATABASE="postgres"

if ! command -v psql > /dev/null 2>&1; then
  echo "ERROR: psql غير متوفر." >&2
  exit 2
fi

if [ -z "${PGPASSWORD:-}" ]; then
  printf 'كلمة مرور قاعدة البيانات السحابية (لن تظهر): ' >&2
  stty -echo 2>/dev/null
  IFS= read -r PGPASSWORD
  stty echo 2>/dev/null
  printf '\n' >&2
fi

export PGPASSWORD PGHOST PGPORT PGUSER PGDATABASE

PSQL="psql -X -A -t -v ON_ERROR_STOP=1"

work_dir=$(mktemp -d) || exit 2
trap 'rm -rf "$work_dir"' EXIT INT TERM
out_file="$work_dir/state.out"
err_file="$work_dir/state.err"

connect_err=$($PSQL -c 'select 1' 2>&1 > /dev/null)
if [ -n "$connect_err" ]; then
  echo "PASSWORD=WRONG أو الاتصال متعذّر." >&2
  echo "السبب كما ورد من psql: $connect_err" >&2
  exit 1
fi

echo "PASSWORD=OK — الاتصال قائم على المنفذ $PGPORT."
echo "===== حالة بيانات الإنتاج ====="

$PSQL -c "select
  'AUTH_USERS='       || (select count(*) from auth.users)              || '|' ||
  'TENANTS='          || (select count(*) from core.tenants)            || '|' ||
  'WELLS='            || (select count(*) from core.wells)             || '|' ||
  'ASSIGNMENTS='      || (select count(*) from core.well_assignments)   || '|' ||
  'PERSONS='          || (select count(*) from core.persons)           || '|' ||
  'FARMER_ACCOUNTS='  || (select count(*) from ops.farmer_well_accounts) || '|' ||
  'FARMS='            || (select count(*) from ops.farms)              || '|' ||
  'PUMPS='            || (select count(*) from core.pumps)             || '|' ||
  'PRICE_SCHEDULES='  || (select count(*) from ops.price_schedules)    || '|' ||
  'SESSIONS='         || (select count(*) from ops.irrigation_sessions) || '|' ||
  'SESSIONS_OPEN='    || (select count(*) from ops.irrigation_sessions
                          where ended_at is null)                      || '|' ||
  'INVOICES='         || (select count(*) from billing.invoices)       || '|' ||
  'PAYMENTS='         || (select count(*) from billing.payments)       || '|' ||
  'RESET_TICKETS='    || (select count(*) from core.password_reset_tickets)
" > "$out_file" 2>"$err_file"
state=$?

# رمز الخروج يُقرأ من psql لا من tr: `psql | tr` يُخفي فشل الأول ويُعلن
# نجاح الثاني — نجاح كاذب في أداة قياس (الثابت 699).
if [ "$state" -ne 0 ]; then
  echo "RESULT=FAILED" >&2
  head -n 3 "$err_file" >&2
  exit 1
fi

tr '|' '\n' < "$out_file"
echo "===== انتهى القياس ====="
printf 'RESULT=SUCCESS\n'

#!/bin/sh
# c:state — ملخّص حالة المستودع في أسطر قليلة.
# للقراءة فقط: لا يعدّل ملفًا ولا يلمس القاعدة ولا الشبكة.
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root" || exit 2

log_dir="${TMPDIR:-/tmp}/wi-checks"
mkdir -p "$log_dir" || exit 2
gerr="$log_dir/state-git.err"
: > "$gerr"

# git في بيئة المساعد يطبع تحذيرًا غير ضار عن config.worktree.
# نجمع stderr ثم نُظهر ما بقي بعد تصفية هذا التحذير وحده.
g() { git "$@" 2>>"$gerr"; }

# وقد يعجز git عن العمل أصلًا (ملف تهيئة محجوب في مجلد عمل معزول). حينها
# مخرَجه فارغ، و`git status | wc -l` = 0 — فيُقرأ الصمت «لا تغييرات غير
# محفوظة» وهو نجاح كاذب داخل أداة التحقق نفسها (ق-113 / الثابت 699).
# فنفصل الحالتين: حقول git تُعلن BLOCKED عند العجز ولا تُلفَّق أرقامًا.
git_ok=yes
if ! g rev-parse --git-dir >/dev/null 2>>"$gerr"; then
  git_ok=no
fi

count_vs() {
  ref=$1
  if [ "$git_ok" = no ]; then
    printf 'BLOCKED'
    return
  fi
  if ! g rev-parse --verify --quiet "$ref" >/dev/null; then
    printf 'MISSING'
    return
  fi
  pair=$(g rev-list --left-right --count "$ref...HEAD")
  if [ -z "$pair" ]; then
    printf 'UNKNOWN'
    return
  fi
  printf 'behind=%s ahead=%s' \
    "$(printf '%s' "$pair" | awk '{print $1}')" \
    "$(printf '%s' "$pair" | awk '{print $2}')"
}

lines_of() {
  if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else printf '?'; fi
}

if [ "$git_ok" = yes ]; then
  branch=$(g rev-parse --abbrev-ref HEAD)
  head_line=$(g log --oneline -1)
  dirty=$(g status --porcelain --untracked-files=no | wc -l | tr -d ' ')
else
  branch=BLOCKED
  head_line=BLOCKED
  dirty=BLOCKED
fi

mig_dir="supabase/migrations"
mig_count=$(find "$mig_dir" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')

# SEALED_NEXT يقرأ من المصدر الحاكم وحده: AGENTS.md §4 عبارة
# «الهجرة التالية = N». لا استنتاج من أسماء ملفات الهجرات ولا من
# أي نص تاريخي خارج §4 (الثابت 699: لا رقم مكتوب بلا مصدر حي،
# ولا نجاح كاذب إذا غاب المصدر أو التبس).
# يجب العثور على قيمة رقمية واحدة بالضبط؛ غير ذلك STATE=BLOCKED.
agents_file="AGENTS.md"
sealed_next='UNKNOWN'
state_ok=no
if [ -f "$agents_file" ]; then
  section4=$(sed -n '/^## 4\./,/^## 5\./p' "$agents_file" 2>/dev/null)
  candidates=$(printf '%s\n' "$section4" \
    | sed -n 's/.*الهجرة التالية[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    | sort -u)
  candidate_count=$(printf '%s' "$candidates" | grep -c . || true)
  if [ "$candidate_count" = 1 ]; then
    sealed_next=$candidates
    state_ok=yes
  fi
fi

test_count=$(find supabase/tests -maxdepth 1 -type f -name '*.test.sql' 2>/dev/null | wc -l | tr -d ' ')

resume_file="docs/memory/RESUME_POINT.md"
resume_lines=$(lines_of "$resume_file")
resume_date=$(sed -n '1s/.*\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p' "$resume_file" 2>/dev/null)
[ -z "$resume_date" ] && resume_date='?'

printf 'BRANCH=%s\n' "${branch:-UNKNOWN}"
printf 'HEAD=%s\n' "${head_line:-UNKNOWN}"
printf 'VS_MAIN=%s\n' "$(count_vs main)"
printf 'VS_ORIGIN_MAIN=%s\n' "$(count_vs origin/main)"
printf 'DIRTY_TRACKED=%s\n' "$dirty"
printf 'MIGRATIONS=%s SEALED_NEXT=%s\n' "$mig_count" "$sealed_next"
printf 'DB_TESTS=%s\n' "$test_count"
printf 'RESUME=%s lines date=%s\n' "$resume_lines" "$resume_date"
printf 'DB_INDEX=columns:%s constraints:%s functions:%s triggers:%s\n' \
  "$(lines_of docs/technical/db/columns.txt)" \
  "$(lines_of docs/technical/db/constraints.txt)" \
  "$(lines_of docs/technical/db/functions.txt)" \
  "$(lines_of docs/technical/db/triggers.txt)"

left=$(grep -v 'config\.worktree' "$gerr" \
  | grep -v 'unable to access' \
  | grep -v 'unknown error occurred while reading the configuration' \
  | grep -v '^[[:space:]]*$' || true)
if [ -n "$left" ]; then
  printf 'GIT_WARN=%s\n' "$(printf '%s' "$left" | tr '\n' ';' | cut -c1-200)"
fi

if [ "$git_ok" = no ]; then
  printf 'GIT=BLOCKED سبب: git لا يعمل في هذا المجلد — لا تُقرأ حقوله رقمًا\n'
  printf 'RESULT=BLOCKED_GIT\n'
  exit 0
fi

if [ "$state_ok" = no ]; then
  printf 'STATE=BLOCKED سبب: «الهجرة التالية» غير موجودة قيمةً واحدة رقمية في AGENTS.md §4 — لا يُقرأ SUCCESS (الثابت 699)\n'
  printf 'RESULT=BLOCKED_STATE\n'
  exit 0
fi

printf 'RESULT=SUCCESS\n'

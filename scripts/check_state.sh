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

count_vs() {
  ref=$1
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

branch=$(g rev-parse --abbrev-ref HEAD)
head_line=$(g log --oneline -1)
dirty=$(g status --porcelain --untracked-files=no | wc -l | tr -d ' ')

mig_dir="supabase/migrations"
mig_count=$(find "$mig_dir" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')
mig_max=$(find "$mig_dir" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' 2>/dev/null \
  | sed -n 's/^[0-9]\{8,\}_\([0-9]\{3\}\)_.*/\1/p' | LC_ALL=C sort | tail -n 1)
[ -z "$mig_max" ] && mig_max='?'

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
printf 'MIGRATIONS=%s max=%s SEALED_NEXT=%s\n' "$mig_count" "$mig_max" \
  "$(printf '%s' "$mig_max" | awk '/^[0-9]+$/ {printf "%03d", $1 + 1; found=1} END {if (!found) printf "?"}')"
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

printf 'RESULT=SUCCESS\n'

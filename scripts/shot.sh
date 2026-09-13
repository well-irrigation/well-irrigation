#!/bin/sh
# =====================================================================
# لقطة شاشة من الهاتف إلى الحاسب — قناة العين في جلسة الفحص المشتركة
#
#   sh scripts/shot.sh                 ← لقطة بلا وسم
#   sh scripts/shot.sh "شاشة التقارير" ← لقطة بوسم يظهر في الفهرس
#
# تُحفظ في `.wi-live/shots/` (غير متعقَّبة) باسم مرقَّم بطابع وقت، ويُكتب
# سطر واحد لكل لقطة في `.wi-live/shots/index.log`. المساعد يقرأ **آخر N
# سطرًا** من الفهرس فيعرف مسارات آخر لقطات وحدها — فلا يفتح كل اللقطات
# في كل مرة، ولا يعتمد على ترتيب أسماء الملفات.
#
# ولماذا التحقق من الملف بعد الحفظ: `adb` قد يُنتج ملفًا **فارغًا** ويخرج
# بلا خطأ واضح (مُقيس في 2026-09-04: ملف 0 بايت مع `no devices found`).
# فملفٌ فارغ يُقرأ «لقطة موجودة» = نجاح كاذب، والمساعد يستنتج من العدم.
# فتُفحص بصمة PNG وحجمه قبل تسجيله في الفهرس.
# =====================================================================

set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
shots_dir="$root/.wi-live/shots"
index="$shots_dir/index.log"
label=${1:-}

mkdir -p "$shots_dir" || exit 2

if ! command -v adb > /dev/null 2>&1; then
  echo "ERROR: adb غير متوفر على هذا الحاسب." >&2
  exit 2
fi

# الجهاز يُفحص قبل المحاولة: بلا جهاز تكون الرسالة صريحة لا ملفًا فارغًا.
if ! adb get-state > /dev/null 2>&1; then
  echo "ERROR: لا هاتف موصول (أو adb لا يراه)." >&2
  echo "تحقّق من الكبل ومن تفعيل تصحيح USB وموافقة الهاتف." >&2
  exit 1
fi

seq_num=1
if [ -f "$index" ]; then
  seq_num=$(( $(grep -c '' < "$index") + 1 ))
fi

stamp=$(date '+%H%M%S')
name=$(printf '%03d-%s.png' "$seq_num" "$stamp")
path="$shots_dir/$name"

adb exec-out screencap -p > "$path" 2>"$shots_dir/last.err"
rc=$?

# ثلاثة شروط لا واحد: رمز الخروج، وحجم غير صفري، وبصمة PNG الحقيقية.
size=0
[ -f "$path" ] && size=$(wc -c < "$path" | tr -d ' ')
is_png=no
if [ "$size" -gt 1000 ]; then
  head -c 4 "$path" | od -An -tx1 | tr -d ' \n' | grep -qi '89504e47' && is_png=yes
fi

if [ "$rc" -ne 0 ] || [ "$is_png" = no ]; then
  rm -f "$path"
  echo "RESULT=FAILED rc=$rc size=$size png=$is_png" >&2
  head -n 2 "$shots_dir/last.err" >&2
  exit 1
fi

printf '%s|%s|%s\n' "$name" "$(date '+%H:%M:%S')" "${label:--}" >> "$index"

echo "SHOT=$path"
echo "SIZE=$size"
echo "INDEX=$index"
echo "TOTAL=$(grep -c '' < "$index")"

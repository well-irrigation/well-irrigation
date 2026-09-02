#!/bin/sh

# فهرس مخطط القاعدة الحقيقي: أربعة ملفات نصية تُقرأ بالبحث المُوجَّه
# بدلًا من قراءة ملفات الهجرات كاملة لإثبات وجود عمود أو قيد أو زناد.
# يُشغَّل على القاعدة المحلية بعد npm run db:reset.

set -u

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out_dir="$project_root/docs/technical/db"
db_container=$(docker ps --filter name=supabase_db -q | head -n 1)

if [ -z "$db_container" ]; then
  echo "ERROR: لم تُعثر على حاوية Supabase PostgreSQL العاملة." >&2
  exit 2
fi

mkdir -p "$out_dir" || exit 2

# مخططات التطبيق وحدها: تُستثنى مخططات النظام ومخططات Supabase المُدارة.
app_schemas="n.nspname not like 'pg\\_%'
  and n.nspname not in (
    'information_schema', 'auth', 'storage', 'realtime', '_realtime',
    '_analytics', 'vault', 'extensions', 'supabase_functions',
    'supabase_migrations', 'graphql', 'graphql_public', 'pgbouncer',
    'net', 'cron', 'pgsodium', 'pgsodium_masks'
  )"

status=0

write_index() {
  # $1 = اسم الملف، $2 = وصف الأعمدة، $3 = الاستعلام
  file="$out_dir/$1"
  printf '# %s\n' "$2" > "$file"
  printf '# مولَّد آليًا بـ scripts/db_index.sh — لا يُحرَّر يدويًا\n' >> "$file"

  docker exec -i "$db_container" psql -X -A -t -F '|' \
    -U postgres -d postgres -v ON_ERROR_STOP=1 -c "$3" >> "$file"

  if [ $? -ne 0 ]; then
    echo "ERROR: فشل توليد $1" >&2
    status=1
    return 1
  fi

  printf '%s: %s سطرًا\n' "$1" "$(wc -l < "$file")"
}

write_index columns.txt \
  'schema.table|column|type|nullability|default' \
  "select n.nspname || '.' || c.relname || '|' || a.attname || '|' ||
          format_type(a.atttypid, a.atttypmod) || '|' ||
          case when a.attnotnull then 'NOT NULL' else 'null' end || '|' ||
          coalesce(pg_get_expr(d.adbin, d.adrelid), '-')
   from pg_attribute a
   join pg_class c on c.oid = a.attrelid
   join pg_namespace n on n.oid = c.relnamespace
   left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
   where a.attnum > 0 and not a.attisdropped
     and c.relkind in ('r', 'p', 'v', 'm')
     and $app_schemas
   order by n.nspname, c.relname, a.attnum"

write_index constraints.txt \
  'schema.table|constraint|type|definition' \
  "select n.nspname || '.' || c.relname || '|' || con.conname || '|' ||
          con.contype::text || '|' || pg_get_constraintdef(con.oid)
   from pg_constraint con
   join pg_class c on c.oid = con.conrelid
   join pg_namespace n on n.oid = c.relnamespace
   where $app_schemas
   order by n.nspname, c.relname, con.conname"

write_index triggers.txt \
  'schema.table|trigger|definition' \
  "select n.nspname || '.' || c.relname || '|' || t.tgname || '|' ||
          pg_get_triggerdef(t.oid)
   from pg_trigger t
   join pg_class c on c.oid = t.tgrelid
   join pg_namespace n on n.oid = c.relnamespace
   where not t.tgisinternal and $app_schemas
   order by n.nspname, c.relname, t.tgname"

write_index functions.txt \
  'schema.function(args)|returns|volatility|security|config' \
  "select n.nspname || '.' || p.proname || '(' ||
          pg_get_function_identity_arguments(p.oid) || ')|' ||
          pg_get_function_result(p.oid) || '|' ||
          case p.provolatile when 'i' then 'immutable'
                             when 's' then 'stable'
                             else 'volatile' end || '|' ||
          case when p.prosecdef then 'definer' else 'invoker' end || '|' ||
          coalesce(array_to_string(p.proconfig, ' '), '-')
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where p.prokind = 'f' and $app_schemas
   order by n.nspname, p.proname"

if [ "$status" -ne 0 ]; then
  echo "===== فشل فهرس المخطط =====" >&2
  exit 1
fi

echo "===== فهرس المخطط جاهز: docs/technical/db ====="

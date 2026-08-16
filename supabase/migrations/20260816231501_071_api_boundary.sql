-- 071: ق-78 — حد واجهة Data API المخصص للتطبيق
--
-- الهدف:
-- إنشاء مخطط api بوصفه عقد التطبيق الصريح عبر Supabase Data API،
-- مع إبقاء مخططات الأعمال الداخلية غير مكشوفة مباشرة.
--
-- هذه الهجرة لا تلغي بعد صلاحيات DML القديمة على المخططات الداخلية.
-- ذلك موضوع مستقل في الشرط الثاني من بوابة جاهزية المرحلة 7.

create schema if not exists api;

comment on schema api is
  'ق-78: عقد Data API المخصص للتطبيق. مخططات الأعمال الداخلية ليست واجهة عميل مباشرة.';

-- إغلاق المخطط أولًا ثم منح الحد الأدنى صراحة.
revoke all on schema api from public;
revoke all on schema api from anon;
revoke all on schema api from authenticated;
revoke all on schema api from service_role;

grant usage on schema api to authenticated;
grant usage on schema api to service_role;

-- لا يملك العميل CREATE داخل عقد API.
revoke create on schema api from anon;
revoke create on schema api from authenticated;
revoke create on schema api from service_role;

-- أي كائن مستقبلي ينشئه postgres داخل api يجب أن يبدأ مغلقًا.
-- لا وصول تلقائي إلى الجداول.
alter default privileges for role postgres in schema api
  revoke all on tables from public, anon, authenticated, service_role;

-- لا وصول تلقائي إلى التسلسلات.
alter default privileges for role postgres in schema api
  revoke all on sequences from public, anon, authenticated, service_role;

-- دوال PostgreSQL تمنح EXECUTE إلى PUBLIC افتراضيًا؛
-- نلغي ذلك داخل api حتى تصبح كل دالة Opt-in.
alter default privileges for role postgres in schema api
  revoke all on functions from public, anon, authenticated, service_role;

-- مسبار تقني فقط.
-- لا يقرأ ولا يكتب أي بيانات أعمال.
drop function if exists api.health();

create function api.health()
returns jsonb
language sql
stable
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
  select jsonb_build_object(
    'status', 'ok',
    'contract', 'api',
    'version', 1
  );
$function$;

comment on function api.health() is
  'ق-78: مسبار صحة تقني لعقد api؛ لا يصل إلى أي بيانات أعمال.';

-- إلغاء المنح الافتراضية ثم المنح الصريح فقط.
revoke all on function api.health() from public;
revoke all on function api.health() from anon;
revoke all on function api.health() from authenticated;
revoke all on function api.health() from service_role;

grant execute on function api.health() to authenticated;
grant execute on function api.health() to service_role;

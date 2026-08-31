-- 089 — عقود قراءة العمليات (م-41C1)
--
-- المشكلة التي تغلقها هذه الهجرة:
-- تطبيق Flutter كان يقرأ المزارعين والأراضي والمضخات مباشرة من
-- ops/core عبر Data API. المخططات الداخلية غير مكشوفة أصلًا،
-- فكان كل نداء يفشل صامتًا ويُستبدل ببيانات تجريبية في الشاشة.
--
-- القواعد المطبقة (ق-82 / ق-88 / ق-98):
-- 1. api.* تبقى SECURITY INVOKER بلا أي SECURITY DEFINER.
-- 2. لا جداول ولا Views داخل api — دوال فقط.
-- 3. نطاق البيانات مشتق من الجلسة عبر RLS، لا من وسيط يرسله العميل.
-- 4. لا وسيط جدول/مخطط ديناميكي.
-- 5. anon محجوب، والحدود العليا للنتائج مثبتة.
-- 6. الترتيب حتمي حتى لا تتغير الشاشة بين نداءين.

begin;

-- ==============================================================
-- 1. قائمة المزارعين في البئر
-- ==============================================================

create or replace function api.list_well_farmers(
  p_well_id uuid,
  p_query text default null,
  p_limit integer default 200
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_query text := nullif(btrim(coalesce(p_query, '')), '');
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة المزارعين'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  -- RLS على core.wells هي مصدر التفويض؛ البئر غير المرئي = رفض صريح
  -- بدل قائمة فارغة غامضة.
  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(x.item order by x.full_name, x.id), '[]'::jsonb)
  into v_items
  from (
    select
      fwa.id,
      p.full_name,
      jsonb_build_object(
        'id', fwa.id,
        'public_code', fwa.public_code,
        'full_name', p.full_name,
        'phone', (
          select pc.contact_value
          from core.person_contacts pc
          where pc.person_id = p.id
          order by
            pc.is_primary desc,
            case
              when pc.contact_type in ('mobile', 'whatsapp') then 0
              else 1
            end,
            pc.created_at,
            pc.id
          limit 1
        ),
        'status', fwa.status
      ) as item
    from ops.farmer_well_accounts fwa
    join ops.farmer_profiles fp
      on fp.id = fwa.farmer_profile_id
    join core.persons p
      on p.id = fp.person_id
    where fwa.well_id = p_well_id
      and fwa.status = 'active'
      and (
        v_query is null
        or p.full_name ilike '%' || v_query || '%'
        or fwa.public_code ilike '%' || v_query || '%'
        or exists (
          select 1
          from core.person_contacts pc
          where pc.person_id = p.id
            and (
              pc.contact_value ilike '%' || v_query || '%'
              or pc.normalized_value ilike '%' || v_query || '%'
            )
        )
      )
    order by p.full_name, fwa.id
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_farmers',
    'version', 1,
    'items', v_items
  );
end;
$function$;

revoke all on function api.list_well_farmers(uuid, text, integer)
  from public, anon, authenticated, service_role;

grant execute on function api.list_well_farmers(uuid, text, integer)
  to authenticated, service_role;

-- ==============================================================
-- 2. قائمة أراضي البئر
-- ==============================================================

create or replace function api.list_well_farms(
  p_well_id uuid,
  p_farmer_well_account_id uuid default null
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة الأراضي'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(x.item order by x.name, x.id), '[]'::jsonb)
  into v_items
  from (
    select
      f.id,
      f.name,
      jsonb_build_object(
        'id', f.id,
        'well_id', f.well_id,
        'name', f.name,
        'farmer_well_account_id', f.farmer_well_account_id,
        'status', f.status
      ) as item
    from ops.farms f
    where f.well_id = p_well_id
      and f.status = 'active'
      and (
        p_farmer_well_account_id is null
        or f.farmer_well_account_id = p_farmer_well_account_id
      )
    order by f.name, f.id
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_farms',
    'version', 1,
    'items', v_items
  );
end;
$function$;

revoke all on function api.list_well_farms(uuid, uuid)
  from public, anon, authenticated, service_role;

grant execute on function api.list_well_farms(uuid, uuid)
  to authenticated, service_role;

-- ==============================================================
-- 3. قائمة مضخات البئر
-- ==============================================================

create or replace function api.list_well_pumps(
  p_well_id uuid
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة المضخات'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(x.item order by x.name, x.id), '[]'::jsonb)
  into v_items
  from (
    select
      pm.id,
      pm.name,
      jsonb_build_object(
        'id', pm.id,
        'well_id', pm.well_id,
        'name', pm.name,
        'public_code', pm.public_code,
        'status', pm.status
      ) as item
    from core.pumps pm
    where pm.well_id = p_well_id
      and pm.status = 'active'
    order by pm.name, pm.id
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_pumps',
    'version', 1,
    'items', v_items
  );
end;
$function$;

revoke all on function api.list_well_pumps(uuid)
  from public, anon, authenticated, service_role;

grant execute on function api.list_well_pumps(uuid)
  to authenticated, service_role;

commit;

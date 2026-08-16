-- ق-80 / م-22
-- هوية المزارع المسؤول عن الأرض هي Farmer Well Account،
-- وليست iam.profiles الخاصة بحساب الدخول.
--
-- القاعدة:
-- core.persons
--   -> ops.farmer_profiles
--   -> ops.farmer_well_accounts
--   -> ops.farms.farmer_well_account_id
--
-- الهجرة Fail-closed:
-- لا تخمن علاقة iam.profiles بأي core.persons.
-- إذا أمكن استنتاج حساب الأرض تاريخيًا بصورة حتمية من الحجوزات/
-- الجلسات، يستخدم ذلك الحساب. أي تعارض أو هوية قديمة غير قابلة
-- للحسم يوقف الهجرة بدل ربط أشخاص بالتخمين.

begin;


-- ==============================================================
-- A. إضافة الهوية الجديدة للأرض
-- ==============================================================

alter table ops.farms
  add column farmer_well_account_id uuid;

comment on column ops.farms.farmer_well_account_id is
  'حساب المزارع المسؤول عن الأرض داخل البئر؛ مستقل عن حسابات الدخول iam.profiles';


-- ==============================================================
-- B. ترحيل حتمي فقط من الاستخدام التشغيلي التاريخي
-- ==============================================================

-- لا يجوز أن تكون الأرض نفسها قد استُخدمت تاريخيًا مع أكثر من
-- Farmer Well Account؛ فهذا يعني أن الفجوة القديمة أحدثت تعارضًا
-- يحتاج مراجعة بشرية.
do $$
begin
  if exists (
    with farm_usage as (
      select
        b.farm_id,
        b.farmer_well_account_id
      from ops.irrigation_bookings b
      where b.farm_id is not null
        and b.farmer_well_account_id is not null

      union all

      select
        s.farm_id,
        s.farmer_well_account_id
      from ops.irrigation_sessions s
      where s.farm_id is not null
        and s.farmer_well_account_id is not null
    )
    select 1
    from farm_usage u
    group by u.farm_id
    having count(distinct u.farmer_well_account_id) > 1
  ) then
    raise exception
      'ق-80: توجد أرض تاريخية مرتبطة بأكثر من حساب مزارع؛ يلزم حسم يدوي قبل تطبيق 075';
  end if;
end;
$$;


-- تأكيد أن أي حساب مستنتج تاريخيًا تابع للبئر نفسه.
do $$
begin
  if exists (
    with farm_usage as (
      select
        b.farm_id,
        b.farmer_well_account_id
      from ops.irrigation_bookings b
      where b.farm_id is not null
        and b.farmer_well_account_id is not null

      union

      select
        s.farm_id,
        s.farmer_well_account_id
      from ops.irrigation_sessions s
      where s.farm_id is not null
        and s.farmer_well_account_id is not null
    )
    select 1
    from farm_usage u
    join ops.farms f
      on f.id = u.farm_id
    left join ops.farmer_well_accounts fwa
      on fwa.id = u.farmer_well_account_id
    where fwa.id is null
       or fwa.well_id <> f.well_id
  ) then
    raise exception
      'ق-80: توجد علاقة تاريخية Farm/Farmer Account خارج البئر نفسه؛ يلزم إصلاح يدوي قبل 075';
  end if;
end;
$$;


-- عندما يكون التاريخ التشغيلي متفقًا على حساب واحد، فهذا هو
-- المرجع الحتمي للأرض.
with farm_usage as (
  select
    b.farm_id,
    b.farmer_well_account_id
  from ops.irrigation_bookings b
  where b.farm_id is not null
    and b.farmer_well_account_id is not null

  union all

  select
    s.farm_id,
    s.farmer_well_account_id
  from ops.irrigation_sessions s
  where s.farm_id is not null
    and s.farmer_well_account_id is not null
),
resolved as (
  select
    u.farm_id,
    min(u.farmer_well_account_id::text)::uuid
      as farmer_well_account_id
  from farm_usage u
  group by u.farm_id
  having count(distinct u.farmer_well_account_id) = 1
)
update ops.farms f
set farmer_well_account_id = r.farmer_well_account_id
from resolved r
where r.farm_id = f.id;


-- إذا كانت الأرض القديمة مرتبطة بحساب دخول، ولم توجد حقيقة
-- تشغيلية تسمح بتحويلها إلى Farmer Well Account، فلا نخمن.
do $$
begin
  if exists (
    select 1
    from ops.farms f
    where f.farmer_profile_id is not null
      and f.farmer_well_account_id is null
  ) then
    raise exception
      'ق-80: توجد أرض مرتبطة بـ Login Profile ولا يمكن اشتقاق Farmer Well Account لها حتميًا؛ يلزم تعيين يدوي قبل 075';
  end if;
end;
$$;


-- ==============================================================
-- C. إزالة نموذج Login Profile القديم
-- ==============================================================

alter table ops.farms
  drop constraint if exists farms_farmer_profile_id_fkey;

alter table ops.farms
  drop column farmer_profile_id;


-- ==============================================================
-- D. قيود قاعدة البيانات
-- ==============================================================

-- يلزم مفتاح مركب حتى تضمن القاعدة نفسها أن حساب المزارع
-- والأرض ينتميان إلى البئر نفسه.
alter table ops.farmer_well_accounts
  add constraint farmer_well_accounts_well_id_id_key
  unique (well_id, id);


alter table ops.farms
  add constraint farms_well_farmer_account_fkey
  foreign key (well_id, farmer_well_account_id)
  references ops.farmer_well_accounts (well_id, id);


-- يسمح بإنشاء أرض غير معيّنة لمزارع على مستوى الجدول،
-- لذلك farmer_well_account_id يبقى nullable.
--
-- المفتاح التالي يسمح بإجبار Booking/Session على استخدام
-- حساب المزارع الخاص بالأرض نفسها.
alter table ops.farms
  add constraint farms_id_farmer_account_key
  unique (id, farmer_well_account_id);


alter table ops.irrigation_bookings
  add constraint irrigation_bookings_farm_farmer_account_fkey
  foreign key (farm_id, farmer_well_account_id)
  references ops.farms (id, farmer_well_account_id);


alter table ops.irrigation_sessions
  add constraint irrigation_sessions_farm_farmer_account_fkey
  foreign key (farm_id, farmer_well_account_id)
  references ops.farms (id, farmer_well_account_id);


create index if not exists idx_farms_farmer_well_account
  on ops.farms (farmer_well_account_id);


-- ==============================================================
-- E. رسالة أعمال واضحة قبل الوصول إلى FK
-- ==============================================================

create function ops.enforce_farm_assignment_consistency()
returns trigger
language plpgsql
security invoker
set search_path = ops, pg_temp
as $function$
declare
  v_farm_well_id uuid;
  v_farm_account_id uuid;
begin
  if new.farm_id is null then
    return new;
  end if;

  select
    f.well_id,
    f.farmer_well_account_id
  into
    v_farm_well_id,
    v_farm_account_id
  from ops.farms f
  where f.id = new.farm_id;

  -- FK الخاص بـ farm_id سيحمي حالة عدم وجود الأرض.
  if not found then
    return new;
  end if;

  if v_farm_well_id <> new.well_id then
    raise exception
      'الأرض لا تتبع البئر المحدد';
  end if;

  if v_farm_account_id is null then
    if new.farmer_well_account_id is not null then
      raise exception
        'الأرض غير مرتبطة بحساب مزارع في هذا البئر';
    end if;

    return new;
  end if;

  if new.farmer_well_account_id is distinct from v_farm_account_id then
    raise exception
      'الأرض لا تخص حساب المزارع المحدد';
  end if;

  return new;
end;
$function$;


revoke all on function
  ops.enforce_farm_assignment_consistency()
from public, anon, authenticated, service_role;


create trigger trg_irrigation_bookings_farm_assignment
before insert or update of
  well_id,
  farm_id,
  farmer_well_account_id
on ops.irrigation_bookings
for each row
execute function ops.enforce_farm_assignment_consistency();


create trigger trg_irrigation_sessions_farm_assignment
before insert or update of
  well_id,
  farm_id,
  farmer_well_account_id
on ops.irrigation_sessions
for each row
execute function ops.enforce_farm_assignment_consistency();


-- ==============================================================
-- F. استبدال عقد ops.create_farm
--
-- نوع المعامل الثالث بقي uuid لكن اسمه ومعناه تغيّرا.
-- PostgreSQL لا يسمح بتغيير اسم input parameter بواسطة
-- CREATE OR REPLACE، لذلك يعاد إنشاء الدالة صراحة.
-- ==============================================================

drop function ops.create_farm(uuid, text, uuid);


create function ops.create_farm(
  p_well_id uuid,
  p_name text,
  p_farmer_well_account_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ops, core, audit, iam, pg_temp
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_farm_id uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception
      'يجب تسجيل الدخول قبل إنشاء أرض';
  end if;

  if not iam.has_well_role(
    p_well_id,
    array['owner']
  ) then
    raise exception
      'لا تملك صلاحية إنشاء أرض في هذا البئر';
  end if;

  if nullif(btrim(p_name), '') is null then
    raise exception
      'اسم الأرض مطلوب';
  end if;

  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id;

  if not found then
    raise exception
      'البئر غير موجود: %',
      p_well_id;
  end if;

  if p_farmer_well_account_id is null
     or not exists (
       select 1
       from ops.farmer_well_accounts fwa
       where fwa.id = p_farmer_well_account_id
         and fwa.well_id = p_well_id
         and fwa.tenant_id = v_tenant_id
         and fwa.status = 'active'
     ) then
    raise exception
      'حساب المزارع غير موجود أو غير فعال في هذا البئر';
  end if;

  -- إنشاء الأرض لا يتوقف بسبب وجود جلسة سقي مفتوحة.
  insert into ops.farms (
    well_id,
    name,
    farmer_well_account_id,
    status
  )
  values (
    p_well_id,
    btrim(p_name),
    p_farmer_well_account_id,
    'active'
  )
  returning id into v_farm_id;

  perform audit.log(
    v_tenant_id,
    p_well_id,
    'create_farm',
    'ops.farms',
    v_farm_id,
    null,
    jsonb_build_object(
      'farm_id',
      v_farm_id,
      'name',
      btrim(p_name),
      'farmer_well_account_id',
      p_farmer_well_account_id
    ),
    'إنشاء أرض للمزارع'
  );

  return jsonb_build_object(
    'farm_id',
    v_farm_id,
    'well_id',
    p_well_id,
    'farmer_well_account_id',
    p_farmer_well_account_id,
    'status',
    'active'
  );
end;
$function$;


revoke all on function
  ops.create_farm(uuid, text, uuid)
from public, anon, authenticated, service_role;

grant execute on function
  ops.create_farm(uuid, text, uuid)
to authenticated, service_role;


-- ==============================================================
-- G. كشف create_farm داخل عقد api بعد حسم م-22
-- ==============================================================

create function api.create_farm(
  p_well_id uuid,
  p_name text,
  p_farmer_well_account_id uuid
)
returns jsonb
language sql
security invoker
set search_path = pg_catalog, pg_temp
as $function$
  select ops.create_farm(
    p_well_id,
    p_name,
    p_farmer_well_account_id
  );
$function$;


revoke all on function
  api.create_farm(uuid, text, uuid)
from public, anon, authenticated, service_role;

grant execute on function
  api.create_farm(uuid, text, uuid)
to authenticated, service_role;


commit;

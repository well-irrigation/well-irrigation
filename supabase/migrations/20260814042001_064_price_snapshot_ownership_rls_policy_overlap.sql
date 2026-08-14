-- القرار ق-77 - الملف 064: لقطة السعر، مجموع الملكية، تهيئة الجهة الآمنة، ومنع تداخل السياسات

create extension if not exists btree_gist;

-- 1) تثبيت سعر الجلسة وقت البدء (ق-02 وق-20)
alter table ops.irrigation_sessions
  add column price_per_hour_minor_snapshot bigint;

create or replace function ops.capture_session_price_snapshot()
returns trigger
language plpgsql
security definer
set search_path to 'ops', 'billing', 'pg_temp'
as $function$
declare
  v_price_per_hour_minor bigint;
begin
  select wp.price_per_hour_minor
    into v_price_per_hour_minor
  from billing.well_pricing wp
  where wp.well_id = new.well_id
    and wp.period_start <= new.started_at
    and (wp.period_end is null or wp.period_end > new.started_at)
  order by wp.period_start desc, wp.created_at desc, wp.id desc
  limit 1;

  new.price_per_hour_minor_snapshot := v_price_per_hour_minor;
  return new;
end;
$function$;

revoke all on function ops.capture_session_price_snapshot() from public;

create trigger irrigation_sessions_capture_price_snapshot
before insert on ops.irrigation_sessions
for each row execute function ops.capture_session_price_snapshot();

create or replace function ops.compute_session_charge()
returns trigger
language plpgsql
security definer
set search_path to 'ops', 'billing', 'pg_temp'
as $function$
declare
  v_duration_seconds integer;
  v_price_per_hour_minor bigint;
  v_amount_minor bigint;
begin
  if new.status in ('closed', 'forgotten') and new.ended_at is not null
     and old.status = 'open' then

    v_duration_seconds := extract(epoch from (new.ended_at - new.started_at))::integer;
    v_price_per_hour_minor := new.price_per_hour_minor_snapshot;

    if v_price_per_hour_minor is null then
      raise exception 'لا يوجد سعر مثبت لهذه الجلسة — يجب ضبط سعر البئر قبل بدء الجلسة';
    end if;

    v_amount_minor := (v_duration_seconds::bigint * v_price_per_hour_minor) / 3600;

    insert into billing.session_charges
      (session_id, well_id, duration_seconds, price_per_hour_minor, amount_minor)
    values
      (new.id, new.well_id, v_duration_seconds, v_price_per_hour_minor, v_amount_minor);
  end if;

  return new;
end;
$function$;

-- 2) مجموع الملكية والأرباح الفعالة يساوي 100% (ق-22)
create or replace function core.check_well_profit_shares_total()
returns trigger
language plpgsql
as $function$
declare
  ownership_total numeric;
  profit_total numeric;
  target_well uuid;
begin
  target_well := coalesce(new.well_id, old.well_id);

  select
    coalesce(sum(ownership_percentage), 0),
    coalesce(sum(profit_percentage), 0)
  into ownership_total, profit_total
  from core.ownership_share_versions
  where well_id = target_well
    and effective_period @> current_date;

  if ownership_total <> 100 then
    raise exception 'مجموع نسب ملكية الشركاء الفعالة للبئر % يجب أن يساوي 100 بالضبط، والقيمة الحالية %',
      target_well, ownership_total;
  end if;

  if profit_total <> 100 then
    raise exception 'مجموع نسب أرباح الشركاء الفعالة للبئر % يجب أن يساوي 100 بالضبط، والقيمة الحالية %',
      target_well, profit_total;
  end if;

  return new;
end;
$function$;

-- 3) تهيئة جهة وبئر بصورة ذرية وإغلاق سياسات الإدخال العامة (م-15)
drop policy tenants_insert_authenticated on core.tenants;
drop policy wells_insert_authenticated on core.wells;

create or replace function core.create_tenant_with_well(
  p_tenant_name text,
  p_well_name text
)
returns uuid
language plpgsql
security definer
set search_path to 'core', 'pg_temp'
as $function$
declare
  v_user_id uuid;
  v_tenant_id uuid;
  v_well_id uuid;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء جهة وبئر';
  end if;

  if not exists (select 1 from iam.profiles p where p.id = v_user_id) then
    raise exception 'لا يوجد ملف مستخدم صالح للحساب المسجل';
  end if;

  if nullif(btrim(p_tenant_name), '') is null then
    raise exception 'اسم الجهة مطلوب';
  end if;

  if nullif(btrim(p_well_name), '') is null then
    raise exception 'اسم البئر مطلوب';
  end if;

  insert into core.tenants (name)
  values (btrim(p_tenant_name))
  returning id into v_tenant_id;

  insert into core.wells (tenant_id, name)
  values (v_tenant_id, btrim(p_well_name))
  returning id into v_well_id;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well_id, v_user_id, 'owner', 'active');

  return v_well_id;
end;
$function$;

revoke all on function core.create_tenant_with_well(text, text) from public;
grant execute on function core.create_tenant_with_well(text, text) to authenticated;

create or replace function core.is_active_owner_in_tenant(
  p_tenant_id uuid,
  p_excluded_well_id uuid
)
returns boolean
language sql
stable
security definer
set search_path to 'core', 'pg_temp'
as $function$
  select exists (
    select 1
    from core.wells w
    join core.well_assignments wa on wa.well_id = w.id
    where w.tenant_id = p_tenant_id
      and w.id is distinct from p_excluded_well_id
      and wa.profile_id = auth.uid()
      and wa.role = 'owner'
      and wa.status = 'active'
  );
$function$;

revoke all on function core.is_active_owner_in_tenant(uuid, uuid) from public;
grant execute on function core.is_active_owner_in_tenant(uuid, uuid) to authenticated;

create policy wells_insert_existing_tenant_owner
on core.wells
for insert
to authenticated
with check (core.is_active_owner_in_tenant(tenant_id, id));

-- 4) منع تداخل سياسات سقي الشريك التاريخية (م-05)
alter table core.partner_irrigation_policies
  add constraint no_partner_policy_period_overlap
  exclude using gist (
    partner_id with =,
    daterange(period_start, period_end, '[)'::text) with &&
  );

-- 5) حذف أثر التقريب الملغى (ق-12)
alter table billing.invoices drop column rounding_minor;

-- ق-81
-- نموذج المضخة = بيانات المعدة.
-- مصدر الطاقة الفعلي = مقاطع جلسة السقي.
-- resource_concurrency_rules = مصدر حدود التوازي.
--
-- power_source يبقى مؤقتًا للتوافق مع الجلسات التاريخية flat فقط،
-- ولا يعد مصدر الحقيقة للجلسات الحديثة.

-- =============================================================
-- 1. Expand core.pumps to the canonical equipment model
-- =============================================================

alter table core.pumps
  add column tenant_id uuid,
  add column public_code text,
  add column pump_type text,
  add column power_rating text,
  add column estimated_fuel_ml_per_hour bigint,
  add column estimated_water_flow_liters_per_minute numeric(14,3),
  add column installed_at date,
  add column notes text;

alter table core.pumps
  alter column power_source drop not null;

comment on column core.pumps.power_source is
  'Legacy compatibility only for historical flat sessions; actual session energy source belongs to ops.session_segments.energy_source.';

-- Backfill existing pumps.
update core.pumps p
set
  tenant_id = w.tenant_id,
  public_code = 'P-' || replace(p.id::text, '-', '')
from core.wells w
where w.id = p.well_id;

alter table core.pumps
  alter column tenant_id set not null,
  alter column public_code set not null;

alter table core.pumps
  add constraint pumps_tenant_id_fkey
    foreign key (tenant_id)
    references core.tenants(id);

alter table core.pumps
  add constraint pumps_well_public_code_key
    unique (well_id, public_code);

alter table core.pumps
  add constraint pumps_estimated_fuel_ml_per_hour_check
    check (
      estimated_fuel_ml_per_hour is null
      or estimated_fuel_ml_per_hour >= 0
    );

alter table core.pumps
  add constraint pumps_estimated_water_flow_check
    check (
      estimated_water_flow_liters_per_minute is null
      or estimated_water_flow_liters_per_minute >= 0
    );

alter table core.pumps
  drop constraint pumps_status_check;

alter table core.pumps
  add constraint pumps_status_check
    check (
      status in (
        'active',
        'inactive',
        'maintenance',
        'retired'
      )
    );

create index pumps_tenant_id_idx
  on core.pumps (tenant_id);


-- =============================================================
-- 2. Derive tenant/public code safely from the well
--
-- This preserves historical fixtures that insert only:
-- well_id, name, power_source
-- =============================================================

create function core.prepare_pump_identity_076()
returns trigger
language plpgsql
set search_path = 'core', 'pg_temp'
as $function$
declare
  v_tenant_id uuid;
begin
  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = new.well_id;

  if v_tenant_id is null then
    raise exception 'البئر المحدد للمضخة غير موجود';
  end if;

  if new.tenant_id is null then
    new.tenant_id := v_tenant_id;
  elsif new.tenant_id is distinct from v_tenant_id then
    raise exception 'جهة المضخة لا تطابق جهة البئر';
  end if;

  if new.public_code is null
     or btrim(new.public_code) = '' then
    new.public_code :=
      'P-' || replace(new.id::text, '-', '');
  else
    new.public_code := btrim(new.public_code);
  end if;

  return new;
end;
$function$;

create trigger trg_prepare_pump_identity_076
before insert or update of well_id, tenant_id, public_code
on core.pumps
for each row
execute function core.prepare_pump_identity_076();


create function core.touch_pump_updated_at_076()
returns trigger
language plpgsql
set search_path = 'pg_catalog', 'pg_temp'
as $function$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$function$;

create trigger trg_touch_pump_updated_at_076
before update
on core.pumps
for each row
execute function core.touch_pump_updated_at_076();


-- =============================================================
-- 3. Reporting correctness
--
-- Modern sessions:
--   ops.session_segments.energy_source + billable_seconds.
--
-- Legacy flat sessions without any segments:
--   billing.session_charges.duration_seconds + old pump.power_source.
--
-- All closed/forgotten sessions remain attributed to END DAY
-- according to ق-65.
-- =============================================================

create or replace view reporting.well_daily_summary as
with days as (
  select
    s.well_id,
    date_trunc('day', s.ended_at)::date as day
  from ops.irrigation_sessions s
  where s.status in ('closed', 'forgotten')
    and s.ended_at is not null

  union

  select
    s.well_id,
    date_trunc('day', s.started_at)::date as day
  from ops.irrigation_sessions s
  where s.status = 'open'

  union

  select
    p.well_id,
    date_trunc('day', p.paid_at)::date as day
  from billing.payments p

  union

  select
    e.well_id,
    date_trunc('day', e.spent_at)::date as day
  from finance.expenses e

  union

  select
    f.well_id,
    date_trunc('day', f.occurred_at)::date as day
  from inventory.fuel_transactions f
),
session_energy as (
  select
    s.id as session_id,
    s.well_id,
    date_trunc('day', s.ended_at)::date as day,

    case
      when count(ss.id) > 0 then
        coalesce(
          sum(ss.billable_seconds)
            filter (where ss.energy_source = 'solar'),
          0
        )::bigint

      when p.power_source = 'solar' then
        coalesce(sc.duration_seconds, 0)::bigint

      else 0::bigint
    end as solar_seconds,

    case
      when count(ss.id) > 0 then
        coalesce(
          sum(ss.billable_seconds)
            filter (
              where ss.energy_source in (
                'well_diesel',
                'farmer_diesel'
              )
            ),
          0
        )::bigint

      when p.power_source = 'diesel' then
        coalesce(sc.duration_seconds, 0)::bigint

      else 0::bigint
    end as diesel_seconds

  from ops.irrigation_sessions s

  join core.pumps p
    on p.id = s.pump_id

  left join billing.session_charges sc
    on sc.session_id = s.id

  left join ops.session_segments ss
    on ss.session_id = s.id

  where s.status in ('closed', 'forgotten')
    and s.ended_at is not null

  group by
    s.id,
    s.well_id,
    s.ended_at,
    p.power_source,
    sc.duration_seconds
)
select
  w.tenant_id,
  d.well_id,
  d.day,

  (
    select count(*)
    from ops.irrigation_sessions s
    where s.well_id = d.well_id
      and s.status in ('closed', 'forgotten')
      and date_trunc('day', s.ended_at)::date = d.day
  ) as sessions_count,

  (
    select count(*)
    from ops.irrigation_sessions s
    where s.well_id = d.well_id
      and s.status = 'open'
      and date_trunc('day', s.started_at)::date = d.day
  ) as open_sessions,

  (
    select coalesce(sum(se.solar_seconds), 0)::bigint
    from session_energy se
    where se.well_id = d.well_id
      and se.day = d.day
  ) as solar_seconds,

  (
    select coalesce(sum(se.diesel_seconds), 0)::bigint
    from session_energy se
    where se.well_id = d.well_id
      and se.day = d.day
  ) as diesel_seconds,

  (
    select coalesce(sum(sc.amount_minor), 0)
    from billing.session_charges sc
    join ops.irrigation_sessions s
      on s.id = sc.session_id
    where s.well_id = d.well_id
      and s.status in ('closed', 'forgotten')
      and date_trunc('day', s.ended_at)::date = d.day
  ) as charges_minor,

  (
    select coalesce(sum(p.amount_minor), 0)
    from billing.payments p
    where p.well_id = d.well_id
      and p.status = 'posted'
      and date_trunc('day', p.paid_at)::date = d.day
  ) as collected_minor,

  (
    select coalesce(sum(e.amount_minor), 0)
    from finance.expenses e
    where e.well_id = d.well_id
      and e.status = 'posted'
      and date_trunc('day', e.spent_at)::date = d.day
  ) as expenses_minor,

  (
    select coalesce(sum(f.quantity_ml), 0)
    from inventory.fuel_transactions f
    where f.well_id = d.well_id
      and f.status = 'posted'
      and f.direction = 'out'
      and date_trunc('day', f.occurred_at)::date = d.day
  ) as fuel_out_ml

from days d
join core.wells w
  on w.id = d.well_id;


comment on view reporting.well_daily_summary is
  'Q81: modern energy totals come from session segments; legacy flat sessions without segments use pump.power_source only as compatibility fallback.';


-- =============================================================
-- 4. Reservation concurrency
--
-- Precedence:
-- resource-specific active rule
-- -> well-wide active rule
-- -> resource default
--
-- Pump default = 1.
-- Water-line default = core.water_lines.max_parallel_sessions.
-- =============================================================

create or replace function ops.reserve_resource(
  p_well_id uuid,
  p_resource_type text,
  p_resource_id uuid,
  p_reserved_period tstzrange,
  p_booking_id uuid default null,
  p_session_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = 'ops', 'core', 'pg_temp'
as $function$
declare
  v_tenant_id uuid;
  v_default_limit integer;
  v_rule_limit integer;
  v_max_parallel integer;
  v_active_count integer;
  v_reservation_id uuid;
begin
  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id;

  if v_tenant_id is null then
    raise exception 'البئر المحدد غير موجود: %', p_well_id;
  end if;

  if p_resource_type = 'water_line' then

    select wl.max_parallel_sessions
    into v_default_limit
    from core.water_lines wl
    where wl.id = p_resource_id
      and wl.well_id = p_well_id
      and wl.status = 'active'
    for update;

    if not found then
      raise exception
        'المورد المحدد غير موجود أو غير فعال في هذا البئر: % (%)',
        p_resource_id,
        p_resource_type;
    end if;

  elsif p_resource_type = 'pump' then

    perform 1
    from core.pumps p
    where p.id = p_resource_id
      and p.well_id = p_well_id
      and p.status = 'active'
    for update;

    if not found then
      raise exception
        'المورد المحدد غير موجود أو غير فعال في هذا البئر: % (%)',
        p_resource_id,
        p_resource_type;
    end if;

    v_default_limit := 1;

  else
    raise exception
      'نوع المورد غير صالح للحجز: %',
      p_resource_type;
  end if;

  select r.max_parallel_sessions
  into v_rule_limit
  from ops.resource_concurrency_rules r
  where r.well_id = p_well_id
    and r.rule_status = 'active'
    and (
      (
        r.resource_type = p_resource_type
        and r.resource_id = p_resource_id
      )
      or r.resource_type = 'well'
    )
  order by
    case
      when r.resource_type = p_resource_type
       and r.resource_id = p_resource_id
      then 0
      else 1
    end
  limit 1;

  v_max_parallel :=
    coalesce(v_rule_limit, v_default_limit);

  select count(*)
  into v_active_count
  from ops.resource_reservations rr
  where rr.resource_type = p_resource_type
    and rr.resource_id = p_resource_id
    and rr.status = 'active'
    and rr.reserved_period && p_reserved_period;

  if v_active_count >= v_max_parallel then
    raise exception
      'المورد محجوز بالكامل خلال هذه الفترة (الحد الأقصى للتوازي: %)',
      v_max_parallel;
  end if;

  insert into ops.resource_reservations (
    tenant_id,
    well_id,
    resource_type,
    resource_id,
    booking_id,
    session_id,
    reserved_period,
    status
  )
  values (
    v_tenant_id,
    p_well_id,
    p_resource_type,
    p_resource_id,
    p_booking_id,
    p_session_id,
    p_reserved_period,
    'active'
  )
  returning id into v_reservation_id;

  return v_reservation_id;
end;
$function$;

-- القرار ق-77 - الملف 065: يوم الجلسة هو يوم النهاية والجلسة المفتوحة معلوماتية فقط

create or replace view reporting.well_daily_summary
with (security_invoker = true) as
with days as (
  select well_id, date_trunc('day', ended_at)::date as day
  from ops.irrigation_sessions
  where status in ('closed', 'forgotten') and ended_at is not null

  union

  select well_id, date_trunc('day', started_at)::date as day
  from ops.irrigation_sessions
  where status = 'open'

  union

  select well_id, date_trunc('day', paid_at)::date
  from billing.payments

  union

  select well_id, date_trunc('day', spent_at)::date
  from finance.expenses

  union

  select well_id, date_trunc('day', occurred_at)::date
  from inventory.fuel_transactions
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
    select coalesce(sum(sc.duration_seconds), 0)
    from billing.session_charges sc
    join ops.irrigation_sessions s on s.id = sc.session_id
    join core.pumps p on p.id = s.pump_id
    where s.well_id = d.well_id
      and s.status in ('closed', 'forgotten')
      and date_trunc('day', s.ended_at)::date = d.day
      and p.power_source = 'solar'
  ) as solar_seconds,
  (
    select coalesce(sum(sc.duration_seconds), 0)
    from billing.session_charges sc
    join ops.irrigation_sessions s on s.id = sc.session_id
    join core.pumps p on p.id = s.pump_id
    where s.well_id = d.well_id
      and s.status in ('closed', 'forgotten')
      and date_trunc('day', s.ended_at)::date = d.day
      and p.power_source = 'diesel'
  ) as diesel_seconds,
  (
    select coalesce(sum(sc.amount_minor), 0)
    from billing.session_charges sc
    join ops.irrigation_sessions s on s.id = sc.session_id
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
join core.wells w on w.id = d.well_id;

grant select on reporting.well_daily_summary to authenticated;

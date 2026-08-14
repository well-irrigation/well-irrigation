-- الدفعة الختامية - الملف 060 (ق-75): عروض التقارير المحسوبة (doc03 قسم 51، doc02 قسم 42-45)
-- عروض حية وليست ارصدة مخزنة يدويا، وترث صلاحيات القارئ (security_invoker)

create schema if not exists reporting;
grant usage on schema reporting to authenticated;

-- 51.1 رصيد المزارع: الفواتير والمخصص والمقدم والدين المتبقي
create view reporting.farmer_account_balances with (security_invoker = true) as
select a.tenant_id, a.well_id, a.id as farmer_well_account_id, a.public_code,
       coalesce(inv.total_billed, 0) as invoiced_minor,
       coalesce(alloc.allocated_minor, 0) as allocated_minor,
       coalesce(adv.advance_minor, 0) as advance_minor,
       coalesce(inv.total_billed, 0) - coalesce(alloc.allocated_minor, 0) as debt_minor
from ops.farmer_well_accounts a
left join (select farmer_well_account_id, sum(total_minor) as total_billed
           from billing.invoices where status not in ('cancelled', 'reversed') group by 1) inv
  on inv.farmer_well_account_id = a.id
left join (select i.farmer_well_account_id, sum(pa.allocated_minor) as allocated_minor
           from billing.payment_allocations pa join billing.invoices i on i.id = pa.invoice_id group by 1) alloc
  on alloc.farmer_well_account_id = a.id
left join (select farmer_well_account_id, sum(amount_minor) as advance_minor
           from billing.payments where purpose = 'advance' and status = 'posted' group by 1) adv
  on adv.farmer_well_account_id = a.id;
grant select on reporting.farmer_account_balances to authenticated;

-- 51.2 رصيد الصندوق: مجموع المدين ناقص الدائن من القيود المرحلة المرتبطة بالصندوق
create view reporting.cashbox_balances with (security_invoker = true) as
select w.tenant_id, c.well_id, c.id as cashbox_id, c.public_code, c.name,
       coalesce(sum(case when l.entry_side = 'debit' and e.status = 'posted' then l.amount_minor else 0 end), 0)
     - coalesce(sum(case when l.entry_side = 'credit' and e.status = 'posted' then l.amount_minor else 0 end), 0) as balance_minor
from finance.cashboxes c
join core.wells w on w.id = c.well_id
left join finance.journal_lines l on l.cashbox_id = c.id
left join finance.journal_entries e on e.id = l.journal_entry_id
group by w.tenant_id, c.well_id, c.id, c.public_code, c.name;
grant select on reporting.cashbox_balances to authenticated;

-- 51.3 رصيد الوقود: ديزل البئر وديزل المزارعين والمعلق تقديريا
create view reporting.fuel_balances with (security_invoker = true) as
select w.tenant_id, t.well_id, t.id as fuel_tank_id, t.name,
       t.current_balance_ml, t.avg_cost_per_liter_minor,
       coalesce(farm.farmer_total_ml, 0) as farmers_total_ml,
       coalesce(est.pending_estimated_ml, 0) as pending_estimated_ml
from inventory.fuel_tanks t
join core.wells w on w.id = t.well_id
left join (select well_id, sum(case when direction = 'in' then quantity_ml else -quantity_ml end) as farmer_total_ml
           from inventory.fuel_transactions where ownership_type = 'farmer' and status = 'posted' group by well_id) farm
  on farm.well_id = t.well_id
left join (select fuel_tank_id, sum(quantity_ml) as pending_estimated_ml
           from inventory.fuel_transactions where status = 'pending_actual_measurement' group by 1) est
  on est.fuel_tank_id = t.id;
grant select on reporting.fuel_balances to authenticated;

-- 51.4 حساب الشريك: النسبة الحالية والارباح والاستقطاعات والمستحقات
create view reporting.partner_account_summary with (security_invoker = true) as
select wp.tenant_id, wp.well_id, wp.id as partner_id, pr.full_name as partner_name,
       (select v.profit_percentage from core.ownership_share_versions v
        where v.partner_id = wp.id and v.effective_period @> current_date
        order by lower(v.effective_period) desc limit 1) as current_profit_percentage,
       coalesce(dl.gross_total, 0) as gross_earned_minor,
       coalesce(dl.irrigation_total, 0) as irrigation_deducted_minor,
       coalesce(dl.receivables_total, 0) as expenses_paid_minor,
       coalesce(dl.net_total, 0) as net_payable_minor,
       coalesce(dl.unpaid_total, 0) as unpaid_minor
from core.well_partners wp
join core.persons pr on pr.id = wp.person_id
left join (
  select c.well_id, l.partner_id,
         sum(l.gross_share_minor) as gross_total,
         sum(l.irrigation_deductions_minor) as irrigation_total,
         sum(l.partner_receivables_minor) as receivables_total,
         sum(l.net_payable_minor) as net_total,
         sum(case when l.status in ('approved', 'partially_paid', 'carried_forward') then l.net_payable_minor else 0 end) as unpaid_total
  from finance.profit_distribution_lines l
  join finance.profit_distribution_cycles c on c.id = l.distribution_cycle_id
  where c.status <> 'cancelled'
  group by c.well_id, l.partner_id
) dl on dl.partner_id = wp.id;
grant select on reporting.partner_account_summary to authenticated;

-- 51.5 التقرير اليومي للبئر
create view reporting.well_daily_summary with (security_invoker = true) as
with days as (
  select well_id, date_trunc('day', started_at)::date as day from ops.irrigation_sessions
  union select well_id, date_trunc('day', paid_at)::date from billing.payments
  union select well_id, date_trunc('day', spent_at)::date from finance.expenses
  union select well_id, date_trunc('day', occurred_at)::date from inventory.fuel_transactions
)
select w.tenant_id, d.well_id, d.day,
  (select count(*) from ops.irrigation_sessions s
   where s.well_id = d.well_id and date_trunc('day', s.started_at)::date = d.day) as sessions_count,
  (select count(*) from ops.irrigation_sessions s
   where s.well_id = d.well_id and date_trunc('day', s.started_at)::date = d.day and s.status = 'open') as open_sessions,
  (select coalesce(sum(sc.duration_seconds), 0) from billing.session_charges sc
   join ops.irrigation_sessions s on s.id = sc.session_id join core.pumps p on p.id = s.pump_id
   where s.well_id = d.well_id and date_trunc('day', s.started_at)::date = d.day and p.power_source = 'solar') as solar_seconds,
  (select coalesce(sum(sc.duration_seconds), 0) from billing.session_charges sc
   join ops.irrigation_sessions s on s.id = sc.session_id join core.pumps p on p.id = s.pump_id
   where s.well_id = d.well_id and date_trunc('day', s.started_at)::date = d.day and p.power_source = 'diesel') as diesel_seconds,
  (select coalesce(sum(sc.amount_minor), 0) from billing.session_charges sc
   join ops.irrigation_sessions s on s.id = sc.session_id
   where s.well_id = d.well_id and date_trunc('day', s.started_at)::date = d.day) as charges_minor,
  (select coalesce(sum(p.amount_minor), 0) from billing.payments p
   where p.well_id = d.well_id and p.status = 'posted' and date_trunc('day', p.paid_at)::date = d.day) as collected_minor,
  (select coalesce(sum(e.amount_minor), 0) from finance.expenses e
   where e.well_id = d.well_id and e.status = 'posted' and date_trunc('day', e.spent_at)::date = d.day) as expenses_minor,
  (select coalesce(sum(f.quantity_ml), 0) from inventory.fuel_transactions f
   where f.well_id = d.well_id and f.status = 'posted' and f.direction = 'out'
     and date_trunc('day', f.occurred_at)::date = d.day) as fuel_out_ml
from days d
join core.wells w on w.id = d.well_id;
grant select on reporting.well_daily_summary to authenticated;

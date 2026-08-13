-- المرحلة 4 - الملف 045
-- ربط الجلسات بالمناوبة المفتوحة تلقائيا، وتوحيد عمود المستلم في الدفعات،
-- ودالتا التقرير: تقرير المناوبة الواحدة واجمالي المشغل بالارقام الخمسة.
-- المرجع: قرار المالك (تقرير مفصل للمالك لكل مناوبة + شاشة حسابي للمشغل)

-- ربط الجلسة بالمناوبة المفتوحة وتحديد صاحب حق التحصيل
create or replace function ops.attach_session_to_open_shift()
returns trigger
language plpgsql
security definer
set search_path to 'ops', 'pg_temp'
as $$
begin
  if new.current_shift_id is null then
    select s.id into new.current_shift_id from ops.shifts s
    where s.well_id = new.well_id and s.status = 'open' limit 1;
  end if;

  if new.collector_profile_id is null then
    if new.current_shift_id is not null then
      select s.operator_profile_id into new.collector_profile_id
      from ops.shifts s where s.id = new.current_shift_id;
    end if;
    new.collector_profile_id := coalesce(new.collector_profile_id, new.operator_profile_id);
  end if;

  return new;
end;
$$;

create trigger irrigation_sessions_attach_shift
before insert on ops.irrigation_sessions
for each row execute function ops.attach_session_to_open_shift();

-- توحيد العمودين: القديم received_by_profile_id يُملأ مثل الجديد
create or replace function billing.fill_payment_context()
returns trigger
language plpgsql
security definer
set search_path to 'billing', 'ops', 'finance', 'core', 'pg_temp'
as $$
declare
  v_well_id uuid;
begin
  if new.well_id is null then
    if new.session_charge_id is not null then
      select sc.well_id into v_well_id from billing.session_charges sc where sc.id = new.session_charge_id;
    elsif new.farmer_well_account_id is not null then
      select fwa.well_id into v_well_id from ops.farmer_well_accounts fwa where fwa.id = new.farmer_well_account_id;
    end if;
    new.well_id := v_well_id;
  end if;

  if new.tenant_id is null and new.well_id is not null then
    select w.tenant_id into new.tenant_id from core.wells w where w.id = new.well_id;
  end if;

  if new.cashbox_id is null and new.well_id is not null then
    new.cashbox_id := finance.main_cashbox_id(new.well_id);
  end if;

  if new.shift_id is null and new.well_id is not null then
    select s.id into new.shift_id from ops.shifts s
    where s.well_id = new.well_id and s.status = 'open' limit 1;
  end if;

  if new.collected_by_profile_id is null and new.shift_id is not null then
    select s.operator_profile_id into new.collected_by_profile_id from ops.shifts s where s.id = new.shift_id;
  end if;

  new.collected_by_profile_id := coalesce(new.collected_by_profile_id, new.received_by_profile_id);
  new.received_by_profile_id := coalesce(new.received_by_profile_id, new.collected_by_profile_id);

  return new;
end;
$$;

-- تقرير مناوبة واحدة بالارقام الخمسة مع التفصيل
create or replace function ops.shift_report(p_shift_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'ops', 'billing', 'finance', 'iam', 'pg_temp'
as $$
declare
  v_s record;
  v_collected bigint;
  v_expenses bigint;
  v_handed bigint;
  v_debt bigint;
  v_sessions integer;
  v_open_sessions integer;
  v_operator text;
  v_payments jsonb;
  v_expense_items jsonb;
begin
  select * into v_s from ops.shifts where id = p_shift_id;
  if v_s.id is null then
    raise exception 'المناوبة % غير موجودة', p_shift_id;
  end if;

  select full_name into v_operator from iam.profiles where id = v_s.operator_profile_id;

  select coalesce(sum(amount_minor), 0) into v_collected
  from billing.payments where shift_id = p_shift_id and status <> 'reversed';

  select coalesce(sum(amount_minor), 0) into v_expenses
  from finance.expenses where shift_id = p_shift_id and status in ('posted', 'approved');

  select coalesce(sum(coalesce(confirmed_amount_minor, declared_amount_minor)), 0) into v_handed
  from ops.shift_handovers where shift_id = p_shift_id and status in ('confirmed', 'settled');

  select count(*), coalesce(sum(case when s.status = 'open' then 1 else 0 end), 0)
  into v_sessions, v_open_sessions
  from ops.irrigation_sessions s where s.current_shift_id = p_shift_id;

  select coalesce(sum(sc.amount_minor), 0) - coalesce((
    select sum(p.amount_minor) from billing.payments p
    where p.session_charge_id in (
      select sc2.id from billing.session_charges sc2
      join ops.irrigation_sessions s2 on s2.id = sc2.session_id
      where s2.current_shift_id = p_shift_id
    ) and p.status <> 'reversed'
  ), 0)
  into v_debt
  from billing.session_charges sc
  join ops.irrigation_sessions s on s.id = sc.session_id
  where s.current_shift_id = p_shift_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'public_code', p.public_code, 'amount_minor', p.amount_minor,
    'purpose', p.purpose, 'method', p.method, 'paid_at', p.paid_at, 'note', p.note
  ) order by p.paid_at), '[]'::jsonb) into v_payments
  from billing.payments p where p.shift_id = p_shift_id and p.status <> 'reversed';

  select coalesce(jsonb_agg(jsonb_build_object(
    'public_code', e.public_code, 'amount_minor', e.amount_minor,
    'description', e.description, 'spent_at', e.spent_at,
    'has_attachment', (e.attachment_url is not null), 'status', e.status
  ) order by e.spent_at), '[]'::jsonb) into v_expense_items
  from finance.expenses e where e.shift_id = p_shift_id and e.status <> 'reversed';

  return jsonb_build_object(
    'shift_id', p_shift_id,
    'public_code', v_s.public_code,
    'operator', v_operator,
    'status', v_s.status,
    'started_at', v_s.started_at,
    'ended_at', v_s.ended_at,
    'collected_minor', v_collected,
    'expenses_minor', v_expenses,
    'handed_over_minor', v_handed,
    'farmer_debt_minor', greatest(v_debt, 0),
    'in_hand_minor', v_collected - v_expenses - v_handed,
    'sessions_count', v_sessions,
    'open_sessions_count', v_open_sessions,
    'payments', v_payments,
    'expenses', v_expense_items
  );
end;
$$;

-- اجمالي المشغل: نفس الارقام الخمسة لكل مناوباته
create or replace function ops.operator_totals(p_profile_id uuid, p_well_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'ops', 'billing', 'finance', 'pg_temp'
as $$
declare
  v_collected bigint;
  v_expenses bigint;
  v_handed bigint;
  v_debt bigint;
  v_shifts integer;
begin
  select count(*) into v_shifts from ops.shifts s
  where s.operator_profile_id = p_profile_id
    and (p_well_id is null or s.well_id = p_well_id);

  select coalesce(sum(p.amount_minor), 0) into v_collected
  from billing.payments p
  join ops.shifts s on s.id = p.shift_id
  where s.operator_profile_id = p_profile_id
    and (p_well_id is null or s.well_id = p_well_id)
    and p.status <> 'reversed';

  select coalesce(sum(e.amount_minor), 0) into v_expenses
  from finance.expenses e
  join ops.shifts s on s.id = e.shift_id
  where s.operator_profile_id = p_profile_id
    and (p_well_id is null or s.well_id = p_well_id)
    and e.status in ('posted', 'approved');

  select coalesce(sum(coalesce(h.confirmed_amount_minor, h.declared_amount_minor)), 0) into v_handed
  from ops.shift_handovers h
  where h.from_profile_id = p_profile_id
    and (p_well_id is null or h.well_id = p_well_id)
    and h.status in ('confirmed', 'settled');

  select coalesce(sum(sc.amount_minor), 0) - coalesce((
    select sum(p.amount_minor) from billing.payments p
    where p.session_charge_id in (
      select sc2.id from billing.session_charges sc2
      join ops.irrigation_sessions s2 on s2.id = sc2.session_id
      where s2.collector_profile_id = p_profile_id
        and (p_well_id is null or s2.well_id = p_well_id)
    ) and p.status <> 'reversed'
  ), 0)
  into v_debt
  from billing.session_charges sc
  join ops.irrigation_sessions s on s.id = sc.session_id
  where s.collector_profile_id = p_profile_id
    and (p_well_id is null or s.well_id = p_well_id);

  return jsonb_build_object(
    'profile_id', p_profile_id,
    'shifts_count', v_shifts,
    'collected_minor', v_collected,
    'expenses_minor', v_expenses,
    'handed_over_minor', v_handed,
    'farmer_debt_minor', greatest(v_debt, 0),
    'unsettled_minor', v_collected - v_expenses - v_handed
  );
end;
$$;

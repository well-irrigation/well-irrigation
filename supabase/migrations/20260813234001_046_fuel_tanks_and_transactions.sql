-- المرحلة 4 - الملف 046
-- خزانات الوقود وحركاته بانواعها العشرة، بملكية بئر او مزارع،
-- مع المتوسط المرجح المتحرك لتقييم المخزون. المرجع: doc 03 §24 §25 §26 §26.1 + doc 02 §26

create table inventory.fuel_tanks (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  public_code text not null default core.generate_public_code('FTK'),
  name text not null,
  capacity_ml bigint check (capacity_ml > 0),
  measurement_method text not null default 'manual'
    check (measurement_method in ('manual', 'dipstick', 'meter', 'estimated')),
  status text not null default 'active'
    check (status in ('active', 'inactive', 'maintenance', 'retired')),
  -- رصيد ديزل البئر ومتوسط تكلفة اللتر (المتوسط المرجح المتحرك)
  current_balance_ml bigint not null default 0,
  avg_cost_per_liter_minor bigint not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  unique (well_id, public_code)
);

create index fuel_tanks_well_idx on inventory.fuel_tanks (well_id, status);

alter table inventory.fuel_tanks enable row level security;

create policy fuel_tanks_select_owner_operator on inventory.fuel_tanks for select
  using (iam.has_well_role(well_id, array['owner', 'operator']));
create policy fuel_tanks_insert_owner on inventory.fuel_tanks for insert
  with check (iam.has_well_role(well_id, array['owner']));
create policy fuel_tanks_update_owner_operator on inventory.fuel_tanks for update
  using (iam.has_well_role(well_id, array['owner', 'operator']));

grant select, insert, update on inventory.fuel_tanks to authenticated;

-- خزان رئيسي تلقائي مع كل بئر
create or replace function inventory.create_default_fuel_tank()
returns trigger
language plpgsql
security definer
set search_path to 'inventory', 'core', 'pg_temp'
as $$
begin
  insert into inventory.fuel_tanks (tenant_id, well_id, name)
  values (new.tenant_id, new.id, 'خزان ' || new.name);
  return new;
end;
$$;

create trigger wells_create_default_fuel_tank
after insert on core.wells
for each row execute function inventory.create_default_fuel_tank();

insert into inventory.fuel_tanks (tenant_id, well_id, name)
select w.tenant_id, w.id, 'خزان ' || w.name
from core.wells w
where not exists (select 1 from inventory.fuel_tanks t where t.well_id = w.id);

-- ═══ حركات الوقود (نص doc 03 §25) ═══
create table inventory.fuel_transactions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  public_code text not null default core.generate_public_code('FTX'),
  well_id uuid not null references core.wells(id) on delete cascade,
  fuel_tank_id uuid references inventory.fuel_tanks(id),
  transaction_type text not null check (transaction_type in (
    'purchase', 'farmer_deposit', 'session_consumption', 'farmer_return',
    'adjustment_in', 'adjustment_out', 'leakage', 'loss',
    'opening_balance', 'physical_count'
  )),
  ownership_type text not null check (ownership_type in ('well', 'farmer')),
  owner_person_id uuid references core.persons(id),
  farmer_well_account_id uuid references ops.farmer_well_accounts(id),
  quantity_ml bigint not null check (quantity_ml > 0),
  direction text not null check (direction in ('in', 'out')),
  measurement_type text not null default 'actual' check (measurement_type in ('actual', 'estimated')),
  unit_cost_per_liter_minor bigint,
  total_cost_minor bigint,
  session_segment_id uuid references ops.session_segments(id),
  expense_id uuid references finance.expenses(id),
  shift_id uuid references ops.shifts(id),
  occurred_at timestamptz not null default now(),
  status text not null default 'posted'
    check (status in ('draft', 'pending_actual_measurement', 'posted', 'reversed')),
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid references iam.profiles(id),
  unique (well_id, public_code),
  check (ownership_type = 'well' or owner_person_id is not null)
);

create index fuel_transactions_tank_idx on inventory.fuel_transactions (fuel_tank_id, occurred_at desc);
create index fuel_transactions_owner_idx on inventory.fuel_transactions (owner_person_id, status);
create index fuel_transactions_well_idx on inventory.fuel_transactions (well_id, occurred_at desc);

alter table inventory.fuel_transactions enable row level security;

create policy fuel_transactions_select_owner_operator on inventory.fuel_transactions for select
  using (iam.has_well_role(well_id, array['owner', 'operator']));
create policy fuel_transactions_insert_owner_operator on inventory.fuel_transactions for insert
  with check (iam.has_well_role(well_id, array['owner', 'operator']));
create policy fuel_transactions_update_owner on inventory.fuel_transactions for update
  using (iam.has_well_role(well_id, array['owner']));

grant select, insert, update on inventory.fuel_transactions to authenticated;

-- المفتاح الاجنبي المؤجل من المرحلة 3
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'journal_lines_fuel_tank_id_fkey') then
    alter table finance.journal_lines
      add constraint journal_lines_fuel_tank_id_fkey
      foreign key (fuel_tank_id) references inventory.fuel_tanks(id);
  end if;
end $$;

-- ملء الخزان والتكاليف تلقائيا
create or replace function inventory.fill_fuel_transaction()
returns trigger
language plpgsql
security definer
set search_path to 'inventory', 'core', 'ops', 'pg_temp'
as $$
declare
  v_liters numeric;
begin
  if new.tenant_id is null then
    select tenant_id into new.tenant_id from core.wells where id = new.well_id;
  end if;

  if new.fuel_tank_id is null then
    select id into new.fuel_tank_id from inventory.fuel_tanks
    where well_id = new.well_id and status = 'active'
    order by created_at limit 1;
  end if;

  if new.shift_id is null then
    select s.id into new.shift_id from ops.shifts s
    where s.well_id = new.well_id and s.status = 'open' limit 1;
  end if;

  -- القياس التقديري يبقى بانتظار قياس فعلي (doc 02 §26.2)
  if new.measurement_type = 'estimated' and new.status = 'posted' then
    new.status := 'pending_actual_measurement';
  end if;

  v_liters := new.quantity_ml::numeric / 1000;

  if new.direction = 'in' then
    if new.unit_cost_per_liter_minor is not null and new.total_cost_minor is null then
      new.total_cost_minor := round(v_liters * new.unit_cost_per_liter_minor);
    elsif new.total_cost_minor is not null and new.unit_cost_per_liter_minor is null and v_liters > 0 then
      new.unit_cost_per_liter_minor := round(new.total_cost_minor / v_liters);
    end if;
  else
    if new.ownership_type = 'well' and new.unit_cost_per_liter_minor is null then
      select avg_cost_per_liter_minor into new.unit_cost_per_liter_minor
      from inventory.fuel_tanks where id = new.fuel_tank_id;
    end if;
    if new.total_cost_minor is null and new.unit_cost_per_liter_minor is not null then
      new.total_cost_minor := round(v_liters * new.unit_cost_per_liter_minor);
    end if;
  end if;

  return new;
end;
$$;

create trigger fuel_transactions_fill
before insert on inventory.fuel_transactions
for each row execute function inventory.fill_fuel_transaction();

-- تحديث الرصيد والمتوسط المرجح المتحرك بعد كل حركة مسجلة
create or replace function inventory.apply_fuel_transaction()
returns trigger
language plpgsql
security definer
set search_path to 'inventory', 'pg_temp'
as $$
declare
  v_bal bigint;
  v_avg bigint;
  v_new_bal bigint;
  v_value numeric;
  v_farmer_bal bigint;
begin
  if new.status <> 'posted' then
    return new;
  end if;

  if new.ownership_type = 'well' then
    select current_balance_ml, avg_cost_per_liter_minor into v_bal, v_avg
    from inventory.fuel_tanks where id = new.fuel_tank_id for update;

    if new.direction = 'in' then
      v_value := (v_bal::numeric / 1000) * coalesce(v_avg, 0) + coalesce(new.total_cost_minor, 0);
      v_new_bal := v_bal + new.quantity_ml;
      update inventory.fuel_tanks
      set current_balance_ml = v_new_bal,
          avg_cost_per_liter_minor = case
            when v_new_bal > 0 then round(v_value / (v_new_bal::numeric / 1000))
            else 0 end
      where id = new.fuel_tank_id;
    else
      v_new_bal := v_bal - new.quantity_ml;
      if v_new_bal < 0 then
        raise exception 'رصيد ديزل البئر لا يكفي: المتاح % لتر والمطلوب % لتر',
          round(v_bal / 1000.0, 2), round(new.quantity_ml / 1000.0, 2);
      end if;
      update inventory.fuel_tanks set current_balance_ml = v_new_bal where id = new.fuel_tank_id;
    end if;
  else
    -- ديزل المزارع: الرصيد محسوب من الحركات لا مخزون مستقل (doc 02 §26.3)
    select coalesce(sum(case when direction = 'in' then quantity_ml else -quantity_ml end), 0)
    into v_farmer_bal
    from inventory.fuel_transactions
    where well_id = new.well_id and ownership_type = 'farmer'
      and owner_person_id = new.owner_person_id and status = 'posted';

    if v_farmer_bal < 0 then
      raise exception 'رصيد ديزل المزارع لا يكفي: الناتج % لتر', round(v_farmer_bal / 1000.0, 2);
    end if;
  end if;

  return new;
end;
$$;

create trigger fuel_transactions_apply
after insert on inventory.fuel_transactions
for each row execute function inventory.apply_fuel_transaction();

-- رصيد ديزل مزارع محدد (محسوب لحظيا)
create or replace function inventory.farmer_fuel_balance_ml(p_well_id uuid, p_person_id uuid)
returns bigint
language sql
stable
security definer
set search_path to 'inventory', 'pg_temp'
as $$
  select coalesce(sum(case when direction = 'in' then quantity_ml else -quantity_ml end), 0)
  from inventory.fuel_transactions
  where well_id = p_well_id and ownership_type = 'farmer'
    and owner_person_id = p_person_id and status = 'posted';
$$;

-- جسر مع جدول الشراء القديم: كل شراء يسجل حركة مخزون تلقائيا
create or replace function inventory.bridge_fuel_purchase()
returns trigger
language plpgsql
security definer
set search_path to 'inventory', 'core', 'pg_temp'
as $$
declare
  v_tenant uuid;
begin
  select tenant_id into v_tenant from core.wells where id = new.well_id;

  insert into inventory.fuel_transactions (
    tenant_id, well_id, transaction_type, ownership_type, quantity_ml, direction,
    measurement_type, total_cost_minor, occurred_at, created_by, notes
  ) values (
    v_tenant, new.well_id, 'purchase', 'well', round(new.liters * 1000), 'in',
    'actual', new.cost_minor, new.purchased_at, new.recorded_by_profile_id,
    'مولدة تلقائيا من سجل شراء الديزل'
  );

  return new;
end;
$$;

create trigger fuel_purchases_bridge_to_inventory
after insert on inventory.fuel_purchases
for each row execute function inventory.bridge_fuel_purchase();

-- المرحلة 4 - الملف 041
-- صناديق النقد: صندوق عام واحد لكل بئر ينشأ تلقائيا مع البئر
-- المرجع: doc 03 §29 + قرار المالك (كل مبلغ محصل يدخل صندوق البئر مباشرة)

create table finance.cashboxes (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  public_code text default core.generate_public_code('CBX'),
  name text not null,
  cashbox_type text not null check (cashbox_type in ('main_well', 'operator_custody', 'shift_cashbox', 'petty_cash')),
  assigned_profile_id uuid references iam.profiles(id),
  status text not null default 'active' check (status in ('active', 'inactive', 'closed')),
  notes text,
  created_at timestamptz not null default now()
);

-- صندوق عام واحد فقط لكل بئر
create unique index cashboxes_one_main_per_well on finance.cashboxes (well_id) where cashbox_type = 'main_well';
create index cashboxes_well_idx on finance.cashboxes (well_id, status);

alter table finance.cashboxes enable row level security;

create policy cashboxes_select_owner_operator on finance.cashboxes for select
  using (iam.has_well_role(well_id, array['owner', 'operator']));
create policy cashboxes_insert_owner on finance.cashboxes for insert
  with check (iam.has_well_role(well_id, array['owner']));
create policy cashboxes_update_owner on finance.cashboxes for update
  using (iam.has_well_role(well_id, array['owner']));

grant select, insert, update on finance.cashboxes to authenticated;

-- انشاء الصندوق العام تلقائيا عند انشاء بئر جديد
create or replace function finance.create_main_cashbox()
returns trigger
language plpgsql
security definer
set search_path to 'finance', 'core', 'pg_temp'
as $$
begin
  insert into finance.cashboxes (tenant_id, well_id, name, cashbox_type)
  values (new.tenant_id, new.id, 'صندوق ' || new.name, 'main_well')
  on conflict do nothing;
  return new;
end;
$$;

create trigger wells_create_main_cashbox
after insert on core.wells
for each row execute function finance.create_main_cashbox();

-- ملء الابار الموجودة مسبقا
insert into finance.cashboxes (tenant_id, well_id, name, cashbox_type)
select w.tenant_id, w.id, 'صندوق ' || w.name, 'main_well'
from core.wells w
where not exists (
  select 1 from finance.cashboxes c where c.well_id = w.id and c.cashbox_type = 'main_well'
);

-- دالة جاهزة للتطبيق: معرف الصندوق العام للبئر
create or replace function finance.main_cashbox_id(p_well_id uuid)
returns uuid
language sql
stable
security definer
set search_path to 'finance', 'pg_temp'
as $$
  select id from finance.cashboxes
  where well_id = p_well_id and cashbox_type = 'main_well'
  limit 1;
$$;

-- المفتاح الاجنبي المؤجل من المرحلة 3
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'finance' and table_name = 'journal_lines' and column_name = 'cashbox_id'
  ) and not exists (
    select 1 from pg_constraint where conname = 'journal_lines_cashbox_id_fkey'
  ) then
    alter table finance.journal_lines
      add constraint journal_lines_cashbox_id_fkey
      foreign key (cashbox_id) references finance.cashboxes(id);
  end if;
end $$;

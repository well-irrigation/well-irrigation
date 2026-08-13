-- المرحلة 4 - الملف 044
-- المصروفات: انواع جاهزة لكل مؤسسة، تسجيل من المشغل او المالك، مرفق مطلوب مع تخطي صريح،
-- اشعار لحظي للمالك عند كل مصروف، وقواعد اعتماد اختيارية.
-- المرجع: doc 03 §34 §35.1 §35.2 + قرارات المالك

create table finance.expense_categories (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  code text not null,
  name_ar text not null,
  ledger_account_code text,
  requires_approval boolean not null default false,
  attachment_required boolean not null default true,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, code)
);

create index expense_categories_tenant_idx on finance.expense_categories (tenant_id, is_active);

alter table finance.expense_categories enable row level security;

create policy expense_categories_select_member on finance.expense_categories for select
  using (exists (
    select 1 from core.wells w
    where w.tenant_id = expense_categories.tenant_id
      and iam.has_well_role(w.id, array['owner', 'operator'])
  ));
create policy expense_categories_insert_owner on finance.expense_categories for insert
  with check (exists (
    select 1 from core.wells w
    where w.tenant_id = expense_categories.tenant_id and iam.has_well_role(w.id, array['owner'])
  ));
create policy expense_categories_update_owner on finance.expense_categories for update
  using (exists (
    select 1 from core.wells w
    where w.tenant_id = expense_categories.tenant_id and iam.has_well_role(w.id, array['owner'])
  ));

grant select, insert, update on finance.expense_categories to authenticated;

-- انواع المصروفات الافتراضية مرتبطة بحسابات دليل الحسابات
create or replace function finance.create_default_expense_categories(p_tenant_id uuid)
returns integer
language plpgsql
security definer
set search_path to 'finance', 'pg_temp'
as $$
declare
  v_count integer := 0;
begin
  insert into finance.expense_categories (tenant_id, code, name_ar, ledger_account_code, attachment_required, sort_order)
  values
    (p_tenant_id, 'diesel',      'ديزل',              '5000', true,  10),
    (p_tenant_id, 'maintenance', 'صيانة',             '5100', true,  20),
    (p_tenant_id, 'oil',         'زيت',               '5200', true,  30),
    (p_tenant_id, 'spare_parts', 'قطع غيار',          '5300', true,  40),
    (p_tenant_id, 'salaries',    'رواتب واجور',       '5400', false, 50),
    (p_tenant_id, 'transport',   'نقل',               '5500', true,  60),
    (p_tenant_id, 'guarding',    'حراسة',             '5600', false, 70),
    (p_tenant_id, 'admin',       'مصروفات ادارية',    '5700', false, 80),
    (p_tenant_id, 'other',       'مصروفات اخرى',      '5900', true,  90)
  on conflict (tenant_id, code) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function finance.seed_expense_categories()
returns trigger
language plpgsql
security definer
set search_path to 'finance', 'pg_temp'
as $$
begin
  perform finance.create_default_expense_categories(new.id);
  return new;
end;
$$;

create trigger tenants_seed_expense_categories
after insert on core.tenants
for each row execute function finance.seed_expense_categories();

-- المؤسسات الموجودة مسبقا
do $$
declare r record;
begin
  for r in select id from core.tenants loop
    perform finance.create_default_expense_categories(r.id);
  end loop;
end $$;

-- ═══ المصروفات ═══
create table finance.expenses (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  public_code text default core.generate_public_code('EXP'),
  category_id uuid references finance.expense_categories(id),
  amount_minor bigint not null check (amount_minor > 0),
  description text not null,
  spent_at timestamptz not null default now(),
  payment_source text not null default 'cashbox'
    check (payment_source in ('cashbox', 'partner_paid', 'unpaid_payable', 'other')),
  cashbox_id uuid references finance.cashboxes(id),
  shift_id uuid references ops.shifts(id),
  created_by uuid references iam.profiles(id),
  attachment_url text,
  attachment_skipped boolean not null default false,
  attachment_skip_reason text,
  status text not null default 'posted'
    check (status in ('draft', 'pending_approval', 'approved', 'rejected', 'posted', 'reversed')),
  journal_entry_id uuid references finance.journal_entries(id),
  note text,
  created_at timestamptz not null default now(),
  -- المرفق مطلوب دائما، والتخطي يجب ان يكون صريحا ومسجلا
  constraint expenses_attachment_check check (attachment_url is not null or attachment_skipped = true),
  -- الصرف من الصندوق يلزمه صندوق
  constraint expenses_cashbox_check check (payment_source <> 'cashbox' or cashbox_id is not null)
);

create index expenses_well_date_idx on finance.expenses (well_id, spent_at desc);
create index expenses_shift_idx on finance.expenses (shift_id);
create index expenses_status_idx on finance.expenses (well_id, status);

alter table finance.expenses enable row level security;

create policy expenses_select_owner_operator on finance.expenses for select
  using (iam.has_well_role(well_id, array['owner', 'operator']));
create policy expenses_insert_owner_operator on finance.expenses for insert
  with check (iam.has_well_role(well_id, array['owner', 'operator']));
create policy expenses_update_owner on finance.expenses for update
  using (iam.has_well_role(well_id, array['owner']));

grant select, insert, update on finance.expenses to authenticated;

-- ملء السياق تلقائيا + اشعار لحظي للمالك
create or replace function finance.fill_expense_context()
returns trigger
language plpgsql
security definer
set search_path to 'finance', 'ops', 'core', 'pg_temp'
as $$
begin
  if new.tenant_id is null then
    select w.tenant_id into new.tenant_id from core.wells w where w.id = new.well_id;
  end if;

  if new.cashbox_id is null and new.payment_source = 'cashbox' then
    new.cashbox_id := finance.main_cashbox_id(new.well_id);
  end if;

  if new.shift_id is null then
    select s.id into new.shift_id from ops.shifts s
    where s.well_id = new.well_id and s.status = 'open' limit 1;
  end if;

  if new.created_by is null and new.shift_id is not null then
    select s.operator_profile_id into new.created_by from ops.shifts s where s.id = new.shift_id;
  end if;

  return new;
end;
$$;

create trigger expenses_fill_context
before insert on finance.expenses
for each row execute function finance.fill_expense_context();

create or replace function finance.notify_expense_recorded()
returns trigger
language plpgsql
security definer
set search_path to 'finance', 'ops', 'pg_temp'
as $$
declare
  v_cat text;
begin
  select name_ar into v_cat from finance.expense_categories where id = new.category_id;

  perform ops.notify_well_owners(new.well_id, 'expense_recorded',
    format('مصروف جديد الان: %s ريال (%s) - %s%s',
      new.amount_minor,
      coalesce(v_cat, 'غير مصنف'),
      new.description,
      case when new.attachment_skipped then ' - بلا مرفق' else ' - مع مرفق' end));

  return new;
end;
$$;

create trigger expenses_notify_owner
after insert on finance.expenses
for each row execute function finance.notify_expense_recorded();

-- ═══ قواعد الاعتماد وسجل القرارات ═══
create table finance.expense_approval_rules (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid references core.wells(id) on delete cascade,
  category_id uuid references finance.expense_categories(id),
  min_amount_minor bigint not null default 0 check (min_amount_minor >= 0),
  requires_approval boolean not null default true,
  approver_profile_id uuid references iam.profiles(id),
  effective_period daterange not null default daterange(current_date, null),
  created_at timestamptz not null default now()
);

create index expense_approval_rules_tenant_idx on finance.expense_approval_rules (tenant_id, well_id);

alter table finance.expense_approval_rules enable row level security;

create policy expense_approval_rules_select_member on finance.expense_approval_rules for select
  using (exists (
    select 1 from core.wells w
    where w.tenant_id = expense_approval_rules.tenant_id
      and iam.has_well_role(w.id, array['owner', 'operator'])
  ));
create policy expense_approval_rules_insert_owner on finance.expense_approval_rules for insert
  with check (exists (
    select 1 from core.wells w
    where w.tenant_id = expense_approval_rules.tenant_id and iam.has_well_role(w.id, array['owner'])
  ));
create policy expense_approval_rules_update_owner on finance.expense_approval_rules for update
  using (exists (
    select 1 from core.wells w
    where w.tenant_id = expense_approval_rules.tenant_id and iam.has_well_role(w.id, array['owner'])
  ));

grant select, insert, update on finance.expense_approval_rules to authenticated;

create table finance.expense_approvals (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  expense_id uuid not null references finance.expenses(id) on delete cascade,
  approver_profile_id uuid not null references iam.profiles(id),
  decision text not null check (decision in ('approved', 'rejected')),
  note text,
  decided_at timestamptz not null default now()
);

create index expense_approvals_expense_idx on finance.expense_approvals (expense_id);

alter table finance.expense_approvals enable row level security;

create policy expense_approvals_select_member on finance.expense_approvals for select
  using (exists (
    select 1 from finance.expenses e
    where e.id = expense_approvals.expense_id and iam.has_well_role(e.well_id, array['owner', 'operator'])
  ));
create policy expense_approvals_insert_owner on finance.expense_approvals for insert
  with check (exists (
    select 1 from finance.expenses e
    where e.id = expense_approvals.expense_id and iam.has_well_role(e.well_id, array['owner'])
  ));
create policy expense_approvals_update_owner on finance.expense_approvals for update
  using (exists (
    select 1 from finance.expenses e
    where e.id = expense_approvals.expense_id and iam.has_well_role(e.well_id, array['owner'])
  ));

grant select, insert, update on finance.expense_approvals to authenticated;

-- الدالة التي يستخدمها التطبيق لتسجيل مصروف
create or replace function finance.record_expense(
  p_well_id uuid,
  p_category_code text,
  p_amount_minor bigint,
  p_description text,
  p_created_by uuid default null,
  p_attachment_url text default null,
  p_attachment_skipped boolean default false,
  p_payment_source text default 'cashbox',
  p_note text default null
) returns uuid
language plpgsql
security definer
set search_path to 'finance', 'core', 'ops', 'pg_temp'
as $$
declare
  v_tenant uuid;
  v_cat uuid;
  v_requires boolean := false;
  v_status text;
  v_id uuid;
begin
  select tenant_id into v_tenant from core.wells where id = p_well_id;
  if v_tenant is null then
    raise exception 'البئر % غير موجود', p_well_id;
  end if;

  select id into v_cat from finance.expense_categories
  where tenant_id = v_tenant and code = p_category_code and is_active;
  if v_cat is null then
    raise exception 'نوع المصروف % غير معروف', p_category_code;
  end if;

  if p_attachment_url is null and p_attachment_skipped is not true then
    raise exception 'ارفاق صورة مطلوب، او تحديد التخطي صراحة';
  end if;

  select coalesce(bool_or(r.requires_approval), false) into v_requires
  from finance.expense_approval_rules r
  where r.tenant_id = v_tenant
    and (r.well_id is null or r.well_id = p_well_id)
    and (r.category_id is null or r.category_id = v_cat)
    and p_amount_minor >= r.min_amount_minor
    and r.effective_period @> current_date;

  v_status := case when v_requires then 'pending_approval' else 'posted' end;

  insert into finance.expenses (
    tenant_id, well_id, category_id, amount_minor, description, payment_source,
    created_by, attachment_url, attachment_skipped, status, note
  ) values (
    v_tenant, p_well_id, v_cat, p_amount_minor, p_description, p_payment_source,
    p_created_by, p_attachment_url, coalesce(p_attachment_skipped, false), v_status, p_note
  ) returning id into v_id;

  return v_id;
end;
$$;

-- قرار المالك على مصروف بانتظار الاعتماد
create or replace function finance.decide_expense(
  p_expense_id uuid,
  p_approver_profile_id uuid,
  p_approve boolean,
  p_note text default null
) returns text
language plpgsql
security definer
set search_path to 'finance', 'ops', 'pg_temp'
as $$
declare
  v_e record;
  v_new_status text;
begin
  select * into v_e from finance.expenses where id = p_expense_id;
  if v_e.id is null then
    raise exception 'المصروف % غير موجود', p_expense_id;
  end if;
  if v_e.status not in ('draft', 'pending_approval') then
    raise exception 'المصروف % لا ينتظر قرارا (الحالة %)', p_expense_id, v_e.status;
  end if;

  v_new_status := case when p_approve then 'posted' else 'rejected' end;

  insert into finance.expense_approvals (tenant_id, expense_id, approver_profile_id, decision, note)
  values (v_e.tenant_id, p_expense_id, p_approver_profile_id,
          case when p_approve then 'approved' else 'rejected' end, p_note);

  update finance.expenses set status = v_new_status where id = p_expense_id;

  if v_e.created_by is not null then
    perform ops.notify_profile(v_e.created_by, v_e.well_id, 'expense_recorded',
      case when p_approve then 'تم اعتماد مصروفك' else 'تم رفض مصروفك: ' || coalesce(p_note, '') end);
  end if;

  return v_new_status;
end;
$$;

-- المرحلة 6 - الملف 055 (ق-74 بنود 6-7):
-- 1) اصلاح ترحيل الارصدة الافتتاحية: بلا قيود مقابلة، بل قاعدة الاصول = الالتزامات + راس المال
-- 2) record_expense يقبل الشريك (لمصروف partner_paid)
-- 3) الرواتب: قواعد التعويض والمستحقات وقيدا الاستحقاق والصرف (doc 02 قسم 29)
-- 4) قيود الديزل المحاسبية التلقائية (doc 03 قسم 26 و33.5 و33.6)
-- 5) الالتزامات المحتجزة تضم الرواتب المستحقة غير المدفوعة

-- ═══ 1) اصلاح ترحيل الارصدة الافتتاحية ═══
create or replace function finance.post_opening_balance_batch(p_batch_id uuid, p_posted_by uuid)
returns void language plpgsql security definer
set search_path to 'finance', 'core', 'inventory', 'pg_temp' as $$
declare
  v_batch record;
  v_item record;
  v_je uuid;
  v_acc3000 uuid; v_acc1000 uuid; v_acc1100 uuid; v_acc1200 uuid;
  v_acc2000 uuid; v_acc2200 uuid; v_acc2300 uuid; v_acc2400 uuid;
  v_debits bigint;
  v_credits bigint;
begin
  select * into v_batch from finance.opening_balance_batches where id = p_batch_id for update;
  if v_batch is null then raise exception 'جلسة الارصدة غير موجودة: %', p_batch_id; end if;
  if v_batch.status <> 'approved' then
    raise exception 'لا يمكن ترحيل جلسة حالتها % — يجب اعتمادها اولا', v_batch.status;
  end if;

  -- قاعدة التوازن الافتتاحي: الاصول = الالتزامات + راس المال
  select coalesce(sum(case when item_type in ('farmer_debt','cashbox_balance','fuel_tank_balance','partner_receivable') then amount_minor else 0 end), 0),
         coalesce(sum(case when item_type in ('farmer_advance','partner_payable','salary_payable','expense_payable','capital_balance') then amount_minor else 0 end), 0)
  into v_debits, v_credits
  from finance.opening_balance_items where batch_id = p_batch_id;

  if v_debits = 0 and v_credits = 0 then raise exception 'الجلسة بلا عناصر'; end if;
  if v_debits <> v_credits then
    raise exception 'جلسة الارصدة غير متوازنة: مجموع الاصول % لا يساوي مجموع الالتزامات وراس المال %', v_debits, v_credits;
  end if;

  v_acc3000 := finance.ledger_account_id(v_batch.well_id, '3000');
  v_acc1000 := finance.ledger_account_id(v_batch.well_id, '1000');
  v_acc1100 := finance.ledger_account_id(v_batch.well_id, '1100');
  v_acc1200 := finance.ledger_account_id(v_batch.well_id, '1200');
  v_acc2000 := finance.ledger_account_id(v_batch.well_id, '2000');
  v_acc2200 := finance.ledger_account_id(v_batch.well_id, '2200');
  v_acc2300 := finance.ledger_account_id(v_batch.well_id, '2300');
  v_acc2400 := finance.ledger_account_id(v_batch.well_id, '2400');

  insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
  values (v_batch.tenant_id, core.generate_public_code('JE'), v_batch.well_id, v_batch.reference_date::timestamptz,
          'opening_balance', p_batch_id, 'ارصدة افتتاحية بمرجع ' || v_batch.reference_date,
          'OB-' || p_batch_id::text)
  returning id into v_je;

  for v_item in select * from finance.opening_balance_items where batch_id = p_batch_id loop
    if v_item.item_type in ('farmer_debt', 'cashbox_balance', 'fuel_tank_balance', 'partner_receivable') then
      insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor,
        person_id, farmer_well_account_id, partner_id, cashbox_id, fuel_tank_id, description)
      values (v_batch.tenant_id, v_je,
        case v_item.item_type
          when 'farmer_debt' then v_acc1100
          when 'cashbox_balance' then v_acc1000
          when 'fuel_tank_balance' then v_acc1200
          when 'partner_receivable' then v_acc2400
        end,
        'debit', v_item.amount_minor,
        v_item.person_id, v_item.farmer_well_account_id, v_item.partner_id, v_item.cashbox_id, v_item.fuel_tank_id,
        coalesce(v_item.description, v_item.item_type));
    else
      insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor,
        person_id, farmer_well_account_id, partner_id, description)
      values (v_batch.tenant_id, v_je,
        case v_item.item_type
          when 'farmer_advance' then v_acc2000
          when 'partner_payable' then v_acc2400
          when 'salary_payable' then v_acc2200
          when 'expense_payable' then v_acc2300
          when 'capital_balance' then v_acc3000
        end,
        'credit', v_item.amount_minor,
        v_item.person_id, v_item.farmer_well_account_id, v_item.partner_id,
        coalesce(v_item.description, v_item.item_type));
    end if;

    -- رصيد الوقود الافتتاحي ينشئ حركة مخزون فعلية
    if v_item.item_type = 'fuel_tank_balance' then
      insert into inventory.fuel_transactions (tenant_id, well_id, fuel_tank_id, transaction_type, ownership_type,
        quantity_ml, direction, measurement_type, total_cost_minor, occurred_at, created_by, notes)
      values (v_batch.tenant_id, v_batch.well_id, v_item.fuel_tank_id, 'opening_balance', 'well',
        v_item.quantity_ml, 'in', 'actual', v_item.amount_minor, v_batch.reference_date::timestamptz, p_posted_by,
        'رصيد افتتاحي من جلسة ' || p_batch_id::text);
    end if;
  end loop;

  perform finance.post_journal_entry(v_je, p_posted_by);
  update finance.opening_balance_batches set status = 'posted' where id = p_batch_id;
end;
$$;

-- ═══ 2) record_expense يقبل الشريك ═══
create or replace function finance.record_expense(
  p_well_id uuid, p_category_code text, p_amount_minor bigint, p_description text,
  p_created_by uuid default null, p_attachment_url text default null,
  p_attachment_skipped boolean default false, p_payment_source text default 'cashbox',
  p_note text default null, p_partner_id uuid default null
) returns uuid language plpgsql security definer
set search_path to 'finance', 'core', 'ops', 'pg_temp' as $$
declare
  v_tenant uuid;
  v_cat uuid;
  v_requires boolean := false;
  v_status text;
  v_id uuid;
begin
  select tenant_id into v_tenant from core.wells where id = p_well_id;
  if v_tenant is null then raise exception 'البئر % غير موجود', p_well_id; end if;

  select id into v_cat from finance.expense_categories
  where tenant_id = v_tenant and code = p_category_code and is_active;
  if v_cat is null then raise exception 'نوع المصروف % غير معروف', p_category_code; end if;

  if p_attachment_url is null and p_attachment_skipped is not true then
    raise exception 'ارفاق صورة مطلوب، او تحديد التخطي صراحة';
  end if;
  if p_payment_source = 'partner_paid' and p_partner_id is null then
    raise exception 'مصروف دفعه شريك من جيبه يلزم تحديد الشريك';
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
    created_by, attachment_url, attachment_skipped, status, note, partner_id
  ) values (
    v_tenant, p_well_id, v_cat, p_amount_minor, p_description, p_payment_source,
    p_created_by, p_attachment_url, coalesce(p_attachment_skipped, false), v_status, p_note, p_partner_id
  ) returning id into v_id;

  return v_id;
end;
$$;

-- ═══ 3) الرواتب (doc 02 قسم 29) ═══
create table finance.worker_compensation_rules (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  person_id uuid not null references core.persons(id),
  compensation_type text not null check (compensation_type in (
    'monthly', 'daily', 'hourly', 'per_shift', 'fixed_plus_bonus', 'custom'
  )),
  rate_amount_minor bigint not null check (rate_amount_minor > 0),
  effective_period daterange not null,
  settings jsonb not null default '{}',
  created_at timestamptz not null default now()
);
alter table finance.worker_compensation_rules add constraint no_worker_rule_period_overlap
  exclude using gist (well_id with =, person_id with =, effective_period with &&);

alter table finance.worker_compensation_rules enable row level security;
create policy worker_compensation_rules_select on finance.worker_compensation_rules for select
  using (iam.has_well_role(well_id, array['owner', 'manager']) or iam.is_well_partner(well_id));
create policy worker_compensation_rules_insert_owner_manager on finance.worker_compensation_rules for insert
  with check (iam.has_well_role(well_id, array['owner', 'manager']));
create policy worker_compensation_rules_update_owner_manager on finance.worker_compensation_rules for update
  using (iam.has_well_role(well_id, array['owner', 'manager']));
grant select, insert, update on finance.worker_compensation_rules to authenticated;

create table finance.payroll_accruals (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  person_id uuid not null references core.persons(id),
  period_start date not null,
  period_end date not null,
  gross_amount_minor bigint not null check (gross_amount_minor >= 0),
  deductions_minor bigint not null default 0 check (deductions_minor >= 0),
  net_amount_minor bigint not null check (net_amount_minor >= 0),
  status text not null default 'due' check (status in ('due', 'paid', 'cancelled')),
  accrual_journal_entry_id uuid references finance.journal_entries(id),
  payment_journal_entry_id uuid references finance.journal_entries(id),
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  unique (well_id, person_id, period_start, period_end),
  check (period_end >= period_start)
);
create index payroll_accruals_well_idx on finance.payroll_accruals (well_id, status);

alter table finance.payroll_accruals enable row level security;
create policy payroll_accruals_select on finance.payroll_accruals for select
  using (iam.has_well_role(well_id, array['owner', 'manager']) or iam.is_well_partner(well_id));
create policy payroll_accruals_insert_owner_manager on finance.payroll_accruals for insert
  with check (iam.has_well_role(well_id, array['owner', 'manager']));
create policy payroll_accruals_update_owner_manager on finance.payroll_accruals for update
  using (iam.has_well_role(well_id, array['owner', 'manager']));
grant select, insert, update on finance.payroll_accruals to authenticated;

-- استحقاق الراتب: يحسب الاجمالي من القاعدة الفعالة وينشئ قيد الاستحقاق
create or replace function finance.accrue_payroll(
  p_well_id uuid, p_person_id uuid, p_period_start date, p_period_end date,
  p_gross_minor bigint default null, p_deductions_minor bigint default 0, p_created_by uuid default null
) returns uuid language plpgsql security definer
set search_path to 'finance', 'core', 'pg_temp' as $$
declare
  v_tenant uuid;
  v_rule record;
  v_rule_found boolean;
  v_gross bigint;
  v_net bigint;
  v_id uuid;
  v_je uuid;
  v_person_name text;
begin
  select tenant_id into v_tenant from core.wells where id = p_well_id;
  if p_period_end < p_period_start then raise exception 'نهاية فترة الاستحقاق قبل بدايتها'; end if;
  if exists (select 1 from finance.payroll_accruals a
             where a.well_id = p_well_id and a.person_id = p_person_id
               and a.period_start = p_period_start and a.period_end = p_period_end
               and a.status <> 'cancelled') then
    raise exception 'يوجد مستحق راتب لهذا العامل عن هذه الفترة مسبقًا';
  end if;

  if p_gross_minor is not null then
    v_gross := p_gross_minor;
  else
    select * into v_rule from finance.worker_compensation_rules r
    where r.well_id = p_well_id and r.person_id = p_person_id and r.effective_period @> p_period_end
    order by r.created_at desc limit 1;
    v_rule_found := found;
    if not v_rule_found then
      raise exception 'لا توجد قاعدة تعويض فعالة لهذا العامل — مرر المبلغ صراحة';
    end if;
    if v_rule.compensation_type = 'monthly' then
      v_gross := v_rule.rate_amount_minor;
    elsif v_rule.compensation_type = 'daily' then
      v_gross := v_rule.rate_amount_minor * (p_period_end - p_period_start + 1);
    else
      raise exception 'نوع التعويض % يتطلب تمرير المبلغ الاجمالي صراحة', v_rule.compensation_type;
    end if;
  end if;

  v_net := v_gross - coalesce(p_deductions_minor, 0);
  if v_net < 0 then raise exception 'صافي الراتب سالب — راجع الاستقطاعات'; end if;

  insert into finance.payroll_accruals (tenant_id, well_id, person_id, period_start, period_end,
    gross_amount_minor, deductions_minor, net_amount_minor)
  values (v_tenant, p_well_id, p_person_id, p_period_start, p_period_end, v_gross, coalesce(p_deductions_minor, 0), v_net)
  returning id into v_id;

  select full_name into v_person_name from core.persons where id = p_person_id;

  -- قيد الاستحقاق: مدين رواتب 5400 / دائن رواتب مستحقة 2200
  insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
  values (v_tenant, core.generate_public_code('JE'), p_well_id, p_period_end::timestamptz,
          'payroll_accrual', v_id, 'استحقاق راتب ' || coalesce(v_person_name, 'عامل') || ' عن ' || p_period_start || ' الى ' || p_period_end,
          'PAY-' || v_id::text)
  returning id into v_je;
  insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, person_id, description) values
    (v_tenant, v_je, finance.ledger_account_id(p_well_id, '5400'), 'debit',  v_net, p_person_id, 'مصروف رواتب'),
    (v_tenant, v_je, finance.ledger_account_id(p_well_id, '2200'), 'credit', v_net, p_person_id, 'رواتب مستحقة');
  perform finance.post_journal_entry(v_je, p_created_by);

  update finance.payroll_accruals set accrual_journal_entry_id = v_je where id = v_id;
  return v_id;
end;
$$;

-- صرف الراتب من الصندوق العام: مدين رواتب مستحقة 2200 / دائن النقد والصناديق 1000
create or replace function finance.pay_salary(p_accrual_id uuid, p_paid_by uuid default null)
returns void language plpgsql security definer
set search_path to 'finance', 'core', 'pg_temp' as $$
declare
  v_accr record;
  v_je uuid;
  v_cashbox uuid;
  v_person_name text;
begin
  select * into v_accr from finance.payroll_accruals where id = p_accrual_id for update;
  if v_accr is null then raise exception 'المستحق غير موجود: %', p_accrual_id; end if;
  if v_accr.status <> 'due' then raise exception 'لا يمكن صرف مستحق حالته %', v_accr.status; end if;

  v_cashbox := finance.main_cashbox_id(v_accr.well_id);
  select full_name into v_person_name from core.persons where id = v_accr.person_id;

  insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
  values (v_accr.tenant_id, core.generate_public_code('JE'), v_accr.well_id, now(),
          'salary_payment', p_accrual_id, 'صرف راتب ' || coalesce(v_person_name, 'عامل'),
          'SAL-' || p_accrual_id::text)
  returning id into v_je;
  insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, person_id, cashbox_id, description) values
    (v_accr.tenant_id, v_je, finance.ledger_account_id(v_accr.well_id, '2200'), 'debit',  v_accr.net_amount_minor, v_accr.person_id, null, 'تسوية راتب مستحق'),
    (v_accr.tenant_id, v_je, finance.ledger_account_id(v_accr.well_id, '1000'), 'credit', v_accr.net_amount_minor, v_accr.person_id, v_cashbox, 'صرف من صندوق البئر');
  perform finance.post_journal_entry(v_je, p_paid_by);

  update finance.payroll_accruals
  set status = 'paid', paid_at = now(), payment_journal_entry_id = v_je
  where id = p_accrual_id;
end;
$$;

-- ═══ 4) قيود الديزل التلقائية (قسم 26 و33.5 و33.6) ═══
create or replace function finance.journalize_fuel_transaction()
returns trigger language plpgsql security definer
set search_path to 'finance', 'core', 'pg_temp' as $$
declare
  v_je uuid;
begin
  -- ديزل البئر المنشور فقط، والرصيد الافتتاحي مرحل من جلسته فلا يكرر
  if new.status <> 'posted' or new.ownership_type <> 'well' then return new; end if;
  if new.transaction_type = 'opening_balance' then return new; end if;
  if new.total_cost_minor is null or new.total_cost_minor <= 0 then return new; end if;

  if new.transaction_type = 'purchase' and new.direction = 'in' then
    insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
    values (new.tenant_id, core.generate_public_code('JE'), new.well_id, new.occurred_at,
            'fuel_purchase', new.id, 'شراء ديزل', 'FTX-' || new.id::text)
    returning id into v_je;
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, fuel_tank_id, description) values
      (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1200'), 'debit',  new.total_cost_minor, new.fuel_tank_id, 'مخزون ديزل البئر'),
      (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1000'), 'credit', new.total_cost_minor, null, 'النقد والصناديق');
    perform finance.post_journal_entry(v_je, new.created_by);

  elsif new.transaction_type = 'session_consumption' and new.direction = 'out' then
    insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
    values (new.tenant_id, core.generate_public_code('JE'), new.well_id, new.occurred_at,
            'fuel_consumption', new.id, 'استهلاك ديزل في التشغيل', 'FTC-' || new.id::text)
    returning id into v_je;
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, fuel_tank_id, description) values
      (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '5000'), 'debit',  new.total_cost_minor, new.fuel_tank_id, 'تكلفة ديزل مستهلك'),
      (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1200'), 'credit', new.total_cost_minor, new.fuel_tank_id, 'مخزون ديزل البئر');
    perform finance.post_journal_entry(v_je, new.created_by);
  end if;

  return new;
end;
$$;
create trigger fuel_transactions_journalize
after insert on inventory.fuel_transactions
for each row execute function finance.journalize_fuel_transaction();

-- ═══ 5) الالتزامات المحتجزة = مستحقات الشركاء غير المسلمة + الرواتب المستحقة ═══
create or replace function finance.compute_reserved_liabilities(p_well_id uuid)
returns bigint language plpgsql stable security definer
set search_path to 'finance', 'pg_temp' as $$
declare
  v_partners bigint;
  v_payroll bigint;
begin
  select coalesce(sum(l.net_payable_minor), 0) into v_partners
  from finance.profit_distribution_lines l
  join finance.profit_distribution_cycles c on c.id = l.distribution_cycle_id
  where c.well_id = p_well_id and l.status in ('approved', 'partially_paid', 'carried_forward');

  select coalesce(sum(a.net_amount_minor), 0) into v_payroll
  from finance.payroll_accruals a
  where a.well_id = p_well_id and a.status = 'due';

  return v_partners + v_payroll;
end;
$$;

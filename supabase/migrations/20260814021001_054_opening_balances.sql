-- المرحلة 6 - الملف 054 (ق-74): الارصدة الافتتاحية — لا تصبح فعالة الا بعد اعتماد المالك
-- الترحيل ينشئ قيدا واحدا متوازنا طرفه المقابل راس المال (3000)
-- وعنصر fuel_tank_balance ينشئ حركة مخزون opening_balance فعلية

create table finance.opening_balance_batches (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  reference_date date not null,
  status text not null default 'draft'
    check (status in ('draft', 'pending_approval', 'approved', 'posted', 'reversed')),
  notes text,
  created_by uuid references iam.profiles(id),
  approved_by uuid references iam.profiles(id),
  approved_at timestamptz,
  created_at timestamptz not null default now()
);

create table finance.opening_balance_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  batch_id uuid not null references finance.opening_balance_batches(id) on delete cascade,
  item_type text not null check (item_type in (
    'farmer_debt', 'farmer_advance', 'cashbox_balance', 'fuel_tank_balance',
    'partner_payable', 'partner_receivable', 'salary_payable', 'expense_payable', 'capital_balance'
  )),
  person_id uuid references core.persons(id),
  farmer_well_account_id uuid references ops.farmer_well_accounts(id),
  partner_id uuid references core.well_partners(id),
  cashbox_id uuid references finance.cashboxes(id),
  fuel_tank_id uuid references inventory.fuel_tanks(id),
  amount_minor bigint,
  quantity_ml bigint,
  description text,
  created_at timestamptz not null default now()
);
create index opening_balance_items_batch_idx on finance.opening_balance_items (batch_id);

alter table finance.opening_balance_batches enable row level security;
create policy opening_balance_batches_select on finance.opening_balance_batches for select
  using (iam.has_well_role(well_id, array['owner', 'manager']) or iam.is_well_partner(well_id));
create policy opening_balance_batches_insert_owner on finance.opening_balance_batches for insert
  with check (iam.has_well_role(well_id, array['owner']));
create policy opening_balance_batches_update_owner on finance.opening_balance_batches for update
  using (iam.has_well_role(well_id, array['owner']));
grant select, insert, update on finance.opening_balance_batches to authenticated;

alter table finance.opening_balance_items enable row level security;
create policy opening_balance_items_select on finance.opening_balance_items for select
  using (exists (select 1 from finance.opening_balance_batches b
    where b.id = opening_balance_items.batch_id
      and (iam.has_well_role(b.well_id, array['owner', 'manager']) or iam.is_well_partner(b.well_id))));
create policy opening_balance_items_insert_owner on finance.opening_balance_items for insert
  with check (exists (select 1 from finance.opening_balance_batches b
    where b.id = opening_balance_items.batch_id and iam.has_well_role(b.well_id, array['owner'])));
create policy opening_balance_items_update_owner on finance.opening_balance_items for update
  using (exists (select 1 from finance.opening_balance_batches b
    where b.id = opening_balance_items.batch_id and iam.has_well_role(b.well_id, array['owner'])));
grant select, insert, update on finance.opening_balance_items to authenticated;

-- التحقق من متطلبات كل نوع + ملء tenant_id من الجلسة
create or replace function finance.validate_opening_balance_item()
returns trigger language plpgsql
set search_path to 'finance', 'pg_temp' as $$
begin
  if new.tenant_id is null then
    select tenant_id into new.tenant_id from finance.opening_balance_batches where id = new.batch_id;
  end if;
  if new.amount_minor is null or new.amount_minor <= 0 then
    raise exception 'كل عنصر رصيد افتتاحي يلزم مبلغا موجبا';
  end if;
  if new.item_type in ('farmer_debt', 'farmer_advance') and new.farmer_well_account_id is null then
    raise exception 'عنصر % يلزم ربطه بحساب مزارع', new.item_type;
  end if;
  if new.item_type in ('partner_payable', 'partner_receivable') and new.partner_id is null then
    raise exception 'عنصر % يلزم ربطه بالشريك', new.item_type;
  end if;
  if new.item_type = 'cashbox_balance' and new.cashbox_id is null then
    raise exception 'رصيد الصندوق الافتتاحي يلزم تحديد الصندوق';
  end if;
  if new.item_type = 'fuel_tank_balance'
     and (new.fuel_tank_id is null or new.quantity_ml is null or new.quantity_ml <= 0) then
    raise exception 'رصيد خزان الوقود الافتتاحي يلزم تحديد الخزان وكمية موجبة بالمليلتر';
  end if;
  return new;
end;
$$;
create trigger opening_balance_items_validate
before insert or update on finance.opening_balance_items
for each row execute function finance.validate_opening_balance_item();

-- قفل العناصر بعد الاعتماد
create or replace function finance.prevent_approved_opening_item_change()
returns trigger language plpgsql security definer set search_path to 'finance', 'pg_temp' as $$
declare
  v_status text;
begin
  select status into v_status from finance.opening_balance_batches
  where id = coalesce(new.batch_id, old.batch_id);
  if v_status in ('approved', 'posted') then
    raise exception 'لا يمكن تعديل عناصر جلسة ارصدة معتمدة او مرحلة';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
create trigger opening_balance_items_lock
before insert or update or delete on finance.opening_balance_items
for each row execute function finance.prevent_approved_opening_item_change();

-- اعتماد المالك
create or replace function finance.approve_opening_balance_batch(p_batch_id uuid, p_approved_by uuid)
returns void language plpgsql security definer set search_path to 'finance', 'pg_temp' as $$
declare
  v_status text;
  v_items integer;
begin
  select status into v_status from finance.opening_balance_batches where id = p_batch_id for update;
  if v_status is null then raise exception 'جلسة الارصدة غير موجودة: %', p_batch_id; end if;
  if v_status not in ('draft', 'pending_approval') then
    raise exception 'لا يمكن اعتماد جلسة حالتها % — يجب ان تكون مسودة او بانتظار الاعتماد', v_status;
  end if;
  select count(*) into v_items from finance.opening_balance_items where batch_id = p_batch_id;
  if v_items = 0 then raise exception 'لا يمكن اعتماد جلسة بلا عناصر'; end if;
  update finance.opening_balance_batches
  set status = 'approved', approved_by = p_approved_by, approved_at = now()
  where id = p_batch_id;
end;
$$;

-- الترحيل: قيد واحد متوازن طرفه المقابل راس المال 3000 + حركة مخزون للوقود
create or replace function finance.post_opening_balance_batch(p_batch_id uuid, p_posted_by uuid)
returns void language plpgsql security definer
set search_path to 'finance', 'core', 'inventory', 'pg_temp' as $$
declare
  v_batch record;
  v_item record;
  v_je uuid;
  v_acc3000 uuid; v_acc1000 uuid; v_acc1100 uuid; v_acc1200 uuid;
  v_acc2000 uuid; v_acc2200 uuid; v_acc2300 uuid; v_acc2400 uuid;
  v_debit_total bigint := 0;
  v_credit_total bigint := 0;
begin
  select * into v_batch from finance.opening_balance_batches where id = p_batch_id for update;
  if v_batch is null then raise exception 'جلسة الارصدة غير موجودة: %', p_batch_id; end if;
  if v_batch.status <> 'approved' then
    raise exception 'لا يمكن ترحيل جلسة حالتها % — يجب اعتمادها اولا', v_batch.status;
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
      insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, description)
      values (v_batch.tenant_id, v_je, v_acc3000, 'credit', v_item.amount_minor, 'مقابل راس المال');
      v_debit_total := v_debit_total + v_item.amount_minor;
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
      if v_item.item_type <> 'capital_balance' then
        insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, description)
        values (v_batch.tenant_id, v_je, v_acc3000, 'debit', v_item.amount_minor, 'مقابل راس المال');
      end if;
      v_credit_total := v_credit_total + v_item.amount_minor;
    end if;

    -- رصيد الوقود الافتتاحي ينشئ حركة مخزون فعلية تحدث الرصيد والمتوسط
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

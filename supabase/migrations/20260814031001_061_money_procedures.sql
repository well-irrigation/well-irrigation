-- =====================================================================
-- 061 — الاجراءات المالية الختامية (ق-75)
-- 1) فاتورة واحدة نشطة لكل جلسة
-- 2) ربط الدفعات والفواتير بقيودها (journal_entry_id)
-- 3) تحويل زيادة الدفعة الى رصيد مقدم تلقائيا (يحل محل الرفض القديم)
-- 4) ترحيل آلي: الدفعات 1000/1100 او 2000 — المصروفات فئة/1000 او 2400 او 2300 — الفواتير 1100/4x00
-- 5) قيد شراء الديزل يحمل معرف الصندوق الرئيسي
-- 6) عكس القيود المرحلة وعكس الدفعات
-- 7) اصلاح عرض ارصدة الصناديق ليحتسب المرحل والمعكوس معا
-- =====================================================================

-- (1) فاتورة واحدة نشطة لكل جلسة
create unique index invoices_one_per_session
  on billing.invoices (session_id)
  where session_id is not null and status not in ('cancelled', 'reversed');

-- (2) ربط السندات بقيودها
alter table billing.payments add column journal_entry_id uuid references finance.journal_entries(id);
alter table billing.invoices add column journal_entry_id uuid references finance.journal_entries(id);

-- (3) تحويل زيادة الدفعة الى رصيد مقدم
create or replace function billing.split_overpayment_to_advance()
returns trigger
language plpgsql
security definer
set search_path = 'billing', 'finance', 'core', 'pg_temp'
as $function$
declare
  v_charge bigint;
  v_paid bigint;
  v_remaining bigint;
  v_over bigint;
begin
  if new.purpose <> 'session' or new.session_charge_id is null then
    return new;
  end if;
  if coalesce(new.status, 'posted') = 'reversed' then
    return new;
  end if;

  select sc.amount_minor into v_charge
  from billing.session_charges sc
  where sc.id = new.session_charge_id;
  if v_charge is null then
    return new;
  end if;

  select coalesce(sum(p.amount_minor), 0) into v_paid
  from billing.payments p
  where p.session_charge_id = new.session_charge_id
    and coalesce(p.status, 'posted') <> 'reversed';

  v_remaining := v_charge - v_paid;
  if new.amount_minor <= v_remaining then
    return new;
  end if;

  if new.farmer_well_account_id is null then
    raise exception 'الدفعة تتجاوز المتبقي من قيمة الجلسة ولا يمكن تحويل الزيادة الى رصيد مقدم دون تحديد حساب المزارع';
  end if;

  if v_remaining <= 0 then
    new.note := coalesce(new.note || ' | ', '') || format('حُوّلت كاملة (%s) الى رصيد مقدم: الجلسة مسددة بالكامل', new.amount_minor);
    new.purpose := 'advance';
    new.session_charge_id := null;
    return new;
  end if;

  v_over := new.amount_minor - v_remaining;

  insert into billing.payments (
    tenant_id, well_id, farmer_well_account_id, payer_person_id,
    cashbox_id, shift_id, collected_by_profile_id, received_by_profile_id,
    method, amount_minor, purpose, status, note
  ) values (
    new.tenant_id, new.well_id, new.farmer_well_account_id, new.payer_person_id,
    new.cashbox_id, new.shift_id, new.collected_by_profile_id, new.received_by_profile_id,
    new.method, v_over, 'advance', new.status,
    format('رصيد مقدم تلقائي: زيادة %s عن المتبقي من قيمة الجلسة', v_over)
  );

  new.note := coalesce(new.note || ' | ', '') || format('اقتُطعت الزيادة %s وحُوّلت الى رصيد مقدم', v_over);
  new.amount_minor := v_remaining;
  return new;
end;
$function$;

drop trigger if exists payments_not_exceed_charge_check on billing.payments;
drop function if exists billing.check_payment_not_exceed_charge();

create trigger payments_split_overpayment
  before insert on billing.payments
  for each row execute function billing.split_overpayment_to_advance();

-- (4أ) ترحيل الدفعات
create or replace function billing.journalize_payment()
returns trigger
language plpgsql
security definer
set search_path = 'billing', 'finance', 'core', 'pg_temp'
as $function$
declare
  v_je uuid;
  v_credit_code text;
begin
  if new.status <> 'posted' or new.journal_entry_id is not null then
    return new;
  end if;

  v_credit_code := case when new.purpose = 'advance' then '2000' else '1100' end;

  insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
  values (new.tenant_id, core.generate_public_code('JE'), new.well_id, new.paid_at,
          'payment', new.id, 'سند قبض ' || coalesce(new.public_code, new.id::text), 'PAY-' || new.id::text)
  returning id into v_je;

  insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, farmer_well_account_id, cashbox_id, description)
  values
    (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1000'), 'debit', new.amount_minor, new.farmer_well_account_id, new.cashbox_id, 'تحصيل دفعة'),
    (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, v_credit_code), 'credit', new.amount_minor, new.farmer_well_account_id, null,
     case when new.purpose = 'advance' then 'رصيد مقدم للمزارع' else 'تسديد ذمة المزارع' end);

  perform finance.post_journal_entry(v_je, new.collected_by_profile_id);

  update billing.payments
  set journal_entry_id = v_je, updated_at = now()
  where id = new.id;

  return new;
end;
$function$;

create trigger payments_journalize
  after insert or update of status on billing.payments
  for each row execute function billing.journalize_payment();

-- (4ب) ترحيل المصروفات
create or replace function finance.journalize_expense()
returns trigger
language plpgsql
security definer
set search_path = 'finance', 'core', 'pg_temp'
as $function$
declare
  v_je uuid;
  v_debit_code text;
  v_credit_code text;
begin
  if new.status <> 'posted' or new.journal_entry_id is not null then
    return new;
  end if;
  if new.payment_source = 'other' then
    return new;
  end if;

  select c.ledger_account_code into v_debit_code
  from finance.expense_categories c
  where c.id = new.category_id;
  v_debit_code := coalesce(v_debit_code, '5900');

  v_credit_code := case new.payment_source
    when 'cashbox' then '1000'
    when 'partner_paid' then '2400'
    when 'unpaid_payable' then '2300'
  end;

  insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
  values (new.tenant_id, core.generate_public_code('JE'), new.well_id, new.spent_at,
          'expense', new.id, 'مصروف: ' || new.description, 'EXP-' || new.id::text)
  returning id into v_je;

  insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, cashbox_id, description)
  values
    (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, v_debit_code), 'debit', new.amount_minor, null, null, new.description),
    (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, v_credit_code), 'credit', new.amount_minor,
     case when new.payment_source = 'partner_paid' then new.partner_id else null end,
     case when new.payment_source = 'cashbox' then new.cashbox_id else null end,
     'طرف الدائن للمصروف');

  perform finance.post_journal_entry(v_je, new.created_by);

  update finance.expenses
  set journal_entry_id = v_je
  where id = new.id;

  return new;
end;
$function$;

create trigger expenses_journalize
  after insert or update of status on finance.expenses
  for each row execute function finance.journalize_expense();

-- (4ج) ترحيل الفواتير عند الاصدار
create or replace function billing.journalize_invoice()
returns trigger
language plpgsql
security definer
set search_path = 'billing', 'finance', 'core', 'pg_temp'
as $function$
declare
  v_je uuid;
  v_lines_count integer;
  v_lines_sum bigint;
begin
  if new.status <> 'issued' or new.journal_entry_id is not null then
    return new;
  end if;

  select count(*), coalesce(sum(l.amount_minor), 0) into v_lines_count, v_lines_sum
  from billing.invoice_lines l
  where l.invoice_id = new.id;

  if v_lines_count > 0 and v_lines_sum <> new.total_minor then
    raise exception 'لا يمكن اصدار الفاتورة %: مجموع البنود % لا يساوي الاجمالي %', new.public_code, v_lines_sum, new.total_minor;
  end if;

  insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
  values (new.tenant_id, core.generate_public_code('JE'), new.well_id, new.invoice_date,
          'invoice', new.id, 'فاتورة ' || new.public_code, 'INV-' || new.id::text)
  returning id into v_je;

  insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, farmer_well_account_id, description)
  values (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1100'), 'debit', new.total_minor, new.farmer_well_account_id, 'ذمة الفاتورة على المزارع');

  if v_lines_count = 0 then
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, description)
    values (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '4000'), 'credit', new.total_minor, 'ايراد الفاتورة');
  else
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, description)
    select new.tenant_id, v_je,
           finance.ledger_account_id(new.well_id, case l.line_type
             when 'solar_irrigation' then '4000'
             when 'diesel_operation' then '4100'
             when 'diesel_fuel' then '4200'
             else '4300'
           end),
           'credit', sum(l.amount_minor), 'ايراد: ' || l.line_type
    from billing.invoice_lines l
    where l.invoice_id = new.id
    group by l.line_type;
  end if;

  perform finance.post_journal_entry(v_je, new.issued_by);

  update billing.invoices
  set journal_entry_id = v_je
  where id = new.id;

  return new;
end;
$function$;

create trigger invoices_journalize
  after insert or update of status on billing.invoices
  for each row execute function billing.journalize_invoice();

-- (5) قيد شراء الديزل يحمل معرف الصندوق الرئيسي
create or replace function finance.journalize_fuel_transaction()
returns trigger
language plpgsql
security definer
set search_path = 'finance', 'core', 'pg_temp'
as $function$
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
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, fuel_tank_id, cashbox_id, description) values
      (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1200'), 'debit',  new.total_cost_minor, new.fuel_tank_id, null, 'مخزون ديزل البئر'),
      (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1000'), 'credit', new.total_cost_minor, null, finance.main_cashbox_id(new.well_id), 'النقد والصناديق');
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
$function$;

-- (6أ) عكس قيد مرحل: ينشئ قيدا عكسيا مرحلا ويعلّم الاصلي معكوسا
create or replace function finance.reverse_journal_entry(p_entry_id uuid, p_reason text, p_posted_by uuid default null)
returns uuid
language plpgsql
security definer
set search_path = 'finance', 'core', 'pg_temp'
as $function$
declare
  v_old finance.journal_entries%rowtype;
  v_new uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'سبب العكس مطلوب';
  end if;

  select * into v_old from finance.journal_entries where id = p_entry_id for update;
  if not found then
    raise exception 'القيد غير موجود: %', p_entry_id;
  end if;
  if v_old.source_type = 'reversal' then
    raise exception 'لا يمكن عكس قيد عكسي';
  end if;
  if v_old.status <> 'posted' then
    raise exception 'لا يمكن عكس قيد حالته % — يجب ان يكون مرحلا', v_old.status;
  end if;

  insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key, reversal_of_entry_id)
  values (v_old.tenant_id, core.generate_public_code('JE'), v_old.well_id, now(),
          'reversal', v_old.id, 'عكس قيد ' || v_old.public_code || ': ' || p_reason,
          'REV-' || v_old.id::text, v_old.id)
  returning id into v_new;

  insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, person_id, farmer_well_account_id, partner_id, cashbox_id, fuel_tank_id, description)
  select l.tenant_id, v_new, l.ledger_account_id,
         case l.entry_side when 'debit' then 'credit' else 'debit' end,
         l.amount_minor, l.person_id, l.farmer_well_account_id, l.partner_id, l.cashbox_id, l.fuel_tank_id,
         'عكس: ' || coalesce(l.description, '')
  from finance.journal_lines l
  where l.journal_entry_id = v_old.id;

  perform finance.post_journal_entry(v_new, p_posted_by);

  update finance.journal_entries
  set status = 'reversed'
  where id = v_old.id;

  return v_new;
end;
$function$;

-- (6ب) عكس دفعة: يعكس قيدها ثم يعلّمها معكوسة
create or replace function billing.reverse_payment(p_payment_id uuid, p_reason text, p_reversed_by uuid default null)
returns uuid
language plpgsql
security definer
set search_path = 'billing', 'finance', 'core', 'pg_temp'
as $function$
declare
  v_pay billing.payments%rowtype;
  v_rev uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'سبب العكس مطلوب';
  end if;

  select * into v_pay from billing.payments where id = p_payment_id for update;
  if not found then
    raise exception 'الدفعة غير موجودة: %', p_payment_id;
  end if;
  if v_pay.status <> 'posted' then
    raise exception 'لا يمكن عكس دفعة حالتها % — يجب ان تكون مرحلة', v_pay.status;
  end if;

  if v_pay.journal_entry_id is not null then
    v_rev := finance.reverse_journal_entry(v_pay.journal_entry_id, 'عكس دفعة ' || coalesce(v_pay.public_code, v_pay.id::text) || ': ' || p_reason, p_reversed_by);
  end if;

  update billing.payments
  set status = 'reversed',
      note = coalesce(note || ' | ', '') || 'معكوسة: ' || p_reason,
      updated_at = now()
  where id = v_pay.id;

  return v_rev;
end;
$function$;

-- (7) اصلاح عرض ارصدة الصناديق: احتساب القيود المرحلة والمعكوسة معا
create or replace view reporting.cashbox_balances
with (security_invoker = true) as
select w.tenant_id,
       c.well_id,
       c.id as cashbox_id,
       c.public_code,
       c.name,
       coalesce(sum(case when l.entry_side = 'debit' and e.status in ('posted', 'reversed') then l.amount_minor else 0 end), 0)
     - coalesce(sum(case when l.entry_side = 'credit' and e.status in ('posted', 'reversed') then l.amount_minor else 0 end), 0) as balance_minor
from finance.cashboxes c
join core.wells w on w.id = c.well_id
left join finance.journal_lines l on l.cashbox_id = c.id
left join finance.journal_entries e on e.id = l.journal_entry_id
group by w.tenant_id, c.well_id, c.id, c.public_code, c.name;

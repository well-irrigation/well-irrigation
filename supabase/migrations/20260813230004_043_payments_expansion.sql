-- المرحلة 4 - الملف 043
-- توسيع billing.payments لتقبل: سداد دين قديم، دفع مقدم، الصندوق، المناوبة، من حصل المبلغ
-- يحسم م-20: التحصيل ممكن بدون جلسة. المرجع: doc 03 §28 §29 + قرار المالك

alter table billing.payments
  add column if not exists tenant_id uuid references core.tenants(id),
  add column if not exists well_id uuid references core.wells(id),
  add column if not exists public_code text default core.generate_public_code('PAY'),
  add column if not exists farmer_well_account_id uuid references ops.farmer_well_accounts(id),
  add column if not exists payer_person_id uuid references core.persons(id),
  add column if not exists cashbox_id uuid,
  add column if not exists shift_id uuid references ops.shifts(id),
  add column if not exists collected_by_profile_id uuid references iam.profiles(id),
  add column if not exists purpose text not null default 'session',
  add column if not exists status text not null default 'posted',
  add column if not exists note text,
  add column if not exists attachment_url text;

-- المفتاح الاجنبي المطلوب في doc 03 §29 بالاسم نفسه
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'fk_payment_cashbox') then
    alter table billing.payments
      add constraint fk_payment_cashbox foreign key (cashbox_id) references finance.cashboxes(id);
  end if;
end $$;

-- التحصيل بدون جلسة صار مسموحا
alter table billing.payments alter column session_charge_id drop not null;

alter table billing.payments drop constraint if exists payments_purpose_check;
alter table billing.payments add constraint payments_purpose_check
  check (purpose in ('session', 'old_debt', 'advance'));

alter table billing.payments drop constraint if exists payments_status_check;
alter table billing.payments add constraint payments_status_check
  check (status in ('draft', 'posted', 'reversed'));

-- دفعة الجلسة تلزمها جلسة، وغيرها يلزمها حساب مزارع
alter table billing.payments drop constraint if exists payments_target_check;
alter table billing.payments add constraint payments_target_check check (
  (purpose = 'session' and session_charge_id is not null)
  or (purpose in ('old_debt', 'advance') and farmer_well_account_id is not null and session_charge_id is null)
);

-- توسيع طرق الدفع الى ست قيم
do $$
declare r record;
begin
  for r in
    select conname from pg_constraint
    where conrelid = 'billing.payments'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%method%'
  loop
    execute format('alter table billing.payments drop constraint %I', r.conname);
  end loop;
end $$;

alter table billing.payments add constraint payments_method_check
  check (method in ('cash', 'bank_transfer', 'mobile_wallet', 'fuel_in_kind', 'offset_credit', 'other'));

create index if not exists payments_shift_idx on billing.payments (shift_id);
create index if not exists payments_cashbox_idx on billing.payments (cashbox_id, paid_at);
create index if not exists payments_account_idx on billing.payments (farmer_well_account_id, paid_at);

-- اعادة كتابة حماية عدم تجاوز التكلفة: تتخطى الدفعات بلا جلسة وتتجاهل الملغاة
create or replace function billing.check_payment_not_exceed_charge()
returns trigger
language plpgsql
as $$
declare
  total_paid bigint;
  charge_amount bigint;
begin
  if new.session_charge_id is null then
    return new;
  end if;

  if coalesce(new.status, 'posted') = 'reversed' then
    return new;
  end if;

  select coalesce(sum(amount_minor), 0) into total_paid
  from billing.payments
  where session_charge_id = new.session_charge_id
    and coalesce(status, 'posted') <> 'reversed';

  select amount_minor into charge_amount
  from billing.session_charges
  where id = new.session_charge_id;

  if total_paid > charge_amount then
    raise exception 'مجموع المدفوعات للتكلفة % تجاوز المبلغ المستحق %، القيمة المحاولة %', new.session_charge_id, charge_amount, total_paid;
  end if;

  return new;
end;
$$;

-- ملء الصندوق والبئر تلقائيا عند تسجيل دفعة
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
    where s.well_id = new.well_id and s.status = 'open'
    limit 1;
  end if;

  if new.collected_by_profile_id is null and new.shift_id is not null then
    select s.operator_profile_id into new.collected_by_profile_id from ops.shifts s where s.id = new.shift_id;
  end if;

  return new;
end;
$$;

create trigger payments_fill_context
before insert on billing.payments
for each row execute function billing.fill_payment_context();

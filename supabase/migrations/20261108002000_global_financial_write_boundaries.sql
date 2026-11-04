-- R6-C2B coordinated root-first financial boundaries.
-- Static implementation only; owner compilation, regression and concurrency pending.
begin;
-- New scope bootstrap boundary. BEFORE INSERT owns the canonical advisory
-- root before the well row/default financial children exist. This also keeps
-- owner fixtures/migrations inserting new wells compatible without allowing a
-- deep posting helper to first-acquire root after an existing child lock.
create function core.lock_new_well_financial_scope() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin
 perform billing.lock_customer_credit_well(new.id);
 return new;
end;$$;
revoke all on function core.lock_new_well_financial_scope() from public,anon,authenticated,service_role;
create trigger aa_new_well_financial_boundary before insert on core.wells
 for each row execute function core.lock_new_well_financial_scope();

-- Narrow root-owning boundary. SQL roles are not business roles; auth.uid and
-- current assignments/permissions remain authoritative before and after wait.
create function billing.enter_financial_write(p_well uuid,p_permission text default null,p_roles text[] default null,p_expected_tenant uuid default null)
returns void language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare tenant uuid;
begin
 if auth.uid() is null and current_setting('role',true) in ('anon','authenticated','service_role') then
  raise exception 'authentication_required' using errcode='42501';end if;
 select tenant_id into tenant from core.wells where id=p_well;
 if tenant is null then raise exception 'financial_well_required' using errcode='22023';end if;
 if p_expected_tenant is not null and tenant<>p_expected_tenant then raise exception 'financial_parent_scope_mismatch' using errcode='42501';end if;
 if auth.uid() is not null and((p_permission is not null and not coalesce(iam.has_well_permission(p_well,p_permission),false))
  or(p_roles is not null and not coalesce(iam.has_well_role(p_well,p_roles),false))) then
  raise exception 'financial_write_forbidden' using errcode='42501';end if;
 perform billing.lock_customer_credit_well(p_well);
 -- C1/start accept operational scope before processed_commands. Financial
 -- command reservation must use the same well-before-command order; otherwise
 -- a colliding command id can form WELL -> COMMAND -> WELL through journal FK.
 perform ops.lock_operational_scope(p_well,true);
 if not exists(select 1 from core.wells where id=p_well and tenant_id=tenant) then
  raise exception 'financial_scope_changed' using errcode='40001';end if;
 if auth.uid() is not null and((p_permission is not null and not coalesce(iam.has_well_permission(p_well,p_permission),false))
  or(p_roles is not null and not coalesce(iam.has_well_role(p_well,p_roles),false))) then
  raise exception 'financial_write_forbidden' using errcode='42501';end if;
end;$$;
revoke all on function billing.enter_financial_write(uuid,text,text[],uuid) from public,anon,authenticated,service_role;

-- Preserved body from 20260814031001_061_money_procedures.sql; only root boundary/necessary row lock changes.
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
 -- Internal child of source cancellation; never establish root after its source lock.
 perform billing.require_customer_credit_well_lock((select well_id from finance.journal_entries where id=p_entry_id));
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

-- Preserved body from 20260813233001_044_expenses.sql; only root boundary/necessary row lock changes.
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
 if auth.uid() is not null then
  if p_approver_profile_id is not null and p_approver_profile_id is distinct from auth.uid() then raise exception 'financial_actor_mismatch' using errcode='42501';end if;
  p_approver_profile_id:=auth.uid();
 end if;
 perform billing.enter_financial_write((select well_id from finance.expenses where id=p_expense_id),'expense.approve',null, (select tenant_id from finance.expenses where id=p_expense_id));
  select * into v_e from finance.expenses where id = p_expense_id for update;
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

-- Preserved body from 20260814022001_055_payroll_and_fuel_journal.sql; only root boundary/necessary row lock changes.
create or replace function finance.pay_salary(p_accrual_id uuid, p_paid_by uuid default null)
returns void language plpgsql security definer
set search_path to 'finance', 'core', 'pg_temp' as $$
declare
  v_accr record;
  v_je uuid;
  v_cashbox uuid;
  v_person_name text;
begin
 if auth.uid() is not null then
  if p_paid_by is not null and p_paid_by is distinct from auth.uid() then raise exception 'financial_actor_mismatch' using errcode='42501';end if;
  p_paid_by:=auth.uid();
 end if;
 perform billing.enter_financial_write((select well_id from finance.payroll_accruals where id=p_accrual_id),'payroll.pay',null, (select tenant_id from finance.payroll_accruals where id=p_accrual_id));
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

-- Preserved body from 20260814022001_055_payroll_and_fuel_journal.sql; only root boundary/necessary row lock changes.
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
 if auth.uid() is not null then
  if p_posted_by is not null and p_posted_by is distinct from auth.uid() then raise exception 'financial_actor_mismatch' using errcode='42501';end if;
  p_posted_by:=auth.uid();
 end if;
 perform billing.enter_financial_write((select well_id from finance.opening_balance_batches where id=p_batch_id),null,array['owner'], (select tenant_id from finance.opening_balance_batches where id=p_batch_id));
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

-- Preserved body from 20260814023001_056_record_expense_overload_and_opening_approve_check.sql; only root boundary/necessary row lock changes.
create or replace function finance.approve_opening_balance_batch(p_batch_id uuid, p_approved_by uuid)
returns void language plpgsql security definer set search_path to 'finance', 'pg_temp' as $$
declare
  v_status text;
  v_items integer;
  v_debits bigint;
  v_credits bigint;
begin
 if auth.uid() is not null then
  if p_approved_by is not null and p_approved_by is distinct from auth.uid() then raise exception 'financial_actor_mismatch' using errcode='42501';end if;
  p_approved_by:=auth.uid();
 end if;
 perform billing.enter_financial_write((select well_id from finance.opening_balance_batches where id=p_batch_id),null,array['owner'], (select tenant_id from finance.opening_balance_batches where id=p_batch_id));
  select status into v_status from finance.opening_balance_batches where id = p_batch_id for update;
  if v_status is null then raise exception 'جلسة الارصدة غير موجودة: %', p_batch_id; end if;
  if v_status not in ('draft', 'pending_approval') then
    raise exception 'لا يمكن اعتماد جلسة حالتها % — يجب ان تكون مسودة او بانتظار الاعتماد', v_status;
  end if;
  select count(*) into v_items from finance.opening_balance_items where batch_id = p_batch_id;
  if v_items = 0 then raise exception 'لا يمكن اعتماد جلسة بلا عناصر'; end if;

  -- التوازن الافتتاحي يفحص عند الاعتماد (والترحيل يعيده كحارس نهائي)
  select coalesce(sum(case when item_type in ('farmer_debt','cashbox_balance','fuel_tank_balance','partner_receivable') then amount_minor else 0 end), 0),
         coalesce(sum(case when item_type in ('farmer_advance','partner_payable','salary_payable','expense_payable','capital_balance') then amount_minor else 0 end), 0)
  into v_debits, v_credits
  from finance.opening_balance_items where batch_id = p_batch_id;
  if v_debits <> v_credits then
    raise exception 'جلسة الارصدة غير متوازنة: مجموع الاصول % لا يساوي مجموع الالتزامات وراس المال %', v_debits, v_credits;
  end if;

  update finance.opening_balance_batches
  set status = 'approved', approved_by = p_approved_by, approved_at = now()
  where id = p_batch_id;
end;
$$;

-- Preserved body from 20260929133348_operator_cash_custody.sql; only root boundary/necessary row lock changes.
create or replace function ops.confirm_handover(
  p_handover_id uuid,
  p_confirmed_amount_minor bigint,
  p_confirmed_by uuid,
  p_difference_reason text default null
)
returns text
language plpgsql
security definer
set search_path to 'ops', 'finance', 'core', 'pg_temp'
as $$
declare
  v_h ops.shift_handovers%rowtype;
  v_src finance.cashboxes%rowtype;
  v_diff bigint;
  v_je uuid;
  v_amount bigint;
begin
 perform billing.enter_financial_write((select well_id from ops.shift_handovers where id=p_handover_id),'handover.confirm',null, (select tenant_id from ops.shift_handovers where id=p_handover_id));
  select * into v_h from ops.shift_handovers where id = p_handover_id for update;
  if v_h.id is null then
    raise exception 'اقرار التسليم % غير موجود', p_handover_id;
  end if;
  if v_h.status in ('confirmed', 'settled') then
    raise exception 'اقرار التسليم % مؤكد مسبقا', p_handover_id;
  end if;

  v_diff := p_confirmed_amount_minor - v_h.declared_amount_minor;

  -- ═══ ترحيل حيازة المشغل: مطابقة تامة = قيد نقل واحد وتكراره مستحيل ═══
  --    مدين 1000 لصندوق البئر العام / دائن 1000 لحيازة المشغل —
  --    بلا إيراد ولا ذمم ولا مقدم ولا مصروف، والنقد الكلي للبئر
  --    لا يتغير. (unique(well_id, source_type, source_id) في 036
  --    ومفتاح idempotency ثانٍ يمنعان قيدًا ثانيًا حتى لو حُاول.)
  if v_h.handover_kind = 'operator_cash_remittance' and v_diff = 0 then
    if v_h.from_cashbox_id is null or v_h.to_cashbox_id is null then
      raise exception 'اقرار الترحيل % بلا صندوق مصدر أو وجهة — لا قيد نقلي', p_handover_id;
    end if;

    -- نقطة التسلسل: قفل صف صندوق الحيازة المصدر قبل أي قراءة رصيد.
    -- كل تأكيدات الترحيل على الصندوق نفسه تتصالح على هذا الصف الواحد؛
    -- فالمتأخر في القفل يرى بعد انتظاره الترحيل المرحّل سلفًا في
    -- رصيده — فلا حيازة سالبة ولا قيد مزدوج تحت التزامن.
    select * into v_src
    from finance.cashboxes c
    where c.id = v_h.from_cashbox_id
      and c.well_id = v_h.well_id
      and c.cashbox_type = 'operator_custody'
      and c.status = 'active'
      and c.assigned_profile_id = v_h.from_profile_id
    for update;
    if not found then
      raise exception 'صندوق حيازة المصدر غير صالح للاقرار %: يلزم حيازة نشطة للملف المرسل في البئر نفسه', p_handover_id;
    end if;

    -- الوجهة: صندوق البئر العام في البئر نفسه وفعّال.
    if not exists (
      select 1 from finance.cashboxes c
      where c.id = v_h.to_cashbox_id
        and c.well_id = v_h.well_id
        and c.cashbox_type = 'main_well'
        and c.status = 'active'
    ) then
      raise exception 'صناديق الترحيل غير صالحة: المصدر حيازة المشغل والوجهة صندوق البئر العام في البئر نفسه';
    end if;

    -- قراءة الرصيد بعد اكتساب قفل المصدر حصرًا.
    if finance.cashbox_balance_minor(v_h.from_cashbox_id) < v_h.declared_amount_minor then
      raise exception 'حيازة المشغل الحالية أقل من مبلغ الترحيل % — لا قيد نقلي', v_h.declared_amount_minor;
    end if;

    v_amount := v_h.declared_amount_minor;
    v_je := gen_random_uuid();

    insert into finance.journal_entries (
      id, tenant_id, public_code, well_id, entry_date,
      source_type, source_id, description, idempotency_key
    ) values (
      v_je, v_h.tenant_id, core.generate_public_code('JE'), v_h.well_id,
      clock_timestamp(), 'operator_cash_remittance', v_h.id,
      'ترحيل حيازة المشغل النقدية إلى صندوق البئر — نقل حيازة لا إيراد',
      'CUSTODY-REMIT-' || v_h.id::text
    );

    insert into finance.journal_lines (
      tenant_id, journal_entry_id, ledger_account_id, entry_side,
      amount_minor, cashbox_id, description
    ) values
      (v_h.tenant_id, v_je, finance.ledger_account_id(v_h.well_id, '1000'), 'debit',
       v_amount, v_h.to_cashbox_id, 'استلام صندوق البئر العام من حيازة المشغل'),
      (v_h.tenant_id, v_je, finance.ledger_account_id(v_h.well_id, '1000'), 'credit',
       v_amount, v_h.from_cashbox_id, 'خروج نقد حيازة المشغل إلى صندوق البئر العام');

    perform finance.post_journal_entry(v_je, p_confirmed_by);

    update ops.shift_handovers
    set confirmed_amount_minor = p_confirmed_amount_minor, difference_minor = 0,
        status = 'confirmed', confirmed_by = p_confirmed_by, confirmed_at = now(),
        journal_entry_id = v_je
    where id = p_handover_id;

    perform ops.notify_profile(v_h.from_profile_id, v_h.well_id, 'handover_confirmed',
      format('تم تأكيد ترحيل %s ريال من حيازتك إلى صندوق البئر، ورفعت المسؤولية', p_confirmed_amount_minor));
    return 'confirmed';
  end if;

  -- ═══ التسليم العادي/الشخصي: سلوكه القائم كما هو حرفيًا ═══
  if v_diff = 0 then
    update ops.shift_handovers
    set confirmed_amount_minor = p_confirmed_amount_minor, difference_minor = 0,
        status = 'confirmed', confirmed_by = p_confirmed_by, confirmed_at = now()
    where id = p_handover_id;

    perform ops.notify_profile(v_h.from_profile_id, v_h.well_id, 'handover_confirmed',
      format('تم تاكيد استلام مبلغ %s ريال منك، ورفعت المسؤولية', p_confirmed_amount_minor));
    return 'confirmed';
  end if;

  if p_difference_reason is null then
    raise exception 'يوجد فرق % ريال بين المبلغ المقر والمبلغ المؤكد، وذكر السبب الزامي', v_diff;
  end if;

  -- ترحيل بفرق: يعلق difference_pending ولا يُرحَّل نقديًا صمتًا ولا
  -- يُخترع محاسبة عجز/زيادة — حسمه عقد مالي مخصص (رسالة settle أدناه).
  update ops.shift_handovers
  set confirmed_amount_minor = p_confirmed_amount_minor, difference_minor = v_diff,
      difference_reason = p_difference_reason, status = 'difference_pending',
      confirmed_by = p_confirmed_by, confirmed_at = now()
  where id = p_handover_id;

  perform ops.notify_well_owners(v_h.well_id, 'handover_difference',
    format('فرق في التسليم: المقر %s ريال والمؤكد %s ريال (الفرق %s) - السبب: %s',
      v_h.declared_amount_minor, p_confirmed_amount_minor, v_diff, p_difference_reason));
  perform ops.notify_profile(v_h.from_profile_id, v_h.well_id, 'handover_difference',
    format('يوجد فرق %s ريال في تسليمك، معلق حتى حسم المالك', v_diff));

  return 'difference_pending';
end;
$$;

-- Preserved body from 20260929133348_operator_cash_custody.sql; only root boundary/necessary row lock changes.
create or replace function ops.settle_handover(p_handover_id uuid, p_settled_by uuid)
returns text
language plpgsql
security definer
set search_path to 'ops', 'pg_temp'
as $$
declare
  v_h record;
begin
 perform billing.enter_financial_write((select well_id from ops.shift_handovers where id=p_handover_id),'handover.settle',null, (select tenant_id from ops.shift_handovers where id=p_handover_id));
  select * into v_h from ops.shift_handovers where id = p_handover_id for update;
  if v_h.id is null then
    raise exception 'اقرار التسليم % غير موجود', p_handover_id;
  end if;
  if v_h.status <> 'difference_pending' then
    raise exception 'لا يوجد فرق معلق في الاقرار % (الحالة %)', p_handover_id, v_h.status;
  end if;
  -- الترتيب المقصود: «لا فرق معلق» أولًا بسلوكه العادي، ثم رفض ترحيل
  -- الحيازة بعقد التسوية المالية المخصص — فترحيل مؤكد مطابقًا يحصل
  -- على رسالة «لا فرق معلق» لا رسالة العقد المضللة.
  if v_h.handover_kind = 'operator_cash_remittance' then
    raise exception 'فرق ترحيل حيازة المشغل في الاقرار % لا يُحسم بلا عقد تسوية مالية مخصص — لا يُفترض اختفاؤه ولا يُخترع محاسبة للعجز', p_handover_id;
  end if;

  update ops.shift_handovers
  set status = 'settled', confirmed_by = p_settled_by, confirmed_at = now()
  where id = p_handover_id;

  perform ops.notify_profile(v_h.from_profile_id, v_h.well_id, 'handover_settled',
    'تم حسم فرق التسليم من المالك، ورفعت المسؤولية عنك');

  return 'settled';
end;
$$;

-- Preserved body from 20261102000000_operational_occurrence_contract.sql; only root boundary/necessary row lock changes.
create or replace function ops.complete_irrigation_session(
  p_session_id uuid,
  p_ended_at timestamptz default now(),
  p_fuel_quantity_ml bigint default null,
  p_fuel_measurement_type text default null,
  p_fuel_tank_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'ops', 'billing', 'inventory', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_tenant_id uuid;
  v_status text;
  v_session_started_at timestamptz;
  v_operator_profile_id uuid;
  v_farmer_well_account_id uuid;
  v_open_segment_id uuid;
  v_open_segment_type text;
  v_open_energy_source text;
  v_open_started_at timestamptz;
  v_total_actual_seconds bigint;
  v_total_billable_seconds bigint;
  v_total_amount_minor bigint;
  v_weighted_numerator numeric;
  v_weighted_rate_minor bigint;
  v_charge_id uuid;
  v_fuel_quantity bigint;
  v_segment record;
  v_segments_json jsonb;
begin
 perform billing.enter_financial_write((select well_id from ops.irrigation_sessions where id=p_session_id),'session.complete',null);
  perform ops.lock_operational_scope((select well_id from ops.irrigation_sessions where id=p_session_id));
  if p_fuel_quantity_ml is not null and p_fuel_quantity_ml <= 0 then
    raise exception 'كمية الوقود المستهلك يجب أن تكون أكبر من صفر';
  end if;
  if p_fuel_quantity_ml is not null
     and coalesce(p_fuel_measurement_type, 'actual') not in ('actual', 'estimated') then
    raise exception 'نوع قياس الوقود يجب أن يكون actual أو estimated';
  end if;

  select s.well_id, w.tenant_id, s.status, s.started_at,
         s.operator_profile_id, s.farmer_well_account_id
  into v_well_id, v_tenant_id, v_status, v_session_started_at,
       v_operator_profile_id, v_farmer_well_account_id
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
  for update of s;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;
  if v_status <> 'open' then
    raise exception 'لا يمكن إكمال جلسة مغلقة أو غير مفتوحة';
  end if;

  v_actor := auth.uid();
  if v_actor is null or not iam.has_well_permission(v_well_id, 'session.complete') then
    raise exception 'لا تملك صلاحية إكمال هذه الجلسة';
  end if;
  if p_ended_at <= v_session_started_at then
    raise exception 'وقت نهاية الجلسة يجب أن يكون بعد وقت بدايتها';
  end if;
  if p_fuel_tank_id is not null and not exists (
    select 1 from inventory.fuel_tanks ft
    where ft.id = p_fuel_tank_id
      and ft.well_id = v_well_id
      and ft.status = 'active'
  ) then
    raise exception 'خزان الوقود غير موجود أو غير فعال في هذا البئر';
  end if;
  if exists (
    select 1 from billing.session_charges sc where sc.session_id = p_session_id
  ) then
    raise exception 'توجد تكلفة مسجلة مسبقًا لهذه الجلسة';
  end if;

  select ss.id, ss.segment_type, ss.energy_source, ss.started_at
  into v_open_segment_id, v_open_segment_type, v_open_energy_source,
       v_open_started_at
  from ops.session_segments ss
  where ss.session_id = p_session_id and ss.ended_at is null
  order by ss.sequence_number desc
  limit 1
  for update;

  if not found then
    raise exception 'لا يوجد مقطع مفتوح يمكن إغلاقه عند إكمال الجلسة';
  end if;
  if p_ended_at <= v_open_started_at then
    raise exception 'وقت نهاية الجلسة يجب أن يكون بعد وقت بدء المقطع المفتوح';
  end if;
  if p_fuel_quantity_ml is not null
     and v_open_energy_source not in ('well_diesel', 'farmer_diesel') then
    raise exception 'لا يمكن تسجيل استهلاك وقود على مقطع غير ديزل';
  end if;

  update ops.session_segments
  set ended_at = p_ended_at,
      fuel_measurement_type = case
        when p_fuel_quantity_ml is null then fuel_measurement_type
        else coalesce(p_fuel_measurement_type, 'actual')
      end,
      fuel_actual_ml = case
        when p_fuel_quantity_ml is not null
         and coalesce(p_fuel_measurement_type, 'actual') = 'actual'
          then p_fuel_quantity_ml
        else fuel_actual_ml
      end,
      fuel_estimated_ml = case
        when p_fuel_quantity_ml is not null
         and coalesce(p_fuel_measurement_type, 'actual') = 'estimated'
          then p_fuel_quantity_ml
        else fuel_estimated_ml
      end
  where id = v_open_segment_id;

  return ops.finalize_session_from_closed_segments(p_session_id,p_ended_at,p_fuel_tank_id);
end;
$function$;

-- Preserved body from 20260822013001_082_permission_enforcement_ops.sql; only root boundary/necessary row lock changes.
create or replace function ops.pause_irrigation_session(
  p_session_id uuid,
  p_reason text,
  p_paused_at timestamptz default clock_timestamp()
)
returns uuid
language plpgsql
security definer
set search_path to 'ops', 'core', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_tenant_id uuid;
  v_status text;
  v_segment_id uuid;
  v_segment_type text;
  v_segment_started_at timestamptz;
  v_sequence_number integer;
  v_pause_id uuid;
begin
 perform billing.enter_financial_write((select well_id from ops.irrigation_sessions where id=p_session_id),'session.pause',null);
  if p_reason not in ('operator_pause', 'farmer_requested_pause') then
    raise exception 'سبب الإيقاف غير صالح؛ المسموح operator_pause أو farmer_requested_pause';
  end if;

  select s.well_id, w.tenant_id, s.status
  into v_well_id, v_tenant_id, v_status
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
  for update of s;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;
  if v_status <> 'open' then
    raise exception 'لا يمكن إيقاف جلسة غير مفتوحة';
  end if;

  v_actor := auth.uid();
  if v_actor is null or not iam.has_well_permission(v_well_id, 'session.pause') then
    raise exception 'لا تملك صلاحية إيقاف هذه الجلسة';
  end if;

  select ss.id, ss.segment_type, ss.started_at, ss.sequence_number
  into v_segment_id, v_segment_type, v_segment_started_at, v_sequence_number
  from ops.session_segments ss
  where ss.session_id = p_session_id and ss.ended_at is null
  order by ss.sequence_number desc
  limit 1
  for update;

  if not found then
    raise exception 'لا يوجد مقطع تشغيل مفتوح يمكن إيقافه';
  end if;
  if v_segment_type not in ('solar_run', 'well_diesel_run', 'farmer_diesel_run') then
    raise exception 'الجلسة متوقفة بالفعل ولا يوجد مقطع تشغيل مفتوح';
  end if;
  if p_paused_at <= v_segment_started_at then
    raise exception 'وقت الإيقاف يجب أن يكون بعد وقت بدء مقطع التشغيل';
  end if;

  update ops.session_segments
  set ended_at = p_paused_at
  where id = v_segment_id;

  insert into ops.session_segments (
    tenant_id, session_id, sequence_number, segment_type,
    energy_source, started_at, is_billable, notes
  ) values (
    v_tenant_id, p_session_id, v_sequence_number + 1, p_reason,
    null, p_paused_at, false, p_reason
  )
  returning id into v_pause_id;

  return v_pause_id;
end;
$function$;

-- Preserved body from 20260916010001_100_paused_energy_source_change.sql; only root boundary/necessary row lock changes.
create or replace function ops.resume_irrigation_session(
  p_session_id uuid,
  p_resumed_at timestamptz default clock_timestamp()
)
returns uuid
language plpgsql
security definer
set search_path to 'ops', 'core', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_tenant_id uuid;
  v_status text;
  v_pause_id uuid;
  v_pause_type text;
  v_pause_started_at timestamptz;
  v_sequence_number integer;
  v_pause_energy_source text;
  v_pause_fuel_owner uuid;
  v_energy_source text;
  v_segment_type text;
  v_fuel_owner_person_id uuid;
  v_price_rule_id uuid;
  v_hourly_rate_minor bigint;
  v_operation_rate_minor bigint;
  v_fuel_price_per_liter_minor bigint;
  v_new_segment_id uuid;
begin
 perform billing.enter_financial_write((select well_id from ops.irrigation_sessions where id=p_session_id),'session.resume',null);
  select s.well_id, w.tenant_id, s.status
  into v_well_id, v_tenant_id, v_status
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
  for update of s;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;
  if v_status <> 'open' then
    raise exception 'لا يمكن استئناف جلسة غير مفتوحة';
  end if;

  v_actor := auth.uid();
  if v_actor is null or not iam.has_well_permission(v_well_id, 'session.resume') then
    raise exception 'لا تملك صلاحية استئناف هذه الجلسة';
  end if;

  select ss.id, ss.segment_type, ss.started_at, ss.sequence_number,
         ss.energy_source, ss.fuel_owner_person_id
  into v_pause_id, v_pause_type, v_pause_started_at, v_sequence_number,
       v_pause_energy_source, v_pause_fuel_owner
  from ops.session_segments ss
  where ss.session_id = p_session_id and ss.ended_at is null
  order by ss.sequence_number desc
  limit 1
  for update;

  if not found then
    raise exception 'لا يوجد مقطع توقف مفتوح يمكن استئنافه';
  end if;
  if v_pause_type not in ('operator_pause', 'farmer_requested_pause', 'source_change_pause') then
    raise exception 'الجلسة تعمل بالفعل ولا يوجد مقطع توقف مفتوح';
  end if;
  if p_resumed_at <= v_pause_started_at then
    raise exception 'وقت الاستئناف يجب أن يكون بعد وقت بدء التوقف';
  end if;

  -- إغلاق مقطع التوقف الحالي
  update ops.session_segments
  set ended_at = p_resumed_at
  where id = v_pause_id;

  if v_pause_energy_source is not null then
    -- ============================================================
    -- الحالة ب: التوقف يحمل تغييراً معلّقاً لمصدر الطاقة
    -- يُلتقط السعر المعتمد للمصدر الجديد عند لحظة الاستئناف مباشرة
    -- ============================================================
    v_new_segment_id := ops.create_priced_session_segment(
      p_session_id,
      v_pause_energy_source,
      p_resumed_at,
      v_pause_fuel_owner
    );
  else
    -- ============================================================
    -- الحالة أ: توقف عادي دون تغيير مصدر الطاقة
    -- استئناف نفس المصدر والسعر التاريخي السابق دون إعادة تسعير
    -- ============================================================
    select ss.energy_source, ss.segment_type, ss.fuel_owner_person_id,
           ss.applied_price_rule_id, ss.applied_hourly_rate_minor,
           ss.applied_operation_rate_minor,
           ss.applied_fuel_price_per_liter_minor
    into v_energy_source, v_segment_type, v_fuel_owner_person_id,
         v_price_rule_id, v_hourly_rate_minor, v_operation_rate_minor,
         v_fuel_price_per_liter_minor
    from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.sequence_number < v_sequence_number
      and ss.segment_type in ('solar_run', 'well_diesel_run', 'farmer_diesel_run')
    order by ss.sequence_number desc
    limit 1;

    if not found then
      raise exception 'لا يوجد مصدر تشغيل سابق يمكن استئنافه';
    end if;

    insert into ops.session_segments (
      tenant_id, session_id, sequence_number, segment_type, energy_source,
      started_at, is_billable, fuel_owner_person_id, applied_price_rule_id,
      applied_hourly_rate_minor, applied_operation_rate_minor,
      applied_fuel_price_per_liter_minor
    ) values (
      v_tenant_id, p_session_id, v_sequence_number + 1, v_segment_type,
      v_energy_source, p_resumed_at, true, v_fuel_owner_person_id,
      v_price_rule_id, v_hourly_rate_minor, v_operation_rate_minor,
      v_fuel_price_per_liter_minor
    )
    returning id into v_new_segment_id;
  end if;

  return v_new_segment_id;
end;
$function$;

-- Preserved body from 20260916010001_100_paused_energy_source_change.sql; only root boundary/necessary row lock changes.
create or replace function ops.change_session_energy_source(
  p_session_id uuid,
  p_new_source text,
  p_changed_at timestamptz default clock_timestamp(),
  p_closed_fuel_quantity_ml bigint default null,
  p_closed_fuel_measurement_type text default null,
  p_new_fuel_owner_person_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path to 'ops', 'core', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_tenant_id uuid;
  v_status text;
  v_segment_id uuid;
  v_segment_type text;
  v_current_source text;
  v_segment_started_at timestamptz;
  v_sequence_number integer;
  v_effective_source text;
  v_owner_person_id uuid;
  v_farmer_well_account_id uuid;
  v_new_segment_id uuid;
begin
 perform billing.enter_financial_write((select well_id from ops.irrigation_sessions where id=p_session_id),null,null);
  if p_new_source not in ('solar', 'well_diesel', 'farmer_diesel') then
    raise exception 'مصدر الطاقة الجديد غير صالح؛ القيم المسموحة: solar أو well_diesel أو farmer_diesel';
  end if;
  if p_closed_fuel_quantity_ml is not null and p_closed_fuel_quantity_ml <= 0 then
    raise exception 'كمية الوقود للمقطع المغلق يجب أن تكون أكبر من صفر';
  end if;
  if p_closed_fuel_quantity_ml is not null
     and coalesce(p_closed_fuel_measurement_type, 'actual') not in ('actual', 'estimated') then
    raise exception 'نوع قياس الوقود يجب أن يكون actual أو estimated';
  end if;

  select s.well_id, w.tenant_id, s.status, s.farmer_well_account_id
  into v_well_id, v_tenant_id, v_status, v_farmer_well_account_id
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
  for update of s;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;
  if v_status <> 'open' then
    raise exception 'لا يمكن تغيير مصدر الطاقة لجلسة غير مفتوحة';
  end if;

  v_actor := auth.uid();
  if v_actor is null or not iam.has_well_permission(v_well_id, 'session.energy.change') then
    raise exception 'لا تملك صلاحية تغيير مصدر الطاقة لهذه الجلسة';
  end if;

  select ss.id, ss.segment_type, ss.energy_source, ss.started_at, ss.sequence_number
  into v_segment_id, v_segment_type, v_current_source, v_segment_started_at, v_sequence_number
  from ops.session_segments ss
  where ss.session_id = p_session_id and ss.ended_at is null
  order by ss.sequence_number desc
  limit 1
  for update;

  if not found then
    raise exception 'لا يوجد مقطع تشغيل مفتوح يمكن تغيير مصدره';
  end if;

  if v_segment_type in ('solar_run', 'well_diesel_run', 'farmer_diesel_run') then
    -- ============================================================
    -- المسار الجاري: السقي يعمل (RUNNING)
    -- ============================================================
    if v_current_source = p_new_source then
      raise exception 'مصدر الطاقة الجديد مطابق للمصدر الحالي';
    end if;
    if p_changed_at <= v_segment_started_at then
      raise exception 'وقت تغيير المصدر يجب أن يكون بعد وقت بدء المقطع الحالي';
    end if;
    if p_closed_fuel_quantity_ml is not null
       and v_current_source not in ('well_diesel', 'farmer_diesel') then
      raise exception 'لا يمكن تسجيل استهلاك وقود على مقطع غير ديزل';
    end if;

    update ops.session_segments
    set ended_at = p_changed_at,
        fuel_measurement_type = case
          when p_closed_fuel_quantity_ml is null then fuel_measurement_type
          else coalesce(p_closed_fuel_measurement_type, 'actual')
        end,
        fuel_actual_ml = case
          when p_closed_fuel_quantity_ml is not null
           and coalesce(p_closed_fuel_measurement_type, 'actual') = 'actual'
            then p_closed_fuel_quantity_ml
          else fuel_actual_ml
        end,
        fuel_estimated_ml = case
          when p_closed_fuel_quantity_ml is not null
           and coalesce(p_closed_fuel_measurement_type, 'actual') = 'estimated'
            then p_closed_fuel_quantity_ml
          else fuel_estimated_ml
        end
    where id = v_segment_id;

    v_new_segment_id := ops.create_priced_session_segment(
      p_session_id, p_new_source, p_changed_at, p_new_fuel_owner_person_id
    );

    return v_new_segment_id;

  elsif v_segment_type in ('operator_pause', 'farmer_requested_pause', 'source_change_pause') then
    -- ============================================================
    -- المسار المتوقف: السقي موقوف مؤقتًا (PAUSED)
    -- ============================================================
    if p_closed_fuel_quantity_ml is not null or p_closed_fuel_measurement_type is not null then
      raise exception 'لا يمكن تسجيل بيانات إغلاق الوقود أثناء التوقف المؤقت';
    end if;
    if p_changed_at <= v_segment_started_at then
      raise exception 'وقت تغيير المصدر يجب أن يكون بعد وقت بدء المقطع الحالي';
    end if;

    -- تحديد المصدر الفعّال للمقارنة
    if v_current_source is not null then
      v_effective_source := v_current_source;
    else
      select ss.energy_source
      into v_effective_source
      from ops.session_segments ss
      where ss.session_id = p_session_id
        and ss.sequence_number < v_sequence_number
        and ss.segment_type in ('solar_run', 'well_diesel_run', 'farmer_diesel_run')
      order by ss.sequence_number desc
      limit 1;
    end if;

    if v_effective_source = p_new_source then
      raise exception 'مصدر الطاقة الجديد مطابق للمصدر الحالي';
    end if;

    -- التحقق من مالك الوقود عند التحويل إلى ديزل المزارع
    if p_new_source = 'farmer_diesel' then
      v_owner_person_id := p_new_fuel_owner_person_id;
      if v_owner_person_id is null and v_farmer_well_account_id is not null then
        select fp.person_id
        into v_owner_person_id
        from ops.farmer_well_accounts fwa
        join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
        where fwa.id = v_farmer_well_account_id;
      end if;

      if v_owner_person_id is null then
        raise exception 'يجب تحديد مالك ديزل المزارع قبل فتح المقطع';
      end if;

      if not exists (
        select 1 from core.persons p
        where p.id = v_owner_person_id and p.tenant_id = v_tenant_id
      ) then
        raise exception 'مالك ديزل المزارع لا ينتمي إلى جهة البئر';
      end if;
    else
      v_owner_person_id := null;
    end if;

    -- إغلاق مقطع التوقف الحالي
    update ops.session_segments
    set ended_at = p_changed_at
    where id = v_segment_id;

    -- فتح مقطع توقف جديد غير مفوتر يحمل المصدر المعلّق
    insert into ops.session_segments (
      tenant_id, session_id, sequence_number, segment_type,
      energy_source, started_at, is_billable, fuel_owner_person_id,
      notes
    ) values (
      v_tenant_id, p_session_id, v_sequence_number + 1, 'source_change_pause',
      p_new_source, p_changed_at, false, v_owner_person_id,
      'source_change_pause'
    )
    returning id into v_new_segment_id;

    return v_new_segment_id;

  else
    raise exception 'يجب استئناف الجلسة قبل تغيير مصدر الطاقة';
  end if;
end;
$function$;

-- Preserved body from 20261102000000_operational_occurrence_contract.sql; only root boundary/necessary row lock changes.
create or replace function ops.settle_operational_occurrence(p_well_id uuid,p_command_id uuid,p_request jsonb)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $f$
declare
 tenant uuid; actor uuid:=auth.uid(); original sync.processed_commands%rowtype; pc sync.processed_commands%rowtype;
 o ops.operational_occurrences%rowtype; guard jsonb; stored jsonb; result jsonb; completed jsonb;
 occurrence_id uuid; original_id uuid; sid uuid; facts jsonb:=p_request->'facts'; start_fact jsonb;
 stop_at timestamptz; source_booking uuid; existing boolean;
begin
 perform billing.enter_financial_write(p_well_id,null,null);
 if actor is null or p_well_id is null or p_command_id is null or
    not coalesce(iam.has_well_permission(p_well_id,'session.start'),false) or
    not coalesce(iam.has_well_permission(p_well_id,'session.complete'),false) then
   raise exception 'settlement_forbidden' using errcode='42501'; end if;
 select tenant_id into tenant from core.wells where id=p_well_id;
 if tenant is null then raise exception 'settlement_forbidden' using errcode='42501'; end if;
 perform ops.lock_operational_scope(p_well_id,true);
 if jsonb_typeof(p_request) is distinct from 'object' or p_request->'version' is distinct from '1'::jsonb
    or p_request->'human_confirmed' is distinct from 'true'::jsonb
    or nullif(btrim(p_request->>'reason'),'') is null then
   raise exception 'settlement_confirmation_required' using errcode='22023'; end if;
 occurrence_id:=(p_request->>'occurrence_command_id')::uuid;
 original_id:=(p_request->>'original_rejected_request_id')::uuid;
 if occurrence_id is null or original_id is null or p_command_id in (occurrence_id,original_id)
    or nullif(facts->'completion'->>'command_id','') is null
    or p_command_id=(facts->'completion'->>'command_id')::uuid then
   raise exception 'settlement_identity_invalid' using errcode='22023'; end if;
 select * into original from sync.processed_commands where tenant_id=tenant and command_id=original_id;
 if not found or original.entity_id is distinct from p_well_id
    or original.command_type<>'start_session_with_booking_delays'
    or original.status<>'rejected' or original.response_payload is null
    or original.request_payload->'request'->>'occurrence_command_id' is distinct from occurrence_id::text
    or original.response_payload is distinct from p_request->'original_rejected_result'
    or md5((original.request_payload->'request')::text) is distinct from p_request->>'original_request_fingerprint' then
   raise exception 'original_rejection_unproven' using errcode='22023'; end if;
 start_fact:=original.request_payload->'request'->'start';
 if jsonb_typeof(facts) is distinct from 'object' or facts->'start' is distinct from start_fact
    or facts->>'root_local_id' is distinct from original.request_payload->'request'->>'root_local_id'
    or (p_request->>'source_booking_id')::uuid is distinct from (start_fact->>'booking_id')::uuid then
   raise exception 'settlement_original_facts_mismatch' using errcode='22023'; end if;
 stored:=jsonb_build_object('request',p_request,'actor_id',actor);
 guard:=sync.begin_command(tenant,p_command_id,'settle_operational_occurrence',stored,p_well_id);
 if coalesce((guard->>'duplicate')::boolean,false) then
   select * into strict pc from sync.processed_commands where tenant_id=tenant and command_id=p_command_id;
   if pc.command_type<>'settle_operational_occurrence' or pc.entity_id<>p_well_id or pc.request_payload is distinct from stored then
     raise exception 'command_identity_mismatch' using errcode='22023'; end if;
   if pc.status in ('accepted','conflict','rejected') then return pc.response_payload; end if;
   raise exception 'settlement_processing' using errcode='55000';
 end if;
 begin
   select * into o from ops.operational_occurrences where tenant_id=tenant and occurrence_command_id=occurrence_id for update;
   existing:=found;
   if existing then
     if o.well_id<>p_well_id or o.original_request_id<>original_id or o.original_facts is distinct from facts
       or o.status<>'accepted' or o.provenance<>'historical_settlement' then
       raise exception 'occurrence_binding_conflict' using errcode='23514'; end if;
     sid:=o.server_session_id;
     select response_payload into completed from sync.processed_commands
       where tenant_id=tenant and command_id=o.completion_command_id and status='accepted'
         and command_type='complete_irrigation_session' and entity_id=sid;
     if completed is null then raise exception 'completion_result_unproven' using errcode='23514'; end if;
   else
     -- لا تبنٍّ لجلسة سابقة بلا رابط واقعة؛ حتى تطابق الحجز ليس إثباتًا كافيًا.
     source_booking:=(start_fact->>'booking_id')::uuid;
     if source_booking is not null and (not exists(select 1 from ops.irrigation_bookings b
         where b.id=source_booking and b.well_id=p_well_id and b.tenant_id=tenant)
       or exists(select 1 from ops.irrigation_sessions s where s.booking_id=source_booking)) then
       raise exception 'existing_session_requires_exact_occurrence_proof' using errcode='23514'; end if;
     sid:=gen_random_uuid(); stop_at:=(facts->'completion'->>'occurred_at')::timestamptz;
     insert into ops.operational_occurrences(tenant_id,occurrence_command_id,well_id,source_booking_id,
       original_request_id,original_operator_id,started_at,ended_at,original_facts,provenance,
       settlement_command_id,completion_command_id,server_session_id,status)
     values(tenant,occurrence_id,p_well_id,source_booking,original_id,
       (original.request_payload->>'actor_id')::uuid,(start_fact->>'started_at')::timestamptz,stop_at,facts,
       'historical_settlement',p_command_id,(facts->'completion'->>'command_id')::uuid,sid,'materializing');
     completed:=ops.materialize_historical_occurrence(p_well_id,occurrence_id,p_command_id,facts);
     update ops.operational_occurrences set status='accepted',resolved_at=clock_timestamp()
       where tenant_id=tenant and occurrence_command_id=occurrence_id;
   end if;
   result:=jsonb_build_object('contract','occurrence_settlement','version',1,'status','accepted',
     'settlement_request_id',p_command_id,'occurrence_command_id',occurrence_id,
     'original_rejected_request_id',original_id,'original_rejected_result',original.response_payload,
     'well_id',p_well_id,'source_booking_id',start_fact->'booking_id',
     'request_fingerprint',md5(p_request::text),'server_session_id',sid,
     'started_at',start_fact->'started_at','ended_at',completed->'ended_at',
     'original_completion_command_id',facts->'completion'->'command_id',
     'session_charge_id',completed->'session_charge_id','completion_receipt',completed,'resolved_at',clock_timestamp());
   perform sync.finish_command(tenant,p_command_id,'accepted',result);
   -- التحقق المؤجل يرى الآن دليل التسوية المقبول في المعاملة نفسها.
   set constraints ops.irrigation_sessions_adhoc_duration_guard immediate;
   set constraints ops.irrigation_sessions_adhoc_duration_guard deferred;
 exception when check_violation or exclusion_violation or unique_violation or raise_exception
   or invalid_parameter_value or invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
   if SQLSTATE='P0001' and SQLERRM !~ '^(group_|stale_operational_|لا |الحجز |الجلسة |المضخة |المزرعة |حساب |بدء |المدة |وقت |يوجد |رصيد )' then
     raise;
   end if;
   result:=jsonb_build_object('contract','occurrence_settlement','version',1,'status','review',
     'settlement_request_id',p_command_id,'occurrence_command_id',occurrence_id,'well_id',p_well_id,
     'original_rejected_request_id',original_id,'original_rejected_result',original.response_payload,
     'request_fingerprint',md5(p_request::text),'reason',SQLERRM,'resolved_at',clock_timestamp());
   perform sync.finish_command(tenant,p_command_id,'conflict',result);
 end;
 return result;
end;$f$;

-- Preserved body from 20260822013001_082_permission_enforcement_ops.sql; only root boundary/necessary row lock changes.
create or replace function inventory.purchase_fuel(
  p_well_id uuid,
  p_liters numeric,
  p_cost_minor bigint,
  p_purchased_at timestamptz default clock_timestamp(),
  p_recorded_by uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'inventory', 'finance', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_tank_id uuid;
  v_purchase_id uuid;
  v_transaction_id uuid;
  v_journal_id uuid;
  v_balance_before bigint;
  v_balance_after bigint;
  v_avg_after bigint;
  v_quantity_ml bigint;
  v_existing_transactions uuid[] := '{}'::uuid[];
begin
 perform billing.enter_financial_write(p_well_id,'fuel.purchase',null);
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل شراء الديزل';
  end if;
  if p_recorded_by is not null and p_recorded_by is distinct from v_actor then
    raise exception 'مسجل الشراء يجب أن يطابق المستخدم المسجل حاليًا';
  end if;
  if not iam.has_well_permission(p_well_id, 'fuel.purchase') then
    raise exception 'لا تملك صلاحية تسجيل شراء ديزل لهذا البئر';
  end if;
  if p_liters is null or p_liters <= 0 then
    raise exception 'كمية الديزل المشتراة يجب أن تكون أكبر من صفر';
  end if;
  if p_cost_minor is null or p_cost_minor <= 0 then
    raise exception 'مبلغ شراء الديزل يجب أن يكون أكبر من صفر';
  end if;
  if p_liters <> round(p_liters, 2) then
    raise exception 'كمية الشراء تقبل منزلتين عشريتين كحد أقصى';
  end if;

  select w.tenant_id into v_tenant_id
  from core.wells w where w.id = p_well_id;
  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  select ft.id, ft.current_balance_ml
  into v_tank_id, v_balance_before
  from inventory.fuel_tanks ft
  where ft.well_id = p_well_id and ft.status = 'active'
  order by ft.created_at, ft.id
  limit 1
  for update;
  if not found then
    raise exception 'لا يوجد خزان ديزل فعال لهذا البئر';
  end if;

  v_quantity_ml := round(p_liters * 1000);
  if v_quantity_ml <= 0 then
    raise exception 'كمية الديزل بعد التحويل يجب أن تكون ملليلترًا واحدًا على الأقل';
  end if;

  select coalesce(array_agg(ftx.id), '{}'::uuid[])
  into v_existing_transactions
  from inventory.fuel_transactions ftx
  where ftx.well_id = p_well_id;

  insert into inventory.fuel_purchases (
    well_id, liters, cost_minor, purchased_at, recorded_by_profile_id
  ) values (
    p_well_id, p_liters, p_cost_minor, p_purchased_at, v_actor
  ) returning id into v_purchase_id;

  select ftx.id into v_transaction_id
  from inventory.fuel_transactions ftx
  where ftx.well_id = p_well_id
    and ftx.transaction_type = 'purchase'
    and ftx.ownership_type = 'well'
    and ftx.quantity_ml = v_quantity_ml
    and ftx.total_cost_minor = p_cost_minor
    and ftx.occurred_at = p_purchased_at
    and not (ftx.id = any(v_existing_transactions))
  order by ftx.id
  limit 1;
  if not found then
    raise exception 'فشل التحقق من حركة المخزون الناتجة عن شراء الديزل';
  end if;

  select ft.current_balance_ml, ft.avg_cost_per_liter_minor
  into v_balance_after, v_avg_after
  from inventory.fuel_tanks ft where ft.id = v_tank_id;

  if v_balance_after <> v_balance_before + v_quantity_ml then
    raise exception 'فشل التحقق من رصيد الخزان بعد شراء الديزل';
  end if;

  select je.id into v_journal_id
  from finance.journal_entries je
  where je.source_type = 'fuel_purchase'
    and je.source_id = v_transaction_id and je.status = 'posted';
  if not found then
    raise exception 'فشل التحقق من القيد المالي المرحل لشراء الديزل';
  end if;

  perform audit.log(
    v_tenant_id, p_well_id, 'purchase_fuel',
    'inventory.fuel_purchases', v_purchase_id, null,
    jsonb_build_object(
      'purchase_id', v_purchase_id,
      'fuel_transaction_id', v_transaction_id,
      'quantity_ml', v_quantity_ml,
      'cost_minor', p_cost_minor,
      'balance_ml', v_balance_after,
      'avg_cost_per_liter_minor', v_avg_after,
      'journal_entry_id', v_journal_id
    ),
    'شراء ديزل وإضافته إلى الخزان'
  );

  return jsonb_build_object(
    'purchase_id', v_purchase_id,
    'fuel_transaction_id', v_transaction_id,
    'journal_entry_id', v_journal_id,
    'balance_ml', v_balance_after,
    'avg_cost_per_liter_minor', v_avg_after
  );
end;
$function$;

-- Preserved body from 20260822013001_082_permission_enforcement_ops.sql; only root boundary/necessary row lock changes.
create or replace function inventory.record_fuel_consumption(
  p_well_id uuid,
  p_quantity_ml bigint,
  p_ownership_type text,
  p_measurement_type text,
  p_owner_person_id uuid default null,
  p_farmer_well_account_id uuid default null,
  p_fuel_tank_id uuid default null,
  p_session_segment_id uuid default null,
  p_occurred_at timestamptz default clock_timestamp(),
  p_created_by uuid default null,
  p_estimated_transaction_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'inventory', 'finance', 'ops', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_tank_id uuid;
  v_transaction_id uuid;
  v_journal_id uuid;
  v_status text;
  v_balance_before bigint;
  v_balance_after bigint;
begin
 perform billing.enter_financial_write(p_well_id,'fuel.consume',null);
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل استهلاك الديزل';
  end if;
  if p_created_by is not null and p_created_by is distinct from v_actor then
    raise exception 'مسجل الاستهلاك يجب أن يطابق المستخدم المسجل حاليًا';
  end if;
  if not iam.has_well_permission(p_well_id, 'fuel.consume') then
    raise exception 'لا تملك صلاحية تسجيل استهلاك ديزل لهذا البئر';
  end if;
  if p_quantity_ml is null or p_quantity_ml <= 0 then
    raise exception 'كمية الديزل المستهلكة يجب أن تكون أكبر من صفر';
  end if;
  if p_ownership_type is null or p_ownership_type not in ('well', 'farmer') then
    raise exception 'ملكية الديزل غير صالحة؛ المسموح ديزل البئر أو ديزل المزارع';
  end if;
  if p_measurement_type is null or p_measurement_type not in ('actual', 'estimated') then
    raise exception 'نوع القياس غير صالح؛ المسموح فعلي أو تقديري';
  end if;

  select w.tenant_id into v_tenant_id
  from core.wells w where w.id = p_well_id;
  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  select ft.id, ft.current_balance_ml
  into v_tank_id, v_balance_before
  from inventory.fuel_tanks ft
  where ft.id = coalesce(p_fuel_tank_id, ft.id)
    and ft.well_id = p_well_id and ft.status = 'active'
  order by ft.created_at, ft.id
  limit 1
  for update;
  if not found then
    raise exception 'خزان الديزل غير موجود أو غير فعال في هذا البئر';
  end if;

  if p_ownership_type = 'farmer' then
    if p_owner_person_id is null or p_farmer_well_account_id is null then
      raise exception 'استهلاك ديزل المزارع يحتاج صاحب الوقود وحساب المزارع';
    end if;
    if not exists (
      select 1
      from ops.farmer_well_accounts fwa
      join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
      where fwa.id = p_farmer_well_account_id
        and fwa.well_id = p_well_id and fwa.status = 'active'
        and fp.person_id = p_owner_person_id and fp.status = 'active'
    ) then
      raise exception 'رصيد ديزل المزارع لا يخص حساب المزارع المحدد';
    end if;
    v_balance_before := inventory.farmer_fuel_balance_ml(p_well_id, p_owner_person_id);
  elsif p_owner_person_id is not null or p_farmer_well_account_id is not null then
    raise exception 'ديزل البئر لا يقبل صاحب وقود أو حساب مزارع';
  end if;

  if p_measurement_type = 'actual' and p_quantity_ml > v_balance_before then
    if p_ownership_type = 'farmer' then
      raise exception 'رصيد ديزل المزارع لا يكفي: المتاح % مل والمطلوب % مل',
        v_balance_before, p_quantity_ml;
    else
      raise exception 'رصيد ديزل البئر لا يكفي: المتاح % مل والمطلوب % مل',
        v_balance_before, p_quantity_ml;
    end if;
  end if;

  if p_estimated_transaction_id is not null then
    if p_measurement_type <> 'actual' then
      raise exception 'لا يمكن تسوية قياس تقديري إلا بقياس فعلي';
    end if;
    update inventory.fuel_transactions ftx
    set status = 'reversed',
        notes = coalesce(ftx.notes || ' | ', '') || 'استُبدل بقياس فعلي'
    where ftx.id = p_estimated_transaction_id
      and ftx.well_id = p_well_id
      and ftx.status = 'pending_actual_measurement'
      and ftx.ownership_type = p_ownership_type
      and ftx.owner_person_id is not distinct from p_owner_person_id;
    if not found then
      raise exception 'حركة القياس التقديري غير موجودة أو لا تطابق الاستهلاك الفعلي';
    end if;
  end if;

  insert into inventory.fuel_transactions (
    tenant_id, well_id, fuel_tank_id, transaction_type,
    ownership_type, owner_person_id, farmer_well_account_id,
    quantity_ml, direction, measurement_type, session_segment_id,
    occurred_at, status, created_by, notes
  ) values (
    v_tenant_id, p_well_id, v_tank_id, 'session_consumption',
    p_ownership_type, p_owner_person_id, p_farmer_well_account_id,
    p_quantity_ml, 'out', p_measurement_type, p_session_segment_id,
    p_occurred_at, 'posted', v_actor,
    case when p_measurement_type = 'estimated'
      then 'استهلاك تقديري بانتظار القياس الفعلي'
      else 'استهلاك فعلي مسجل عبر الإجراء' end
  ) returning id, status into v_transaction_id, v_status;

  if p_ownership_type = 'farmer' then
    v_balance_after := inventory.farmer_fuel_balance_ml(p_well_id, p_owner_person_id);
  else
    select ft.current_balance_ml into v_balance_after
    from inventory.fuel_tanks ft where ft.id = v_tank_id;
  end if;

  if p_measurement_type = 'estimated' and (
    v_status <> 'pending_actual_measurement' or v_balance_after <> v_balance_before
  ) then
    raise exception 'فشل التحقق: القياس التقديري يجب أن يبقى معلقًا دون خصم';
  end if;
  if p_measurement_type = 'actual' and v_balance_after <> v_balance_before - p_quantity_ml then
    raise exception 'فشل التحقق من خصم استهلاك الديزل الفعلي';
  end if;

  select je.id into v_journal_id
  from finance.journal_entries je
  where je.source_type = 'fuel_consumption'
    and je.source_id = v_transaction_id and je.status = 'posted';

  if p_measurement_type = 'actual' and p_ownership_type = 'well'
     and v_journal_id is null then
    raise exception 'فشل التحقق من القيد المالي لاستهلاك ديزل البئر';
  end if;

  perform audit.log(
    v_tenant_id, p_well_id, 'record_fuel_consumption',
    'inventory.fuel_transactions', v_transaction_id, null,
    jsonb_build_object(
      'fuel_transaction_id', v_transaction_id,
      'ownership_type', p_ownership_type,
      'measurement_type', p_measurement_type,
      'status', v_status,
      'quantity_ml', p_quantity_ml,
      'balance_ml', v_balance_after,
      'journal_entry_id', v_journal_id,
      'replaced_estimate_id', p_estimated_transaction_id
    ),
    'تسجيل استهلاك ديزل'
  );

  return jsonb_build_object(
    'fuel_transaction_id', v_transaction_id,
    'status', v_status,
    'measurement_type', p_measurement_type,
    'balance_ml', v_balance_after,
    'journal_entry_id', v_journal_id,
    'replaced_estimate_id', p_estimated_transaction_id
  );
end;
$function$;

-- Preserved body from 20260822013001_082_permission_enforcement_ops.sql; only root boundary/necessary row lock changes.
create or replace function inventory.record_physical_fuel_count(
  p_well_id uuid,
  p_fuel_tank_id uuid,
  p_measured_balance_ml bigint,
  p_counted_at timestamptz default clock_timestamp(),
  p_counted_by uuid default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'inventory', 'finance', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_book_balance bigint;
  v_avg_cost bigint;
  v_difference bigint;
  v_transaction_id uuid;
  v_journal_id uuid;
  v_total_cost bigint;
  v_direction text;
  v_balance_after bigint;
begin
 perform billing.enter_financial_write(p_well_id,'fuel.count',null);
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل الجرد الفعلي';
  end if;
  if p_counted_by is not null and p_counted_by is distinct from v_actor then
    raise exception 'منفذ الجرد يجب أن يطابق المستخدم المسجل حاليًا';
  end if;
  if not iam.has_well_permission(p_well_id, 'fuel.count') then
    raise exception 'لا تملك صلاحية تسجيل جرد ديزل لهذا البئر';
  end if;
  if p_measured_balance_ml is null or p_measured_balance_ml < 0 then
    raise exception 'الرصيد المقاس في الجرد لا يجوز أن يكون سالبًا';
  end if;

  select ft.tenant_id, ft.current_balance_ml, ft.avg_cost_per_liter_minor
  into v_tenant_id, v_book_balance, v_avg_cost
  from inventory.fuel_tanks ft
  where ft.id = p_fuel_tank_id
    and ft.well_id = p_well_id and ft.status = 'active'
  for update;
  if not found then
    raise exception 'خزان الديزل غير موجود أو غير فعال في هذا البئر';
  end if;

  v_difference := p_measured_balance_ml - v_book_balance;
  if v_difference = 0 then
    perform audit.log(
      v_tenant_id, p_well_id, 'record_physical_fuel_count',
      'inventory.fuel_tanks', p_fuel_tank_id,
      jsonb_build_object('book_balance_ml', v_book_balance),
      jsonb_build_object('measured_balance_ml', p_measured_balance_ml, 'difference_ml', 0),
      coalesce(p_notes, 'جرد فعلي مطابق للرصيد')
    );
    return jsonb_build_object(
      'fuel_transaction_id', null,
      'journal_entry_id', null,
      'book_balance_ml', v_book_balance,
      'measured_balance_ml', p_measured_balance_ml,
      'difference_ml', 0,
      'balance_ml', v_book_balance
    );
  end if;

  v_direction := case when v_difference > 0 then 'in' else 'out' end;
  v_total_cost := round((abs(v_difference)::numeric / 1000) * v_avg_cost);

  insert into inventory.fuel_transactions (
    tenant_id, well_id, fuel_tank_id, transaction_type,
    ownership_type, quantity_ml, direction, measurement_type,
    unit_cost_per_liter_minor, total_cost_minor,
    occurred_at, status, created_by, notes
  ) values (
    v_tenant_id, p_well_id, p_fuel_tank_id, 'physical_count',
    'well', abs(v_difference), v_direction, 'actual',
    v_avg_cost, v_total_cost, p_counted_at, 'posted', v_actor,
    coalesce(p_notes, 'فرق جرد فعلي للديزل')
  ) returning id into v_transaction_id;

  select ft.current_balance_ml into v_balance_after
  from inventory.fuel_tanks ft where ft.id = p_fuel_tank_id;
  if v_balance_after <> p_measured_balance_ml then
    raise exception 'فشل التحقق من مطابقة رصيد الخزان للقياس الفعلي';
  end if;

  select je.id into v_journal_id
  from finance.journal_entries je
  where je.source_type = 'fuel_physical_count'
    and je.source_id = v_transaction_id and je.status = 'posted';
  if v_total_cost > 0 and v_journal_id is null then
    raise exception 'فشل التحقق من قيد فرق الجرد الفعلي';
  end if;

  perform audit.log(
    v_tenant_id, p_well_id, 'record_physical_fuel_count',
    'inventory.fuel_transactions', v_transaction_id,
    jsonb_build_object('book_balance_ml', v_book_balance),
    jsonb_build_object(
      'measured_balance_ml', p_measured_balance_ml,
      'difference_ml', v_difference,
      'balance_ml', v_balance_after,
      'journal_entry_id', v_journal_id
    ),
    coalesce(p_notes, 'تسجيل فرق الجرد الفعلي')
  );

  return jsonb_build_object(
    'fuel_transaction_id', v_transaction_id,
    'journal_entry_id', v_journal_id,
    'book_balance_ml', v_book_balance,
    'measured_balance_ml', p_measured_balance_ml,
    'difference_ml', v_difference,
    'balance_ml', v_balance_after,
    'avg_cost_per_liter_minor', v_avg_cost
  );
end;
$function$;

-- Preserved body from 20261108001700_expense_approval_configuration_boundary.sql; only root boundary/necessary row lock changes.
create or replace function finance.record_expense(
  p_well_id uuid,
  p_category_code text,
  p_amount_minor bigint,
  p_description text,
  p_created_by uuid default null,
  p_attachment_url text default null,
  p_attachment_skipped boolean default false,
  p_payment_source text default 'cashbox',
  p_note text default null,
  p_partner_id uuid default null,
  p_attachment_skip_reason text default null
)
returns uuid
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
  v_attachment_url text;
  v_skip_reason text;
  v_skipped boolean;
begin
 perform billing.enter_financial_write(p_well_id,'expense.create',null);
  perform billing.lock_customer_credit_well(p_well_id);
  select tenant_id into v_tenant from core.wells where id = p_well_id;
  if v_tenant is null then
    raise exception 'البئر % غير موجود', p_well_id;
  end if;

  select id into v_cat from finance.expense_categories
  where tenant_id = v_tenant and code = p_category_code and is_active
   and(well_id is null or well_id=p_well_id);
  if v_cat is null then
    raise exception 'نوع المصروف % غير معروف', p_category_code;
  end if;

  -- ═══ تحقّق الإثبات: مرفق صريح أو تخطٍ صريح بسببه — حصريًا ═══
  --    التطبيع: الفراغ والبياض يصيران NULL، ولا يُقبل سبب في
  --    حقل الملاحظات بديلًا (الطي القديم في Flutter ينتهي هنا).
  v_attachment_url := nullif(btrim(coalesce(p_attachment_url, '')), '');
  v_skip_reason := nullif(btrim(coalesce(p_attachment_skip_reason, '')), '');
  v_skipped := coalesce(p_attachment_skipped, false);

  if v_attachment_url is not null and v_skipped then
    raise exception 'لا يجوز إرفاق السند مع تخطي المرفق في الوقت نفسه';
  end if;
  if v_attachment_url is not null and v_skip_reason is not null then
    raise exception 'لا يجوز إرفاق السند مع تدوين سبب تخطٍ';
  end if;
  if v_skip_reason is not null and not v_skipped then
    raise exception 'سبب التخطي بلا تخطٍ صريح — علّم التخطي أو احذف السبب';
  end if;
  if v_skipped and v_skip_reason is null then
    raise exception 'سبب التخطي إلزامي عند تخطي المرفق ولا يقبل فراغًا';
  end if;
  if v_attachment_url is null and not v_skipped then
    raise exception 'إرفاق صورة السند/الفاتورة أو التخطي الصريح بسببه إلزامي';
  end if;

  if p_payment_source = 'partner_paid' and p_partner_id is null then
    raise exception 'مصروف دفعه شريك من جيبه يلزم تحديد الشريك';
  end if;

  v_requires:=(finance.expense_approval_context(p_well_id,v_cat,p_amount_minor)->>'requires_approval')::boolean;

  v_status := case when v_requires then 'pending_approval' else 'posted' end;

  insert into finance.expenses (
    tenant_id, well_id, category_id, amount_minor, description, payment_source,
    created_by, attachment_url, attachment_skipped, attachment_skip_reason,
    status, note, partner_id
  ) values (
    v_tenant, p_well_id, v_cat, p_amount_minor, p_description, p_payment_source,
    p_created_by, v_attachment_url, v_skipped, v_skip_reason,
    v_status, p_note, p_partner_id
  ) returning id into v_id;

  return v_id;
end;
$$;

-- Preserved body from 20261108001300_worker_compensation_rule_boundary.sql; only root boundary/necessary row lock changes.
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
  requested daterange;
begin
 perform billing.enter_financial_write(p_well_id,'payroll.accrue',null);
  perform billing.lock_customer_credit_well(p_well_id);
  if p_period_start is null or p_period_end is null or p_period_end<p_period_start then
   raise exception 'payroll_period_invalid' using errcode='22023';end if;
  requested:=daterange(p_period_start,p_period_end,'[]');
  if exists(select 1 from finance.worker_compensation_rules r where r.well_id=p_well_id and r.person_id=p_person_id
   and r.effective_period && requested and not(r.effective_period @> requested)) then
   raise exception 'payroll_period_crosses_compensation_boundary_split_required' using errcode='23514';end if;
  select tenant_id into v_tenant from core.wells where id = p_well_id;
  if p_period_end < p_period_start then raise exception 'نهاية فترة الاستحقاق قبل بدايتها'; end if;
  if exists (select 1 from finance.payroll_accruals a
             where a.well_id = p_well_id and a.person_id = p_person_id
               and a.period_start = p_period_start and a.period_end = p_period_end
               and a.status <> 'cancelled') then
    raise exception 'يوجد مستحق راتب لهذا العامل عن هذه الفترة مسبقًا';
  end if;

  if not exists(select 1 from finance.worker_compensation_rules r where r.well_id=p_well_id
   and r.person_id=p_person_id and r.effective_period @> requested) then
   raise exception 'payroll_single_compensation_rule_required' using errcode='23514';end if;
  if p_gross_minor is not null then
    v_gross := p_gross_minor;
  else
    select * into v_rule from finance.worker_compensation_rules r
    where r.well_id = p_well_id and r.person_id = p_person_id and r.effective_period @> requested
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

-- Preserved body from 20261108001900_partner_distribution_source_settlement.sql; only root boundary/necessary row lock changes.
create or replace function finance.calculate_profit_distribution(
  p_well_id uuid, p_period_start timestamptz, p_period_end timestamptz,
  p_calculated_by uuid default null, p_manual_reserve_minor bigint default 0
) returns uuid language plpgsql security definer
set search_path to 'finance', 'billing', 'inventory', 'core', 'ops', 'pg_temp' as $$
declare
  v_tenant uuid;
  v_cycle uuid;
  v_collected bigint;
  v_expenses bigint;
  v_liabilities bigint := 0;
  v_reserve bigint := 0;
  v_distributable bigint;
  v_total_pct numeric;
  v_withhold boolean;
  v_rule record;
  v_rule_found boolean;
  v_share record;
  v_gross bigint;
  v_remaining bigint;
  v_max_pct numeric := -1;
  v_max_partner uuid;
  v_receivables bigint;
  v_irrigation bigint;
  cfg jsonb;cfg_id uuid;cfg_stamp timestamptz;
begin
 perform billing.enter_financial_write(p_well_id,'distribution.calculate',null);
  perform billing.lock_customer_credit_well(p_well_id);
  cfg:=finance.current_distribution_configuration(p_well_id);
  cfg_id:=(cfg->>'id')::uuid;
  if cfg_id is null then
   -- Historical settings are observed now, not falsely attributed to an old actor.
   cfg_stamp:=clock_timestamp();
   insert into finance.distribution_configuration_versions(tenant_id,well_id,sequence,withhold_liabilities,
    legacy_rules,accepted_at,source)
   values((select tenant_id from core.wells where id=p_well_id),p_well_id,1,
    (cfg->>'withhold_liabilities')::boolean,cfg->'legacy_rules',cfg_stamp,'legacy_snapshot') returning id into cfg_id;
   cfg:=finance.current_distribution_configuration(p_well_id);
  end if;
  if p_period_end <= p_period_start then
    raise exception 'نهاية الفترة يجب ان تكون بعد بدايتها';
  end if;
  select tenant_id into v_tenant from core.wells where id = p_well_id;

  if exists (select 1 from finance.profit_distribution_cycles c
             where c.well_id = p_well_id and c.status not in ('paid', 'cancelled')
               and tstzrange(c.period_start, c.period_end) && tstzrange(p_period_start, p_period_end)) then
    raise exception 'توجد دورة توزيع متداخلة غير مغلقة لهذا البئر';
  end if;

  select coalesce(sum(p.amount_minor), 0) into v_collected
  from billing.payments p
  where p.well_id = p_well_id and p.status = 'posted' and p.purpose <> 'advance'
    and p.paid_at >= p_period_start and p.paid_at < p_period_end;

  select coalesce((
    select sum(x.amt) from (
      select fp.cost_minor as amt from inventory.fuel_purchases fp
      where fp.well_id = p_well_id and fp.purchased_at >= p_period_start and fp.purchased_at < p_period_end
      union all
      select e.amount_minor from finance.expenses e
      where e.well_id = p_well_id and e.status = 'posted'
        and e.spent_at >= p_period_start and e.spent_at < p_period_end
    ) x
  ), 0) into v_expenses;

  v_withhold:=(cfg->>'withhold_liabilities')::boolean;
  if coalesce(v_withhold, true) then
    v_liabilities := finance.compute_reserved_liabilities(p_well_id);
  end if;

  -- الاحتياطي: found وليس "سجل is not null" (الاخير خطان مع الحقول الفارغة)
  if cfg->>'reserve_type' is null then
   select r.* into v_rule from jsonb_populate_recordset(null::finance.maintenance_reserve_rules,cfg->'legacy_rules') r
   where r.effective_period @> p_period_end::date order by r.created_at desc,r.id limit 1;
   v_rule_found:=found;
  else
   select cfg->>'reserve_type' as reserve_type,(cfg->>'reserve_percentage')::numeric as reserve_percentage,
    (cfg->>'fixed_amount_minor')::bigint as fixed_amount_minor into v_rule;
   v_rule_found:=true;
  end if;
  if v_rule_found then
    if v_rule.reserve_type = 'percentage_of_collections' then
      v_reserve := round(v_collected * v_rule.reserve_percentage / 100);
    elsif v_rule.reserve_type = 'percentage_of_profit' then
      v_reserve := round(greatest(v_collected - v_expenses, 0) * v_rule.reserve_percentage / 100);
    elsif v_rule.reserve_type = 'fixed_amount' then
      v_reserve := coalesce(v_rule.fixed_amount_minor, 0);
    elsif v_rule.reserve_type = 'manual_per_cycle' then
      v_reserve := coalesce(p_manual_reserve_minor, 0);
    end if;
  end if;

  v_distributable := greatest(v_collected - v_expenses - v_liabilities - v_reserve, 0);

  select coalesce(sum(v.profit_percentage), 0) into v_total_pct
  from core.ownership_share_versions v
  where v.well_id = p_well_id and v.effective_period @> p_period_end::date;
  if v_total_pct <> 100 then
    raise exception 'مجموع نسب الارباح الفعالة عند نهاية الفترة يساوي % وليس 100 — لا يمكن الاحتساب', v_total_pct;
  end if;

  insert into finance.profit_distribution_cycles (
    tenant_id, well_id, period_start, period_end, status,
    eligible_collections_minor, eligible_cash_expenses_minor,
    reserved_liabilities_minor, maintenance_reserve_minor, distributable_amount_minor,
    calculated_at, calculated_by
  ) values (
    v_tenant, p_well_id, p_period_start, p_period_end, 'calculated',
    v_collected, v_expenses, v_liabilities, v_reserve, v_distributable,
    now(), p_calculated_by
  ) returning id into v_cycle;

  v_remaining := v_distributable;
  for v_share in
    select v.partner_id, v.profit_percentage
    from core.ownership_share_versions v
    where v.well_id = p_well_id and v.effective_period @> p_period_end::date
    order by v.profit_percentage desc, v.partner_id
  loop
    v_gross := floor(v_distributable * v_share.profit_percentage / 100);
    v_remaining := v_remaining - v_gross;

    v_receivables:=0;v_irrigation:=0;

    insert into finance.profit_distribution_lines (
      tenant_id, distribution_cycle_id, partner_id, profit_percentage_snapshot,
      gross_share_minor, partner_receivables_minor, irrigation_deductions_minor,
      other_deductions_minor, net_payable_minor
    ) values (
      v_tenant, v_cycle, v_share.partner_id, v_share.profit_percentage,
      v_gross, v_receivables, v_irrigation, 0,
      v_gross + v_receivables - v_irrigation
    );

    if v_max_pct = -1 then
      v_max_pct := v_share.profit_percentage;
      v_max_partner := v_share.partner_id;
    end if;
  end loop;

  if v_remaining <> 0 and v_max_partner is not null then
    update finance.profit_distribution_lines
    set gross_share_minor = gross_share_minor + v_remaining,
        net_payable_minor = net_payable_minor + v_remaining
    where distribution_cycle_id = v_cycle and partner_id = v_max_partner;
  end if;

  perform finance.prepare_distribution_source_selections(v_cycle);
  insert into finance.distribution_source_calculation_basis(cycle_id) values(v_cycle);
  insert into finance.distribution_calculation_history(tenant_id,well_id,cycle_id,configuration_id,
   configuration_snapshot,cycle_snapshot,lines_snapshot,manual_reserve_minor)
  select v_tenant,p_well_id,v_cycle,cfg_id,cfg,to_jsonb(c),coalesce((select jsonb_agg(to_jsonb(l) order by l.id)
   from finance.profit_distribution_lines l where l.distribution_cycle_id=v_cycle),'[]'::jsonb),coalesce(p_manual_reserve_minor,0)
  from finance.profit_distribution_cycles c where c.id=v_cycle;
  return v_cycle;
end;
$$;

-- Preserved body from 20261108001900_partner_distribution_source_settlement.sql; only root boundary/necessary row lock changes.
create or replace function finance.approve_profit_distribution(p_cycle_id uuid, p_approved_by uuid)
returns void language plpgsql security definer
set search_path to 'finance', 'core', 'ops', 'billing', 'pg_temp' as $$
declare
  v_cycle record;
  v_line record;
  v_je uuid;
  v_acc3200 uuid; v_acc2500 uuid; v_acc2100 uuid; v_acc2400 uuid; v_acc1100 uuid;
begin
 perform billing.enter_financial_write((select well_id from finance.profit_distribution_cycles where id=p_cycle_id),'distribution.approve',null, (select tenant_id from finance.profit_distribution_cycles where id=p_cycle_id));
  perform billing.lock_customer_credit_well((select well_id from finance.profit_distribution_cycles where id=p_cycle_id));
  select * into v_cycle from finance.profit_distribution_cycles where id = p_cycle_id for update;
  if v_cycle is null then raise exception 'الدورة غير موجودة: %', p_cycle_id; end if;
  if v_cycle.status not in ('calculated', 'under_review') then
    raise exception 'لا يمكن اعتماد دورة حالتها % — يجب ان تكون محسوبة او قيد المراجعة', v_cycle.status;
  end if;
  if exists(select 1 from billing.legacy_invoice_review_effects held join billing.invoices i on i.id=held.invoice_id
   where i.well_id=v_cycle.well_id and held.disputed_minor>0 and i.invoice_date<v_cycle.period_end) then
   raise exception 'legacy_invoice_amount_requires_review' using errcode='23514',detail=
    '{"status":"review_required","title":"يحتاج هذا المبلغ إلى مراجعة","message":"راجع المبلغ المرتبط بتوزيع سابق قبل اعتماد التوزيع الجديد.","action":"مراجعة المبلغ"}';end if;
  if exists (select 1 from finance.profit_distribution_lines l
             where l.distribution_cycle_id = p_cycle_id and l.net_payable_minor < 0) then
    raise exception 'لا يمكن الاعتماد: يوجد شريك صافي مستحقه سالب — راجع الاستقطاعات';
  end if;

  perform finance.consume_distribution_sources(p_cycle_id,auth.uid());

  v_acc3200 := finance.ledger_account_id(v_cycle.well_id, '3200');
  v_acc2100 := finance.ledger_account_id(v_cycle.well_id, '2100');
  v_acc2400 := finance.ledger_account_id(v_cycle.well_id, '2400');
  v_acc1100 := finance.ledger_account_id(v_cycle.well_id, '1100');

  if v_cycle.maintenance_reserve_minor > 0 then
    v_acc2500 := finance.ledger_account_id(v_cycle.well_id, '2500');
    insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
    values (v_cycle.tenant_id, core.generate_public_code('JE'), v_cycle.well_id, now(),
            'maintenance_reserve', p_cycle_id, 'تكوين احتياطي الصيانة لدورة التوزيع ' || v_cycle.public_code,
            'MRS-' || p_cycle_id::text)
    returning id into v_je;
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, description) values
      (v_cycle.tenant_id, v_je, v_acc3200, 'debit',  v_cycle.maintenance_reserve_minor, 'من الارباح القابلة للتوزيع'),
      (v_cycle.tenant_id, v_je, v_acc2500, 'credit', v_cycle.maintenance_reserve_minor, 'الى احتياطي الصيانة');
    perform finance.post_journal_entry(v_je, p_approved_by);
  end if;

  for v_line in
    select * from finance.profit_distribution_lines where distribution_cycle_id = p_cycle_id order by id for update
  loop
    if v_line.gross_share_minor = 0 and v_line.partner_receivables_minor = 0 then
      continue;
    end if;
    insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
    values (v_cycle.tenant_id, core.generate_public_code('JE'), v_cycle.well_id, now(),
            'profit_distribution', v_line.id, 'مستحقات شريك من دورة التوزيع ' || v_cycle.public_code,
            'PDC-' || v_line.id::text)
    returning id into v_je;
    if v_line.gross_share_minor>0 then
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
    values (v_cycle.tenant_id, v_je, v_acc3200, 'debit', v_line.gross_share_minor, v_line.partner_id, 'حصة الشريك الاجمالية');
    end if;
    if v_line.partner_receivables_minor > 0 then
      insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
      values (v_cycle.tenant_id, v_je, v_acc2400, 'debit', v_line.partner_receivables_minor, v_line.partner_id, 'تسوية مبالغ كانت مستحقة للشريك');
    end if;
    if v_line.net_payable_minor>0 then
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
    values (v_cycle.tenant_id, v_je, v_acc2100, 'credit', v_line.net_payable_minor, v_line.partner_id, 'صافي مستحق الشريك');
    end if;
    if v_line.irrigation_deductions_minor > 0 then
      insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
      values (v_cycle.tenant_id, v_je, v_acc1100, 'credit', v_line.irrigation_deductions_minor, v_line.partner_id, 'خصم قيمة سقيه من ديون المزارعين');
    end if;
    perform finance.post_journal_entry(v_je, p_approved_by);
  end loop;

  -- Exact source consumptions replace all-or-nothing legacy markers.
  update finance.profit_distribution_lines set status = 'approved' where distribution_cycle_id = p_cycle_id;
  update finance.profit_distribution_cycles
  set status = 'approved', approved_at = now(), approved_by = p_approved_by
  where id = p_cycle_id;

  insert into ops.notifications (recipient_profile_id, well_id, type, message)
  select wp.profile_id, v_cycle.well_id, 'distribution_approved',
    format('اعتمدت دورة توزيع %s: صافي مستحقك %s ريال', v_cycle.public_code, l.net_payable_minor)
  from finance.profit_distribution_lines l
  join core.well_partners wp on wp.id = l.partner_id
  where l.distribution_cycle_id = p_cycle_id and wp.profile_id is not null;
end;
$$;

-- Preserved body from 20261108001000_session_correction_financial_reconciliation.sql; only root boundary/necessary row lock changes.
create or replace function billing.issue_session_invoice(
  p_session_id uuid,
  p_issued_by uuid
)
returns uuid
language plpgsql
security definer
set search_path=pg_catalog,pg_temp
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_well_id uuid;
  v_farmer_well_account_id uuid;
  v_session_status text;
  v_ended_at timestamptz;
  v_charge_amount bigint;
  v_invoice_id uuid;
  v_partner_policy_id uuid;
  v_partner_policy_type text;
  v_settlement_method text := 'normal';
  v_line_number integer := 0;
  v_lines_total bigint;
  v_segment record;
  v_time_rate bigint;
  v_fuel_quantity bigint;
begin
 perform billing.enter_financial_write((select well_id from ops.irrigation_sessions where id=p_session_id),'invoice.issue',null);
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إصدار فاتورة الجلسة';
  end if;
  if p_issued_by is distinct from v_actor then
    raise exception 'مصدر الفاتورة يجب أن يطابق المستخدم المسجل حاليًا';
  end if;

  select well_id into v_well_id from ops.irrigation_sessions where id=p_session_id;
  if not coalesce(iam.has_well_permission(v_well_id,'invoice.issue'),false) then
   raise exception 'لا تملك صلاحية إصدار فاتورة هذه الجلسة';end if;
  perform billing.lock_customer_credit_well(v_well_id);
  perform ops.lock_operational_scope(v_well_id,true);
  select w.tenant_id, s.well_id, s.farmer_well_account_id,
         s.status, s.ended_at
  into v_tenant_id, v_well_id, v_farmer_well_account_id,
       v_session_status, v_ended_at
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
  for update of s;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;
  if v_session_status <> 'closed' then
    raise exception 'لا يمكن إصدار فاتورة قبل إكمال الجلسة';
  end if;
  if not iam.has_well_permission(v_well_id, 'invoice.issue') then
    raise exception 'لا تملك صلاحية إصدار فاتورة هذه الجلسة';
  end if;
  if v_farmer_well_account_id is null then
    raise exception 'لا يمكن إصدار الفاتورة لأن الجلسة غير مرتبطة بحساب مزارع';
  end if;
  if exists (
    select 1 from billing.invoices i
    where i.session_id = p_session_id
      and i.status not in ('cancelled', 'reversed')
  ) then
    raise exception 'توجد فاتورة سارية مسبقًا لهذه الجلسة';
  end if;
  if not exists (
    select 1 from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.ended_at is not null
  ) then
    raise exception 'لا توجد مقاطع مكتملة يمكن بناء بنود الفاتورة منها';
  end if;

  select sc.amount_minor,sc.effective_ended_at
  into v_charge_amount,v_ended_at
  from billing.effective_session_charges sc
  where sc.session_id = p_session_id
    and sc.pricing_mode = 'segments';

  if not found then
    raise exception 'لا يوجد ملخص تكلفة مقاطع مكتمل لهذه الجلسة';
  end if;

  select pip.id, pip.policy_type
  into v_partner_policy_id, v_partner_policy_type
  from ops.farmer_well_accounts fwa
  join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  join core.well_partners wp
    on wp.well_id = fwa.well_id and wp.person_id = fp.person_id
  join core.partner_irrigation_policies pip
    on pip.partner_id = wp.id and pip.well_id = fwa.well_id
  where fwa.id = v_farmer_well_account_id
    and pip.period_start <= v_ended_at::date
    and (pip.period_end is null or pip.period_end > v_ended_at::date)
  order by pip.period_start desc, pip.created_at desc, pip.id desc
  limit 1;

  if found and v_partner_policy_type = 'deduct_from_profit' then
    v_settlement_method := 'partner_profit_offset';
  end if;

  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    session_id, invoice_date, status, subtotal_minor, total_minor,
    paid_minor, outstanding_minor, settlement_method, partner_policy_id
  ) values (
    v_tenant_id, core.generate_public_code('INV'), v_well_id,
    v_farmer_well_account_id, p_session_id, v_ended_at, 'draft',
    v_charge_amount, v_charge_amount, 0, v_charge_amount,
    v_settlement_method, v_partner_policy_id
  )
  returning id into v_invoice_id;

  for v_segment in
    select ss.id, ss.sequence_number, ss.segment_type, ss.energy_source,
           ss.billable_seconds, ss.applied_hourly_rate_minor,
           ss.applied_operation_rate_minor,
           ss.applied_fuel_price_per_liter_minor,
           ss.fuel_actual_ml, ss.fuel_estimated_ml,
           ss.time_charge_minor, ss.fuel_charge_minor,
           ss.total_charge_minor
    from billing.financial_session_segments ss
    where ss.session_id = p_session_id
      and ss.is_billable
      and ss.total_charge_minor > 0
    order by ss.sequence_number
  loop
    if v_segment.time_charge_minor > 0 then
      v_line_number := v_line_number + 1;
      v_time_rate := coalesce(v_segment.applied_operation_rate_minor,
                              v_segment.applied_hourly_rate_minor);

      insert into billing.invoice_lines (
        tenant_id, invoice_id, line_number, line_type, description,
        quantity, unit, unit_price_minor, amount_minor,
        session_segment_id
      ) values (
        v_tenant_id, v_invoice_id, v_line_number,
        case when v_segment.energy_source = 'solar'
          then 'solar_irrigation' else 'diesel_operation' end,
        case when v_segment.energy_source = 'solar'
          then 'سقي شمسي — المقطع ' || v_segment.sequence_number
          else 'تشغيل ديزل — المقطع ' || v_segment.sequence_number end,
        v_segment.billable_seconds::numeric / 3600,
        'hour', v_time_rate, v_segment.time_charge_minor,
        v_segment.id
      );
    end if;

    if v_segment.fuel_charge_minor > 0 then
      v_line_number := v_line_number + 1;
      v_fuel_quantity := coalesce(v_segment.fuel_actual_ml,
                                  v_segment.fuel_estimated_ml);

      insert into billing.invoice_lines (
        tenant_id, invoice_id, line_number, line_type, description,
        quantity, unit, unit_price_minor, amount_minor,
        session_segment_id
      ) values (
        v_tenant_id, v_invoice_id, v_line_number, 'diesel_fuel',
        'وقود ديزل — المقطع ' || v_segment.sequence_number,
        v_fuel_quantity::numeric / 1000,
        'liter', v_segment.applied_fuel_price_per_liter_minor,
        v_segment.fuel_charge_minor, v_segment.id
      );
    end if;
  end loop;

  if v_line_number = 0 then
    raise exception 'لم تنتج مقاطع الجلسة أي بند قابل للفوترة';
  end if;

  select coalesce(sum(il.amount_minor), 0)
  into v_lines_total
  from billing.invoice_lines il
  where il.invoice_id = v_invoice_id;

  if v_lines_total <> v_charge_amount then
    raise exception 'مجموع بنود الفاتورة % لا يساوي تكلفة الجلسة %',
      v_lines_total, v_charge_amount;
  end if;

  update billing.invoices
  set status = 'issued',
      issued_at = clock_timestamp(),
      issued_by = p_issued_by
  where id = v_invoice_id;

  perform billing.refresh_partition_invoices(v_well_id);
  return v_invoice_id;
end;
$function$;

-- Preserved body from 20261108001500_legacy_invoice_accounting_resolution.sql; only root boundary/necessary row lock changes.
create or replace function billing.record_payment(
  p_well_id uuid,
  p_farmer_well_account_id uuid,
  p_amount_minor bigint,
  p_method text,
  p_allocations jsonb default '[]'::jsonb,
  p_session_charge_id uuid default null,
  p_payer_person_id uuid default null,
  p_cashbox_id uuid default null,
  p_paid_at timestamptz default clock_timestamp(),
  p_note text default null,
  p_attachment_url text default null
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,pg_temp
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_cashbox_id uuid;
  v_payment_id uuid;
  v_advance_payment_id uuid;
  v_payment_amount bigint;
  v_payment_purpose text;
  v_journal_id uuid;
  v_advance_journal_id uuid;
  v_requested_total bigint := 0;
  v_settled_minor bigint := 0;
  v_advance_minor bigint := 0;
  v_item jsonb;
  v_invoice_id uuid;
  v_item_amount bigint;
  v_charge_remaining bigint;
  v_existing_advance_ids uuid[] := '{}'::uuid[];
  v_allocation_summary jsonb := jsonb_build_object(
    'allocated_minor', 0, 'remaining_available_minor', 0, 'allocations', '[]'::jsonb
  );
begin
 perform billing.enter_financial_write(p_well_id,'payment.create',null);
  -- 1) صلاحية المستخدم والدور.
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل الدفعة';
  end if;
  if not iam.has_well_permission(p_well_id, 'payment.create') then
    raise exception 'لا تملك صلاحية تسجيل دفعة لهذا البئر';
  end if;

  perform billing.lock_customer_credit_well(p_well_id);
  perform billing.require_no_disputed_invoice(i.id,p_amount_minor) from billing.invoices i
   where (p_session_charge_id is not null and i.session_id=(select session_id from billing.session_charges where id=p_session_charge_id))
;
  perform billing.require_no_disputed_invoice((x->>'invoice_id')::uuid,(x->>'amount_minor')::bigint) from jsonb_array_elements(p_allocations) x;


  -- 2) البئر وحساب المزارع.
  select w.tenant_id into v_tenant_id
  from core.wells w
  where w.id = p_well_id;
  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;
  if p_farmer_well_account_id is null then
    raise exception 'حساب المزارع غير موجود أو غير فعال في هذا البئر';
  end if;
  perform 1 from ops.farmer_well_accounts fwa
    where fwa.id = p_farmer_well_account_id
      and fwa.well_id = p_well_id
      and fwa.status = 'active'
  for update;
  if not found then
    raise exception 'حساب المزارع غير موجود أو غير فعال في هذا البئر';
  end if;
  if p_payer_person_id is not null and not exists (
    select 1 from core.persons p
    where p.id = p_payer_person_id and p.tenant_id = v_tenant_id
  ) then
    raise exception 'الشخص الدافع غير موجود في الجهة التابعة لهذا البئر';
  end if;

  -- 3) المبلغ موجب.
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'مبلغ الدفعة يجب أن يكون أكبر من صفر';
  end if;
  if p_method is null or p_method not in ('cash', 'bank_transfer', 'mobile_wallet', 'fuel_in_kind', 'offset_credit', 'other') then
    raise exception 'طريقة الدفع غير صالحة';
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array' then
    raise exception 'قائمة تخصيص الفواتير يجب أن تكون مصفوفة';
  end if;

  for v_item in select value from jsonb_array_elements(p_allocations)
  loop
    begin
      v_invoice_id := (v_item ->> 'invoice_id')::uuid;
      v_item_amount := (v_item ->> 'amount_minor')::bigint;
    exception when others then
      raise exception 'صيغة تخصيص الفاتورة غير صالحة — يلزم invoice_id و amount_minor صحيحان';
    end;
    if v_invoice_id is null or v_item_amount is null or v_item_amount <= 0 then
      raise exception 'كل تخصيص يحتاج فاتورة ومبلغًا أكبر من صفر';
    end if;
    if not exists (
      select 1 from billing.invoices i
      where i.id = v_invoice_id
        and i.well_id = p_well_id
        and i.farmer_well_account_id = p_farmer_well_account_id
        and i.status in ('issued', 'partially_paid', 'overdue')
    ) then
      raise exception 'الفاتورة % غير مفتوحة أو لا تخص حساب المزارع المحدد', v_invoice_id;
    end if;
    v_requested_total := v_requested_total + v_item_amount;
  end loop;

  -- 4) الصندوق الحاكم عند الدفع النقدي (ق-131 بند 18).
  --    المشغل النشط: نقد المزارع يدخل حيازته حصرًا — تمرير معرف صندوق
  --    آخر (وفيه صندوق البئر العام) يُرفض، فلا يرسل المشغل نقدًا إلى
  --    main_well عبر المعامل. سلوك غير المشغل وغير النقدي كما كان.
  if p_method = 'cash'
     and finance.is_active_operator_assignment(p_well_id, v_actor) then
    if p_cashbox_id is not null
       and p_cashbox_id is distinct from finance.ensure_operator_custody_cashbox(p_well_id, v_actor) then
      raise exception 'لا يجوز للمشغل توجيه نقد المزارع إلى صندوق آخر: التحصيل النقدي يدخل حيازة المشغل لهذا البئر إلزامًا';
    end if;
    v_cashbox_id := finance.ensure_operator_custody_cashbox(p_well_id, v_actor);
  else
    v_cashbox_id := coalesce(p_cashbox_id, finance.main_cashbox_id(p_well_id));
  end if;
  if p_method = 'cash' and not exists (
    select 1 from finance.cashboxes c
    where c.id = v_cashbox_id and c.well_id = p_well_id and c.status = 'active'
  ) then
    raise exception 'الصندوق النقدي غير موجود أو غير فعال لهذا البئر';
  end if;

  if p_session_charge_id is not null then
    select coalesce(array_agg(p.id), '{}'::uuid[])
    into v_existing_advance_ids
    from billing.payments p
    where p.farmer_well_account_id = p_farmer_well_account_id
      and p.well_id = p_well_id
      and p.purpose = 'advance';

    select (select outstanding_minor from billing.session_economic_settlements where session_charge_id=sc.id)
    into v_charge_remaining
    from billing.session_charges sc
    join ops.irrigation_sessions s on s.id = sc.session_id
    where sc.id = p_session_charge_id
      and sc.well_id = p_well_id
      and s.farmer_well_account_id = p_farmer_well_account_id
    for update of sc;

    if not found then
      raise exception 'تكلفة الجلسة غير موجودة أو لا تخص حساب المزارع المحدد';
    end if;
    v_charge_remaining := greatest(v_charge_remaining, 0);
    if jsonb_array_length(p_allocations) > 0
       and v_requested_total <> least(p_amount_minor, v_charge_remaining) then
      raise exception 'مجموع الفواتير المختارة % يجب أن يساوي الجزء المسدد من المستحق %',
        v_requested_total, least(p_amount_minor, v_charge_remaining);
    end if;

    -- 5) إنشاء الدفعة العادية؛ الزناد يقسم أي زيادة إلى رصيد مقدم
    --    ويرث الصندوق الحاكم نفسه — فتتغير الحيازة بمبلغ الاستلام
    --    كاملًا مرة واحدة لا مرتين.
    insert into billing.payments (
      tenant_id, well_id, session_charge_id, farmer_well_account_id,
      payer_person_id, cashbox_id, collected_by_profile_id,
      received_by_profile_id, amount_minor, method, paid_at,
      purpose, status, note, attachment_url
    ) values (
      v_tenant_id, p_well_id, p_session_charge_id, p_farmer_well_account_id,
      p_payer_person_id, v_cashbox_id, v_actor,
      v_actor, p_amount_minor, p_method, p_paid_at,
      'session', 'posted', p_note, p_attachment_url
    )
    returning id, amount_minor, purpose
    into v_payment_id, v_payment_amount, v_payment_purpose;

    select p.journal_entry_id into v_journal_id
    from billing.payments p where p.id = v_payment_id;

    if v_payment_purpose = 'advance' then
      v_settled_minor := 0;
      v_advance_minor := v_payment_amount;
      v_advance_payment_id := v_payment_id;
      v_advance_journal_id := v_journal_id;
    else
      v_settled_minor := v_payment_amount;
      v_advance_minor := p_amount_minor - v_payment_amount;
    end if;

    -- 6-8) تخصيص الفواتير المختارة مع حارسي قيمة الدفعة والدين.
    if jsonb_array_length(p_allocations) > 0 then
      v_allocation_summary := billing.allocate_payment(v_payment_id, p_allocations);
    end if;

    -- 9) التحقق من الرصيد المقدم الذي أنشأه الزناد.
    if v_advance_minor > 0 and v_advance_payment_id is null then
      select p.id, p.journal_entry_id
      into v_advance_payment_id, v_advance_journal_id
      from billing.payments p
      where p.farmer_well_account_id = p_farmer_well_account_id
        and p.well_id = p_well_id
        and p.purpose = 'advance'
        and p.amount_minor = v_advance_minor
        and not (p.id = any(v_existing_advance_ids))
        and p.note like 'رصيد مقدم تلقائي:%'
      order by p.created_at desc, p.id desc
      limit 1;
      if not found then
        raise exception 'فشل التحقق من تحويل زيادة الدفعة إلى رصيد مقدم';
      end if;
    end if;
  else
    -- التحصيل العام يخصص المبلغ المختار، وما بقي يسجل رصيدًا مقدمًا.
    if v_requested_total > p_amount_minor then
      raise exception 'إجمالي تخصيص الفواتير % يتجاوز مبلغ الدفعة %',
        v_requested_total, p_amount_minor;
    end if;

    v_settled_minor := v_requested_total;
    v_advance_minor := p_amount_minor - v_settled_minor;

    if v_settled_minor > 0 then
      insert into billing.payments (
        tenant_id, well_id, farmer_well_account_id, payer_person_id,
        cashbox_id, collected_by_profile_id, received_by_profile_id,
        amount_minor, method, paid_at, purpose, status, note, attachment_url
      ) values (
        v_tenant_id, p_well_id, p_farmer_well_account_id, p_payer_person_id,
        v_cashbox_id, v_actor, v_actor,
        v_settled_minor, p_method, p_paid_at, 'old_debt', 'posted', p_note, p_attachment_url
      )
      returning id into v_payment_id;

      select p.journal_entry_id into v_journal_id
      from billing.payments p where p.id = v_payment_id;

      v_allocation_summary := billing.allocate_payment(v_payment_id, p_allocations);
    end if;

    if v_advance_minor > 0 then
      insert into billing.payments (
        tenant_id, well_id, farmer_well_account_id, payer_person_id,
        cashbox_id, collected_by_profile_id, received_by_profile_id,
        amount_minor, method, paid_at, purpose, status, note, attachment_url
      ) values (
        v_tenant_id, p_well_id, p_farmer_well_account_id, p_payer_person_id,
        v_cashbox_id, v_actor, v_actor,
        v_advance_minor, p_method, p_paid_at, 'advance', 'posted',
        coalesce(p_note || ' | ', '') || 'المتبقي بعد تخصيص الفواتير رصيد مقدم',
        p_attachment_url
      )
      returning id into v_advance_payment_id;

      select p.journal_entry_id into v_advance_journal_id
      from billing.payments p where p.id = v_advance_payment_id;

      if v_payment_id is null then
        v_payment_id := v_advance_payment_id;
        v_journal_id := v_advance_journal_id;
      end if;
    end if;
  end if;

  -- 10) التحقق من أن القيود المالية أنشئت ورحلت.
  if v_journal_id is null or not exists (
    select 1 from finance.journal_entries je
    where je.id = v_journal_id and je.status = 'posted'
  ) then
    raise exception 'فشل إنشاء القيد المالي المرحل للدفعة';
  end if;
  if v_advance_minor > 0 and (
    v_advance_journal_id is null or not exists (
      select 1 from finance.journal_entries je
      where je.id = v_advance_journal_id and je.status = 'posted'
    )
  ) then
    raise exception 'فشل إنشاء القيد المالي المرحل للرصيد المقدم';
  end if;

  -- 11) حالات الفواتير حدثها إجراء التخصيص؛ نتحقق من سلامة الأرصدة.
  if exists (
    select 1 from billing.invoices i
    where i.id in (
      select (x ->> 'invoice_id')::uuid from jsonb_array_elements(p_allocations) x
    ) and (i.paid_minor + i.outstanding_minor <> i.total_minor::numeric+i.correction_total_delta_minor
           or i.outstanding_minor < 0)
  ) then
    raise exception 'فشل التحقق النهائي من أرصدة الفواتير بعد الدفعة';
  end if;

  -- 12) سجل التدقيق.
  perform audit.log(
    v_tenant_id, p_well_id, 'record_payment', 'billing.payments', v_payment_id,
    null,
    jsonb_build_object(
      'payment_id', v_payment_id,
      'settled_minor', v_settled_minor,
      'advance_minor', v_advance_minor,
      'advance_payment_id', v_advance_payment_id,
      'journal_entry_id', v_journal_id,
      'advance_journal_entry_id', v_advance_journal_id
    ),
    'تسجيل دفعة وتوزيعها'
  );

  -- 13) الإيصال جزء من الملخص النهائي ويحمل رقم السند ووقته ومكوناته.
  return jsonb_build_object(
    'payment_id', v_payment_id,
    'settled_minor', v_settled_minor,
    'advance_minor', v_advance_minor,
    'journal_entry_id', v_journal_id,
    'advance_payment_id', v_advance_payment_id,
    'advance_journal_entry_id', v_advance_journal_id,
    'allocation', v_allocation_summary,
    'receipt', jsonb_build_object(
      'payment_id', v_payment_id,
      'public_code', (select p.public_code from billing.payments p where p.id = v_payment_id),
      'paid_at', p_paid_at,
      'amount_minor', p_amount_minor,
      'method', p_method,
      'payer_person_id', p_payer_person_id
    )
  );
end;
$function$;

-- Preserved body from 20261108001500_legacy_invoice_accounting_resolution.sql; only root boundary/necessary row lock changes.
create or replace function billing.allocate_payment(
  p_payment_id uuid,
  p_allocations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'billing', 'finance', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_payment billing.payments%rowtype;
  v_invoice billing.invoices%rowtype;
  v_item jsonb;
  v_invoice_id uuid;
  v_amount bigint;
  v_requested_total bigint := 0;
  v_allocated_before bigint;
  v_available bigint;
  v_allocation_id uuid;
  v_journal_id uuid;
  v_result_items jsonb := '[]'::jsonb;
  v_position integer := 0;
begin
 perform billing.enter_financial_write((select well_id from billing.payments where id=p_payment_id),'payment.allocate',null, (select tenant_id from billing.payments where id=p_payment_id));
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل توزيع الدفعة على الفواتير';
  end if;

  select * into v_payment from billing.payments where id=p_payment_id;
  if not found then raise exception 'الدفعة غير موجودة: %',p_payment_id;end if;
  if not coalesce(iam.has_well_permission(v_payment.well_id,'payment.allocate'),false) then
    raise exception 'لا تملك صلاحية توزيع دفعات هذا البئر';end if;
  perform billing.lock_customer_credit_well(v_payment.well_id);
  perform billing.require_no_disputed_invoice((x->>'invoice_id')::uuid,(x->>'amount_minor')::bigint) from jsonb_array_elements(p_allocations) x;

  perform billing.refresh_partition_invoices(v_payment.well_id);
  select p.* into v_payment
  from billing.payments p
  where p.id = p_payment_id
  for update;

  if not found then
    raise exception 'الدفعة غير موجودة: %', p_payment_id;
  end if;
  if v_payment.status <> 'posted' then
    raise exception 'لا يمكن توزيع دفعة حالتها % — يجب أن تكون مرحلة', v_payment.status;
  end if;
  if v_payment.farmer_well_account_id is null then
    raise exception 'لا يمكن توزيع الدفعة لأنها غير مرتبطة بحساب مزارع';
  end if;
  if not iam.has_well_permission(v_payment.well_id, 'payment.allocate') then
    raise exception 'لا تملك صلاحية توزيع دفعات هذا البئر';
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array'
     or jsonb_array_length(p_allocations) = 0 then
    raise exception 'يجب إرسال فاتورة واحدة على الأقل مع مبلغ التخصيص';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_allocations) x
    group by x ->> 'invoice_id'
    having count(*) > 1
  ) then
    raise exception 'لا يجوز تكرار الفاتورة نفسها في طلب التوزيع';
  end if;

  for v_item in select value from jsonb_array_elements(p_allocations)
  loop
    begin
      v_invoice_id := (v_item ->> 'invoice_id')::uuid;
      v_amount := (v_item ->> 'amount_minor')::bigint;
    exception when others then
      raise exception 'صيغة تخصيص الفاتورة غير صالحة — يلزم invoice_id و amount_minor صحيحان';
    end;
    if v_invoice_id is null then
      raise exception 'معرف الفاتورة مطلوب في كل تخصيص';
    end if;
    if v_amount is null or v_amount <= 0 then
      raise exception 'مبلغ تخصيص كل فاتورة يجب أن يكون أكبر من صفر';
    end if;
    v_requested_total := v_requested_total + v_amount;
  end loop;

  select b.direct_capacity_minor into strict v_available
  from billing.payment_economic_applications b where b.payment_id=p_payment_id;
  if v_requested_total > v_available then
    raise exception 'إجمالي التخصيص المطلوب % يتجاوز المتاح من الدفعة %',
      v_requested_total, v_available;
  end if;

  for v_item in
    select a.value
    from jsonb_array_elements(p_allocations) with ordinality as a(value, position)
    order by a.position
  loop
    v_position := v_position + 1;
    v_invoice_id := (v_item ->> 'invoice_id')::uuid;
    v_amount := (v_item ->> 'amount_minor')::bigint;

    select i.* into v_invoice
    from billing.invoices i
    where i.id = v_invoice_id
    for update;

    if not found then
      raise exception 'الفاتورة غير موجودة: %', v_invoice_id;
    end if;
    if v_invoice.well_id is distinct from v_payment.well_id
       or v_invoice.farmer_well_account_id is distinct from v_payment.farmer_well_account_id then
      raise exception 'الفاتورة % لا تخص البئر وحساب المزارع المرتبطين بالدفعة', v_invoice_id;
    end if;
    if v_invoice.status not in ('issued', 'partially_paid', 'overdue','paid') then
      raise exception 'لا يمكن تخصيص دفعة لفاتورة حالتها %', v_invoice.status;
    end if;
    if v_amount > v_invoice.outstanding_minor + coalesce((select direct_settled_minor from billing.session_economic_settlements d
      where d.session_charge_id=v_payment.session_charge_id and d.session_id=v_invoice.session_id),0) then
      raise exception 'مبلغ التخصيص % يتجاوز دين الفاتورة المتبقي %',
        v_amount, v_invoice.outstanding_minor;
    end if;

    insert into billing.payment_allocations (
      tenant_id, payment_id, invoice_id, allocated_minor
    ) values (
      v_payment.tenant_id, p_payment_id, v_invoice_id, v_amount
    )
    returning id into v_allocation_id;

    perform billing.refresh_partition_invoices(v_payment.well_id);

    -- استخدام الرصيد المقدم يحوّل الالتزام إلى تسوية ذمة المزارع.
    if v_payment.purpose = 'advance' then
      v_journal_id := gen_random_uuid();
      insert into finance.journal_entries (
        id, tenant_id, public_code, well_id, entry_date,
        source_type, source_id, description, idempotency_key
      ) values (
        v_journal_id, v_payment.tenant_id, core.generate_public_code('JE'),
        v_payment.well_id, clock_timestamp(), 'advance_allocation',
        v_allocation_id, 'استخدام رصيد مقدم في الفاتورة ' || v_invoice.public_code,
        'ADV-ALLOC-' || v_allocation_id::text
      );

      insert into finance.journal_lines (
        tenant_id, journal_entry_id, ledger_account_id, entry_side,
        amount_minor, farmer_well_account_id, description
      ) values
        (v_payment.tenant_id, v_journal_id,
         finance.ledger_account_id(v_payment.well_id, '2000'), 'debit',
         v_amount, v_payment.farmer_well_account_id, 'استخدام الرصيد المقدم'),
        (v_payment.tenant_id, v_journal_id,
         finance.ledger_account_id(v_payment.well_id, '1100'), 'credit',
         v_amount, v_payment.farmer_well_account_id, 'تسديد ذمة فاتورة من الرصيد المقدم');

      perform finance.post_journal_entry(v_journal_id, v_actor);
    else
      v_journal_id := null;
    end if;

    perform audit.log(
      v_payment.tenant_id, v_payment.well_id,
      'allocate_payment', 'billing.payment_allocations', v_allocation_id,
      null,
      jsonb_build_object(
        'payment_id', p_payment_id,
        'invoice_id', v_invoice_id,
        'allocated_minor', v_amount,
        'position', v_position,
        'journal_entry_id', v_journal_id
      ),
      'توزيع دفعة على فاتورة'
    );

    v_result_items := v_result_items || jsonb_build_array(jsonb_build_object(
      'allocation_id', v_allocation_id,
      'invoice_id', v_invoice_id,
      'allocated_minor', v_amount,
      'invoice_status',(select status from billing.invoices where id=v_invoice_id),
      'journal_entry_id', v_journal_id
    ));
  end loop;

  if (select available_minor from billing.payment_available_balances where payment_id=p_payment_id)<0 then
    raise exception 'payment_effective_availability_negative' using errcode='23514';
  end if;

  return jsonb_build_object(
    'payment_id', p_payment_id,
    'allocated_minor', v_requested_total,
    'remaining_available_minor',(select remaining_minor from billing.payment_economic_applications where payment_id=p_payment_id),
    'remaining_transfer_capacity_minor',v_available-v_requested_total,
    'allocations', v_result_items
  );
end;
$function$;

-- Preserved body from 20261107001000_payment_partition_consumers.sql; only root boundary/necessary row lock changes.
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
 if auth.uid() is not null then
  if p_reversed_by is not null and p_reversed_by is distinct from auth.uid() then raise exception 'financial_actor_mismatch' using errcode='42501';end if;
  p_reversed_by:=auth.uid();
 end if;
 perform billing.enter_financial_write((select well_id from billing.payments where id=p_payment_id),'payment.reverse',null, (select tenant_id from billing.payments where id=p_payment_id));
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'سبب العكس مطلوب';
  end if;

  perform billing.lock_customer_credit_well((select well_id from billing.payments where id=p_payment_id));
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

  perform billing.refresh_partition_invoices(v_pay.well_id);
  return v_rev;
end;
$function$;

-- Preserved distribution cash/payment semantics; parent then child locks.
create or replace function finance.pay_partner_distribution(
  p_distribution_line_id uuid,
  p_amount_minor bigint,
  p_paid_by uuid default null,
  p_paid_at timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
security definer
set search_path to 'finance', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  candidate_cycle uuid;candidate_well uuid;candidate_tenant uuid;
  v_line finance.profit_distribution_lines%rowtype;
  v_cycle finance.profit_distribution_cycles%rowtype;
  v_remaining bigint;
  v_new_paid bigint;
  v_new_line_status text;
  v_new_cycle_status text;
  v_cashbox_id uuid;
  v_journal_id uuid;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل دفع مستحق الشريك';
  end if;
  if p_paid_by is not null and p_paid_by is distinct from v_actor then
    raise exception 'منفذ الدفع يجب أن يطابق المستخدم المسجل حاليًا';
  end if;
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'مبلغ دفع الشريك يجب أن يكون أكبر من صفر';
  end if;

  select l.distribution_cycle_id,c.well_id,c.tenant_id into candidate_cycle,candidate_well,candidate_tenant
  from finance.profit_distribution_lines l join finance.profit_distribution_cycles c on c.id=l.distribution_cycle_id
  where l.id=p_distribution_line_id;
  if not found then raise exception 'سطر توزيع الشريك غير موجود: %',p_distribution_line_id;end if;
  perform billing.enter_financial_write(candidate_well,'distribution.pay',null,candidate_tenant);
  select * into strict v_cycle from finance.profit_distribution_cycles where id=candidate_cycle for update;
  select * into strict v_line from finance.profit_distribution_lines where id=p_distribution_line_id for update;
  if(v_cycle.well_id,v_cycle.tenant_id,v_line.distribution_cycle_id) is distinct from(candidate_well,candidate_tenant,candidate_cycle)
   or v_line.tenant_id<>v_cycle.tenant_id then raise exception 'distribution_payment_scope_changed' using errcode='40001';end if;
  if not iam.has_well_permission(v_cycle.well_id, 'distribution.pay') then
    raise exception 'لا تملك صلاحية دفع مستحقات شركاء هذا البئر';
  end if;
  if v_line.status = 'paid' then
    raise exception 'مستحق الشريك في هذا السطر مدفوع بالكامل مسبقًا';
  end if;
  if v_cycle.status not in ('approved', 'partially_paid') then
    raise exception 'لا يمكن دفع مستحق شريك من دورة حالتها % — يجب أن تكون معتمدة', v_cycle.status;
  end if;
  if v_line.status not in ('approved', 'partially_paid') then
    raise exception 'لا يمكن دفع سطر حالته % — يجب أن يكون معتمدًا', v_line.status;
  end if;

  v_remaining := v_line.net_payable_minor - v_line.paid_minor;
  if v_remaining <= 0 then
    raise exception 'لا يوجد مبلغ متبقٍ لدفعه في مستحق الشريك';
  end if;
  if p_amount_minor > v_remaining then
    raise exception 'مبلغ الدفع % يتجاوز مستحق الشريك المتبقي %',
      p_amount_minor, v_remaining;
  end if;

  v_cashbox_id := finance.main_cashbox_id(v_cycle.well_id);
  if v_cashbox_id is null or not exists (
    select 1 from finance.cashboxes c
    where c.id = v_cashbox_id and c.status = 'active'
  ) then
    raise exception 'الصندوق الرئيسي غير موجود أو غير فعال لهذا البئر';
  end if;

  -- قيد الصرف: تخفيض مستحق الشريك مقابل النقد الخارج من الصندوق الرئيسي.
  v_journal_id := gen_random_uuid();
  insert into finance.journal_entries (
    id, tenant_id, public_code, well_id, entry_date,
    source_type, source_id, description, idempotency_key
  ) values (
    v_journal_id, v_cycle.tenant_id, core.generate_public_code('JE'),
    v_cycle.well_id, p_paid_at, 'partner_distribution_payment',
    v_journal_id, 'دفع مستحق شريك من دورة ' || v_cycle.public_code,
    'PDP-' || v_journal_id::text
  );

  insert into finance.journal_lines (
    tenant_id, journal_entry_id, ledger_account_id, entry_side,
    amount_minor, partner_id, cashbox_id, description
  ) values
    (v_cycle.tenant_id, v_journal_id,
     finance.ledger_account_id(v_cycle.well_id, '2100'), 'debit',
     p_amount_minor, v_line.partner_id, null, 'تخفيض مستحق الشريك'),
    (v_cycle.tenant_id, v_journal_id,
     finance.ledger_account_id(v_cycle.well_id, '1000'), 'credit',
     p_amount_minor, v_line.partner_id, v_cashbox_id, 'صرف من الصندوق الرئيسي');

  perform finance.post_journal_entry(v_journal_id, v_actor);

  v_new_paid := v_line.paid_minor + p_amount_minor;
  v_new_line_status := case
    when v_new_paid = v_line.net_payable_minor then 'paid'
    else 'partially_paid'
  end;

  update finance.profit_distribution_lines
  set paid_minor = v_new_paid,
      status = v_new_line_status
  where id = p_distribution_line_id;

  if exists (
    select 1 from finance.profit_distribution_lines l
    where l.distribution_cycle_id = v_cycle.id
      and l.paid_minor < greatest(l.net_payable_minor, 0)
  ) then
    v_new_cycle_status := 'partially_paid';
  else
    v_new_cycle_status := 'paid';
  end if;

  update finance.profit_distribution_cycles
  set status = v_new_cycle_status
  where id = v_cycle.id;

  perform audit.log(
    v_cycle.tenant_id, v_cycle.well_id,
    'pay_partner_distribution', 'finance.profit_distribution_lines',
    p_distribution_line_id,
    jsonb_build_object(
      'paid_minor', v_line.paid_minor,
      'status', v_line.status
    ),
    jsonb_build_object(
      'paid_minor', v_new_paid,
      'status', v_new_line_status,
      'cycle_status', v_new_cycle_status,
      'journal_entry_id', v_journal_id
    ),
    'دفع مستحق شريك'
  );

  return jsonb_build_object(
    'distribution_line_id', p_distribution_line_id,
    'paid_now_minor', p_amount_minor,
    'paid_total_minor', v_new_paid,
    'remaining_minor', v_line.net_payable_minor - v_new_paid,
    'line_status', v_new_line_status,
    'cycle_status', v_new_cycle_status,
    'journal_entry_id', v_journal_id
  );
end;
$function$;

create or replace function ops.finalize_session_from_closed_segments(
 p_session_id uuid,p_ended_at timestamptz,p_fuel_tank_id uuid default null)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_tenant_id uuid;
  v_status text;
  v_session_started_at timestamptz;
  v_operator_profile_id uuid;
  v_farmer_well_account_id uuid;
  v_open_segment_id uuid;
  v_open_segment_type text;
  v_open_energy_source text;
  v_open_started_at timestamptz;
  v_total_actual_seconds bigint;
  v_total_billable_seconds bigint;
  v_total_amount_minor bigint;
  v_weighted_numerator numeric;
  v_weighted_rate_minor bigint;
  v_charge_id uuid;
  v_fuel_quantity bigint;
  v_segment record;
  v_segments_json jsonb;
begin
 perform billing.require_customer_credit_well_lock((select well_id from ops.irrigation_sessions where id=p_session_id));
 select s.well_id,w.tenant_id,s.started_at,s.farmer_well_account_id
 into v_well_id,v_tenant_id,v_session_started_at,v_farmer_well_account_id
 from ops.irrigation_sessions s join core.wells w on w.id=s.well_id
 where s.id=p_session_id for update of s;
 v_actor:=auth.uid();
 if not found or v_actor is null or not iam.has_well_permission(v_well_id,'session.complete') then
   raise exception 'completion_forbidden' using errcode='42501'; end if;
 if exists(select 1 from billing.session_charges where session_id=p_session_id) then
   raise exception 'session_already_charged' using errcode='23514'; end if;
 if p_ended_at<=v_session_started_at or not isfinite(p_ended_at) or
    not exists(select 1 from ops.session_segments where session_id=p_session_id) or
    exists(select 1 from (select started_at,ended_at,lag(ended_at) over(order by sequence_number) prev,
      row_number() over(order by sequence_number) n from ops.session_segments where session_id=p_session_id) q
      where (n=1 and started_at<>v_session_started_at) or (n>1 and started_at is distinct from prev)) or
    (select max(ended_at) from ops.session_segments where session_id=p_session_id) is distinct from p_ended_at then
   raise exception 'historical_segment_chronology_invalid' using errcode='23514'; end if;
  if exists (
    select 1
    from (
      select ss.sequence_number,
             row_number() over (order by ss.sequence_number) as expected_sequence
      from ops.session_segments ss
      where ss.session_id = p_session_id
    ) ordered_segments
    where ordered_segments.sequence_number <> ordered_segments.expected_sequence
  ) then
    raise exception 'ترتيب مقاطع الجلسة غير متسلسل ولا يمكن إكمالها';
  end if;

  if exists (
    select 1
    from ops.session_segments a
    join ops.session_segments b
      on b.session_id = a.session_id and b.id <> a.id
    where a.session_id = p_session_id
      and tstzrange(a.started_at, a.ended_at, '[)')
          && tstzrange(b.started_at, b.ended_at, '[)')
  ) then
    raise exception 'يوجد تداخل زمني بين مقاطع الجلسة ولا يمكن إكمالها';
  end if;

  if exists (
    select 1 from ops.session_segments ss
    where ss.session_id = p_session_id
      and (ss.ended_at is null or ss.ended_at <= ss.started_at)
  ) then
    raise exception 'يوجد مقطع بلا نهاية صحيحة ولا يمكن إكمال الجلسة';
  end if;

  if exists (
    select 1 from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.is_billable
      and ss.segment_type in ('solar_run', 'well_diesel_run', 'farmer_diesel_run')
      and coalesce(ss.applied_operation_rate_minor,
                   ss.applied_hourly_rate_minor, 0) <= 0
  ) then
    raise exception 'يوجد مقطع تشغيل بلا سعر مثبت صالح';
  end if;

  if exists (
    select 1 from ops.session_segments ss
    where ss.session_id = p_session_id
      and (ss.fuel_actual_ml is not null or ss.fuel_estimated_ml is not null)
      and ss.fuel_measurement_type is null
  ) then
    raise exception 'يوجد استهلاك وقود بلا نوع قياس محدد';
  end if;

  update ops.session_segments ss
  set actual_seconds = extract(epoch from (ss.ended_at - ss.started_at))::bigint,
      billable_seconds = case
        when ss.is_billable
          then extract(epoch from (ss.ended_at - ss.started_at))::bigint
        else 0
      end,
      actual_minutes = extract(epoch from (ss.ended_at - ss.started_at))::bigint / 60,
      raw_billable_minutes = case
        when ss.is_billable
          then extract(epoch from (ss.ended_at - ss.started_at))::bigint / 60
        else 0
      end,
      time_charge_minor = case
        when not ss.is_billable then 0
        else (
          extract(epoch from (ss.ended_at - ss.started_at))::bigint
          * coalesce(ss.applied_operation_rate_minor,
                     ss.applied_hourly_rate_minor)
        ) / 3600
      end,
      fuel_charge_minor = case
        when not ss.is_billable then 0
        when coalesce(ss.fuel_actual_ml, ss.fuel_estimated_ml, 0) = 0 then 0
        when ss.applied_fuel_price_per_liter_minor is null then 0
        else (
          coalesce(ss.fuel_actual_ml, ss.fuel_estimated_ml)
          * ss.applied_fuel_price_per_liter_minor
        ) / 1000
      end,
      -- تصحيح ق-17/ق-91: total = time فقط (الوقود رقابي لا يُضاف كرسوم)
      total_charge_minor = case
        when not ss.is_billable then 0
        else (
          extract(epoch from (ss.ended_at - ss.started_at))::bigint
          * coalesce(ss.applied_operation_rate_minor,
                     ss.applied_hourly_rate_minor)
        ) / 3600
      end
  where ss.session_id = p_session_id;

  select coalesce(sum(ss.actual_seconds), 0),
         coalesce(sum(ss.billable_seconds), 0),
         -- تصحيح ق-17/ق-91: المبلغ الإجمالي = مجموع time_charge_minor فقط
         coalesce(sum(ss.time_charge_minor), 0),
         coalesce(sum(
           ss.billable_seconds::numeric
           * coalesce(ss.applied_operation_rate_minor,
                      ss.applied_hourly_rate_minor, 0)::numeric
         ), 0)
  into v_total_actual_seconds, v_total_billable_seconds,
       v_total_amount_minor, v_weighted_numerator
  from ops.session_segments ss
  where ss.session_id = p_session_id;

  if v_total_billable_seconds <= 0 then
    raise exception 'لا يوجد وقت تشغيل مفوتر في الجلسة';
  end if;
  if v_total_billable_seconds > 2147483647 then
    raise exception 'مدة الجلسة المفوترة تتجاوز الحد المدعوم';
  end if;

  v_weighted_rate_minor := round(
    v_weighted_numerator / v_total_billable_seconds
  )::bigint;

  if v_weighted_rate_minor <= 0 then
    raise exception 'تعذر حساب متوسط سعر زمني صالح للجلسة';
  end if;

  update ops.irrigation_sessions
  set ended_at = p_ended_at,
      status = 'closed',
      updated_at = clock_timestamp()
  where id = p_session_id;

  insert into billing.session_charges (
    session_id, well_id, duration_seconds, price_per_hour_minor,
    amount_minor, pricing_mode
  ) values (
    p_session_id, v_well_id, v_total_billable_seconds::integer,
    v_weighted_rate_minor, v_total_amount_minor, 'segments'
  )
  returning id into v_charge_id;

  for v_segment in
    select ss.id, ss.energy_source, ss.fuel_owner_person_id,
           ss.fuel_actual_ml, ss.fuel_estimated_ml,
           ss.fuel_measurement_type, ss.ended_at
    from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.energy_source in ('well_diesel', 'farmer_diesel')
      and coalesce(ss.fuel_actual_ml, ss.fuel_estimated_ml, 0) > 0
    order by ss.sequence_number
  loop
    v_fuel_quantity := coalesce(v_segment.fuel_actual_ml,
                                v_segment.fuel_estimated_ml);

    insert into inventory.fuel_transactions (
      tenant_id, well_id, fuel_tank_id, transaction_type,
      ownership_type, owner_person_id, farmer_well_account_id,
      quantity_ml, direction, measurement_type, session_segment_id,
      occurred_at, status, created_by, notes
    ) values (
      v_tenant_id, v_well_id,
      case when v_segment.energy_source = 'well_diesel'
        then p_fuel_tank_id else null end,
      'session_consumption',
      case when v_segment.energy_source = 'well_diesel'
        then 'well' else 'farmer' end,
      case when v_segment.energy_source = 'farmer_diesel'
        then v_segment.fuel_owner_person_id else null end,
      case when v_segment.energy_source = 'farmer_diesel'
        then v_farmer_well_account_id else null end,
      v_fuel_quantity, 'out', v_segment.fuel_measurement_type,
      v_segment.id, v_segment.ended_at, 'posted', v_actor,
      'استهلاك وقود ناتج عن إكمال جلسة السقي'
    );
  end loop;

  select jsonb_agg(
    jsonb_build_object(
      'segment_id', ss.id,
      'sequence_number', ss.sequence_number,
      'segment_type', ss.segment_type,
      'energy_source', ss.energy_source,
      'actual_seconds', ss.actual_seconds,
      'billable_seconds', ss.billable_seconds,
      'time_charge_minor', ss.time_charge_minor,
      'fuel_charge_minor', ss.fuel_charge_minor,
      'total_charge_minor', ss.total_charge_minor
    ) order by ss.sequence_number
  )
  into v_segments_json
  from ops.session_segments ss
  where ss.session_id = p_session_id;

  insert into audit.audit_logs (
    tenant_id, well_id, user_id, action, entity_type, entity_id,
    new_values, reason
  ) values (
    v_tenant_id, v_well_id, v_actor, 'session_completed',
    'ops.irrigation_sessions', p_session_id,
    jsonb_build_object(
      'ended_at', p_ended_at,
      'actual_seconds', v_total_actual_seconds,
      'billable_seconds', v_total_billable_seconds,
      'amount_minor', v_total_amount_minor,
      'pricing_mode', 'segments'
    ),
    'إكمال جلسة السقي عبر الإجراء الذري'
  );

  return jsonb_build_object(
    'session_id', p_session_id,
    'session_charge_id', v_charge_id,
    'status', 'closed',
    'ended_at', p_ended_at,
    'actual_seconds', v_total_actual_seconds,
    'billable_seconds', v_total_billable_seconds,
    'weighted_price_per_hour_minor', v_weighted_rate_minor,
    'amount_minor', v_total_amount_minor,
    'segments', coalesce(v_segments_json, '[]'::jsonb)
  );
end;
$function$;

create or replace function ops.materialize_historical_occurrence(
 p_well_id uuid,p_occurrence_id uuid,p_settlement_id uuid,p_facts jsonb)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $f$
declare
 o ops.operational_occurrences%rowtype; s jsonb:=p_facts->'start'; c jsonb:=p_facts->'completion';
 e jsonb; ep jsonb; at_time timestamptz; stop_time timestamptz; previous_time timestamptz;
 sid uuid; segment_id uuid; completion_id uuid; guard jsonb; result jsonb; seq integer:=1;
 running boolean:=true; pending_source boolean:=false; source text; owner_id uuid;
 last_run ops.session_segments%rowtype; old_segment ops.session_segments%rowtype;
 reason text; request_payload jsonb; event_ids uuid[]; q bigint; measurement text;
begin
 perform billing.require_customer_credit_well_lock(p_well_id);
 select * into strict o from ops.operational_occurrences
 where well_id=p_well_id and occurrence_command_id=p_occurrence_id
   and settlement_command_id=p_settlement_id and provenance='historical_settlement' for update;
 sid:=o.server_session_id; stop_time:=(c->>'occurred_at')::timestamptz;
 completion_id:=(c->>'command_id')::uuid;
 if auth.uid() is null or not iam.has_well_permission(p_well_id,'session.complete') then
   raise exception 'historical_settlement_forbidden' using errcode='42501'; end if;
 if o.status<>'materializing' or completion_id is null or completion_id<>o.completion_command_id
    or (s->>'started_at')::timestamptz<>o.started_at or stop_time<>o.ended_at
    or not isfinite(o.started_at) or not isfinite(stop_time)
    or o.started_at>=stop_time or stop_time>=transaction_timestamp()
    or jsonb_typeof(p_facts->'events') is distinct from 'array'
    or jsonb_typeof(c->'payload') is distinct from 'object'
    or (select count(*) from jsonb_object_keys(c->'payload'))<>1
    or c->'payload'->'p_session_id' is distinct from jsonb_build_object('$ref',p_facts->>'root_local_id','$kind','session') then
   raise exception 'historical_facts_invalid' using errcode='22023'; end if;
 if exists(select 1 from ops.irrigation_sessions x
    where (x.well_id=p_well_id or x.pump_id=(s->>'pump_id')::uuid)
    and tstzrange(x.started_at,x.ended_at,'[)') && tstzrange(o.started_at,stop_time,'[)')) then
   raise exception 'historical_interval_conflict' using errcode='23514'; end if;
 if not exists(select 1 from core.pumps where id=(s->>'pump_id')::uuid and well_id=p_well_id)
    or not exists(select 1 from ops.farms f join ops.farmer_well_accounts a on a.id=f.farmer_well_account_id
      where f.id=(s->>'farm_id')::uuid and f.well_id=p_well_id and a.well_id=p_well_id
        and a.tenant_id=o.tenant_id and a.id=(s->>'farmer_well_account_id')::uuid) then
   raise exception 'historical_entity_scope_mismatch' using errcode='22023'; end if;
 request_payload:=jsonb_build_object('session_id',sid,'well_id',p_well_id,
   'ended_at',stop_time,'original_command',c,'occurrence_command_id',p_occurrence_id);
 guard:=sync.begin_command(o.tenant_id,completion_id,'complete_irrigation_session',request_payload,sid);
 if coalesce((guard->>'duplicate')::boolean,false) then
   -- لا استبدال لنتيجة إكمال سابقة، حتى عند نقص بصمتها القديمة.
   raise exception 'original_completion_already_has_result' using errcode='22023'; end if;
 insert into ops.irrigation_sessions(id,well_id,pump_id,farm_id,farmer_well_account_id,
   operator_profile_id,started_at,ended_at,status,booking_id,current_shift_id,collector_profile_id)
 values(sid,p_well_id,(s->>'pump_id')::uuid,(s->>'farm_id')::uuid,
   (s->>'farmer_well_account_id')::uuid,o.original_operator_id,o.started_at,stop_time,'closed',null,null,null);
 -- source_booking_id في سجل الواقعة هو المنشأ؛ لا استهلاك لحجز أعيدت جدولته الآن.
 source:=s->>'energy_source'; owner_id:=(s->>'fuel_owner_person_id')::uuid;
 segment_id:=ops.create_priced_session_segment(sid,source,o.started_at,owner_id);
 previous_time:=o.started_at; event_ids:=array[p_occurrence_id,completion_id,p_settlement_id];
 for e in select value from jsonb_array_elements(p_facts->'events') loop
   ep:=e->'payload'; at_time:=(e->>'occurred_at')::timestamptz;
   if (e->>'command_id')::uuid is null or (e->>'command_id')::uuid=any(event_ids)
      or at_time is null or not isfinite(at_time) or at_time<=previous_time or at_time>=stop_time
      or jsonb_typeof(ep) is distinct from 'object'
      or ep->'p_session_id' is distinct from c->'payload'->'p_session_id' then
     raise exception 'historical_event_chronology_invalid' using errcode='22023'; end if;
   event_ids:=array_append(event_ids,(e->>'command_id')::uuid);
   guard:=sync.begin_command(o.tenant_id,(e->>'command_id')::uuid,e->>'type',
     jsonb_build_object('session_id',sid,'original_command',e,'occurrence_command_id',p_occurrence_id),sid);
   if coalesce((guard->>'duplicate')::boolean,false) then
     raise exception 'historical_event_identity_already_used' using errcode='22023'; end if;
   select * into strict old_segment from ops.session_segments where id=segment_id;
   update ops.session_segments set ended_at=at_time where id=segment_id;
   if running then select * into strict last_run from ops.session_segments where id=segment_id; end if;
   q:=(ep->>'p_closed_fuel_quantity_ml')::bigint;
   measurement:=ep->>'p_closed_fuel_measurement_type';
   if q is not null then
     if not running or source not in ('well_diesel','farmer_diesel') or q<=0
       or coalesce(measurement,'actual') not in ('actual','estimated') then
       raise exception 'historical_fuel_invalid' using errcode='22023'; end if;
     update ops.session_segments set fuel_measurement_type=coalesce(measurement,'actual'),
       fuel_actual_ml=case when coalesce(measurement,'actual')='actual' then q end,
       fuel_estimated_ml=case when measurement='estimated' then q end where id=segment_id;
   elsif measurement is not null then raise exception 'historical_fuel_invalid' using errcode='22023'; end if;
   seq:=seq+1;
   case e->>'type'
   when 'pause_irrigation_session' then
     reason:=ep->>'p_reason';
     if not running or reason not in ('operator_pause','farmer_requested_pause') then
       raise exception 'historical_pause_invalid' using errcode='22023'; end if;
     insert into ops.session_segments(tenant_id,session_id,sequence_number,segment_type,started_at,is_billable,notes)
       values(o.tenant_id,sid,seq,reason,at_time,false,reason) returning id into segment_id;
     running:=false; pending_source:=false;
   when 'resume_irrigation_session' then
     if running then raise exception 'historical_resume_invalid' using errcode='22023'; end if;
     if pending_source then segment_id:=ops.create_priced_session_segment(sid,source,at_time,owner_id);
     else
       insert into ops.session_segments(tenant_id,session_id,sequence_number,segment_type,energy_source,
         started_at,is_billable,fuel_owner_person_id,applied_price_rule_id,applied_hourly_rate_minor,
         applied_operation_rate_minor,applied_fuel_price_per_liter_minor)
       values(o.tenant_id,sid,seq,last_run.segment_type,last_run.energy_source,at_time,true,
         last_run.fuel_owner_person_id,last_run.applied_price_rule_id,last_run.applied_hourly_rate_minor,
         last_run.applied_operation_rate_minor,last_run.applied_fuel_price_per_liter_minor)
       returning id into segment_id;
     end if;
     running:=true; pending_source:=false;
   when 'change_session_energy_source' then
     if ep->>'p_new_source' is null or ep->>'p_new_source' not in ('solar','well_diesel','farmer_diesel')
       or ep->>'p_new_source'=source then
       raise exception 'historical_energy_invalid' using errcode='22023'; end if;
     source:=ep->>'p_new_source'; owner_id:=(ep->>'p_new_fuel_owner_person_id')::uuid;
     if running then segment_id:=ops.create_priced_session_segment(sid,source,at_time,owner_id);
     else
       if source='farmer_diesel' and owner_id is null then
         select fp.person_id into owner_id from ops.farmer_well_accounts a
          join ops.farmer_profiles fp on fp.id=a.farmer_profile_id where a.id=(s->>'farmer_well_account_id')::uuid;
       end if;
       if source='farmer_diesel' and not exists(select 1 from core.persons where id=owner_id and tenant_id=o.tenant_id) then
         raise exception 'historical_fuel_owner_invalid' using errcode='22023'; end if;
       insert into ops.session_segments(tenant_id,session_id,sequence_number,segment_type,energy_source,
         started_at,is_billable,fuel_owner_person_id,notes)
       values(o.tenant_id,sid,seq,'source_change_pause',source,at_time,false,
         case when source='farmer_diesel' then owner_id end,'source_change_pause') returning id into segment_id;
       pending_source:=true;
     end if;
   else raise exception 'historical_event_type_invalid' using errcode='22023';
   end case;
   perform sync.finish_command(o.tenant_id,(e->>'command_id')::uuid,'accepted',jsonb_build_object('id',segment_id));
   previous_time:=at_time;
 end loop;
 q:=(c->>'fuel_quantity_ml')::bigint;
 measurement:=c->>'fuel_measurement_type';
 if q is not null and (not running or source not in ('well_diesel','farmer_diesel') or q<=0
   or coalesce(measurement,'actual') not in ('actual','estimated')) then
   raise exception 'historical_completion_fuel_invalid' using errcode='22023'; end if;
 if q is null and measurement is not null then
   raise exception 'historical_completion_fuel_invalid' using errcode='22023'; end if;
 update ops.session_segments set ended_at=stop_time,
   fuel_measurement_type=case when q is not null then coalesce(measurement,'actual') else fuel_measurement_type end,
   fuel_actual_ml=case when q is not null and coalesce(measurement,'actual')='actual' then q else fuel_actual_ml end,
   fuel_estimated_ml=case when q is not null and measurement='estimated' then q else fuel_estimated_ml end
 where id=segment_id;
 if exists(select 1 from ops.session_segments where session_id=sid and energy_source='well_diesel'
     and coalesce(fuel_actual_ml,fuel_estimated_ml,0)>0) and nullif(p_facts->>'fuel_tank_id','') is null then
   raise exception 'historical_fuel_tank_required' using errcode='22023'; end if;
 if p_facts ? 'fuel_tank_id' and not exists(select 1 from inventory.fuel_tanks
    where id=(p_facts->>'fuel_tank_id')::uuid and well_id=p_well_id and status='active') then
   raise exception 'historical_fuel_tank_invalid' using errcode='22023'; end if;
 -- لا حقول مبلغ أو سعر تؤخذ من الوقائع؛ محاصيل الأصل تُطبّع بالقواعد القائمة.
 if jsonb_typeof(s->'crops') is distinct from 'array' then
   raise exception 'historical_crops_invalid' using errcode='22023'; end if;
 insert into ops.session_crops(session_id,crop_name,position)
 select sid,name,row_number() over(order by ord) from (
   select btrim(value) name,min(ordinality) ord from jsonb_array_elements_text(s->'crops') with ordinality
   where btrim(value)<>'' group by btrim(value)) q;
 result:=ops.finalize_session_from_closed_segments(sid,stop_time,(p_facts->>'fuel_tank_id')::uuid);
 perform sync.finish_command(o.tenant_id,completion_id,'accepted',result);
 return result;
end;$f$;

create or replace function sync.begin_session_command(
  p_session_id uuid,
  p_command_id uuid,
  p_command_type text,
  p_payload jsonb default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_serialized_well uuid;
  v_command_guard jsonb;
  v_tenant_id uuid;
begin
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  select w.tenant_id
  into v_tenant_id
  from ops.irrigation_sessions s
  join core.wells w
    on w.id = s.well_id
  where s.id = p_session_id
    and exists (
      select 1
      from core.well_assignments wa
      where wa.well_id = w.id
        and wa.profile_id = auth.uid()
        and wa.status = 'active'
    );

  if v_tenant_id is null then
    raise exception 'الجلسة غير موجودة أو لا تملك وصولًا إليها';
  end if;

  v_serialized_well:=(select well_id from ops.irrigation_sessions where id=p_session_id);
  if p_command_type in ('complete_irrigation_session','change_session_energy_source','resume_irrigation_session','pause_irrigation_session') then
   perform billing.enter_financial_write(v_serialized_well,null,null);
  else perform ops.lock_operational_scope(v_serialized_well);end if;
  if not exists(select 1 from core.wells w join core.well_assignments a on a.well_id=w.id
   where w.id=v_serialized_well and w.tenant_id=v_tenant_id and a.profile_id=auth.uid() and a.status='active') or not exists(select 1 from ops.irrigation_sessions where id=p_session_id and well_id=v_serialized_well) then
   raise exception 'command_scope_or_assignment_changed' using errcode='42501';end if;
  -- Well serialization makes this check authoritative after waiting. Never
  -- return a receipt for a different operation/entity sharing the command id.
  if exists(select 1 from sync.processed_commands pc
   where pc.tenant_id=v_tenant_id and pc.command_id=p_command_id
    and (pc.command_type is distinct from p_command_type
      or pc.entity_id is distinct from p_session_id)) then
   raise exception 'command_identity_conflict' using errcode='22023';end if;
  v_command_guard := sync.begin_command(
    v_tenant_id,
    p_command_id,
    p_command_type,
    p_payload,
    p_session_id
  );
  -- A tenant-wide id can also collide from a different well. ON CONFLICT in
  -- begin_command may have waited there; validate the durable identity again.
  if exists(select 1 from sync.processed_commands pc
   where pc.tenant_id=v_tenant_id and pc.command_id=p_command_id
    and (pc.command_type is distinct from p_command_type
      or pc.entity_id is distinct from p_session_id)) then
   raise exception 'command_identity_conflict' using errcode='22023';end if;
  return v_command_guard;
end;
$function$;

create or replace function sync.begin_well_command(
  p_well_id uuid,
  p_command_id uuid,
  p_command_type text,
  p_payload jsonb default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_serialized_well uuid;
  v_command_guard jsonb;
  v_tenant_id uuid;
begin
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id
    and exists (
      select 1
      from core.well_assignments wa
      where wa.well_id = w.id
        and wa.profile_id = auth.uid()
        and wa.status = 'active'
    );

  if v_tenant_id is null then
    raise exception 'البئر غير موجود أو لا تملك وصولًا إليه';
  end if;

  v_serialized_well:=p_well_id;
  if p_command_type in ('record_payment','create_farmer','resolve_farmer_identity') then
   perform billing.enter_financial_write(v_serialized_well,null,null);
  else perform ops.lock_operational_scope(v_serialized_well);end if;
  if not exists(select 1 from core.wells w join core.well_assignments a on a.well_id=w.id
   where w.id=v_serialized_well and w.tenant_id=v_tenant_id and a.profile_id=auth.uid() and a.status='active') then
   raise exception 'command_scope_or_assignment_changed' using errcode='42501';end if;
  -- Well serialization makes this check authoritative after waiting. Never
  -- return a receipt for a different operation/entity sharing the command id.
  if exists(select 1 from sync.processed_commands pc
   where pc.tenant_id=v_tenant_id and pc.command_id=p_command_id
    and (pc.command_type is distinct from p_command_type
      or pc.entity_id is distinct from null::uuid)) then
   raise exception 'command_identity_conflict' using errcode='22023';end if;
  v_command_guard := sync.begin_command(
    v_tenant_id,
    p_command_id,
    p_command_type,
    p_payload,
    null
  );
  -- A tenant-wide id can also collide from a different well. ON CONFLICT in
  -- begin_command may have waited there; validate the durable identity again.
  if exists(select 1 from sync.processed_commands pc
   where pc.tenant_id=v_tenant_id and pc.command_id=p_command_id
    and (pc.command_type is distinct from p_command_type
      or pc.entity_id is distinct from null::uuid)) then
   raise exception 'command_identity_conflict' using errcode='22023';end if;
  return v_command_guard;
end;
$function$;

create or replace function sync.begin_booking_completion_command(
  p_session_id uuid,
  p_ended_at timestamptz,
  p_fuel_quantity_ml bigint,
  p_fuel_measurement_type text,
  p_fuel_tank_id uuid,
  p_command_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant_id uuid;
  v_well_id uuid;
  v_payload jsonb;
  v_guard jsonb;
  v_stored_type text;
  v_stored_payload jsonb;
  v_status text;
  v_response jsonb;
  v_entity_id uuid;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إكمال جلسة محجوزة';
  end if;
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;

  select w.tenant_id, s.well_id
    into v_tenant_id, v_well_id
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
    and exists (
      select 1 from core.well_assignments wa
      where wa.well_id = s.well_id
        and wa.profile_id = v_actor
        and wa.status = 'active'
    );
  if v_tenant_id is null then
    raise exception 'الجلسة غير موجودة أو لا تملك وصولًا إليها';
  end if;
  if not iam.has_well_permission(v_well_id, 'session.complete') then
    raise exception 'لا تملك صلاحية إكمال جلسة على هذا البئر';
  end if;

  -- Prove a real booking association from server data; a free session must
  -- continue to use complete_irrigation_session, never this booking contract.
  if not exists (
    select 1 from ops.irrigation_sessions s
    join ops.irrigation_bookings b on b.id = s.booking_id
    join core.wells w on w.id = s.well_id
    join ops.farmer_well_accounts a on a.id = s.farmer_well_account_id
    where s.id = p_session_id and s.well_id = v_well_id
      and s.booking_id is not null and b.well_id = s.well_id
      and b.tenant_id = w.tenant_id and a.tenant_id = w.tenant_id
      and a.well_id = s.well_id and b.farmer_well_account_id = a.id
      and b.farm_id = s.farm_id
  ) then
    raise exception 'booking_completion_requires_booked_session' using errcode = '22023';
  end if;

  v_payload := jsonb_build_object(
    'booking_execution_contract_version', 113,
    'session_id', p_session_id,
    'ended_at', p_ended_at,
    'fuel_quantity_ml', p_fuel_quantity_ml,
    'fuel_measurement_type', p_fuel_measurement_type,
    'fuel_tank_id', p_fuel_tank_id
  );

  perform billing.enter_financial_write(v_well_id,'session.complete',null);
  if not coalesce(iam.has_well_permission(v_well_id,'session.complete'),false) then raise exception 'command_scope_authorization_changed' using errcode='42501';end if;
  v_guard := sync.begin_command(
    v_tenant_id,
    p_command_id,
    'complete_booking_session',
    v_payload,
    p_session_id
  );

  if not coalesce((v_guard ->> 'duplicate')::boolean, false) then
    return jsonb_build_object('duplicate', false, 'well_id', v_well_id);
  end if;

  select pc.command_type, pc.request_payload, pc.status, pc.response_payload, pc.entity_id
  into v_stored_type, v_stored_payload, v_status, v_response, v_entity_id
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant_id and pc.command_id = p_command_id;

  if not found
     or v_stored_type is distinct from 'complete_booking_session'
     or v_stored_payload is distinct from v_payload
     or v_entity_id is distinct from p_session_id then
    raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
  end if;

  return jsonb_build_object(
    'duplicate', true,
    'status', v_status,
    'response', v_response,
    'well_id', v_well_id
  );
end;
$function$;


-- Retired batch function was DROPPED by 052. Do not recreate a retired model.
-- core.merge_persons remains owner/maintenance-only: multi-well ordering deferred.
revoke all on function core.merge_persons(uuid,uuid,text,uuid) from public,anon,authenticated,service_role;
revoke all on function finance.reverse_journal_entry(uuid,text,uuid),
 ops.finalize_session_from_closed_segments(uuid,timestamptz,uuid),ops.materialize_historical_occurrence(uuid,uuid,uuid,jsonb)
 from public,anon,authenticated,service_role;
create or replace function ops.open_shift(p_well_id uuid, p_operator_profile_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'ops', 'core', 'finance', 'pg_temp'
as $$
declare
  v_shift_id uuid;
  v_tenant_id uuid;
  v_cashbox_id uuid;
begin
 perform billing.enter_financial_write(p_well_id,'shift.open',null);
  select tenant_id into v_tenant_id from core.wells where id = p_well_id;
  if v_tenant_id is null then
    raise exception 'البئر % غير موجود', p_well_id;
  end if;

  -- المناوبة تنطلق من الصندوق الحاكم: حيازة المشغل النشط، وإلا صندوق
  -- البئر العام كما كان (مناوبات يفتحها غير المشغل).
  if finance.is_active_operator_assignment(p_well_id, p_operator_profile_id) then
    v_cashbox_id := finance.ensure_operator_custody_cashbox(p_well_id, p_operator_profile_id);
  else
    v_cashbox_id := finance.main_cashbox_id(p_well_id);
  end if;

  insert into ops.shifts (tenant_id, well_id, operator_profile_id, cashbox_id)
  values (v_tenant_id, p_well_id, p_operator_profile_id, v_cashbox_id)
  returning id into v_shift_id;

  -- ربط الجلسات المنقولة المقبولة بالمناوبة الجديدة
  update ops.session_shift_transfers t
  set to_shift_id = v_shift_id
  where t.well_id = p_well_id
    and t.to_profile_id = p_operator_profile_id
    and t.status = 'accepted'
    and t.to_shift_id is null;

  update ops.irrigation_sessions s
  set current_shift_id = v_shift_id
  where s.id in (
    select t.session_id from ops.session_shift_transfers t
    where t.to_shift_id = v_shift_id and t.status = 'accepted'
  );

  perform ops.notify_well_owners(p_well_id, 'shift_opened',
    format('بدات مناوبة جديدة في البئر بواسطة المشغل %s', p_operator_profile_id));

  return v_shift_id;
end;
$$;
-- Owner decision: only system-created cashboxes; metadata rename only.
-- Business status, custody assignment, quantities and financial balance are internal.
create table finance.cashbox_name_history(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references core.tenants(id),
 well_id uuid not null references core.wells(id),cashbox_id uuid not null references finance.cashboxes(id),
 previous_name text not null,new_name text not null check(nullif(btrim(new_name),'') is not null),
 actor_id uuid not null references iam.profiles(id),accepted_at timestamptz not null default clock_timestamp()
);
alter table finance.cashbox_name_history enable row level security;
revoke all on finance.cashbox_name_history from public,anon,authenticated,service_role;
grant select on finance.cashbox_name_history to authenticated;
create policy cashbox_name_history_read on finance.cashbox_name_history for select
 using(iam.has_well_role(well_id,array['owner','manager','operator']) or iam.is_well_partner(well_id));
create trigger cashbox_name_history_immutable before update or delete on finance.cashbox_name_history
 for each row execute function finance.reject_distribution_source_history_mutation();
create function api.rename_cashbox(p_cashbox_id uuid,p_name text) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate finance.cashboxes%rowtype;c finance.cashboxes%rowtype;
begin
 select * into candidate from finance.cashboxes where id=p_cashbox_id;
 if candidate.id is null or auth.uid() is null or not coalesce(iam.has_well_role(candidate.well_id,array['owner','manager']),false) then
  raise exception 'cashbox_configuration_forbidden' using errcode='42501';end if;
 perform billing.enter_financial_write(candidate.well_id,null,array['owner','manager'],candidate.tenant_id);
 select * into strict c from finance.cashboxes where id=p_cashbox_id for update;
 if(c.well_id,c.tenant_id,c.cashbox_type,c.assigned_profile_id) is distinct from(candidate.well_id,candidate.tenant_id,candidate.cashbox_type,candidate.assigned_profile_id)
  or not coalesce(iam.has_well_role(c.well_id,array['owner','manager']),false) then
  raise exception 'cashbox_configuration_forbidden' using errcode='42501';end if;
 if nullif(btrim(p_name),'') is null then raise exception 'cashbox_name_required' using errcode='22023';end if;
 insert into finance.cashbox_name_history(tenant_id,well_id,cashbox_id,previous_name,new_name,actor_id)
 values(c.tenant_id,c.well_id,c.id,c.name,p_name,auth.uid());
 update finance.cashboxes set name=p_name where id=c.id;
 return jsonb_build_object('status','saved','cashbox_id',c.id,'name',p_name,'title','تم حفظ اسم الصندوق','action','عرض الصندوق');
end;$$;
revoke all on function api.rename_cashbox(uuid,text) from public,anon,authenticated,service_role;
grant execute on function api.rename_cashbox(uuid,text) to authenticated;
revoke insert,update,delete,truncate on finance.cashboxes from public,anon,authenticated,service_role;
do $cashbox_columns$ declare c record;begin
 for c in select attname from pg_attribute where attrelid='finance.cashboxes'::regclass and attnum>0 and not attisdropped loop
  execute format('revoke insert (%I),update (%I) on finance.cashboxes from public,anon,authenticated,service_role',c.attname,c.attname);
 end loop;
end;$cashbox_columns$;

-- Private child helper: no first root acquisition.
create or replace function billing.post_customer_credit_entry(p_event uuid,p_tenant uuid,p_well uuid,p_account uuid,
 p_amount bigint,p_issue boolean,p_posted_at timestamptz,p_actor uuid) returns uuid
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare j uuid;
begin
 perform billing.require_customer_credit_well_lock(p_well);
 if p_amount=0 then return null;end if;
 insert into finance.journal_entries(tenant_id,well_id,public_code,entry_date,source_type,source_id,description,idempotency_key)
 values(p_tenant,p_well,core.generate_public_code('JE'),p_posted_at,'customer_credit',p_event,
 'إعادة تصنيف غير نقدية لرصيد مزارع','CUSTOMER-CREDIT-'||p_event::text) returning id into j;
 insert into finance.journal_lines(tenant_id,journal_entry_id,ledger_account_id,entry_side,amount_minor,farmer_well_account_id,description)
 values(p_tenant,j,finance.ledger_account_id(p_well,'1100'),case when p_issue then 'debit' else 'credit' end,p_amount,p_account,'ذمة المزارع'),
 (p_tenant,j,finance.ledger_account_id(p_well,'2000'),case when p_issue then 'credit' else 'debit' end,p_amount,p_account,'رصيد مزارع غير نقدي');
 perform finance.post_journal_entry(j,p_actor);
 return j;
end;$$;

-- Private child helper: no first root acquisition.
create or replace function billing.post_session_correction_delta(p_correction uuid,p_invoice uuid,p_evidence jsonb,p_previous jsonb,
 p_posted_at timestamptz) returns uuid language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c ops.session_corrections%rowtype;i billing.invoices%rowtype;j uuid;x record;delta bigint;
begin
 perform billing.require_customer_credit_well_lock((select well_id from ops.session_corrections where id=p_correction));
 select * into strict c from ops.session_corrections where id=p_correction;
 select * into strict i from billing.invoices where id=p_invoice;
 if auth.uid() is null or not coalesce(iam.has_well_permission(c.well_id,'session.correct'),false)
  or (i.well_id,i.tenant_id,i.session_id) is distinct from(c.well_id,c.tenant_id,c.session_id) then
  raise exception 'session_financial_posting_forbidden' using errcode='42501';end if;
 for x in
  select ss.energy_source,sum((e.value->>'time_charge_minor')::bigint-coalesce(
    (old.value->>'time_charge_minor')::bigint,ss.time_charge_minor))::bigint as delta
  from jsonb_array_elements(p_evidence->'segments')e(value)
  join ops.session_segments ss on ss.id::text=e.value->>'segment_id' and ss.session_id=c.session_id
  left join lateral(select value from jsonb_array_elements(p_previous->'segments')
    where value->>'segment_id'=ss.id::text)old on true
  group by ss.energy_source
 loop
  delta:=x.delta;if delta=0 then continue;end if;
  if j is null then
   insert into finance.journal_entries(tenant_id,well_id,public_code,entry_date,source_type,source_id,description,idempotency_key)
   values(c.tenant_id,c.well_id,core.generate_public_code('JE'),p_posted_at,'session_correction',c.id,
    'Canonical session time correction','SESSION-CORRECTION-'||c.id::text) returning id into j;
  end if;
  insert into finance.journal_lines(tenant_id,journal_entry_id,ledger_account_id,entry_side,amount_minor,farmer_well_account_id)
  values(c.tenant_id,j,finance.ledger_account_id(c.well_id,'1100'),case when delta>0 then 'debit' else 'credit' end,abs(delta),i.farmer_well_account_id),
   (c.tenant_id,j,finance.ledger_account_id(c.well_id,case when x.energy_source='solar' then '4000' else '4100' end),
    case when delta>0 then 'credit' else 'debit' end,abs(delta),null);
 end loop;
 if j is not null then perform finance.post_journal_entry(j,auth.uid());end if;
 return j;
end;$$;

-- Private child helper: no first root acquisition.
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
 perform billing.require_customer_credit_well_lock(new.well_id);
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

-- Private child helper: no first root acquisition.
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
 perform billing.require_customer_credit_well_lock(new.well_id);
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

-- Private child helper: no first root acquisition.
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
 perform billing.require_customer_credit_well_lock(new.well_id);
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

-- Private child helper: no first root acquisition.
create or replace function finance.journalize_fuel_transaction()
returns trigger
language plpgsql
security definer
set search_path to 'finance', 'core', 'pg_temp'
as $function$
declare
  v_je uuid;
begin
 perform billing.require_customer_credit_well_lock(new.well_id);
  if new.status <> 'posted' or new.ownership_type <> 'well' then
    return new;
  end if;
  if new.transaction_type = 'opening_balance' then
    return new;
  end if;
  if new.total_cost_minor is null or new.total_cost_minor <= 0 then
    return new;
  end if;

  if new.transaction_type = 'purchase' and new.direction = 'in' then
    insert into finance.journal_entries (
      tenant_id, public_code, well_id, entry_date,
      source_type, source_id, description, idempotency_key
    ) values (
      new.tenant_id, core.generate_public_code('JE'), new.well_id,
      new.occurred_at, 'fuel_purchase', new.id, 'شراء ديزل',
      'FTX-' || new.id::text
    ) returning id into v_je;
    insert into finance.journal_lines (
      tenant_id, journal_entry_id, ledger_account_id, entry_side,
      amount_minor, fuel_tank_id, cashbox_id, description
    ) values
      (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1200'),
       'debit', new.total_cost_minor, new.fuel_tank_id, null, 'مخزون ديزل البئر'),
      (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1000'),
       'credit', new.total_cost_minor, null, finance.main_cashbox_id(new.well_id),
       'النقد والصناديق');

  elsif new.transaction_type = 'session_consumption' and new.direction = 'out' then
    insert into finance.journal_entries (
      tenant_id, public_code, well_id, entry_date,
      source_type, source_id, description, idempotency_key
    ) values (
      new.tenant_id, core.generate_public_code('JE'), new.well_id,
      new.occurred_at, 'fuel_consumption', new.id,
      'استهلاك ديزل في التشغيل', 'FTC-' || new.id::text
    ) returning id into v_je;
    insert into finance.journal_lines (
      tenant_id, journal_entry_id, ledger_account_id, entry_side,
      amount_minor, fuel_tank_id, description
    ) values
      (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '5000'),
       'debit', new.total_cost_minor, new.fuel_tank_id, 'تكلفة ديزل مستهلك'),
      (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1200'),
       'credit', new.total_cost_minor, new.fuel_tank_id, 'مخزون ديزل البئر');

  elsif new.transaction_type = 'physical_count' then
    insert into finance.journal_entries (
      tenant_id, public_code, well_id, entry_date,
      source_type, source_id, description, idempotency_key
    ) values (
      new.tenant_id, core.generate_public_code('JE'), new.well_id,
      new.occurred_at, 'fuel_physical_count', new.id,
      'فرق جرد فعلي للديزل', 'FPC-' || new.id::text
    ) returning id into v_je;

    if new.direction = 'out' then
      insert into finance.journal_lines (
        tenant_id, journal_entry_id, ledger_account_id, entry_side,
        amount_minor, fuel_tank_id, description
      ) values
        (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '5800'),
         'debit', new.total_cost_minor, new.fuel_tank_id, 'عجز جرد الديزل'),
        (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1200'),
         'credit', new.total_cost_minor, new.fuel_tank_id, 'تخفيض مخزون الديزل');
    else
      insert into finance.journal_lines (
        tenant_id, journal_entry_id, ledger_account_id, entry_side,
        amount_minor, fuel_tank_id, description
      ) values
        (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1200'),
         'debit', new.total_cost_minor, new.fuel_tank_id, 'زيادة مخزون الديزل'),
        (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '5800'),
         'credit', new.total_cost_minor, new.fuel_tank_id, 'زيادة ناتجة عن الجرد');
    end if;
  end if;

  if v_je is not null then
    perform finance.post_journal_entry(v_je, new.created_by);
  end if;
  return new;
end;
$function$;

create or replace function core.confirm_well_invitation(
  p_invitation_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_well_id uuid;
  v_row core.well_invitations;
  v_profile uuid;
  v_profile_count integer;
  v_partner_id uuid;
  v_partner_profile uuid;
  v_partner_count integer;
begin
 perform billing.enter_financial_write((select well_id from core.well_invitations where id=p_invitation_id),null,null);
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تأكيد الدعوة'
      using errcode = '28000';
  end if;

  select inv.well_id into v_well_id
  from core.well_invitations inv
  where inv.id = p_invitation_id;

  if v_well_id is null then
    raise exception 'الدعوة غير موجودة'
      using errcode = '22023';
  end if;

  if not iam.has_well_permission(v_well_id, 'team.manage') then
    raise exception 'تأكيد أعضاء هذا البئر متاح لمالكه'
      using errcode = '42501';
  end if;

  select inv.* into v_row
  from core.well_invitations inv
  where inv.id = p_invitation_id
  for update;

  if v_row.status = 'confirmed' then
    return jsonb_build_object(
      'contract', 'confirm_well_invitation',
      'version', 2,
      'outcome', 'already_confirmed',
      'invitation_id', v_row.id,
      'well_id', v_row.well_id,
      'role', v_row.role
    );
  end if;

  if v_row.acceptance_kind = 'new_no_auth' then
    if v_row.status = 'owner_confirmed_pending_account' then
      return jsonb_build_object(
        'contract', 'confirm_well_invitation',
        'version', 3,
        'outcome', 'owner_confirmed_pending_account',
        'invitation_id', v_row.id,
        'well_id', v_row.well_id,
        'role', v_row.role
      );
    end if;

    if v_row.status <> 'accepted_pending_owner'
       or v_row.accepted_profile_id is not null
    then
      raise exception 'دعوة العضو الجديد ليست بانتظار تأكيد المالك'
        using errcode = '42501';
    end if;

    select count(*) into v_profile_count
    from iam.profiles pr
    where core.normalize_phone(pr.phone) = v_row.normalized_phone;

    if v_profile_count > 0 then
      raise exception 'ظهر حساب لهذا الهاتف؛ استخدم مسار الحساب القائم'
        using errcode = '42501';
    end if;

    update core.well_invitations
    set status = 'owner_confirmed_pending_account',
        confirmed_by = v_actor,
        confirmed_at = now(),
        updated_at = now()
    where id = v_row.id;

    return jsonb_build_object(
      'contract', 'confirm_well_invitation',
      'version', 3,
      'outcome', 'owner_confirmed_pending_account',
      'invitation_id', v_row.id,
      'well_id', v_row.well_id,
      'role', v_row.role
    );
  end if;

  -- المسار التالي هو سلوك M103 للحساب القائم دون تغيير.
  if v_row.status <> 'accepted_pending_owner' then
    raise exception 'لا يمكن تأكيد دعوة غير مقبولة من الحساب'
      using errcode = '42501';
  end if;

  select pr.id into v_profile
  from iam.profiles pr
  where pr.id = v_row.accepted_profile_id
    and core.normalize_phone(pr.phone) = v_row.normalized_phone;

  if v_profile is null then
    raise exception 'الحساب المقبول لم يعد يطابق هوية الدعوة'
      using errcode = '42501';
  end if;

  if v_row.role = 'partner' then
    select count(*) into v_partner_count
    from core.well_partners wp
    where wp.well_id = v_row.well_id
      and wp.person_id = v_row.person_id
      and wp.status = 'active'
      and wp.period_end is null;

    if v_partner_count <> 1 then
      raise exception 'تعذر تحديد Partner الحالي الوحيد للدعوة'
        using errcode = 'P0001';
    end if;

    select wp.id, wp.profile_id into v_partner_id, v_partner_profile
    from core.well_partners wp
    where wp.well_id = v_row.well_id
      and wp.person_id = v_row.person_id
      and wp.status = 'active'
      and wp.period_end is null
    for update;

    if v_partner_profile is not null and v_partner_profile <> v_profile then
      raise exception 'Partner التاريخي مربوط بحساب آخر'
        using errcode = '42501';
    end if;
  end if;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_row.well_id, v_profile, v_row.role, 'active')
  on conflict (well_id, profile_id, role)
  do update set status = 'active', updated_at = now();

  if v_row.role = 'partner' then
    update core.well_partners wp
    set profile_id = v_profile,
        activated_at = coalesce(wp.activated_at, now()),
        updated_at = now()
    where wp.id = v_partner_id
      and wp.status = 'active'
      and wp.period_end is null;
  end if;

  update core.well_invitations
  set status = 'confirmed',
      confirmed_by = v_actor,
      confirmed_at = now(),
      updated_at = now()
  where id = v_row.id;

  return jsonb_build_object(
    'contract', 'confirm_well_invitation',
    'version', 2,
    'outcome', 'confirmed',
    'invitation_id', v_row.id,
    'well_id', v_row.well_id,
    'profile_id', v_profile,
    'role', v_row.role
  );
end;
$function$;

create or replace function core.invite_well_member(
  p_well_id uuid,
  p_role text,
  p_full_name text,
  p_phone text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant uuid;
  v_name text := btrim(coalesce(p_full_name, ''));
  v_phone text := btrim(coalesce(p_phone, ''));
  v_norm text;
  v_person uuid;
  v_candidate_person_ids uuid[];
  v_candidate_count integer;
  v_candidate_person_status text;
  v_code text;
  v_salt text;
  v_invitation uuid;
  v_expires timestamptz;
  v_existing core.well_invitations;
begin
 perform billing.enter_financial_write(p_well_id,null,null);
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل دعوة عضو'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if p_role is null or p_role not in ('operator', 'partner') then
    raise exception 'الدور المدعو غير مقبول: مشغّل أو شريك فقط'
      using errcode = '22023';
  end if;

  if v_name = '' then
    raise exception 'اسم العضو مطلوب'
      using errcode = '22023';
  end if;

  v_norm := core.normalize_phone(v_phone);
  if v_norm is null or v_norm = '' then
    raise exception 'رقم هاتف العضو مطلوب'
      using errcode = '22023';
  end if;

  if not iam.has_well_permission(p_well_id, 'team.manage') then
    raise exception 'إدارة فريق هذا البئر متاحة لمالكه'
      using errcode = '42501';
  end if;

  select w.tenant_id into v_tenant
  from core.wells w
  where w.id = p_well_id;

  if v_tenant is null then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  -- بعد القبول تتجمد الهوية المرشحة حتى يؤكدها المالك أو يرفضها.
  select inv.* into v_existing
  from core.well_invitations inv
  where inv.well_id = p_well_id
    and inv.role = p_role
    and inv.normalized_phone = v_norm
    and inv.status = 'accepted_pending_owner'
  order by inv.accepted_at desc
  limit 1
  for update;

  if v_existing.id is not null then
    return jsonb_build_object(
      'contract', 'invite_well_member',
      'version', 2,
      'outcome', 'accepted_pending_owner',
      'person_id', v_existing.person_id,
      'profile_id', v_existing.accepted_profile_id,
      'invitation_id', v_existing.id,
      'code', null,
      'expires_at', v_existing.expires_at
    );
  end if;

  -- صف confirmed يمنع دعوة جديدة فقط إذا كانت صلاحيته ما زالت فعالة. عند
  -- الإلغاء تبقى الدعوة التاريخية كما هي، وتبدأ دعوة جديدة بصفر وصول.
  select inv.* into v_existing
  from core.well_invitations inv
  join core.well_assignments wa
    on wa.well_id = inv.well_id
   and wa.profile_id = inv.accepted_profile_id
   and wa.role = inv.role
   and wa.status = 'active'
  where inv.well_id = p_well_id
    and inv.role = p_role
    and inv.normalized_phone = v_norm
    and inv.status = 'confirmed'
  order by inv.confirmed_at desc
  limit 1;

  if v_existing.id is not null then
    return jsonb_build_object(
      'contract', 'invite_well_member',
      'version', 2,
      'outcome', 'already_confirmed',
      'person_id', v_existing.person_id,
      'profile_id', v_existing.accepted_profile_id,
      'invitation_id', v_existing.id,
      'code', null,
      'expires_at', null
    );
  end if;

  -- الهاتف التاريخي قد يشير إلى أكثر من Person، بما في ذلك Person غير
  -- فعّال أو مدموج. لا نرتّب المرشحين ولا نعيد إحياء الهوية؛ كل تعارض أو
  -- حالة تاريخية غير فعّالة تحتاج مراجعة بشرية ولا تخلق هوية أو صلاحية.
  select array_agg(distinct candidate.person_id) into v_candidate_person_ids
  from (
    select pc.person_id
    from core.person_contacts pc
    where pc.tenant_id = v_tenant
      and core.normalize_phone(pc.normalized_value) = v_norm
    union all
    select wp.person_id
    from core.well_partners wp
    where wp.well_id = p_well_id
      and core.normalize_phone(wp.phone) = v_norm
  ) candidate
  join core.persons pe on pe.id = candidate.person_id;

  v_candidate_count := coalesce(array_length(v_candidate_person_ids, 1), 0);

  if v_candidate_count = 0 then
    insert into core.persons (
      tenant_id, full_name, normalized_name, created_by, updated_by
    ) values (
      v_tenant, v_name, core.normalize_arabic(v_name), v_actor, v_actor
    ) returning id into v_person;

    insert into core.person_contacts (
      tenant_id, person_id, contact_type, contact_value,
      normalized_value, is_primary
    ) values (
      v_tenant, v_person, 'mobile', v_phone, v_norm, true
    );
  elsif v_candidate_count = 1 then
    v_person := v_candidate_person_ids[1];
    select pe.status into v_candidate_person_status
    from core.persons pe
    where pe.id = v_person;

    if v_candidate_person_status <> 'active' then
      raise exception 'هوية رقم هاتف الدعوة تحتاج مراجعة بشرية'
        using errcode = 'P0001';
    end if;
  else
    raise exception 'هوية رقم هاتف الدعوة تحتاج مراجعة بشرية'
      using errcode = 'P0001';
  end if;

  -- قبل القبول فقط يمكن إعادة الإصدار وإبطال الصف القديم.
  update core.well_invitations
  set status = 'revoked',
      revoked_at = now(),
      updated_at = now()
  where well_id = p_well_id
    and role = p_role
    and normalized_phone = v_norm
    and status = 'invited';

  v_code := core.new_invitation_code();
  v_salt := replace(gen_random_uuid()::text, '-', '');
  v_expires := now() + interval '14 days';

  insert into core.well_invitations (
    tenant_id, well_id, role, person_id, phone, normalized_phone,
    code_salt, code_hash, expires_at, invited_by
  ) values (
    v_tenant, p_well_id, p_role, v_person, v_phone, v_norm,
    v_salt, core.hash_invitation_code(v_code, v_salt), v_expires, v_actor
  ) returning id into v_invitation;

  return jsonb_build_object(
    'contract', 'invite_well_member',
    'version', 2,
    'outcome', 'invited',
    'person_id', v_person,
    'profile_id', null,
    'invitation_id', v_invitation,
    'code', v_code,
    'expires_at', v_expires
  );
end;
$function$;

create or replace function core.revoke_well_member(
  p_well_id uuid,
  p_role text,
  p_phone text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_norm text;
  v_invitations integer := 0;
  v_assignments integer := 0;
begin
 perform billing.enter_financial_write(p_well_id,null,null);
  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if p_role is null or p_role not in ('operator', 'partner') then
    raise exception 'الدور غير مقبول: مشغّل أو شريك فقط'
      using errcode = '22023';
  end if;

  v_norm := core.normalize_phone(btrim(coalesce(p_phone, '')));
  if v_norm is null or v_norm = '' then
    raise exception 'رقم هاتف العضو مطلوب'
      using errcode = '22023';
  end if;

  if not iam.has_well_permission(p_well_id, 'team.manage') then
    raise exception 'إدارة فريق هذا البئر متاحة لمالكه'
      using errcode = '42501';
  end if;

  update core.well_invitations
  set status = 'revoked',
      revoked_at = now(),
      updated_at = now()
  where well_id = p_well_id
    and role = p_role
    and normalized_phone = v_norm
    and status = 'invited';

  get diagnostics v_invitations = row_count;

  -- التعيين النافذ يُوسم inactive: لا حذف، فالسجل المالي لا يُمسّ.
  update core.well_assignments wa
  set status = 'inactive',
      updated_at = now()
  where wa.well_id = p_well_id
    and wa.role = p_role
    and wa.status = 'active'
    and wa.profile_id in (
      select pr.id
      from iam.profiles pr
      where pr.phone is not null
        and core.normalize_phone(pr.phone) = v_norm
    );

  get diagnostics v_assignments = row_count;

  return jsonb_build_object(
    'contract', 'revoke_well_member',
    'version', 1,
    'revoked_invitations', v_invitations,
    'deactivated_assignments', v_assignments
  );
end;
$function$;

create or replace function core.complete_member_finalization(
  p_continuation_token text,
  p_profile_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_token text := btrim(coalesce(p_continuation_token, ''));
  v_ids uuid[];
  v_inv core.well_invitations;
  v_completed core.well_invitations;
  v_profile_count integer;
  v_link_count integer;
  v_partner_count integer;
  v_partner_id uuid;
  v_partner_profile uuid;
  v_rows integer;
begin
  if p_profile_id is null then
    raise exception 'profile الجديد مطلوب'
      using errcode = '22023';
  end if;

  -- idempotency بعد استهلاك token: لا أثر جديد، ويقبل profile المكتمل نفسه.
  select inv.* into v_completed
  from core.well_invitations inv
  where inv.status = 'confirmed'
    and inv.acceptance_kind = 'new_no_auth'
    and inv.accepted_profile_id = p_profile_id
    and exists (
      select 1
      from iam.profile_person_links l
      where l.tenant_id = inv.tenant_id
        and l.profile_id = p_profile_id
        and l.person_id = inv.person_id
        and l.revoked_at is null
    )
    and exists (
      select 1
      from core.well_assignments wa
      where wa.well_id = inv.well_id
        and wa.profile_id = p_profile_id
        and wa.role = inv.role
        and wa.status = 'active'
    )
  order by inv.updated_at desc
  limit 1;

  if v_completed.id is not null then
    return jsonb_build_object(
      'contract', 'complete_member_finalization',
      'version', 1,
      'outcome', 'already_completed'
    );
  end if;

  if length(v_token) < 48 or length(v_token) > 256 then
    raise exception 'token الاستمرار غير صالح'
      using errcode = '42501';
  end if;

  select array_agg(inv.id) into v_ids
  from core.well_invitations inv
  where inv.status = 'owner_confirmed_pending_account'
    and inv.acceptance_kind = 'new_no_auth'
    and inv.accepted_profile_id is null
    and inv.continuation_expires_at > now()
    and inv.continuation_token_hash =
      core.hash_member_finalization_token(
        v_token,
        inv.continuation_token_salt
      );

  if coalesce(cardinality(v_ids), 0) <> 1 then
    raise exception 'token الاستمرار غير صالح أو ملتبس'
      using errcode = '42501';
  end if;

  perform billing.enter_financial_write((select well_id from core.well_invitations where id=v_ids[1]),null,null);
  select inv.* into v_inv
  from core.well_invitations inv
  where inv.id = v_ids[1]
  for update;

  if v_inv.status <> 'owner_confirmed_pending_account'
     or v_inv.acceptance_kind <> 'new_no_auth'
     or v_inv.accepted_profile_id is not null
     or v_inv.continuation_expires_at <= now()
     or v_inv.continuation_token_hash <>
       core.hash_member_finalization_token(
         v_token,
         v_inv.continuation_token_salt
       )
  then
    -- قد تكون معاملة متزامنة أكملت الصف أثناء انتظار القفل.
    select inv.* into v_completed
    from core.well_invitations inv
    where inv.status = 'confirmed'
      and inv.acceptance_kind = 'new_no_auth'
      and inv.accepted_profile_id = p_profile_id
    order by inv.updated_at desc
    limit 1;

    if v_completed.id is not null then
      return jsonb_build_object(
        'contract', 'complete_member_finalization',
        'version', 1,
        'outcome', 'already_completed'
      );
    end if;

    raise exception 'حالة finalization تغيرت'
      using errcode = '40001';
  end if;

  perform 1
  from core.persons pe
  where pe.id = v_inv.person_id
    and pe.tenant_id = v_inv.tenant_id
    and pe.status = 'active'
  for update;

  if not found then
    raise exception 'هوية الدعوة تحتاج مراجعة بشرية'
      using errcode = 'P0001';
  end if;

  perform 1
  from iam.profiles pr
  where pr.id = p_profile_id
  for update;

  if not found then
    raise exception 'ملف Auth الجديد غير موجود'
      using errcode = '42501';
  end if;

  select count(*) into v_profile_count
  from iam.profiles pr
  where core.normalize_phone(pr.phone) = v_inv.normalized_phone;

  if v_profile_count <> 1
     or not exists (
       select 1
       from iam.profiles pr
       where pr.id = p_profile_id
         and core.normalize_phone(pr.phone) = v_inv.normalized_phone
     )
  then
    raise exception 'Profile الجديد لا يطابق هاتف الدعوة أو الهاتف مكرر'
      using errcode = '42501';
  end if;

  select count(*) into v_link_count
  from iam.profile_person_links l
  where l.revoked_at is null
    and (
      l.profile_id = p_profile_id
      or l.person_id = v_inv.person_id
    );

  if v_link_count <> 0 then
    raise exception 'يوجد رابط Profile/Person متعارض'
      using errcode = '42501';
  end if;

  if v_inv.role = 'partner' then
    select count(*) into v_partner_count
    from core.well_partners wp
    where wp.well_id = v_inv.well_id
      and wp.person_id = v_inv.person_id
      and wp.status = 'active'
      and wp.period_end is null;

    if v_partner_count <> 1 then
      raise exception 'تعذر تحديد Partner المالي الحالي الوحيد'
        using errcode = 'P0001';
    end if;

    select wp.id, wp.profile_id into v_partner_id, v_partner_profile
    from core.well_partners wp
    where wp.well_id = v_inv.well_id
      and wp.person_id = v_inv.person_id
      and wp.status = 'active'
      and wp.period_end is null
    for update;

    if v_partner_profile is not null then
      raise exception 'Partner المالي الحالي مربوط بحساب آخر'
        using errcode = '42501';
    end if;
  end if;

  insert into iam.profile_person_links (
    tenant_id, profile_id, person_id,
    linked_by, link_reason
  ) values (
    v_inv.tenant_id, p_profile_id, v_inv.person_id,
    v_inv.confirmed_by, 'm104_member_finalization'
  );

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_inv.well_id, p_profile_id, v_inv.role, 'active')
  on conflict (well_id, profile_id, role)
  do update set status = 'active', updated_at = now();

  if v_inv.role = 'partner' then
    update core.well_partners wp
    set profile_id = p_profile_id,
        activated_at = coalesce(wp.activated_at, now()),
        updated_at = now()
    where wp.id = v_partner_id
      and wp.status = 'active'
      and wp.period_end is null
      and wp.profile_id is null;
    get diagnostics v_rows = row_count;

    if v_rows <> 1 then
      raise exception 'Partner المالي تغير أثناء finalization'
        using errcode = '40001';
    end if;
  end if;

  update core.well_invitations
  set accepted_profile_id = p_profile_id,
      status = 'confirmed',
      continuation_token_salt = null,
      continuation_token_hash = null,
      continuation_expires_at = null,
      updated_at = now()
  where id = v_inv.id
    and status = 'owner_confirmed_pending_account'
    and acceptance_kind = 'new_no_auth';
  get diagnostics v_rows = row_count;

  if v_rows <> 1 then
    raise exception 'الدعوة تغيرت أثناء finalization'
      using errcode = '40001';
  end if;

  return jsonb_build_object(
    'contract', 'complete_member_finalization',
    'version', 1,
    'outcome', 'confirmed'
  );
end;
$function$;

create or replace function finance.ensure_operator_custody_cashbox(
  p_well_id uuid,
  p_profile_id uuid
)
returns uuid
language plpgsql
volatile
security definer
set search_path to 'finance', 'core', 'iam', 'pg_temp'
as $$
declare
  v_tenant_id uuid;
  v_cashbox_id uuid;
  v_name text;
begin
 perform billing.require_customer_credit_well_lock(p_well_id);
  select w.tenant_id into v_tenant_id from core.wells w where w.id = p_well_id;
  if v_tenant_id is null then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;
  if not finance.is_active_operator_assignment(p_well_id, p_profile_id) then
    raise exception 'لا يوجد تعيين مشغل نشط للملف % في البئر %', p_profile_id, p_well_id;
  end if;

  select c.id into v_cashbox_id
  from finance.cashboxes c
  where c.well_id = p_well_id
    and c.assigned_profile_id = p_profile_id
    and c.cashbox_type = 'operator_custody'
    and c.status = 'active'
  limit 1;
  if v_cashbox_id is not null then
    return v_cashbox_id;
  end if;

  select 'حيازة نقد المشغل ' || p.full_name into v_name
  from iam.profiles p
  where p.id = p_profile_id;

  begin
    insert into finance.cashboxes (
      tenant_id, well_id, name, cashbox_type, assigned_profile_id
    ) values (
      v_tenant_id, p_well_id, v_name, 'operator_custody', p_profile_id
    ) returning id into v_cashbox_id;
  exception when unique_violation then
    -- نداء متوازٍ سبقنا: الصندوق موجود بالفعل، نعيد قراءته ولا نكرر.
    select c.id into v_cashbox_id
    from finance.cashboxes c
    where c.well_id = p_well_id
      and c.assigned_profile_id = p_profile_id
      and c.cashbox_type = 'operator_custody'
      and c.status = 'active'
    limit 1;
    if v_cashbox_id is null then
      raise exception 'تعذر ضمان صندوق حيازة المشغل دون تكرار';
    end if;
  end;

  return v_cashbox_id;
end;
$$;

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
 perform billing.require_customer_credit_well_lock(new.well_id);
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

create or replace function inventory.bridge_fuel_purchase()
returns trigger
language plpgsql
security definer
set search_path to 'inventory', 'core', 'pg_temp'
as $$
declare
  v_tenant uuid;
begin
 perform billing.require_customer_credit_well_lock(new.well_id);
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

create or replace function billing.refresh_effective_invoice(p_invoice uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare b record;s text;
begin
 perform billing.require_customer_credit_well_lock((select well_id from billing.invoices where id=p_invoice));
 select status into s from billing.invoices where id=p_invoice for update;
 select * into strict b from billing.invoice_effective_balances where invoice_id=p_invoice;
 if b.paid_minor<0 or b.outstanding_minor<0 then
  raise exception 'effective_invoice_allocation_out_of_range' using errcode='23514';end if;
 update billing.invoices set correction_total_delta_minor=b.total_minor-(select total_minor from billing.invoices where id=p_invoice),
 paid_minor=b.paid_minor,outstanding_minor=b.outstanding_minor,
 status=case when s in ('draft','cancelled','reversed') then s when b.outstanding_minor=0 then 'paid'
  when b.paid_minor>0 then 'partially_paid' when s='overdue' then s else 'issued' end where id=p_invoice;
end;$$;

create or replace function billing.refresh_partition_invoices(p_well uuid) returns void
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare i uuid;
begin
 perform billing.require_customer_credit_well_lock(p_well);
 for i in select id from billing.invoices where well_id=p_well and status not in ('draft','cancelled','reversed') order by id for update loop
  if exists(select 1 from billing.invoices x join billing.invoice_effective_balances b on b.invoice_id=x.id
   where x.id=i and ((x.paid_minor,x.outstanding_minor) is distinct from (b.paid_minor,b.outstanding_minor)
    or(b.outstanding_minor=0 and x.status<>'paid') or(b.outstanding_minor>0 and b.paid_minor>0 and x.status<>'partially_paid')
    or(b.paid_minor=0 and x.status in ('paid','partially_paid')))) then
   perform billing.refresh_effective_invoice(i);end if;
 end loop;
end;$$;

create or replace function billing.invalidate_pending_credit_distributions(p_well uuid) returns jsonb
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 with boundary as materialized(select billing.require_customer_credit_well_lock(p_well)), invalidated as (
  update finance.profit_distribution_cycles set status='cancelled'
   where well_id=p_well and status in ('draft','calculated','under_review') and exists(select 1 from boundary) returning id)
 select coalesce(jsonb_agg(id order by id),'[]') from invalidated;
$$;

create or replace function finance.capture_expense_approval_context() returns trigger language plpgsql security definer
set search_path=pg_catalog,pg_temp as $$
declare ctx jsonb;
begin
 perform billing.require_customer_credit_well_lock(new.well_id);
 ctx:=finance.expense_approval_context(new.well_id,new.category_id,new.amount_minor);
 if ctx->>'configuration_id' is not null and new.status in ('posted','pending_approval')
  and new.status<>ctx->>'initial_status' then
  raise exception 'expense_approval_context_mismatch' using errcode='23514';end if;
 insert into finance.expense_approval_contexts(expense_id,tenant_id,well_id,configuration_id,source,category_id,amount_minor,
 matched_rules,requires_approval,initial_status)
 values(new.id,new.tenant_id,new.well_id,(ctx->>'configuration_id')::uuid,ctx->>'source',new.category_id,new.amount_minor,
 ctx->'matched_rules',(ctx->>'requires_approval')::boolean,new.status);
 return new;
end;$$;

create or replace function ops.declare_operator_cash_remittance_for_well(
  p_well_id uuid,
  p_operator_profile_id uuid,
  p_amount_minor bigint,
  p_note text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path to 'ops', 'core', 'finance', 'pg_temp'
as $$
declare
  v_tenant_id uuid;
  v_custody_id uuid;
  v_main_cashbox uuid;
  v_balance bigint;
  v_id uuid;
begin
 perform billing.enter_financial_write(p_well_id,'handover.declare',null);
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'مبلغ الترحيل يجب أن يكون أكبر من صفر';
  end if;

  select w.tenant_id into v_tenant_id from core.wells w where w.id = p_well_id;
  if v_tenant_id is null then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  -- تعيين مشغل نشط على هذا البئر شرط، والحيازة تُضمن له (م-109):
  -- لا حيازة لغير المشغل النشط مهما كانت صلاحياته المالية.
  if not finance.is_active_operator_assignment(p_well_id, p_operator_profile_id) then
    raise exception 'لا يوجد تعيين مشغل نشط للملف % في البئر %', p_operator_profile_id, p_well_id;
  end if;
  v_custody_id := finance.ensure_operator_custody_cashbox(p_well_id, p_operator_profile_id);

  v_main_cashbox := finance.main_cashbox_id(p_well_id);
  if v_main_cashbox is null or not exists (
    select 1 from finance.cashboxes c
    where c.id = v_main_cashbox and c.well_id = p_well_id and c.status = 'active'
  ) then
    raise exception 'صندوق البئر العام غير موجود أو غير فعال — لا وجهة للترحيل';
  end if;

  -- الحيازة من دفتر الحسابات حصرًا: لا إقرار فوق المتوفر.
  select finance.cashbox_balance_minor(v_custody_id) into v_balance;
  if v_balance < p_amount_minor then
    raise exception 'مبلغ الترحيل % يتجاوز حيازة المشغل الحالية % — لا يُقرَّر ترحيل فوق المتوفر', p_amount_minor, v_balance;
  end if;

  -- إقرار بلا نوبة: shift_id = null من النوع الصريح، بلا قيد يومية —
  -- تأكيد المالك في م-109 هو سلطة القيد المحاسبي وحدها.
  insert into ops.shift_handovers (
    tenant_id, well_id, shift_id, from_profile_id,
    to_description, declared_amount_minor, note,
    handover_kind, from_cashbox_id, to_cashbox_id
  ) values (
    v_tenant_id, p_well_id, null, p_operator_profile_id,
    'ترحيل إلى صندوق البئر العام', p_amount_minor, p_note,
    'operator_cash_remittance', v_custody_id, v_main_cashbox
  ) returning id into v_id;

  perform ops.notify_well_owners(p_well_id, 'handover_declared',
    format('أقر المشغل بترحيل مبلغ %s ريال من حيازته إلى صندوق البئر - بانتظار تأكيدك', p_amount_minor));

  return v_id;
end;
$$;

create or replace function ops.declare_handover(
  p_shift_id uuid,
  p_amount_minor bigint,
  p_to_profile_id uuid default null,
  p_to_description text default null,
  p_note text default null
) returns uuid
language plpgsql
security definer
set search_path to 'ops', 'pg_temp'
as $$
declare
  v_shift record;
  v_id uuid;
begin
 perform billing.enter_financial_write((select well_id from ops.shifts where id=p_shift_id),'handover.declare',null);
  select * into v_shift from ops.shifts where id = p_shift_id;
  if v_shift.id is null then
    raise exception 'المناوبة % غير موجودة', p_shift_id;
  end if;
  if p_to_profile_id is null and p_to_description is null then
    raise exception 'يجب تحديد من تم تسليمه المبلغ (شخص من النظام او ملاحظة نصية)';
  end if;

  insert into ops.shift_handovers (
    tenant_id, well_id, shift_id, from_profile_id, to_profile_id, to_description,
    declared_amount_minor, note
  ) values (
    v_shift.tenant_id, v_shift.well_id, p_shift_id, v_shift.operator_profile_id,
    p_to_profile_id, p_to_description, p_amount_minor, p_note
  ) returning id into v_id;

  perform ops.notify_well_owners(v_shift.well_id, 'handover_declared',
    format('اقر المشغل بتسليم مبلغ %s ريال - بانتظار تاكيدك (%s)', p_amount_minor, coalesce(p_to_description, 'مستلم مسجل')));

  if p_to_profile_id is not null then
    perform ops.notify_profile(p_to_profile_id, v_shift.well_id, 'handover_declared',
      format('المشغل يقر بتسليمك مبلغ %s ريال', p_amount_minor));
  end if;

  return v_id;
end;
$$;

-- Private helpers remain callable by their definer-owned trigger/RPC callers.
do $internal$ declare f record;begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where
  (n.nspname='finance' and p.proname in ('ensure_operator_custody_cashbox','create_default_ledger_accounts','create_default_expense_categories','write_draft_opening_item','capture_expense_approval_context'))
  or(n.nspname='billing' and p.proname in ('refresh_effective_invoice','refresh_partition_invoices','invalidate_pending_credit_distributions','post_customer_credit_entry','post_session_correction_delta')) loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.signature);
 end loop;
end;$internal$;
create or replace function core.create_tenant_with_well(
  p_tenant_name text,
  p_well_name text
)
returns uuid
language plpgsql
security definer
set search_path to 'core', 'pg_temp'
as $function$
declare
  v_user_id uuid;
  v_tenant_id uuid;
  v_well_id uuid;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء جهة وبئر';
  end if;

  if not exists (select 1 from iam.profiles p where p.id = v_user_id) then
    raise exception 'لا يوجد ملف مستخدم صالح للحساب المسجل';
  end if;

  if nullif(btrim(p_tenant_name), '') is null then
    raise exception 'اسم الجهة مطلوب';
  end if;

  if nullif(btrim(p_well_name), '') is null then
    raise exception 'اسم البئر مطلوب';
  end if;

  insert into core.tenants (name)
  values (btrim(p_tenant_name))
  returning id into v_tenant_id;

  v_well_id:=gen_random_uuid();
  perform billing.lock_customer_credit_well(v_well_id);
  insert into core.wells (id, tenant_id, name)
  values (v_well_id, v_tenant_id, btrim(p_well_name));

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well_id, v_user_id, 'owner', 'active');

  return v_well_id;
end;
$function$;

create or replace function core.setup_well_full(
  p_setup_data jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'core', 'ops', 'iam', 'pg_temp'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_owner_profile record;
  v_tenant_id uuid;
  v_well_id uuid;
  v_well_name text;
  v_location text;
  v_pump_name text;
  v_power_source text;
  v_ps_id uuid;
  v_solar_rate bigint;
  v_well_diesel_rate bigint;
  v_farmer_diesel_rate bigint;
  v_owner_equity numeric;
  v_owner_profit numeric;
  v_owner_person_id uuid;
  v_owner_partner_id uuid;
  v_partner jsonb;
  v_partner_person_id uuid;
  v_partner_id uuid;
  v_operator jsonb;
  v_op_person_id uuid;
  v_op_profile_id uuid;
begin
  if v_user_id is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء وتجهيز البئر' using errcode = '28000';
  end if;

  select * into v_owner_profile
  from iam.profiles
  where id = v_user_id;

  if v_owner_profile is null then
    raise exception 'لا يوجد ملف مستخدم صالح للحساب المسجل' using errcode = 'P0002';
  end if;

  v_well_name := btrim(coalesce(p_setup_data->>'well_name', ''));
  if v_well_name = '' then
    raise exception 'اسم البئر مطلوب' using errcode = '22023';
  end if;

  v_location := nullif(btrim(coalesce(p_setup_data->>'location', '')), '');

  -- 1) إنشاء الجهة والبئر
  insert into core.tenants (name)
  values (v_well_name)
  returning id into v_tenant_id;

  v_well_id:=gen_random_uuid();
  perform billing.lock_customer_credit_well(v_well_id);
  insert into core.wells (id, tenant_id, name, location)
  values (v_well_id, v_tenant_id, v_well_name, v_location);

  -- 2) تعيين المالك على البئر
  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well_id, v_user_id, 'owner', 'active');

  -- 3) إضافة المضخة الأساسية
  v_pump_name := coalesce(nullif(btrim(p_setup_data->>'pump_name'), ''), 'المضخة الرئيسية');
  v_power_source := coalesce(nullif(btrim(p_setup_data->>'pump_power_source'), ''), 'diesel');
  if v_power_source not in ('diesel', 'electric', 'solar') then
    v_power_source := 'diesel';
  end if;

  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_id, v_pump_name, v_power_source, 'active');

  -- 4) جدول التسعير الافتراضي
  v_solar_rate := (p_setup_data->'pricing'->>'solar_rate_minor')::bigint;
  v_well_diesel_rate := (p_setup_data->'pricing'->>'well_diesel_rate_minor')::bigint;
  v_farmer_diesel_rate := (p_setup_data->'pricing'->>'farmer_diesel_rate_minor')::bigint;

  insert into ops.price_schedules (
    tenant_id, well_id, name, effective_period, status, approved_by
  ) values (
    v_tenant_id, v_well_id, 'الجدول الافتراضي للتسعير',
    tstzrange(now() - interval '1 hour', null), 'active', v_user_id
  ) returning id into v_ps_id;

  if v_solar_rate is not null and v_solar_rate > 0 then
    insert into ops.price_rules (
      tenant_id, price_schedule_id, energy_source, hourly_rate_minor
    ) values (
      v_tenant_id, v_ps_id, 'solar', v_solar_rate
    );
  end if;

  if v_well_diesel_rate is not null and v_well_diesel_rate > 0 then
    insert into ops.price_rules (
      tenant_id, price_schedule_id, energy_source, diesel_pricing_model, hourly_rate_minor
    ) values (
      v_tenant_id, v_ps_id, 'well_diesel', 'inclusive_hourly', v_well_diesel_rate
    );
  end if;

  if v_farmer_diesel_rate is not null and v_farmer_diesel_rate > 0 then
    insert into ops.price_rules (
      tenant_id, price_schedule_id, energy_source, hourly_rate_minor
    ) values (
      v_tenant_id, v_ps_id, 'farmer_diesel', v_farmer_diesel_rate
    );
  end if;

  -- 5) إنشاء سجل شخص وشريك للمالك وحصته
  v_owner_equity := coalesce((p_setup_data->>'owner_equity_share')::numeric, 100.0);
  v_owner_profit := coalesce((p_setup_data->>'owner_profit_share')::numeric, v_owner_equity);

  insert into core.persons (
    tenant_id, full_name, normalized_name, created_by, updated_by
  ) values (
    v_tenant_id, v_owner_profile.full_name, v_owner_profile.full_name, v_user_id, v_user_id
  ) returning id into v_owner_person_id;

  if v_owner_profile.phone is not null and v_owner_profile.phone <> '' then
    insert into core.person_contacts (
      tenant_id, person_id, contact_type, contact_value, normalized_value, is_primary
    ) values (
      v_tenant_id, v_owner_person_id, 'mobile', v_owner_profile.phone, v_owner_profile.phone, true
    );
  end if;

  insert into core.well_partners (
    tenant_id, well_id, person_id, profile_id, phone, status, period_start
  ) values (
    v_tenant_id, v_well_id, v_owner_person_id, v_user_id,
    coalesce(v_owner_profile.phone, ''), 'active', current_date
  ) returning id into v_owner_partner_id;

  insert into core.ownership_share_versions (
    tenant_id, well_id, partner_id, ownership_percentage, profit_percentage,
    effective_period, approved_by
  ) values (
    v_tenant_id, v_well_id, v_owner_partner_id, v_owner_equity, v_owner_profit,
    daterange(current_date, null), v_user_id
  );

  -- 6) الشركاء الإضافيون
  if p_setup_data->'partners' is not null and jsonb_typeof(p_setup_data->'partners') = 'array' then
    for v_partner in select * from jsonb_array_elements(p_setup_data->'partners') loop
      declare
        v_p_name text := btrim(coalesce(v_partner->>'full_name', ''));
        v_p_phone text := btrim(coalesce(v_partner->>'phone', ''));
        v_p_equity numeric := coalesce((v_partner->>'equity_share')::numeric, 0);
        v_p_profit numeric := coalesce((v_partner->>'profit_share')::numeric, v_p_equity);
      begin
        if v_p_name <> '' and v_p_equity > 0 then
          insert into core.persons (
            tenant_id, full_name, normalized_name, created_by, updated_by
          ) values (
            v_tenant_id, v_p_name, v_p_name, v_user_id, v_user_id
          ) returning id into v_partner_person_id;

          if v_p_phone <> '' then
            insert into core.person_contacts (
              tenant_id, person_id, contact_type, contact_value, normalized_value, is_primary
            ) values (
              v_tenant_id, v_partner_person_id, 'mobile', v_p_phone, v_p_phone, true
            );
          end if;

          insert into core.well_partners (
            tenant_id, well_id, person_id, phone, status, period_start
          ) values (
            v_tenant_id, v_well_id, v_partner_person_id, v_p_phone, 'active', current_date
          ) returning id into v_partner_id;

          insert into core.ownership_share_versions (
            tenant_id, well_id, partner_id, ownership_percentage, profit_percentage,
            effective_period, approved_by
          ) values (
            v_tenant_id, v_well_id, v_partner_id, v_p_equity, v_p_profit,
            daterange(current_date, null), v_user_id
          );
        end if;
      end;
    end loop;
  end if;

  -- 7) المشغلون
  if p_setup_data->'operators' is not null and jsonb_typeof(p_setup_data->'operators') = 'array' then
    for v_operator in select * from jsonb_array_elements(p_setup_data->'operators') loop
      declare
        v_op_name text := btrim(coalesce(v_operator->>'full_name', ''));
        v_op_phone text := btrim(coalesce(v_operator->>'phone', ''));
      begin
        if v_op_name <> '' then
          insert into core.persons (
            tenant_id, full_name, normalized_name, created_by, updated_by
          ) values (
            v_tenant_id, v_op_name, v_op_name, v_user_id, v_user_id
          ) returning id into v_op_person_id;

          if v_op_phone <> '' then
            insert into core.person_contacts (
              tenant_id, person_id, contact_type, contact_value, normalized_value, is_primary
            ) values (
              v_tenant_id, v_op_person_id, 'mobile', v_op_phone, v_op_phone, true
            );

            -- فحص إذا كان للمشغل حساب دخول مسبق لربطه في well_assignments
            select id into v_op_profile_id
            from iam.profiles
            where phone = v_op_phone
            limit 1;

            if v_op_profile_id is not null then
              insert into core.well_assignments (
                well_id, profile_id, role, status
              ) values (
                v_well_id, v_op_profile_id, 'operator', 'active'
              ) on conflict do nothing;
            end if;
          end if;
        end if;
      end;
    end loop;
  end if;

  return jsonb_build_object(
    'tenant_id', v_tenant_id,
    'well_id', v_well_id,
    'well_name', v_well_name,
    'status', 'success'
  );
end;
$function$;

create or replace function finance.create_default_ledger_accounts(p_well_id uuid)
returns integer
language plpgsql
security definer
set search_path = finance, core, public
as $$
declare
    v_tenant_id uuid;
    v_count integer := 0;
begin
 perform billing.require_customer_credit_well_lock(p_well_id);
    select tenant_id into v_tenant_id from core.wells where id = p_well_id;
    if v_tenant_id is null then
        raise exception 'البئر غير موجود: %', p_well_id;
    end if;

    insert into finance.ledger_accounts
        (tenant_id, well_id, account_code, name_ar, account_type, normal_balance, is_system_account)
    select v_tenant_id, p_well_id, a.code, a.name_ar, a.acct_type, a.nb, true
    from (values
        ('1000', 'النقد والصناديق',        'asset',     'debit'),
        ('1100', 'ديون المزارعين',         'asset',     'debit'),
        ('1200', 'مخزون ديزل البئر',       'asset',     'debit'),
        ('2000', 'أرصدة مقدمة للمزارعين',  'liability', 'credit'),
        ('2100', 'مستحقات الشركاء',        'liability', 'credit'),
        ('2200', 'رواتب مستحقة',           'liability', 'credit'),
        ('2300', 'مصروفات مستحقة',         'liability', 'credit'),
        ('2400', 'مبالغ مستحقة لشركاء',    'liability', 'credit'),
        ('2500', 'احتياطي الصيانة',        'liability', 'credit'),
        ('3000', 'رأس المال',              'equity',    'credit'),
        ('3100', 'أرباح متراكمة',          'equity',    'credit'),
        ('3200', 'أرباح قابلة للتوزيع',    'equity',    'credit'),
        ('4000', 'إيراد سقي شمسي',         'revenue',   'credit'),
        ('4100', 'إيراد تشغيل ديزل',       'revenue',   'credit'),
        ('4200', 'إيراد وقود',             'revenue',   'credit'),
        ('4300', 'إيرادات أخرى',           'revenue',   'credit'),
        ('5000', 'تكلفة ديزل مستهلك',      'expense',   'debit'),
        ('5100', 'مصروف صيانة',            'expense',   'debit'),
        ('5200', 'مصروف زيت',              'expense',   'debit'),
        ('5300', 'قطع غيار',               'expense',   'debit'),
        ('5400', 'رواتب',                  'expense',   'debit'),
        ('5500', 'نقل',                    'expense',   'debit'),
        ('5600', 'حراسة',                  'expense',   'debit'),
        ('5700', 'مصروفات إدارية',         'expense',   'debit'),
        ('5800', 'فروقات مخزون',           'expense',   'debit'),
        ('5900', 'مصروفات أخرى',           'expense',   'debit')
    ) as a(code, name_ar, acct_type, nb)
    on conflict (tenant_id, well_id, account_code) do nothing;

    get diagnostics v_count = row_count;
    return v_count;
end;
$$;

create or replace function finance.create_main_cashbox()
returns trigger
language plpgsql
security definer
set search_path to 'finance', 'core', 'pg_temp'
as $$
begin
 perform billing.require_customer_credit_well_lock(new.id);
  insert into finance.cashboxes (tenant_id, well_id, name, cashbox_type)
  values (new.tenant_id, new.id, 'صندوق ' || new.name, 'main_well')
  on conflict do nothing;
  return new;
end;
$$;

create or replace function inventory.create_default_fuel_tank()
returns trigger
language plpgsql
security definer
set search_path to 'inventory', 'core', 'pg_temp'
as $$
begin
 perform billing.require_customer_credit_well_lock(new.id);
  insert into inventory.fuel_tanks (tenant_id, well_id, name)
  values (new.tenant_id, new.id, 'خزان ' || new.name);
  return new;
end;
$$;

create or replace function finance.create_distribution_settings()
returns trigger language plpgsql security definer set search_path to 'finance', 'pg_temp' as $$
begin
 perform billing.require_customer_credit_well_lock(new.id);
  insert into finance.distribution_settings (well_id, tenant_id)
  values (new.id, new.tenant_id) on conflict do nothing;
  return new;
end;
$$;

create or replace function ops.compute_session_charge()
returns trigger
language plpgsql
security definer
set search_path to 'ops', 'billing', 'pg_temp'
as $function$
declare
  v_duration_seconds integer;
  v_price_per_hour_minor bigint;
  v_amount_minor bigint;
begin
  if new.status in ('closed', 'forgotten') and new.ended_at is not null
     and old.status = 'open' then

    if exists (
      select 1 from ops.session_segments ss where ss.session_id = new.id
    ) then
      return new;
    end if;

    v_duration_seconds := extract(epoch from (new.ended_at - new.started_at))::integer;
    v_price_per_hour_minor := new.price_per_hour_minor_snapshot;

    if v_price_per_hour_minor is null then
      raise exception 'لا يوجد سعر مثبت لهذه الجلسة — يجب ضبط سعر البئر قبل بدء الجلسة';
    end if;

    v_amount_minor := (v_duration_seconds::bigint * v_price_per_hour_minor) / 3600;

    perform billing.require_customer_credit_well_lock(new.well_id);
    insert into billing.session_charges (
      session_id, well_id, duration_seconds, price_per_hour_minor,
      amount_minor, pricing_mode
    ) values (
      new.id, new.well_id, v_duration_seconds, v_price_per_hour_minor,
      v_amount_minor, 'flat'
    );
  end if;

  return new;
end;
$function$;

-- Fixed/accounting history is not an arbitrary editor surface. Legitimate
-- execution routes remain the sanctioned recording/approval/payment APIs.
do $financial_acl$ declare rel regclass;c record;begin
 foreach rel in array array[
 'billing.payments'::regclass,'billing.payment_allocations'::regclass,
 'billing.invoices'::regclass,'billing.invoice_lines'::regclass,'billing.session_charges'::regclass,
 'billing.account_credits'::regclass,'billing.account_credit_applications'::regclass,
 'finance.journal_entries'::regclass,'finance.journal_lines'::regclass,
 'finance.expenses'::regclass,'finance.expense_approvals'::regclass,'finance.payroll_accruals'::regclass,
 'finance.profit_distribution_cycles'::regclass,'finance.profit_distribution_lines'::regclass,
 'inventory.fuel_purchases'::regclass,'inventory.fuel_transactions'::regclass,
 'ops.irrigation_sessions'::regclass,'ops.session_segments'::regclass,
 'ops.shifts'::regclass,'ops.session_shift_transfers'::regclass,'ops.shift_handovers'::regclass,
 'ops.price_schedules'::regclass,'ops.price_rules'::regclass,'billing.well_pricing'::regclass,'finance.ledger_accounts'::regclass] loop
  execute format('revoke insert,update,delete,truncate on %s from public,anon,authenticated,service_role',rel);
  for c in select attname from pg_attribute where attrelid=rel and attnum>0 and not attisdropped loop
   execute format('revoke insert (%I),update (%I) on %s from public,anon,authenticated,service_role',c.attname,c.attname,rel);
  end loop;
 end loop;
end;$financial_acl$;

-- Existing business capabilities exposed narrowly through the sanctioned API.
create function api.approve_opening_balance_batch(p_batch_id uuid) returns void
language plpgsql volatile security invoker set search_path=pg_catalog,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'authentication_required' using errcode='42501';end if;
 perform finance.approve_opening_balance_batch(p_batch_id,auth.uid());
end;$$;
create function api.post_opening_balance_batch(p_batch_id uuid) returns void
language plpgsql volatile security invoker set search_path=pg_catalog,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'authentication_required' using errcode='42501';end if;
 perform finance.post_opening_balance_batch(p_batch_id,auth.uid());
end;$$;
create function api.reverse_payment(p_payment_id uuid,p_reason text) returns uuid
language plpgsql volatile security invoker set search_path=pg_catalog,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'authentication_required' using errcode='42501';end if;
 return billing.reverse_payment(p_payment_id,p_reason,auth.uid());
end;$$;
create function api.request_period_reopen(p_period_id uuid,p_reason text) returns uuid
language plpgsql volatile security invoker set search_path=pg_catalog,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'authentication_required' using errcode='42501';end if;
 return finance.request_period_reopen(p_period_id,auth.uid(),p_reason);
end;$$;
create function api.approve_period_reopen(p_request_id uuid) returns void
language plpgsql volatile security invoker set search_path=pg_catalog,pg_temp as $$
declare partner uuid;
begin
 if auth.uid() is null then raise exception 'authentication_required' using errcode='42501';end if;
 select p.id into partner from finance.period_reopen_requests r join finance.accounting_periods ap on ap.id=r.period_id
  join core.well_partners p on p.well_id=ap.well_id and p.tenant_id=ap.tenant_id and p.profile_id=auth.uid()
  where r.id=p_request_id and p.status='active' and p.period_end is null;
 if partner is null then raise exception 'period_reopen_partner_required' using errcode='42501';end if;
 perform finance.approve_period_reopen(p_request_id,partner);
end;$$;
create function api.decide_period_reopen(p_request_id uuid,p_approve boolean,p_note text default null) returns void
language plpgsql volatile security invoker set search_path=pg_catalog,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'authentication_required' using errcode='42501';end if;
 perform finance.decide_period_reopen(p_request_id,auth.uid(),p_approve,p_note);
end;$$;
revoke all on function api.approve_opening_balance_batch(uuid),api.post_opening_balance_batch(uuid),api.reverse_payment(uuid,text),
 api.request_period_reopen(uuid,text),api.approve_period_reopen(uuid),api.decide_period_reopen(uuid,boolean,text)
 from public,anon,authenticated,service_role;
grant execute on function api.approve_opening_balance_batch(uuid),api.post_opening_balance_batch(uuid),api.reverse_payment(uuid,text),
 api.request_period_reopen(uuid,text),api.approve_period_reopen(uuid),api.decide_period_reopen(uuid,boolean,text) to authenticated,service_role;
-- These are the specific inner dispatchers used by invoker API wrappers.
-- Revoking PUBLIC avoids the old anonymous SECURITY DEFINER bypass; SQL owner
-- and the same currently-authorized authenticated business users remain usable.
revoke all on function finance.approve_opening_balance_batch(uuid,uuid),finance.post_opening_balance_batch(uuid,uuid),
 billing.reverse_payment(uuid,text,uuid),finance.close_period(uuid,uuid),finance.request_period_reopen(uuid,uuid,text),
 finance.approve_period_reopen(uuid,uuid),finance.decide_period_reopen(uuid,uuid,boolean,text)
 from public,anon,authenticated,service_role;
grant execute on function finance.approve_opening_balance_batch(uuid,uuid),finance.post_opening_balance_batch(uuid,uuid),
 billing.reverse_payment(uuid,text,uuid),finance.close_period(uuid,uuid),finance.request_period_reopen(uuid,uuid,text),
 finance.approve_period_reopen(uuid,uuid),finance.decide_period_reopen(uuid,uuid,boolean,text) to authenticated,service_role;

create or replace function ops.create_price_schedule(
  p_well_id uuid,
  p_name text,
  p_effective_from timestamptz default null,
  p_reason text default null,
  p_solar_rate_minor bigint default null,
  p_well_diesel_rate_minor bigint default null,
  p_farmer_diesel_rate_minor bigint default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_from timestamptz := coalesce(p_effective_from, now());
  v_tenant_id uuid;
  v_schedule_id uuid;
  v_conflict timestamptz;
begin
 perform billing.enter_financial_write(p_well_id,'price.manage',null);
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء جدول تسعير'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  if v_name is null then
    raise exception 'اسم جدول التسعير مطلوب'
      using errcode = '22023';
  end if;

  if coalesce(p_solar_rate_minor, 0) <= 0
     and coalesce(p_well_diesel_rate_minor, 0) <= 0
     and coalesce(p_farmer_diesel_rate_minor, 0) <= 0 then
    raise exception 'يجب تحديد سعر واحد على الأقل أكبر من صفر'
      using errcode = '22023';
  end if;

  if coalesce(p_solar_rate_minor, 0) < 0
     or coalesce(p_well_diesel_rate_minor, 0) < 0
     or coalesce(p_farmer_diesel_rate_minor, 0) < 0 then
    raise exception 'الأسعار لا تكون سالبة'
      using errcode = '22023';
  end if;

  -- السلطة القائمة (ق-113): price.manage. حاليًا لا تُمنح إلا
  -- لحزمة tenant_owner، أي المالك — وهو نفس ما تطلبه سياسة
  -- price_schedules_insert_owner، فلا تعارض بين الطبقتين.
  -- الإجراء DEFINER يتجاوز RLS، فهذا الفحص هو التفويض الفعلي.
  if not iam.has_well_permission(p_well_id, 'price.manage') then
    raise exception 'إدارة التسعير متاحة للمالك فقط'
      using errcode = '42501';
  end if;

  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id;

  if v_tenant_id is null then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  -- منع الجداول المتراكبة: تاريخ السريان يجب أن يكون بعد بداية
  -- أي جدول قائم، وإلا استحال قصّ الحدّ الأعلى بشكل صحيح.
  select lower(ps.effective_period)
  into v_conflict
  from ops.price_schedules ps
  where ps.well_id = p_well_id
    and ps.status = 'active'
    and lower(ps.effective_period) >= v_from
  order by lower(ps.effective_period) desc
  limit 1;

  if v_conflict is not null then
    raise exception
      'يوجد جدول تسعير يبدأ في % أو بعده؛ اختر تاريخًا لاحقًا',
      v_conflict
      using errcode = '22023';
  end if;

  update ops.price_schedules ps
  set
    effective_period = tstzrange(lower(ps.effective_period), v_from),
    status = case
      when v_from <= now() then 'expired'
      else ps.status
    end
  where ps.well_id = p_well_id
    and ps.status = 'active'
    and (
      upper(ps.effective_period) is null
      or upper(ps.effective_period) > v_from
    );

  insert into ops.price_schedules (
    tenant_id, well_id, name, effective_period,
    status, reason, approved_by
  )
  values (
    v_tenant_id, p_well_id, v_name,
    tstzrange(v_from, null), 'active',
    nullif(btrim(coalesce(p_reason, '')), ''),
    v_actor
  )
  returning id into v_schedule_id;

  if coalesce(p_solar_rate_minor, 0) > 0 then
    insert into ops.price_rules (
      tenant_id, price_schedule_id, energy_source, hourly_rate_minor
    )
    values (
      v_tenant_id, v_schedule_id, 'solar', p_solar_rate_minor
    );
  end if;

  if coalesce(p_well_diesel_rate_minor, 0) > 0 then
    insert into ops.price_rules (
      tenant_id, price_schedule_id, energy_source,
      diesel_pricing_model, hourly_rate_minor
    )
    values (
      v_tenant_id, v_schedule_id, 'well_diesel',
      'inclusive_hourly', p_well_diesel_rate_minor
    );
  end if;

  if coalesce(p_farmer_diesel_rate_minor, 0) > 0 then
    insert into ops.price_rules (
      tenant_id, price_schedule_id, energy_source, hourly_rate_minor
    )
    values (
      v_tenant_id, v_schedule_id, 'farmer_diesel',
      p_farmer_diesel_rate_minor
    );
  end if;

  return jsonb_build_object(
    'schedule_id', v_schedule_id,
    'effective_from', v_from
  );
end;
$function$;
create or replace function sync.begin_booking_session_command(
  p_booking_id uuid,
  p_command_id uuid,
  p_started_at timestamptz,
  p_crops text[] default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant_id uuid;
  v_well_id uuid;
  v_payload jsonb;
  v_guard jsonb;
  v_stored_type text;
  v_stored_payload jsonb;
  v_status text;
  v_response jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل بدء جلسة من حجز';
  end if;
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;
  if p_started_at is null then
    raise exception 'زمن البداية الفعلي مطلوب';
  end if;

  select w.tenant_id, b.well_id
    into v_tenant_id, v_well_id
  from ops.irrigation_bookings b
  join core.wells w on w.id = b.well_id
  where b.id = p_booking_id
    and exists (
      select 1
      from core.well_assignments wa
      where wa.well_id = b.well_id
        and wa.profile_id = v_actor
        and wa.status = 'active'
    );

  if v_tenant_id is null then
    raise exception 'الحجز غير موجود أو لا تملك وصولًا إليه';
  end if;
  if not iam.has_well_permission(v_well_id, 'session.start') then
    raise exception 'لا تملك صلاحية بدء جلسة على هذا البئر';
  end if;

  v_payload := jsonb_build_object(
    'booking_execution_contract_version', 113,
    'booking_id', p_booking_id,
    'started_at', p_started_at,
    'crops', to_jsonb(p_crops)
  );

  perform ops.lock_operational_scope(v_well_id);
  if not coalesce(iam.has_well_permission(v_well_id,'session.start'),false) then raise exception 'command_scope_authorization_changed' using errcode='42501';end if;
  v_guard := sync.begin_command(
    v_tenant_id,
    p_command_id,
    'start_irrigation_session_from_booking',
    v_payload,
    p_booking_id
  );

  if not coalesce((v_guard ->> 'duplicate')::boolean, false) then
    return jsonb_build_object(
      'duplicate', false,
      'well_id', v_well_id
    );
  end if;

  select
    pc.command_type,
    pc.request_payload,
    pc.status,
    pc.response_payload
  into
    v_stored_type,
    v_stored_payload,
    v_status,
    v_response
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant_id
    and pc.command_id = p_command_id;

  if not found
     or v_stored_type is distinct from
          'start_irrigation_session_from_booking'
     or v_stored_payload is distinct from v_payload then
    raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
  end if;

  return jsonb_build_object(
    'duplicate', true,
    'well_id', v_well_id,
    'status', v_status,
    'response', v_response
  );
end;
$function$;
-- Retired booking execution command helper remains untouched/unreachable.
create or replace function sync.begin_adhoc_session_command(
  p_well_id uuid,
  p_pump_id uuid,
  p_farm_id uuid,
  p_farmer_well_account_id uuid,
  p_energy_source text,
  p_planned_duration_minutes integer,
  p_started_at timestamptz,
  p_command_id uuid,
  p_crops text[],
  p_fuel_owner_person_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_tenant_id uuid;
  v_payload jsonb;
  v_guard jsonb;
  v_stored_type text;
  v_stored_payload jsonb;
  v_status text;
  v_response jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل بدء جلسة سقي';
  end if;
  if p_command_id is null then
    raise exception 'معرّف العملية مطلوب';
  end if;
  if p_started_at is null then
    raise exception 'زمن البداية الفعلي مطلوب';
  end if;

  select w.tenant_id into v_tenant_id
  from core.wells w
  where w.id = p_well_id
    and exists (
      select 1 from core.well_assignments wa
      where wa.well_id = p_well_id and wa.profile_id = v_actor
        and wa.status = 'active'
    );
  if v_tenant_id is null then
    raise exception 'البئر غير موجود أو لا تملك وصولًا إليه';
  end if;
  if not iam.has_well_permission(p_well_id, 'session.start') then
    raise exception 'لا تملك صلاحية بدء جلسة على هذا البئر';
  end if;
  v_payload := jsonb_build_object(
    'booking_execution_contract_version', 113,
    'well_id', p_well_id,
    'pump_id', p_pump_id,
    'farm_id', p_farm_id,
    'farmer_well_account_id', p_farmer_well_account_id,
    'energy_source', p_energy_source,
    'planned_duration_minutes', p_planned_duration_minutes,
    'started_at', p_started_at,
    'crops', to_jsonb(p_crops),
    'fuel_owner_person_id', p_fuel_owner_person_id
  );

  perform ops.lock_operational_scope(p_well_id);
  if not coalesce(iam.has_well_permission(p_well_id,'session.start'),false) then raise exception 'command_scope_authorization_changed' using errcode='42501';end if;
  v_guard := sync.begin_command(
    v_tenant_id, p_command_id, 'start_adhoc_session', v_payload, p_well_id
  );

  if not coalesce((v_guard ->> 'duplicate')::boolean, false) then
    return jsonb_build_object('duplicate', false, 'tenant_id', v_tenant_id);
  end if;

  select pc.command_type, pc.request_payload, pc.status, pc.response_payload
  into v_stored_type, v_stored_payload, v_status, v_response
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant_id and pc.command_id = p_command_id;

  if not found
     or v_stored_type is distinct from 'start_adhoc_session'
     or v_stored_payload is distinct from v_payload then
    raise exception 'معرّف العملية مستخدم لمحتوى مختلف';
  end if;

  return jsonb_build_object(
    'duplicate', true, 'tenant_id', v_tenant_id,
    'status', v_status, 'response', v_response
  );
end;
$function$;
create or replace function ops.declare_operator_cash_remittance(
  p_shift_id uuid,
  p_amount_minor bigint,
  p_note text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path to 'ops', 'core', 'finance', 'pg_temp'
as $$
declare
  v_shift ops.shifts%rowtype;
  v_main_cashbox uuid;
  v_balance bigint;
  v_id uuid;
begin
 perform billing.enter_financial_write((select well_id from ops.shifts where id=p_shift_id),'handover.declare',null);
  if p_amount_minor is null or p_amount_minor <= 0 then
    raise exception 'مبلغ الترحيل يجب أن يكون أكبر من صفر';
  end if;

  select * into v_shift from ops.shifts where id = p_shift_id;
  if v_shift.id is null then
    raise exception 'المناوبة % غير موجودة', p_shift_id;
  end if;

  if v_shift.cashbox_id is null or not exists (
    select 1 from finance.cashboxes c
    where c.id = v_shift.cashbox_id
      and c.cashbox_type = 'operator_custody'
      and c.status = 'active'
      and c.assigned_profile_id = v_shift.operator_profile_id
  ) then
    raise exception 'المناوبة % غير مدعومة بصندوق حيازة المشغل المخصص له نفسه — لا ترحيل', p_shift_id;
  end if;

  v_main_cashbox := finance.main_cashbox_id(v_shift.well_id);
  if v_main_cashbox is null or not exists (
    select 1 from finance.cashboxes c
    where c.id = v_main_cashbox and c.well_id = v_shift.well_id and c.status = 'active'
  ) then
    raise exception 'صندوق البئر العام غير موجود أو غير فعال — لا وجهة للترحيل';
  end if;

  select finance.cashbox_balance_minor(v_shift.cashbox_id) into v_balance;
  if v_balance < p_amount_minor then
    raise exception 'مبلغ الترحيل % يتجاوز حيازة المشغل الحالية % — لا يُقرَّر ترحيل فوق المتوفر', p_amount_minor, v_balance;
  end if;

  insert into ops.shift_handovers (
    tenant_id, well_id, shift_id, from_profile_id,
    to_description, declared_amount_minor, note,
    handover_kind, from_cashbox_id, to_cashbox_id
  ) values (
    v_shift.tenant_id, v_shift.well_id, v_shift.id, v_shift.operator_profile_id,
    'ترحيل إلى صندوق البئر العام', p_amount_minor, p_note,
    'operator_cash_remittance', v_shift.cashbox_id, v_main_cashbox
  ) returning id into v_id;

  perform ops.notify_well_owners(v_shift.well_id, 'handover_declared',
    format('أقر المشغل بترحيل مبلغ %s ريال من حيازته إلى صندوق البئر - بانتظار تأكيدك', p_amount_minor));

  return v_id;
end;
$$;
-- Custody/collection scope changes use the same well-before-child boundary.
create or replace function ops.respond_session_transfer(
  p_transfer_id uuid,
  p_accept boolean,
  p_to_shift_id uuid default null
) returns text
language plpgsql
security definer
set search_path to 'ops', 'pg_temp'
as $$
declare
  v_t record;
begin
 perform billing.enter_financial_write((select well_id from ops.session_shift_transfers where id=p_transfer_id),null,null);
  select * into v_t from ops.session_shift_transfers where id = p_transfer_id for update;
  if v_t.id is null then
    raise exception 'طلب النقل % غير موجود', p_transfer_id;
  end if;

 if auth.uid() is not null and auth.uid() is distinct from v_t.to_profile_id then
  raise exception 'الرد على نقل الجلسة خاص بالمشغل المطلوب منه الاستلام' using errcode='42501';end if;
 if p_to_shift_id is not null and not exists(select 1 from ops.shifts sh where sh.id=p_to_shift_id
  and sh.well_id=v_t.well_id and sh.operator_profile_id=v_t.to_profile_id and sh.status='open') then
  raise exception 'المناوبة المستقبلة غير صالحة لهذا المشغل' using errcode='23514';end if;
  if v_t.status <> 'pending' then
    raise exception 'طلب النقل % تم الرد عليه مسبقا (%)', p_transfer_id, v_t.status;
  end if;

  if p_accept then
    update ops.session_shift_transfers
    set status = 'accepted', responded_at = now(), to_shift_id = coalesce(p_to_shift_id, to_shift_id)
    where id = p_transfer_id;

    update ops.irrigation_sessions
    set current_shift_id = coalesce(p_to_shift_id, current_shift_id),
        collector_profile_id = case
          when v_t.collection_right = 'transfer_to_new' then v_t.to_profile_id
          else v_t.from_profile_id
        end
    where id = v_t.session_id;

    perform ops.notify_profile(v_t.from_profile_id, v_t.well_id, 'session_transfer_accepted',
      'تم قبول نقل الجلسة الى المشغل التالي', v_t.session_id);
    return 'accepted';
  else
    update ops.session_shift_transfers
    set status = 'rejected', responded_at = now()
    where id = p_transfer_id;

    perform ops.notify_profile(v_t.from_profile_id, v_t.well_id, 'session_transfer_rejected',
      'تم رفض نقل الجلسة، ما زالت على مسؤوليتك', v_t.session_id);
    perform ops.notify_well_owners(v_t.well_id, 'session_transfer_rejected',
      'رفض المشغل التالي استلام جلسة سقي شغالة', v_t.session_id);
    return 'rejected';
  end if;
end;
$$;

-- Custody/collection scope changes use the same well-before-child boundary.
create or replace function ops.close_shift(
  p_shift_id uuid,
  p_allow_open_sessions boolean default false
) returns uuid
language plpgsql
security definer
set search_path to 'ops', 'pg_temp'
as $$
declare
  v_shift record;
  v_unresolved integer;
begin
 perform billing.enter_financial_write((select well_id from ops.shifts where id=p_shift_id),null,null);
  select * into v_shift from ops.shifts where id = p_shift_id for update;
  if v_shift.id is null then
    raise exception 'المناوبة % غير موجودة', p_shift_id;
  end if;

 if auth.uid() is not null and ((auth.uid() is distinct from v_shift.operator_profile_id
  and not coalesce(iam.has_well_permission(v_shift.well_id,'shift.close_override'),false))
  or(p_allow_open_sessions and not coalesce(iam.has_well_permission(v_shift.well_id,'shift.close_override'),false))) then
  raise exception 'لا تملك صلاحية إغلاق هذه المناوبة' using errcode='42501';end if;
  if v_shift.status <> 'open' then
    raise exception 'المناوبة % ليست مفتوحة (%)', p_shift_id, v_shift.status;
  end if;

  select count(*) into v_unresolved
  from ops.irrigation_sessions s
  where s.well_id = v_shift.well_id
    and s.status = 'open'
    and not exists (
      select 1 from ops.session_shift_transfers t
      where t.session_id = s.id and t.from_shift_id = p_shift_id and t.status = 'accepted'
    );

  if v_unresolved > 0 and not p_allow_open_sessions then
    raise exception 'لا يمكن اقفال المناوبة: % جلسة سقي شغالة لم يتم نقلها والاتفاق على من يستلم مبلغها', v_unresolved;
  end if;

  update ops.shifts
  set status = 'closed', ended_at = now(), closed_at = now()
  where id = p_shift_id;

  perform ops.notify_well_owners(v_shift.well_id, 'shift_closed',
    format('تم اقفال مناوبة المشغل %s', v_shift.operator_profile_id));

  return p_shift_id;
end;
$$;

create or replace function ops.flag_long_running_sessions()
returns setof uuid
language plpgsql
security definer
set search_path = ops, core, iam, pg_temp
as $$
declare
    v_session record;
    v_scope uuid;
begin
    -- Operational-only scheduler: serialize the well before updating a session
    -- and inserting notifications whose FK would otherwise wait on that well.
    for v_scope in select distinct sess.well_id from ops.irrigation_sessions sess
     where sess.status='open' order by sess.well_id loop
    perform ops.lock_operational_scope(v_scope,true);
    for v_session in
        update ops.irrigation_sessions s
        set long_alert_sent_at = now()
        from core.well_settings ws
        where ws.well_id = s.well_id
          and s.well_id=v_scope
          and s.status = 'open'
          and s.long_alert_sent_at is null
          and now() - s.started_at > (ws.long_session_alert_minutes || ' minutes')::interval
        returning s.id, s.well_id
    loop
        insert into ops.notifications (recipient_profile_id, well_id, session_id, type, message)
        select wa.profile_id, v_session.well_id, v_session.id, 'long_session',
               'جلسة سقي مفتوحة منذ فترة طويلة تجاوزت الحد المسموح'
        from core.well_assignments wa
        where wa.well_id = v_session.well_id and wa.status = 'active' and wa.role in ('owner', 'operator');

        return next v_session.id;
    end loop;
    end loop;
end;
$$;

create or replace function ops.flag_approaching_long_sessions()
returns setof uuid
language plpgsql
security definer
set search_path = ops, core, iam, pg_temp
as $$
declare
    v_session record;
    v_scope uuid;
begin
    -- Operational-only scheduler: serialize the well before updating a session
    -- and inserting notifications whose FK would otherwise wait on that well.
    for v_scope in select distinct sess.well_id from ops.irrigation_sessions sess
     where sess.status='open' order by sess.well_id loop
    perform ops.lock_operational_scope(v_scope,true);
    for v_session in
        update ops.irrigation_sessions s
        set ending_alert_sent_at = now()
        from core.well_settings ws
        where ws.well_id = s.well_id
          and s.well_id=v_scope
          and s.status = 'open'
          and s.ending_alert_sent_at is null
          and now() - s.started_at > ((ws.long_session_alert_minutes - ws.session_ending_alert_minutes) || ' minutes')::interval
          and now() - s.started_at <= (ws.long_session_alert_minutes || ' minutes')::interval
        returning s.id, s.well_id
    loop
        insert into ops.notifications (recipient_profile_id, well_id, session_id, type, message)
        select wa.profile_id, v_session.well_id, v_session.id, 'approaching_long_session',
               'جلسة سقي تقترب من أن تصبح جلسة طويلة، يُرجى المتابعة'
        from core.well_assignments wa
        where wa.well_id = v_session.well_id and wa.status = 'active' and wa.role in ('owner', 'operator');

        return next v_session.id;
    end loop;
    end loop;
end;
$$;

-- A financial account identity cannot lock its shared person before the well.
create or replace function ops.create_farmer(
  p_well_id uuid,
  p_full_name text,
  p_phone text default null,
  p_preferred_name text default null,
  p_notes text default null,
  p_credit_limit_minor bigint default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_name text;
  v_phone text;
  v_person_id uuid;
  v_farmer_profile_id uuid;
  v_account_id uuid;
  v_exact_ids uuid[] := '{}'::uuid[];
  v_exact_total integer := 0;
  v_exact_active integer := 0;
  v_status text;
  v_candidates jsonb := '[]'::jsonb;
begin
 perform billing.enter_financial_write(p_well_id,'farmer.create',null);
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء مزارع';
  end if;

  if not iam.has_well_permission(p_well_id, 'farmer.create') then
    raise exception 'لا تملك صلاحية إنشاء مزارع في هذا البئر';
  end if;

  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id;

  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  v_name := core.normalize_arabic(p_full_name);
  v_phone := core.normalize_phone(p_phone);

  if v_name is null then
    raise exception 'اسم المزارع مطلوب';
  end if;

  if p_credit_limit_minor is not null and p_credit_limit_minor < 0 then
    raise exception 'حد الدين لا يجوز أن يكون سالبًا';
  end if;

  -- لا يُجرى أي فحص قرار قبل القفل. كل الفحوص التالية ترى الحالة
  -- بعد تسلسل الطلبات التي تتشارك الاسم أو الهاتف المطبع داخل الجهة.
  perform ops.lock_farmer_identity(v_tenant_id, v_name, v_phone);

  select
    coalesce(array_agg(p.id order by p.created_at, p.id), '{}'::uuid[]),
    count(*)::integer,
    count(*) filter (where p.status = 'active')::integer
  into v_exact_ids, v_exact_total, v_exact_active
  from core.persons p
  where v_phone is not null
    and p.tenant_id = v_tenant_id
    and p.status not in ('merged', 'archived')
    and core.normalize_arabic(p.full_name) = v_name
    and exists (
      select 1
      from core.person_contacts pc
      where pc.person_id = p.id
        and pc.tenant_id = v_tenant_id
        and pc.contact_type in ('mobile', 'whatsapp', 'landline')
        and core.normalize_phone(pc.contact_value) = v_phone
    );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'person_id', d.person_id,
        'public_code', d.public_code,
        'full_name', d.full_name,
        'match_level', d.match_level,
        'matched_on', d.matched_on
      )
      order by
        case when d.match_level = 'match' then 0 else 1 end,
        case
          when d.matched_on = 'name+phone' then 0
          when d.matched_on = 'phone' then 1
          else 2
        end,
        d.public_code,
        d.person_id
    ),
    '[]'::jsonb
  )
  into v_candidates
  from core.find_person_duplicates(v_tenant_id, p_full_name, p_phone) d;

  -- أكثر من هوية تاريخية مطابقة تمامًا لا تُختزل إلى أول صف.
  if v_exact_total > 1 then
    return jsonb_build_object(
      'status', 'requires_resolution',
      'person_id', null,
      'farmer_profile_id', null,
      'farmer_well_account_id', null,
      'already_exists', false,
      'duplicate_candidates', v_candidates
    );
  end if;

  -- هوية مطابقة وحيدة غير فعالة ليست إعادة استخدام آمنة تلقائيًا.
  if v_exact_total = 1 and v_exact_active <> 1 then
    return jsonb_build_object(
      'status', 'requires_resolution',
      'person_id', null,
      'farmer_profile_id', null,
      'farmer_well_account_id', null,
      'already_exists', false,
      'duplicate_candidates', v_candidates
    );
  end if;

  if v_exact_total = 1 then
    v_person_id := v_exact_ids[1];
    v_status := 'matched_existing';

    -- يثبت الشخص أثناء استكمال ملف المزارع وحساب البئر.
    perform 1
    from core.persons p
    where p.id = v_person_id
    for update;

    select fp.id
    into v_farmer_profile_id
    from ops.farmer_profiles fp
    where fp.tenant_id = v_tenant_id
      and fp.person_id = v_person_id;

    if not found then
      insert into ops.farmer_profiles (tenant_id, person_id, notes)
      values (v_tenant_id, v_person_id, p_notes)
      returning id into v_farmer_profile_id;
    end if;

    select fwa.id
    into v_account_id
    from ops.farmer_well_accounts fwa
    where fwa.farmer_profile_id = v_farmer_profile_id
      and fwa.well_id = p_well_id;

    if not found then
      insert into ops.farmer_well_accounts (
        tenant_id,
        farmer_profile_id,
        well_id,
        public_code,
        credit_limit_minor,
        notes
      ) values (
        v_tenant_id,
        v_farmer_profile_id,
        p_well_id,
        core.generate_public_code('FWA'),
        p_credit_limit_minor,
        p_notes
      )
      returning id into v_account_id;
    end if;
  elsif jsonb_array_length(v_candidates) > 0 then
    -- أي مرشح غير محسوم يوقف الإنشاء كليًا.
    return jsonb_build_object(
      'status', 'requires_resolution',
      'person_id', null,
      'farmer_profile_id', null,
      'farmer_well_account_id', null,
      'already_exists', false,
      'duplicate_candidates', v_candidates
    );
  else
    v_status := 'created';

    insert into core.persons (
      tenant_id,
      full_name,
      normalized_name,
      preferred_name,
      notes,
      created_by,
      updated_by
    ) values (
      v_tenant_id,
      btrim(p_full_name),
      v_name,
      nullif(btrim(p_preferred_name), ''),
      p_notes,
      v_actor,
      v_actor
    )
    returning id into v_person_id;

    if v_phone is not null then
      insert into core.person_contacts (
        tenant_id,
        person_id,
        contact_type,
        contact_value,
        normalized_value,
        is_primary
      ) values (
        v_tenant_id,
        v_person_id,
        'mobile',
        btrim(p_phone),
        v_phone,
        true
      );
    end if;

    insert into ops.farmer_profiles (tenant_id, person_id, notes)
    values (v_tenant_id, v_person_id, p_notes)
    returning id into v_farmer_profile_id;

    insert into ops.farmer_well_accounts (
      tenant_id,
      farmer_profile_id,
      well_id,
      public_code,
      credit_limit_minor,
      notes
    ) values (
      v_tenant_id,
      v_farmer_profile_id,
      p_well_id,
      core.generate_public_code('FWA'),
      p_credit_limit_minor,
      p_notes
    )
    returning id into v_account_id;
  end if;

  perform audit.log(
    v_tenant_id,
    p_well_id,
    'create_farmer',
    'core.persons',
    v_person_id,
    null,
    jsonb_build_object(
      'status', v_status,
      'person_id', v_person_id,
      'farmer_profile_id', v_farmer_profile_id,
      'farmer_well_account_id', v_account_id,
      'already_exists', v_status = 'matched_existing',
      'duplicate_candidates', '[]'::jsonb
    ),
    case
      when v_status = 'matched_existing'
        then 'إعادة الشخص المطابق دون إنشاء مكرر'
      else 'إنشاء مزارع وحساب بئر'
    end
  );

  return jsonb_build_object(
    'status', v_status,
    'person_id', v_person_id,
    'farmer_profile_id', v_farmer_profile_id,
    'farmer_well_account_id', v_account_id,
    'already_exists', v_status = 'matched_existing',
    'duplicate_candidates', '[]'::jsonb
  );
end;
$function$;

-- A financial account identity cannot lock its shared person before the well.
create or replace function ops.resolve_farmer_identity(
  p_well_id uuid,
  p_original_command_id uuid,
  p_resolution_action text,
  p_selected_person_id uuid default null,
  p_full_name text default null,
  p_phone text default null,
  p_preferred_name text default null,
  p_notes text default null,
  p_credit_limit_minor bigint default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_orig_tenant_id uuid;
  v_orig_status text;
  v_orig_response jsonb;
  v_candidate_found boolean := false;
  v_person_id uuid;
  v_farmer_profile_id uuid;
  v_account_id uuid;
  v_name text;
  v_phone text;
  v_candidates jsonb := '[]'::jsonb;
  v_result jsonb;
begin
 perform billing.enter_financial_write(p_well_id,'farmer.create',null);
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل حسم هوية المزارع';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب لحسم هوية المزارع';
  end if;

  if p_original_command_id is null then
    raise exception 'معرّف العملية الأصلية مطلوب لحسم هوية المزارع';
  end if;

  if not iam.has_well_permission(p_well_id, 'farmer.create') then
    raise exception 'لا تملك صلاحية إنشاء مزارع في هذا البئر';
  end if;

  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id;

  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  if p_credit_limit_minor is not null and p_credit_limit_minor < 0 then
    raise exception 'حد الدين لا يجوز أن يكون سالبًا';
  end if;

  -- التحقق من الأمر الأصلي وحالته وردّه
  select pc.tenant_id, pc.status, pc.response_payload
  into v_orig_tenant_id, v_orig_status, v_orig_response
  from sync.processed_commands pc
  where pc.command_id = p_original_command_id;

  if not found then
    raise exception 'أمر إنشاء المزارع الأصلي غير موجود: %', p_original_command_id;
  end if;

  if v_orig_tenant_id <> v_tenant_id then
    raise exception 'الأمر الأصلي يتبع جهة أخرى';
  end if;

  if v_orig_status <> 'conflict' then
    raise exception 'حالة الأمر الأصلي ليست تعارضًا: %', v_orig_status;
  end if;

  if coalesce(v_orig_response ->> 'status', '') <> 'requires_resolution' then
    raise exception 'رد الأمر الأصلي لا يتطلب حسمًا: %', v_orig_response ->> 'status';
  end if;

  if p_resolution_action = 'use_existing' then
    if p_selected_person_id is null then
      raise exception 'معرّف الشخص المختار مطلوب عند استخدام مزارع قائم';
    end if;

    -- التحقق من أن الشخص المختار كان ضمن مرشحي التعارض للأمر الأصلي
    select exists (
      select 1
      from jsonb_array_elements(v_orig_response -> 'duplicate_candidates') c
      where (c ->> 'person_id')::uuid = p_selected_person_id
    ) into v_candidate_found;

    if not v_candidate_found then
      raise exception 'الشخص المحدد لم يكن ضمن مرشحي التعارض للأمر الأصلي';
    end if;

    -- إعادة التحقق من أن الشخص ما زال فعالًا وقانونيًا لنفس الجهة
    select p.id
    into v_person_id
    from core.persons p
    where p.id = p_selected_person_id
      and p.tenant_id = v_tenant_id
      and p.status = 'active'
    for update;

    if not found then
      raise exception 'الشخص المحدد غير موجود أو غير فعال في هذه الجهة';
    end if;

    -- إنشاء أو إعادة استخدام farmer_profile
    select fp.id
    into v_farmer_profile_id
    from ops.farmer_profiles fp
    where fp.tenant_id = v_tenant_id
      and fp.person_id = v_person_id;

    if not found then
      insert into ops.farmer_profiles (tenant_id, person_id, notes)
      values (v_tenant_id, v_person_id, p_notes)
      returning id into v_farmer_profile_id;
    end if;

    -- إنشاء أو إعادة استخدام farmer_well_account
    select fwa.id
    into v_account_id
    from ops.farmer_well_accounts fwa
    where fwa.farmer_profile_id = v_farmer_profile_id
      and fwa.well_id = p_well_id;

    if not found then
      insert into ops.farmer_well_accounts (
        tenant_id,
        farmer_profile_id,
        well_id,
        public_code,
        credit_limit_minor,
        notes
      ) values (
        v_tenant_id,
        v_farmer_profile_id,
        p_well_id,
        core.generate_public_code('FWA'),
        p_credit_limit_minor,
        p_notes
      )
      returning id into v_account_id;
    end if;

    v_result := jsonb_build_object(
      'status', 'matched_existing',
      'person_id', v_person_id,
      'farmer_profile_id', v_farmer_profile_id,
      'farmer_well_account_id', v_account_id,
      'already_exists', true,
      'duplicate_candidates', '[]'::jsonb
    );

    perform audit.log(
      v_tenant_id,
      p_well_id,
      'resolve_farmer_identity',
      'core.persons',
      v_person_id,
      null,
      v_result,
      'حسم هوية مزارع باختيار شخص قائم'
    );

    return v_result;

  elsif p_resolution_action = 'different_person' then
    v_name := core.normalize_arabic(p_full_name);
    v_phone := core.normalize_phone(p_phone);

    if v_name is null then
      raise exception 'اسم المزارع مطلوب لحسم الشخص المختلف';
    end if;

    -- قفل معاملي على الاسم والهاتف إن وجد
    perform ops.lock_farmer_identity(v_tenant_id, v_name, v_phone);

    -- ق-88: نفس الهاتف المطبع لأي مرشح قائم لا يمكن تجاوزه أبدًا كشخص مختلف
    if v_phone is not null and exists (
      select 1
      from jsonb_array_elements(v_orig_response -> 'duplicate_candidates') c
      join core.person_contacts pc on pc.person_id = (c ->> 'person_id')::uuid
      where pc.tenant_id = v_tenant_id
        and pc.contact_type in ('mobile', 'whatsapp', 'landline')
        and core.normalize_phone(pc.contact_value) = v_phone
    ) then
      raise exception 'لا يمكن حسم الهوية كشخص مختلف بنفس رقم هاتف مرشح قائم';
    end if;

    -- هاتف مطابق لأي شخص موجود في الجهة لا يمكن تجاوزه
    if v_phone is not null and exists (
      select 1
      from core.person_contacts pc
      where pc.tenant_id = v_tenant_id
        and pc.contact_type in ('mobile', 'whatsapp', 'landline')
        and core.normalize_phone(pc.contact_value) = v_phone
    ) then
      raise exception 'رقم الهاتف مستخدم بالفعل لشخص آخر في هذه الجهة';
    end if;

    -- فحص المرشحين للهوية المقترحة
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'person_id', d.person_id,
          'public_code', d.public_code,
          'full_name', d.full_name,
          'match_level', d.match_level,
          'matched_on', d.matched_on
        )
        order by
          case when d.match_level = 'match' then 0 else 1 end,
          case
            when d.matched_on = 'name+phone' then 0
            when d.matched_on = 'phone' then 1
            else 2
          end,
          d.public_code,
          d.person_id
      ),
      '[]'::jsonb
    )
    into v_candidates
    from core.find_person_duplicates(v_tenant_id, p_full_name, p_phone) d;

    -- غياب الهاتف مع وجود اشتباه/مرشحين يعني نقص بيانات التمييز ويفشل مغلقًا
    if v_phone is null and jsonb_array_length(v_candidates) > 0 then
      return jsonb_build_object(
        'status', 'requires_resolution',
        'person_id', null,
        'farmer_profile_id', null,
        'farmer_well_account_id', null,
        'already_exists', false,
        'duplicate_candidates', v_candidates
      );
    end if;

    -- إذا كانت البيانات مميزة قانونيًا (هاتف مختلف حقيقي وغير مستخدم)، يُنشأ شخص واحد فقط
    insert into core.persons (
      tenant_id,
      full_name,
      normalized_name,
      preferred_name,
      notes,
      created_by,
      updated_by
    ) values (
      v_tenant_id,
      btrim(p_full_name),
      v_name,
      nullif(btrim(p_preferred_name), ''),
      p_notes,
      v_actor,
      v_actor
    )
    returning id into v_person_id;

    if v_phone is not null then
      insert into core.person_contacts (
        tenant_id,
        person_id,
        contact_type,
        contact_value,
        normalized_value,
        is_primary
      ) values (
        v_tenant_id,
        v_person_id,
        'mobile',
        btrim(p_phone),
        v_phone,
        true
      );
    end if;

    insert into ops.farmer_profiles (tenant_id, person_id, notes)
    values (v_tenant_id, v_person_id, p_notes)
    returning id into v_farmer_profile_id;

    insert into ops.farmer_well_accounts (
      tenant_id,
      farmer_profile_id,
      well_id,
      public_code,
      credit_limit_minor,
      notes
    ) values (
      v_tenant_id,
      v_farmer_profile_id,
      p_well_id,
      core.generate_public_code('FWA'),
      p_credit_limit_minor,
      p_notes
    )
    returning id into v_account_id;

    v_result := jsonb_build_object(
      'status', 'created',
      'person_id', v_person_id,
      'farmer_profile_id', v_farmer_profile_id,
      'farmer_well_account_id', v_account_id,
      'already_exists', false,
      'duplicate_candidates', '[]'::jsonb
    );

    perform audit.log(
      v_tenant_id,
      p_well_id,
      'resolve_farmer_identity',
      'core.persons',
      v_person_id,
      null,
      v_result,
      'حسم هوية مزارع كشخص مختلف ومميز قانونيًا'
    );

    return v_result;
  else
    raise exception 'إجراء حسم الهوية غير معروف: %', p_resolution_action;
  end if;
end;
$function$;
commit;

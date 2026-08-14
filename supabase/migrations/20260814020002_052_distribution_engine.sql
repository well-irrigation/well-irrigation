-- المرحلة 6 - الملف 052 (ق-74): استبدال دفعات التوزيع بدورات المرجع (doc 03 قسم 39)
-- واجراء الاحتساب والاعتماد (قسم 49) واحتياطي الصيانة (قسم 38) ومفتاح الالتزامات المحتجزة

-- 1) مفتاح الالتزامات المحتجزة لكل بئر (الافتراضي مشغل)
create table finance.distribution_settings (
  well_id uuid primary key references core.wells(id) on delete cascade,
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  withhold_liabilities boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table finance.distribution_settings enable row level security;
create policy distribution_settings_select on finance.distribution_settings for select
  using (iam.has_well_role(well_id, array['owner', 'manager']) or iam.is_well_partner(well_id));
create policy distribution_settings_update_owner on finance.distribution_settings for update
  using (iam.has_well_role(well_id, array['owner']));
grant select, update on finance.distribution_settings to authenticated;

create or replace function finance.create_distribution_settings()
returns trigger language plpgsql security definer set search_path to 'finance', 'pg_temp' as $$
begin
  insert into finance.distribution_settings (well_id, tenant_id)
  values (new.id, new.tenant_id) on conflict do nothing;
  return new;
end;
$$;
create trigger wells_create_distribution_settings
after insert on core.wells for each row execute function finance.create_distribution_settings();
insert into finance.distribution_settings (well_id, tenant_id)
select id, tenant_id from core.wells on conflict do nothing;

-- 2) قواعد احتياطي الصيانة (قسم 38) بخمسة انواع ومانع تداخل
create table finance.maintenance_reserve_rules (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  reserve_type text not null check (reserve_type in (
    'percentage_of_collections', 'percentage_of_profit', 'fixed_amount', 'manual_per_cycle', 'disabled'
  )),
  reserve_percentage numeric(9,6),
  fixed_amount_minor bigint,
  effective_period daterange not null,
  created_at timestamptz not null default now()
);
alter table finance.maintenance_reserve_rules add constraint no_well_reserve_period_overlap
  exclude using gist (well_id with =, effective_period with &&);
alter table finance.maintenance_reserve_rules enable row level security;
create policy maintenance_reserve_rules_select on finance.maintenance_reserve_rules for select
  using (iam.has_well_role(well_id, array['owner', 'manager']) or iam.is_well_partner(well_id));
create policy maintenance_reserve_rules_insert_owner on finance.maintenance_reserve_rules for insert
  with check (iam.has_well_role(well_id, array['owner']));
create policy maintenance_reserve_rules_update_owner on finance.maintenance_reserve_rules for update
  using (iam.has_well_role(well_id, array['owner']));
grant select, insert, update on finance.maintenance_reserve_rules to authenticated;

-- 3) دورات التوزيع واسطرها (قسم 39)
create table finance.profit_distribution_cycles (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  public_code text not null default core.generate_public_code('PDC'),
  well_id uuid not null references core.wells(id) on delete cascade,
  period_start timestamptz not null,
  period_end timestamptz not null,
  status text not null default 'draft'
    check (status in ('draft', 'calculated', 'under_review', 'approved', 'partially_paid', 'paid', 'cancelled')),
  eligible_collections_minor bigint not null default 0,
  eligible_cash_expenses_minor bigint not null default 0,
  reserved_liabilities_minor bigint not null default 0,
  maintenance_reserve_minor bigint not null default 0,
  distributable_amount_minor bigint not null default 0,
  calculated_at timestamptz,
  calculated_by uuid references iam.profiles(id),
  approved_at timestamptz,
  approved_by uuid references iam.profiles(id),
  created_at timestamptz not null default now(),
  unique (well_id, public_code),
  check (period_end > period_start)
);
alter table finance.profit_distribution_cycles enable row level security;
create policy profit_distribution_cycles_select on finance.profit_distribution_cycles for select
  using (iam.has_well_role(well_id, array['owner', 'manager']) or iam.is_well_partner(well_id));
create policy profit_distribution_cycles_insert_owner on finance.profit_distribution_cycles for insert
  with check (iam.has_well_role(well_id, array['owner']));
create policy profit_distribution_cycles_update_owner on finance.profit_distribution_cycles for update
  using (iam.has_well_role(well_id, array['owner']));
grant select, insert, update on finance.profit_distribution_cycles to authenticated;

create table finance.profit_distribution_lines (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  distribution_cycle_id uuid not null references finance.profit_distribution_cycles(id) on delete cascade,
  partner_id uuid not null references core.well_partners(id),
  profit_percentage_snapshot numeric(9,6) not null,
  gross_share_minor bigint not null default 0,
  partner_receivables_minor bigint not null default 0,
  irrigation_deductions_minor bigint not null default 0,
  other_deductions_minor bigint not null default 0,
  net_payable_minor bigint not null default 0,
  status text not null default 'calculated'
    check (status in ('calculated', 'approved', 'partially_paid', 'paid', 'carried_forward')),
  created_at timestamptz not null default now(),
  unique (distribution_cycle_id, partner_id)
);
alter table finance.profit_distribution_lines enable row level security;
create policy profit_distribution_lines_select on finance.profit_distribution_lines for select
  using (exists (select 1 from finance.profit_distribution_cycles c
    where c.id = profit_distribution_lines.distribution_cycle_id
      and (iam.has_well_role(c.well_id, array['owner', 'manager']) or iam.is_well_partner(c.well_id))));
create policy profit_distribution_lines_insert_owner on finance.profit_distribution_lines for insert
  with check (exists (select 1 from finance.profit_distribution_cycles c
    where c.id = profit_distribution_lines.distribution_cycle_id
      and iam.has_well_role(c.well_id, array['owner'])));
create policy profit_distribution_lines_update_owner on finance.profit_distribution_lines for update
  using (exists (select 1 from finance.profit_distribution_cycles c
    where c.id = profit_distribution_lines.distribution_cycle_id
      and iam.has_well_role(c.well_id, array['owner'])));
grant select, insert, update on finance.profit_distribution_lines to authenticated;

-- 4) المصروف المدفوع من جيب الشريك يلزم تحديده (قابل قسم 33.7)
alter table finance.expenses add column partner_id uuid references core.well_partners(id);
alter table finance.expenses add constraint expenses_partner_check
  check (payment_source <> 'partner_paid' or partner_id is not null);

-- 5) نوع اشعار جديد لاعتماد التوزيع
alter table ops.notifications drop constraint if exists notifications_type_check;
alter table ops.notifications add constraint notifications_type_check
  check (type in (
    'long_session', 'approaching_long_session', 'distribution_finalized', 'expense_recorded',
    'handover_declared', 'handover_confirmed', 'handover_difference', 'handover_settled',
    'shift_opened', 'shift_closed', 'shift_open_too_long', 'shift_blocked',
    'session_transfer_requested', 'session_transfer_accepted', 'session_transfer_rejected',
    'period_reopen_requested', 'period_reopen_ready', 'period_reopen_approved', 'period_reopen_rejected',
    'distribution_approved'
  ));

-- 6) مساعد جلب حساب من الدليل بالرمز (يزرع الدليل ان لزم)
create or replace function finance.ledger_account_id(p_well_id uuid, p_code text)
returns uuid language plpgsql security definer set search_path to 'finance', 'pg_temp' as $$
declare
  v_id uuid;
begin
  perform finance.create_default_ledger_accounts(p_well_id);
  select id into v_id from finance.ledger_accounts where well_id = p_well_id and account_code = p_code;
  if v_id is null then
    raise exception 'الحساب % غير موجود في دليل حسابات البئر %', p_code, p_well_id;
  end if;
  return v_id;
end;
$$;

-- 7) الالتزامات المحتجزة (نسخة الدفعة الاولى: مستحقات الشركاء السابقة غير المسلمة؛
--    الرواتب المستحقة تضاف في الدفعة الثالثة باعادة كتابة هذه الدالة)
create or replace function finance.compute_reserved_liabilities(p_well_id uuid)
returns bigint language sql stable security definer set search_path to 'finance', 'pg_temp' as $$
  select coalesce(sum(l.net_payable_minor), 0)
  from finance.profit_distribution_lines l
  join finance.profit_distribution_cycles c on c.id = l.distribution_cycle_id
  where c.well_id = p_well_id
    and l.status in ('approved', 'partially_paid', 'carried_forward');
$$;

-- 8) اقفال الحقول المحسوبة بعد الاعتماد (يسمح بتغيير الحالة فقط)
create or replace function finance.prevent_approved_cycle_change()
returns trigger language plpgsql as $$
begin
  if old.status in ('approved', 'partially_paid', 'paid') then
    if new.distributable_amount_minor is distinct from old.distributable_amount_minor
       or new.eligible_collections_minor is distinct from old.eligible_collections_minor
       or new.eligible_cash_expenses_minor is distinct from old.eligible_cash_expenses_minor
       or new.reserved_liabilities_minor is distinct from old.reserved_liabilities_minor
       or new.maintenance_reserve_minor is distinct from old.maintenance_reserve_minor
       or new.period_start is distinct from old.period_start
       or new.period_end is distinct from old.period_end
       or new.well_id is distinct from old.well_id then
      raise exception 'لا يمكن تعديل دورة توزيع معتمدة — الحقول المحسوبة مقفلة';
    end if;
  end if;
  return new;
end;
$$;
create trigger profit_distribution_cycles_lock
before update on finance.profit_distribution_cycles
for each row execute function finance.prevent_approved_cycle_change();

create or replace function finance.prevent_approved_line_change()
returns trigger language plpgsql security definer set search_path to 'finance', 'pg_temp' as $$
declare
  v_status text;
begin
  select status into v_status from finance.profit_distribution_cycles
  where id = coalesce(new.distribution_cycle_id, old.distribution_cycle_id);
  if v_status in ('approved', 'partially_paid', 'paid') then
    if tg_op in ('INSERT', 'DELETE') then
      raise exception 'لا يمكن تعديل بنود دورة توزيع معتمدة';
    end if;
    if new.gross_share_minor is distinct from old.gross_share_minor
       or new.partner_receivables_minor is distinct from old.partner_receivables_minor
       or new.irrigation_deductions_minor is distinct from old.irrigation_deductions_minor
       or new.other_deductions_minor is distinct from old.other_deductions_minor
       or new.net_payable_minor is distinct from old.net_payable_minor
       or new.partner_id is distinct from old.partner_id then
      raise exception 'لا يمكن تعديل مبالغ بند توزيع معتمد';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
create trigger profit_distribution_lines_lock
before insert or update or delete on finance.profit_distribution_lines
for each row execute function finance.prevent_approved_line_change();

-- 9) مجموع الحصص الاجمالية يساوي القابل للتوزيع بالضبط
create or replace function finance.check_distribution_cycle_lines_total()
returns trigger language plpgsql as $$
declare
  total bigint;
  cycle_total bigint;
  target_cycle uuid;
begin
  target_cycle := coalesce(new.distribution_cycle_id, old.distribution_cycle_id);
  select coalesce(sum(gross_share_minor), 0) into total
  from finance.profit_distribution_lines where distribution_cycle_id = target_cycle;
  select distributable_amount_minor into cycle_total
  from finance.profit_distribution_cycles where id = target_cycle;
  if total <> cycle_total then
    raise exception 'مجموع الحصص الاجمالية للدورة % يجب ان يساوي % بالضبط، القيمة الحالية %',
      target_cycle, cycle_total, total;
  end if;
  return new;
end;
$$;
create constraint trigger profit_distribution_lines_total_check
after insert or update on finance.profit_distribution_lines
deferrable initially deferred
for each row execute function finance.check_distribution_cycle_lines_total();

-- 10) اجراء الاحتساب (قسم 49 الخطوات 1-17)
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
  v_share record;
  v_gross bigint;
  v_remaining bigint;
  v_max_pct numeric := -1;
  v_max_partner uuid;
  v_receivables bigint;
  v_irrigation bigint;
begin
  if p_period_end <= p_period_start then
    raise exception 'نهاية الفترة يجب ان تكون بعد بدايتها';
  end if;
  select tenant_id into v_tenant from core.wells where id = p_well_id;

  -- منع دورة متداخلة غير مغلقة
  if exists (select 1 from finance.profit_distribution_cycles c
             where c.well_id = p_well_id and c.status not in ('paid', 'cancelled')
               and tstzrange(c.period_start, c.period_end) && tstzrange(p_period_start, p_period_end)) then
    raise exception 'توجد دورة توزيع متداخلة غير مغلقة لهذا البئر';
  end if;

  -- المقبوضات المؤهلة: دفعات مرحلة غير معكوسة، باستثناء الارصدة المقدمة
  select coalesce(sum(p.amount_minor), 0) into v_collected
  from billing.payments p
  where p.well_id = p_well_id and p.status = 'posted' and p.purpose <> 'advance'
    and p.paid_at >= p_period_start and p.paid_at < p_period_end;

  -- المصروفات النقدية المؤهلة
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

  -- الالتزامات المحتجزة (حسب مفتاح البئر)
  select withhold_liabilities into v_withhold from finance.distribution_settings where well_id = p_well_id;
  if coalesce(v_withhold, true) then
    v_liabilities := finance.compute_reserved_liabilities(p_well_id);
  end if;

  -- احتياطي الصيانة من القاعدة الفعالة
  select * into v_rule from finance.maintenance_reserve_rules r
  where r.well_id = p_well_id and r.effective_period @> p_period_end::date
  order by r.created_at desc limit 1;
  if v_rule is not null then
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

  -- مجموع نسب الارباح الفعالة عند نهاية الفترة يجب ان يساوي 100
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

    -- مستحقات الشريك: مصروفات دفعها من جيبه
    select coalesce(sum(e.amount_minor), 0) into v_receivables
    from finance.expenses e
    where e.well_id = p_well_id and e.partner_id = v_share.partner_id
      and e.payment_source = 'partner_paid' and e.status = 'posted'
      and e.spent_at < p_period_end;

    -- استقطاعات سقي الشريك: فواتيره غير المسددة المربوطة بسياسة الخصم
    select coalesce(sum(i.outstanding_minor), 0) into v_irrigation
    from billing.invoices i
    join core.partner_irrigation_policies pol on pol.id = i.partner_policy_id
    where pol.partner_id = v_share.partner_id
      and i.status in ('issued', 'partially_paid', 'overdue')
      and i.invoice_date < p_period_end;

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

  -- باقي القسمة لصاحب اكبر حصة (ق-67)
  if v_remaining <> 0 and v_max_partner is not null then
    update finance.profit_distribution_lines
    set gross_share_minor = gross_share_minor + v_remaining,
        net_payable_minor = net_payable_minor + v_remaining
    where distribution_cycle_id = v_cycle and partner_id = v_max_partner;
  end if;

  return v_cycle;
end;
$$;

-- 11) الاعتماد: قيود مستحقات الشركاء + قيد الاحتياطي + اشعار الشركاء (قسم 49)
create or replace function finance.approve_profit_distribution(p_cycle_id uuid, p_approved_by uuid)
returns void language plpgsql security definer
set search_path to 'finance', 'core', 'ops', 'pg_temp' as $$
declare
  v_cycle record;
  v_line record;
  v_je uuid;
  v_acc3200 uuid; v_acc2500 uuid; v_acc2100 uuid; v_acc2400 uuid; v_acc1100 uuid;
begin
  select * into v_cycle from finance.profit_distribution_cycles where id = p_cycle_id for update;
  if v_cycle is null then raise exception 'الدورة غير موجودة: %', p_cycle_id; end if;
  if v_cycle.status not in ('calculated', 'under_review') then
    raise exception 'لا يمكن اعتماد دورة حالتها % — يجب ان تكون محسوبة او قيد المراجعة', v_cycle.status;
  end if;
  if exists (select 1 from finance.profit_distribution_lines l
             where l.distribution_cycle_id = p_cycle_id and l.net_payable_minor < 0) then
    raise exception 'لا يمكن الاعتماد: يوجد شريك صافي مستحقه سالب — راجع الاستقطاعات';
  end if;

  v_acc3200 := finance.ledger_account_id(v_cycle.well_id, '3200');
  v_acc2100 := finance.ledger_account_id(v_cycle.well_id, '2100');
  v_acc2400 := finance.ledger_account_id(v_cycle.well_id, '2400');
  v_acc1100 := finance.ledger_account_id(v_cycle.well_id, '1100');

  -- قيد تكوين الاحتياطي (doc 02 قسم 32.2)
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

  -- قيد مستحقات لكل شريك
  for v_line in
    select * from finance.profit_distribution_lines where distribution_cycle_id = p_cycle_id
  loop
    if v_line.gross_share_minor = 0 and v_line.partner_receivables_minor = 0 then
      continue;
    end if;
    insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
    values (v_cycle.tenant_id, core.generate_public_code('JE'), v_cycle.well_id, now(),
            'profit_distribution', v_line.id, 'مستحقات شريك من دورة التوزيع ' || v_cycle.public_code,
            'PDC-' || v_line.id::text)
    returning id into v_je;
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
    values (v_cycle.tenant_id, v_je, v_acc3200, 'debit', v_line.gross_share_minor, v_line.partner_id, 'حصة الشريك الاجمالية');
    if v_line.partner_receivables_minor > 0 then
      insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
      values (v_cycle.tenant_id, v_je, v_acc2400, 'debit', v_line.partner_receivables_minor, v_line.partner_id, 'تسوية مبالغ كانت مستحقة للشريك');
    end if;
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
    values (v_cycle.tenant_id, v_je, v_acc2100, 'credit', v_line.net_payable_minor, v_line.partner_id, 'صافي مستحق الشريك');
    if v_line.irrigation_deductions_minor > 0 then
      insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
      values (v_cycle.tenant_id, v_je, v_acc1100, 'credit', v_line.irrigation_deductions_minor, v_line.partner_id, 'خصم قيمة سقيه من ديون المزارعين');
    end if;
    perform finance.post_journal_entry(v_je, p_approved_by);
  end loop;

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

-- 12) ترحيل اي دفعات قديمة ثم اسقاط الجداول والدوال القديمة
do $$
declare
  b record;
  v_cycle uuid;
begin
  for b in select * from finance.distribution_batches loop
    insert into finance.profit_distribution_cycles (tenant_id, well_id, period_start, period_end, status, distributable_amount_minor, created_at)
    select w.tenant_id, b.well_id, b.period_start::timestamptz, (b.period_end + 1)::timestamptz,
           'calculated', b.total_amount_minor, b.created_at
    from core.wells w where w.id = b.well_id
    returning id into v_cycle;

    insert into finance.profit_distribution_lines (tenant_id, distribution_cycle_id, partner_id, profit_percentage_snapshot, gross_share_minor, net_payable_minor, status, created_at)
    select (select tenant_id from core.wells where id = b.well_id), v_cycle, l.partner_id,
           l.share_ppm / 10000.0, l.amount_minor, l.amount_minor, 'calculated', l.created_at
    from finance.distribution_lines l where l.batch_id = b.id;

    if b.status = 'finalized' then
      update finance.profit_distribution_cycles set status = 'approved', approved_at = b.updated_at where id = v_cycle;
      update finance.profit_distribution_lines set status = 'approved' where distribution_cycle_id = v_cycle;
    end if;
  end loop;
end $$;

drop table finance.distribution_lines;
drop table finance.distribution_batches;
drop function if exists finance.generate_distribution_batch(uuid, date, date);
drop function if exists finance.check_distribution_lines_total();
drop function if exists finance.prevent_finalized_batch_update();
drop function if exists finance.prevent_finalized_batch_lines_change();
drop function if exists finance.notify_distribution_finalized();

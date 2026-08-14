-- المرحلة 6 - الملف 053: اصلاحان:
-- 1) خطا Postgres في "سجل is not null" الذي الغى الاحتياطي بصمت (يفحص found بدلا منه)
-- 2) منع ازدواج مستحقات الشريك واستقطاعات سقيه بين الدورات بعلامتي تسوية

alter table finance.expenses add column settled_in_cycle_id uuid
  references finance.profit_distribution_cycles(id);
alter table billing.invoices add column deducted_in_cycle_id uuid
  references finance.profit_distribution_cycles(id);

-- اعادة كتابة الاحتساب: found + ترشيح المسواة
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
begin
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

  select withhold_liabilities into v_withhold from finance.distribution_settings where well_id = p_well_id;
  if coalesce(v_withhold, true) then
    v_liabilities := finance.compute_reserved_liabilities(p_well_id);
  end if;

  -- الاحتياطي: found وليس "سجل is not null" (الاخير خطان مع الحقول الفارغة)
  select * into v_rule from finance.maintenance_reserve_rules r
  where r.well_id = p_well_id and r.effective_period @> p_period_end::date
  order by r.created_at desc limit 1;
  v_rule_found := found;
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

    -- مستحقات الشريك غير المسواة فقط (منع الازدواج)
    select coalesce(sum(e.amount_minor), 0) into v_receivables
    from finance.expenses e
    where e.well_id = p_well_id and e.partner_id = v_share.partner_id
      and e.payment_source = 'partner_paid' and e.status = 'posted'
      and e.spent_at < p_period_end
      and e.settled_in_cycle_id is null;

    -- فواتير سقي الشريك غير المخصومة سابقا فقط
    select coalesce(sum(i.outstanding_minor), 0) into v_irrigation
    from billing.invoices i
    join core.partner_irrigation_policies pol on pol.id = i.partner_policy_id
    where pol.partner_id = v_share.partner_id
      and i.status in ('issued', 'partially_paid', 'overdue')
      and i.invoice_date < p_period_end
      and i.deducted_in_cycle_id is null;

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

  return v_cycle;
end;
$$;

-- اعادة كتابة الاعتماد: تعليم المسواة بعد الترحيل
create or replace function finance.approve_profit_distribution(p_cycle_id uuid, p_approved_by uuid)
returns void language plpgsql security definer
set search_path to 'finance', 'core', 'ops', 'billing', 'pg_temp' as $$
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

  -- تعليم المسواة: المصروفات المدفوعة من الشركاء والفواتير المخصومة لا تحسب مرة اخرى
  update finance.expenses e set settled_in_cycle_id = p_cycle_id
  where e.well_id = v_cycle.well_id and e.payment_source = 'partner_paid'
    and e.status = 'posted' and e.spent_at < v_cycle.period_end
    and e.settled_in_cycle_id is null;

  update billing.invoices i set deducted_in_cycle_id = p_cycle_id
  from core.partner_irrigation_policies pol
  where i.partner_policy_id = pol.id
    and i.well_id = v_cycle.well_id
    and i.status in ('issued', 'partially_paid', 'overdue')
    and i.outstanding_minor > 0
    and i.invoice_date < v_cycle.period_end
    and i.deducted_in_cycle_id is null;

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

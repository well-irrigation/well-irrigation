-- R6-C2B coordinated follow-up; owner DB verification pending.
begin;
alter table core.ownership_share_versions add column origin_version_id uuid references core.ownership_share_versions(id);
create table core.partner_share_changes(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references core.tenants(id),well_id uuid not null references core.wells(id),
 effective_period daterange not null check(not isempty(effective_period)),previous_versions jsonb not null,new_versions jsonb not null,
 reason text not null check(nullif(btrim(reason),'') is not null),actor_id uuid not null references iam.profiles(id),accepted_at timestamptz not null default clock_timestamp()
);
alter table core.partner_share_changes enable row level security;
revoke all on core.partner_share_changes from public,anon,authenticated,service_role;
grant select on core.partner_share_changes to authenticated;
create policy partner_share_change_read on core.partner_share_changes for select
 using(iam.has_well_role(well_id,array['owner','manager']) or iam.is_well_partner(well_id));
create trigger partner_share_history_immutable before update or delete on core.partner_share_changes
 for each row execute function finance.reject_distribution_source_history_mutation();
create function api.preview_partner_share_change(p_well_id uuid,p_effective_from date) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare next_date date;
begin
 if auth.uid() is null or not coalesce(iam.has_well_role(p_well_id,array['owner']),false) then raise exception 'partner_share_owner_required' using errcode='42501';end if;
 if p_effective_from is null or not isfinite(p_effective_from) then raise exception 'partner_share_date_required' using errcode='22023';end if;
 select min(lower(effective_period)) into next_date from core.ownership_share_versions
  where well_id=p_well_id and not isempty(effective_period) and lower(effective_period)>p_effective_from;
 return jsonb_build_object('effective_from',p_effective_from,'effective_until',next_date,'title','تغيير نسب الشركاء',
  'message',case when next_date is null then 'ستُحفظ النسب الجديدة من التاريخ المحدد. التوزيعات المعتمدة لن تتغير.'
   else 'ستنتهي هذه النسب عند بداية التغيير القادم المحفوظ. التوزيعات المعتمدة لن تتغير.' end,'action','حفظ النسب');
end;$$;
create function api.set_partner_shares(p_well_id uuid,p_effective_from date,p_expected_until date,p_shares jsonb,p_reason text) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare tenant uuid;state jsonb;until_date date;period daterange;row_data jsonb;v core.ownership_share_versions%rowtype;
 before_rows jsonb;after_rows jsonb;change_id uuid:=gen_random_uuid();ownership numeric;profit numeric;partner uuid;
begin
 select tenant_id into tenant from core.wells where id=p_well_id;
 if tenant is null or auth.uid() is null or not coalesce(iam.has_well_role(p_well_id,array['owner']),false) then raise exception 'partner_share_owner_required' using errcode='42501';end if;
 perform billing.enter_financial_write(p_well_id,null,array['owner'],tenant);
 perform 1 from core.well_partners where well_id=p_well_id order by id for update;
 perform 1 from core.ownership_share_versions where well_id=p_well_id order by id for update;
 if not coalesce(iam.has_well_role(p_well_id,array['owner']),false) or not exists(select 1 from core.wells where id=p_well_id and tenant_id=tenant) then
  raise exception 'partner_share_owner_required' using errcode='42501';end if;
 state:=api.preview_partner_share_change(p_well_id,p_effective_from);until_date:=(state->>'effective_until')::date;
 if until_date is distinct from p_expected_until then return state||jsonb_build_object('status','review_again','title','راجع تاريخ تطبيق النسب',
  'message','يوجد تغيير محفوظ يحتاج منك مراجعة تاريخ انتهاء النسب الجديدة قبل الحفظ.','action','مراجعة');end if;
 if p_shares is null or jsonb_typeof(p_shares)<>'array' or jsonb_array_length(p_shares)=0 or nullif(btrim(p_reason),'') is null then
  raise exception 'partner_share_values_required' using errcode='22023';end if;
 for row_data in select value from jsonb_array_elements(p_shares) loop
  if jsonb_typeof(row_data)<>'object' or(row_data-array['partner_id','ownership_percentage','profit_percentage'])<>'{}'::jsonb
   or jsonb_typeof(row_data->'ownership_percentage') is distinct from 'number' or jsonb_typeof(row_data->'profit_percentage') is distinct from 'number' then
   raise exception 'partner_share_values_invalid' using errcode='22023';end if;
  partner:=(row_data->>'partner_id')::uuid;ownership:=(row_data->>'ownership_percentage')::numeric;profit:=(row_data->>'profit_percentage')::numeric;
  if ownership<0 or ownership>100 or profit<0 or profit>100 or round(ownership,6)<>ownership or round(profit,6)<>profit
   or not exists(select 1 from core.well_partners where id=partner and well_id=p_well_id and tenant_id=tenant) then
   raise exception 'partner_share_scope_or_amount_invalid' using errcode='23514';end if;
 end loop;
 if(select count(*)<>count(distinct value->>'partner_id') from jsonb_array_elements(p_shares))
  or(select sum((value->>'ownership_percentage')::numeric)<>100 or sum((value->>'profit_percentage')::numeric)<>100 from jsonb_array_elements(p_shares)) then
  raise exception 'partner_share_total_must_be_100' using errcode='23514';end if;
 period:=daterange(p_effective_from,until_date,'[)');
 select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) into before_rows from core.ownership_share_versions x where well_id=p_well_id and effective_period && period;
 -- Preserve scheduled future versions. Only close the overlapping old range;
 -- all old percentages/actor fields remain, and before snapshots retain dates.
 for v in select * from core.ownership_share_versions where well_id=p_well_id and effective_period && period order by id loop
  update core.ownership_share_versions set effective_period=case when lower(v.effective_period)<p_effective_from
   then daterange(lower(v.effective_period),p_effective_from,'[)') else 'empty'::daterange end where id=v.id;
  if until_date is not null and(upper_inf(v.effective_period) or upper(v.effective_period)>until_date) then
   insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period,approved_by,approval_notes,origin_version_id)
   values(v.tenant_id,v.well_id,v.partner_id,v.ownership_percentage,v.profit_percentage,
    daterange(until_date,upper(v.effective_period),'[)'),v.approved_by,v.approval_notes,coalesce(v.origin_version_id,v.id));
  end if;
 end loop;
 for row_data in select value from jsonb_array_elements(p_shares) loop
  insert into core.ownership_share_versions(tenant_id,well_id,partner_id,ownership_percentage,profit_percentage,effective_period,approved_by,approval_notes)
  values(tenant,p_well_id,(row_data->>'partner_id')::uuid,(row_data->>'ownership_percentage')::numeric,
   (row_data->>'profit_percentage')::numeric,period,auth.uid(),p_reason);
 end loop;
 select jsonb_agg(to_jsonb(x) order by x.partner_id) into after_rows from core.ownership_share_versions x where well_id=p_well_id and effective_period=period;
 insert into core.partner_share_changes(id,tenant_id,well_id,effective_period,previous_versions,new_versions,reason,actor_id)
 values(change_id,tenant,p_well_id,period,before_rows,after_rows,p_reason,auth.uid());
 return state||jsonb_build_object('status','saved','change_id',change_id,'title','تم حفظ نسب الشركاء',
  'message','التوزيعات المعتمدة لم تتغير. أعد حساب أي دورة غير معتمدة تأثرت بهذه النسب قبل اعتمادها.','action','مراجعة التوزيع');
end;$$;
revoke all on function api.preview_partner_share_change(uuid,date),api.set_partner_shares(uuid,date,date,jsonb,text) from public,anon,authenticated,service_role;
grant execute on function api.preview_partner_share_change(uuid,date),api.set_partner_shares(uuid,date,date,jsonb,text) to authenticated;
revoke insert,update,delete,truncate on core.ownership_share_versions from public,anon,authenticated,service_role;
do $columns$ declare c record;begin
 for c in select attname from pg_attribute where attrelid='core.ownership_share_versions'::regclass and attnum>0 and not attisdropped loop
  execute format('revoke insert (%I),update (%I) on core.ownership_share_versions from public,anon,authenticated,service_role',c.attname,c.attname);
 end loop;
end;$columns$;
alter table finance.profit_distribution_cycles add column share_basis jsonb;

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
  update finance.profit_distribution_cycles set share_basis=(select coalesce(jsonb_agg(jsonb_build_object('version_id',coalesce(v.origin_version_id,v.id),'partner_id',v.partner_id,'ownership_percentage',v.ownership_percentage,'profit_percentage',v.profit_percentage) order by v.partner_id,v.id),'[]'::jsonb)
   from core.ownership_share_versions v where v.well_id=p_well_id and v.effective_period @> p_period_end::date) where id=v_cycle;
  insert into finance.distribution_calculation_history(tenant_id,well_id,cycle_id,configuration_id,
   configuration_snapshot,cycle_snapshot,lines_snapshot,manual_reserve_minor)
  select v_tenant,p_well_id,v_cycle,cfg_id,cfg,to_jsonb(c),coalesce((select jsonb_agg(to_jsonb(l) order by l.id)
   from finance.profit_distribution_lines l where l.distribution_cycle_id=v_cycle),'[]'::jsonb),coalesce(p_manual_reserve_minor,0)
  from finance.profit_distribution_cycles c where c.id=v_cycle;
  return v_cycle;
end;
$$;

create or replace function finance.approve_profit_distribution(p_cycle_id uuid, p_approved_by uuid)
returns void language plpgsql security definer
set search_path to 'finance', 'core', 'ops', 'billing', 'pg_temp' as $$
declare
  v_cycle record;
  v_line record;
  v_je uuid;
  v_acc3200 uuid; v_acc2500 uuid; v_acc2100 uuid; v_acc2400 uuid; v_acc1100 uuid;
begin
 perform billing.enter_financial_write((select well_id from finance.profit_distribution_cycles where id=p_cycle_id),'distribution.approve',null);
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

  if v_cycle.share_basis is distinct from(select coalesce(jsonb_agg(jsonb_build_object('version_id',coalesce(v.origin_version_id,v.id),'partner_id',v.partner_id,'ownership_percentage',v.ownership_percentage,'profit_percentage',v.profit_percentage) order by v.partner_id,v.id),'[]'::jsonb)
   from core.ownership_share_versions v where v.well_id=v_cycle.well_id and v.effective_period @> v_cycle.period_end::date) then
   raise exception 'distribution_shares_changed_recalculate' using errcode='23514',detail='{"status":"review_required","title":"أعد حساب التوزيع قبل الاعتماد","message":"تغيّرت نسب مرتبطة بهذه الدورة. أعد الحساب وراجع النتيجة قبل الاعتماد.","action":"إعادة الحساب"}';end if;
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
commit;

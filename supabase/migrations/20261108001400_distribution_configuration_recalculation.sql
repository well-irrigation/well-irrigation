begin;
-- C2B5: configuration saves do not recalculate or mutate distribution cycles.
create table finance.distribution_configuration_versions(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references core.tenants(id),
 well_id uuid not null references core.wells(id),sequence bigint not null check(sequence>0),
 previous_id uuid references finance.distribution_configuration_versions(id),
 withhold_liabilities boolean not null,reserve_type text,
 reserve_percentage numeric(9,6),fixed_amount_minor bigint,
 legacy_rules jsonb not null default '[]',
 accepted_at timestamptz not null,actor_id uuid references iam.profiles(id),
 source text not null check(source in ('owner_save','legacy_snapshot')),
 unique(well_id,sequence),check(reserve_type is null or reserve_type in
 ('percentage_of_collections','percentage_of_profit','fixed_amount','manual_per_cycle','disabled'))
);
create table finance.distribution_calculation_history(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references core.tenants(id),
 well_id uuid not null references core.wells(id),cycle_id uuid not null unique references finance.profit_distribution_cycles(id),
 configuration_id uuid not null references finance.distribution_configuration_versions(id),
 configuration_snapshot jsonb not null,cycle_snapshot jsonb not null,lines_snapshot jsonb not null,
 manual_reserve_minor bigint not null,calculated_at timestamptz not null default clock_timestamp()
);
create table finance.distribution_recalculations(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references core.tenants(id),well_id uuid not null references core.wells(id),
 previous_cycle_id uuid not null unique references finance.profit_distribution_cycles(id),
 new_cycle_id uuid not null unique references finance.profit_distribution_cycles(id),
 previous_cycle_snapshot jsonb not null,previous_lines_snapshot jsonb not null,
 manual_adjustments_snapshot jsonb not null,removed_partner_adjustments jsonb not null,
 confirmed_state text not null,actor_id uuid not null references iam.profiles(id),accepted_at timestamptz not null default clock_timestamp()
);
create function finance.reject_distribution_history_mutation() returns trigger language plpgsql
set search_path=pg_catalog,pg_temp as $$
begin raise exception 'distribution_history_append_only' using errcode='23514';end;$$;
do $install$
declare tab text;
begin
 foreach tab in array array['distribution_configuration_versions','distribution_calculation_history','distribution_recalculations'] loop
  execute format('alter table finance.%I enable row level security',tab);
  execute format('revoke all on finance.%I from public,anon,authenticated,service_role',tab);
  execute format('grant select on finance.%I to authenticated',tab);
  execute format('create policy distribution_history_read on finance.%I for select to authenticated using
   (iam.has_well_role(well_id,array[''owner'',''manager'']) or iam.is_well_partner(well_id))',tab);
  execute format('create trigger distribution_history_immutable before update or delete on finance.%I
   for each row execute function finance.reject_distribution_history_mutation()',tab);
 end loop;
end;$install$;
revoke all on function finance.reject_distribution_history_mutation() from public,anon,authenticated,service_role;

-- Private read helper. Legacy dated policies are snapshotted as a collection,
-- not guessed from today's rule when calculating a historical period.
create function finance.current_distribution_configuration(p_well uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare v jsonb;
begin
 select to_jsonb(x) into v from finance.distribution_configuration_versions x where x.well_id=p_well order by sequence desc limit 1;
 if found then return v;end if;
 return jsonb_build_object('id',null,'sequence',0,'withhold_liabilities',coalesce((
  select withhold_liabilities from finance.distribution_settings where well_id=p_well),true),
  'reserve_type',null,'reserve_percentage',null,'fixed_amount_minor',null,'legacy_rules',coalesce((
  select jsonb_agg(to_jsonb(r) order by r.created_at,r.id) from finance.maintenance_reserve_rules r where r.well_id=p_well),'[]'::jsonb));
end;$$;
revoke all on function finance.current_distribution_configuration(uuid) from public,anon,authenticated,service_role;

create function finance.save_distribution_configuration(p_well uuid,p_withhold boolean,p_mode text,p_percentage numeric,p_fixed bigint,p_change_reserve boolean)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare tenant uuid;cfg jsonb;result jsonb;stamp timestamptz;
begin
 if auth.uid() is null or not coalesce(iam.has_well_role(p_well,array['owner']),false) then
  raise exception 'distribution_owner_required' using errcode='42501';end if;
 select tenant_id into tenant from core.wells where id=p_well;
 perform billing.lock_customer_credit_well(p_well);
 if not exists(select 1 from core.wells where id=p_well and tenant_id=tenant)
  or not coalesce(iam.has_well_role(p_well,array['owner']),false) then
  raise exception 'distribution_owner_required' using errcode='42501';end if;
 perform 1 from finance.distribution_configuration_versions where well_id=p_well order by sequence for update;
 cfg:=finance.current_distribution_configuration(p_well);
 if cfg->>'id' is null then
  insert into finance.distribution_configuration_versions(tenant_id,well_id,sequence,withhold_liabilities,
   legacy_rules,accepted_at,source) values(tenant,p_well,1,(cfg->>'withhold_liabilities')::boolean,
   cfg->'legacy_rules',clock_timestamp(),'legacy_snapshot');
  cfg:=finance.current_distribution_configuration(p_well);
 end if;
 stamp:=clock_timestamp();
 if p_change_reserve then
  if p_mode is null or p_mode not in ('percentage_of_collections','percentage_of_profit','fixed_amount','manual_per_cycle','disabled')
   or(p_mode in ('percentage_of_collections','percentage_of_profit') and(p_percentage is null or p_percentage<0 or p_fixed is not null))
   or(p_mode='fixed_amount' and(p_fixed is null or p_fixed<0 or p_percentage is not null))
   or(p_mode in ('manual_per_cycle','disabled') and(p_fixed is not null or p_percentage is not null)) then
   raise exception 'distribution_reserve_configuration_invalid' using errcode='22023';end if;
  cfg:=cfg||jsonb_build_object('reserve_type',p_mode,'reserve_percentage',p_percentage,'fixed_amount_minor',p_fixed,'legacy_rules','[]'::jsonb);
 else
  if p_withhold is null then raise exception 'distribution_setting_required' using errcode='22023';end if;
  cfg:=cfg||jsonb_build_object('withhold_liabilities',p_withhold);
 end if;
 insert into finance.distribution_configuration_versions(tenant_id,well_id,sequence,previous_id,withhold_liabilities,
 reserve_type,reserve_percentage,fixed_amount_minor,legacy_rules,accepted_at,actor_id,source)
 values(tenant,p_well,(cfg->>'sequence')::bigint+1,(cfg->>'id')::uuid,(cfg->>'withhold_liabilities')::boolean,
 cfg->>'reserve_type',(cfg->>'reserve_percentage')::numeric,(cfg->>'fixed_amount_minor')::bigint,cfg->'legacy_rules',stamp,auth.uid(),'owner_save')
 returning to_jsonb(distribution_configuration_versions.*) into result;
 return result||jsonb_build_object('effective_from',stamp,'message','سيُطبق هذا التغيير على حسابات التوزيع الجديدة فقط. الدورات المحسوبة سابقًا لن تتغير تلقائيًا. يمكن إعادة حساب الدورة غير المعتمدة يدويًا. الدورات المعتمدة لن تتغير.');
end;$$;
revoke all on function finance.save_distribution_configuration(uuid,boolean,text,numeric,bigint,boolean) from public,anon,authenticated,service_role;
create function api.update_distribution_settings(p_well_id uuid,p_withhold_liabilities boolean) returns jsonb
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select finance.save_distribution_configuration(p_well_id,p_withhold_liabilities,null,null,null,false)
$$;
create function api.set_maintenance_reserve_rule(p_well_id uuid,p_reserve_type text,p_reserve_percentage numeric default null,p_fixed_amount_minor bigint default null)
returns jsonb language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select finance.save_distribution_configuration(p_well_id,null,p_reserve_type,p_reserve_percentage,p_fixed_amount_minor,true)
$$;
create function api.disable_maintenance_reserve_rule(p_well_id uuid) returns jsonb
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select finance.save_distribution_configuration(p_well_id,null,'disabled',null,null,true)
$$;
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

  insert into finance.distribution_calculation_history(tenant_id,well_id,cycle_id,configuration_id,
   configuration_snapshot,cycle_snapshot,lines_snapshot,manual_reserve_minor)
  select v_tenant,p_well_id,v_cycle,cfg_id,cfg,to_jsonb(c),coalesce((select jsonb_agg(to_jsonb(l) order by l.id)
   from finance.profit_distribution_lines l where l.distribution_cycle_id=v_cycle),'[]'::jsonb),coalesce(p_manual_reserve_minor,0)
  from finance.profit_distribution_cycles c where c.id=v_cycle;
  return v_cycle;
end;
$$;

-- Read-only evidence builder: no financial mutation and no invented clean
-- baseline for legacy cycles whose original calculation is unknown.
create function finance.distribution_recalculation_state(p_cycle uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c finance.profit_distribution_cycles%rowtype;lines jsonb;base jsonb;affected jsonb;cfg jsonb;
begin
 select * into strict c from finance.profit_distribution_cycles where id=p_cycle;
 select coalesce(jsonb_agg(to_jsonb(l) order by l.id),'[]'::jsonb) into lines from finance.profit_distribution_lines l where l.distribution_cycle_id=p_cycle;
 select lines_snapshot into base from finance.distribution_calculation_history where cycle_id=p_cycle;
 -- Compare all computed financial fields, not only other_deductions. Preserve
 -- deleted/removed baseline partners too, so their evidence is never lost.
 select coalesce(jsonb_agg(x order by x->>'partner_id'),'[]'::jsonb) into affected from (
  select x from jsonb_array_elements(lines) x where base is null or not exists(
   select 1 from jsonb_array_elements(base) y where (x-'status'-'created_at')=(y-'status'-'created_at'))
  union all select y from jsonb_array_elements(coalesce(base,'[]'::jsonb)) y
   where not exists(select 1 from jsonb_array_elements(lines) x where x->>'partner_id'=y->>'partner_id')
 ) q;
 cfg:=finance.current_distribution_configuration(c.well_id);
 return jsonb_build_object('cycle',to_jsonb(c),'lines',lines,'affected',affected,'configuration',cfg,
  'state_token',md5(jsonb_build_object('cycle',to_jsonb(c),'lines',lines,'configuration',cfg)::text),
  'manual_adjustments_present',jsonb_array_length(affected)>0,'original_calculation_unknown',base is null);
end;$$;
revoke all on function finance.distribution_recalculation_state(uuid) from public,anon,authenticated,service_role;

create function api.recalculate_profit_distribution(p_cycle_id uuid,p_confirm_manual_adjustments boolean default false,
 p_expected_state text default null,p_manual_reserve_minor bigint default 0,p_execute boolean default false)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate finance.profit_distribution_cycles%rowtype;c finance.profit_distribution_cycles%rowtype;
 state jsonb;new_id uuid;removed jsonb;affected_partners jsonb;result jsonb;
begin
 select * into candidate from finance.profit_distribution_cycles where id=p_cycle_id;
 if not found or auth.uid() is null or not coalesce(iam.has_well_role(candidate.well_id,array['owner']),false) then
  raise exception 'distribution_owner_required' using errcode='42501';end if;
 perform billing.lock_customer_credit_well(candidate.well_id);
 select * into c from finance.profit_distribution_cycles where id=p_cycle_id for update;
 if not found or (c.well_id,c.tenant_id) is distinct from(candidate.well_id,candidate.tenant_id)
  or not coalesce(iam.has_well_role(c.well_id,array['owner']),false) then
  raise exception 'distribution_owner_required' using errcode='42501';end if;
 if c.status not in ('draft','calculated','under_review') then
  return jsonb_build_object('status','not_available','title','لا يمكن إعادة حساب هذه الدورة',
   'message','يمكن إعادة حساب دورة غير معتمدة فقط.','action','عرض التفاصيل');end if;
 perform 1 from finance.profit_distribution_lines where distribution_cycle_id=c.id order by id for update;
 state:=finance.distribution_recalculation_state(c.id);
 select coalesce(jsonb_agg(jsonb_build_object('partner_id',q.partner_id,'name',p.full_name) order by q.partner_id),'[]'::jsonb)
 into affected_partners from(select distinct(x->>'partner_id')::uuid as partner_id from jsonb_array_elements(state->'affected') x)q
 join core.well_partners w on w.id=q.partner_id join core.persons p on p.id=w.person_id;
 result:=jsonb_build_object('state_token',state->>'state_token','manual_adjustments_present',(state->>'manual_adjustments_present')::boolean,
  'affected_partner_count',jsonb_array_length(affected_partners),'affected_partners',affected_partners,
  'recalculation_requires_confirmation',true,'manual_adjustments_will_not_be_carried',true,
  'original_calculation_unknown',(state->>'original_calculation_unknown')::boolean);
 if not p_execute or ((state->>'manual_adjustments_present')::boolean and not p_confirm_manual_adjustments) then
  return result||jsonb_build_object('status','confirmation_required','title',case when(state->>'manual_adjustments_present')::boolean
   then 'تحتاج هذه الدورة إلى مراجعة قبل إعادة الحساب' else 'إعادة حساب التوزيع' end,
   'message',case when(state->>'original_calculation_unknown')::boolean then
    'هذه دورة سابقة لا تتوفر تفاصيل حسابها الأصلي للمقارنة. راجع تعديلات الشركاء قبل إعادة الحساب. سنحتفظ بالحساب السابق ولن ننقل تعديلاته تلقائيًا.'
    when(state->>'manual_adjustments_present')::boolean then
    'توجد خصومات أو تعديلات أُضيفت يدويًا إلى هذه الدورة. عند إعادة الحساب سيتم إنشاء مبالغ جديدة، ولن ننقل هذه التعديلات تلقائيًا حتى لا تُطبق على مبالغ أو شركاء غير صحيحين.'
    else 'ستُعاد حساب مبالغ هذه الدورة باستخدام إعدادات التوزيع الحالية.' end,
   'next_step','بعد إعادة الحساب، راجع النتيجة الجديدة وأضف التعديلات التي ما زلت تحتاجها.',
   'cancel_action','إلغاء','confirm_action','إعادة الحساب ومراجعة النتيجة');
 end if;
 if p_expected_state is null or p_expected_state<>state->>'state_token' then
  return jsonb_build_object('status','review_again','title','تغيّرت بيانات هذه الدورة',
   'message','راجع البيانات الحالية ثم أكّد إعادة الحساب.','action','مراجعة');end if;
 if p_manual_reserve_minor is null or p_manual_reserve_minor<0 then
  raise exception 'distribution_manual_reserve_invalid' using errcode='22023';end if;
 -- Cancel only this unapproved predecessor; all amount rows remain intact.
 -- New calculation and link are atomic: any failure rolls back cancellation.
 update finance.profit_distribution_cycles set status='cancelled' where id=c.id;
 new_id:=finance.calculate_profit_distribution(c.well_id,c.period_start,c.period_end,auth.uid(),p_manual_reserve_minor);
 select coalesce(jsonb_agg(x),'[]'::jsonb) into removed from jsonb_array_elements(state->'affected') x
  where not exists(select 1 from finance.profit_distribution_lines l where l.distribution_cycle_id=new_id and l.partner_id=(x->>'partner_id')::uuid);
 insert into finance.distribution_recalculations(tenant_id,well_id,previous_cycle_id,new_cycle_id,previous_cycle_snapshot,
 previous_lines_snapshot,manual_adjustments_snapshot,removed_partner_adjustments,confirmed_state,actor_id)
 values(c.tenant_id,c.well_id,c.id,new_id,state->'cycle',state->'lines',state->'affected',removed,p_expected_state,auth.uid());
 return result||jsonb_build_object('status','recalculated','previous_cycle_id',c.id,'cycle_id',new_id,
  'removed_partner_adjustments',removed,'review_required',true,'title','تمت إعادة حساب التوزيع',
  'message','تم تحديث مبالغ التوزيع باستخدام الإعدادات الحالية. راجع المبالغ وأضف أي خصومات أو تعديلات مطلوبة قبل الاعتماد.',
  'action','مراجعة التوزيع','removed_partner_notice',case when jsonb_array_length(removed)>0 then jsonb_build_object(
   'title','هناك تعديل سابق يحتاج مراجعة','message','هذا الشريك لم يعد ضمن التوزيع الجديد، وكان لديه تعديل يدوي في الحساب السابق. احتفظنا بالتعديل في السجل ولم ننقله إلى أي شريك آخر.','action','عرض التفاصيل') end);
end;$$;
create function api.get_distribution_configuration(p_well_id uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
begin
 if auth.uid() is null or not(iam.has_well_role(p_well_id,array['owner','manager']) or iam.is_well_partner(p_well_id)) then
  raise exception 'distribution_read_forbidden' using errcode='42501';end if;
 return jsonb_build_object('current',finance.current_distribution_configuration(p_well_id),'history',coalesce((
  select jsonb_agg(to_jsonb(v)||jsonb_build_object('effective_from',v.accepted_at,'superseded_at',v.next_at) order by v.sequence)
  from(select x.*,lead(accepted_at) over(order by sequence) next_at from finance.distribution_configuration_versions x
   where well_id=p_well_id)v),'[]'::jsonb));
end;$$;
revoke all on function api.update_distribution_settings(uuid,boolean),api.set_maintenance_reserve_rule(uuid,text,numeric,bigint),
 api.disable_maintenance_reserve_rule(uuid),api.recalculate_profit_distribution(uuid,boolean,text,bigint,boolean),
 api.get_distribution_configuration(uuid) from public,anon,authenticated,service_role;
grant execute on function api.update_distribution_settings(uuid,boolean),api.set_maintenance_reserve_rule(uuid,text,numeric,bigint),
 api.disable_maintenance_reserve_rule(uuid),api.recalculate_profit_distribution(uuid,boolean,text,bigint,boolean),
 api.get_distribution_configuration(uuid) to authenticated;
do $acl$
declare rel regclass;c record;
begin
 foreach rel in array array['finance.distribution_settings'::regclass,'finance.maintenance_reserve_rules'::regclass] loop
  execute format('revoke insert,update,delete,truncate on %s from public,anon,authenticated,service_role',rel);
  for c in select attname from pg_attribute where attrelid=rel and attnum>0 and not attisdropped loop
   execute format('revoke insert (%I),update (%I) on %s from public,anon,authenticated,service_role',c.attname,c.attname,rel);
  end loop;
 end loop;
end;$acl$;
drop policy if exists distribution_settings_update_owner on finance.distribution_settings;
drop policy if exists maintenance_reserve_rules_insert_owner on finance.maintenance_reserve_rules;
drop policy if exists maintenance_reserve_rules_update_owner on finance.maintenance_reserve_rules;
commit;

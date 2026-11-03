begin;
-- C2B3 only: compensation configuration, not global financial graph closure.
-- Existing range exclusion remains the concurrency-safe no-overlap authority.
alter table finance.worker_compensation_rules
 add column accepted_at timestamptz,
 add column accepted_by uuid references iam.profiles(id),
 add column replaced_at timestamptz,
 add column replaced_by uuid references iam.profiles(id),
 add column replacement_rule_id uuid references finance.worker_compensation_rules(id),
 add column business_timezone text;
create table finance.worker_compensation_changes(
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references core.tenants(id),well_id uuid not null references core.wells(id),
 person_id uuid not null references core.persons(id),
 previous_rule_id uuid references finance.worker_compensation_rules(id),
 new_rule_id uuid references finance.worker_compensation_rules(id),
 operation text not null check(operation in ('create','change','deactivate')),
 effective_from date not null,accepted_at timestamptz not null,actor_id uuid not null references iam.profiles(id),
 business_timezone text not null,before_facts jsonb,after_facts jsonb
);
alter table finance.worker_compensation_changes enable row level security;
revoke all on finance.worker_compensation_changes from public,anon,authenticated,service_role;
grant select on finance.worker_compensation_changes to authenticated;
create policy compensation_changes_read on finance.worker_compensation_changes for select to authenticated
 using(iam.has_well_role(well_id,array['owner','manager']) or iam.is_well_partner(well_id));
create function finance.reject_compensation_history_mutation() returns trigger
language plpgsql set search_path=pg_catalog,pg_temp as $$
begin raise exception 'compensation_history_append_only' using errcode='23514';end;$$;
create trigger compensation_history_immutable before update or delete on finance.worker_compensation_changes
 for each row execute function finance.reject_compensation_history_mutation();
revoke all on function finance.reject_compensation_history_mutation() from public,anon,authenticated,service_role;

create function finance.compensation_effective_date(p_type text,p_zone text,p_accepted timestamptz)
returns date language plpgsql immutable set search_path=pg_catalog,pg_temp as $$
declare d date:=(p_accepted at time zone p_zone)::date;
begin
 if p_type='monthly' then return (date_trunc('month',d::timestamp)+interval '1 month')::date;
 elsif p_type='daily' then return d+1;
 else raise exception 'compensation_type_not_supported' using errcode='22023';end if;
end;$$;
revoke all on function finance.compensation_effective_date(text,text,timestamptz) from public,anon,authenticated,service_role;

-- Private mutation boundary. Discovery reads are provisional. Person is the
-- existing payroll worker identity; no invented profile/person relationship.
create function finance.mutate_worker_compensation(p_well uuid,p_person uuid,p_operation text,
 p_rule uuid,p_type text,p_amount bigint,p_expected_effective_from date)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare tenant uuid;person_tenant uuid;r finance.worker_compensation_rules%rowtype;
 candidate finance.worker_compensation_rules%rowtype;new_id uuid;stamp timestamptz;zone text;effective date;
 before_facts jsonb;after_facts jsonb;new_range daterange;owner_row uuid;
begin
 if auth.uid() is null or not coalesce(iam.has_well_role(p_well,array['owner']),false) then
  raise exception 'compensation_owner_required' using errcode='42501';end if;
 select w.tenant_id into tenant from core.wells w where w.id=p_well;
 if not found then raise exception 'compensation_scope_missing' using errcode='22023';end if;
 if p_operation not in ('create','change','deactivate') or p_operation is null then
  raise exception 'compensation_operation_invalid' using errcode='22023';end if;
 if p_operation<>'create' then
  select x.* into candidate from finance.worker_compensation_rules x where x.id=p_rule;
  if not found or (candidate.well_id,candidate.tenant_id,candidate.person_id) is distinct from(p_well,tenant,p_person) then
   raise exception 'compensation_scope_mismatch' using errcode='42501';end if;
 end if;
 perform billing.lock_customer_credit_well(p_well);
 -- Recheck and lock actor's existing active owner assignment, then payroll
 -- worker identity, BEFORE rule rows. No first root acquisition in a trigger.
 select a.id into owner_row from core.well_assignments a where a.well_id=p_well
  and a.profile_id=auth.uid() and a.status='active' and a.role='owner' order by a.id limit 1 for share of a;
 if not found or not exists(select 1 from core.wells w where w.id=p_well and w.tenant_id=tenant) then
  raise exception 'compensation_owner_required' using errcode='42501';end if;
 select p.tenant_id into person_tenant from core.persons p where p.id=p_person for share of p;
 if not found or person_tenant<>tenant then raise exception 'compensation_worker_scope_invalid' using errcode='42501';end if;
 perform 1 from finance.worker_compensation_rules x where x.well_id=p_well and x.person_id=p_person order by x.id for update of x;
 if p_operation<>'create' then
  select x.* into r from finance.worker_compensation_rules x where x.id=p_rule;
  if not found or (r.well_id,r.tenant_id,r.person_id) is distinct from(p_well,tenant,p_person)
   or r.effective_period is distinct from candidate.effective_period or r.replaced_at is not null then
   raise exception 'compensation_rule_changed' using errcode='40001';end if;
  before_facts:=to_jsonb(r);
 end if;
 zone:=core.well_timezone(p_well);stamp:=clock_timestamp();
 effective:=finance.compensation_effective_date(case when p_operation='deactivate' then r.compensation_type else p_type end,zone,stamp);
 if p_expected_effective_from is not null and p_expected_effective_from<>effective then
  raise exception 'compensation_preview_expired' using errcode='40001';end if;
 if p_operation<>'deactivate' and (p_amount is null or p_amount<=0) then
  raise exception 'compensation_positive_amount_required' using errcode='22023';end if;
 -- No accepted change may alter the rule evidence of an accrued interval,
 -- including an already-accrued future interval. Do not move the date silently.
 if exists(select 1 from finance.payroll_accruals a where a.well_id=p_well and a.person_id=p_person
  and a.status<>'cancelled' and a.period_end>=effective) then
  raise exception 'compensation_effective_date_already_accrued' using errcode='23514';end if;
 if p_operation='create' then
  if exists(select 1 from finance.worker_compensation_rules x where x.well_id=p_well and x.person_id=p_person
   and x.effective_period && daterange(effective,null,'[)')) then
   raise exception 'compensation_rule_already_effective' using errcode='23514';end if;
 else
  -- Closing a pending version at its own start creates an empty retained
  -- historical range. Moving an unrelated later boundary backwards is denied.
  if lower_inf(r.effective_period) then null;
  elsif lower(r.effective_period)>effective then raise exception 'compensation_pending_boundary_conflict' using errcode='23514';end if;
  if not upper_inf(r.effective_period) then raise exception 'compensation_rule_not_current_head' using errcode='23514';end if;
  update finance.worker_compensation_rules set effective_period=daterange(lower(r.effective_period),effective,'[)'),
   replaced_at=stamp,replaced_by=auth.uid() where id=r.id;
 end if;
 if p_operation<>'deactivate' then
  new_range:=daterange(effective,null,'[)');
  insert into finance.worker_compensation_rules(tenant_id,well_id,person_id,compensation_type,rate_amount_minor,
   effective_period,accepted_at,accepted_by,business_timezone)
  values(tenant,p_well,p_person,p_type,p_amount,new_range,stamp,auth.uid(),zone) returning id into new_id;
  select to_jsonb(x) into after_facts from finance.worker_compensation_rules x where x.id=new_id;
  if p_operation='change' then update finance.worker_compensation_rules set replacement_rule_id=new_id where id=r.id;end if;
 end if;
 insert into finance.worker_compensation_changes(tenant_id,well_id,person_id,previous_rule_id,new_rule_id,operation,
  effective_from,accepted_at,actor_id,business_timezone,before_facts,after_facts)
 values(tenant,p_well,p_person,p_rule,new_id,p_operation,effective,stamp,auth.uid(),zone,before_facts,after_facts);
 return jsonb_build_object('operation',p_operation,'rule_id',new_id,'previous_rule_id',p_rule,
  'effective_from',effective,'accepted_at',stamp,'timezone',zone,'status','scheduled');
end;$$;
revoke all on function finance.mutate_worker_compensation(uuid,uuid,text,uuid,text,bigint,date) from public,anon,authenticated,service_role;

create function api.create_worker_compensation_rule(p_well_id uuid,p_person_id uuid,p_compensation_type text,p_amount_minor bigint,p_expected_effective_from date default null) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$

begin
 return finance.mutate_worker_compensation(p_well_id,p_person_id,'create',null,p_compensation_type,p_amount_minor,p_expected_effective_from);
end;$$;
revoke all on function api.create_worker_compensation_rule(uuid,uuid,text,bigint,date) from public,anon,authenticated,service_role;
grant execute on function api.create_worker_compensation_rule(uuid,uuid,text,bigint,date) to authenticated;

create function api.update_worker_compensation_rule(p_rule_id uuid,p_compensation_type text,p_amount_minor bigint,p_expected_effective_from date default null) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare r finance.worker_compensation_rules%rowtype;
begin select x.* into r from finance.worker_compensation_rules x where x.id=p_rule_id;
 if not found then raise exception 'compensation_rule_missing' using errcode='22023';end if;
 return finance.mutate_worker_compensation(r.well_id,r.person_id,'change',p_rule_id,p_compensation_type,p_amount_minor,p_expected_effective_from);
end;$$;
revoke all on function api.update_worker_compensation_rule(uuid,text,bigint,date) from public,anon,authenticated,service_role;
grant execute on function api.update_worker_compensation_rule(uuid,text,bigint,date) to authenticated;

create function api.deactivate_worker_compensation_rule(p_rule_id uuid,p_expected_effective_from date default null) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare r finance.worker_compensation_rules%rowtype;
begin select x.* into r from finance.worker_compensation_rules x where x.id=p_rule_id;
 if not found then raise exception 'compensation_rule_missing' using errcode='22023';end if;
 return finance.mutate_worker_compensation(r.well_id,r.person_id,'deactivate',p_rule_id,null,null,p_expected_effective_from);
end;$$;
revoke all on function api.deactivate_worker_compensation_rule(uuid,date) from public,anon,authenticated,service_role;
grant execute on function api.deactivate_worker_compensation_rule(uuid,date) to authenticated;

-- Exact server preview date must be displayed before owner confirmation. Save
-- can echo that date as an expectation, never as financial date authority.
create function api.preview_worker_compensation_effective_date(p_well_id uuid,p_compensation_type text)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare zone text;stamp timestamptz:=clock_timestamp();
begin
 if auth.uid() is null or not coalesce(iam.has_well_role(p_well_id,array['owner']),false) then
  raise exception 'compensation_owner_required' using errcode='42501';end if;
 zone:=core.well_timezone(p_well_id);
 return jsonb_build_object('effective_from',finance.compensation_effective_date(p_compensation_type,zone,stamp),
  'timezone',zone,'server_now',stamp,'compensation_type',p_compensation_type);
end;$$;
revoke all on function api.preview_worker_compensation_effective_date(uuid,text) from public,anon,authenticated,service_role;
grant execute on function api.preview_worker_compensation_effective_date(uuid,text) to authenticated;

create function api.get_worker_compensation_history(p_well_id uuid,p_person_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare d date;zone text;
begin
 if auth.uid() is null or not(iam.has_well_role(p_well_id,array['owner','manager']) or iam.is_well_partner(p_well_id)) then
  raise exception 'compensation_read_forbidden' using errcode='42501';end if;
 zone:=core.well_timezone(p_well_id);d:=(clock_timestamp() at time zone zone)::date;
 return jsonb_build_object('timezone',zone,'business_date',d,'versions',coalesce((select jsonb_agg(
  to_jsonb(r)||jsonb_build_object('effective_from',lower(r.effective_period),'effective_until_exclusive',upper(r.effective_period),
   'status',case when isempty(r.effective_period) then 'replaced' when r.effective_period @> d then 'active'
    when lower(r.effective_period)>d then 'future' else 'inactive' end) order by r.created_at,r.id)
  from finance.worker_compensation_rules r where r.well_id=p_well_id and r.person_id=p_person_id),'[]'::jsonb),
  'changes',coalesce((select jsonb_agg(to_jsonb(c) order by c.accepted_at,c.id) from finance.worker_compensation_changes c
   where c.well_id=p_well_id and c.person_id=p_person_id),'[]'::jsonb));
end;$$;
revoke all on function api.get_worker_compensation_history(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function api.get_worker_compensation_history(uuid,uuid) to authenticated;

-- Restrict rule-based accrual to a SINGLE version covering the entire closed
-- date interval. Explicit-gross mode still has no automatic rule authority;
-- the full period must have one version in either mode.
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
-- Existing persisted payroll rows are never recomputed by rule mutations.
-- Protect accrued amount/period/worker identity from direct destructive edits.
create function finance.guard_accrued_payroll_facts() returns trigger language plpgsql
set search_path=pg_catalog,pg_temp as $$
begin
 if tg_op='DELETE' then raise exception 'accrued_payroll_immutable' using errcode='23514';end if;
 if (new.tenant_id,new.well_id,new.person_id,new.period_start,new.period_end,new.gross_amount_minor,new.deductions_minor,new.net_amount_minor)
 is distinct from(old.tenant_id,old.well_id,old.person_id,old.period_start,old.period_end,old.gross_amount_minor,old.deductions_minor,old.net_amount_minor) then
  raise exception 'accrued_payroll_immutable' using errcode='23514';end if;
 return new;
end;$$;
create trigger accrued_payroll_facts_immutable before update or delete on finance.payroll_accruals
 for each row execute function finance.guard_accrued_payroll_facts();
revoke all on function finance.guard_accrued_payroll_facts() from public,anon,authenticated,service_role;
do $acl$
declare col record;
begin
 revoke insert,update,delete,truncate on finance.worker_compensation_rules from public,anon,authenticated,service_role;
 for col in select attname from pg_attribute where attrelid='finance.worker_compensation_rules'::regclass and attnum>0 and not attisdropped loop
  execute format('revoke insert (%I),update (%I) on finance.worker_compensation_rules from public,anon,authenticated,service_role',col.attname,col.attname);
 end loop;
end;$acl$;
drop policy if exists worker_compensation_rules_insert_owner_manager on finance.worker_compensation_rules;
drop policy if exists worker_compensation_rules_update_owner_manager on finance.worker_compensation_rules;
commit;

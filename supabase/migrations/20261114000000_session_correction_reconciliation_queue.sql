-- Server-only durable delivery; no Cron or HTTP queue surface.
begin;
create extension if not exists pgmq;
do $$begin
 if not exists(select 1 from pgmq.list_queues() where queue_name='session_correction_reconciliation') then
  perform pgmq.create('session_correction_reconciliation');
 end if;
 if not exists(select 1 from pgmq.list_queues() where queue_name='session_correction_reconciliation'
  and not is_unlogged and not is_partitioned)
 or exists(select 1 from pg_class where oid in ('pgmq.q_session_correction_reconciliation'::regclass,
  'pgmq.a_session_correction_reconciliation'::regclass) and relpersistence<>'p') then
  raise exception 'reconciliation_queue_must_be_logged_basic';
 end if;
 if not exists(select 1 from pg_roles where rolname='reconciliation_executor') then
  create role reconciliation_executor nologin noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls;
 end if;
 -- Fail closed on a pre-existing role with broader authority or memberships.
 if exists(select 1 from pg_roles where rolname='reconciliation_executor' and
  (rolcanlogin or rolinherit or rolsuper or rolcreatedb or rolcreaterole or rolreplication or rolbypassrls))
 or exists(select 1 from pg_auth_members where member='reconciliation_executor'::regrole) then
  raise exception 'reconciliation_executor_role_not_isolated';
 end if;
end;$$;
-- Existing DB transport connects as postgres, then SET LOCAL ROLE.
grant reconciliation_executor to postgres;

-- One canonical permission authority. Actor selection is confined to trusted
-- definers: the existing interactive/P2 helper and the private worker cores.
create function iam.has_well_permission_for_actor(
 p_well_id uuid,p_permission_code text,p_actor_id uuid
) returns boolean language sql stable security definer set search_path=pg_catalog,pg_temp as $$
 select exists (
  select 1 from core.well_assignments wa
  join iam.well_assignment_role_map arm on arm.assignment_role=wa.role
  join iam.role_permissions rp on rp.role_id=arm.role_id
  join iam.permissions perm on perm.id=rp.permission_id
  where wa.well_id=p_well_id and wa.profile_id=p_actor_id
   and wa.status='active' and perm.code=p_permission_code
 );
$$;
create or replace function iam.has_well_permission(p_well_id uuid,p_permission_code text)
returns boolean language sql stable security definer set search_path=pg_catalog,pg_temp as $$
 select iam.has_well_permission_for_actor(p_well_id,p_permission_code,ops.current_execution_operator());
$$;
create function billing.reconciliation_actor_authorized(p_well uuid,p_actor uuid) returns boolean
language sql stable security definer set search_path=pg_catalog,pg_temp as $$
 select iam.has_well_permission_for_actor(p_well,'session.correct',p_actor);
$$;

-- Explicit actor implementations are the sole financial business bodies.
-- Existing signatures below retain auth.uid() and forward without changing
-- validation, locking, receipts, posting or response semantics.
create function billing.post_session_correction_delta_core(p_actor_id uuid,p_correction uuid,p_invoice uuid,p_evidence jsonb,p_previous jsonb,
 p_posted_at timestamptz) returns uuid language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c ops.session_corrections%rowtype;i billing.invoices%rowtype;j uuid;x record;delta bigint;
begin
 select * into strict c from ops.session_corrections where id=p_correction;
 select * into strict i from billing.invoices where id=p_invoice;
 if p_actor_id is null or not coalesce(iam.has_well_permission_for_actor(c.well_id,'session.correct',p_actor_id),false)
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
 if j is not null then perform finance.post_journal_entry(j,p_actor_id);end if;
 return j;
end;$$;

create function billing.adjust_credit_application_core(p_actor_id uuid,p_application uuid,p_operation text,p_amount bigint,
 p_source uuid,p_revision bigint,p_reason text,p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare a billing.account_credit_applications%rowtype;c billing.account_credits%rowtype;i billing.invoices%rowtype;
 actor uuid:=p_actor_id;req jsonb;r jsonb;e uuid:=gen_random_uuid();adj uuid:=gen_random_uuid();j uuid;
 b record;available numeric;review text;op text;cycles jsonb:='[]'::jsonb;
begin
 select * into strict a from billing.account_credit_applications where id=p_application;
 if actor is null or not coalesce(iam.has_well_permission_for_actor(a.well_id,'session.correct',p_actor_id),false) then
  raise exception 'application_adjustment_forbidden' using errcode='42501';end if;
 if p_operation is null or p_operation not in ('release','restore') or p_amount is null or p_amount<=0
  or nullif(btrim(p_reason),'') is null or p_posted_at is null or not isfinite(p_posted_at) then
  raise exception 'application_adjustment_facts_required' using errcode='22023';end if;
 op:='application_'||p_operation;
 req:=jsonb_build_object('operation',op,'application_id',p_application,'amount_minor',p_amount,'reason',p_reason,
  'actor',actor,'origin_source_id',coalesce(p_origin_id,p_source),
  'posted_at',to_char(p_posted_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
 perform billing.lock_customer_credit_well(a.well_id);
 r:=billing.credit_event_replay(a.tenant_id,p_source,p_revision,req);if r is not null then return r;end if;
 perform 1 from ops.farmer_well_accounts where id=a.farmer_well_account_id for update;
 select * into strict c from billing.account_credits where id=a.credit_id;
 perform 1 from billing.payments where id=c.payment_id for update;
 perform 1 from billing.account_credits where id=c.id for update;
 perform 1 from billing.account_credit_applications where id=a.id for update;
 select * into strict i from billing.invoices where id=a.invoice_id for update;
 select * into strict b from billing.effective_account_credit_applications where id=a.id;
 select available_minor into available from billing.account_credit_balances where id=c.id;
 if p_operation='release' and p_amount>b.effective_amount_minor
  or p_operation='restore' and p_amount>b.amount_minor-b.effective_amount_minor then
  raise exception 'application_adjustment_out_of_range' using errcode='23514';end if;
 if exists(select 1 from billing.account_credit_reversals where credit_id=c.id and receivable_review_minor>0) then
  review:='source_reversal_review_required';
 elsif i.deducted_in_cycle_id is not null then review:='distribution_reconciliation_required';
 elsif i.status not in ('issued','partially_paid','paid','overdue') then review:='invoice_state_requires_review';
 elsif p_operation='restore' and p_amount>available then review:='credit_unavailable';
 elsif p_operation='restore' and p_amount>i.outstanding_minor then review:='invoice_debt_unavailable';end if;
 if review is null then
  begin
   -- قيد فرق جديد؛ لا عكس للقيد الأصلي أو تغيير لتاريخه. المعاملة الفرعية
   -- تعيد كل أثر مالي عند رفض الفترة، ثم يحفظ طلب المراجعة خارجه.
   j:=billing.post_customer_credit_entry(e,a.tenant_id,a.well_id,a.farmer_well_account_id,
    p_amount,p_operation='release',p_posted_at,actor);
   insert into billing.account_credit_application_adjustments(id,event_id,tenant_id,well_id,farmer_well_account_id,
    application_id,operation,amount_minor,source_id,origin_source_id,source_revision,request_payload,reason,created_by,status,journal_entry_id)
   values(adj,e,a.tenant_id,a.well_id,a.farmer_well_account_id,a.id,p_operation,p_amount,p_source,
    coalesce(p_origin_id,p_source),p_revision,req,p_reason,actor,'accepted',j);
   cycles:=billing.invalidate_pending_credit_distributions(a.well_id);
  exception when raise_exception then
   if SQLERRM like 'لا يمكن ترحيل القيد: الفترة المحاسبية المحتوية للتاريخ % مغلقة' then
    review:='accounting_period_closed';j:=null;
   else raise;end if;
  end;
 end if;
 if review is not null then
  insert into billing.account_credit_application_adjustments(id,event_id,tenant_id,well_id,farmer_well_account_id,
   application_id,operation,amount_minor,source_id,origin_source_id,source_revision,request_payload,reason,created_by,status,review_reason)
  values(adj,e,a.tenant_id,a.well_id,a.farmer_well_account_id,a.id,p_operation,p_amount,p_source,
   coalesce(p_origin_id,p_source),p_revision,req,p_reason,actor,'financial_review_required',review);
 end if;
 select * into strict b from billing.effective_account_credit_applications where id=a.id;
 select available_minor into available from billing.account_credit_balances where id=c.id;
 r:=jsonb_build_object('status',case when review is null then 'accepted' else 'financial_review_required' end,
  'event_id',e,'adjustment_id',adj,'application_id',a.id,'credit_id',c.id,'invoice_id',a.invoice_id,
  'operation',p_operation,'requested_minor',p_amount,'applied_minor',case when review is null then p_amount else 0 end,
  'effective_application_minor',b.effective_amount_minor,'credit_available_minor',available,
  'reason',review,'invalidated_distribution_cycles',cycles);
 insert into billing.customer_credit_events(id,tenant_id,well_id,farmer_well_account_id,source_id,origin_source_id,source_revision,
  operation,request_payload,result_payload,reason,created_by,journal_entry_id)
 values(e,a.tenant_id,a.well_id,a.farmer_well_account_id,p_source,coalesce(p_origin_id,p_source),p_revision,
  op,req,r,p_reason,actor,j);
 return r;
end;$$;

create function billing.repartition_payment_internal_core(p_actor_id uuid,p_payment uuid,p_allocation uuid,p_credit uuid,p_amount bigint,
 p_mode text,p_source uuid,p_revision bigint,p_reason text,p_posted_at timestamptz,p_origin uuid default null,p_parent uuid default null)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare p billing.payments%rowtype;a billing.payment_allocations%rowtype;c billing.account_credits%rowtype;i billing.invoices%rowtype;
 actor uuid:=p_actor_id;req jsonb;r jsonb;e uuid:=gen_random_uuid();j uuid;aid uuid;credit uuid;operation text;
 before_state record;after_state record;x record;review text;amount bigint;credit_amount bigint:=0;needed bigint:=0;
 credit_left bigint;take bigint;restorable bigint;released_credit bigint;before_direct numeric:=0;direct_gain numeric:=0;child_source uuid;child jsonb;target uuid:=p_allocation;cycles jsonb:='[]';extra numeric;
begin
 select * into strict p from billing.payments where id=p_payment;
 if actor is null or not coalesce(iam.has_well_permission_for_actor(p.well_id,'session.correct',p_actor_id),false) then
  raise exception 'payment_repartition_forbidden' using errcode='42501';end if;
 if p_mode is null or p_mode not in ('release','restore','rebalance','reverse','withdraw')
  or (p_mode<>'rebalance' and (p_amount is null or p_amount<=0)) or(p_mode='rebalance' and p_amount is not null)
  or nullif(btrim(p_reason),'') is null or p_posted_at is null or not isfinite(p_posted_at)
  or ((p_mode='withdraw') is distinct from (p_parent is not null)) then
  raise exception 'payment_repartition_facts_required' using errcode='22023';end if;
 operation:=case p_mode when 'release' then 'release' when 'reverse' then 'reverse'
  when 'restore' then 'restore_allocation' when 'rebalance' then 'rebalance_payment' else 'partition_withdraw' end;
 req:=jsonb_build_object('operation',operation,'reason',p_reason,'actor',actor,'origin_source_id',coalesce(p_origin,p_source),
  'posted_at',to_char(p_posted_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
 if p_mode='release' then req:=req||jsonb_build_object('allocation',p_allocation,'amount',p_amount);
 elsif p_mode='reverse' then req:=req||jsonb_build_object('credit',p_credit,'amount',p_amount);
 else req:=req||jsonb_build_object('payment',p_payment,'allocation',p_allocation,'credit',p_credit,'amount',p_amount,'parent',p_parent);end if;
perform billing.lock_customer_credit_well(p.well_id);
 if not coalesce(iam.has_well_permission_for_actor(p.well_id,'session.correct',p_actor_id),false) then
  raise exception 'payment_repartition_forbidden' using errcode='42501';end if;
 r:=billing.credit_event_replay(p.tenant_id,p_source,p_revision,req);if r is not null then return r;end if;
 perform 1 from ops.farmer_well_accounts where id=p.farmer_well_account_id for update;
 select * into strict p from billing.payments where id=p.id for update;
 if p.status<>'posted' then raise exception 'payment_repartition_ineligible' using errcode='23514';end if;
 if p_mode='rebalance' and p.purpose='advance' then
  raise exception 'cash_advance_rebalance_not_required' using errcode='22023';end if;
 select * into strict before_state from billing.payment_economic_applications where payment_id=p.id;
 amount:=coalesce(p_amount,before_state.remaining_minor::bigint);
 if before_state.default_session_charge_id is not null then
  select direct_settled_minor into before_direct from billing.session_economic_settlements
   where session_charge_id=before_state.default_session_charge_id;
 end if;
 if p_mode in ('reverse','withdraw') then
  select * into strict c from billing.account_credits where id=p_credit for update;
  if (c.tenant_id,c.well_id,c.farmer_well_account_id,c.payment_id) is distinct from
    (p.tenant_id,p.well_id,p.farmer_well_account_id,p.id) then
   raise exception 'payment_credit_scope_mismatch' using errcode='23514';end if;
  if p_mode='reverse' then
   select allocation_id into target from billing.payment_allocation_adjustments where id=c.allocation_adjustment_id;
   if target is null then select allocation_id into target from billing.payment_repartition_events where event_id=c.repartition_event_id;end if;
  end if;
 end if;
 if target is not null then
  select * into strict a from billing.payment_allocations where id=target for update;
  select * into strict i from billing.invoices where id=a.invoice_id for update;
  select outstanding_minor into i.outstanding_minor from billing.invoice_effective_balances where invoice_id=i.id;
  if a.payment_id<>p.id or a.tenant_id<>p.tenant_id or i.tenant_id<>p.tenant_id or i.well_id<>p.well_id
   or i.farmer_well_account_id<>p.farmer_well_account_id then raise exception 'payment_allocation_scope_mismatch' using errcode='23514';end if;
  if billing.invoice_has_protected_distribution_use(i.id) then
   if p_mode='release' then
    raise exception 'allocation_release_requires_distribution_review' using errcode='23514';end if;
   review:='distribution_reconciliation_required';
  elsif i.status not in ('issued','paid','partially_paid','overdue') then review:='invoice_state_requires_review';end if;
  select effective_allocated_minor into extra from billing.effective_payment_allocations where id=a.id;
  restorable:=(a.allocated_minor-extra)::bigint;
  if p_mode='release' and amount>extra or p_mode<>'release' and amount>a.allocated_minor-extra then
   raise exception 'payment_allocation_adjustment_out_of_range' using errcode='23514';end if;
 elsif p_mode in ('release','restore') then raise exception 'payment_allocation_required' using errcode='22023';end if;
 if p_mode in ('restore','reverse') and target is not null then
  extra:=0;
  if i.session_id=(select session_id from billing.session_charges where id=p.session_charge_id) then
   select direct_settled_minor into extra from billing.session_economic_settlements where session_charge_id=p.session_charge_id;
  end if;
  if amount>i.outstanding_minor+coalesce(extra,0) then review:='invoice_debt_unavailable';end if;
  if p_mode='reverse' then needed:=amount;
  else
   select least(restorable,coalesce(sum(b.amount_minor-b.reversed_minor),0)) into released_credit
    from billing.account_credit_balances b join billing.account_credits src on src.id=b.id
    left join billing.payment_allocation_adjustments ax on ax.id=src.allocation_adjustment_id
    left join billing.payment_repartition_events px on px.event_id=src.repartition_event_id
    where b.payment_id=p.id and (ax.allocation_id=a.id or px.allocation_id=a.id);
   needed:=greatest(amount-greatest(restorable-released_credit,0),0)::bigint;
  end if;
  if amount-needed>before_state.direct_capacity_minor then review:='payment_capacity_used_elsewhere';end if;
 elsif p_mode in ('reverse','withdraw') then
  needed:=amount;
  if p_mode='reverse' and (p.purpose<>'session' or p.session_charge_id is null or amount>coalesce((
    select greatest(debt_minor-settled_minor,0) from billing.session_economic_settlements where session_charge_id=p.session_charge_id),0)) then
   review:='default_destination_unavailable';end if;
 end if;
 if needed>0 then
  select coalesce(sum(b.available_minor),0) into extra from billing.account_credit_balances b
   where b.payment_id=p.id and (p_credit is null or b.id=p_credit)
    and (target is null or exists(select 1 from billing.account_credits src
     left join billing.payment_allocation_adjustments ax on ax.id=src.allocation_adjustment_id
     left join billing.payment_repartition_events px on px.event_id=src.repartition_event_id
     where src.id=b.id and (ax.allocation_id=target or px.allocation_id=target)));
  if needed>extra then review:='credit_already_used_requires_reconciliation';end if;
 end if;
 -- تاريخ التصحيح الصريح هو سياق الترحيل؛ لا نختار فترة مفتوحة بديلة تلقائيًا.
 -- التحرير في فترة مغلقة يرفض قبل أول أثر، حتى إن لم يتطلب قيدًا محاسبيًا.
 if p_mode='release' then
  perform 1 from finance.accounting_periods ap where ap.well_id=p.well_id
   and p_posted_at::date between ap.starts_at and ap.ends_at order by ap.id for share;
  if exists(select 1 from finance.accounting_periods ap
   where ap.well_id=p.well_id and p_posted_at::date between ap.starts_at and ap.ends_at and ap.status='closed') then
   raise exception 'لا يمكن ترحيل القيد: الفترة المحاسبية المحتوية للتاريخ % مغلقة',p_posted_at::date;
  end if;
 end if;
 if review is null then
  begin
   if p_mode='release' then
    insert into billing.payment_allocation_adjustments(tenant_id,well_id,farmer_well_account_id,allocation_id,event_id,operation,amount_minor,reason,created_by)
    values(p.tenant_id,p.well_id,p.farmer_well_account_id,a.id,e,'release',amount,p_reason,actor) returning id into aid;
    select * into strict after_state from billing.payment_economic_applications where payment_id=p.id;
    if before_state.default_session_charge_id is not null then
     select direct_settled_minor-before_direct into direct_gain from billing.session_economic_settlements
      where session_charge_id=before_state.default_session_charge_id;
    end if;
    if direct_gain<0 or direct_gain>amount then raise exception 'payment_default_recovery_invalid' using errcode='23514';end if;
    credit_amount:=(amount-direct_gain)::bigint;
   elsif p_mode='rebalance' then credit_amount:=amount;
   elsif p_mode='withdraw' or (p_mode='reverse' and target is null) then
    select c.amount_minor-coalesce(sum(requested_minor),0) into credit_left from billing.account_credit_reversals where credit_id=c.id;
    if amount>credit_left then raise exception 'credit_reversal_out_of_range' using errcode='23514';end if;
    insert into billing.account_credit_reversals(tenant_id,well_id,farmer_well_account_id,credit_id,event_id,requested_minor,
     restored_minor,held_minor,receivable_review_minor,status,reason,created_by)
    values(p.tenant_id,p.well_id,p.farmer_well_account_id,c.id,e,amount,amount,0,0,'accepted',p_reason,actor);
    credit:=c.id;credit_amount:=amount;
    j:=billing.post_customer_credit_entry(e,p.tenant_id,p.well_id,p.farmer_well_account_id,amount,false,p_posted_at,actor);
   else
    -- هوية كل أثر فرعي مشتقة بثبات من المصدر/مراجعته والرصيد، لا بديل للأصل.
    credit_left:=needed;
    for x in select b.id,b.available_minor from billing.account_credit_balances b where b.payment_id=p.id
     and (p_credit is null or b.id=p_credit) and b.available_minor>0
     and exists(select 1 from billing.account_credits src
      left join billing.payment_allocation_adjustments ax on ax.id=src.allocation_adjustment_id
      left join billing.payment_repartition_events px on px.event_id=src.repartition_event_id
      where src.id=b.id and (ax.allocation_id=target or px.allocation_id=target))
     order by b.created_at,b.id loop
     exit when credit_left=0;take:=least(credit_left,x.available_minor)::bigint;
     child_source:=md5(p_source::text||':'||p_revision::text||':withdraw:'||x.id::text)::uuid;
     child:=billing.repartition_payment_internal_core(p_actor_id,p.id,null,x.id,take,'withdraw',child_source,p_revision,p_reason,p_posted_at,coalesce(p_origin,p_source),e);
     if child->>'status'<>'accepted' then
      if child->>'reason'='accounting_period_closed' then
       raise exception 'لا يمكن ترحيل القيد: الفترة المحاسبية المحتوية للتاريخ % مغلقة',p_posted_at::date;
      end if;
      raise exception 'partition_credit_withdrawal_incomplete' using errcode='23514';end if;
     credit_left:=credit_left-take;
    end loop;
    if credit_left<>0 then raise exception 'partition_credit_withdrawal_incomplete' using errcode='23514';end if;
    insert into billing.payment_allocation_adjustments(tenant_id,well_id,farmer_well_account_id,allocation_id,event_id,operation,amount_minor,reason,created_by)
    values(p.tenant_id,p.well_id,p.farmer_well_account_id,a.id,e,'restore',amount,p_reason,actor) returning id into aid;
    credit_amount:=needed;
    if p.purpose='advance' and amount-needed>0 then
     j:=billing.post_customer_credit_entry(e,p.tenant_id,p.well_id,p.farmer_well_account_id,amount-needed,false,p_posted_at,actor);
    end if;
   end if;
   if p_mode in ('release','rebalance') and credit_amount>0 then
    credit:=gen_random_uuid();
    j:=billing.post_customer_credit_entry(e,p.tenant_id,p.well_id,p.farmer_well_account_id,credit_amount,true,p_posted_at,actor);
    -- الحدث المالي الأصل والرصيد يتحققان معًا بقيود مؤجلة.
    insert into billing.payment_repartition_events(event_id,parent_event_id,payment_id,tenant_id,well_id,farmer_well_account_id,
     mode,allocation_id,allocation_adjustment_id,credit_id,amount_minor,credit_amount_minor,status,journal_entry_id)
    values(e,p_parent,p.id,p.tenant_id,p.well_id,p.farmer_well_account_id,p_mode,target,aid,credit,amount,credit_amount,'accepted',j);
    insert into billing.account_credits(id,tenant_id,well_id,farmer_well_account_id,payment_id,allocation_adjustment_id,repartition_event_id,event_id,
     source_type,source_id,origin_source_id,source_revision,amount_minor,reason,created_by)
    values(credit,p.tenant_id,p.well_id,p.farmer_well_account_id,p.id,
     case when p_mode='release' and p.purpose<>'session' then aid end,
     case when p_mode='release' and p.purpose<>'session' then null else e end,e,
     case when p_mode='release' and p.purpose<>'session' then 'allocation_release' else 'payment_repartition' end,p_source,
     coalesce(p_origin,p_source),p_revision,credit_amount,p_reason,actor);
   end if;
   perform billing.refresh_partition_invoices(p.well_id);
   cycles:=billing.invalidate_pending_credit_distributions(p.well_id);
  exception when raise_exception then
   if SQLERRM like 'لا يمكن ترحيل القيد: الفترة المحاسبية المحتوية للتاريخ % مغلقة' then
    if p_mode='release' then raise;end if;
    review:='accounting_period_closed';j:=null;credit:=null;aid:=null;credit_amount:=0;
   else raise;end if;
  end;
 end if;
 if not exists(select 1 from billing.payment_repartition_events where event_id=e) then
  insert into billing.payment_repartition_events(event_id,parent_event_id,payment_id,tenant_id,well_id,farmer_well_account_id,
   mode,allocation_id,allocation_adjustment_id,credit_id,amount_minor,credit_amount_minor,status,review_reason,journal_entry_id)
  values(e,p_parent,p.id,p.tenant_id,p.well_id,p.farmer_well_account_id,p_mode,target,aid,credit,amount,credit_amount,
   case when review is null then 'accepted' else 'financial_review_required' end,review,j);
 end if;
 select * into strict after_state from billing.payment_economic_applications where payment_id=p.id;
 r:=jsonb_build_object('status',case when review is null then 'accepted' else 'financial_review_required' end,'event_id',e,
  'adjustment_id',aid,'credit_id',credit,'payment_id',p.id,'amount_minor',amount,'credit_amount_minor',credit_amount,
  'direct_settled_minor',after_state.effective_direct_minor,'remaining_minor',after_state.remaining_minor,
  'restored_minor',case when review is null and p_mode in ('restore','reverse','withdraw') then amount else 0 end,
  'released_minor',case when review is null and p_mode='release' then amount else 0 end,
  'reason',review,'invalidated_distribution_cycles',cycles);
 insert into billing.customer_credit_events(id,tenant_id,well_id,farmer_well_account_id,source_id,origin_source_id,source_revision,
  operation,request_payload,result_payload,reason,created_by,journal_entry_id)
 values(e,p.tenant_id,p.well_id,p.farmer_well_account_id,p_source,coalesce(p_origin,p_source),p_revision,operation,req,r,p_reason,actor,j);
 return r;
end;$$;

create function billing.reconcile_session_correction_core(p_actor_id uuid,p_correction uuid,p_command_id uuid,p_posted_at timestamptz)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c ops.session_corrections%rowtype;work ops.session_correction_reconciliations%rowtype;
 s ops.irrigation_sessions%rowtype;ch billing.effective_session_charges%rowtype;i billing.invoices%rowtype;
 actor uuid:=p_actor_id;pc sync.processed_commands%rowtype;req jsonb;guard jsonb;result jsonb;evidence jsonb;previous jsonb;
 x record;child jsonb;children jsonb:='[]';source uuid;account uuid;j uuid;new_amount bigint;old_invoice bigint;
 excess numeric;take bigint;invoice_count bigint;code text;error_detail text;errstate text;event billing.customer_credit_events%rowtype;
begin
 select * into c from ops.session_corrections where id=p_correction;
 if actor is null or not found or not exists(select 1 from core.well_assignments a where a.well_id=c.well_id
   and a.profile_id=actor and a.status='active') or not coalesce(iam.has_well_permission_for_actor(c.well_id,'session.correct',p_actor_id),false) then
  raise exception 'session_financial_reconciliation_forbidden' using errcode='42501';end if;
 if p_command_id is null then raise exception 'session_financial_command_required' using errcode='22023';end if;
 -- C0.2-compatible order: financial well, operational well, session, work,
 -- account, then payment/credit/invoice rows under the same financial lock.
 -- Never hold session/work and THEN wait for the financial well lock.
 perform billing.lock_customer_credit_well(c.well_id);
 perform ops.lock_operational_scope(c.well_id,true);
 select * into strict s from ops.irrigation_sessions where id=c.session_id for update;
 select * into strict work from ops.session_correction_reconciliations where correction_id=c.id for update;
 if s.well_id<>c.well_id or not exists(select 1 from core.wells w where w.id=c.well_id and w.tenant_id=c.tenant_id)
   or not exists(select 1 from core.well_assignments a where a.well_id=c.well_id and a.profile_id=actor and a.status='active')
   or not coalesce(iam.has_well_permission_for_actor(c.well_id,'session.correct',p_actor_id),false) then
  raise exception 'session_financial_reconciliation_forbidden' using errcode='42501';end if;
 req:=jsonb_build_object('contract','session_financial_reconciliation','version',1,'correction_id',c.id,
  'session_id',c.session_id,'tenant_id',c.tenant_id,'well_id',c.well_id,'operational_revision',c.new_revision,
  'actor_id',actor,'posting_timezone',current_setting('TimeZone'),
  'posted_at',to_char(p_posted_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
 select * into pc from sync.processed_commands where tenant_id=c.tenant_id and command_id=p_command_id;
 if found then
  if pc.command_type is distinct from 'reconcile_session_correction' or pc.entity_id is distinct from c.id
    or pc.request_payload is distinct from req then
   raise exception 'session_financial_idempotency_conflict' using errcode='22023';end if;
  if pc.status<>'accepted' then raise exception 'session_financial_result_unresolved' using errcode='55000';end if;
  return pc.response_payload;
 end if;
 if work.status='applied' then raise exception 'session_financial_idempotency_conflict' using errcode='22023';end if;
 if exists(select 1 from ops.session_correction_reconciliations r where r.session_id=c.session_id
  and r.operational_revision<c.new_revision and r.status<>'applied') then
  -- No attempt was started or reserved; this is an internal readiness result.
  return jsonb_build_object('status','pending','correction_id',c.id,'reason','predecessor_not_applied','attempt_started',false,
   'operational_revision',c.new_revision,'financial_applied_revision',coalesce((select financial_applied_revision
    from billing.effective_session_charges where session_id=c.session_id),0));
 end if;
 guard:=sync.begin_command(c.tenant_id,p_command_id,'reconcile_session_correction',req,c.id);
 if coalesce((guard->>'duplicate')::boolean,false) then
  select * into strict pc from sync.processed_commands where tenant_id=c.tenant_id and command_id=p_command_id;
  if pc.command_type is distinct from 'reconcile_session_correction' or pc.entity_id is distinct from c.id
   or pc.request_payload is distinct from req then raise exception 'session_financial_idempotency_conflict' using errcode='22023';end if;
  if pc.status<>'accepted' then raise exception 'session_financial_result_unresolved' using errcode='55000';end if;
  return pc.response_payload;
 end if;
 update ops.session_correction_reconciliations set attempt_count=attempt_count+1,last_attempt_at=clock_timestamp(),
  last_reconciliation_command_id=p_command_id,last_financial_request=req where correction_id=c.id;
 begin
  if exists(select 1 from billing.session_financial_adjustments where session_id=c.session_id) then
   raise exception 'manual_approval_reconciliation_required' using errcode='P0C02';end if;
  evidence:=billing.derive_session_correction_charge(c.id);
  select * into strict ch from billing.effective_session_charges where session_id=c.session_id;
  if ch.financial_applied_revision<>c.previous_revision then
   raise exception 'financial_revision_chain_invalid' using errcode='P0C02';end if;
  previous:=ch.pricing_evidence;new_amount:=(evidence->>'amount_minor')::bigint;
  select d.farmer_well_account_id into account from billing.default_session_debts d
   where d.session_charge_id=ch.id and d.scope_valid;
  if account is null or not exists(select 1 from ops.farmer_well_accounts a where a.id=account
   and a.well_id=c.well_id and a.tenant_id=c.tenant_id) then
   raise exception 'financial_account_unproven' using errcode='P0C02';end if;
  perform 1 from ops.farmer_well_accounts where id=account for update;
  if p_posted_at is null or not isfinite(p_posted_at) then
   raise exception 'explicit_posting_context_required' using errcode='P0C02';end if;
  -- Existing explicit open monthly AND yearly context, locked against closure.
  -- No period creation/date selection from requested_at or the current clock.
  perform 1 from finance.accounting_periods ap where ap.well_id=c.well_id
   and p_posted_at::date between ap.starts_at and ap.ends_at order by ap.id for share;
  if (select count(distinct period_type) from finance.accounting_periods ap where ap.well_id=c.well_id
    and p_posted_at::date between ap.starts_at and ap.ends_at and ap.status in ('open','reopened'))<>2
   or exists(select 1 from finance.accounting_periods ap where ap.well_id=c.well_id
    and p_posted_at::date between ap.starts_at and ap.ends_at and ap.status not in ('open','reopened')) then
   raise exception 'accounting_period_not_open' using errcode='P0C02';end if;
  select count(*) into invoice_count from billing.invoices inv where inv.session_id=c.session_id and inv.status not in ('cancelled','reversed');
  if invoice_count>1 then raise exception 'invoice_identity_ambiguous' using errcode='P0C02';end if;
  if invoice_count=1 then
   select * into strict i from billing.invoices inv where inv.session_id=c.session_id and inv.status not in ('cancelled','reversed') for update;
   select total_minor into old_invoice from billing.effective_invoice_totals where id=i.id;
   if (i.tenant_id,i.well_id,i.farmer_well_account_id) is distinct from(c.tenant_id,c.well_id,account)
    or i.status not in ('issued','paid','partially_paid','overdue') or i.settlement_method<>'normal'
    or old_invoice<>ch.amount_minor then raise exception 'invoice_charge_scope_or_policy_unproven' using errcode='P0C02';end if;
   if i.journal_entry_id is null or not exists(select 1 from finance.journal_entries je where je.id=i.journal_entry_id
     and je.well_id=c.well_id and je.tenant_id=c.tenant_id and je.source_type='invoice' and je.source_id=i.id and je.status='posted') then
    raise exception 'original_invoice_posting_unproven' using errcode='P0C02';end if;
   if exists(select 1 from billing.invoice_effective_balances b where b.invoice_id=i.id
      and (b.paid_minor<0 or b.outstanding_minor<0 or b.paid_minor>b.total_minor)) then
    raise exception 'original_settlement_unproven' using errcode='P0C02';end if;
   if billing.invoice_has_protected_distribution_use(i.id) and new_amount<>ch.amount_minor then
    raise exception 'approved_distribution_reconciliation_required' using errcode='P0C02';end if;
   select greatest(explicitly_settled_minor-new_amount,0) into excess from billing.invoice_explicit_settlements where invoice_id=i.id;
   -- Release explicit excess BEFORE debt publication so C0 refreshes never see
   -- a transient negative invoice balance. Its default destination may recover
   -- the released value; after publication C0.2 rebalances the remaining capacity.
   for x in select a.* from billing.effective_account_credit_applications a
     where a.invoice_id=i.id and a.effective_amount_minor>0 order by a.created_at desc,a.id loop
    exit when excess<=0;take:=least(excess,x.effective_amount_minor)::bigint;
    source:=md5(c.id::text||':application_release:'||x.id::text)::uuid;
    child:=billing.adjust_credit_application_core(actor,x.id,'release',take,source,c.new_revision,c.reason,p_posted_at,c.id);
    if child->>'status' is distinct from 'accepted' then
     raise exception 'credit_application_release_requires_review' using errcode='P0C02',detail=child::text;end if;
    children:=children||jsonb_build_array(child);excess:=excess-take;
   end loop;
   for x in select a.* from billing.effective_payment_allocations a join billing.payments p on p.id=a.payment_id
     where a.invoice_id=i.id and p.status='posted' and a.effective_allocated_minor>0 order by a.id loop
    exit when excess<=0;take:=least(excess,x.effective_allocated_minor)::bigint;
    source:=md5(c.id::text||':allocation_release:'||x.id::text)::uuid;
    child:=billing.repartition_payment_internal_core(actor,(select payment_id from billing.payment_allocations where id=x.id),x.id,null,take,'release',source,c.new_revision,c.reason,p_posted_at,c.id);
    if child->>'status' is distinct from 'accepted' then
     raise exception 'payment_allocation_release_requires_review' using errcode='P0C02',detail=child::text;end if;
    children:=children||jsonb_build_array(child);excess:=excess-take;
   end loop;
   if excess>0 then raise exception 'legacy_settlement_unreleasable' using errcode='P0C02';end if;
  end if;
  insert into billing.session_charge_corrections(correction_id,tenant_id,well_id,session_id,session_charge_id,
   operational_revision,previous_financial_revision,old_amount_minor,new_amount_minor,delta_minor,
   billable_seconds,weighted_rate_minor,effective_started_at,effective_ended_at,pricing_evidence,reconciliation_command_id,source_id,posted_at)
  values(c.id,c.tenant_id,c.well_id,c.session_id,ch.id,c.new_revision,ch.financial_applied_revision,ch.amount_minor,new_amount,new_amount-ch.amount_minor,
   (evidence->>'billable_seconds')::bigint,(evidence->>'weighted_rate_minor')::bigint,c.after_started_at,c.after_ended_at,evidence,
   p_command_id,md5(c.id::text||':charge')::uuid,p_posted_at);
  if i.id is not null then
   j:=billing.post_session_correction_delta_core(actor,c.id,i.id,evidence,previous,p_posted_at);
   insert into billing.invoice_corrections(correction_id,tenant_id,well_id,session_id,session_charge_id,invoice_id,
    operational_revision,previous_financial_revision,old_amount_minor,new_amount_minor,delta_minor,pricing_evidence,
    reconciliation_command_id,source_id,journal_entry_id,posted_at)
   values(c.id,c.tenant_id,c.well_id,c.session_id,ch.id,i.id,c.new_revision,ch.financial_applied_revision,
    old_invoice,new_amount,new_amount-old_invoice,evidence,p_command_id,md5(c.id::text||':invoice')::uuid,j,p_posted_at);
  end if;
  if new_amount<ch.amount_minor then
   for x in select p.id from billing.payments p where p.session_charge_id=ch.id and p.status='posted'
    and p.purpose='session' order by p.paid_at,p.id loop
    if exists(select 1 from billing.payment_economic_applications a where a.payment_id=x.id and a.remaining_minor>0) then
     source:=md5(c.id::text||':rebalance:'||x.id::text)::uuid;
     child:=billing.repartition_payment_internal_core(actor,x.id,null,null,null,'rebalance',source,c.new_revision,c.reason,p_posted_at,c.id);
     if child->>'status' is distinct from 'accepted' then
      raise exception 'payment_rebalance_requires_review' using errcode='P0C02',detail=child::text;end if;
     children:=children||jsonb_build_array(child);
    end if;
   end loop;
  end if;
  perform billing.refresh_partition_invoices(c.well_id);
  if exists(select 1 from billing.invoice_effective_balances b where b.invoice_id=i.id and
    (b.outstanding_minor<0 or b.paid_minor<0 or b.paid_minor>b.total_minor)) then
   raise exception 'effective_invoice_balance_invalid' using errcode='P0C02';end if;
  result:=jsonb_build_object('status','applied','correction_id',c.id,'session_id',c.session_id,
   'operational_revision',c.new_revision,'financial_applied_revision',c.new_revision,'session_charge_id',ch.id,
   'invoice_id',i.id,'old_amount_minor',ch.amount_minor,'new_amount_minor',new_amount,'delta_minor',new_amount-ch.amount_minor,
   'reconciliation_command_id',p_command_id,'journal_entry_id',j,'child_effects',children);
  update ops.session_correction_reconciliations set status='applied',financial_applied_revision=c.new_revision,
   last_error=null,last_financial_result=result where correction_id=c.id;
  -- Validate the same deferred C0 invariants while rollback-to-review is still
  -- possible; do not change caller-wide constraint modes with SET CONSTRAINTS.
  for x in select value from jsonb_array_elements(children) loop
   select * into strict event from billing.customer_credit_events where id=(x.value->>'event_id')::uuid;
   if event.operation='application_release' then perform billing.validate_application_adjustment_event(event);
   else perform billing.validate_payment_repartition(event);end if;
  end loop;
  perform billing.validate_session_financial_correction(c.id);
 exception when sqlstate 'P0C02' or numeric_value_out_of_range or check_violation or raise_exception then
  get stacked diagnostics code=MESSAGE_TEXT,error_detail=PG_EXCEPTION_DETAIL,errstate=RETURNED_SQLSTATE;
  result:=jsonb_build_object('status','financial_review_required','correction_id',c.id,'session_id',c.session_id,
   'operational_revision',c.new_revision,'financial_applied_revision',coalesce((select financial_applied_revision
    from billing.effective_session_charges where session_id=c.session_id),0),
   'review_code',case when errstate='22003' then 'financial_numeric_range'
    when errstate in ('23514','P0001') then 'financial_child_rejected' else code end,
   'review_detail',case when errstate in ('23514','P0001') then code else error_detail end,'reconciliation_command_id',p_command_id);
  update ops.session_correction_reconciliations set status='financial_review_required',financial_applied_revision=null,
   last_error=result->>'review_code',last_financial_result=result where correction_id=c.id;
 end;
 perform sync.finish_command(c.tenant_id,p_command_id,'accepted',result);
 return result;
end;$$;

create or replace function billing.post_session_correction_delta(p_correction uuid,p_invoice uuid,p_evidence jsonb,p_previous jsonb,
 p_posted_at timestamptz) returns uuid language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select billing.post_session_correction_delta_core(auth.uid(),p_correction,p_invoice,p_evidence,p_previous,p_posted_at);
$$;

create or replace function billing.adjust_credit_application(p_application uuid,p_operation text,p_amount bigint,
 p_source uuid,p_revision bigint,p_reason text,p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select billing.adjust_credit_application_core(auth.uid(),p_application,p_operation,p_amount,p_source,p_revision,p_reason,p_posted_at,p_origin_id);
$$;

create or replace function billing.repartition_payment_internal(p_payment uuid,p_allocation uuid,p_credit uuid,p_amount bigint,
 p_mode text,p_source uuid,p_revision bigint,p_reason text,p_posted_at timestamptz,p_origin uuid default null,p_parent uuid default null)
returns jsonb language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select billing.repartition_payment_internal_core(auth.uid(),p_payment,p_allocation,p_credit,p_amount,p_mode,p_source,p_revision,p_reason,p_posted_at,p_origin,p_parent);
$$;

create or replace function billing.reconcile_session_correction(p_correction uuid,p_command_id uuid,p_posted_at timestamptz)
returns jsonb language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select billing.reconcile_session_correction_core(auth.uid(),p_correction,p_command_id,p_posted_at);
$$;

create function billing.enqueue_session_correction_reconciliation() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin
 perform pgmq.send('session_correction_reconciliation',jsonb_build_object('correction_id',new.correction_id));
 return null;
end;$$;
create trigger session_correction_reconciliation_enqueue after insert on ops.session_correction_reconciliations
 for each row execute function billing.enqueue_session_correction_reconciliation();
-- Runs once with this migration, in the same transaction as trigger installation.
select pgmq.send('session_correction_reconciliation',jsonb_build_object('correction_id',correction_id))
 from ops.session_correction_reconciliations where status='pending';

create function billing.lease_session_correction_reconciliation_messages(p_qty integer,p_visibility_timeout_seconds integer)
returns table(msg_id bigint,read_count integer)
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
begin
 if p_qty is null or p_qty<1 or p_qty>100 or p_visibility_timeout_seconds is null
  or p_visibility_timeout_seconds<1 or p_visibility_timeout_seconds>3600 then
  raise exception 'reconciliation_lease_bounds_invalid' using errcode='22023';end if;
 return query select m.msg_id,m.read_ct from pgmq.read('session_correction_reconciliation',p_visibility_timeout_seconds,p_qty) m;
end;$$;

create function billing.process_session_correction_reconciliation_message(p_msg_id bigint) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare m pgmq.q_session_correction_reconciliation%rowtype;c ops.session_corrections%rowtype;
 w ops.session_correction_reconciliations%rowtype;cid uuid;cmd uuid;posted timestamptz;r jsonb;review text;
begin
 -- The queue row is private and locked through financial processing + archive.
 select * into m from pgmq.q_session_correction_reconciliation where msg_id=p_msg_id for update;
 if not found then return jsonb_build_object('status','already_completed');end if;
 if m.read_ct<1 or m.vt<=clock_timestamp() then
  return jsonb_build_object('status','pending','reason','lease_required','attempt_started',false);end if;
 if jsonb_typeof(m.message) is distinct from 'object' then review:='invalid_message';
 elsif (select count(*) from jsonb_object_keys(m.message))<>1
  or jsonb_typeof(m.message->'correction_id') is distinct from 'string'
  or (m.message->>'correction_id') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then review:='invalid_message';
 end if;
 if review is not null then
  perform pgmq.archive('session_correction_reconciliation',p_msg_id);
  return jsonb_build_object('status','invalid_message');
 end if;
 cid:=(m.message->>'correction_id')::uuid;
 select * into c from ops.session_corrections where id=cid;
 if not found or not exists(select 1 from ops.session_correction_reconciliations where correction_id=cid) then
  perform pgmq.archive('session_correction_reconciliation',p_msg_id);
  return jsonb_build_object('status','invalid_message');end if;
 -- C2 order: financial root, operational well, session, work, then periods.
 -- Transaction advisory locks are reentrant; core uses these same two locks.
 perform billing.lock_customer_credit_well(c.well_id);
 perform ops.lock_operational_scope(c.well_id,true);
 perform 1 from ops.irrigation_sessions where id=c.session_id for update;
 select * into strict w from ops.session_correction_reconciliations where correction_id=cid for update;
 if w.status in ('applied','financial_review_required') then
  r:=jsonb_build_object('status',w.status,'already_completed',true);
 else
  if exists(select 1 from ops.session_correction_reconciliations where session_id=c.session_id
   and operational_revision<c.new_revision and status<>'applied') then
   return jsonb_build_object('status','pending','reason','predecessor_not_applied','attempt_started',false);end if;
  cmd:=md5('session-correction-auto-reconcile:v1:'||cid::text)::uuid;
  if not billing.reconciliation_actor_authorized(c.well_id,c.actor_id) then
   review:='actor_authorization_changed';
  else
   begin
    posted:=billing.manual_financial_posting_context(c.well_id);
    r:=billing.reconcile_session_correction_core(c.actor_id,cid,cmd,posted);
   exception when sqlstate 'P0FA1' then review:='posting_context_unavailable';
    when insufficient_privilege then
     if SQLERRM='session_financial_reconciliation_forbidden' then review:='actor_authorization_changed';
     else raise;end if;
   end;
  end if;
  if review is not null then
   r:=jsonb_build_object('status','financial_review_required','correction_id',cid,'review_code',review,
    'reconciliation_command_id',cmd);
   update ops.session_correction_reconciliations set status='financial_review_required',
    attempt_count=attempt_count+1,last_attempt_at=clock_timestamp(),last_reconciliation_command_id=cmd,
    financial_applied_revision=null,last_error=review,last_financial_result=r where correction_id=cid;
  end if;
 end if;
 if r->>'status' in ('applied','financial_review_required') then
  if not pgmq.archive('session_correction_reconciliation',p_msg_id) then
   raise exception 'reconciliation_archive_failed';end if;
 end if;
 -- Nonterminal readiness keeps the message; unexpected exceptions roll back.
 return r;
end;$$;

revoke all on function iam.has_well_permission_for_actor(uuid,text,uuid),
 billing.reconciliation_actor_authorized(uuid,uuid),
 billing.reconcile_session_correction_core(uuid,uuid,uuid,timestamptz),
 billing.post_session_correction_delta_core(uuid,uuid,uuid,jsonb,jsonb,timestamptz),
 billing.adjust_credit_application_core(uuid,uuid,text,bigint,uuid,bigint,text,timestamptz,uuid),
 billing.repartition_payment_internal_core(uuid,uuid,uuid,uuid,bigint,text,uuid,bigint,text,timestamptz,uuid,uuid),
 billing.reconcile_session_correction(uuid,uuid,timestamptz),
 billing.enqueue_session_correction_reconciliation(),
 billing.lease_session_correction_reconciliation_messages(integer,integer),
 billing.process_session_correction_reconciliation_message(bigint)
 from public,anon,authenticated,service_role,reconciliation_executor;
revoke all on function iam.has_well_permission_for_actor(uuid,text,uuid) from booking_automation_executor;
grant usage on schema billing to reconciliation_executor;
grant execute on function billing.lease_session_correction_reconciliation_messages(integer,integer),
 billing.process_session_correction_reconciliation_message(bigint) to reconciliation_executor;
-- Extension default EXECUTE is PUBLIC. Keep its entire low-level surface private,
-- including future overloads, rather than exposing a general queue authority.
revoke all on schema pgmq from public,anon,authenticated,service_role,reconciliation_executor;
revoke all on all functions in schema pgmq from public,anon,authenticated,service_role,reconciliation_executor;
revoke all on all tables in schema pgmq from public,anon,authenticated,service_role,reconciliation_executor;
revoke all on all sequences in schema pgmq from public,anon,authenticated,service_role,reconciliation_executor;
commit;

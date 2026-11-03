begin;
-- قـ C0.2: التخصيص نقل لقيمة قبض موجودة؛ لا تسديد إضافي من رابط charge.
create index payments_default_partition_idx on billing.payments(session_charge_id,paid_at,id)
 where status='posted' and purpose='session';
create function billing.require_valid_payment_partition(ok boolean,amount numeric) returns numeric
language plpgsql immutable security invoker set search_path=pg_catalog,pg_temp as $$
begin
 if ok is distinct from true then raise exception 'payment_partition_requires_review' using errcode='23514';end if;
 return amount;
end;$$;
revoke all on function billing.require_valid_payment_partition(boolean,numeric) from public,anon;
grant execute on function billing.require_valid_payment_partition(boolean,numeric) to authenticated,service_role;

-- لا تعتمد أي معادلة هنا على counters الفاتورة القابلة للتحديث، منعًا للدوران.
-- لقطة INSERT القديمة ليست تسديدًا إضافيًا حين تصل تخصيصاتها الأصلية لاحقًا.
alter table billing.invoices add column inserted_settlement_snapshot_minor bigint
 check(inserted_settlement_snapshot_minor>=0);
-- لا نغير حساب الدفعة التاريخي؛ نثبت نطاقها من الأدلة الدائمة المتفقة فقط.
create view billing.payment_scope_evidence with(security_invoker=true) as
select p.id,p.tenant_id,p.well_id,p.purpose,p.status,p.paid_at,p.amount_minor,p.session_charge_id,
 evidence.farmer_well_account_id,
 evidence.account_count=1 and coalesce(evidence.scope_valid,true) as scope_valid
from billing.payments p
left join lateral(select count(distinct account_id) as account_count,
 (array_agg(distinct account_id) filter(where account_id is not null))[1] as farmer_well_account_id,
 bool_and(source_tenant=p.tenant_id and source_well=p.well_id) as scope_valid
 from (
  select p.farmer_well_account_id as account_id,p.tenant_id as source_tenant,p.well_id as source_well
  union all select s.farmer_well_account_id,w.tenant_id,s.well_id
   from billing.session_charges sc join ops.irrigation_sessions s on s.id=sc.session_id
   join core.wells w on w.id=s.well_id where sc.id=p.session_charge_id and p.purpose='session'
  union all select i.farmer_well_account_id,i.tenant_id,i.well_id
   from billing.invoices i join billing.session_charges sc on sc.session_id=i.session_id
   where sc.id=p.session_charge_id and p.purpose='session' and i.status not in ('cancelled','reversed')
  union all select i.farmer_well_account_id,i.tenant_id,i.well_id
   from billing.payment_allocations a join billing.invoices i on i.id=a.invoice_id where a.payment_id=p.id
 ) sources)evidence on true;
create view billing.invoice_explicit_settlements with(security_invoker=true) as
select i.id as invoice_id,i.tenant_id,i.well_id,i.farmer_well_account_id,i.session_id,i.total_minor,i.status,
 i.nonallocation_paid_minor
 +greatest(coalesce(i.inserted_settlement_snapshot_minor,0)-coalesce(original_allocations.amount_minor,0),0)
 +coalesce(a.amount_minor,0)+coalesce(c.amount_minor,0) as explicitly_settled_minor,
 (exists(select 1 from core.wells w join ops.farmer_well_accounts fa on fa.well_id=w.id and fa.tenant_id=w.tenant_id
   where w.id=i.well_id and w.tenant_id=i.tenant_id and fa.id=i.farmer_well_account_id)
  and coalesce(a.scope_valid,true) and coalesce(c.scope_valid,true)
  and (i.session_id is null or exists(select 1 from ops.irrigation_sessions sess where sess.id=i.session_id
    and sess.well_id=i.well_id and (sess.farmer_well_account_id is null or sess.farmer_well_account_id=i.farmer_well_account_id)))
  and not exists(select 1 from billing.invoice_lines l join ops.session_segments seg on seg.id=l.session_segment_id
   where l.invoice_id=i.id and (l.tenant_id<>i.tenant_id or i.session_id is null or seg.session_id<>i.session_id))) as scope_valid
from billing.invoices i
left join lateral(select sum(allocated_minor) as amount_minor from billing.payment_allocations
 where invoice_id=i.id)original_allocations on true
left join lateral(select sum(a.effective_allocated_minor) as amount_minor,
 bool_and(p.scope_valid and p.tenant_id=i.tenant_id and p.well_id=i.well_id and p.farmer_well_account_id=i.farmer_well_account_id
  and (p.purpose='session' or p.session_charge_id is null) and a.tenant_id=i.tenant_id and a.effective_allocated_minor between 0 and a.allocated_minor) as scope_valid
 from billing.effective_payment_allocations a join billing.payment_scope_evidence p on p.id=a.payment_id
 where a.invoice_id=i.id and p.status='posted')a on true
left join lateral(select sum(c.effective_amount_minor) as amount_minor,
 bool_and(c.tenant_id=i.tenant_id and c.well_id=i.well_id and c.farmer_well_account_id=i.farmer_well_account_id
  and src.tenant_id=i.tenant_id and src.well_id=i.well_id and src.farmer_well_account_id=i.farmer_well_account_id
  and p.status='posted' and c.effective_amount_minor between 0 and c.amount_minor) as scope_valid
 from billing.effective_account_credit_applications c join billing.account_credits src on src.id=c.credit_id
 join billing.payments p on p.id=src.payment_id where c.invoice_id=i.id)c on true;
create view billing.default_session_debts with(security_invoker=true) as
select sc.id as session_charge_id,sc.session_id,sc.well_id,scope.farmer_well_account_id,
 coalesce(i.total_minor,sc.amount_minor) as debt_minor,coalesce(i.settled_minor,0) as explicitly_settled_minor,
 greatest(coalesce(i.total_minor,sc.amount_minor)-coalesce(i.settled_minor,0),0) as remaining_before_direct_minor,
 s.well_id=sc.well_id and scope.account_count<=1
 and coalesce(i.invoice_count,0)<=1 and coalesce(i.scope_valid,true) as scope_valid
from billing.session_charges sc join ops.irrigation_sessions s on s.id=sc.session_id
-- الجلسات القديمة تسمح بحساب NULL؛ الدفعة/الفاتورة دليل دائم، لا NEW غير المدرج.
-- لا نختار حسابًا عند التعارض؛ الحساب الصريح للجلسة يدخل مجموعة الأدلة نفسها.
left join lateral(select count(distinct account_id) as account_count,
 (array_agg(distinct account_id) filter(where account_id is not null))[1] as farmer_well_account_id
 from (
  select s.farmer_well_account_id as account_id
  union all select p.farmer_well_account_id from billing.payments p
   where p.session_charge_id=sc.id and p.purpose='session' and p.status='posted'
  union all select inv.farmer_well_account_id from billing.invoices inv
   where inv.session_id=s.id and inv.status not in ('cancelled','reversed')
 ) evidence)scope on true
left join lateral(select count(*) as invoice_count,sum(total_minor) as total_minor,sum(explicitly_settled_minor) as settled_minor,
 bool_and(x.scope_valid and x.well_id=sc.well_id and x.farmer_well_account_id=scope.farmer_well_account_id
  and x.tenant_id=(select tenant_id from core.wells where id=sc.well_id)) as scope_valid
 from billing.invoice_explicit_settlements x where x.session_id=sc.session_id and x.status not in ('draft','cancelled','reversed'))i on true;
create view billing.payment_partition_inputs with(security_invoker=true) as
select p.id as payment_id,p.tenant_id,p.well_id,p.farmer_well_account_id,p.purpose,p.status,p.paid_at,p.amount_minor,
 case when p.purpose='session' then p.session_charge_id end as default_session_charge_id,
 coalesce(a.amount_minor,0) as allocated_minor,coalesce(c.amount_minor,0) as credit_backed_minor,
 p.amount_minor-coalesce(a.amount_minor,0)-coalesce(c.amount_minor,0) as capacity_minor,
 d.remaining_before_direct_minor,
 (p.scope_valid and exists(select 1 from core.wells w where w.id=p.well_id and w.tenant_id=p.tenant_id)
  and exists(select 1 from ops.farmer_well_accounts fa where fa.id=p.farmer_well_account_id
   and fa.tenant_id=p.tenant_id and fa.well_id=p.well_id)
  and coalesce(a.scope_valid,true) and coalesce(c.scope_valid,true)
  and (p.purpose='session' or p.session_charge_id is null)
  and (p.purpose<>'session' or (d.session_charge_id is not null and d.well_id=p.well_id
   and d.farmer_well_account_id=p.farmer_well_account_id and d.scope_valid))
  and p.amount_minor-coalesce(a.amount_minor,0)-coalesce(c.amount_minor,0)>=0) as scope_valid
from billing.payment_scope_evidence p
left join lateral(select sum(pa.effective_allocated_minor) as amount_minor,
 bool_and(ix.scope_valid and pa.tenant_id=p.tenant_id and i.tenant_id=p.tenant_id and i.well_id=p.well_id
  and i.farmer_well_account_id=p.farmer_well_account_id and pa.effective_allocated_minor between 0 and pa.allocated_minor) as scope_valid
 from billing.effective_payment_allocations pa join billing.invoices i on i.id=pa.invoice_id
 join billing.invoice_explicit_settlements ix on ix.invoice_id=i.id where pa.payment_id=p.id)a on true
left join lateral(select sum(amount_minor-reversed_minor) as amount_minor,
 bool_and(tenant_id=p.tenant_id and well_id=p.well_id and farmer_well_account_id=p.farmer_well_account_id
  and amount_minor>=reversed_minor and available_minor>=0) as scope_valid
 from billing.account_credit_balances c where c.payment_id=p.id)c on true
left join billing.default_session_debts d on d.session_charge_id=p.session_charge_id
where p.status='posted';
create view billing.payment_economic_applications with(security_invoker=true) as
with capacities as (
 select x.*,capacity_minor as checked_capacity,
 bool_and(scope_valid) over(partition by coalesce(default_session_charge_id,payment_id)) as group_valid,
 sum(case when default_session_charge_id is not null then capacity_minor else 0 end)
 over(partition by coalesce(default_session_charge_id,payment_id) order by paid_at,payment_id rows between unbounded preceding and 1 preceding) as preceding_capacity
 from billing.payment_partition_inputs x
), settled as (
 select *,case when default_session_charge_id is not null then
 least(checked_capacity,greatest(remaining_before_direct_minor-coalesce(preceding_capacity,0),0)) else 0 end as direct_minor
 from capacities
)
select payment_id,tenant_id,well_id,farmer_well_account_id,purpose,status,paid_at,amount_minor,default_session_charge_id,
 billing.require_valid_payment_partition(scope_valid and group_valid,allocated_minor) as explicit_allocated_minor,
 billing.require_valid_payment_partition(scope_valid and group_valid,credit_backed_minor) as credit_backed_minor,
 billing.require_valid_payment_partition(scope_valid and group_valid,checked_capacity) as direct_capacity_minor,
 billing.require_valid_payment_partition(scope_valid and group_valid,direct_minor) as effective_direct_minor,
 billing.require_valid_payment_partition(scope_valid and group_valid,checked_capacity-direct_minor) as remaining_minor
from settled;
create view billing.session_economic_settlements with(security_invoker=true) as
select d.*,coalesce(p.direct_minor,0) as direct_settled_minor,
 billing.require_valid_payment_partition(d.scope_valid,d.explicitly_settled_minor+coalesce(p.direct_minor,0)) as settled_minor,
 billing.require_valid_payment_partition(d.scope_valid,greatest(d.debt_minor-d.explicitly_settled_minor-coalesce(p.direct_minor,0),0)) as outstanding_minor
from billing.default_session_debts d left join lateral(select sum(effective_direct_minor) as direct_minor
 from billing.payment_economic_applications p where p.default_session_charge_id=d.session_charge_id)p on true;
create or replace view billing.payment_available_balances with(security_invoker=true) as
select p.id as payment_id,p.tenant_id,p.well_id,p.farmer_well_account_id,p.purpose,p.status,p.amount_minor,
 coalesce(e.explicit_allocated_minor,0) as effective_allocated_minor,coalesce(e.credit_backed_minor,0) as credit_reserved_minor,
 case when p.status='posted' then e.remaining_minor else 0::numeric end as available_minor
from billing.payment_scope_evidence p left join billing.payment_economic_applications e on e.payment_id=p.id;
create or replace view billing.invoice_effective_balances with(security_invoker=true) as
select i.id as invoice_id,i.well_id,i.tenant_id,i.farmer_well_account_id,i.total_minor,
 billing.require_valid_payment_partition(x.scope_valid,x.explicitly_settled_minor+coalesce(d.direct_settled_minor,0)) as paid_minor,
 billing.require_valid_payment_partition(x.scope_valid,i.total_minor-x.explicitly_settled_minor-coalesce(d.direct_settled_minor,0)) as outstanding_minor
from billing.invoices i join billing.invoice_explicit_settlements x on x.invoice_id=i.id
left join billing.session_economic_settlements d on d.session_id=i.session_id and i.status not in ('draft','cancelled','reversed');

create table billing.payment_repartition_events (
 event_id uuid primary key references billing.customer_credit_events(id) deferrable initially deferred,
 parent_event_id uuid references billing.payment_repartition_events(event_id) deferrable initially deferred,
 payment_id uuid not null references billing.payments(id),tenant_id uuid not null references core.tenants(id),
 well_id uuid not null references core.wells(id),farmer_well_account_id uuid not null references ops.farmer_well_accounts(id),
 mode text not null check(mode in ('release','restore','rebalance','reverse','withdraw')),
 allocation_id uuid references billing.payment_allocations(id),allocation_adjustment_id uuid unique references billing.payment_allocation_adjustments(id),
 credit_id uuid,amount_minor bigint not null check(amount_minor>=0),credit_amount_minor bigint not null check(credit_amount_minor>=0),
 status text not null check(status in ('accepted','financial_review_required')),review_reason text,
 journal_entry_id uuid references finance.journal_entries(id),
 check((status='accepted' and review_reason is null) or(status='financial_review_required' and review_reason is not null and journal_entry_id is null)),
 check((mode='withdraw')=(parent_event_id is not null))
);
create index payment_repartition_payment_idx on billing.payment_repartition_events(payment_id);
create index payment_repartition_allocation_idx on billing.payment_repartition_events(allocation_id);
create index payment_repartition_credit_idx on billing.payment_repartition_events(credit_id);
create index payment_repartition_parent_idx on billing.payment_repartition_events(parent_event_id);
alter table billing.account_credits alter column allocation_adjustment_id drop not null;
alter table billing.account_credits add column repartition_event_id uuid unique references billing.payment_repartition_events(event_id);
alter table billing.account_credits drop constraint account_credits_source_type_check;
alter table billing.account_credits add constraint account_credits_source_type_check check(
 (source_type='allocation_release' and allocation_adjustment_id is not null and repartition_event_id is null)
 or(source_type='payment_repartition' and allocation_adjustment_id is null and repartition_event_id is not null));
alter table billing.payment_repartition_events add foreign key(credit_id) references billing.account_credits(id) deferrable initially deferred;
alter table billing.customer_credit_events drop constraint customer_credit_events_operation_check;
alter table billing.customer_credit_events add constraint customer_credit_events_operation_check check(operation in
 ('release','apply','reverse','application_release','application_restore','restore_allocation','rebalance_payment','partition_withdraw'));

create function billing.refresh_partition_invoices(p_well uuid) returns void
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare i uuid;
begin
 for i in select id from billing.invoices where well_id=p_well and status not in ('draft','cancelled','reversed') order by id for update loop
  if exists(select 1 from billing.invoices x join billing.invoice_effective_balances b on b.invoice_id=x.id
   where x.id=i and ((x.paid_minor,x.outstanding_minor) is distinct from (b.paid_minor,b.outstanding_minor)
    or(b.outstanding_minor=0 and x.status<>'paid') or(b.outstanding_minor>0 and b.paid_minor>0 and x.status<>'partially_paid')
    or(b.paid_minor=0 and x.status in ('paid','partially_paid')))) then
   perform billing.refresh_effective_invoice(i);end if;
 end loop;
end;$$;
create function billing.repartition_payment_internal(p_payment uuid,p_allocation uuid,p_credit uuid,p_amount bigint,
 p_mode text,p_source uuid,p_revision bigint,p_reason text,p_posted_at timestamptz,p_origin uuid default null,p_parent uuid default null)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare p billing.payments%rowtype;a billing.payment_allocations%rowtype;c billing.account_credits%rowtype;i billing.invoices%rowtype;
 actor uuid:=auth.uid();req jsonb;r jsonb;e uuid:=gen_random_uuid();j uuid;aid uuid;credit uuid;operation text;
 before_state record;after_state record;x record;review text;amount bigint;credit_amount bigint:=0;needed bigint:=0;
 credit_left bigint;take bigint;restorable bigint;released_credit bigint;before_direct numeric:=0;direct_gain numeric:=0;child_source uuid;child jsonb;target uuid:=p_allocation;cycles jsonb:='[]';extra numeric;
begin
 select * into strict p from billing.payments where id=p_payment;
 if actor is null or not coalesce(iam.has_well_permission(p.well_id,'session.correct'),false) then
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
 if not coalesce(iam.has_well_permission(p.well_id,'session.correct'),false) then
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
  if i.deducted_in_cycle_id is not null then
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
     child:=billing.repartition_payment_internal(p.id,null,x.id,take,'withdraw',child_source,p_revision,p_reason,p_posted_at,coalesce(p_origin,p_source),e);
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
create or replace function billing.release_payment_allocation(p_allocation uuid,p_amount bigint,p_source uuid,p_revision bigint,
 p_reason text,p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select billing.repartition_payment_internal((select payment_id from billing.payment_allocations where id=p_allocation),
  p_allocation,null,p_amount,'release',p_source,p_revision,p_reason,p_posted_at,p_origin_id);
$$;
create function billing.restore_payment_allocation(p_allocation uuid,p_amount bigint,p_source uuid,p_revision bigint,
 p_reason text,p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select billing.repartition_payment_internal((select payment_id from billing.payment_allocations where id=p_allocation),
  p_allocation,null,p_amount,'restore',p_source,p_revision,p_reason,p_posted_at,p_origin_id);
$$;
create function billing.rebalance_payment_capacity(p_payment uuid,p_source uuid,p_revision bigint,p_reason text,
 p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select billing.repartition_payment_internal(p_payment,null,null,null,'rebalance',p_source,p_revision,p_reason,p_posted_at,p_origin_id);
$$;
create function billing.reverse_allocation_credit_legacy(p_credit uuid,p_amount bigint,p_source uuid,p_revision bigint,
 p_reason text,p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c billing.account_credits%rowtype;i billing.invoices%rowtype;a billing.payment_allocations%rowtype;
 actor uuid:=auth.uid();request jsonb;r jsonb;e uuid:=gen_random_uuid();j uuid;rev uuid;
 available bigint;remaining bigint;restored bigint;held bigint;review bigint;s text;
begin
 select * into strict c from billing.account_credits where id=p_credit;
 if actor is null or not coalesce(iam.has_well_permission(c.well_id,'session.correct'),false) then
  raise exception 'financial_correction_forbidden' using errcode='42501';end if;
 if p_amount is null or p_amount<=0 or nullif(btrim(p_reason),'') is null or p_posted_at is null or not isfinite(p_posted_at) then
  raise exception 'financial_effect_facts_required' using errcode='22023';end if;
 request:=jsonb_build_object('operation','reverse','credit',p_credit,'amount',p_amount,'reason',p_reason,
 'posted_at',to_char(p_posted_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'actor',actor,'origin_source_id',coalesce(p_origin_id,p_source));
 perform billing.lock_customer_credit_well(c.well_id);
 r:=billing.credit_event_replay(c.tenant_id,p_source,p_revision,request);if r is not null then return r;end if;
 perform 1 from billing.payments where id=c.payment_id for update;
 perform 1 from billing.account_credits where id=c.id for update;
 select pa.* into strict a from billing.payment_allocations pa join billing.payment_allocation_adjustments x on x.allocation_id=pa.id
  where x.id=c.allocation_adjustment_id for update of pa;
 select * into strict i from billing.invoices where id=a.invoice_id for update;
 select available_minor into available from billing.account_credit_balances where id=c.id;
 select c.amount_minor-coalesce(sum(requested_minor),0) into remaining from billing.account_credit_reversals where credit_id=c.id;
 if p_amount>remaining then raise exception 'credit_reversal_out_of_range' using errcode='23514';end if;
 restored:=case when i.deducted_in_cycle_id is null and i.status in ('issued','partially_paid','paid','overdue')
  then least(p_amount,available,greatest(i.outstanding_minor,0)) else 0 end;
 held:=least(p_amount,available)-restored;review:=p_amount-restored-held;
 s:=case when held+review>0 then 'financial_review_required' else 'accepted' end;
 insert into billing.account_credit_reversals(tenant_id,well_id,farmer_well_account_id,credit_id,event_id,requested_minor,
 restored_minor,held_minor,receivable_review_minor,status,reason,created_by)
 values(c.tenant_id,c.well_id,c.farmer_well_account_id,c.id,e,p_amount,restored,held,review,s,p_reason,actor) returning id into rev;
 if restored>0 then
  insert into billing.payment_allocation_adjustments(tenant_id,well_id,farmer_well_account_id,allocation_id,event_id,operation,amount_minor,reason,created_by)
  values(c.tenant_id,c.well_id,c.farmer_well_account_id,a.id,e,'restore',restored,p_reason,actor);
 end if;
 j:=billing.post_customer_credit_entry(e,c.tenant_id,c.well_id,c.farmer_well_account_id,restored,false,p_posted_at,actor);
 r:=jsonb_build_object('status',s,'event_id',e,'reversal_id',rev,'restored_minor',restored,'held_minor',held,'receivable_review_minor',review);
 r:=r||jsonb_build_object('invalidated_distribution_cycles',billing.invalidate_pending_credit_distributions(c.well_id));
 insert into billing.customer_credit_events(id,tenant_id,well_id,farmer_well_account_id,source_id,origin_source_id,source_revision,operation,
 request_payload,result_payload,reason,created_by,journal_entry_id)
 values(e,c.tenant_id,c.well_id,c.farmer_well_account_id,p_source,coalesce(p_origin_id,p_source),p_revision,'reverse',request,r,p_reason,actor,j);
 return r;
end;$$;
create or replace function billing.reverse_account_credit(p_credit uuid,p_amount bigint,p_source uuid,p_revision bigint,
 p_reason text,p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c billing.account_credits%rowtype;p billing.payments%rowtype;
begin
 select * into strict c from billing.account_credits where id=p_credit;
 select * into strict p from billing.payments where id=c.payment_id;
 if c.source_type='allocation_release' and p.purpose<>'session' then
  return billing.reverse_allocation_credit_legacy(p_credit,p_amount,p_source,p_revision,p_reason,p_posted_at,p_origin_id);
 end if;
 return billing.repartition_payment_internal(p.id,null,p_credit,p_amount,'reverse',p_source,p_revision,p_reason,p_posted_at,p_origin_id);
end;$$;
create function billing.validate_payment_repartition(e billing.customer_credit_events) returns void
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare m billing.payment_repartition_events%rowtype;p billing.payments%rowtype;v record;c billing.account_credits%rowtype;
 a billing.payment_allocation_adjustments%rowtype;n numeric;expected_j bigint:=0;issue boolean:=false;
begin
 select * into strict m from billing.payment_repartition_events where event_id=e.id;
 select * into strict p from billing.payments where id=m.payment_id;
 if (e.tenant_id,e.well_id,e.farmer_well_account_id) is distinct from (m.tenant_id,m.well_id,m.farmer_well_account_id)
  or (p.tenant_id,p.well_id,p.farmer_well_account_id) is distinct from (m.tenant_id,m.well_id,m.farmer_well_account_id)
  or m.credit_amount_minor>m.amount_minor or e.journal_entry_id is distinct from m.journal_entry_id
  or e.result_payload->>'event_id' is distinct from e.id::text or e.result_payload->>'status' is distinct from m.status
  or e.result_payload->>'payment_id' is distinct from p.id::text
  or e.result_payload->>'credit_id' is distinct from m.credit_id::text
  or e.result_payload->>'credit_amount_minor' is distinct from m.credit_amount_minor::text
  or e.result_payload->>'amount_minor' is distinct from m.amount_minor::text
  or e.result_payload->>'reason' is distinct from m.review_reason
  or e.operation is distinct from (case m.mode when 'restore' then 'restore_allocation' when 'rebalance' then 'rebalance_payment'
    when 'withdraw' then 'partition_withdraw' else m.mode end) then
  raise exception 'payment_repartition_event_inconsistent' using errcode='23514';end if;
 if p.status='posted' then
 select * into strict v from billing.payment_economic_applications where payment_id=p.id;
 if v.explicit_allocated_minor+v.effective_direct_minor+v.credit_backed_minor+v.remaining_minor<>p.amount_minor
  or least(v.explicit_allocated_minor,v.effective_direct_minor,v.credit_backed_minor,v.remaining_minor)<0 then
  raise exception 'payment_partition_value_violation' using errcode='23514';end if;
 else
  if exists(select 1 from billing.account_credit_balances where payment_id=p.id and amount_minor>reversed_minor) then
   raise exception 'reversed_payment_has_live_credit' using errcode='23514';end if;
 end if;
 if m.status='financial_review_required' then
  if m.allocation_adjustment_id is not null or m.credit_id is not null or m.credit_amount_minor<>0
   or exists(select 1 from billing.account_credit_reversals where event_id=e.id)
   or exists(select 1 from billing.payment_repartition_events where parent_event_id=e.id) then
   raise exception 'payment_review_has_partial_effect' using errcode='23514';end if;return;
 end if;
 if m.mode='release' or m.mode='restore' or(m.mode='reverse' and m.allocation_id is not null) then
  select * into strict a from billing.payment_allocation_adjustments where id=m.allocation_adjustment_id;
  if a.event_id<>e.id or a.allocation_id<>m.allocation_id or a.amount_minor<>m.amount_minor
   or a.operation<>(case when m.mode='release' then 'release' else 'restore' end) then
   raise exception 'payment_repartition_allocation_invalid' using errcode='23514';end if;
 end if;
 if m.mode in ('release','rebalance') and m.credit_amount_minor>0 then
  select * into strict c from billing.account_credits where id=m.credit_id;
  if c.payment_id<>p.id or c.event_id<>e.id or c.amount_minor<>m.credit_amount_minor
   or (c.source_id,c.origin_source_id,c.source_revision) is distinct from(e.source_id,e.origin_source_id,e.source_revision) then
   raise exception 'payment_repartition_credit_invalid' using errcode='23514';end if;
  expected_j:=m.credit_amount_minor;issue:=true;
 elsif m.mode='withdraw' or (m.mode='reverse' and m.allocation_id is null) then
  if not exists(select 1 from billing.account_credit_reversals r join billing.account_credits src on src.id=r.credit_id
   where src.payment_id=p.id and (src.tenant_id,src.well_id,src.farmer_well_account_id)=(m.tenant_id,m.well_id,m.farmer_well_account_id)
   and r.event_id=e.id and r.credit_id=m.credit_id
   and r.requested_minor=m.amount_minor and r.restored_minor=m.amount_minor and r.held_minor=0 and r.receivable_review_minor=0) then
   raise exception 'payment_repartition_withdrawal_invalid' using errcode='23514';end if;
  expected_j:=m.amount_minor;
 else
  select coalesce(sum(credit_amount_minor),0) into n from billing.payment_repartition_events where parent_event_id=e.id and status='accepted';
  if n<>m.credit_amount_minor then raise exception 'payment_repartition_children_invalid' using errcode='23514';end if;
  if p.purpose='advance' then expected_j:=m.amount_minor-m.credit_amount_minor;end if;
 end if;
 if m.mode='withdraw' and not exists(select 1 from billing.payment_repartition_events parent where parent.event_id=m.parent_event_id
  and parent.payment_id=p.id and parent.status='accepted' and (parent.mode='restore' or parent.mode='reverse')) then
  raise exception 'payment_withdrawal_parent_invalid' using errcode='23514';end if;
 if expected_j>0 then
  if not exists(select 1 from finance.journal_entries j where j.id=m.journal_entry_id and j.status='posted'
    and j.tenant_id=m.tenant_id and j.well_id=m.well_id and j.source_type='customer_credit' and j.source_id=e.id)
   or (select count(*) from finance.journal_lines where journal_entry_id=m.journal_entry_id)<>2
   or not exists(select 1 from finance.journal_lines l where l.journal_entry_id=m.journal_entry_id and l.entry_side='debit'
    and l.ledger_account_id=finance.ledger_account_id(m.well_id,case when issue then '1100' else '2000' end)
    and l.amount_minor=expected_j and l.cashbox_id is null and l.farmer_well_account_id=m.farmer_well_account_id)
   or not exists(select 1 from finance.journal_lines l where l.journal_entry_id=m.journal_entry_id and l.entry_side='credit'
    and l.ledger_account_id=finance.ledger_account_id(m.well_id,case when issue then '2000' else '1100' end)
    and l.amount_minor=expected_j and l.cashbox_id is null and l.farmer_well_account_id=m.farmer_well_account_id) then
   raise exception 'payment_repartition_posting_invalid' using errcode='23514';end if;
 elsif m.journal_entry_id is not null then raise exception 'payment_transfer_unexpected_posting' using errcode='23514';end if;
end;$$;
create function billing.check_payment_repartition_link() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare e billing.customer_credit_events%rowtype;
begin
 select * into strict e from billing.customer_credit_events where id=new.event_id;
 perform billing.validate_payment_repartition(e);return null;
end;$$;
create constraint trigger payment_repartition_event_integrity after insert on billing.payment_repartition_events
 deferrable initially deferred for each row execute function billing.check_payment_repartition_link();

create function billing.guard_payment_destination_identity() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin
 if old.status in ('posted','reversed') and (old.tenant_id,old.well_id,old.farmer_well_account_id,old.session_charge_id,old.purpose)
  is distinct from(new.tenant_id,new.well_id,new.farmer_well_account_id,new.session_charge_id,new.purpose) then
  raise exception 'posted_payment_destination_immutable' using errcode='23514';end if;return new;
end;$$;
create trigger payment_destination_identity before update on billing.payments
 for each row execute function billing.guard_payment_destination_identity();
create trigger payment_repartition_immutable before update or delete on billing.payment_repartition_events
 for each row execute function billing.reject_credit_history_mutation();

create or replace function billing.guard_customer_credit_insert() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare c billing.account_credits%rowtype;i billing.invoices%rowtype;x record;n bigint;
begin
 if TG_TABLE_NAME='account_credits' then
  if new.source_type='payment_repartition' then
   select * into strict x from billing.payment_repartition_events where event_id=new.repartition_event_id;
   if x.status<>'accepted' or x.mode not in ('release','rebalance') or x.payment_id<>new.payment_id
    or x.credit_id<>new.id or x.credit_amount_minor<>new.amount_minor or x.event_id<>new.event_id
    or (x.tenant_id,x.well_id,x.farmer_well_account_id) is distinct from(new.tenant_id,new.well_id,new.farmer_well_account_id) then
    raise exception 'payment_partition_credit_source_invalid' using errcode='23514';end if;return new;
  end if;
 end if;
 if TG_TABLE_NAME='account_credits' then
  select adj.*,pa.payment_id into strict x from billing.payment_allocation_adjustments adj
   join billing.payment_allocations pa on pa.id=adj.allocation_id where adj.id=new.allocation_adjustment_id;
  if x.operation<>'release' or new.amount_minor<>x.amount_minor or new.payment_id<>x.payment_id
   or new.event_id<>x.event_id or new.tenant_id<>x.tenant_id or new.well_id<>x.well_id
   or new.farmer_well_account_id<>x.farmer_well_account_id then
   raise exception 'credit_release_source_mismatch' using errcode='23514';end if;
 else
  select * into strict c from billing.account_credits where id=new.credit_id for update;
  if new.tenant_id<>c.tenant_id or new.well_id<>c.well_id or new.farmer_well_account_id<>c.farmer_well_account_id then
   raise exception 'credit_effect_scope_mismatch' using errcode='23514';end if;
  select available_minor into n from billing.account_credit_balances where id=c.id;
  if TG_TABLE_NAME='account_credit_applications' then
   select * into strict i from billing.invoices where id=new.invoice_id for update;
   if i.tenant_id<>c.tenant_id or i.well_id<>c.well_id or i.farmer_well_account_id<>c.farmer_well_account_id
    or i.deducted_in_cycle_id is not null or i.status not in ('issued','partially_paid','overdue') or new.amount_minor>n or new.amount_minor>i.outstanding_minor then
    raise exception 'credit_application_out_of_range' using errcode='23514';end if;
  else
   if new.restored_minor+new.held_minor>n or new.requested_minor>
     c.amount_minor-coalesce((select sum(requested_minor) from billing.account_credit_reversals where credit_id=c.id),0) then
    raise exception 'credit_reversal_out_of_range' using errcode='23514';end if;
  end if;
 end if;
 return new;
end;$$;
create or replace function billing.check_customer_credit_event() returns trigger language plpgsql security definer
set search_path=pg_catalog,pg_temp as $$
declare c billing.account_credits%rowtype;a billing.payment_allocation_adjustments%rowtype;
 app billing.account_credit_applications%rowtype;rev billing.account_credit_reversals%rowtype;
 expected_amount bigint;payment uuid;
begin
 if exists(select 1 from billing.payment_repartition_events where event_id=new.id) then
  perform billing.validate_payment_repartition(new);return null;
 end if;
 if new.operation in ('application_release','application_restore') then
  perform billing.validate_application_adjustment_event(new);return null;
 end if;
 if new.operation<>'reverse' and new.result_payload->>'status'<>'accepted' then
  raise exception 'credit_event_status_inconsistent' using errcode='23514';end if;
 if new.operation='release' then
  select * into strict c from billing.account_credits where event_id=new.id;
  select * into strict a from billing.payment_allocation_adjustments where event_id=new.id and operation='release';
  if c.source_id<>new.source_id or c.origin_source_id<>new.origin_source_id or c.source_revision<>new.source_revision or c.amount_minor<>a.amount_minor
   or new.result_payload->>'credit_id' is distinct from c.id::text then
   raise exception 'credit_event_source_inconsistent' using errcode='23514';end if;
  expected_amount:=c.amount_minor;payment:=c.payment_id;
 elsif new.operation='apply' then
  select * into strict app from billing.account_credit_applications where event_id=new.id;
  select * into strict c from billing.account_credits where id=app.credit_id;
  if new.result_payload->>'application_id' is distinct from app.id::text then
   raise exception 'credit_event_source_inconsistent' using errcode='23514';end if;
  expected_amount:=app.amount_minor;payment:=c.payment_id;
 else
  select * into strict rev from billing.account_credit_reversals where event_id=new.id;
  select * into strict c from billing.account_credits where id=rev.credit_id;
  if rev.restored_minor>0 then
   select * into strict a from billing.payment_allocation_adjustments where event_id=new.id and operation='restore';
   if a.amount_minor<>rev.restored_minor or a.allocation_id is distinct from
     (select allocation_id from billing.payment_allocation_adjustments where id=c.allocation_adjustment_id) then
    raise exception 'credit_restoration_source_inconsistent' using errcode='23514';end if;
  end if;
  if new.result_payload->>'status' is distinct from rev.status then
   raise exception 'credit_event_status_inconsistent' using errcode='23514';end if;
  expected_amount:=rev.restored_minor;payment:=c.payment_id;
  if new.result_payload->>'reversal_id' is distinct from rev.id::text then
   raise exception 'credit_event_source_inconsistent' using errcode='23514';end if;
 end if;
 if new.tenant_id<>c.tenant_id or new.well_id<>c.well_id or new.farmer_well_account_id<>c.farmer_well_account_id
  or (select available_minor from billing.payment_available_balances where payment_id=payment)<0
  or (select available_minor from billing.account_credit_balances where id=c.id)<0 then
  raise exception 'credit_event_scope_or_balance_inconsistent' using errcode='23514';end if;
 if expected_amount>0 and not exists(select 1 from finance.journal_entries j where j.id=new.journal_entry_id
  and j.source_type='customer_credit' and j.source_id=new.id and j.status='posted') then
  raise exception 'credit_event_posting_missing' using errcode='23514';end if;
 if expected_amount=0 and new.journal_entry_id is not null then
  raise exception 'credit_review_has_unexpected_posting' using errcode='23514';end if;
 return null;
end;$$;
alter table billing.payment_repartition_events enable row level security;
revoke all on billing.payment_repartition_events from public,anon,authenticated,service_role;
grant select on billing.payment_repartition_events to authenticated,service_role;
create policy payment_repartition_read on billing.payment_repartition_events for select to authenticated using(exists(
 select 1 from ops.farmer_well_accounts a where a.id=payment_repartition_events.farmer_well_account_id
 and a.tenant_id=payment_repartition_events.tenant_id and a.well_id=payment_repartition_events.well_id));
revoke all on billing.payment_scope_evidence,billing.invoice_explicit_settlements,billing.default_session_debts,billing.payment_partition_inputs,
 billing.payment_economic_applications,billing.session_economic_settlements from public,anon,authenticated,service_role;
grant select on billing.payment_scope_evidence,billing.invoice_explicit_settlements,billing.default_session_debts,billing.payment_partition_inputs,
 billing.payment_economic_applications,billing.session_economic_settlements to authenticated,service_role;
revoke all on function billing.refresh_partition_invoices(uuid),
 billing.repartition_payment_internal(uuid,uuid,uuid,bigint,text,uuid,bigint,text,timestamptz,uuid,uuid),
 billing.release_payment_allocation(uuid,bigint,uuid,bigint,text,timestamptz,uuid),
 billing.restore_payment_allocation(uuid,bigint,uuid,bigint,text,timestamptz,uuid),
 billing.rebalance_payment_capacity(uuid,uuid,bigint,text,timestamptz,uuid),
 billing.reverse_allocation_credit_legacy(uuid,bigint,uuid,bigint,text,timestamptz,uuid),
 billing.reverse_account_credit(uuid,bigint,uuid,bigint,text,timestamptz,uuid),
 billing.validate_payment_repartition(billing.customer_credit_events),billing.check_payment_repartition_link(),
 billing.guard_payment_destination_identity() from public,anon,authenticated,service_role;
commit;

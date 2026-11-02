begin;
-- R6-C0: أساس مالي فقط. لا تعديل جلسة أو تكلفة أو فاتورة أصلية في هذا العقد.
create table billing.customer_credit_events (
 id uuid primary key,
 tenant_id uuid not null references core.tenants(id),
 well_id uuid not null references core.wells(id),
 farmer_well_account_id uuid not null references ops.farmer_well_accounts(id),
 source_type text not null default 'financial_correction' check(source_type='financial_correction'),
 source_id uuid not null,origin_source_id uuid not null,source_revision bigint not null check(source_revision>=0),
 operation text not null check(operation in ('release','apply','reverse')),
 request_payload jsonb not null check(jsonb_typeof(request_payload)='object'),
 result_payload jsonb not null check(jsonb_typeof(result_payload)='object'),
 reason text not null check(nullif(btrim(reason),'') is not null),
 created_by uuid not null references iam.profiles(id),created_at timestamptz not null default clock_timestamp(),
 journal_entry_id uuid references finance.journal_entries(id),
 unique(tenant_id,source_id,source_revision),
 check(coalesce(result_payload->>'status' in ('accepted','financial_review_required'),false)),
 check(coalesce(request_payload->>'operation'=operation and request_payload->>'reason'=reason
  and request_payload->>'actor'=created_by::text and request_payload->>'origin_source_id'=origin_source_id::text,false))
);
create index customer_credit_events_origin_idx on billing.customer_credit_events(tenant_id,origin_source_id,source_revision);
create table billing.payment_allocation_adjustments (
 id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references core.tenants(id),well_id uuid not null references core.wells(id),
 farmer_well_account_id uuid not null references ops.farmer_well_accounts(id),
 allocation_id uuid not null references billing.payment_allocations(id),
 event_id uuid not null references billing.customer_credit_events(id) deferrable initially deferred,
 operation text not null check(operation in ('release','restore')),
 amount_minor bigint not null check(amount_minor>0),
 reason text not null check(nullif(btrim(reason),'') is not null),created_by uuid not null references iam.profiles(id),
 created_at timestamptz not null default clock_timestamp(),unique(event_id,operation)
);
create index allocation_adjustments_original_idx on billing.payment_allocation_adjustments(allocation_id);
create table billing.account_credits (
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references core.tenants(id),
 well_id uuid not null references core.wells(id),farmer_well_account_id uuid not null references ops.farmer_well_accounts(id),
 payment_id uuid not null references billing.payments(id),
 allocation_adjustment_id uuid not null unique references billing.payment_allocation_adjustments(id),
 event_id uuid not null unique references billing.customer_credit_events(id) deferrable initially deferred,
 source_type text not null default 'allocation_release' check(source_type='allocation_release'),
 source_id uuid not null,origin_source_id uuid not null,source_revision bigint not null check(source_revision>=0),
 amount_minor bigint not null check(amount_minor>0),reason text not null check(nullif(btrim(reason),'') is not null),
 created_by uuid not null references iam.profiles(id),created_at timestamptz not null default clock_timestamp(),
 unique(tenant_id,source_id,source_revision)
);
create index account_credits_payment_idx on billing.account_credits(payment_id);
create index account_credits_account_idx on billing.account_credits(farmer_well_account_id,id);
create index account_credits_well_idx on billing.account_credits(well_id);
create table billing.account_credit_applications (
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references core.tenants(id),
 well_id uuid not null references core.wells(id),farmer_well_account_id uuid not null references ops.farmer_well_accounts(id),
 credit_id uuid not null references billing.account_credits(id),invoice_id uuid not null references billing.invoices(id),
 event_id uuid not null unique references billing.customer_credit_events(id) deferrable initially deferred,
 amount_minor bigint not null check(amount_minor>0),reason text not null check(nullif(btrim(reason),'') is not null),
 created_by uuid not null references iam.profiles(id),created_at timestamptz not null default clock_timestamp()
);
create index credit_applications_credit_idx on billing.account_credit_applications(credit_id);
create index credit_applications_invoice_idx on billing.account_credit_applications(invoice_id);
create table billing.account_credit_reversals (
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references core.tenants(id),
 well_id uuid not null references core.wells(id),farmer_well_account_id uuid not null references ops.farmer_well_accounts(id),
 credit_id uuid not null references billing.account_credits(id),
 event_id uuid not null unique references billing.customer_credit_events(id) deferrable initially deferred,
 requested_minor bigint not null check(requested_minor>0),
 restored_minor bigint not null check(restored_minor>=0),held_minor bigint not null check(held_minor>=0),
 receivable_review_minor bigint not null check(receivable_review_minor>=0),
 status text not null check(status in ('accepted','financial_review_required')),
 reason text not null check(nullif(btrim(reason),'') is not null),created_by uuid not null references iam.profiles(id),
 created_at timestamptz not null default clock_timestamp(),
 check(requested_minor=restored_minor+held_minor+receivable_review_minor),
 check((status='accepted')=(held_minor+receivable_review_minor=0))
);
create index credit_reversals_credit_idx on billing.account_credit_reversals(credit_id);

-- الاحتفاظ بالجزء التاريخي المسدد بوسيلة غير ممثلة في صفوف التخصيص.
-- لا تتغير مبالغ الفواتير أو المدفوعات أو التخصيصات عند تأسيس هذا العمود.
alter table billing.invoices add column nonallocation_paid_minor bigint not null default 0
 check(nonallocation_paid_minor>=0);
update billing.invoices i set nonallocation_paid_minor=greatest(i.paid_minor-coalesce((
 select sum(pa.allocated_minor) from billing.payment_allocations pa where pa.invoice_id=i.id),0),0);

create view billing.effective_payment_allocations with (security_invoker=true) as
select pa.*,pa.allocated_minor-coalesce(x.released_minor,0)+coalesce(x.restored_minor,0) as effective_allocated_minor,
 coalesce(x.released_minor,0)-coalesce(x.restored_minor,0) as released_minor
from billing.payment_allocations pa left join lateral(
 select sum(amount_minor) filter(where operation='release') as released_minor,
 sum(amount_minor) filter(where operation='restore') as restored_minor
 from billing.payment_allocation_adjustments x where x.allocation_id=pa.id) x on true;
create view billing.account_credit_balances with (security_invoker=true) as
select c.*,coalesce(a.used_minor,0) as used_minor,coalesce(r.restored_minor,0) as reversed_minor,
 coalesce(r.held_minor,0) as held_minor,coalesce(r.review_minor,0) as receivable_review_minor,
 c.amount_minor-coalesce(a.used_minor,0)-coalesce(r.restored_minor,0)-coalesce(r.held_minor,0) as available_minor
from billing.account_credits c
left join lateral(select sum(amount_minor) as used_minor from billing.account_credit_applications a where a.credit_id=c.id) a on true
left join lateral(select sum(restored_minor) as restored_minor,sum(held_minor) as held_minor,
 sum(receivable_review_minor) as review_minor from billing.account_credit_reversals r where r.credit_id=c.id) r on true;
create view billing.payment_available_balances with (security_invoker=true) as
select p.id as payment_id,p.tenant_id,p.well_id,p.farmer_well_account_id,p.purpose,p.status,p.amount_minor,
 coalesce(a.effective_minor,0) as effective_allocated_minor,
 coalesce(c.reserved_minor,0) as credit_reserved_minor,
 p.amount_minor-coalesce(a.effective_minor,0)-coalesce(c.reserved_minor,0) as available_minor
from billing.payments p
left join lateral(select sum(effective_allocated_minor) as effective_minor from billing.effective_payment_allocations a where a.payment_id=p.id) a on true
left join lateral(select sum(amount_minor-reversed_minor) as reserved_minor from billing.account_credit_balances c where c.payment_id=p.id) c on true;
create view billing.invoice_effective_balances with (security_invoker=true) as
select i.id as invoice_id,i.well_id,i.tenant_id,i.farmer_well_account_id,i.total_minor,
 i.nonallocation_paid_minor+coalesce(a.amount_minor,0)+coalesce(c.amount_minor,0) as paid_minor,
 i.total_minor-i.nonallocation_paid_minor-coalesce(a.amount_minor,0)-coalesce(c.amount_minor,0) as outstanding_minor
from billing.invoices i
left join lateral(select sum(effective_allocated_minor) as amount_minor from billing.effective_payment_allocations a where a.invoice_id=i.id) a on true
left join lateral(select sum(amount_minor) as amount_minor from billing.account_credit_applications c where c.invoice_id=i.id) c on true;

create function billing.reject_credit_history_mutation() returns trigger
language plpgsql set search_path=pg_catalog,pg_temp as $$
begin raise exception 'financial_history_append_only' using errcode='23514';end;$$;
create trigger original_allocation_immutable before update or delete on billing.payment_allocations
 for each row execute function billing.reject_credit_history_mutation();
do $install$
declare t text;
begin
 foreach t in array array['customer_credit_events','payment_allocation_adjustments','account_credits',
 'account_credit_applications','account_credit_reversals'] loop
 execute format('alter table billing.%I enable row level security',t);
 execute format('revoke all on billing.%I from public,anon,authenticated,service_role',t);
 execute format('create trigger immutable_credit_history before update or delete on billing.%I for each row execute function billing.reject_credit_history_mutation()',t);
 if t<>'customer_credit_events' then
  execute format('grant select on billing.%I to authenticated,service_role',t);
  execute format('create policy credit_account_read on billing.%I for select to authenticated using
  (exists(select 1 from ops.farmer_well_accounts a where a.id=%I.farmer_well_account_id
   and a.well_id=%I.well_id and a.tenant_id=%I.tenant_id))',t,t,t,t);
 end if;
 end loop;
end;$install$;
grant select on billing.effective_payment_allocations,billing.account_credit_balances,
 billing.payment_available_balances,billing.invoice_effective_balances to authenticated,service_role;
revoke all on function billing.reject_credit_history_mutation() from public,anon,authenticated,service_role;

create function billing.refresh_effective_invoice(p_invoice uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare b record;s text;
begin
 select status into s from billing.invoices where id=p_invoice for update;
 select * into strict b from billing.invoice_effective_balances where invoice_id=p_invoice;
 if b.paid_minor<0 or b.outstanding_minor<0 then
  raise exception 'effective_invoice_allocation_out_of_range' using errcode='23514';end if;
 update billing.invoices set paid_minor=b.paid_minor,outstanding_minor=b.outstanding_minor,
 status=case when s in ('draft','cancelled','reversed') then s when b.outstanding_minor=0 then 'paid'
  when b.paid_minor>0 then 'partially_paid' when s='overdue' then s else 'issued' end where id=p_invoice;
end;$$;
create function billing.guard_allocation_adjustment() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare a billing.payment_allocations%rowtype;i billing.invoices%rowtype;p billing.payments%rowtype;n bigint;
begin
 select * into strict a from billing.payment_allocations where id=new.allocation_id for update;
 select * into strict i from billing.invoices where id=a.invoice_id;
 select * into strict p from billing.payments where id=a.payment_id;
 if new.tenant_id is distinct from a.tenant_id or new.tenant_id is distinct from i.tenant_id
  or new.well_id is distinct from i.well_id or new.farmer_well_account_id is distinct from i.farmer_well_account_id
  or not exists(select 1 from core.wells w join ops.farmer_well_accounts fa on fa.well_id=w.id and fa.tenant_id=w.tenant_id
    where w.id=i.well_id and w.tenant_id=i.tenant_id and fa.id=i.farmer_well_account_id)
  or p.tenant_id is distinct from i.tenant_id or p.well_id is distinct from i.well_id or p.farmer_well_account_id is distinct from i.farmer_well_account_id then
  raise exception 'allocation_adjustment_scope_mismatch' using errcode='23514';end if;
 select effective_allocated_minor into n from billing.effective_payment_allocations where id=a.id;
 n:=n+case when new.operation='release' then -new.amount_minor else new.amount_minor end;
 if n<0 or n>a.allocated_minor then raise exception 'allocation_adjustment_out_of_range' using errcode='23514';end if;
 return new;
end;$$;
create trigger allocation_adjustment_guard before insert on billing.payment_allocation_adjustments
 for each row execute function billing.guard_allocation_adjustment();
create function billing.refresh_adjusted_invoice() returns trigger language plpgsql security definer
set search_path=pg_catalog,pg_temp as $$
begin
 if TG_TABLE_NAME='payment_allocation_adjustments' then
  perform billing.refresh_effective_invoice((select invoice_id from billing.payment_allocations where id=new.allocation_id));
 else perform billing.refresh_effective_invoice(new.invoice_id);end if;
 return new;
end;$$;
create trigger allocation_adjustment_refresh after insert on billing.payment_allocation_adjustments
 for each row execute function billing.refresh_adjusted_invoice();
create trigger credit_application_refresh after insert on billing.account_credit_applications
 for each row execute function billing.refresh_adjusted_invoice();

-- إعادة الحدث تحت قفل مستقل لهويته، ثم أقفال payment -> allocation/credit -> invoice.
create function billing.credit_event_replay(p_tenant uuid,p_source uuid,p_revision bigint,p_request jsonb)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare e billing.customer_credit_events%rowtype;
begin
 if p_source is null or p_revision is null or p_revision<0 then
  raise exception 'financial_source_identity_required' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_tenant::text||':'||p_source::text||':'||p_revision::text,0));
 select * into e from billing.customer_credit_events where tenant_id=p_tenant and source_id=p_source and source_revision=p_revision;
 if found then
  if e.request_payload is distinct from p_request then raise exception 'financial_source_payload_mismatch' using errcode='22023';end if;
  return e.result_payload;
 end if;
 return null;
end;$$;
create function billing.post_customer_credit_entry(p_event uuid,p_tenant uuid,p_well uuid,p_account uuid,
 p_amount bigint,p_issue boolean,p_posted_at timestamptz,p_actor uuid) returns uuid
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare j uuid;
begin
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

-- تسلسل مالي للبئر مشترك مع حساب/اعتماد التوزيع؛ لا يمس نسخة جدول التشغيل.
create function billing.lock_customer_credit_well(p_well uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
begin
 if p_well is null then raise exception 'financial_well_required' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('customer-credit-well:'||p_well::text,0));
end;$$;
create function billing.invalidate_pending_credit_distributions(p_well uuid) returns jsonb
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 with invalidated as (
  update finance.profit_distribution_cycles set status='cancelled'
   where well_id=p_well and status in ('draft','calculated','under_review') returning id)
 select coalesce(jsonb_agg(id order by id),'[]') from invalidated;
$$;
revoke all on function billing.lock_customer_credit_well(uuid),billing.invalidate_pending_credit_distributions(uuid)
 from public,anon,authenticated,service_role;

create function billing.release_payment_allocation(p_allocation uuid,p_amount bigint,p_source uuid,p_revision bigint,
 p_reason text,p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare a billing.payment_allocations%rowtype;p billing.payments%rowtype;i billing.invoices%rowtype;
 actor uuid:=auth.uid();request jsonb;r jsonb;e uuid:=gen_random_uuid();adjustment uuid;credit uuid;j uuid;
begin
 select * into strict a from billing.payment_allocations where id=p_allocation;
 select * into strict i from billing.invoices where id=a.invoice_id;
 if actor is null or not coalesce(iam.has_well_permission(i.well_id,'session.correct'),false) then
  raise exception 'financial_correction_forbidden' using errcode='42501';end if;
 if p_amount is null or p_amount<=0 or nullif(btrim(p_reason),'') is null or p_posted_at is null or not isfinite(p_posted_at) then
  raise exception 'financial_effect_facts_required' using errcode='22023';end if;
 request:=jsonb_build_object('operation','release','allocation',p_allocation,'amount',p_amount,'reason',p_reason,
  'posted_at',to_char(p_posted_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'actor',actor,'origin_source_id',coalesce(p_origin_id,p_source));
 perform billing.lock_customer_credit_well(i.well_id);
 r:=billing.credit_event_replay(i.tenant_id,p_source,p_revision,request);if r is not null then return r;end if;
 select * into strict p from billing.payments where id=a.payment_id for update;
 perform 1 from billing.payment_allocations where id=a.id for update;
 select * into strict i from billing.invoices where id=a.invoice_id for update;
 if i.deducted_in_cycle_id is not null then
  raise exception 'allocation_release_requires_distribution_review' using errcode='23514';end if;
 if p.status<>'posted' or i.status not in ('issued','partially_paid','paid','overdue') then
  raise exception 'allocation_release_ineligible' using errcode='23514';end if;
 insert into billing.payment_allocation_adjustments(tenant_id,well_id,farmer_well_account_id,allocation_id,event_id,operation,amount_minor,reason,created_by)
 values(i.tenant_id,i.well_id,i.farmer_well_account_id,a.id,e,'release',p_amount,p_reason,actor) returning id into adjustment;
 insert into billing.account_credits(tenant_id,well_id,farmer_well_account_id,payment_id,allocation_adjustment_id,event_id,
 source_id,origin_source_id,source_revision,amount_minor,reason,created_by)
 values(i.tenant_id,i.well_id,i.farmer_well_account_id,p.id,adjustment,e,p_source,coalesce(p_origin_id,p_source),p_revision,p_amount,p_reason,actor) returning id into credit;
 j:=billing.post_customer_credit_entry(e,i.tenant_id,i.well_id,i.farmer_well_account_id,p_amount,true,p_posted_at,actor);
 r:=jsonb_build_object('status','accepted','event_id',e,'adjustment_id',adjustment,'credit_id',credit,'released_minor',p_amount);
 r:=r||jsonb_build_object('invalidated_distribution_cycles',billing.invalidate_pending_credit_distributions(i.well_id));
 insert into billing.customer_credit_events(id,tenant_id,well_id,farmer_well_account_id,source_id,origin_source_id,source_revision,operation,
 request_payload,result_payload,reason,created_by,journal_entry_id)
 values(e,i.tenant_id,i.well_id,i.farmer_well_account_id,p_source,coalesce(p_origin_id,p_source),p_revision,'release',request,r,p_reason,actor,j);
 return r;
end;$$;

create function billing.apply_account_credit(p_credit uuid,p_invoice uuid,p_amount bigint,p_source uuid,p_revision bigint,
 p_reason text,p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c billing.account_credits%rowtype;i billing.invoices%rowtype;actor uuid:=auth.uid();
 request jsonb;r jsonb;e uuid:=gen_random_uuid();app uuid;j uuid;available bigint;
begin
 select * into strict c from billing.account_credits where id=p_credit;
 if actor is null or not coalesce(iam.has_well_permission(c.well_id,'payment.allocate'),false) then
  raise exception 'credit_application_forbidden' using errcode='42501';end if;
 if p_amount is null or p_amount<=0 or nullif(btrim(p_reason),'') is null or p_posted_at is null or not isfinite(p_posted_at) then
  raise exception 'financial_effect_facts_required' using errcode='22023';end if;
 request:=jsonb_build_object('operation','apply','credit',p_credit,'invoice',p_invoice,'amount',p_amount,'reason',p_reason,
 'posted_at',to_char(p_posted_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'actor',actor,'origin_source_id',coalesce(p_origin_id,p_source));
 perform billing.lock_customer_credit_well(c.well_id);
 r:=billing.credit_event_replay(c.tenant_id,p_source,p_revision,request);if r is not null then return r;end if;
 perform 1 from billing.account_credits where id=c.id for update;
 select * into strict i from billing.invoices where id=p_invoice for update;
 if i.tenant_id<>c.tenant_id or i.well_id<>c.well_id or i.farmer_well_account_id<>c.farmer_well_account_id
  or i.deducted_in_cycle_id is not null or i.status not in ('issued','partially_paid','overdue') then
  raise exception 'credit_invoice_scope_or_state_invalid' using errcode='23514';end if;
 select available_minor into available from billing.account_credit_balances where id=c.id;
 if p_amount>available or p_amount>i.outstanding_minor then raise exception 'credit_application_out_of_range' using errcode='23514';end if;
 insert into billing.account_credit_applications(tenant_id,well_id,farmer_well_account_id,credit_id,invoice_id,event_id,amount_minor,reason,created_by)
 values(c.tenant_id,c.well_id,c.farmer_well_account_id,c.id,i.id,e,p_amount,p_reason,actor) returning id into app;
 j:=billing.post_customer_credit_entry(e,c.tenant_id,c.well_id,c.farmer_well_account_id,p_amount,false,p_posted_at,actor);
 r:=jsonb_build_object('status','accepted','event_id',e,'application_id',app,'applied_minor',p_amount);
 r:=r||jsonb_build_object('invalidated_distribution_cycles',billing.invalidate_pending_credit_distributions(c.well_id));
 insert into billing.customer_credit_events(id,tenant_id,well_id,farmer_well_account_id,source_id,origin_source_id,source_revision,operation,
 request_payload,result_payload,reason,created_by,journal_entry_id)
 values(e,c.tenant_id,c.well_id,c.farmer_well_account_id,p_source,coalesce(p_origin_id,p_source),p_revision,'apply',request,r,p_reason,actor,j);
 return r;
end;$$;

-- لا نحذف رصيدًا استُهلك: نعيد غير المستهلك إلى التخصيص الأصلي إذا قبل الدين
-- ذلك، وإلا نحجزه للمراجعة. الجزء المستهلك يظهر كعاقبة ذمة للمراجعة لا كدين مكرر.
create function billing.reverse_account_credit(p_credit uuid,p_amount bigint,p_source uuid,p_revision bigint,
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
 if restored>0 then
  insert into billing.payment_allocation_adjustments(tenant_id,well_id,farmer_well_account_id,allocation_id,event_id,operation,amount_minor,reason,created_by)
  values(c.tenant_id,c.well_id,c.farmer_well_account_id,a.id,e,'restore',restored,p_reason,actor);
 end if;
 insert into billing.account_credit_reversals(tenant_id,well_id,farmer_well_account_id,credit_id,event_id,requested_minor,
 restored_minor,held_minor,receivable_review_minor,status,reason,created_by)
 values(c.tenant_id,c.well_id,c.farmer_well_account_id,c.id,e,p_amount,restored,held,review,s,p_reason,actor) returning id into rev;
 j:=billing.post_customer_credit_entry(e,c.tenant_id,c.well_id,c.farmer_well_account_id,restored,false,p_posted_at,actor);
 r:=jsonb_build_object('status',s,'event_id',e,'reversal_id',rev,'restored_minor',restored,'held_minor',held,'receivable_review_minor',review);
 r:=r||jsonb_build_object('invalidated_distribution_cycles',billing.invalidate_pending_credit_distributions(c.well_id));
 insert into billing.customer_credit_events(id,tenant_id,well_id,farmer_well_account_id,source_id,origin_source_id,source_revision,operation,
 request_payload,result_payload,reason,created_by,journal_entry_id)
 values(e,c.tenant_id,c.well_id,c.farmer_well_account_id,p_source,coalesce(p_origin_id,p_source),p_revision,'reverse',request,r,p_reason,actor,j);
 return r;
end;$$;

-- جميع الكتّاب خاصة؛ لا يستطيع authenticated أو service_role سكّ رصيد.
revoke all on function billing.refresh_effective_invoice(uuid),billing.guard_allocation_adjustment(),
 billing.refresh_adjusted_invoice(),billing.credit_event_replay(uuid,uuid,bigint,jsonb),
 billing.post_customer_credit_entry(uuid,uuid,uuid,uuid,bigint,boolean,timestamptz,uuid),
 billing.release_payment_allocation(uuid,bigint,uuid,bigint,text,timestamptz,uuid),
 billing.apply_account_credit(uuid,uuid,bigint,uuid,bigint,text,timestamptz,uuid),
 billing.reverse_account_credit(uuid,bigint,uuid,bigint,text,timestamptz,uuid)
 from public,anon,authenticated,service_role;

-- حراس الجداول نفسها تمنع تجاوز المصدر أو الرصيد حتى عند خطأ كاتب داخلي.
create function billing.guard_customer_credit_insert() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare c billing.account_credits%rowtype;i billing.invoices%rowtype;x record;n bigint;
begin
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
create trigger credit_source_guard before insert on billing.account_credits
 for each row execute function billing.guard_customer_credit_insert();
create trigger credit_application_guard before insert on billing.account_credit_applications
 for each row execute function billing.guard_customer_credit_insert();
create trigger credit_reversal_guard before insert on billing.account_credit_reversals
 for each row execute function billing.guard_customer_credit_insert();
revoke all on function billing.guard_customer_credit_insert() from public,anon,authenticated,service_role;
revoke all on billing.effective_payment_allocations,billing.account_credit_balances,
 billing.payment_available_balances,billing.invoice_effective_balances from public,anon;

-- أصل القبض لا يتغير، ولا يعكسه مسار قديم بينما رصيد مشتق منه ما زال قائمًا.
create function billing.guard_payment_credit_backing() returns trigger language plpgsql security definer
set search_path=pg_catalog,pg_temp as $$
begin
 if old.status<>'draft' and (new.amount_minor is distinct from old.amount_minor or new.paid_at is distinct from old.paid_at) then
  raise exception 'original_payment_amount_time_immutable' using errcode='23514';end if;
 if exists(select 1 from billing.account_credits where payment_id=old.id) and
  (new.tenant_id is distinct from old.tenant_id or new.well_id is distinct from old.well_id
   or new.farmer_well_account_id is distinct from old.farmer_well_account_id
   or new.purpose is distinct from old.purpose or new.session_charge_id is distinct from old.session_charge_id
   or (new.status is distinct from old.status and exists(select 1 from billing.account_credit_balances
     where payment_id=old.id and amount_minor>reversed_minor))) then
  raise exception 'payment_credit_backing_requires_reconciliation' using errcode='23514';end if;
 return new;
end;$$;
create trigger payment_credit_backing before update on billing.payments
 for each row execute function billing.guard_payment_credit_backing();
revoke all on function billing.guard_payment_credit_backing() from public,anon,authenticated,service_role;

-- التحقق المؤجل يغلق المعاملة على مصدر محفوظ وآثار متطابقة، لا أثر يتيم.
create function billing.check_customer_credit_event() returns trigger language plpgsql security definer
set search_path=pg_catalog,pg_temp as $$
declare c billing.account_credits%rowtype;a billing.payment_allocation_adjustments%rowtype;
 app billing.account_credit_applications%rowtype;rev billing.account_credit_reversals%rowtype;
 expected_amount bigint;payment uuid;
begin
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
create constraint trigger customer_credit_event_integrity after insert on billing.customer_credit_events
 deferrable initially deferred for each row execute function billing.check_customer_credit_event();
revoke all on function billing.check_customer_credit_event() from public,anon,authenticated,service_role;

-- العكس العام لقيد منفرد لا يسوّي دفتر الرصيد؛ يلزم المسار المالي الدلالي.
create function billing.guard_customer_credit_journal() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin
 if old.status='posted' and new.status='reversed' and
  (old.source_type='customer_credit' or exists(select 1 from billing.payments p
    join billing.account_credit_balances c on c.payment_id=p.id
    where p.journal_entry_id=old.id and c.amount_minor>c.reversed_minor)) then
  raise exception 'customer_credit_requires_domain_reconciliation' using errcode='23514';
 end if;
 return new;
end;$$;
create trigger customer_credit_journal_guard before update on finance.journal_entries
 for each row execute function billing.guard_customer_credit_journal();
revoke all on function billing.guard_customer_credit_journal() from public,anon,authenticated,service_role;
commit;

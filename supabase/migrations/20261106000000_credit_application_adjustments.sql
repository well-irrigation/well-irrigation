begin;
-- R6-C0.1: تعديل تطبيق الائتمان فقط؛ لا جلسة أو قبض أو تعديل لأصل التطبيق.
-- الأقفال لا تجدد لقطة REPEATABLE READ؛ رفض السياق غير المدعوم يمنع
-- قراءة مجموع قديم بعد انتظار الكاتب السابق. جميع كتّاب C0 تشترك بهذا القفل.
create or replace function billing.lock_customer_credit_well(p_well uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
begin
 if p_well is null then raise exception 'financial_well_required' using errcode='22023';end if;
 if current_setting('transaction_isolation')<>'read committed' then
  raise exception 'credit_financial_isolation_requires_read_committed' using errcode='25000';end if;
 perform pg_advisory_xact_lock(hashtextextended('customer-credit-well:'||p_well::text,0));
end;$$;
alter table billing.customer_credit_events drop constraint customer_credit_events_operation_check;
alter table billing.customer_credit_events add constraint customer_credit_events_operation_check
 check(operation in ('release','apply','reverse','application_release','application_restore'));

create table billing.account_credit_application_adjustments (
 id uuid primary key default gen_random_uuid(),
 event_id uuid not null unique references billing.customer_credit_events(id) deferrable initially deferred,
 tenant_id uuid not null references core.tenants(id),well_id uuid not null references core.wells(id),
 farmer_well_account_id uuid not null references ops.farmer_well_accounts(id),
 application_id uuid not null references billing.account_credit_applications(id),
 operation text not null check(operation in ('release','restore')),
 amount_minor bigint not null check(amount_minor>0),
 source_type text not null default 'financial_correction' check(source_type='financial_correction'),
 source_id uuid not null,origin_source_id uuid not null,source_revision bigint not null check(source_revision>=0),
 request_payload jsonb not null check(jsonb_typeof(request_payload)='object'),
 reason text not null check(nullif(btrim(reason),'') is not null),
 created_by uuid not null references iam.profiles(id),created_at timestamptz not null default clock_timestamp(),
 status text not null check(status in ('accepted','financial_review_required')),
 review_reason text,journal_entry_id uuid references finance.journal_entries(id),
 unique(tenant_id,source_id,source_revision),
 check((status='accepted' and review_reason is null and journal_entry_id is not null)
  or (status='financial_review_required' and review_reason is not null and journal_entry_id is null))
);
create index credit_application_adjustments_application_idx on billing.account_credit_application_adjustments(application_id);
alter table billing.account_credit_application_adjustments enable row level security;
revoke all on billing.account_credit_application_adjustments from public,anon,authenticated,service_role;
grant select on billing.account_credit_application_adjustments to authenticated,service_role;
create policy credit_application_adjustment_read on billing.account_credit_application_adjustments
 for select to authenticated using(exists(select 1 from ops.farmer_well_accounts a
  where a.id=account_credit_application_adjustments.farmer_well_account_id
   and a.tenant_id=account_credit_application_adjustments.tenant_id and a.well_id=account_credit_application_adjustments.well_id));
create trigger immutable_credit_application_adjustment before update or delete on billing.account_credit_application_adjustments
 for each row execute function billing.reject_credit_history_mutation();

create view billing.effective_account_credit_applications with(security_invoker=true) as
select a.*,coalesce(x.released_minor,0) as released_minor,coalesce(x.restored_minor,0) as restored_minor,
 a.amount_minor-coalesce(x.released_minor,0)+coalesce(x.restored_minor,0) as effective_amount_minor
from billing.account_credit_applications a left join lateral(
 select sum(amount_minor) filter(where operation='release') as released_minor,
 sum(amount_minor) filter(where operation='restore') as restored_minor
 from billing.account_credit_application_adjustments x where x.application_id=a.id and x.status='accepted')x on true;
revoke all on billing.effective_account_credit_applications from public,anon;
grant select on billing.effective_account_credit_applications to authenticated,service_role;

-- هذان فقط يجمعان التطبيق الخام في C0. بقية الكتّاب/القراءات ترث الصافي.
create or replace view billing.account_credit_balances with(security_invoker=true) as
select c.*,coalesce(a.used_minor,0) as used_minor,coalesce(r.restored_minor,0) as reversed_minor,
 coalesce(r.held_minor,0) as held_minor,coalesce(r.review_minor,0) as receivable_review_minor,
 c.amount_minor-coalesce(a.used_minor,0)-coalesce(r.restored_minor,0)-coalesce(r.held_minor,0) as available_minor
from billing.account_credits c
left join lateral(select sum(effective_amount_minor) as used_minor from billing.effective_account_credit_applications a where a.credit_id=c.id)a on true
left join lateral(select sum(restored_minor) as restored_minor,sum(held_minor) as held_minor,
 sum(receivable_review_minor) as review_minor from billing.account_credit_reversals r where r.credit_id=c.id)r on true;
create or replace view billing.invoice_effective_balances with(security_invoker=true) as
select i.id as invoice_id,i.well_id,i.tenant_id,i.farmer_well_account_id,i.total_minor,
 i.nonallocation_paid_minor+coalesce(a.amount_minor,0)+coalesce(c.amount_minor,0) as paid_minor,
 i.total_minor-i.nonallocation_paid_minor-coalesce(a.amount_minor,0)-coalesce(c.amount_minor,0) as outstanding_minor
from billing.invoices i
left join lateral(select sum(effective_allocated_minor) as amount_minor from billing.effective_payment_allocations a where a.invoice_id=i.id)a on true
left join lateral(select sum(effective_amount_minor) as amount_minor from billing.effective_account_credit_applications c where c.invoice_id=i.id)c on true;

create function billing.guard_credit_application_adjustment() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare a billing.account_credit_applications%rowtype;c billing.account_credits%rowtype;
 i billing.invoices%rowtype;b record;available numeric;
begin
 select credit_id into strict a.credit_id from billing.account_credit_applications where id=new.application_id;
 select * into strict c from billing.account_credits where id=a.credit_id for update;
 select * into strict a from billing.account_credit_applications where id=new.application_id for update;
 select * into strict i from billing.invoices where id=a.invoice_id for update;
 if new.tenant_id is distinct from a.tenant_id or new.well_id is distinct from a.well_id
  or new.farmer_well_account_id is distinct from a.farmer_well_account_id
  or c.tenant_id is distinct from a.tenant_id or c.well_id is distinct from a.well_id
  or c.farmer_well_account_id is distinct from a.farmer_well_account_id
  or i.tenant_id is distinct from a.tenant_id or i.well_id is distinct from a.well_id
  or i.farmer_well_account_id is distinct from a.farmer_well_account_id
  or not exists(select 1 from core.wells w join ops.farmer_well_accounts fa on fa.well_id=w.id and fa.tenant_id=w.tenant_id
    where w.id=a.well_id and w.tenant_id=a.tenant_id and fa.id=a.farmer_well_account_id) then
  raise exception 'application_adjustment_scope_mismatch' using errcode='23514';end if;
 if new.status='accepted' then
  select * into strict b from billing.effective_account_credit_applications where id=a.id;
  select available_minor into available from billing.account_credit_balances where id=c.id;
  if (new.operation='release' and new.amount_minor>b.effective_amount_minor)
   or (new.operation='restore' and (new.amount_minor>b.amount_minor-b.effective_amount_minor or new.amount_minor>available
     or new.amount_minor>i.outstanding_minor)) then
   raise exception 'application_adjustment_out_of_range' using errcode='23514';end if;
  if i.deducted_in_cycle_id is not null or i.status not in ('issued','partially_paid','paid','overdue')
   or exists(select 1 from billing.account_credit_reversals where credit_id=c.id and receivable_review_minor>0) then
   raise exception 'application_adjustment_requires_review' using errcode='23514';end if;
 end if;
 return new;
end;$$;
create trigger credit_application_adjustment_guard before insert on billing.account_credit_application_adjustments
 for each row execute function billing.guard_credit_application_adjustment();
create function billing.refresh_application_adjusted_invoice() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin
 if new.status='accepted' then
  perform billing.refresh_effective_invoice((select invoice_id from billing.account_credit_applications where id=new.application_id));
 end if;
 return new;
end;$$;
create trigger credit_application_adjustment_refresh after insert on billing.account_credit_application_adjustments
 for each row execute function billing.refresh_application_adjusted_invoice();

create function billing.adjust_credit_application(p_application uuid,p_operation text,p_amount bigint,
 p_source uuid,p_revision bigint,p_reason text,p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare a billing.account_credit_applications%rowtype;c billing.account_credits%rowtype;i billing.invoices%rowtype;
 actor uuid:=auth.uid();req jsonb;r jsonb;e uuid:=gen_random_uuid();adj uuid:=gen_random_uuid();j uuid;
 b record;available numeric;review text;op text;cycles jsonb:='[]'::jsonb;
begin
 select * into strict a from billing.account_credit_applications where id=p_application;
 if actor is null or not coalesce(iam.has_well_permission(a.well_id,'session.correct'),false) then
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
create function billing.release_credit_application(p_application uuid,p_amount bigint,p_source uuid,p_revision bigint,
 p_reason text,p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select billing.adjust_credit_application(p_application,'release',p_amount,p_source,p_revision,p_reason,p_posted_at,p_origin_id);
$$;
create function billing.restore_credit_application(p_application uuid,p_amount bigint,p_source uuid,p_revision bigint,
 p_reason text,p_posted_at timestamptz,p_origin_id uuid default null) returns jsonb
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select billing.adjust_credit_application(p_application,'restore',p_amount,p_source,p_revision,p_reason,p_posted_at,p_origin_id);
$$;

create function billing.validate_application_adjustment_event(p_event billing.customer_credit_events) returns void
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare a billing.account_credit_application_adjustments%rowtype;app billing.account_credit_applications%rowtype;
 c billing.account_credits%rowtype;amount numeric;debit_account text;credit_account text;
begin
 select * into strict a from billing.account_credit_application_adjustments where event_id=p_event.id;
 select * into strict app from billing.account_credit_applications where id=a.application_id;
 select * into strict c from billing.account_credits where id=app.credit_id;
 if p_event.operation is distinct from 'application_'||a.operation or p_event.request_payload is distinct from a.request_payload
  or p_event.source_id is distinct from a.source_id or p_event.origin_source_id is distinct from a.origin_source_id
  or p_event.source_revision is distinct from a.source_revision or p_event.tenant_id is distinct from a.tenant_id
  or p_event.well_id is distinct from a.well_id or p_event.farmer_well_account_id is distinct from a.farmer_well_account_id
  or p_event.reason is distinct from a.reason or p_event.created_by is distinct from a.created_by
  or p_event.journal_entry_id is distinct from a.journal_entry_id
  or p_event.result_payload->>'adjustment_id' is distinct from a.id::text
  or p_event.result_payload->>'status' is distinct from a.status
  or p_event.result_payload->>'event_id' is distinct from p_event.id::text
  or p_event.result_payload->>'application_id' is distinct from app.id::text
  or p_event.result_payload->>'credit_id' is distinct from c.id::text
  or p_event.result_payload->>'invoice_id' is distinct from app.invoice_id::text
  or p_event.result_payload->>'operation' is distinct from a.operation
  or p_event.result_payload->>'requested_minor' is distinct from a.amount_minor::text
  or p_event.result_payload->>'applied_minor' is distinct from
   (case when a.status='accepted' then a.amount_minor else 0 end)::text
  or p_event.result_payload->>'reason' is distinct from a.review_reason
  or a.request_payload->>'application_id' is distinct from app.id::text
  or a.request_payload->>'amount_minor' is distinct from a.amount_minor::text
  or (select effective_amount_minor from billing.effective_account_credit_applications where id=app.id) not between 0 and app.amount_minor
  or (select available_minor from billing.account_credit_balances where id=c.id)<0
  or (select available_minor from billing.payment_available_balances where payment_id=c.payment_id)<0 then
  raise exception 'application_adjustment_event_inconsistent' using errcode='23514';end if;
 if a.status='accepted' then
  if not exists(select 1 from finance.journal_entries j where j.id=a.journal_entry_id and j.status='posted'
   and j.tenant_id=a.tenant_id and j.well_id=a.well_id and j.source_type='customer_credit' and j.source_id=p_event.id) then
   raise exception 'application_adjustment_posting_missing' using errcode='23514';end if;
  debit_account:=case when a.operation='release' then '1100' else '2000' end;
  credit_account:=case when a.operation='release' then '2000' else '1100' end;
  if (select count(*) from finance.journal_lines where journal_entry_id=a.journal_entry_id)<>2
   or not exists(select 1 from finance.journal_lines l where l.journal_entry_id=a.journal_entry_id
    and l.ledger_account_id=finance.ledger_account_id(a.well_id,debit_account) and l.entry_side='debit'
    and l.amount_minor=a.amount_minor and l.cashbox_id is null and l.farmer_well_account_id=a.farmer_well_account_id)
   or not exists(select 1 from finance.journal_lines l where l.journal_entry_id=a.journal_entry_id
    and l.ledger_account_id=finance.ledger_account_id(a.well_id,credit_account) and l.entry_side='credit'
    and l.amount_minor=a.amount_minor and l.cashbox_id is null and l.farmer_well_account_id=a.farmer_well_account_id) then
   raise exception 'application_adjustment_posting_inconsistent' using errcode='23514';end if;
 elsif a.journal_entry_id is not null then
  raise exception 'application_review_has_posting' using errcode='23514';
 end if;
end;$$;
create function billing.check_application_adjustment_link() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare e billing.customer_credit_events%rowtype;
begin
 select * into strict e from billing.customer_credit_events where id=new.event_id;
 perform billing.validate_application_adjustment_event(e);
 return null;
end;$$;
create constraint trigger application_adjustment_event_integrity
 after insert on billing.account_credit_application_adjustments deferrable initially deferred
 for each row execute function billing.check_application_adjustment_link();
revoke all on function billing.lock_customer_credit_well(uuid),
 billing.guard_credit_application_adjustment(),billing.refresh_application_adjusted_invoice(),
 billing.adjust_credit_application(uuid,text,bigint,uuid,bigint,text,timestamptz,uuid),
 billing.release_credit_application(uuid,bigint,uuid,bigint,text,timestamptz,uuid),
 billing.restore_credit_application(uuid,bigint,uuid,bigint,text,timestamptz,uuid),
 billing.validate_application_adjustment_event(billing.customer_credit_events),billing.check_application_adjustment_link()
 from public,anon,authenticated,service_role;

-- فرع إضافي فقط؛ سائر تحقق C0 التاريخي محفوظ حرفيًا.
create or replace function billing.check_customer_credit_event() returns trigger language plpgsql security definer
set search_path=pg_catalog,pg_temp as $$
declare c billing.account_credits%rowtype;a billing.payment_allocation_adjustments%rowtype;
 app billing.account_credit_applications%rowtype;rev billing.account_credit_reversals%rowtype;
 expected_amount bigint;payment uuid;
begin
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
commit;

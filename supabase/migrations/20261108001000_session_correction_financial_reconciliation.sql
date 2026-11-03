begin;
-- R6-C2 only. Original monetary evidence and C1 operational acceptance stay
-- immutable. Private reconciliation publishes financial children atomically.
alter table ops.session_correction_reconciliations
 add column financial_applied_revision bigint,
 add column last_reconciliation_command_id uuid,
 add column last_financial_request jsonb,
 add column last_financial_result jsonb,
 add constraint session_correction_financial_revision_check check(
  (status='applied' and financial_applied_revision is not null and financial_applied_revision=operational_revision)
  or (status<>'applied' and financial_applied_revision is null));

create table billing.session_charge_corrections (
 correction_id uuid primary key references ops.session_correction_reconciliations(correction_id),
 tenant_id uuid not null references core.tenants(id),well_id uuid not null references core.wells(id),
 session_id uuid not null references ops.irrigation_sessions(id),
 session_charge_id uuid not null references billing.session_charges(id),
 operational_revision bigint not null,
 previous_financial_revision bigint not null check(previous_financial_revision>=0),
 old_amount_minor bigint not null check(old_amount_minor>=0),
 new_amount_minor bigint not null check(new_amount_minor>=0),
 delta_minor bigint not null check(delta_minor=new_amount_minor-old_amount_minor),
 billable_seconds bigint not null check(billable_seconds>0 and billable_seconds<=2147483647),
 weighted_rate_minor bigint not null check(weighted_rate_minor>0),
 effective_started_at timestamptz not null,effective_ended_at timestamptz not null,
 pricing_evidence jsonb not null check(jsonb_typeof(pricing_evidence)='object'),
 reconciliation_command_id uuid not null,source_id uuid not null unique,
 posted_at timestamptz not null check(isfinite(posted_at)),
 accepted_at timestamptz not null default clock_timestamp(),created_at timestamptz not null default clock_timestamp(),
 unique(session_id,operational_revision),unique(tenant_id,reconciliation_command_id),
 check(operational_revision=previous_financial_revision+1),
 foreign key(correction_id,session_id,operational_revision)
  references ops.session_corrections(id,session_id,new_revision)
);
create table billing.invoice_corrections (
 correction_id uuid primary key references billing.session_charge_corrections(correction_id),
 tenant_id uuid not null references core.tenants(id),well_id uuid not null references core.wells(id),
 session_id uuid not null references ops.irrigation_sessions(id),
 session_charge_id uuid not null references billing.session_charges(id),invoice_id uuid not null references billing.invoices(id),
 operational_revision bigint not null,previous_financial_revision bigint not null,
 old_amount_minor bigint not null check(old_amount_minor>=0),new_amount_minor bigint not null check(new_amount_minor>=0),
 delta_minor bigint not null check(delta_minor=new_amount_minor-old_amount_minor),
 pricing_evidence jsonb not null,reconciliation_command_id uuid not null,source_id uuid not null unique,
 journal_entry_id uuid references finance.journal_entries(id),
 posted_at timestamptz not null check(isfinite(posted_at)),
 accepted_at timestamptz not null default clock_timestamp(),created_at timestamptz not null default clock_timestamp(),
 unique(invoice_id,operational_revision),check(operational_revision=previous_financial_revision+1)
);
create index session_charge_correction_scope_idx on billing.session_charge_corrections(well_id,session_charge_id,operational_revision);
create index invoice_correction_scope_idx on billing.invoice_corrections(invoice_id,operational_revision);
alter table billing.session_charge_corrections enable row level security;
alter table billing.invoice_corrections enable row level security;
revoke all on billing.session_charge_corrections,billing.invoice_corrections from public,anon,authenticated,service_role;

create view billing.effective_session_charges with(security_invoker=true) as
select ch.id,ch.session_id,ch.well_id,
 coalesce(h.billable_seconds,ch.duration_seconds::bigint)::integer as duration_seconds,
 coalesce(h.weighted_rate_minor,ch.price_per_hour_minor) as price_per_hour_minor,
 coalesce(h.new_amount_minor,ch.amount_minor) as amount_minor,ch.pricing_mode,
 coalesce(h.operational_revision,0::bigint) as financial_applied_revision,
 coalesce(h.effective_started_at,s.started_at) as effective_started_at,
 coalesce(h.effective_ended_at,s.ended_at) as effective_ended_at,h.pricing_evidence
from billing.session_charges ch join ops.irrigation_sessions s on s.id=ch.session_id
left join lateral(select x.* from billing.session_charge_corrections x where x.session_charge_id=ch.id
 order by x.operational_revision desc limit 1)h on true;

create view billing.effective_invoice_totals with(security_invoker=true) as
select i.id,i.tenant_id,i.well_id,i.farmer_well_account_id,i.session_id,i.status,
 (i.total_minor::numeric+coalesce(h.delta,0))::bigint as total_minor
from billing.invoices i left join lateral(select sum(delta_minor) as delta from billing.invoice_corrections x where x.invoice_id=i.id)h on true;

-- C0 counters are caches, not invoice evidence. Preserve total/subtotal/lines;
-- their original CHECK must now compare counters with the derived effective sum.
alter table billing.invoices add column correction_total_delta_minor bigint not null default 0,
 add column session_financial_revision bigint not null default 0 check(session_financial_revision>=0);
alter table billing.invoices drop constraint invoices_check;
alter table billing.invoices add constraint invoices_effective_counter_check
 check(paid_minor::numeric+outstanding_minor=total_minor::numeric+correction_total_delta_minor),
 add constraint invoices_effective_total_nonnegative check(total_minor::numeric+correction_total_delta_minor>=0);

create function billing.guard_correction_invoice_cache() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare expected bigint;
begin
 -- Writers acquire the financial well lock BEFORE row locks. This integrity
 -- trigger must not add a row -> advisory-lock inversion for metadata updates.
 if TG_OP='INSERT' then
  if new.correction_total_delta_minor<>0 then raise exception 'invoice_correction_cache_private' using errcode='23514';end if;
  select financial_applied_revision into new.session_financial_revision from billing.effective_session_charges where session_id=new.session_id;
  new.session_financial_revision:=coalesce(new.session_financial_revision,0);
 else
  select coalesce(sum(delta_minor),0)::bigint into expected from billing.invoice_corrections where invoice_id=old.id;
  if new.correction_total_delta_minor<>expected or new.session_financial_revision<>old.session_financial_revision
    or (exists(select 1 from billing.invoice_corrections where invoice_id=old.id)
      and (new.total_minor,new.subtotal_minor) is distinct from (old.total_minor,old.subtotal_minor)) then
   raise exception 'invoice_correction_evidence_immutable' using errcode='23514';end if;
 end if;return new;
end;$$;
create trigger invoice_correction_cache_private before insert or update on billing.invoices
 for each row execute function billing.guard_correction_invoice_cache();

create function billing.reject_session_financial_history_mutation() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin raise exception 'session_financial_history_immutable' using errcode='23514';end;$$;
create trigger session_charge_correction_immutable before update or delete on billing.session_charge_corrections
 for each row execute function billing.reject_session_financial_history_mutation();
create trigger invoice_correction_immutable before update or delete on billing.invoice_corrections
 for each row execute function billing.reject_session_financial_history_mutation();

create function billing.validate_session_financial_correction(p_correction uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare h billing.session_charge_corrections%rowtype;v billing.invoice_corrections%rowtype;
 c ops.session_corrections%rowtype;prior bigint;
begin
 select * into strict h from billing.session_charge_corrections where correction_id=p_correction;
 select * into strict c from ops.session_corrections where id=p_correction;
 if (h.tenant_id,h.well_id,h.session_id,h.operational_revision,h.effective_started_at,h.effective_ended_at)
    is distinct from(c.tenant_id,c.well_id,c.session_id,c.new_revision,c.after_started_at,c.after_ended_at)
   or not exists(select 1 from billing.session_charges b where b.id=h.session_charge_id and b.session_id=c.session_id and b.well_id=c.well_id)
   or not exists(select 1 from ops.session_correction_reconciliations r where r.correction_id=c.id
    and r.status='applied' and r.financial_applied_revision=c.new_revision
    and r.last_reconciliation_command_id=h.reconciliation_command_id) then
  raise exception 'session_financial_history_scope_invalid' using errcode='23514';end if;
 if h.previous_financial_revision=0 then
  select amount_minor into prior from billing.session_charges where id=h.session_charge_id;
 else
  select new_amount_minor into prior from billing.session_charge_corrections
   where session_charge_id=h.session_charge_id and operational_revision=h.previous_financial_revision;
 end if;
 if prior is distinct from h.old_amount_minor then
  raise exception 'session_financial_history_chain_invalid' using errcode='23514';end if;
 select * into v from billing.invoice_corrections where correction_id=p_correction;
 if found then
  if (v.tenant_id,v.well_id,v.session_id,v.session_charge_id,v.operational_revision,v.previous_financial_revision,
      v.old_amount_minor,v.new_amount_minor,v.pricing_evidence,v.reconciliation_command_id)
    is distinct from(h.tenant_id,h.well_id,h.session_id,h.session_charge_id,h.operational_revision,h.previous_financial_revision,
      h.old_amount_minor,h.new_amount_minor,h.pricing_evidence,h.reconciliation_command_id)
   or not exists(select 1 from billing.invoices i where i.id=v.invoice_id and i.session_id=c.session_id
     and i.tenant_id=c.tenant_id and i.well_id=c.well_id)
   or (v.delta_minor<>0 and not exists(select 1 from finance.journal_entries j where j.id=v.journal_entry_id
     and j.source_type='session_correction' and j.source_id=c.id and j.well_id=c.well_id and j.status='posted')) then
   raise exception 'invoice_financial_history_scope_invalid' using errcode='23514';end if;
 end if;
end;$$;
create function billing.check_session_financial_correction() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin perform billing.validate_session_financial_correction(new.correction_id);return null;end;$$;
create constraint trigger session_charge_correction_complete after insert on billing.session_charge_corrections
 deferrable initially deferred for each row execute function billing.check_session_financial_correction();
create constraint trigger invoice_correction_complete after insert on billing.invoice_corrections
 deferrable initially deferred for each row execute function billing.check_session_financial_correction();

-- Pure derivation for a SPECIFIC accepted operational revision, not the latest
-- operational head. No query of current prices or mutable historical schedules.
create function billing.derive_session_correction_charge(p_correction uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c ops.session_corrections%rowtype;s ops.irrigation_sessions%rowtype;ch billing.session_charges%rowtype;
 seg record;first_start timestamptz;last_end timestamptz;prior_end timestamptz;st timestamptz;en timestamptz;
 seconds bigint;billable bigint;rate bigint;amount bigint;total numeric:=0;duration numeric:=0;weighted numeric:=0;
 original_total numeric:=0;segments jsonb:='[]';n bigint:=0;segment_count bigint;
begin
 select * into strict c from ops.session_corrections where id=p_correction;
 select * into strict s from ops.irrigation_sessions where id=c.session_id;
 select * into ch from billing.session_charges where session_id=c.session_id;
 if not found or ch.well_id<>c.well_id or ch.pricing_mode<>'segments' then
  raise exception 'original_charge_evidence_unproven' using errcode='P0C02';end if;
 select count(*) into segment_count from ops.session_segments where session_id=s.id;
 if segment_count=0 then raise exception 'segment_evidence_unproven' using errcode='P0C02';end if;
 for seg in select * from ops.session_segments where session_id=s.id order by sequence_number loop
  n:=n+1;
  if seg.tenant_id<>c.tenant_id or seg.sequence_number<>n or seg.ended_at is null
   or not isfinite(seg.started_at) or not isfinite(seg.ended_at) or seg.started_at>=seg.ended_at
   or (n=1 and seg.started_at<>s.started_at) or (n>1 and seg.started_at is distinct from prior_end)
   or (n=segment_count and seg.ended_at is distinct from s.ended_at) then
   raise exception 'segment_evidence_unproven' using errcode='P0C02';end if;
  prior_end:=seg.ended_at;
  st:=case when n=1 then c.after_started_at else seg.started_at end;
  en:=case when n=segment_count then c.after_ended_at else seg.ended_at end;
  if st>=en then raise exception 'effective_segment_invalid' using errcode='P0C02';end if;
  seconds:=extract(epoch from(en-st))::bigint;billable:=case when seg.is_billable then seconds else 0 end;
  rate:=coalesce(seg.applied_operation_rate_minor,seg.applied_hourly_rate_minor);
  if seg.is_billable and st is distinct from seg.started_at then
   raise exception 'historical_price_unproven' using errcode='P0C02',detail=seg.id::text;end if;
  if seg.is_billable and (rate is null or rate<=0 or seg.time_charge_minor::numeric<>
    trunc(extract(epoch from(seg.ended_at-seg.started_at))::bigint::numeric*rate/3600)) then
   raise exception 'historical_price_unproven' using errcode='P0C02';end if;
  if not seg.is_billable and seg.time_charge_minor<>0 then raise exception 'segment_evidence_unproven' using errcode='P0C02';end if;
  amount:=case when seg.is_billable then trunc(billable::numeric*rate/3600)::bigint else 0 end;
  total:=total+amount;duration:=duration+billable;weighted:=weighted+billable::numeric*coalesce(rate,0);
  original_total:=original_total+seg.time_charge_minor;
  segments:=segments||jsonb_build_array(jsonb_build_object('segment_id',seg.id,'sequence_number',seg.sequence_number,
   'segment_type',seg.segment_type,'energy_source',seg.energy_source,'effective_started_at',st,'effective_ended_at',en,
   'actual_seconds',seconds,'billable_seconds',billable,'rate_minor',rate,'time_charge_minor',amount,
   'original_price_rule_id',seg.applied_price_rule_id,'evidence','original_segment_event_snapshot'));
 end loop;
 if original_total<>ch.amount_minor or duration<=0 or duration>2147483647 or total>9223372036854775807 then
  raise exception 'canonical_charge_evidence_unproven' using errcode='P0C02';end if;
 return jsonb_build_object('amount_minor',total::bigint,'billable_seconds',duration::bigint,
  'weighted_rate_minor',round(weighted/duration)::bigint,'segments',segments,
  'correction_id',c.id,'operational_revision',c.new_revision,'original_charge_id',ch.id);
end;$$;

-- Invoice issuance reads the latest FINANCIALLY applied segment evidence. Fuel
-- quantities/transactions are never changed, and fuel is outside operation charge.
create view billing.financial_session_segments with(security_invoker=true) as
select ss.id,ss.session_id,ss.sequence_number,ss.segment_type,ss.energy_source,ss.is_billable,
 case when ch.financial_applied_revision>0 then (e.value->>'billable_seconds')::bigint else ss.billable_seconds end as billable_seconds,
 case when ch.financial_applied_revision>0 then (e.value->>'rate_minor')::bigint else ss.applied_hourly_rate_minor end as applied_hourly_rate_minor,
 case when ch.financial_applied_revision>0 then (e.value->>'rate_minor')::bigint else ss.applied_operation_rate_minor end as applied_operation_rate_minor,
 ss.applied_fuel_price_per_liter_minor,
 ss.fuel_actual_ml,ss.fuel_estimated_ml,
 case when ch.financial_applied_revision>0 then (e.value->>'time_charge_minor')::bigint else ss.time_charge_minor end as time_charge_minor,
 case when ch.financial_applied_revision>0 then 0::bigint else ss.fuel_charge_minor end as fuel_charge_minor,
 case when ch.financial_applied_revision>0 then (e.value->>'time_charge_minor')::bigint else ss.total_charge_minor end as total_charge_minor
from ops.session_segments ss join billing.effective_session_charges ch on ch.session_id=ss.session_id
left join lateral(select value from jsonb_array_elements(ch.pricing_evidence->'segments')
 where value->>'segment_id'=ss.id::text)e on true;

-- C0-compatible view replacements and invoice/payment consumers follow below.
-- These definitions retain existing signatures, privileges and payment partition
-- policy. Only the authoritative debt input and derived counters are replaced.
create or replace view billing.invoice_explicit_settlements with(security_invoker=true) as
select i.id as invoice_id,i.tenant_id,i.well_id,i.farmer_well_account_id,i.session_id,tot.total_minor,i.status,
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
from billing.invoices i join billing.effective_invoice_totals tot on tot.id=i.id
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

create or replace view billing.default_session_debts with(security_invoker=true) as
select sc.id as session_charge_id,sc.session_id,sc.well_id,scope.farmer_well_account_id,
 coalesce(i.total_minor,sc.amount_minor) as debt_minor,coalesce(i.settled_minor,0) as explicitly_settled_minor,
 greatest(coalesce(i.total_minor,sc.amount_minor)-coalesce(i.settled_minor,0),0) as remaining_before_direct_minor,
 s.well_id=sc.well_id and scope.account_count<=1
 and coalesce(i.invoice_count,0)<=1 and coalesce(i.scope_valid,true) as scope_valid
from billing.effective_session_charges sc join ops.irrigation_sessions s on s.id=sc.session_id
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

create or replace view billing.invoice_effective_balances with(security_invoker=true) as
select i.id as invoice_id,i.well_id,i.tenant_id,i.farmer_well_account_id,x.total_minor,
 billing.require_valid_payment_partition(x.scope_valid,x.explicitly_settled_minor+coalesce(d.direct_settled_minor,0)) as paid_minor,
 billing.require_valid_payment_partition(x.scope_valid,x.total_minor-x.explicitly_settled_minor-coalesce(d.direct_settled_minor,0)) as outstanding_minor
from billing.invoices i join billing.invoice_explicit_settlements x on x.invoice_id=i.id
left join billing.session_economic_settlements d on d.session_id=i.session_id and i.status not in ('draft','cancelled','reversed');

create or replace view reporting.farmer_account_balances with(security_invoker=true) as
select a.tenant_id,a.well_id,a.id as farmer_well_account_id,a.public_code,
 coalesce(i.total_minor,0) as invoiced_minor,coalesce(i.paid_minor,0)+coalesce(d.paid_minor,0) as allocated_minor,
 coalesce(p.available_minor,0) as advance_minor,coalesce(i.debt_minor,0)+coalesce(d.debt_minor,0) as debt_minor,
 coalesce(c.available_minor,0) as noncash_credit_minor,
 coalesce(p.available_minor,0)+coalesce(c.available_minor,0)+coalesce(r.available_minor,0) as available_credit_minor,
 coalesce(d.total_minor,0) as uninvoiced_charge_minor,coalesce(r.available_minor,0) as unapplied_payment_minor
from ops.farmer_well_accounts a
left join(select i.farmer_well_account_id,sum(b.total_minor) as total_minor,sum(b.paid_minor) as paid_minor,
 sum(b.outstanding_minor) as debt_minor from billing.invoices i join billing.invoice_effective_balances b on b.invoice_id=i.id
 where i.status not in ('draft','cancelled','reversed') group by 1)i on i.farmer_well_account_id=a.id
left join(select d.farmer_well_account_id,sum(d.debt_minor) as total_minor,sum(d.settled_minor) as paid_minor,
 sum(d.outstanding_minor) as debt_minor from billing.session_economic_settlements d
 where not exists(select 1 from billing.invoices i where i.session_id=d.session_id and i.status not in ('draft','cancelled','reversed'))
 group by 1)d on d.farmer_well_account_id=a.id
left join(select farmer_well_account_id,sum(remaining_minor) as available_minor from billing.payment_economic_applications
 where purpose='advance' group by 1)p on p.farmer_well_account_id=a.id
left join(select farmer_well_account_id,sum(remaining_minor) as available_minor from billing.payment_economic_applications
 where purpose<>'advance' group by 1)r on r.farmer_well_account_id=a.id
left join(select farmer_well_account_id,sum(available_minor) as available_minor from billing.account_credit_balances group by 1)c on c.farmer_well_account_id=a.id;

create or replace function billing.refresh_effective_invoice(p_invoice uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare b record;s text;
begin
 select status into s from billing.invoices where id=p_invoice for update;
 select * into strict b from billing.invoice_effective_balances where invoice_id=p_invoice;
 if b.paid_minor<0 or b.outstanding_minor<0 then
  raise exception 'effective_invoice_allocation_out_of_range' using errcode='23514';end if;
 update billing.invoices set correction_total_delta_minor=b.total_minor-(select total_minor from billing.invoices where id=p_invoice),
 paid_minor=b.paid_minor,outstanding_minor=b.outstanding_minor,
 status=case when s in ('draft','cancelled','reversed') then s when b.outstanding_minor=0 then 'paid'
  when b.paid_minor>0 then 'partially_paid' when s='overdue' then s else 'issued' end where id=p_invoice;
end;$$;

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
  -- 1) صلاحية المستخدم والدور.
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل الدفعة';
  end if;
  if not iam.has_well_permission(p_well_id, 'payment.create') then
    raise exception 'لا تملك صلاحية تسجيل دفعة لهذا البئر';
  end if;

  perform billing.lock_customer_credit_well(p_well_id);

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

create function billing.post_session_correction_delta(p_correction uuid,p_invoice uuid,p_evidence jsonb,p_previous jsonb,
 p_posted_at timestamptz) returns uuid language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c ops.session_corrections%rowtype;i billing.invoices%rowtype;j uuid;x record;delta bigint;
begin
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

create function billing.reconcile_session_correction(p_correction uuid,p_command_id uuid,p_posted_at timestamptz)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c ops.session_corrections%rowtype;work ops.session_correction_reconciliations%rowtype;
 s ops.irrigation_sessions%rowtype;ch billing.effective_session_charges%rowtype;i billing.invoices%rowtype;
 actor uuid:=auth.uid();pc sync.processed_commands%rowtype;req jsonb;guard jsonb;result jsonb;evidence jsonb;previous jsonb;
 x record;child jsonb;children jsonb:='[]';source uuid;account uuid;j uuid;new_amount bigint;old_invoice bigint;
 excess numeric;take bigint;invoice_count bigint;code text;error_detail text;errstate text;event billing.customer_credit_events%rowtype;
begin
 select * into c from ops.session_corrections where id=p_correction;
 if actor is null or not found or not exists(select 1 from core.well_assignments a where a.well_id=c.well_id
   and a.profile_id=actor and a.status='active') or not coalesce(iam.has_well_permission(c.well_id,'session.correct'),false) then
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
   or not coalesce(iam.has_well_permission(c.well_id,'session.correct'),false) then
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
   if i.deducted_in_cycle_id is not null and new_amount<>ch.amount_minor then
    raise exception 'approved_distribution_reconciliation_required' using errcode='P0C02';end if;
   select greatest(explicitly_settled_minor-new_amount,0) into excess from billing.invoice_explicit_settlements where invoice_id=i.id;
   -- Release explicit excess BEFORE debt publication so C0 refreshes never see
   -- a transient negative invoice balance. Its default destination may recover
   -- the released value; after publication C0.2 rebalances the remaining capacity.
   for x in select a.* from billing.effective_account_credit_applications a
     where a.invoice_id=i.id and a.effective_amount_minor>0 order by a.created_at desc,a.id loop
    exit when excess<=0;take:=least(excess,x.effective_amount_minor)::bigint;
    source:=md5(c.id::text||':application_release:'||x.id::text)::uuid;
    child:=billing.release_credit_application(x.id,take,source,c.new_revision,c.reason,p_posted_at,c.id);
    if child->>'status' is distinct from 'accepted' then
     raise exception 'credit_application_release_requires_review' using errcode='P0C02',detail=child::text;end if;
    children:=children||jsonb_build_array(child);excess:=excess-take;
   end loop;
   for x in select a.* from billing.effective_payment_allocations a join billing.payments p on p.id=a.payment_id
     where a.invoice_id=i.id and p.status='posted' and a.effective_allocated_minor>0 order by a.id loop
    exit when excess<=0;take:=least(excess,x.effective_allocated_minor)::bigint;
    source:=md5(c.id::text||':allocation_release:'||x.id::text)::uuid;
    child:=billing.release_payment_allocation(x.id,take,source,c.new_revision,c.reason,p_posted_at,c.id);
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
   j:=billing.post_session_correction_delta(c.id,i.id,evidence,previous,p_posted_at);
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
     child:=billing.rebalance_payment_capacity(x.id,source,c.new_revision,c.reason,p_posted_at,c.id);
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

-- Internal financial projection must remain readable by existing INVOKER debt
-- consumers. SELECT follows the ORIGINAL charge/invoice RLS scope; no new DML.
create policy session_charge_correction_read on billing.session_charge_corrections for select to authenticated
 using(exists(select 1 from billing.session_charges ch where ch.id=session_charge_corrections.session_charge_id
  and ch.session_id=session_charge_corrections.session_id and ch.well_id=session_charge_corrections.well_id));
create policy invoice_correction_read on billing.invoice_corrections for select to authenticated
 using(exists(select 1 from billing.invoices i where i.id=invoice_corrections.invoice_id
  and i.session_id=invoice_corrections.session_id and i.well_id=invoice_corrections.well_id and i.tenant_id=invoice_corrections.tenant_id));
grant select on billing.session_charge_corrections,billing.invoice_corrections to authenticated,service_role;
revoke all on billing.effective_session_charges,billing.effective_invoice_totals,billing.financial_session_segments
 from public,anon,authenticated,service_role;
grant select on billing.effective_session_charges,billing.effective_invoice_totals to authenticated,service_role;
revoke all on function billing.guard_correction_invoice_cache(),billing.reject_session_financial_history_mutation(),
 billing.validate_session_financial_correction(uuid),billing.check_session_financial_correction(),
 billing.derive_session_correction_charge(uuid),billing.post_session_correction_delta(uuid,uuid,jsonb,jsonb,timestamptz),
 billing.reconcile_session_correction(uuid,uuid,timestamptz) from public,anon,authenticated,service_role;
commit;

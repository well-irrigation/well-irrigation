begin;
-- Independent manual approval; C2 operational/system revisions keep their meaning.
insert into iam.permissions(code,description_ar) values('session.financial_adjust','اعتماد مبلغ جلسة سقي') on conflict do nothing;
insert into iam.role_permissions(role_id,permission_id)
select r.id,p.id from iam.roles r cross join iam.permissions p
where r.code in('operator','well_manager','tenant_owner') and p.code='session.financial_adjust' on conflict do nothing;
create table billing.session_financial_adjustments(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references core.tenants,
 well_id uuid not null references core.wells,session_id uuid not null references ops.irrigation_sessions,
 session_charge_id uuid not null references billing.session_charges,command_id uuid not null,
 manual_approval_revision bigint not null check(manual_approval_revision>0),
 base_manual_approval_revision bigint not null check(base_manual_approval_revision>=0),
 base_system_financial_revision bigint not null check(base_system_financial_revision>=0),
 base_operational_revision bigint not null check(base_operational_revision>=0),
 applied_system_financial_revision bigint not null check(applied_system_financial_revision>=0),
 system_snapshot_minor bigint not null check(system_snapshot_minor>=0),
 previous_effective_minor bigint not null check(previous_effective_minor>=0),
 approved_amount_minor bigint not null check(approved_amount_minor>=0),delta_minor bigint not null,
 actor_id uuid not null references iam.profiles,reason text not null check(nullif(btrim(reason),'') is not null),
 requested_at timestamptz not null check(isfinite(requested_at)),
 accepted_at timestamptz not null check(isfinite(accepted_at)),
 created_at timestamptz not null default clock_timestamp() check(isfinite(created_at)),posted_at timestamptz not null check(isfinite(posted_at)),
 status text not null default 'accepted' check(status='accepted'),
 unique(tenant_id,command_id),unique(session_id,manual_approval_revision),
 check(manual_approval_revision::numeric=base_manual_approval_revision::numeric+1),
 check(delta_minor::numeric=approved_amount_minor::numeric-previous_effective_minor::numeric),
 check(applied_system_financial_revision>=base_system_financial_revision),
 check(applied_system_financial_revision=base_operational_revision)
);
create table billing.invoice_financial_adjustments(
 adjustment_id uuid primary key references billing.session_financial_adjustments,
 invoice_id uuid not null references billing.invoices,journal_entry_id uuid references finance.journal_entries,
 delta_minor bigint not null,unique(invoice_id,adjustment_id)
);
create table billing.session_financial_resolution_links(
 correction_id uuid primary key references billing.session_charge_corrections,
 adjustment_id uuid not null references billing.session_financial_adjustments
);
create table billing.session_invoice_financial_snapshots(
 invoice_id uuid primary key references billing.invoices,session_id uuid not null references ops.irrigation_sessions,
 system_financial_revision bigint not null,manual_approval_revision bigint not null,
 system_amount_minor bigint not null check(system_amount_minor>=0),effective_amount_minor bigint not null check(effective_amount_minor>0),
 carry_in_minor bigint not null,check(carry_in_minor::numeric=effective_amount_minor::numeric-system_amount_minor::numeric)
);
create function billing.reject_manual_financial_history_change() returns trigger language plpgsql set search_path=pg_catalog,pg_temp as $$
begin raise exception 'manual_financial_history_immutable' using errcode='23514';end;$$;
create trigger manual_approval_immutable before update or delete on billing.session_financial_adjustments for each row execute function billing.reject_manual_financial_history_change();
create trigger manual_invoice_adjustment_immutable before update or delete on billing.invoice_financial_adjustments for each row execute function billing.reject_manual_financial_history_change();
create trigger manual_resolution_link_immutable before update or delete on billing.session_financial_resolution_links for each row execute function billing.reject_manual_financial_history_change();
create trigger manual_invoice_snapshot_immutable before update or delete on billing.session_invoice_financial_snapshots for each row execute function billing.reject_manual_financial_history_change();
create index manual_approval_charge_revision_idx on billing.session_financial_adjustments(session_charge_id,manual_approval_revision desc);
create index manual_resolution_approval_idx on billing.session_financial_resolution_links(adjustment_id);
-- Same C2 projection columns, composed without a redundant original-charge join.
-- No pricing calculation or source mutation is introduced here.
create view billing.approved_session_charges with(security_invoker=true) as
select ch.id,ch.session_id,ch.well_id,
 coalesce(h.billable_seconds,ch.duration_seconds::bigint)::integer as duration_seconds,
 coalesce(h.weighted_rate_minor,ch.price_per_hour_minor) as price_per_hour_minor,
 coalesce(a.approved_amount_minor,h.new_amount_minor,ch.amount_minor) as amount_minor,ch.pricing_mode,
 coalesce(h.operational_revision,0::bigint) as financial_applied_revision,
 coalesce(h.effective_started_at,s.started_at) as effective_started_at,
 coalesce(h.effective_ended_at,s.ended_at) as effective_ended_at,h.pricing_evidence,
 ch.amount_minor as original_amount_minor,coalesce(h.new_amount_minor,ch.amount_minor) as system_amount_minor,
 a.approved_amount_minor,coalesce(a.manual_approval_revision,0::bigint) as manual_approval_revision
from billing.session_charges ch join ops.irrigation_sessions s on s.id=ch.session_id
left join lateral(select x.* from billing.session_charge_corrections x where x.session_charge_id=ch.id
 order by x.operational_revision desc limit 1)h on true
left join lateral(select x.* from billing.session_financial_adjustments x where x.session_charge_id=ch.id
 order by x.manual_approval_revision desc limit 1)a on true;
create or replace view billing.effective_invoice_totals with(security_invoker=true) as
select i.id,i.tenant_id,i.well_id,i.farmer_well_account_id,i.session_id,i.status,
 (i.total_minor::numeric+coalesce(h.delta,0)+coalesce(m.delta,0))::bigint as total_minor
from billing.invoices i left join lateral(select sum(delta_minor) as delta from billing.invoice_corrections x where x.invoice_id=i.id)h on true
left join lateral(select sum(delta_minor) as delta from billing.invoice_financial_adjustments x where x.invoice_id=i.id)m on true;
create or replace view billing.default_session_debts with(security_invoker=true) as
select sc.id as session_charge_id,sc.session_id,sc.well_id,scope.farmer_well_account_id,
 coalesce(i.total_minor,sc.amount_minor) as debt_minor,coalesce(i.settled_minor,0) as explicitly_settled_minor,
 greatest(coalesce(i.total_minor,sc.amount_minor)-coalesce(i.settled_minor,0),0) as remaining_before_direct_minor,
 s.well_id=sc.well_id and scope.account_count<=1
 and coalesce(i.invoice_count,0)<=1 and coalesce(i.scope_valid,true) as scope_valid
from billing.approved_session_charges sc join ops.irrigation_sessions s on s.id=sc.session_id
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
create or replace function billing.guard_correction_invoice_cache() returns trigger
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
  select (coalesce((select sum(delta_minor) from billing.invoice_corrections where invoice_id=old.id),0)+coalesce((select sum(delta_minor) from billing.invoice_financial_adjustments where invoice_id=old.id),0))::bigint into expected;
  if new.correction_total_delta_minor<>expected or new.session_financial_revision<>old.session_financial_revision
    or ((exists(select 1 from billing.invoice_corrections where invoice_id=old.id) or exists(select 1 from billing.invoice_financial_adjustments where invoice_id=old.id))
      and (new.total_minor,new.subtotal_minor) is distinct from (old.total_minor,old.subtotal_minor)) then
   raise exception 'invoice_correction_evidence_immutable' using errcode='23514';end if;
 end if;return new;
end;$$;

-- All access is scoped by the session's canonical well, never a client actor.
-- Materialize each effective balance once before comparing cache fields.
-- This preserves the existing lock order and every status/cache predicate;
-- expanding the balance view repeatedly inside SQL OR predicates is expensive.
create or replace function billing.refresh_partition_invoices(p_well uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare inv record;b record;begin
 perform billing.require_customer_credit_well_lock(p_well);
 for inv in select id,paid_minor,outstanding_minor,status from billing.invoices
  where well_id=p_well and status not in('draft','cancelled','reversed') order by id for update loop
  select * into b from billing.invoice_effective_balances where invoice_id=inv.id;
  if found then
   if (inv.paid_minor,inv.outstanding_minor) is distinct from(b.paid_minor,b.outstanding_minor)
    or (b.outstanding_minor=0 and inv.status<>'paid')
    or (b.outstanding_minor>0 and b.paid_minor>0 and inv.status<>'partially_paid')
    or (b.paid_minor=0 and inv.status in('paid','partially_paid')) then
    perform billing.refresh_effective_invoice(inv.id);
   end if;
  end if;
 end loop;
end;$$;
create function billing.manual_financial_session_scope(p_session uuid) returns uuid
language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $$
declare w uuid;begin
 if auth.uid() is null then raise exception 'authentication_required' using errcode='28000';end if;
 select s.well_id into w from ops.irrigation_sessions s where s.id=p_session;
 if w is null or not exists(select 1 from core.well_assignments a where a.well_id=w and a.profile_id=auth.uid() and a.status='active')
 or not coalesce(iam.has_well_permission(w,'session.financial_adjust'),false) then
 raise exception 'financial_adjustment_forbidden' using errcode='42501';end if;return w;end;$$;

create function billing.manual_financial_posting_context(p_well uuid) returns timestamptz
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare posted timestamptz:=clock_timestamp();day date;begin
 perform billing.require_customer_credit_well_lock(p_well);
 day:=posted::date;
 -- Existing C2 requires an explicit open monthly AND yearly context; no implicit reopen.
 perform 1 from finance.accounting_periods ap where ap.well_id=p_well and day between starts_at and ends_at order by id for share;
 if (select count(distinct period_type) from finance.accounting_periods ap where ap.well_id=p_well
 and day between starts_at and ends_at and status in('open','reopened'))<>2
 or exists(select 1 from finance.accounting_periods ap where ap.well_id=p_well and day between starts_at and ends_at and status not in('open','reopened')) then
 raise exception 'posting_context_unavailable' using errcode='P0FA1';end if;
 return posted;end;$$;

-- Record system calculation evidence only in an explicitly paired approval.
-- This private path neither posts a C2 invoice delta nor changes its validators.
create function billing.establish_paired_system_basis(p_correction uuid,p_approval uuid,p_posted timestamptz) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c ops.session_corrections%rowtype;a billing.session_financial_adjustments%rowtype;
 ch billing.effective_session_charges%rowtype;e jsonb;cmd uuid;req jsonb;guard jsonb;result jsonb;
begin
 select * into strict a from billing.session_financial_adjustments where id=p_approval;
 perform billing.require_customer_credit_well_lock(a.well_id);
 perform billing.manual_financial_session_scope(a.session_id);
 select * into strict c from ops.session_corrections where id=p_correction;
 if c.session_id<>a.session_id or c.well_id<>a.well_id or c.tenant_id<>a.tenant_id
 or c.new_revision>a.applied_system_financial_revision then raise exception 'paired_scope_invalid' using errcode='23514';end if;
 select * into strict ch from billing.effective_session_charges where session_id=a.session_id;
 if ch.financial_applied_revision<>c.previous_revision then raise exception 'paired_system_sequence_invalid' using errcode='23514';end if;
 e:=billing.derive_session_correction_charge(c.id);
 cmd:=md5(a.command_id::text||':system:'||c.id::text)::uuid;
 req:=jsonb_build_object('contract','paired_session_system_basis','version',1,'correction_id',c.id,'approval_id',a.id,
  'session_id',a.session_id,'actor_id',auth.uid(),'posted_at',p_posted);
 guard:=sync.begin_command(a.tenant_id,cmd,'paired_session_system_basis',req,c.id);
 if coalesce((guard->>'duplicate')::boolean,false) then raise exception 'paired_command_collision' using errcode='23514';end if;
 update ops.session_correction_reconciliations set attempt_count=attempt_count+1,last_attempt_at=clock_timestamp(),
 last_reconciliation_command_id=cmd,last_financial_request=req where correction_id=c.id and status<>'applied';
 if not found then raise exception 'paired_work_already_applied' using errcode='23514';end if;
 insert into billing.session_charge_corrections(correction_id,tenant_id,well_id,session_id,session_charge_id,
 operational_revision,previous_financial_revision,old_amount_minor,new_amount_minor,delta_minor,billable_seconds,
 weighted_rate_minor,effective_started_at,effective_ended_at,pricing_evidence,reconciliation_command_id,source_id,posted_at)
 values(c.id,c.tenant_id,c.well_id,c.session_id,ch.id,c.new_revision,c.previous_revision,ch.amount_minor,
 (e->>'amount_minor')::bigint,(e->>'amount_minor')::bigint-ch.amount_minor,(e->>'billable_seconds')::bigint,
 (e->>'weighted_rate_minor')::bigint,c.after_started_at,c.after_ended_at,e,cmd,md5(cmd::text||':charge')::uuid,p_posted);
 insert into billing.session_financial_resolution_links(correction_id,adjustment_id) values(c.id,a.id);
 result:=jsonb_build_object('status','applied','correction_id',c.id,'session_id',c.session_id,
 'operational_revision',c.new_revision,'financial_applied_revision',c.new_revision,'paired_approval_id',a.id,
 'reconciliation_command_id',cmd);
 update ops.session_correction_reconciliations set status='applied',financial_applied_revision=c.new_revision,
 last_error=null,last_financial_result=result where correction_id=c.id;
 perform sync.finish_command(a.tenant_id,cmd,'accepted',result);
 perform billing.validate_session_financial_correction(c.id);
end;$$;

create function billing.validate_manual_financial_approval(p_id uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare a billing.session_financial_adjustments%rowtype;v billing.invoice_financial_adjustments%rowtype;
 prior bigint;sys bigint;x record;j finance.journal_entries%rowtype;iv uuid;
begin
 select * into strict a from billing.session_financial_adjustments where id=p_id;
 if not exists(select 1 from ops.irrigation_sessions s join core.wells w on w.id=s.well_id
 join billing.session_charges ch on ch.session_id=s.id where s.id=a.session_id and s.well_id=a.well_id
 and w.tenant_id=a.tenant_id and ch.id=a.session_charge_id and ch.well_id=a.well_id) then
 raise exception 'manual_financial_scope_invalid' using errcode='23514';end if;
 if a.base_manual_approval_revision>0 then
 select approved_amount_minor into prior from billing.session_financial_adjustments where session_id=a.session_id
 and manual_approval_revision=a.base_manual_approval_revision;
 elsif a.base_system_financial_revision>0 then
 select new_amount_minor into prior from billing.session_charge_corrections where session_id=a.session_id
 and operational_revision=a.base_system_financial_revision;
 else select amount_minor into prior from billing.session_charges where id=a.session_charge_id;end if;
 if prior is distinct from a.previous_effective_minor then raise exception 'manual_approval_chain_invalid' using errcode='23514';end if;
 if a.applied_system_financial_revision>0 then
 select new_amount_minor into sys from billing.session_charge_corrections where session_id=a.session_id
 and operational_revision=a.applied_system_financial_revision;
 else select amount_minor into sys from billing.session_charges where id=a.session_charge_id;end if;
 if sys is distinct from a.system_snapshot_minor then raise exception 'manual_system_basis_invalid' using errcode='23514';end if;
 if (select count(*) from billing.session_financial_resolution_links l join billing.session_charge_corrections c on c.correction_id=l.correction_id
 where l.adjustment_id=a.id and c.session_id=a.session_id and c.operational_revision>a.base_system_financial_revision
 and c.operational_revision<=a.applied_system_financial_revision)
 <>a.applied_system_financial_revision-a.base_system_financial_revision then
 raise exception 'paired_basis_coverage_invalid' using errcode='23514';end if;
 for x in select c.* from billing.session_financial_resolution_links l join billing.session_charge_corrections c on c.correction_id=l.correction_id
 where l.adjustment_id=a.id loop
  if x.session_id<>a.session_id or x.previous_financial_revision<a.base_system_financial_revision
  or x.operational_revision>a.applied_system_financial_revision or exists(select 1 from billing.invoice_corrections where correction_id=x.correction_id)
  or exists(select 1 from finance.journal_entries where source_type='session_correction' and source_id=x.correction_id) then
   raise exception 'paired_economic_double_publication' using errcode='23514';end if;
  perform billing.validate_session_financial_correction(x.correction_id);
 end loop;
 select * into v from billing.invoice_financial_adjustments where adjustment_id=a.id;
 if found then
  select i.id into iv from billing.invoices i where i.id=v.invoice_id and i.session_id=a.session_id
  and i.tenant_id=a.tenant_id and i.well_id=a.well_id;
  if iv is null or v.delta_minor<>a.delta_minor then raise exception 'manual_invoice_scope_invalid' using errcode='23514';end if;
  if a.delta_minor=0 then
   if v.journal_entry_id is not null then raise exception 'zero_adjustment_fake_journal' using errcode='23514';end if;
  else
   select * into j from finance.journal_entries where id=v.journal_entry_id;
   if j.id is null or j.status<>'posted' or j.source_type<>'session_financial_adjustment' or j.source_id<>a.id
   or j.well_id<>a.well_id or j.tenant_id<>a.tenant_id
   or (select count(*) from finance.journal_lines where journal_entry_id=j.id)<>2
   or not exists(select 1 from finance.journal_lines l where l.journal_entry_id=j.id
    and l.ledger_account_id=finance.ledger_account_id(a.well_id,'1100') and l.amount_minor=abs(a.delta_minor)
    and l.farmer_well_account_id=(select farmer_well_account_id from billing.invoices where id=iv)
    and l.entry_side=case when a.delta_minor>0 then 'debit' else 'credit' end)
   or not exists(select 1 from finance.journal_lines l where l.journal_entry_id=j.id
    and l.ledger_account_id=finance.ledger_account_id(a.well_id,'4300') and l.amount_minor=abs(a.delta_minor)
    and l.entry_side=case when a.delta_minor>0 then 'credit' else 'debit' end) then
    raise exception 'manual_economic_posting_invalid' using errcode='23514';end if;
  end if;
 else
  -- A later invoice may carry this approval in its immutable issuance snapshot.
  if exists(select 1 from billing.invoices i where i.session_id=a.session_id and i.status not in('cancelled','reversed')
   and not exists(select 1 from billing.session_invoice_financial_snapshots sn where sn.invoice_id=i.id
    and sn.manual_approval_revision>=a.manual_approval_revision)) then
   raise exception 'manual_invoice_economic_coverage_missing' using errcode='23514';end if;
  if exists(select 1 from finance.journal_entries where source_type='session_financial_adjustment' and source_id=a.id) then
   raise exception 'uninvoiced_fake_manual_journal' using errcode='23514';end if;
 end if;
end;$$;
create function billing.check_manual_approval_row() returns trigger language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin perform billing.validate_manual_financial_approval(new.id);return null;end;$$;
create function billing.check_manual_invoice_row() returns trigger language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin perform billing.validate_manual_financial_approval(new.adjustment_id);return null;end;$$;
create function billing.check_manual_resolution_row() returns trigger language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
begin perform billing.validate_manual_financial_approval(new.adjustment_id);return null;end;$$;
create constraint trigger manual_approval_complete after insert on billing.session_financial_adjustments deferrable initially deferred for each row execute function billing.check_manual_approval_row();
create constraint trigger manual_invoice_complete after insert on billing.invoice_financial_adjustments deferrable initially deferred for each row execute function billing.check_manual_invoice_row();
create constraint trigger manual_resolution_complete after insert on billing.session_financial_resolution_links deferrable initially deferred for each row execute function billing.check_manual_resolution_row();

create function billing.apply_manual_session_approval(p_session uuid,p_command uuid,p_base_op bigint,p_base_sys bigint,p_base_manual bigint,
 p_amount bigint,p_reason text,p_requested timestamptz) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare well uuid;tenant uuid;actor uuid:=auth.uid();s ops.irrigation_sessions%rowtype;ch billing.approved_session_charges%rowtype;
 inv billing.invoices%rowtype;pc sync.processed_commands%rowtype;debt record;x record;event billing.customer_credit_events%rowtype;
 req jsonb;guard jsonb;result jsonb;child jsonb;children jsonb:='[]';e jsonb;adjustment uuid:=gen_random_uuid();journal uuid;
 posted timestamptz;accepted timestamptz;target_sys bigint;system_amount bigint;delta bigint;excess numeric;take bigint;source uuid;account uuid;code text;
begin
 well:=billing.manual_financial_session_scope(p_session);
 select tenant_id into strict tenant from core.wells where id=well;
 perform billing.enter_financial_write(well,'session.financial_adjust',null,tenant);
 perform billing.manual_financial_session_scope(p_session);
 select * into strict s from ops.irrigation_sessions where id=p_session and well_id=well for update;
 req:=jsonb_build_object('contract','session_financial_adjustment','version',1,'session_id',p_session,'command_id',p_command,
 'base_operational_revision',p_base_op,'base_system_financial_revision',p_base_sys,'base_manual_approval_revision',p_base_manual,
 'approved_amount_minor',p_amount,'reason',btrim(p_reason),'requested_at',to_char(p_requested at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
 if p_command is null then return jsonb_build_object('status','validation_error','reason_code','command_required');end if;
 req:=req||jsonb_build_object('actor_id',actor);
 select * into pc from sync.processed_commands where tenant_id=tenant and command_id=p_command;
 if not found then
  guard:=sync.begin_command(tenant,p_command,'adjust_session_financial_amount',req,p_session);
  if coalesce((guard->>'duplicate')::boolean,false) then
   select * into strict pc from sync.processed_commands where tenant_id=tenant and command_id=p_command;
  end if;
 end if;
 if pc.command_id is not null then
  if pc.command_type is distinct from 'adjust_session_financial_amount' or pc.entity_id is distinct from p_session
   or pc.request_payload is distinct from req then
   return jsonb_build_object('contract','session_financial_adjustment','version',1,'status','conflict_request',
    'session_id',p_session,'command_id',p_command,'retry_authorized',false);
  end if;
  if pc.status='processing' then return jsonb_build_object('contract','session_financial_adjustment','version',1,
   'status','processing','session_id',p_session,'command_id',p_command,'retry_authorized',false);end if;
  if pc.status<>'accepted' or jsonb_typeof(pc.response_payload) is distinct from 'object' then
   return jsonb_build_object('contract','session_financial_adjustment','version',1,'status','unresolved',
    'session_id',p_session,'command_id',p_command,'retry_authorized',false);end if;
  return pc.response_payload;
 end if;
 begin
  if p_amount is null or p_amount<0 or p_base_op is null or p_base_op<0 or p_base_sys is null or p_base_sys<0
   or p_base_manual is null or p_base_manual<0 or p_base_manual=9223372036854775807
   or nullif(btrim(p_reason),'') is null or p_requested is null or not isfinite(p_requested) then
   raise exception 'invalid_financial_request' using errcode='P0FV1';end if;
  select * into ch from billing.approved_session_charges where session_id=p_session;
  if s.status not in('closed','forgotten') or ch.id is null then raise exception 'completed_charge_required' using errcode='P0FV1';end if;
  if s.operational_revision<>p_base_op or ch.financial_applied_revision<>p_base_sys or ch.manual_approval_revision<>p_base_manual then
   raise exception 'revision_changed' using errcode='P0FR1';end if;
  select * into strict debt from billing.session_economic_settlements where session_charge_id=ch.id;
  account:=debt.farmer_well_account_id;
  if not debt.scope_valid or account is null or not exists(select 1 from ops.farmer_well_accounts fa where fa.id=account
   and fa.well_id=well and fa.tenant_id=tenant) then raise exception 'account_evidence_unproven' using errcode='P0FA1';end if;
  perform 1 from ops.farmer_well_accounts where id=account for update;
  if (select count(*) from billing.invoices where session_id=p_session and status not in('cancelled','reversed'))>1 then
   raise exception 'invoice_evidence_unproven' using errcode='P0FA1';end if;
  select * into inv from billing.invoices where session_id=p_session and status not in('cancelled','reversed') for update;
  if inv.id is not null then
   if billing.invoice_has_protected_distribution_use(inv.id) then raise exception 'protected_distribution' using errcode='P0FL1';end if;
   if (inv.tenant_id,inv.well_id,inv.farmer_well_account_id) is distinct from(tenant,well,account)
    or inv.settlement_method<>'normal' or inv.currency_code<>'YER' or inv.status not in('issued','partially_paid','paid','overdue')
    or not exists(select 1 from finance.journal_entries je where je.id=inv.journal_entry_id and je.status='posted'
     and je.tenant_id=tenant and je.well_id=well and je.source_type='invoice' and je.source_id=inv.id)
    or (select total_minor from billing.effective_invoice_totals where id=inv.id) is distinct from ch.amount_minor
    or exists(select 1 from billing.invoice_effective_balances b where b.invoice_id=inv.id and b.collection_hold_minor>0) then
    raise exception 'invoice_evidence_unproven' using errcode='P0FA1';end if;
   if billing.invoice_has_protected_distribution_use(inv.id) then raise exception 'protected_distribution' using errcode='P0FL1';end if;
  end if;
  posted:=billing.manual_financial_posting_context(well);
  -- Derive first, publish nothing if ANY pending system basis is unproven.
  target_sys:=p_base_sys;system_amount:=ch.system_amount_minor;
  for x in select c.* from ops.session_corrections c where c.session_id=p_session and c.new_revision>p_base_sys
   and c.new_revision<=p_base_op order by c.new_revision loop
   if x.previous_revision<>target_sys then raise exception 'system_basis_gap' using errcode='P0FA1';end if;
   e:=billing.derive_session_correction_charge(x.id);system_amount:=(e->>'amount_minor')::bigint;target_sys:=x.new_revision;
  end loop;
  if target_sys<>p_base_op then raise exception 'system_basis_gap' using errcode='P0FA1';end if;
  delta:=(p_amount::numeric-ch.amount_minor::numeric)::bigint;
  -- Release explicit excess BEFORE publishing lower debt; original rows stay intact.
  if inv.id is not null then
   select greatest(explicitly_settled_minor-p_amount,0) into excess from billing.invoice_explicit_settlements where invoice_id=inv.id;
   for x in select a.* from billing.effective_account_credit_applications a where a.invoice_id=inv.id and a.effective_amount_minor>0 order by a.created_at desc,a.id loop
    exit when excess<=0;take:=least(excess,x.effective_amount_minor)::bigint;source:=md5(adjustment::text||':application:'||x.id::text)::uuid;
    child:=billing.release_credit_application(x.id,take,source,p_base_manual+1,btrim(p_reason),posted,adjustment);
    if child->>'status'<>'accepted' then raise exception 'settlement_requires_review' using errcode='P0FA1';end if;
    children:=children||jsonb_build_array(child);excess:=excess-take;
   end loop;
   for x in select a.* from billing.effective_payment_allocations a join billing.payments p on p.id=a.payment_id
    where a.invoice_id=inv.id and a.effective_allocated_minor>0 and p.status='posted' order by a.id loop
    exit when excess<=0;take:=least(excess,x.effective_allocated_minor)::bigint;source:=md5(adjustment::text||':allocation:'||x.id::text)::uuid;
    child:=billing.release_payment_allocation(x.id,take,source,p_base_manual+1,btrim(p_reason),posted,adjustment);
    if child->>'status'<>'accepted' then raise exception 'settlement_requires_review' using errcode='P0FA1';end if;
    children:=children||jsonb_build_array(child);excess:=excess-take;
   end loop;
   if excess>0 then raise exception 'legacy_settlement_unreleasable' using errcode='P0FA1';end if;
  end if;
  accepted:=clock_timestamp();
  insert into billing.session_financial_adjustments(id,tenant_id,well_id,session_id,session_charge_id,command_id,
   manual_approval_revision,base_manual_approval_revision,base_system_financial_revision,base_operational_revision,
   applied_system_financial_revision,system_snapshot_minor,previous_effective_minor,approved_amount_minor,delta_minor,
   actor_id,reason,requested_at,accepted_at,posted_at)
  values(adjustment,tenant,well,p_session,ch.id,p_command,p_base_manual+1,p_base_manual,p_base_sys,p_base_op,
   target_sys,system_amount,ch.amount_minor,p_amount,delta,actor,btrim(p_reason),p_requested,accepted,posted);
  for x in select c.id from ops.session_corrections c where c.session_id=p_session and c.new_revision>p_base_sys
   and c.new_revision<=target_sys order by c.new_revision loop
   perform billing.establish_paired_system_basis(x.id,adjustment,posted);
  end loop;
  if inv.id is not null then
   if delta<>0 then
    insert into finance.journal_entries(tenant_id,well_id,public_code,entry_date,source_type,source_id,description,idempotency_key)
    values(tenant,well,core.generate_public_code('JE'),posted,'session_financial_adjustment',adjustment,
     'اعتماد تعديل مبلغ جلسة','SESSION-FINANCIAL-'||adjustment::text) returning id into journal;
    insert into finance.journal_lines(tenant_id,journal_entry_id,ledger_account_id,entry_side,amount_minor,farmer_well_account_id)
    values(tenant,journal,finance.ledger_account_id(well,'1100'),case when delta>0 then 'debit' else 'credit' end,abs(delta),account),
     (tenant,journal,finance.ledger_account_id(well,'4300'),case when delta>0 then 'credit' else 'debit' end,abs(delta),null);
    perform finance.post_journal_entry(journal,actor);
   end if;
   insert into billing.invoice_financial_adjustments(adjustment_id,invoice_id,journal_entry_id,delta_minor) values(adjustment,inv.id,journal,delta);
  end if;
  if delta<0 then
   for x in select p.id from billing.payments p join billing.payment_economic_applications pe on pe.payment_id=p.id
    where p.session_charge_id=ch.id and p.purpose='session' and p.status='posted' and pe.remaining_minor>0 order by p.paid_at,p.id loop
    child:=billing.rebalance_payment_capacity(x.id,md5(adjustment::text||':rebalance:'||x.id::text)::uuid,p_base_manual+1,btrim(p_reason),posted,adjustment);
    if child->>'status'<>'accepted' then raise exception 'payment_requires_review' using errcode='P0FA1';end if;
    children:=children||jsonb_build_array(child);
   end loop;
  end if;
  perform billing.refresh_partition_invoices(well);
  for x in select value from jsonb_array_elements(children) loop
   select * into strict event from billing.customer_credit_events where id=(x.value->>'event_id')::uuid;
   if event.operation='application_release' then perform billing.validate_application_adjustment_event(event);
   else perform billing.validate_payment_repartition(event);end if;
  end loop;
  perform billing.validate_manual_financial_approval(adjustment);
  result:=jsonb_build_object('contract','session_financial_adjustment','version',1,'status','accepted','session_id',p_session,
   'command_id',p_command,'adjustment_id',adjustment,'operational_revision',p_base_op,'system_financial_revision',target_sys,
   'manual_approval_revision',p_base_manual+1,'previous_effective_minor',ch.amount_minor,'approved_amount_minor',p_amount,
   'effective_amount_minor',p_amount,'delta_minor',delta,'accepted_at',accepted,'retry_authorized',false);
 exception when sqlstate 'P0FA1' or sqlstate 'P0C02' or sqlstate 'P0FL1' or sqlstate 'P0FV1' or sqlstate 'P0FR1'
  or numeric_value_out_of_range then
  get stacked diagnostics code=MESSAGE_TEXT;
  result:=jsonb_build_object('contract','session_financial_adjustment','version',1,'session_id',p_session,'command_id',p_command,
   'status',case SQLSTATE when 'P0FL1' then 'locked' when 'P0FV1' then 'validation_error' when 'P0FR1' then 'conflict_revision'
   else 'financial_review_required' end,'reason_code',case when SQLSTATE='22003' then 'numeric_range' else code end,'retry_authorized',false);
 end;
 perform sync.finish_command(tenant,p_command,'accepted',result);return result;
end;$$;

create function billing.read_manual_session_financial_state(p_session uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $$
declare well uuid;s ops.irrigation_sessions%rowtype;ch billing.approved_session_charges%rowtype;d billing.session_economic_settlements%rowtype;history jsonb;reason text;allowed boolean;
begin
 well:=billing.manual_financial_session_scope(p_session);
 select * into strict s from ops.irrigation_sessions where id=p_session;
 select * into ch from billing.approved_session_charges where session_id=p_session;
 if s.status not in('closed','forgotten') then reason:='completed_charge_required';
 elsif ch.id is null then reason:='canonical_charge_required';
 elsif exists(select 1 from billing.invoices i where i.session_id=p_session and i.status not in('cancelled','reversed')
  and billing.invoice_has_protected_distribution_use(i.id)) then reason:='protected_distribution';
 elsif exists(select 1 from billing.invoices i where i.session_id=p_session and i.status not in('cancelled','reversed')
  and (i.settlement_method<>'normal' or i.currency_code<>'YER' or i.status='draft')) then reason:='invoice_requires_review';
 elsif (select count(distinct period_type) from finance.accounting_periods ap where ap.well_id=well
  and clock_timestamp()::date between ap.starts_at and ap.ends_at
  and ap.status in('open','reopened'))<>2 or exists(select 1 from finance.accounting_periods ap where ap.well_id=well
  and clock_timestamp()::date between ap.starts_at and ap.ends_at
  and ap.status not in('open','reopened')) then reason:='posting_context_unavailable';
 elsif exists(select 1 from ops.session_correction_reconciliations r where r.session_id=p_session and r.status<>'applied') then reason:='system_reconciliation_pending';end if;
 if ch.id is not null then select * into d from billing.session_economic_settlements where session_charge_id=ch.id;end if;
 select coalesce(jsonb_agg(jsonb_build_object('manual_approval_revision',a.manual_approval_revision,
 'previous_effective_minor',a.previous_effective_minor,'approved_amount_minor',a.approved_amount_minor,'delta_minor',a.delta_minor,
 'reason',a.reason,'actor_name',p.full_name,'accepted_at',a.accepted_at,'status',a.status) order by a.manual_approval_revision),'[]')
 into history from billing.session_financial_adjustments a join iam.profiles p on p.id=a.actor_id where a.session_id=p_session;
 allowed:=ch.id is not null and s.status in('closed','forgotten') and coalesce(reason,'') not in('protected_distribution','invoice_requires_review','posting_context_unavailable');
 return jsonb_build_object('contract','session_financial_state','version',1,'session_id',p_session,'well_id',well,
 'original_amount_minor',ch.original_amount_minor,'system_amount_minor',ch.system_amount_minor,'approved_amount_minor',ch.approved_amount_minor,
 'effective_amount_minor',ch.amount_minor,'paid_amount_minor',case when ch.id is null then null else d.settled_minor end,
 'outstanding_amount_minor',case when ch.id is null then null else d.outstanding_minor end,
 'operational_revision',s.operational_revision,'system_financial_revision',coalesce(ch.financial_applied_revision,0),
 'manual_approval_revision',coalesce(ch.manual_approval_revision,0),'can_adjust',allowed,
 'financial_status',case when reason is null then 'ready' when reason='protected_distribution' then 'locked' else 'financial_review_required' end,
 'reason_code',reason,'adjustment_history',history);
end;$$;
create function api.get_session_financial_state(p_session_id uuid) returns jsonb language sql stable security invoker set search_path=pg_catalog,pg_temp as $$
 select billing.read_manual_session_financial_state(p_session_id);$$;
create function api.get_session_financial_adjustment_capability(p_session_id uuid) returns jsonb
language plpgsql stable security invoker set search_path=pg_catalog,pg_temp as $$
begin
 return billing.read_manual_session_financial_state(p_session_id)||jsonb_build_object('contract','session_financial_adjustment_capability');
exception when insufficient_privilege then
 return jsonb_build_object('contract','session_financial_adjustment_capability','version',1,'session_id',p_session_id,
  'can_adjust',false,'reason_code','permission_denied');
end;$$;
create function api.adjust_session_financial_amount(p_session_id uuid,p_command_id uuid,p_base_operational_revision bigint,
 p_base_system_financial_revision bigint,p_base_manual_approval_revision bigint,p_approved_amount_minor bigint,p_reason text,p_requested_at timestamptz)
returns jsonb language plpgsql volatile security invoker set search_path=pg_catalog,pg_temp as $$
begin
 return billing.apply_manual_session_approval(p_session_id,p_command_id,p_base_operational_revision,p_base_system_financial_revision,
 p_base_manual_approval_revision,p_approved_amount_minor,p_reason,p_requested_at);
exception when insufficient_privilege then
 return jsonb_build_object('contract','session_financial_adjustment','version',1,'status','permission_denied',
  'session_id',p_session_id,'command_id',p_command_id,'retry_authorized',false);
end;$$;
create function billing.read_manual_financial_receipt(p_session uuid,p_command uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,pg_temp as $$
declare well uuid;tenant uuid;pc sync.processed_commands%rowtype;state text;begin
 well:=billing.manual_financial_session_scope(p_session);select tenant_id into tenant from core.wells where id=well;
 select * into pc from sync.processed_commands where tenant_id=tenant and command_id=p_command;
 state:='not_found';
 if found then
  if pc.command_type<>'adjust_session_financial_amount' or pc.entity_id<>p_session or pc.request_payload->>'actor_id' is distinct from auth.uid()::text then
   state:='not_found';pc.response_payload:=null;
  elsif pc.status='processing' then state:='processing';else state:=coalesce(pc.response_payload->>'status','unresolved');end if;
 end if;
 return jsonb_build_object('contract','session_financial_adjustment_receipt','version',1,'session_id',p_session,'command_id',p_command,
 'status',state,'result',pc.response_payload,'retry_authorized',false);end;$$;
create function api.get_session_financial_adjustment_receipt(p_session_id uuid,p_command_id uuid) returns jsonb
language plpgsql stable security invoker set search_path=pg_catalog,pg_temp as $$
begin return billing.read_manual_financial_receipt(p_session_id,p_command_id);
exception when insufficient_privilege then
 return jsonb_build_object('contract','session_financial_adjustment_receipt','version',1,'session_id',p_session_id,
 'command_id',p_command_id,'status','permission_denied','result',null,'retry_authorized',false);
end;$$;
create or replace function billing.reconcile_session_correction(p_correction uuid,p_command_id uuid,p_posted_at timestamptz)
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

create or replace function billing.journalize_invoice()
returns trigger
language plpgsql
security definer
set search_path = 'billing', 'finance', 'core', 'pg_temp'
as $function$
declare
  v_je uuid;
  v_lines_count integer;
  v_lines_sum bigint;
begin
 perform billing.require_customer_credit_well_lock(new.well_id);
  if new.status <> 'issued' or new.journal_entry_id is not null then
    return new;
  end if;

  select count(*), coalesce(sum(l.amount_minor), 0) into v_lines_count, v_lines_sum
  from billing.invoice_lines l
  where l.invoice_id = new.id;

  if v_lines_count > 0 and v_lines_sum <> new.total_minor then
    raise exception 'لا يمكن اصدار الفاتورة %: مجموع البنود % لا يساوي الاجمالي %', new.public_code, v_lines_sum, new.total_minor;
  end if;

  insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
  values (new.tenant_id, core.generate_public_code('JE'), new.well_id, new.invoice_date,
          'invoice', new.id, 'فاتورة ' || new.public_code, 'INV-' || new.id::text)
  returning id into v_je;

  insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, farmer_well_account_id, description)
  values (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1100'), 'debit', new.total_minor, new.farmer_well_account_id, 'ذمة الفاتورة على المزارع');

  if v_lines_count = 0 then
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, description)
    values (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '4000'), 'credit', new.total_minor, 'ايراد الفاتورة');
  else
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, description)
    select new.tenant_id, v_je,
           finance.ledger_account_id(new.well_id, case l.line_type
             when 'solar_irrigation' then '4000'
             when 'diesel_operation' then '4100'
             when 'diesel_fuel' then '4200'
             else '4300'
           end),
           case when sum(l.amount_minor)>0 then 'credit' else 'debit' end,
           abs(sum(l.amount_minor)), 'ايراد: ' || l.line_type
    from billing.invoice_lines l
    where l.invoice_id = new.id
    group by l.line_type having sum(l.amount_minor)<>0;
  end if;

  perform finance.post_journal_entry(v_je, new.issued_by);

  update billing.invoices
  set journal_entry_id = v_je
  where id = new.id;

  return new;
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
  v_system_amount bigint;
  v_system_revision bigint;
  v_manual_revision bigint;
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
 perform billing.enter_financial_write((select well_id from ops.irrigation_sessions where id=p_session_id),'invoice.issue',null);
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

  select sc.amount_minor,sc.effective_ended_at,sc.system_amount_minor,sc.financial_applied_revision,sc.manual_approval_revision
  into v_charge_amount,v_ended_at,v_system_amount,v_system_revision,v_manual_revision
  from billing.approved_session_charges sc
  where sc.session_id = p_session_id
    and sc.pricing_mode = 'segments';

  if not found then
    raise exception 'لا يوجد ملخص تكلفة مقاطع مكتمل لهذه الجلسة';
  end if;

  if v_charge_amount=0 then raise exception 'zero_effective_use_typed_issuance_contract' using errcode='22023';end if;

  select pip.id, pip.policy_type
  into v_partner_policy_id, v_partner_policy_type
  from ops.farmer_well_accounts fwa
  join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  join core.well_partners wp
    on wp.well_id = fwa.well_id and wp.person_id = fp.person_id
  join core.partner_irrigation_policies pip
    on pip.partner_id = wp.id and pip.well_id = fwa.well_id
  where fwa.id = v_farmer_well_account_id
    and((pip.accepted_at is not null and pip.accepted_at<=clock_timestamp())
     or(pip.accepted_at is null and pip.period_start<=(clock_timestamp() at time zone core.well_timezone(v_well_id))::date
      and(pip.period_end is null or pip.period_end>(clock_timestamp() at time zone core.well_timezone(v_well_id))::date)))
  order by(pip.accepted_at is not null) desc,pip.policy_version desc nulls last,pip.period_start desc,pip.created_at desc,pip.id desc
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

  if v_line_number = 0 and v_system_amount>0 then
    raise exception 'لم تنتج مقاطع الجلسة أي بند قابل للفوترة';
  end if;

  select coalesce(sum(il.amount_minor), 0)
  into v_lines_total
  from billing.invoice_lines il
  where il.invoice_id = v_invoice_id;

  if v_lines_total<>v_system_amount then raise exception 'system_invoice_evidence_mismatch' using errcode='23514';end if;
  if v_charge_amount<>v_system_amount then
   v_line_number:=v_line_number+1;
   insert into billing.invoice_lines(tenant_id,invoice_id,line_number,line_type,description,quantity,unit,unit_price_minor,amount_minor)
   values(v_tenant_id,v_invoice_id,v_line_number,'manual_adjustment','تعديل مبلغ معتمد',1,'adjustment',
    v_charge_amount-v_system_amount,v_charge_amount-v_system_amount);
   v_lines_total:=v_charge_amount;
  end if;
  insert into billing.session_invoice_financial_snapshots(invoice_id,session_id,system_financial_revision,manual_approval_revision,system_amount_minor,effective_amount_minor,carry_in_minor)
  values(v_invoice_id,p_session_id,v_system_revision,v_manual_revision,v_system_amount,v_charge_amount,v_charge_amount-v_system_amount);

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

create or replace function api.list_well_sessions(
  p_well_id uuid,
  p_farmer_well_account_id uuid default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_unpaid_only boolean default false,
  p_limit integer default 200
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_items jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة سجل الجلسات'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  -- RLS على core.wells هي مصدر التفويض؛ البئر غير المرئي = رفض صريح.
  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  -- Check all visible candidate sessions before filtering or limiting.
  -- Missing positive-revision facts must neither disappear nor use originals.
  if exists (
    select 1 from ops.irrigation_sessions s
    left join ops.effective_session_facts ef on ef.session_id=s.id
    where s.well_id=p_well_id and s.operational_revision>0
      and (ef.operational_revision is distinct from s.operational_revision
        or ef.effective_started_at is null or ef.effective_ended_at is null
        or ef.effective_started_at>=ef.effective_ended_at)
  ) then
    raise exception 'سجل تصحيح الجلسة غير مكتمل' using errcode='55000';
  end if;

  select coalesce(
           jsonb_agg(x.item order by x.started_at desc, x.id),
           '[]'::jsonb
         )
  into v_items
  from (
    select
      s.id,
      ef.effective_started_at as started_at,
      jsonb_build_object(
        'id', s.id,
        'well_id', s.well_id,
        'status', s.status,
        'original_started_at', s.started_at,
        'original_ended_at', s.ended_at,
        'effective_started_at', ef.effective_started_at,
        'effective_ended_at', ef.effective_ended_at,
        'operational_revision', s.operational_revision,
        'financial_applied_revision', sc.financial_applied_revision,
        'financial_status', coalesce((select work.status
          from ops.session_correction_reconciliations work
          where work.session_id=s.id and work.operational_revision=s.operational_revision),
          case when s.operational_revision=0 then 'not_applicable' else 'pending' end),
        'started_at', ef.effective_started_at,
        'ended_at', ef.effective_ended_at,
        'farmer_well_account_id', fwa.id,
        'farmer_public_code', fwa.public_code,
        'farmer_name', per.full_name,
        'farm_id', f.id,
        'farm_name', f.name,
        'pump_id', pm.id,
        'pump_name', pm.name,
        'operator_name', pr.full_name,
        'energy_source', run.energy_source,
        'actual_seconds', case
          -- الجارية بلا مدة فعلية نهائية: null لا تلفيق (ق-37).
          when ef.effective_ended_at is null then null
          when s.operational_revision>0 then extract(epoch from (ef.effective_ended_at-ef.effective_started_at))::bigint
          -- المقفلة: مجموع مقاطعها كلها بما فيها التوقفات (ق-131 البند 7)،
          -- والقديمة بلا مقاطع تغلفها المخزَّن ended_at - started_at.
          when seg.segment_count > 0
            and seg.segments_actual_seconds is not null
            then seg.segments_actual_seconds
          else extract(epoch from (s.ended_at - s.started_at))::bigint
        end,
        'billable_seconds', sc.duration_seconds,
        'original_amount_minor',sc.original_amount_minor,'system_amount_minor',sc.system_amount_minor,
      'approved_amount_minor',sc.approved_amount_minor,'manual_approval_revision',sc.manual_approval_revision,
      'total_amount_minor', sc.amount_minor,
        'paid_amount_minor', pay.paid_minor,
        'payment_status', case
          when sc.id is null then 'not_billed'
          when coalesce(pay.paid_minor, 0) >= sc.amount_minor then 'settled'
          when coalesce(pay.paid_minor, 0) > 0 then 'partial'
          else 'unpaid'
        end,
        'has_charge', sc.id is not null,
        'has_invoice', inv.id is not null
      ) as item
    from ops.irrigation_sessions s
    join ops.effective_session_facts ef on ef.session_id=s.id
    -- كل الانضمامات التالية تزويقية (اسم/رمز) والمصدر الحاكم للتفويض هو
    -- RLS على الجلسة نفسها؛ لذلك LEFT JOIN إجباري: صف تزويق محجوب أو
    -- غير معيّن يجب ألا يُخفي جلسة مرئية.
    left join ops.farms f on f.id = s.farm_id
    left join ops.farmer_well_accounts fwa
      on fwa.id = coalesce(s.farmer_well_account_id, f.farmer_well_account_id)
    left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
    left join core.persons per on per.id = fp.person_id
    left join core.pumps pm on pm.id = s.pump_id
    left join iam.profiles pr on pr.id = s.operator_profile_id
    left join billing.approved_session_charges sc on sc.session_id = s.id
    left join billing.invoices inv on inv.session_id = s.id
    left join lateral (
      select ss.energy_source
      from ops.session_segments ss
      where ss.session_id = s.id
        and ss.energy_source is not null
      order by ss.sequence_number
      limit 1
    ) run on true
    left join lateral (
      select
        count(*) as segment_count,
        sum(ss.actual_seconds)::bigint as segments_actual_seconds
      from ops.session_segments ss
      where ss.session_id = s.id
    ) seg on true
    left join lateral (
      -- الفاتورة الفعالة إن وجدت، وإلا تسديد charge المقسم اقتصاديًا.
      select (select paid_minor from billing.session_read_settlements where session_charge_id=sc.id) as paid_minor
    ) pay on sc.id is not null
    where s.well_id = p_well_id
      and (
        p_farmer_well_account_id is null
        or fwa.id = p_farmer_well_account_id
      )
      and (p_from is null or ef.effective_started_at >= p_from)
      and (p_to is null or ef.effective_started_at < p_to)
      and (
        coalesce(p_unpaid_only, false) is not true
        or sc.id is null
        or coalesce(pay.paid_minor, 0) < sc.amount_minor
      )
    order by ef.effective_started_at desc, s.id
    limit v_limit
  ) x;

  return jsonb_build_object(
    'contract', 'list_well_sessions',
    'version', 1,
    'items', v_items
  );
end;
$function$;

create or replace function api.get_session_detail(
  p_session_id uuid
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_session jsonb;
  v_segments jsonb;
  v_segments_invalid boolean;
  v_financial_revision bigint;
  v_charge_id uuid;
  v_pricing_evidence jsonb;
  v_financial_segments jsonb := '[]'::jsonb;
  v_payment jsonb;
  v_crops jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة تفصيل الجلسة'
      using errcode = '28000';
  end if;

  if p_session_id is null then
    raise exception 'معرّف الجلسة مطلوب'
      using errcode = '22023';
  end if;

  -- Check all visible candidate sessions before filtering or limiting.
  -- Missing positive-revision facts must neither disappear nor use originals.
  if exists (
    select 1 from ops.irrigation_sessions s
    left join ops.effective_session_facts ef on ef.session_id=s.id
    where s.id=p_session_id and s.operational_revision>0
      and (ef.operational_revision is distinct from s.operational_revision
        or ef.effective_started_at is null or ef.effective_ended_at is null
        or ef.effective_started_at>=ef.effective_ended_at)
  ) then
    raise exception 'سجل تصحيح الجلسة غير مكتمل' using errcode='55000';
  end if;

  select
    jsonb_build_object(
      'id', s.id,
      'well_id', s.well_id,
      'status', s.status,
      'original_started_at', s.started_at,
      'original_ended_at', s.ended_at,
      'effective_started_at', ef.effective_started_at,
      'effective_ended_at', ef.effective_ended_at,
      'operational_revision', s.operational_revision,
      'financial_applied_revision', sc.financial_applied_revision,
      'financial_status', coalesce((select work.status
        from ops.session_correction_reconciliations work
        where work.session_id=s.id and work.operational_revision=s.operational_revision),
        case when s.operational_revision=0 then 'not_applicable' else 'pending' end),
      'started_at', ef.effective_started_at,
      'ended_at', ef.effective_ended_at,
      'farmer_well_account_id', fwa.id,
      'farmer_public_code', fwa.public_code,
      'farmer_name', per.full_name,
      'farm_id', f.id,
      'farm_name', f.name,
      'pump_id', pm.id,
      'pump_name', pm.name,
      'operator_name', pr.full_name,
      'energy_source', run.energy_source,
      'actual_seconds', case
        when ef.effective_ended_at is null then null
        when s.operational_revision>0 then extract(epoch from (ef.effective_ended_at-ef.effective_started_at))::bigint
        when seg.segment_count > 0
          and seg.segments_actual_seconds is not null
          then seg.segments_actual_seconds
        else extract(epoch from (s.ended_at - s.started_at))::bigint
      end,
      'billable_seconds', sc.duration_seconds,
      'original_amount_minor',sc.original_amount_minor,'system_amount_minor',sc.system_amount_minor,
      'approved_amount_minor',sc.approved_amount_minor,'manual_approval_revision',sc.manual_approval_revision,
      'total_amount_minor', sc.amount_minor,
      'paid_amount_minor', pay.paid_minor,
      'payment_status', case
        when sc.id is null then 'not_billed'
        when coalesce(pay.paid_minor, 0) >= sc.amount_minor then 'settled'
        when coalesce(pay.paid_minor, 0) > 0 then 'partial'
        else 'unpaid'
      end,
      'has_charge', sc.id is not null,
      'has_invoice', inv.id is not null
    ),
    case
      when last_pay.id is null then null
      else jsonb_build_object(
        'method', last_pay.method,
        'reference', last_pay.public_code,
        'paid_at', last_pay.paid_at
      )
    end
  into v_session, v_payment
  from ops.irrigation_sessions s
  join ops.effective_session_facts ef on ef.session_id=s.id
  left join ops.farms f on f.id = s.farm_id
  left join ops.farmer_well_accounts fwa
    on fwa.id = coalesce(s.farmer_well_account_id, f.farmer_well_account_id)
  left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  left join core.persons per on per.id = fp.person_id
  left join core.pumps pm on pm.id = s.pump_id
  left join iam.profiles pr on pr.id = s.operator_profile_id
  left join billing.approved_session_charges sc on sc.session_id = s.id
  left join billing.invoices inv on inv.session_id = s.id
  left join lateral (
    select ss.energy_source
    from ops.session_segments ss
    where ss.session_id = s.id
      and ss.energy_source is not null
    order by ss.sequence_number
    limit 1
  ) run on true
  left join lateral (
    select
      count(*) as segment_count,
      sum(ss.actual_seconds)::bigint as segments_actual_seconds
    from ops.session_segments ss
    where ss.session_id = s.id
  ) seg on true
  left join lateral (
    select (select paid_minor from billing.session_read_settlements where session_charge_id=sc.id) as paid_minor
  ) pay on sc.id is not null
  left join lateral (
    select p.id, p.method, p.public_code, p.paid_at
    from billing.payments p
    join billing.payment_economic_applications econ on econ.payment_id=p.id
    where p.status = 'posted' and (
      (econ.default_session_charge_id=sc.id and econ.effective_direct_minor>0)
      or exists(select 1 from billing.effective_payment_allocations a
        join billing.invoices target on target.id=a.invoice_id
        where a.payment_id=p.id and target.session_id=s.id and a.effective_allocated_minor>0
          and econ.explicit_allocated_minor>0)
      or exists(select 1 from billing.effective_account_credit_applications a
        join billing.account_credits c on c.id=a.credit_id
        join billing.invoices target on target.id=a.invoice_id
        where c.payment_id=p.id and target.session_id=s.id and a.effective_amount_minor>0
          and econ.credit_backed_minor>0)
    )
    order by p.paid_at desc, p.id
    limit 1
  ) last_pay on sc.id is not null
  where s.id = p_session_id;

  -- الجلسة غير المرئية عبر RLS = رفض صريح بدل مغلّف فارغ غامض.
  if v_session is null then
    raise exception 'لا توجد صلاحية على هذه الجلسة'
      using errcode = '42501';
  end if;

  v_financial_revision:=coalesce((v_session->>'financial_applied_revision')::bigint,0);
  if v_financial_revision>0 then
    -- Read the last FINANCIALLY applied revision, which may trail the current
    -- operational revision. Never derive a new price or fall back to originals.
    select ch.id,ch.pricing_evidence into v_charge_id,v_pricing_evidence
    from billing.effective_session_charges ch
    where ch.session_id=p_session_id and ch.financial_applied_revision=v_financial_revision;
    if v_financial_revision>(v_session->>'operational_revision')::bigint
      or jsonb_typeof(v_pricing_evidence) is distinct from 'object'
      or jsonb_typeof(v_pricing_evidence->'segments') is distinct from 'array' then
      raise exception 'دليل المقاطع المالي المطبق غير مكتمل' using errcode='55000';
    end if;
    v_financial_segments:=v_pricing_evidence->'segments';
    if not exists (
      select 1 from billing.session_charge_corrections fc
      join ops.session_correction_reconciliations work on work.correction_id=fc.correction_id
      where fc.session_charge_id=v_charge_id and fc.session_id=p_session_id
        and fc.operational_revision=v_financial_revision
        and fc.pricing_evidence=v_pricing_evidence
        and work.session_id=p_session_id and work.operational_revision=v_financial_revision
        and work.status='applied' and work.financial_applied_revision=v_financial_revision
        and fc.correction_id::text=v_pricing_evidence->>'correction_id'
    ) then
      raise exception 'دليل المقاطع المالي المطبق غير مثبت' using errcode='55000';
    end if;
    -- Validate persisted shape, one-to-one segment identities and aggregates.
    -- Summation verifies evidence; no duration/rate multiplication occurs here.
    begin
      if (v_pricing_evidence->>'operational_revision')::bigint is distinct from v_financial_revision
        or v_pricing_evidence->>'original_charge_id' is distinct from v_charge_id::text
        or (v_pricing_evidence->>'amount_minor')::bigint is distinct from
             (v_session->>'system_amount_minor')::bigint
        or (v_pricing_evidence->>'billable_seconds')::bigint is distinct from
             (v_session->>'billable_seconds')::bigint
        or jsonb_array_length(v_financial_segments)=0
        or jsonb_array_length(v_financial_segments)<>(select count(*) from ops.session_segments
             where session_id=p_session_id)
        or exists (select 1 from jsonb_array_elements(v_financial_segments) e
             group by e->>'segment_id' having count(*)<>1)
        or exists (
          select 1 from jsonb_array_elements(v_financial_segments) e
          left join ops.session_segments original on original.id::text=e->>'segment_id'
            and original.session_id=p_session_id
          left join ops.session_corrections accepted on accepted.session_id=p_session_id
            and accepted.new_revision=v_financial_revision
          where original.id is null or jsonb_typeof(e) is distinct from 'object'
            or accepted.id is null
            or (e->>'sequence_number')::bigint is distinct from original.sequence_number
            or (e->>'effective_started_at')::timestamptz is distinct from
              case when original.sequence_number=1 then accepted.after_started_at else original.started_at end
            or (e->>'effective_ended_at')::timestamptz is distinct from
              case when original.sequence_number=(select max(sequence_number) from ops.session_segments
                where session_id=p_session_id) then accepted.after_ended_at else original.ended_at end
            or jsonb_typeof(e->'actual_seconds') is distinct from 'number'
            or (e->>'actual_seconds')::bigint is distinct from extract(epoch from
              ((e->>'effective_ended_at')::timestamptz-(e->>'effective_started_at')::timestamptz))::bigint
            or jsonb_typeof(e->'billable_seconds') is distinct from 'number'
            or jsonb_typeof(e->'time_charge_minor') is distinct from 'number'
            or (e->>'billable_seconds')::bigint<0 or (e->>'time_charge_minor')::bigint<0
            or ((e->>'rate_minor') is not null and jsonb_typeof(e->'rate_minor') is distinct from 'number')
            or (e->>'rate_minor')::bigint<0
            or (original.is_billable and
              (jsonb_typeof(e->'rate_minor') is distinct from 'number' or (e->>'rate_minor')::bigint<=0))
            or (not original.is_billable and
              ((e->>'billable_seconds')::bigint<>0 or (e->>'time_charge_minor')::bigint<>0))
        )
        or (select sum((e->>'time_charge_minor')::bigint) from jsonb_array_elements(v_financial_segments) e)
             is distinct from (v_session->>'system_amount_minor')::numeric
        or (select sum((e->>'billable_seconds')::bigint) from jsonb_array_elements(v_financial_segments) e)
             is distinct from (v_session->>'billable_seconds')::numeric then
        raise exception 'دليل المقاطع المالي المطبق غير متسق' using errcode='55000';
      end if;
    exception when invalid_text_representation or numeric_value_out_of_range
      or invalid_datetime_format or datetime_field_overflow then
      raise exception 'قيم دليل المقاطع المالي المطبق غير صالحة' using errcode='55000';
    end;
  end if;

  -- Same operational boundary substitution as C1 acceptance: only the first
  -- start and last end change. Internal execution boundaries stay pinned.
  with original_segments as (
    select ss.*,
      row_number() over(order by sequence_number) as n,
      count(*) over() as total,
      lag(ended_at) over(order by sequence_number) as prior_end
    from ops.session_segments ss where ss.session_id=p_session_id
  ), effective_segments as (
    select original_segments.*,
      case when n=1 then (v_session->>'effective_started_at')::timestamptz
        else started_at end as effective_started_at,
      case when n=total then (v_session->>'effective_ended_at')::timestamptz
        else ended_at end as effective_ended_at
    from original_segments
  )
  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'sequence_number', ss.sequence_number,
               'segment_type', ss.segment_type,
               'is_stop', ss.segment_type not in (
                 'solar_run', 'well_diesel_run', 'farmer_diesel_run'
               ),
               'is_billable', ss.is_billable,
               'energy_source', ss.energy_source,
               'original_started_at', ss.started_at,
               'original_ended_at', ss.ended_at,
               'started_at', ss.effective_started_at,
               'ended_at', ss.effective_ended_at,
               'actual_seconds', case when (v_session->>'operational_revision')::bigint>0
                 then extract(epoch from (ss.effective_ended_at-ss.effective_started_at))::bigint
                 else ss.actual_seconds end,
               'financial_evidence_basis', case when v_financial_revision>0
                 then 'applied_reconciliation' else 'original_execution' end,
               'financial_evidence_revision', v_financial_revision,
               'billable_seconds', case when v_financial_revision>0
                 then (financial.value->>'billable_seconds')::bigint else ss.billable_seconds end,
               'applied_rate_minor', case when v_financial_revision>0
                 then (financial.value->>'rate_minor')::bigint else coalesce(
                 ss.applied_operation_rate_minor,
                 ss.applied_hourly_rate_minor
               ) end,
               'time_charge_minor', case when v_financial_revision>0
                 then (financial.value->>'time_charge_minor')::bigint else ss.time_charge_minor end,
               -- C2 applied charge evidence is operation-only; its canonical
               -- financial_session_segments contract carries zero fuel charge.
               'fuel_charge_minor', case when v_financial_revision>0 then 0::bigint else ss.fuel_charge_minor end,
               'total_charge_minor', case when v_financial_revision>0
                 then (financial.value->>'time_charge_minor')::bigint else ss.total_charge_minor end,
               'notes', ss.notes
             )
             order by ss.sequence_number
           ),
           '[]'::jsonb
         ),
         count(*)=0
         -- Timeline validity uses exact numeric epoch durations. Independent
         -- bigint conversions belong only to presentation, never this check.
         or coalesce(sum(extract(epoch from (ss.effective_ended_at-ss.effective_started_at))),0::numeric)
              is distinct from extract(epoch from (
                (v_session->>'effective_ended_at')::timestamptz
                -(v_session->>'effective_started_at')::timestamptz))
         or coalesce(bool_or(
           ss.sequence_number<>ss.n
           or ss.started_at is null or ss.ended_at is null
           or not isfinite(ss.started_at) or not isfinite(ss.ended_at)
           or ss.started_at>=ss.ended_at
           or (ss.n=1 and ss.started_at is distinct from
               (v_session->>'original_started_at')::timestamptz)
           or (ss.n=ss.total and ss.ended_at is distinct from
               (v_session->>'original_ended_at')::timestamptz)
           or (ss.n>1 and ss.started_at is distinct from ss.prior_end)
           or ss.effective_started_at is null or ss.effective_ended_at is null
           or not isfinite(ss.effective_started_at) or not isfinite(ss.effective_ended_at)
           or ss.effective_started_at>=ss.effective_ended_at
         ),false)
  into v_segments,v_segments_invalid
  from effective_segments ss
  left join jsonb_array_elements(v_financial_segments) financial(value)
    on financial.value->>'segment_id'=ss.id::text;

  if (v_session->>'operational_revision')::bigint>0 and v_segments_invalid then
    raise exception 'مقاطع الجلسة المصححة غير متسقة' using errcode='55000';
  end if;

  -- المحاصيل كما اختيرت وقت بدء هذه الجلسة (لقطة مستقلة لا تتبع الأرض).
  select coalesce(
           jsonb_agg(sc.crop_name order by sc.position),
           '[]'::jsonb
         )
  into v_crops
  from ops.session_crops sc
  where sc.session_id = p_session_id;

  -- Base visibility and all effective/financial validation have already passed.
  v_session := v_session || ops.session_correction_capabilities_read(p_session_id);

  return jsonb_build_object(
    'contract', 'get_session_detail',
    'version', 1,
    'session', v_session,
    'segments', v_segments,
    'crops', v_crops,
    'payment', v_payment
  );
end;
$function$;

create or replace function api.get_reports_summary(
  p_well_id uuid,
  p_period text default 'this_month',
  p_start timestamptz default null,
  p_end timestamptz default null
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_period text := nullif(btrim(coalesce(p_period, '')), '');
  v_tz text;
  v_bounds tstzrange;
  v_start timestamptz;
  v_end timestamptz;
  v_first_day date;
  v_last_day date;
  v_result jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة التقارير'
      using errcode = '28000';
  end if;

  if p_well_id is null then
    raise exception 'معرّف البئر مطلوب'
      using errcode = '22023';
  end if;

  v_period := coalesce(v_period, 'this_month');

  -- الحدود تُحسب في عقد واحد، فيَرِثها كل مستهلك بلا نسخة ثانية منها.
  v_tz := core.well_timezone(p_well_id);
  v_bounds := core.period_bounds(p_well_id, v_period, p_start, p_end);
  v_start := lower(v_bounds);
  v_end := upper(v_bounds);
  v_first_day := (v_start at time zone v_tz)::date;
  v_last_day := (v_end at time zone v_tz)::date - 1;

  if not exists (
    select 1
    from core.wells w
    where w.id = p_well_id
  ) then
    raise exception 'لا توجد صلاحية على هذا البئر'
      using errcode = '42501';
  end if;

  with days as (
    select gs::date as day
    from generate_series(
      v_first_day::timestamp, v_last_day::timestamp, interval '1 day'
    ) as gs
  ),
  -- ق-27: التصفية على وقت النهاية. وق-37: الجلسة غير المقفلة خارج المجاميع.
  -- ق-131 البند 7: المدة التشغيلية = الفعلي (مقاطع الجلسة أو مغلفها
  -- القديم)، والفوترة والإيراد يبقيان من billing.session_charges.
  sess as (
    select
      s.id,
      s.ended_at,
      case
        when seg.segment_count > 0
          and seg.segments_actual_seconds is not null
          then seg.segments_actual_seconds
        else extract(epoch from (s.ended_at - s.started_at))::bigint
      end as actual_seconds,
      coalesce(sc.duration_seconds, 0) as billable_seconds,
      coalesce(sc.amount_minor, 0) as amount_minor
    from ops.irrigation_sessions s
    left join billing.approved_session_charges sc on sc.session_id = s.id
    left join lateral (
      select
        count(*) as segment_count,
        sum(ss.actual_seconds)::bigint as segments_actual_seconds
      from ops.session_segments ss
      where ss.session_id = s.id
    ) seg on true
    where s.well_id = p_well_id
      and s.ended_at is not null
      and s.ended_at >= v_start
      and s.ended_at < v_end
  ),
  paid_rows as (
    select p.paid_at, p.amount_minor
    from billing.payments p
    where p.well_id = p_well_id
      and p.status = 'posted'
      and p.paid_at >= v_start
      and p.paid_at < v_end
  ),
  exp_rows as (
    select e.spent_at, e.amount_minor
    from finance.expenses e
    where e.well_id = p_well_id
      and e.status = 'posted'
      and e.spent_at >= v_start
      and e.spent_at < v_end
  ),
  fuel as (
    select coalesce(sum(f.quantity_ml), 0) as fuel_out_ml
    from inventory.fuel_transactions f
    where f.well_id = p_well_id
      and f.status = 'posted'
      and f.direction = 'out'
      and f.occurred_at >= v_start
      and f.occurred_at < v_end
  ),
  -- إسناد اليوم بالمنطقة المحلية: `::date` الخام يقع على منطقة الخادم.
  daily as (
    select
      d.day,
      (
        select count(*)
        from sess x
        where (x.ended_at at time zone v_tz)::date = d.day
      ) as sessions_count,
      (
        select coalesce(sum(x.actual_seconds), 0)
        from sess x
        where (x.ended_at at time zone v_tz)::date = d.day
      ) as duration_seconds,
      (
        select coalesce(sum(x.amount_minor), 0)
        from paid_rows x
        where (x.paid_at at time zone v_tz)::date = d.day
      ) as collected_minor,
      (
        select coalesce(sum(x.amount_minor), 0)
        from exp_rows x
        where (x.spent_at at time zone v_tz)::date = d.day
      ) as expenses_minor
    from days d
  ),
  weekly as (
    select
      (
        dd.day
        - ((((extract(dow from dd.day)::integer + 1) % 7)) || ' days')::interval
      )::date as week_start,
      sum(dd.collected_minor) as collected_minor,
      sum(dd.expenses_minor) as expenses_minor
    from daily dd
    group by 1
  ),
  -- توزيع الطاقة من actual_seconds للمقاطع الحاملة لمصدر طاقة (ق-131):
  -- بلا مسار actual_minutes*60 القديم، وبلا استخدام المفوتر زمنًا للطاقة.
  energy as (
    select
      src.energy_source,
      coalesce((
        select sum(seg.actual_seconds)
        from ops.session_segments seg
        join sess s2 on s2.id = seg.session_id
        where seg.energy_source = src.energy_source
      ), 0) as total_seconds
    from (
      values ('solar'), ('well_diesel'), ('farmer_diesel')
    ) as src(energy_source)
  )
  select jsonb_build_object(
    'contract', 'get_reports_summary',
    'version', 3,
    'well_id', p_well_id,
    'period_code', v_period,
    'period_start', v_start,
    'period_end', v_end,
    'timezone', v_tz,
    'week_starts_on', 'saturday',
    'session_day_basis', 'ended_at',
    'open_sessions_excluded', true,
    'duration_basis', 'actual_execution',
    'totals', jsonb_build_object(
      'total_sessions', (select count(*) from sess),
      'total_duration_seconds', (
        select coalesce(sum(actual_seconds), 0) from sess
      ),
      'total_revenue_minor', (
        select coalesce(sum(amount_minor), 0) from sess
      ),
      'total_collected_minor', (
        select coalesce(sum(amount_minor), 0) from paid_rows
      ),
      'total_expenses_minor', (
        select coalesce(sum(amount_minor), 0) from exp_rows
      ),
      'total_fuel_consumed_ml', (select fuel_out_ml from fuel)
    ),
    'daily_irrigation', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'day', dd.day,
          'sessions_count', dd.sessions_count,
          'duration_seconds', dd.duration_seconds
        ) order by dd.day
      ), '[]'::jsonb)
      from daily dd
    ),
    'financial_trends', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'week_start', wk.week_start,
          'week_end', wk.week_start + 6,
          'collected_minor', wk.collected_minor,
          'expenses_minor', wk.expenses_minor
        ) order by wk.week_start
      ), '[]'::jsonb)
      from weekly wk
    ),
    'energy_distribution', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'energy_source', en.energy_source,
          'total_seconds', en.total_seconds
        ) order by en.energy_source
      ), '[]'::jsonb)
      from energy en
    )
  )
  into v_result;

  return v_result;
end;
$function$;

create or replace view reporting.well_daily_summary as
with days as (
  select
    s.well_id,
    date_trunc('day', s.ended_at)::date as day
  from ops.irrigation_sessions s
  where s.status in ('closed', 'forgotten')
    and s.ended_at is not null

  union

  select
    s.well_id,
    date_trunc('day', s.started_at)::date as day
  from ops.irrigation_sessions s
  where s.status = 'open'

  union

  select
    p.well_id,
    date_trunc('day', p.paid_at)::date as day
  from billing.payments p

  union

  select
    e.well_id,
    date_trunc('day', e.spent_at)::date as day
  from finance.expenses e

  union

  select
    f.well_id,
    date_trunc('day', f.occurred_at)::date as day
  from inventory.fuel_transactions f
),
session_energy as (
  select
    s.id as session_id,
    s.well_id,
    date_trunc('day', s.ended_at)::date as day,

    case
      when count(ss.id) > 0 then
        coalesce(
          sum(ss.billable_seconds)
            filter (where ss.energy_source = 'solar'),
          0
        )::bigint

      when p.power_source = 'solar' then
        coalesce(sc.duration_seconds, 0)::bigint

      else 0::bigint
    end as solar_seconds,

    case
      when count(ss.id) > 0 then
        coalesce(
          sum(ss.billable_seconds)
            filter (
              where ss.energy_source in (
                'well_diesel',
                'farmer_diesel'
              )
            ),
          0
        )::bigint

      when p.power_source = 'diesel' then
        coalesce(sc.duration_seconds, 0)::bigint

      else 0::bigint
    end as diesel_seconds

  from ops.irrigation_sessions s

  join core.pumps p
    on p.id = s.pump_id

  left join billing.session_charges sc
    on sc.session_id = s.id

  left join ops.session_segments ss
    on ss.session_id = s.id

  where s.status in ('closed', 'forgotten')
    and s.ended_at is not null

  group by
    s.id,
    s.well_id,
    s.ended_at,
    p.power_source,
    sc.duration_seconds
)
select
  w.tenant_id,
  d.well_id,
  d.day,

  (
    select count(*)
    from ops.irrigation_sessions s
    where s.well_id = d.well_id
      and s.status in ('closed', 'forgotten')
      and date_trunc('day', s.ended_at)::date = d.day
  ) as sessions_count,

  (
    select count(*)
    from ops.irrigation_sessions s
    where s.well_id = d.well_id
      and s.status = 'open'
      and date_trunc('day', s.started_at)::date = d.day
  ) as open_sessions,

  (
    select coalesce(sum(se.solar_seconds), 0)::bigint
    from session_energy se
    where se.well_id = d.well_id
      and se.day = d.day
  ) as solar_seconds,

  (
    select coalesce(sum(se.diesel_seconds), 0)::bigint
    from session_energy se
    where se.well_id = d.well_id
      and se.day = d.day
  ) as diesel_seconds,

  (
    select coalesce(sum(sc.amount_minor), 0)
    from billing.approved_session_charges sc
    join ops.irrigation_sessions s
      on s.id = sc.session_id
    where s.well_id = d.well_id
      and s.status in ('closed', 'forgotten')
      and date_trunc('day', s.ended_at)::date = d.day
  ) as charges_minor,

  (
    select coalesce(sum(p.amount_minor), 0)
    from billing.payments p
    where p.well_id = d.well_id
      and p.status = 'posted'
      and date_trunc('day', p.paid_at)::date = d.day
  ) as collected_minor,

  (
    select coalesce(sum(e.amount_minor), 0)
    from finance.expenses e
    where e.well_id = d.well_id
      and e.status = 'posted'
      and date_trunc('day', e.spent_at)::date = d.day
  ) as expenses_minor,

  (
    select coalesce(sum(f.quantity_ml), 0)
    from inventory.fuel_transactions f
    where f.well_id = d.well_id
      and f.status = 'posted'
      and f.direction = 'out'
      and date_trunc('day', f.occurred_at)::date = d.day
  ) as fuel_out_ml

from days d
join core.wells w
  on w.id = d.well_id;

create or replace function ops.shift_report(p_shift_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'ops', 'billing', 'finance', 'iam', 'pg_temp'
as $$
declare
  v_s record;
  v_collected bigint;
  v_expenses bigint;
  v_handed bigint;
  v_debt bigint;
  v_sessions integer;
  v_open_sessions integer;
  v_operator text;
  v_payments jsonb;
  v_expense_items jsonb;
begin
  select * into v_s from ops.shifts where id = p_shift_id;
  if v_s.id is null then
    raise exception 'المناوبة % غير موجودة', p_shift_id;
  end if;

  select full_name into v_operator from iam.profiles where id = v_s.operator_profile_id;

  select coalesce(sum(amount_minor), 0) into v_collected
  from billing.payments where shift_id = p_shift_id and status <> 'reversed';

  select coalesce(sum(amount_minor), 0) into v_expenses
  from finance.expenses where shift_id = p_shift_id and status in ('posted', 'approved');

  select coalesce(sum(coalesce(confirmed_amount_minor, declared_amount_minor)), 0) into v_handed
  from ops.shift_handovers where shift_id = p_shift_id and status in ('confirmed', 'settled');

  select count(*), coalesce(sum(case when s.status = 'open' then 1 else 0 end), 0)
  into v_sessions, v_open_sessions
  from ops.irrigation_sessions s where s.current_shift_id = p_shift_id;

  select coalesce(sum(d.outstanding_minor),0)::bigint into v_debt
  from billing.session_economic_settlements d join ops.irrigation_sessions s on s.id=d.session_id
  where s.current_shift_id = p_shift_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'public_code', p.public_code, 'amount_minor', p.amount_minor,
    'purpose', p.purpose, 'method', p.method, 'paid_at', p.paid_at, 'note', p.note
  ) order by p.paid_at), '[]'::jsonb) into v_payments
  from billing.payments p where p.shift_id = p_shift_id and p.status <> 'reversed';

  select coalesce(jsonb_agg(jsonb_build_object(
    'public_code', e.public_code, 'amount_minor', e.amount_minor,
    'description', e.description, 'spent_at', e.spent_at,
    'has_attachment', (e.attachment_url is not null), 'status', e.status
  ) order by e.spent_at), '[]'::jsonb) into v_expense_items
  from finance.expenses e where e.shift_id = p_shift_id and e.status <> 'reversed';

  return jsonb_build_object(
    'shift_id', p_shift_id,
    'public_code', v_s.public_code,
    'operator', v_operator,
    'status', v_s.status,
    'started_at', v_s.started_at,
    'ended_at', v_s.ended_at,
    'collected_minor', v_collected,
    'expenses_minor', v_expenses,
    'handed_over_minor', v_handed,
    'farmer_debt_minor', greatest(v_debt, 0),
    'in_hand_minor', v_collected - v_expenses - v_handed,
    'sessions_count', v_sessions,
    'open_sessions_count', v_open_sessions,
    'payments', v_payments,
    'expenses', v_expense_items
  );
end;
$$;

create or replace function ops.operator_totals(p_profile_id uuid, p_well_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'ops', 'billing', 'finance', 'pg_temp'
as $$
declare
  v_collected bigint;
  v_expenses bigint;
  v_handed bigint;
  v_debt bigint;
  v_shifts integer;
  v_custody bigint;
begin
  select count(*) into v_shifts from ops.shifts s
  where s.operator_profile_id = p_profile_id
    and (p_well_id is null or s.well_id = p_well_id);

  select coalesce(sum(p.amount_minor), 0) into v_collected
  from billing.payments p
  join ops.shifts s on s.id = p.shift_id
  where s.operator_profile_id = p_profile_id
    and (p_well_id is null or s.well_id = p_well_id)
    and p.status <> 'reversed';

  select coalesce(sum(e.amount_minor), 0) into v_expenses
  from finance.expenses e
  join ops.shifts s on s.id = e.shift_id
  where s.operator_profile_id = p_profile_id
    and (p_well_id is null or s.well_id = p_well_id)
    and e.status in ('posted', 'approved');

  select coalesce(sum(coalesce(h.confirmed_amount_minor, h.declared_amount_minor)), 0) into v_handed
  from ops.shift_handovers h
  where h.from_profile_id = p_profile_id
    and (p_well_id is null or h.well_id = p_well_id)
    and h.status in ('confirmed', 'settled');

  select coalesce(sum(d.outstanding_minor),0)::bigint into v_debt
  from billing.session_economic_settlements d join ops.irrigation_sessions s on s.id=d.session_id
  where s.collector_profile_id = p_profile_id
    and (p_well_id is null or s.well_id = p_well_id);

  select coalesce(sum(finance.cashbox_balance_minor(c.id)), 0) into v_custody
  from finance.cashboxes c
  where c.cashbox_type = 'operator_custody'
    and c.status = 'active'
    and c.assigned_profile_id = p_profile_id
    and (p_well_id is null or c.well_id = p_well_id);

  return jsonb_build_object(
    'profile_id', p_profile_id,
    'shifts_count', v_shifts,
    'collected_minor', v_collected,
    'expenses_minor', v_expenses,
    'handed_over_minor', v_handed,
    'farmer_debt_minor', greatest(v_debt, 0),
    'unsettled_minor', v_custody,
    'custody_minor', v_custody
  );
end;
$$;

create function billing.issue_session_invoice_result(p_session uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare well uuid;tenant uuid;iv uuid;amount bigint;st text;begin
 if auth.uid() is null then raise exception 'authentication_required' using errcode='28000';end if;
 select s.well_id,w.tenant_id into well,tenant from ops.irrigation_sessions s join core.wells w on w.id=s.well_id where s.id=p_session;
 if well is null or not exists(select 1 from core.well_assignments a where a.well_id=well and a.profile_id=auth.uid() and a.status='active')
 or not coalesce(iam.has_well_permission(well,'invoice.issue'),false) then raise exception 'invoice_forbidden' using errcode='42501';end if;
 perform billing.enter_financial_write(well,'invoice.issue',null,tenant);
 select status into st from ops.irrigation_sessions where id=p_session and well_id=well for update;
 if st not in('closed','forgotten') then return jsonb_build_object('contract','issue_session_invoice_result','version',1,'status','validation_error','invoice_id',null);end if;
 select id into iv from billing.invoices where session_id=p_session and status not in('cancelled','reversed');
 if iv is not null then return jsonb_build_object('contract','issue_session_invoice_result','version',1,'status','already_issued','invoice_id',iv);end if;
 select amount_minor into amount from billing.approved_session_charges where session_id=p_session;
 if amount is null then return jsonb_build_object('contract','issue_session_invoice_result','version',1,'status','validation_error','invoice_id',null);end if;
 if amount=0 then return jsonb_build_object('contract','issue_session_invoice_result','version',1,'status','not_required_zero_effective','invoice_id',null);end if;
 if st<>'closed' or (select pricing_mode from billing.approved_session_charges where session_id=p_session)<>'segments' then
  return jsonb_build_object('contract','issue_session_invoice_result','version',1,'status','financial_review_required','invoice_id',null,'reason_code','invoice_evidence_unavailable');end if;
 iv:=billing.issue_session_invoice(p_session,auth.uid());
 return jsonb_build_object('contract','issue_session_invoice_result','version',1,'status','issued','invoice_id',iv);
end;$$;
create function api.issue_session_invoice_result(p_session_id uuid) returns jsonb
language sql volatile security invoker set search_path=pg_catalog,pg_temp as $$select billing.issue_session_invoice_result(p_session_id);$$;

-- History inherits the canonical session/invoice read scope, with no client DML.
alter table billing.session_financial_adjustments enable row level security;
alter table billing.invoice_financial_adjustments enable row level security;
alter table billing.session_financial_resolution_links enable row level security;
alter table billing.session_invoice_financial_snapshots enable row level security;
create policy manual_approval_read on billing.session_financial_adjustments for select to authenticated
 using(exists(select 1 from billing.session_charges ch where ch.id=session_charge_id and ch.session_id=session_financial_adjustments.session_id and ch.well_id=session_financial_adjustments.well_id));
create policy manual_invoice_read on billing.invoice_financial_adjustments for select to authenticated
 using(exists(select 1 from billing.invoices i where i.id=invoice_id));
create policy manual_resolution_read on billing.session_financial_resolution_links for select to authenticated
 using(exists(select 1 from billing.session_financial_adjustments a where a.id=adjustment_id));
create policy manual_snapshot_read on billing.session_invoice_financial_snapshots for select to authenticated
 using(exists(select 1 from billing.invoices i where i.id=invoice_id and i.session_id=session_invoice_financial_snapshots.session_id));
revoke all on billing.session_financial_adjustments,billing.invoice_financial_adjustments,billing.session_financial_resolution_links,
 billing.session_invoice_financial_snapshots,billing.approved_session_charges from public,anon,authenticated,service_role;
grant select on billing.session_financial_adjustments,billing.invoice_financial_adjustments,billing.session_financial_resolution_links,
 billing.session_invoice_financial_snapshots,billing.approved_session_charges to authenticated,service_role;
revoke all on function billing.reject_manual_financial_history_change(),billing.manual_financial_session_scope(uuid),
 billing.manual_financial_posting_context(uuid),billing.establish_paired_system_basis(uuid,uuid,timestamptz),
 billing.validate_manual_financial_approval(uuid),billing.check_manual_approval_row(),billing.check_manual_invoice_row(),billing.check_manual_resolution_row()
 from public,anon,authenticated,service_role;
revoke all on function billing.apply_manual_session_approval(uuid,uuid,bigint,bigint,bigint,bigint,text,timestamptz),
 billing.read_manual_session_financial_state(uuid),billing.read_manual_financial_receipt(uuid,uuid),billing.issue_session_invoice_result(uuid)
 from public,anon,authenticated,service_role;
grant execute on function billing.apply_manual_session_approval(uuid,uuid,bigint,bigint,bigint,bigint,text,timestamptz),
 billing.read_manual_session_financial_state(uuid),billing.read_manual_financial_receipt(uuid,uuid),billing.issue_session_invoice_result(uuid)
 to authenticated,service_role;
revoke all on function api.adjust_session_financial_amount(uuid,uuid,bigint,bigint,bigint,bigint,text,timestamptz),
 api.get_session_financial_state(uuid),api.get_session_financial_adjustment_capability(uuid),
 api.get_session_financial_adjustment_receipt(uuid,uuid),api.issue_session_invoice_result(uuid) from public,anon,authenticated,service_role;
grant execute on function api.adjust_session_financial_amount(uuid,uuid,bigint,bigint,bigint,bigint,text,timestamptz),
 api.get_session_financial_state(uuid),api.get_session_financial_adjustment_capability(uuid),
 api.get_session_financial_adjustment_receipt(uuid,uuid),api.issue_session_invoice_result(uuid) to authenticated,service_role;

-- Coverage also attaches to the system writer: a missing link cannot evade the
-- approval-table triggers by advancing C2 directly under an older approval.
create function billing.check_system_manual_coverage() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare approval uuid;begin
 if exists(select 1 from billing.session_financial_adjustments a where a.session_id=new.session_id
  and a.applied_system_financial_revision<new.operational_revision) then
  select adjustment_id into approval from billing.session_financial_resolution_links where correction_id=new.correction_id;
  if approval is null then raise exception 'paired_system_coverage_missing' using errcode='23514';end if;
  perform billing.validate_manual_financial_approval(approval);
 end if;return null;end;$$;
create constraint trigger system_manual_coverage after insert on billing.session_charge_corrections
 deferrable initially deferred for each row execute function billing.check_system_manual_coverage();
create function billing.check_invoice_financial_snapshot() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare system_amount bigint;effective bigint;basis bigint;iv billing.invoices%rowtype;n bigint;d bigint;begin
 select * into strict iv from billing.invoices where id=new.invoice_id;
 if iv.session_id is distinct from new.session_id or iv.total_minor<>new.effective_amount_minor then
  raise exception 'invoice_financial_snapshot_scope_invalid' using errcode='23514';end if;
 if new.system_financial_revision=0 then select amount_minor into system_amount from billing.session_charges where session_id=new.session_id;
 else select new_amount_minor into system_amount from billing.session_charge_corrections where session_id=new.session_id and operational_revision=new.system_financial_revision;end if;
 if new.manual_approval_revision=0 then effective:=system_amount;
 else select approved_amount_minor,applied_system_financial_revision into effective,basis from billing.session_financial_adjustments
  where session_id=new.session_id and manual_approval_revision=new.manual_approval_revision;
  if basis is distinct from new.system_financial_revision then raise exception 'invoice_approval_basis_invalid' using errcode='23514';end if;
 end if;
 if system_amount is distinct from new.system_amount_minor or effective is distinct from new.effective_amount_minor then
  raise exception 'invoice_financial_snapshot_amount_invalid' using errcode='23514';end if;
 select count(*),coalesce(sum(amount_minor),0) into n,d from billing.invoice_lines where invoice_id=new.invoice_id and line_type='manual_adjustment';
 if n<>(case when new.carry_in_minor=0 then 0 else 1 end) or d<>new.carry_in_minor then
  raise exception 'invoice_carry_in_coverage_invalid' using errcode='23514';end if;
 return null;end;$$;
create constraint trigger invoice_financial_snapshot_complete after insert on billing.session_invoice_financial_snapshots
 deferrable initially deferred for each row execute function billing.check_invoice_financial_snapshot();
revoke all on function billing.check_system_manual_coverage(),billing.check_invoice_financial_snapshot() from public,anon,authenticated,service_role;
-- Replaced trigger/read helpers retain legitimate authenticated callers only.
revoke all on function billing.journalize_invoice() from public,anon,authenticated,service_role;
revoke all on function ops.shift_report(uuid),ops.operator_totals(uuid,uuid) from public,anon;
grant execute on function ops.shift_report(uuid),ops.operator_totals(uuid,uuid) to authenticated,service_role;
commit;

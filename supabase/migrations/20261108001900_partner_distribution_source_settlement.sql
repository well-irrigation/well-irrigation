-- R6-C2B exact source authority. Static implementation; owner DB verification pending.
-- Requires the coordinated financial boundary follow-ups 020 through 024.
begin;

create or replace function billing.require_customer_credit_well_lock(p_well uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare key bigint:=hashtextextended('customer-credit-well:'||p_well::text,0);
begin
 if p_well is null or current_setting('transaction_isolation')<>'read committed' or not exists(
  select 1 from pg_locks l where l.locktype='advisory' and l.pid=pg_backend_pid() and l.granted and l.mode='ExclusiveLock'
   and l.database=(select oid from pg_database where datname=current_database())
   and l.classid::bigint=((key>>32)&4294967295::bigint) and l.objid::bigint=(key&4294967295::bigint) and l.objsubid=1) then
  raise exception 'financial_well_boundary_required' using errcode='55000';end if;
end;$$;
revoke all on function billing.require_customer_credit_well_lock(uuid) from public,anon,authenticated,service_role;
-- Future exact distribution use; legacy aggregates are never source evidence.
create table finance.distribution_sources(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references core.tenants(id),
 well_id uuid not null references core.wells(id),partner_id uuid not null references core.well_partners(id),
 expense_id uuid unique references finance.expenses(id),invoice_id uuid unique references billing.invoices(id),
 original_amount_minor bigint not null check(original_amount_minor>0),
 legacy_review_required boolean not null,created_at timestamptz not null default clock_timestamp(),
 check(num_nonnulls(expense_id,invoice_id)=1)
);
create table finance.distribution_source_reviews(
 id uuid primary key default gen_random_uuid(),source_id uuid not null unique references finance.distribution_sources(id),
 confirmed_consumed_minor bigint not null check(confirmed_consumed_minor>=0),
 confirmed_remaining_minor bigint not null check(confirmed_remaining_minor>=0),
 original_amount_minor bigint not null check(original_amount_minor=confirmed_consumed_minor+confirmed_remaining_minor),
 historical_cycles jsonb not null,reason text not null check(nullif(btrim(reason),'') is not null),
 actor_id uuid not null references iam.profiles(id),accepted_at timestamptz not null default clock_timestamp()
);
create table finance.distribution_source_selections(
 id uuid primary key default gen_random_uuid(),source_id uuid not null references finance.distribution_sources(id),
 cycle_id uuid not null references finance.profit_distribution_cycles(id),line_id uuid not null references finance.profit_distribution_lines(id),
 sequence bigint not null check(sequence>0),previous_id uuid references finance.distribution_source_selections(id),
 mode text not null check(mode in ('automatic','manual_partial')),amount_minor bigint not null check(amount_minor>=0),
 reason text,actor_id uuid references iam.profiles(id),accepted_at timestamptz not null default clock_timestamp(),
 check(mode='automatic' or(amount_minor>0 and nullif(btrim(reason),'') is not null and actor_id is not null)),
 unique(cycle_id,source_id,sequence)
);
create table finance.distribution_source_consumptions(
 id uuid primary key default gen_random_uuid(),source_id uuid not null references finance.distribution_sources(id),
 tenant_id uuid not null references core.tenants(id),well_id uuid not null references core.wells(id),partner_id uuid not null references core.well_partners(id),
 settlement_kind text not null default 'distribution' check(settlement_kind in ('distribution','standalone_payment')),
 command_id uuid,journal_entry_id uuid references finance.journal_entries(id),request_payload jsonb,result_payload jsonb,
 invoice_id uuid references billing.invoices(id),expense_id uuid references finance.expenses(id),
 cycle_id uuid references finance.profit_distribution_cycles(id),line_id uuid references finance.profit_distribution_lines(id),
 selection_id uuid unique references finance.distribution_source_selections(id),
 amount_minor bigint not null check(amount_minor>0),eligible_amount_snapshot_minor bigint not null check(eligible_amount_snapshot_minor>=amount_minor),
 available_snapshot_minor bigint not null check(available_snapshot_minor>=amount_minor and available_snapshot_minor<=eligible_amount_snapshot_minor),
 actor_id uuid not null references iam.profiles(id),accepted_at timestamptz not null default clock_timestamp(),
 check(num_nonnulls(invoice_id,expense_id)=1),unique(cycle_id,source_id),unique(tenant_id,command_id),
 check((settlement_kind='distribution' and cycle_id is not null and line_id is not null and selection_id is not null and command_id is null)
  or(settlement_kind='standalone_payment' and cycle_id is null and line_id is null and selection_id is null
   and expense_id is not null and invoice_id is null and command_id is not null and journal_entry_id is not null and request_payload is not null and result_payload is not null))
);
create index distribution_selection_current_idx on finance.distribution_source_selections(cycle_id,source_id,sequence desc);
create index distribution_consumption_source_idx on finance.distribution_source_consumptions(source_id);
create index distribution_consumption_invoice_idx on finance.distribution_source_consumptions(invoice_id) where invoice_id is not null;
create function finance.reject_distribution_source_history_mutation() returns trigger language plpgsql set search_path=pg_catalog,pg_temp as $$
begin raise exception 'distribution_source_history_append_only' using errcode='23514';end;$$;
do $install$ declare rel text;begin
 foreach rel in array array['distribution_sources','distribution_source_reviews','distribution_source_selections','distribution_source_consumptions'] loop
  execute format('alter table finance.%I enable row level security',rel);
  execute format('revoke all on finance.%I from public,anon,authenticated,service_role',rel);
  execute format('grant select on finance.%I to authenticated,service_role',rel);
  execute format('create trigger distribution_source_history_immutable before update or delete on finance.%I for each row execute function finance.reject_distribution_source_history_mutation()',rel);
 end loop;
end;$install$;
create policy distribution_source_read on finance.distribution_sources for select using
 (iam.has_well_role(well_id,array['owner','manager','operator']) or iam.is_well_partner(well_id)
 or exists(select 1 from billing.invoices i where i.id=invoice_id));
create policy distribution_review_read on finance.distribution_source_reviews for select using
 (exists(select 1 from finance.distribution_sources s where s.id=source_id));
create policy distribution_selection_read on finance.distribution_source_selections for select using
 (exists(select 1 from finance.distribution_sources s where s.id=source_id));
create policy distribution_consumption_read on finance.distribution_source_consumptions for select using
 (exists(select 1 from finance.distribution_sources s where s.id=source_id));
create view finance.current_distribution_source_selections with(security_invoker=true) as
 select distinct on(cycle_id,source_id) * from finance.distribution_source_selections order by cycle_id,source_id,sequence desc;
grant select on finance.current_distribution_source_selections to authenticated,service_role;

-- Private discovery/registration. Caller already owns the well financial root.
create function finance.register_distribution_source(p_expense uuid,p_invoice uuid) returns uuid
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare e finance.expenses%rowtype;i billing.invoices%rowtype;s finance.distribution_sources%rowtype;
 tenant uuid;well uuid;partner uuid;amount bigint;legacy boolean;sid uuid;
begin
 if num_nonnulls(p_expense,p_invoice)<>1 then raise exception 'distribution_source_identity_required' using errcode='22023';end if;
 select * into s from finance.distribution_sources where expense_id=p_expense or invoice_id=p_invoice;
 if found then return s.id;end if;
 if p_expense is not null then
  select * into strict e from finance.expenses where id=p_expense;
  if e.status<>'posted' or e.payment_source<>'partner_paid' or e.partner_id is null or not exists(
   select 1 from finance.journal_entries j where j.id=e.journal_entry_id and j.well_id=e.well_id and j.tenant_id=e.tenant_id
    and j.status='posted' and j.source_type='expense' and j.source_id=e.id
    and(select coalesce(sum(l.amount_minor),0) from finance.journal_lines l join finance.ledger_accounts a on a.id=l.ledger_account_id
     where l.journal_entry_id=j.id and l.partner_id=e.partner_id and l.entry_side='credit' and a.account_code='2400')=e.amount_minor) then raise exception 'distribution_source_ineligible' using errcode='23514';end if;
  tenant:=e.tenant_id;well:=e.well_id;partner:=e.partner_id;amount:=e.amount_minor;
  legacy:=e.settled_in_cycle_id is not null or exists(select 1 from finance.profit_distribution_cycles c
   where c.well_id=well and c.status in ('approved','partially_paid','paid') and e.spent_at<c.period_end);
 else
  select * into strict i from billing.invoices where id=p_invoice;
  select p.partner_id into partner from core.partner_irrigation_policies p where p.id=i.partner_policy_id and p.well_id=i.well_id and p.tenant_id=i.tenant_id
   and p.policy_type='deduct_from_profit';
  if partner is null or i.status not in ('issued','partially_paid','overdue') then raise exception 'distribution_source_ineligible' using errcode='23514';end if;
  tenant:=i.tenant_id;well:=i.well_id;select total_minor into amount from billing.effective_invoice_totals where id=i.id;
  legacy:=i.deducted_in_cycle_id is not null or exists(select 1 from finance.profit_distribution_cycles c
   where c.well_id=well and c.status in ('approved','partially_paid','paid') and i.invoice_date<c.period_end);
 end if;
 if not exists(select 1 from core.well_partners p where p.id=partner and p.well_id=well and p.tenant_id=tenant) then
  raise exception 'distribution_source_scope_invalid' using errcode='23514';end if;
 perform billing.require_customer_credit_well_lock(well);
 insert into finance.distribution_sources(tenant_id,well_id,partner_id,expense_id,invoice_id,original_amount_minor,legacy_review_required)
 values(tenant,well,partner,p_expense,p_invoice,amount,legacy) returning id into sid;
 return sid;
end;$$;

create function finance.distribution_source_availability(p_source uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare s finance.distribution_sources%rowtype;e finance.expenses%rowtype;i billing.invoices%rowtype;
 reviewed boolean;baseline bigint:=0;used bigint:=0;remaining bigint:=0;original bigint;status text:='available';outside_distribution boolean:=false;
begin
 select * into strict s from finance.distribution_sources where id=p_source;original:=s.original_amount_minor;
 if not exists(select 1 from core.wells where id=s.well_id and tenant_id=s.tenant_id) then raise exception 'distribution_source_scope_invalid' using errcode='23514';end if;
 if s.expense_id is not null then
  select * into strict e from finance.expenses where id=s.expense_id;
  if(e.well_id,e.tenant_id,e.partner_id) is distinct from(s.well_id,s.tenant_id,s.partner_id)
   or e.payment_source<>'partner_paid' or e.status<>'posted' or e.amount_minor<>s.original_amount_minor
   or not exists(select 1 from finance.journal_entries j where j.id=e.journal_entry_id and j.status='posted' and j.source_type='expense' and j.source_id=e.id) then status:='unavailable';end if;
  select confirmed_consumed_minor into baseline from finance.distribution_source_reviews where source_id=s.id;reviewed:=found;
  select coalesce(sum(amount_minor),0) into used from finance.distribution_source_consumptions where source_id=s.id;
  used:=used+coalesce(baseline,0);remaining:=greatest(original-used,0);
  outside_distribution:=exists(select 1 from core.well_partners p where p.id=s.partner_id and p.well_id=s.well_id
   and(p.status='left' or p.left_at is not null) and not exists(select 1 from core.ownership_share_versions v where v.partner_id=p.id and v.well_id=p.well_id
    and(v.ownership_percentage>0 or v.profit_percentage>0) and v.effective_period @> (clock_timestamp() at time zone core.well_timezone(p.well_id))::date));
 else
  select * into strict i from billing.invoices where id=s.invoice_id;
  if(i.well_id,i.tenant_id) is distinct from(s.well_id,s.tenant_id) or i.status not in ('issued','partially_paid','overdue')
   or not exists(select 1 from core.partner_irrigation_policies p where p.id=i.partner_policy_id and p.partner_id=s.partner_id
     and p.well_id=s.well_id and p.tenant_id=s.tenant_id and p.policy_type='deduct_from_profit') then status:='unavailable';end if;
  reviewed:=exists(select 1 from billing.legacy_invoice_accounting_resolutions r where r.invoice_id=i.id);
  select total_minor,collectible_minor into original,remaining from billing.invoice_effective_balances where invoice_id=i.id;
  -- Canonical invoice debt already includes cash, credit and the non-cash
  -- consumption below; never subtract a second distribution shadow balance.
  used:=greatest(original-greatest(remaining,0),0);
  if exists(select 1 from billing.legacy_invoice_review_effects where invoice_id=i.id and disputed_minor>0) then status:='review_required';end if;
 end if;
 if s.legacy_review_required and not coalesce(reviewed,false) then status:='review_required';end if;
 if status<>'available' then remaining:=0;end if;
 return jsonb_build_object('source_id',s.id,'source_type',case when s.expense_id is not null then 'payable_expense' else 'receivable_invoice' end,
  'partner_id',s.partner_id,'well_id',s.well_id,'status',status,'available_in_distribution',not outside_distribution,
  'settlement_route',case when outside_distribution then 'standalone_payment' else 'distribution' end,'original_amount_minor',s.original_amount_minor,'effective_amount_minor',original,
  'standalone_paid_amount_minor',(select coalesce(sum(amount_minor),0) from finance.distribution_source_consumptions where source_id=s.id and settlement_kind='standalone_payment'),
  'distribution_used_amount_minor',(select coalesce(sum(amount_minor),0) from finance.distribution_source_consumptions where source_id=s.id and settlement_kind='distribution')
   +case when s.invoice_id is null then coalesce(baseline,0) else coalesce((select settlement_amount_minor from billing.legacy_invoice_accounting_resolutions where invoice_id=s.invoice_id),0) end,
  'used_amount_minor',case when status='review_required' then null else used end,
  'remaining_amount_minor',case when status='review_required' then null else greatest(coalesce(remaining,0),0) end,'title',case when status='review_required' then 'يحتاج هذا المبلغ إلى مراجعة'
   when remaining<=0 then 'تم استخدام هذا المبلغ بالكامل' when outside_distribution then 'مستحق يُسدَّد خارج التوزيع' else 'مستحق مسجل للشريك' end,
  'message',case when status='review_required' then 'يوجد توزيع سابق مرتبط بهذا المبلغ. راجع المبلغ المستخدم سابقًا قبل استخدامه مرة أخرى.'
   when remaining<=0 then 'لا يوجد مبلغ متبقٍ يمكن استخدامه في هذا التوزيع.' when outside_distribution then 'هذا مستحق سابق لشريك خرج. سجّل سداده من إجراء سداد المستحقات.' else 'المبلغ المتاح محسوب بعد الاستخدامات السابقة.' end,
  'action',case when status='review_required' then 'مراجعة المبلغ' when outside_distribution then 'تسجيل سداد المستحق' else 'عرض التفاصيل' end);
end;$$;

create function api.review_legacy_partner_expense_source(p_source_id uuid,p_consumed_minor bigint,p_reason text) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate finance.distribution_sources%rowtype;s finance.distribution_sources%rowtype;prior finance.distribution_source_reviews%rowtype;cycles jsonb;
begin
 select * into candidate from finance.distribution_sources where id=p_source_id;
 if candidate.id is null or auth.uid() is null or not coalesce(iam.has_well_role(candidate.well_id,array['owner']),false) then
  raise exception 'distribution_owner_required' using errcode='42501';end if;
 perform billing.lock_customer_credit_well(candidate.well_id);
 perform ops.lock_operational_scope(candidate.well_id);
 select * into strict s from finance.distribution_sources where id=p_source_id for update;
 perform 1 from finance.expenses where id=s.expense_id and well_id=s.well_id and tenant_id=s.tenant_id and partner_id=s.partner_id
  and status='posted' and payment_source='partner_paid' and amount_minor=s.original_amount_minor for update;
 if not found or(s.well_id,s.tenant_id,s.expense_id) is distinct from(candidate.well_id,candidate.tenant_id,candidate.expense_id)
  or not coalesce(iam.has_well_role(s.well_id,array['owner']),false) then raise exception 'distribution_owner_required' using errcode='42501';end if;
 if not s.legacy_review_required or p_consumed_minor is null or p_consumed_minor<0 or p_consumed_minor>s.original_amount_minor
  or nullif(btrim(p_reason),'') is null then raise exception 'distribution_source_review_invalid' using errcode='22023';end if;
 select * into prior from finance.distribution_source_reviews where source_id=s.id;
 if found then
  if prior.confirmed_consumed_minor<>p_consumed_minor or prior.reason<>p_reason then raise exception 'distribution_source_review_conflict' using errcode='23514';end if;
  return finance.distribution_source_availability(s.id);
 end if;
 select coalesce(jsonb_agg(to_jsonb(c) order by c.id),'[]'::jsonb) into cycles from finance.profit_distribution_cycles c
  where c.well_id=s.well_id and c.status in ('approved','partially_paid','paid');
 insert into finance.distribution_source_reviews(source_id,confirmed_consumed_minor,confirmed_remaining_minor,original_amount_minor,historical_cycles,reason,actor_id)
 values(s.id,p_consumed_minor,s.original_amount_minor-p_consumed_minor,s.original_amount_minor,cycles,p_reason,auth.uid());
 return finance.distribution_source_availability(s.id);
end;$$;

-- Read-only canonical eligibility, including quarantine for unregistered
-- legacy sources. Never register a source or guess consumption on a UI read.
create function finance.partner_invoice_source_available(p_invoice uuid,p_well uuid,p_partner uuid) returns bigint
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare i billing.invoices%rowtype;s finance.distribution_sources%rowtype;legacy boolean;remaining bigint;
begin
 select * into i from billing.invoices where id=p_invoice;
 if i.id is null or i.well_id<>p_well or i.status not in ('issued','partially_paid','overdue') or not exists(
  select 1 from core.partner_irrigation_policies p where p.id=i.partner_policy_id and p.partner_id=p_partner
   and p.well_id=i.well_id and p.tenant_id=i.tenant_id and p.policy_type='deduct_from_profit') then return 0;end if;
 select * into s from finance.distribution_sources where invoice_id=i.id;
 if found then legacy:=s.legacy_review_required;
 else legacy:=i.deducted_in_cycle_id is not null or exists(select 1 from finance.profit_distribution_cycles c
  where c.well_id=i.well_id and c.status in ('approved','partially_paid','paid') and i.invoice_date<c.period_end);end if;
 if legacy and not exists(select 1 from billing.legacy_invoice_accounting_resolutions where invoice_id=i.id) then return 0;end if;
 if exists(select 1 from billing.legacy_invoice_review_effects where invoice_id=i.id and disputed_minor>0) then return 0;end if;
 select collectible_minor into remaining from billing.invoice_effective_balances where invoice_id=i.id;
 return greatest(coalesce(remaining,0),0);
end;$$;

create function finance.distribution_invoice_selection_state(p_source uuid,p_cycle uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare s finance.distribution_sources%rowtype;c finance.profit_distribution_cycles%rowtype;i billing.invoices%rowtype;
 older uuid;available bigint;budget bigint;
begin
 select * into strict s from finance.distribution_sources where id=p_source;
 select * into strict c from finance.profit_distribution_cycles where id=p_cycle;
 select * into i from billing.invoices where id=s.invoice_id;
 if i.id is null or(s.well_id,s.tenant_id) is distinct from(c.well_id,c.tenant_id) then
  raise exception 'distribution_source_scope_invalid' using errcode='23514';end if;
 select x.id into older from billing.invoices x join core.partner_irrigation_policies p on p.id=x.partner_policy_id
  where x.well_id=c.well_id and x.tenant_id=c.tenant_id and p.partner_id=s.partner_id
   and p.well_id=c.well_id and p.tenant_id=c.tenant_id and p.policy_type='deduct_from_profit'
   and x.invoice_date<c.period_end and(x.invoice_date,x.id)<(i.invoice_date,i.id)
   and finance.partner_invoice_source_available(x.id,c.well_id,s.partner_id)>0 order by x.invoice_date,x.id limit 1;
 available:=finance.partner_invoice_source_available(i.id,c.well_id,s.partner_id);
 select l.gross_share_minor+coalesce((select sum(case when not coalesce((finance.distribution_source_availability(src.id)->>'available_in_distribution')::boolean,true) then 0
   when x.mode='manual_partial' then x.amount_minor
   else coalesce((finance.distribution_source_availability(src.id)->>'remaining_amount_minor')::bigint,0) end)
  from finance.current_distribution_source_selections x join finance.distribution_sources src on src.id=x.source_id
  where x.line_id=l.id and x.cycle_id=c.id and src.expense_id is not null),0)
 into budget from finance.profit_distribution_lines l where l.distribution_cycle_id=c.id and l.partner_id=s.partner_id;
 return jsonb_build_object('status',case when older is not null then 'review_required' else 'available' end,
  'blocked_by_older_debt',older is not null,'older_invoice_id',older,
  'maximum_manual_minor',case when older is not null then 0 else least(available,greatest(coalesce(budget,0),0)) end,
  'title',case when older is not null then 'يوجد مبلغ أقدم يجب تسويته أولًا' else 'المبلغ المتاح للاستخدام' end,
  'message',case when older is not null then 'لا يمكن استخدام هذه الفاتورة الآن لأن هناك مبلغًا أقدم مستحقًا. راجع المبلغ المتاح بعد تسوية الأقدم.' else 'اختر مبلغًا ضمن المتاح لهذه الدورة.' end,
  'action','مراجعة المبالغ');
end;$$;

create function finance.require_distribution_invoice_selection(p_source uuid,p_cycle uuid,p_amount bigint) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare state jsonb;
begin
 perform billing.require_customer_credit_well_lock((select well_id from finance.profit_distribution_cycles where id=p_cycle));
 state:=finance.distribution_invoice_selection_state(p_source,p_cycle);
 if(state->>'blocked_by_older_debt')::boolean then
  raise exception 'distribution_older_debt_requires_settlement' using errcode='23514',detail=state::text;end if;
 if p_amount is null or p_amount<=0 or p_amount>(state->>'maximum_manual_minor')::bigint then
  raise exception 'distribution_source_amount_unavailable' using errcode='23514',detail=state::text;end if;
end;$$;

create function finance.ensure_distribution_invoice_candidates(p_cycle uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c finance.profit_distribution_cycles%rowtype;l record;r record;sid uuid;
begin
 perform billing.require_customer_credit_well_lock((select well_id from finance.profit_distribution_cycles where id=p_cycle));
 select * into strict c from finance.profit_distribution_cycles where id=p_cycle;
 for l in select * from finance.profit_distribution_lines where distribution_cycle_id=c.id order by id for update loop
  for r in select i.id from billing.invoices i join core.partner_irrigation_policies p on p.id=i.partner_policy_id
   join billing.invoice_effective_balances b on b.invoice_id=i.id
   where i.well_id=c.well_id and i.tenant_id=c.tenant_id and p.well_id=c.well_id and p.tenant_id=c.tenant_id
    and p.partner_id=l.partner_id and p.policy_type='deduct_from_profit'
    and i.status in ('issued','partially_paid','overdue') and i.invoice_date<c.period_end and b.collectible_minor>0
   order by i.invoice_date,i.id loop
   sid:=finance.register_distribution_source(null,r.id);
   if not exists(select 1 from finance.current_distribution_source_selections x where x.cycle_id=c.id and x.source_id=sid) then
    insert into finance.distribution_source_selections(source_id,cycle_id,line_id,sequence,mode,amount_minor,actor_id)
    values(sid,c.id,l.id,1,'automatic',0,auth.uid());end if;
  end loop;
 end loop;
end;$$;

create function finance.rederive_distribution_source_lines(p_cycle uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c finance.profit_distribution_cycles%rowtype;l finance.profit_distribution_lines%rowtype;r record;a jsonb;
 pos bigint;neg bigint;budget bigint;wanted bigint;available bigint;
begin
 perform billing.require_customer_credit_well_lock((select well_id from finance.profit_distribution_cycles where id=p_cycle));
 select * into strict c from finance.profit_distribution_cycles where id=p_cycle for update;
 if c.status not in ('calculated','under_review') then raise exception 'distribution_approved_no_changes' using errcode='23514';end if;
 perform finance.ensure_distribution_invoice_candidates(c.id);
 for l in select * from finance.profit_distribution_lines where distribution_cycle_id=c.id order by id for update loop
  pos:=0;neg:=0;
  for r in select x.*,s.expense_id,s.invoice_id from finance.current_distribution_source_selections x
   join finance.distribution_sources s on s.id=x.source_id where x.cycle_id=c.id and x.line_id=l.id
   order by s.id loop
   a:=finance.distribution_source_availability(r.source_id);available:=case when coalesce((a->>'available_in_distribution')::boolean,true) then coalesce((a->>'remaining_amount_minor')::bigint,0) else 0 end;
   if r.mode='manual_partial' and (a->>'status'<>'available' or r.amount_minor>available) then
    raise exception 'distribution_source_requires_review' using errcode='23514',detail='{"status":"review_required","title":"هذا المبلغ لم يعد متاحًا بالكامل","message":"تم استخدام جزء منه أو كله في عملية أخرى. راجع المبلغ المتاح قبل المتابعة.","action":"مراجعة التعديل"}';end if;
   if r.expense_id is not null then
    wanted:=case when r.mode='manual_partial' then r.amount_minor else available end;
    pos:=pos+wanted;
    if wanted<>r.amount_minor then
     insert into finance.distribution_source_selections(source_id,cycle_id,line_id,sequence,previous_id,mode,amount_minor,actor_id)
     values(r.source_id,c.id,l.id,r.sequence+1,r.id,'automatic',wanted,auth.uid());end if;
   end if;
  end loop;
  budget:=l.gross_share_minor+pos;
  if budget<0 then raise exception 'distribution_adjustment_exceeds_share' using errcode='23514',detail='{"status":"review_required","title":"راجع مبلغ الخصم","message":"المبلغ المطلوب أكبر من المتاح لهذا الشريك في الدورة الحالية.","action":"مراجعة التعديل"}';end if;
  -- Manual use can cap the oldest source, but cannot reserve a newer one.
  -- A partial oldest source leaves later invoices unused in this cycle.
  for r in select x.*,i.invoice_date from finance.current_distribution_source_selections x
   join finance.distribution_sources s on s.id=x.source_id join billing.invoices i on i.id=s.invoice_id
   where x.cycle_id=c.id and x.line_id=l.id order by i.invoice_date,i.id loop
   a:=finance.distribution_source_availability(r.source_id);available:=case when coalesce((a->>'available_in_distribution')::boolean,true) then coalesce((a->>'remaining_amount_minor')::bigint,0) else 0 end;
   if r.mode='manual_partial' then
    perform finance.require_distribution_invoice_selection(r.source_id,c.id,r.amount_minor);
    wanted:=r.amount_minor;
   else wanted:=least(budget,available);end if;
   if wanted>budget then raise exception 'distribution_adjustment_exceeds_share' using errcode='23514';end if;
   neg:=neg+wanted;budget:=budget-wanted;
   if wanted<available then budget:=0;end if;
   if wanted<>r.amount_minor then
    insert into finance.distribution_source_selections(source_id,cycle_id,line_id,sequence,previous_id,mode,amount_minor,actor_id)
    values(r.source_id,c.id,l.id,r.sequence+1,r.id,'automatic',wanted,auth.uid());end if;
  end loop;
  update finance.profit_distribution_lines set partner_receivables_minor=pos,irrigation_deductions_minor=neg,
   other_deductions_minor=0,net_payable_minor=gross_share_minor+pos-neg where id=l.id;
 end loop;
end;$$;

create function finance.prepare_distribution_source_selections(p_cycle uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c finance.profit_distribution_cycles%rowtype;l record;r record;sid uuid;
begin
 perform billing.require_customer_credit_well_lock((select well_id from finance.profit_distribution_cycles where id=p_cycle));
 select * into strict c from finance.profit_distribution_cycles where id=p_cycle for update;
 for l in select * from finance.profit_distribution_lines where distribution_cycle_id=c.id order by id for update loop
  for r in select e.id from finance.expenses e where e.well_id=c.well_id and e.tenant_id=c.tenant_id and e.partner_id=l.partner_id
   and e.payment_source='partner_paid' and e.status='posted' and e.spent_at<c.period_end order by e.id loop
   sid:=finance.register_distribution_source(r.id,null);
   insert into finance.distribution_source_selections(source_id,cycle_id,line_id,sequence,mode,amount_minor,actor_id)
   values(sid,c.id,l.id,1,'automatic',0,auth.uid());
  end loop;
  for r in select i.id from billing.invoices i join core.partner_irrigation_policies p on p.id=i.partner_policy_id
   where i.well_id=c.well_id and i.tenant_id=c.tenant_id and p.well_id=c.well_id and p.tenant_id=c.tenant_id
    and p.partner_id=l.partner_id and p.policy_type='deduct_from_profit'
    and i.status in ('issued','partially_paid','overdue') and i.invoice_date<c.period_end
    and(exists(select 1 from finance.distribution_sources src where src.invoice_id=i.id)
     or exists(select 1 from billing.invoice_effective_balances b where b.invoice_id=i.id and b.collectible_minor>0))
   order by i.invoice_date,i.id loop
   sid:=finance.register_distribution_source(null,r.id);
   insert into finance.distribution_source_selections(source_id,cycle_id,line_id,sequence,mode,amount_minor,actor_id)
   values(sid,c.id,l.id,1,'automatic',0,auth.uid());
  end loop;
 end loop;
 perform finance.rederive_distribution_source_lines(c.id);
end;$$;

create function api.select_partner_distribution_source(p_cycle_id uuid,p_source_id uuid,p_amount_minor bigint,p_reason text)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate finance.profit_distribution_cycles%rowtype;c finance.profit_distribution_cycles%rowtype;
 s finance.distribution_sources%rowtype;x finance.distribution_source_selections%rowtype;a jsonb;next_id uuid:=gen_random_uuid();
begin
 select * into candidate from finance.profit_distribution_cycles where id=p_cycle_id;
 if candidate.id is null or auth.uid() is null or not coalesce(iam.has_well_role(candidate.well_id,array['owner']),false) then
  raise exception 'distribution_owner_required' using errcode='42501';end if;
 perform billing.lock_customer_credit_well(candidate.well_id);
 perform ops.lock_operational_scope(candidate.well_id);
 select * into strict c from finance.profit_distribution_cycles where id=p_cycle_id for update;
 if(c.well_id,c.tenant_id) is distinct from(candidate.well_id,candidate.tenant_id)
  or not coalesce(iam.has_well_role(c.well_id,array['owner']),false) then raise exception 'distribution_owner_required' using errcode='42501';end if;
 if c.status not in ('calculated','under_review') then raise exception 'distribution_approved_no_changes' using errcode='23514',detail='{"status":"not_available","title":"لا يمكن تعديل هذا التوزيع","message":"تم اعتماد هذا التوزيع، لذلك لا يمكن تغيير الخصومات أو المستحقات فيه.","action":"عرض التفاصيل"}';end if;
 -- Rederivation visits every line: lock all lines deterministically first.
 perform 1 from finance.profit_distribution_lines where distribution_cycle_id=c.id order by id for update;
 select * into s from finance.distribution_sources where id=p_source_id and well_id=c.well_id and tenant_id=c.tenant_id for update;
 if not found then raise exception 'distribution_source_scope_invalid' using errcode='23514';end if;
 select * into x from finance.current_distribution_source_selections where cycle_id=c.id and source_id=s.id;
 if x.id is null or(s.well_id,s.tenant_id) is distinct from(c.well_id,c.tenant_id)
  or not exists(select 1 from finance.profit_distribution_lines where id=x.line_id and distribution_cycle_id=c.id and partner_id=s.partner_id) then
  raise exception 'distribution_source_scope_invalid' using errcode='23514';end if;
 if s.expense_id is not null then perform 1 from finance.expenses where id=s.expense_id for update;
 else perform 1 from billing.invoices where id=s.invoice_id for update;end if;
 a:=finance.distribution_source_availability(s.id);
 -- NULL is a deliberately distinct revert action used by the cancellation API.
 if p_amount_minor is not null and(p_amount_minor<=0 or p_amount_minor>(a->>'remaining_amount_minor')::bigint or a->>'status'<>'available' or not coalesce((a->>'available_in_distribution')::boolean,true)) then
  raise exception 'distribution_source_amount_unavailable' using errcode='23514',detail='{"status":"review_required","title":"هذا المبلغ لم يعد متاحًا بالكامل","message":"راجع المبلغ المتاح قبل حفظ التعديل.","action":"مراجعة التعديل"}';end if;
 if p_amount_minor is not null and s.invoice_id is not null then
  perform finance.require_distribution_invoice_selection(s.id,c.id,p_amount_minor);end if;
 if nullif(btrim(p_reason),'') is null then raise exception 'distribution_adjustment_reason_required' using errcode='22023';end if;
 insert into finance.distribution_source_selections(id,source_id,cycle_id,line_id,sequence,previous_id,mode,amount_minor,reason,actor_id)
 values(next_id,s.id,c.id,x.line_id,x.sequence+1,x.id,case when p_amount_minor is null then 'automatic' else 'manual_partial' end,
  coalesce(p_amount_minor,0),p_reason,auth.uid());
 perform finance.rederive_distribution_source_lines(c.id);
 return jsonb_build_object('status','saved','selection_id',next_id,'source',finance.distribution_source_availability(s.id),
  'mode',case when p_amount_minor is null then 'automatic' else 'manual_partial' end,'title','تم حفظ التعديل',
  'message',case when p_amount_minor is null then 'سيتم احتساب هذا المبلغ تلقائيًا.' else 'سيُستخدم هذا الجزء فقط في الدورة الحالية، وسيبقى الباقي متاحًا لاحقًا. لن يُحسب هذا المبلغ تلقائيًا مرة أخرى داخل هذه الدورة.' end,
  'action','مراجعة التوزيع');
end;$$;
create function api.add_partner_distribution_adjustment(p_cycle_id uuid,p_source_id uuid,p_type text,p_amount_minor bigint,p_reason text)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
begin
 if p_amount_minor is null or p_type is null or not exists(select 1 from finance.distribution_sources where id=p_source_id
  and((p_type='deduction' and invoice_id is not null) or(p_type='additional_entitlement' and expense_id is not null))) then
  raise exception 'distribution_adjustment_source_required' using errcode='22023';end if;
 return api.select_partner_distribution_source(p_cycle_id,p_source_id,p_amount_minor,p_reason);
end;$$;
create function finance.change_current_distribution_adjustment(p_adjustment uuid,p_amount bigint,p_reason text,p_cancel boolean) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare x finance.distribution_source_selections%rowtype;c finance.profit_distribution_cycles%rowtype;head uuid;
begin
 select * into strict x from finance.distribution_source_selections where id=p_adjustment;
 select * into strict c from finance.profit_distribution_cycles where id=x.cycle_id;
 if auth.uid() is null or not coalesce(iam.has_well_role(c.well_id,array['owner']),false) then raise exception 'distribution_owner_required' using errcode='42501';end if;
 perform billing.lock_customer_credit_well(c.well_id);perform ops.lock_operational_scope(c.well_id);
 perform 1 from finance.profit_distribution_cycles where id=c.id for update;
 perform 1 from finance.profit_distribution_lines where distribution_cycle_id=c.id order by id for update;
 perform 1 from finance.distribution_sources where id=x.source_id and well_id=c.well_id and tenant_id=c.tenant_id for update;
 if not found or not coalesce(iam.has_well_role(c.well_id,array['owner']),false) then raise exception 'distribution_owner_required' using errcode='42501';end if;
 select id into head from finance.current_distribution_source_selections where cycle_id=c.id and source_id=x.source_id;
 if head is distinct from x.id or x.mode<>'manual_partial' then
  raise exception 'distribution_adjustment_changed' using errcode='23514',detail='{"status":"review_required","title":"تغيّر هذا التعديل","message":"اعرض القيمة الحالية وراجعها قبل حفظ تغيير جديد.","action":"مراجعة التعديل"}';end if;
 if not p_cancel and p_amount is null then raise exception 'distribution_adjustment_amount_required' using errcode='22023';end if;
 return api.select_partner_distribution_source(c.id,x.source_id,case when p_cancel then null else p_amount end,p_reason);
end;$$;
revoke all on function finance.change_current_distribution_adjustment(uuid,bigint,text,boolean) from public,anon,authenticated,service_role;

create function api.update_partner_distribution_adjustment(p_adjustment_id uuid,p_amount_minor bigint,p_reason text)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
begin
 return finance.change_current_distribution_adjustment(p_adjustment_id,p_amount_minor,p_reason,false);
end;$$;
create function api.cancel_partner_distribution_adjustment(p_adjustment_id uuid,p_reason text)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
begin
 return finance.change_current_distribution_adjustment(p_adjustment_id,null,p_reason,true);
end;$$;
create function finance.distribution_selection_review_state(p_selection uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare x finance.distribution_source_selections%rowtype;s finance.distribution_sources%rowtype;c finance.profit_distribution_cycles%rowtype;
 state jsonb;needs_review boolean;
begin
 select * into strict x from finance.distribution_source_selections where id=p_selection;
 select * into strict s from finance.distribution_sources where id=x.source_id;
 select * into strict c from finance.profit_distribution_cycles where id=x.cycle_id;
 if c.status in ('approved','partially_paid','paid') then
  return jsonb_build_object('status','approved','requires_review',false,'title','تم اعتماد هذا التوزيع');end if;
 if x.mode<>'manual_partial' then return jsonb_build_object('status','automatic','requires_review',false);end if;
 if s.invoice_id is not null then
  state:=finance.distribution_invoice_selection_state(s.id,c.id);
  needs_review:=(state->>'blocked_by_older_debt')::boolean or x.amount_minor>(state->>'maximum_manual_minor')::bigint;
 else
  state:=finance.distribution_source_availability(s.id);
  needs_review:=state->>'status'<>'available' or not coalesce((state->>'available_in_distribution')::boolean,true)
   or x.amount_minor>coalesce((state->>'remaining_amount_minor')::bigint,0);
 end if;
 return state||jsonb_build_object('status',case when needs_review then 'review_required' else 'available' end,'requires_review',needs_review);
end;$$;

create function api.get_partner_distribution_sources(p_cycle_id uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c finance.profit_distribution_cycles%rowtype;result jsonb;
begin
 select * into strict c from finance.profit_distribution_cycles where id=p_cycle_id;
 if auth.uid() is null or not coalesce(iam.has_well_role(c.well_id,array['owner']),false) then raise exception 'distribution_owner_required' using errcode='42501';end if;
 select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('source',finance.distribution_source_availability(x.source_id),
  'selection_review',finance.distribution_selection_review_state(x.id)) order by x.line_id,x.source_id),'[]'::jsonb)
 into result from finance.current_distribution_source_selections x join finance.distribution_sources s on s.id=x.source_id where x.cycle_id=c.id;
 return jsonb_build_object('sources',result,'cycle_status',c.status,'can_change',c.status in ('calculated','under_review'),
  'title',case when c.status in ('approved','partially_paid','paid') then 'تم اعتماد هذا التوزيع' when c.status='cancelled' then 'تحتاج مبالغ التوزيع إلى مراجعة' else 'التوزيع الحالي' end,
  'next_action',case when c.status='cancelled' then 'حساب توزيع جديد' when c.status in ('approved','partially_paid','paid') then 'عرض التفاصيل' else 'مراجعة التوزيع' end,
  'notice',case when c.status='cancelled' then 'تغيّرت مبالغ مرتبطة بهذه الدورة. راجعها واحسب توزيعًا جديدًا.' else 'راجع المبالغ والتعديلات قبل الاعتماد.' end,
  'automatic_notice','سيتم احتساب هذا المبلغ تلقائيًا','manual_action','استخدام مبلغ مختلف',
  'confirm_action','استخدام هذا المبلغ','revert_action','العودة للاحتساب التلقائي',
  'labels',jsonb_build_array('المبلغ الأصلي','المستخدم سابقًا','المتاح الآن','المبلغ الذي تريد استخدامه','السبب'));
end;$$;

create table finance.distribution_source_calculation_basis(
 cycle_id uuid primary key references finance.profit_distribution_cycles(id),created_at timestamptz not null default clock_timestamp()
);
alter table finance.distribution_source_calculation_basis enable row level security;
revoke all on finance.distribution_source_calculation_basis from public,anon,authenticated,service_role;
grant select on finance.distribution_source_calculation_basis to authenticated,service_role;
create policy distribution_source_basis_read on finance.distribution_source_calculation_basis for select
 using(exists(select 1 from finance.profit_distribution_cycles c where c.id=cycle_id));
create trigger distribution_source_basis_immutable before update or delete on finance.distribution_source_calculation_basis
 for each row execute function finance.reject_distribution_source_history_mutation();

create function finance.require_distribution_source_plan(p_cycle uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c finance.profit_distribution_cycles%rowtype;l record;r record;x finance.distribution_source_selections%rowtype;
 a jsonb;available bigint;budget bigint;expected bigint;
begin
 perform billing.require_customer_credit_well_lock((select well_id from finance.profit_distribution_cycles where id=p_cycle));
 select * into strict c from finance.profit_distribution_cycles where id=p_cycle;
 for l in select * from finance.profit_distribution_lines where distribution_cycle_id=c.id order by id loop
  budget:=l.gross_share_minor;
  for r in select sel.*,s.id as sid from finance.current_distribution_source_selections sel join finance.distribution_sources s on s.id=sel.source_id
   where sel.cycle_id=c.id and sel.line_id=l.id and s.expense_id is not null order by s.id loop
   a:=finance.distribution_source_availability(r.sid);available:=case when coalesce((a->>'available_in_distribution')::boolean,true) then coalesce((a->>'remaining_amount_minor')::bigint,0) else 0 end;
   if r.amount_minor>available or(r.mode='automatic' and r.amount_minor<>available) then
    raise exception 'distribution_source_requires_review' using errcode='23514',detail='{"status":"review_required","title":"تغيّر المبلغ المتاح","message":"راجع مبالغ الشريك قبل اعتماد التوزيع.","action":"مراجعة المبالغ"}';end if;
   budget:=budget+r.amount_minor;
  end loop;
  for r in select i.id from billing.invoices i join core.partner_irrigation_policies p on p.id=i.partner_policy_id
   where i.well_id=c.well_id and i.tenant_id=c.tenant_id and p.well_id=c.well_id and p.tenant_id=c.tenant_id
    and p.partner_id=l.partner_id and p.policy_type='deduct_from_profit'
    and i.status in ('issued','partially_paid','overdue') and i.invoice_date<c.period_end order by i.invoice_date,i.id loop
   available:=finance.partner_invoice_source_available(r.id,c.well_id,l.partner_id);
   select sel.* into x from finance.current_distribution_source_selections sel join finance.distribution_sources s on s.id=sel.source_id
    where sel.cycle_id=c.id and sel.line_id=l.id and s.invoice_id=r.id;
   if x.mode='manual_partial' then
    perform finance.require_distribution_invoice_selection(x.source_id,c.id,x.amount_minor);expected:=x.amount_minor;
   else expected:=least(available,budget);end if;
   if coalesce(x.amount_minor,0)<>expected or expected>budget then
    raise exception 'distribution_source_order_requires_review' using errcode='23514',detail='{"status":"review_required","title":"تغيّرت المبالغ المتاحة","message":"راجع مبالغ الشريك قبل اعتماد التوزيع. لم نغيّر اختيارك أو نستخدم مبلغًا آخر بدلًا منه.","action":"مراجعة المبالغ"}';end if;
   budget:=budget-expected;if expected<available then budget:=0;end if;
  end loop;
 end loop;
end;$$;

create function finance.consume_distribution_sources(p_cycle uuid,p_actor uuid) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c finance.profit_distribution_cycles%rowtype;r record;a jsonb;
begin
 perform billing.require_customer_credit_well_lock((select well_id from finance.profit_distribution_cycles where id=p_cycle));
 select * into strict c from finance.profit_distribution_cycles where id=p_cycle for update;
 if not exists(select 1 from finance.distribution_source_calculation_basis where cycle_id=c.id) then
  raise exception 'distribution_legacy_cycle_requires_recalculation' using errcode='23514',detail='{"status":"review_required","title":"أعد حساب هذه الدورة قبل اعتمادها","message":"هذه الدورة حُسبت سابقًا دون تفاصيل كافية للمبالغ المرتبطة بها. أعد الحساب وراجع النتيجة أولًا.","action":"إعادة الحساب"}';end if;
 perform 1 from finance.profit_distribution_lines where distribution_cycle_id=c.id order by id for update;
 for r in select s.* from finance.distribution_sources s join finance.current_distribution_source_selections x on x.source_id=s.id
  where x.cycle_id=c.id order by s.id for update of s loop
  if r.expense_id is not null then perform 1 from finance.expenses where id=r.expense_id for update;
  else perform 1 from billing.invoices where id=r.invoice_id for update;end if;
 end loop;
 for r in select x.* from finance.current_distribution_source_selections x join finance.distribution_sources s on s.id=x.source_id
  where x.cycle_id=c.id and x.mode='manual_partial' and s.invoice_id is not null order by x.source_id loop
  perform finance.require_distribution_invoice_selection(r.source_id,c.id,r.amount_minor);
 end loop;
 perform finance.require_distribution_source_plan(c.id);
 -- Every proposed amount and canonical source must still agree. No automatic
 -- redrafting during approval, no partial result if any check/post fails.
 if exists(select 1 from finance.profit_distribution_lines l where l.distribution_cycle_id=c.id and
  (l.partner_receivables_minor<>coalesce((select sum(x.amount_minor) from finance.current_distribution_source_selections x
    join finance.distribution_sources s on s.id=x.source_id where x.cycle_id=c.id and x.line_id=l.id and s.expense_id is not null),0)
   or l.irrigation_deductions_minor<>coalesce((select sum(x.amount_minor) from finance.current_distribution_source_selections x
    join finance.distribution_sources s on s.id=x.source_id where x.cycle_id=c.id and x.line_id=l.id and s.invoice_id is not null),0)
   or l.other_deductions_minor<>0 or l.net_payable_minor<>l.gross_share_minor+l.partner_receivables_minor-l.irrigation_deductions_minor)) then
  raise exception 'distribution_source_amounts_require_review' using errcode='23514';end if;
 for r in select x.*,s.invoice_id,s.expense_id,s.partner_id,s.well_id,s.tenant_id from finance.current_distribution_source_selections x
  join finance.distribution_sources s on s.id=x.source_id left join billing.invoices source_invoice on source_invoice.id=s.invoice_id
  where x.cycle_id=c.id order by x.line_id,(s.invoice_id is not null),source_invoice.invoice_date,source_invoice.id,x.source_id loop
  if(r.well_id,r.tenant_id) is distinct from(c.well_id,c.tenant_id) or not exists(select 1 from finance.profit_distribution_lines l
   where l.id=r.line_id and l.distribution_cycle_id=c.id and l.partner_id=r.partner_id) then raise exception 'distribution_source_scope_invalid' using errcode='23514';end if;
  if r.amount_minor=0 then continue;end if;
  a:=finance.distribution_source_availability(r.source_id);
  if a->>'status'<>'available' or not coalesce((a->>'available_in_distribution')::boolean,true) or r.amount_minor>coalesce((a->>'remaining_amount_minor')::bigint,0) then
   raise exception 'distribution_source_requires_review' using errcode='23514',detail='{"status":"review_required","title":"يحتاج هذا التعديل إلى مراجعة","message":"المبلغ المرتبط بهذا التعديل تغيّر أو لم يعد متاحًا بالكامل. راجع التعديل قبل اعتماد التوزيع.","action":"مراجعة التعديل"}';end if;
  insert into finance.distribution_source_consumptions(source_id,tenant_id,well_id,partner_id,invoice_id,expense_id,cycle_id,line_id,selection_id,amount_minor,eligible_amount_snapshot_minor,available_snapshot_minor,actor_id)
  values(r.source_id,r.tenant_id,r.well_id,r.partner_id,r.invoice_id,r.expense_id,c.id,r.line_id,r.id,r.amount_minor,(a->>'effective_amount_minor')::bigint,(a->>'remaining_amount_minor')::bigint,p_actor);
 end loop;
end;$$;

create or replace view billing.invoice_explicit_settlements with(security_invoker=true) as
select i.id as invoice_id,i.tenant_id,i.well_id,i.farmer_well_account_id,i.session_id,tot.total_minor,i.status,
 i.nonallocation_paid_minor
 +greatest(coalesce(i.inserted_settlement_snapshot_minor,0)-coalesce(original_allocations.amount_minor,0),0)
 +coalesce(a.amount_minor,0)+coalesce(c.amount_minor,0)+coalesce(legacy.non_cash_settled_minor,0)+coalesce(dist.amount_minor,0) as explicitly_settled_minor,
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
 join billing.payments p on p.id=src.payment_id where c.invoice_id=i.id)c on true
left join billing.legacy_invoice_review_effects legacy on legacy.invoice_id=i.id
left join lateral(select sum(amount_minor) as amount_minor from finance.distribution_source_consumptions where invoice_id=i.id)dist on true;

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

create or replace function finance.distribution_recalculation_state(p_cycle uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare c finance.profit_distribution_cycles%rowtype;lines jsonb;base jsonb;affected jsonb;cfg jsonb;selections jsonb;
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
 select coalesce(jsonb_agg(to_jsonb(x) order by x.source_id),'[]'::jsonb) into selections
 from finance.current_distribution_source_selections x where x.cycle_id=c.id and x.mode='manual_partial';
 select coalesce(jsonb_agg(distinct q.row_value),'[]'::jsonb) into affected from(
  select value as row_value from jsonb_array_elements(affected)
  union all select to_jsonb(l)||jsonb_build_object('manual_source_selections',selections)
   from finance.profit_distribution_lines l where l.distribution_cycle_id=c.id
   and exists(select 1 from finance.current_distribution_source_selections x where x.cycle_id=c.id and x.line_id=l.id and x.mode='manual_partial')
 )q;
 cfg:=finance.current_distribution_configuration(c.well_id);
 return jsonb_build_object('cycle',to_jsonb(c),'lines',lines,'affected',affected,'configuration',cfg,
  'state_token',md5(jsonb_build_object('cycle',to_jsonb(c),'lines',lines,'configuration',cfg,'selections',selections)::text),
  'manual_adjustments_present',jsonb_array_length(affected)>0,'original_calculation_unknown',base is null);
end;$$;

-- Actual standalone repayment of a recorded payable after the partner has
-- left the profit-share model. Same source-consumption authority, no new debt.
create function api.prepare_partner_payable_source(p_expense_id uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate finance.expenses%rowtype;e finance.expenses%rowtype;source uuid;
begin
 select * into candidate from finance.expenses where id=p_expense_id;
 if candidate.id is null or auth.uid() is null or not coalesce(iam.has_well_role(candidate.well_id,array['owner']),false) then
  raise exception 'distribution_owner_required' using errcode='42501';end if;
 perform billing.lock_customer_credit_well(candidate.well_id);
 perform ops.lock_operational_scope(candidate.well_id);
 select * into strict e from finance.expenses where id=p_expense_id for update;
 if(e.well_id,e.tenant_id,e.partner_id) is distinct from(candidate.well_id,candidate.tenant_id,candidate.partner_id)
  or not coalesce(iam.has_well_role(e.well_id,array['owner']),false) then raise exception 'distribution_owner_required' using errcode='42501';end if;
 source:=finance.register_distribution_source(e.id,null);
 return finance.distribution_source_availability(source)||jsonb_build_object('payment_action','تسجيل سداد المستحق');
end;$$;

create function api.pay_departed_partner_source(p_source_id uuid,p_amount_minor bigint,p_reason text,p_command_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate finance.distribution_sources%rowtype;s finance.distribution_sources%rowtype;old finance.distribution_source_consumptions%rowtype;
 a jsonb;req jsonb;result jsonb;effect uuid:=gen_random_uuid();journal uuid:=gen_random_uuid();cashbox uuid;stamp timestamptz;business_date date;
begin
 select * into candidate from finance.distribution_sources where id=p_source_id;
 if candidate.id is null or auth.uid() is null or not coalesce(iam.has_well_role(candidate.well_id,array['owner']),false) then
  raise exception 'distribution_owner_required' using errcode='42501';end if;
 perform billing.lock_customer_credit_well(candidate.well_id);
 perform ops.lock_operational_scope(candidate.well_id);
 select * into strict s from finance.distribution_sources where id=p_source_id for update;
 perform 1 from finance.expenses where id=s.expense_id and well_id=s.well_id and tenant_id=s.tenant_id and partner_id=s.partner_id for update;
 if not found or(s.well_id,s.tenant_id,s.partner_id) is distinct from(candidate.well_id,candidate.tenant_id,candidate.partner_id)
  or not coalesce(iam.has_well_role(s.well_id,array['owner']),false) then raise exception 'distribution_owner_required' using errcode='42501';end if;
 if p_command_id is null or p_amount_minor is null or p_amount_minor<=0 or nullif(btrim(p_reason),'') is null then
  raise exception 'partner_source_repayment_facts_required' using errcode='22023';end if;
 req:=jsonb_build_object('source_id',s.id,'amount_minor',p_amount_minor,'reason',p_reason,'actor_id',auth.uid());
 select * into old from finance.distribution_source_consumptions where tenant_id=s.tenant_id and command_id=p_command_id;
 if found then
  if old.settlement_kind<>'standalone_payment' or old.request_payload<>req then raise exception 'partner_source_repayment_conflict' using errcode='22023';end if;
  return old.result_payload;
 end if;
 stamp:=clock_timestamp();business_date:=(stamp at time zone core.well_timezone(s.well_id))::date;
 if not exists(select 1 from core.well_partners p where p.id=s.partner_id and p.well_id=s.well_id and p.tenant_id=s.tenant_id
  and(p.status='left' or p.left_at is not null)) or exists(select 1 from core.ownership_share_versions v where v.partner_id=s.partner_id
   and v.well_id=s.well_id and(v.ownership_percentage>0 or v.profit_percentage>0) and v.effective_period @> business_date) then
  raise exception 'partner_still_in_distribution' using errcode='23514',detail='{"status":"not_available","title":"راجع مستحقات الشريك","message":"هذا الشريك ما زال ضمن التوزيع. راجع مستحقاته من شاشة التوزيع.","action":"مراجعة التوزيع"}';end if;
 a:=finance.distribution_source_availability(s.id);
 if a->>'status'<>'available' or p_amount_minor>coalesce((a->>'remaining_amount_minor')::bigint,0) then
  raise exception 'partner_source_amount_unavailable' using errcode='23514',detail=a::text;end if;
 cashbox:=finance.main_cashbox_id(s.well_id);
 perform 1 from finance.cashboxes where id=cashbox and well_id=s.well_id and tenant_id=s.tenant_id and status='active' for update;
 if not found then raise exception 'active_main_cashbox_required' using errcode='23514';end if;
 insert into finance.journal_entries(id,tenant_id,public_code,well_id,entry_date,source_type,source_id,description,idempotency_key)
 values(journal,s.tenant_id,core.generate_public_code('JE'),s.well_id,stamp,'partner_source_repayment',effect,
  'سداد مستحق مسجل للشريك','PSR-'||effect::text);
 insert into finance.journal_lines(tenant_id,journal_entry_id,ledger_account_id,entry_side,amount_minor,partner_id,cashbox_id,description)
 values(s.tenant_id,journal,finance.ledger_account_id(s.well_id,'2400'),'debit',p_amount_minor,s.partner_id,null,'تخفيض مستحق مسجل للشريك'),
 (s.tenant_id,journal,finance.ledger_account_id(s.well_id,'1000'),'credit',p_amount_minor,s.partner_id,cashbox,'سداد من الصندوق الرئيسي');
 perform finance.post_journal_entry(journal,auth.uid());
 result:=jsonb_build_object('status','paid','effect_id',effect,'journal_entry_id',journal,'source_id',s.id,'amount_minor',p_amount_minor,
  'remaining_amount_minor',(a->>'remaining_amount_minor')::bigint-p_amount_minor,'title','تم تسجيل سداد المستحق',
  'message','تم سداد المبلغ المحدد، وبقي أي مبلغ آخر محفوظًا للشريك.','action','عرض التفاصيل');
 insert into finance.distribution_source_consumptions(id,source_id,tenant_id,well_id,partner_id,expense_id,
  settlement_kind,command_id,journal_entry_id,request_payload,result_payload,amount_minor,eligible_amount_snapshot_minor,available_snapshot_minor,actor_id,accepted_at)
 values(effect,s.id,s.tenant_id,s.well_id,s.partner_id,s.expense_id,'standalone_payment',p_command_id,journal,req,result,
  p_amount_minor,(a->>'effective_amount_minor')::bigint,(a->>'remaining_amount_minor')::bigint,auth.uid(),stamp);
 return result;
end;$$;



create function billing.invoice_has_approved_distribution_use(p_invoice uuid) returns boolean
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select exists(select 1 from finance.distribution_source_consumptions x join finance.profit_distribution_cycles c on c.id=x.cycle_id
  where x.invoice_id=p_invoice and x.settlement_kind='distribution' and c.status in ('approved','partially_paid','paid'));
$$;
revoke all on function billing.invoice_has_approved_distribution_use(uuid) from public,anon,authenticated,service_role;

create function billing.invoice_legacy_distribution_unresolved(p_invoice uuid) returns boolean
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select exists(select 1 from billing.invoices i where i.id=p_invoice and i.deducted_in_cycle_id is not null
  and not exists(select 1 from billing.legacy_invoice_accounting_resolutions r where r.invoice_id=i.id));
$$;
create function billing.invoice_has_protected_distribution_use(p_invoice uuid) returns boolean
language sql volatile security definer set search_path=pg_catalog,pg_temp as $$
 select billing.invoice_legacy_distribution_unresolved(p_invoice)
 or exists(select 1 from billing.legacy_invoice_accounting_resolutions r where r.invoice_id=p_invoice and r.settlement_amount_minor>0)
 or billing.invoice_has_approved_distribution_use(p_invoice);
$$;
revoke all on function billing.invoice_legacy_distribution_unresolved(uuid),billing.invoice_has_protected_distribution_use(uuid)
 from public,anon,authenticated,service_role;


create or replace function billing.repartition_payment_internal(p_payment uuid,p_allocation uuid,p_credit uuid,p_amount bigint,
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

create or replace function billing.adjust_credit_application(p_application uuid,p_operation text,p_amount bigint,
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
 if p_operation='restore' then perform billing.require_no_disputed_invoice(a.invoice_id,p_amount);end if;

 r:=billing.credit_event_replay(a.tenant_id,p_source,p_revision,req);if r is not null then return r;end if;
 -- A release may repair an in-transaction debt reduction. Publish/validate
 -- refreshed debt only after the append-only application adjustment below;
 -- an eager refresh would reject the very excess that this child releases.
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
 elsif billing.invoice_has_protected_distribution_use(i.id) then review:='distribution_reconciliation_required';
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
 perform billing.refresh_partition_invoices(c.well_id);
 return r;
end;$$;

create or replace function billing.reverse_allocation_credit_legacy(p_credit uuid,p_amount bigint,p_source uuid,p_revision bigint,
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
 restored:=case when not billing.invoice_has_protected_distribution_use(i.id) and i.status in ('issued','partially_paid','paid','overdue')
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


create or replace function billing.apply_account_credit(p_credit uuid,p_invoice uuid,p_amount bigint,p_source uuid,p_revision bigint,
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
 perform billing.require_no_disputed_invoice(p_invoice,p_amount);

 r:=billing.credit_event_replay(c.tenant_id,p_source,p_revision,request);if r is not null then return r;end if;
 perform billing.refresh_partition_invoices(c.well_id);
 perform 1 from billing.account_credits where id=c.id for update;
 select * into strict i from billing.invoices where id=p_invoice for update;
 if i.tenant_id<>c.tenant_id or i.well_id<>c.well_id or i.farmer_well_account_id<>c.farmer_well_account_id
  or billing.invoice_legacy_distribution_unresolved(i.id) or i.status not in ('issued','partially_paid','overdue') then
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
 perform billing.refresh_partition_invoices(c.well_id);
 return r;
end;$$;

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
    or billing.invoice_legacy_distribution_unresolved(i.id) or i.status not in ('issued','partially_paid','overdue') or new.amount_minor>n or new.amount_minor>i.outstanding_minor then
    raise exception 'credit_application_out_of_range' using errcode='23514';end if;
  else
   if new.restored_minor+new.held_minor>n or new.requested_minor>
     c.amount_minor-coalesce((select sum(requested_minor) from billing.account_credit_reversals where credit_id=c.id),0) then
    raise exception 'credit_reversal_out_of_range' using errcode='23514';end if;
  end if;
 end if;
 return new;
end;$$;


-- Unknown legacy use is a collection hold, never an invented paid amount.
-- Once owner records an exact disputed amount, the existing legacy review
-- effect supplies that exact hold; once resolved, canonical settlement applies.
create or replace view billing.invoice_effective_balances with(security_invoker=true) as
select i.id as invoice_id,i.well_id,i.tenant_id,i.farmer_well_account_id,x.total_minor,
 billing.require_valid_payment_partition(x.scope_valid,x.explicitly_settled_minor+coalesce(d.direct_settled_minor,0)) as paid_minor,
 billing.require_valid_payment_partition(x.scope_valid,x.total_minor-x.explicitly_settled_minor-coalesce(d.direct_settled_minor,0)) as outstanding_minor,
 case when quarantine.unknown_use then greatest(x.total_minor-x.explicitly_settled_minor-coalesce(d.direct_settled_minor,0),0)
  else least(coalesce(legacy.disputed_minor,0),greatest(x.total_minor-x.explicitly_settled_minor-coalesce(d.direct_settled_minor,0),0)) end as collection_hold_minor,
 case when quarantine.unknown_use then 0::bigint
  else greatest(x.total_minor-x.explicitly_settled_minor-coalesce(d.direct_settled_minor,0)-coalesce(legacy.disputed_minor,0),0) end as collectible_minor
from billing.invoices i join billing.invoice_explicit_settlements x on x.invoice_id=i.id
left join billing.session_economic_settlements d on d.session_id=i.session_id and i.status not in ('draft','cancelled','reversed')
left join billing.legacy_invoice_review_effects legacy on legacy.invoice_id=i.id
left join lateral(select exists(select 1 from finance.distribution_sources s where s.invoice_id=i.id and s.legacy_review_required
 and not exists(select 1 from billing.legacy_invoice_accounting_reviews r where r.invoice_id=i.id)) as unknown_use)quarantine on true;
create or replace function billing.require_no_disputed_invoice(p_invoice uuid,p_requested_minor bigint default null) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare b record;
begin
 select collection_hold_minor,collectible_minor into b from billing.invoice_effective_balances where invoice_id=p_invoice;
 if found and b.collection_hold_minor>0 and(p_requested_minor is null or p_requested_minor>b.collectible_minor) then
  raise exception 'legacy_invoice_amount_requires_review' using errcode='23514',detail=
   '{"status":"review_required","title":"يحتاج هذا المبلغ إلى مراجعة","message":"المبلغ المطلوب يتضمن جزءًا يحتاج إلى مراجعة قبل استخدامه. راجع المبلغ المتاح أو أكمل مراجعة المبلغ القديم.","action":"مراجعة المبلغ"}';
 end if;
end;$$;


do $acl$ declare f record;begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where(n.nspname='finance' and p.proname in ('reject_distribution_source_history_mutation','register_distribution_source',
   'distribution_source_availability','distribution_selection_review_state','partner_invoice_source_available','distribution_invoice_selection_state','require_distribution_invoice_selection','ensure_distribution_invoice_candidates','rederive_distribution_source_lines','prepare_distribution_source_selections','require_distribution_source_plan','consume_distribution_sources'))
  or(n.nspname='api' and p.proname in ('review_legacy_partner_expense_source','select_partner_distribution_source',
   'prepare_partner_payable_source','pay_departed_partner_source','add_partner_distribution_adjustment','update_partner_distribution_adjustment','cancel_partner_distribution_adjustment','get_partner_distribution_sources')) loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.signature);
  if f.signature::text like 'api.%' then execute format('grant execute on function %s to authenticated',f.signature);end if;
 end loop;
end;$acl$;
revoke insert,update,delete,truncate on finance.profit_distribution_lines from public,anon,authenticated,service_role;
do $columns$ declare c record;begin
 for c in select attname from pg_attribute where attrelid='finance.profit_distribution_lines'::regclass and attnum>0 and not attisdropped loop
  execute format('revoke insert (%I),update (%I) on finance.profit_distribution_lines from public,anon,authenticated,service_role',c.attname,c.attname);
 end loop;
end;$columns$;
commit;

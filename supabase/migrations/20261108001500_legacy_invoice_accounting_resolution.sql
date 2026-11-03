begin;
-- Active-owner legacy invoice review only. No invented historical proof,
-- payment, journal, invoice rewrite or approved-cycle rewrite.
create table billing.legacy_invoice_accounting_reviews(
 id uuid primary key default gen_random_uuid(),tenant_id uuid not null references core.tenants(id),
 well_id uuid not null references core.wells(id),invoice_id uuid not null unique references billing.invoices(id),
 historical_cycle_id uuid not null references finance.profit_distribution_cycles(id),
 partner_id uuid not null references core.well_partners(id),
 confirmed_historical_amount_minor bigint not null check(confirmed_historical_amount_minor>0),
 effective_total_snapshot_minor bigint not null,invoice_snapshot jsonb not null,cycle_snapshot jsonb not null,
 evidence_class text not null default 'accounting_review_required' check(evidence_class='accounting_review_required'),
 reason text not null check(nullif(btrim(reason),'') is not null),
 command_id uuid not null,request_payload jsonb not null,result_payload jsonb not null,
 actor_id uuid not null references iam.profiles(id),accepted_at timestamptz not null default clock_timestamp(),
 unique(tenant_id,command_id)
);
create table billing.legacy_invoice_accounting_resolutions(
 id uuid primary key default gen_random_uuid(),review_id uuid not null unique references billing.legacy_invoice_accounting_reviews(id),
 tenant_id uuid not null references core.tenants(id),well_id uuid not null references core.wells(id),
 invoice_id uuid not null references billing.invoices(id),partner_id uuid not null references core.well_partners(id),
 decision text not null check(decision in ('confirmed_non_cash_settlement','confirmed_not_settled')),
 settlement_amount_minor bigint not null check(settlement_amount_minor>=0),
 command_id uuid not null,request_payload jsonb not null,result_payload jsonb not null,
 reason text not null check(nullif(btrim(reason),'') is not null),actor_id uuid not null references iam.profiles(id),
 accepted_at timestamptz not null default clock_timestamp(),unique(tenant_id,command_id),
 check((decision='confirmed_non_cash_settlement' and settlement_amount_minor>0)
   or(decision='confirmed_not_settled' and settlement_amount_minor=0))
);
alter table billing.legacy_invoice_accounting_reviews enable row level security;
alter table billing.legacy_invoice_accounting_resolutions enable row level security;
revoke all on billing.legacy_invoice_accounting_reviews,billing.legacy_invoice_accounting_resolutions from public,anon,authenticated,service_role;
grant select on billing.legacy_invoice_accounting_reviews,billing.legacy_invoice_accounting_resolutions to authenticated,service_role;
-- Canonical invoice/debt views are SECURITY INVOKER. Give their callers only
-- invoice-visible evidence, using the EXISTING invoice SELECT policy/scope.
create policy legacy_invoice_review_read on billing.legacy_invoice_accounting_reviews for select
 using(exists(select 1 from billing.invoices i where i.id=invoice_id));
create policy legacy_invoice_resolution_read on billing.legacy_invoice_accounting_resolutions for select
 using(exists(select 1 from billing.invoices i where i.id=invoice_id));
create function billing.reject_legacy_invoice_review_mutation() returns trigger language plpgsql
set search_path=pg_catalog,pg_temp as $$
begin raise exception 'legacy_invoice_review_append_only' using errcode='23514';end;$$;
create trigger legacy_invoice_review_immutable before update or delete on billing.legacy_invoice_accounting_reviews
 for each row execute function billing.reject_legacy_invoice_review_mutation();
create trigger legacy_invoice_resolution_immutable before update or delete on billing.legacy_invoice_accounting_resolutions
 for each row execute function billing.reject_legacy_invoice_review_mutation();
revoke all on function billing.reject_legacy_invoice_review_mutation() from public,anon,authenticated,service_role;
create view billing.legacy_invoice_review_effects with(security_invoker=true) as
select r.invoice_id,r.tenant_id,r.well_id,r.partner_id,
 case when x.decision='confirmed_non_cash_settlement' then x.settlement_amount_minor else 0::bigint end as non_cash_settled_minor,
 case when x.id is null then r.confirmed_historical_amount_minor else 0::bigint end as disputed_minor,
 coalesce(x.decision,'accounting_review_required') as status,r.id as review_id
from billing.legacy_invoice_accounting_reviews r left join billing.legacy_invoice_accounting_resolutions x on x.review_id=r.id;
revoke all on billing.legacy_invoice_review_effects from public,anon;
grant select on billing.legacy_invoice_review_effects to authenticated,service_role;

create function billing.require_no_disputed_invoice(p_invoice uuid,p_requested_minor bigint default null) returns void
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
begin
 if exists(select 1 from billing.legacy_invoice_review_effects where invoice_id=p_invoice and disputed_minor>0) and (p_requested_minor is null or p_requested_minor>coalesce((select collectible_minor from billing.invoice_effective_balances where invoice_id=p_invoice),0)) then
  raise exception 'legacy_invoice_amount_requires_review' using errcode='23514',detail=
   '{"status":"review_required","title":"يحتاج هذا المبلغ إلى مراجعة","message":"المبلغ المطلوب يتضمن جزءًا يحتاج إلى مراجعة قبل استخدامه. راجع المبلغ المتاح أو أكمل مراجعة المبلغ القديم.","action":"مراجعة المبلغ"}';
 end if;
end;$$;
revoke all on function billing.require_no_disputed_invoice(uuid,bigint) from public,anon,authenticated,service_role;

create function api.open_legacy_invoice_accounting_review(p_invoice_id uuid,p_historical_cycle_id uuid,
 p_confirmed_historical_amount_minor bigint,p_reason text,p_command_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate billing.invoices%rowtype;i billing.invoices%rowtype;c finance.profit_distribution_cycles%rowtype;
 old billing.legacy_invoice_accounting_reviews%rowtype;partner uuid;req jsonb;result jsonb;review_id uuid:=gen_random_uuid();total bigint;
begin
 select * into candidate from billing.invoices where id=p_invoice_id;
 if not found or auth.uid() is null or not coalesce(iam.has_well_role(candidate.well_id,array['owner']),false) then
  raise exception 'legacy_invoice_review_owner_required' using errcode='42501';end if;
 perform billing.lock_customer_credit_well(candidate.well_id);
 select * into strict i from billing.invoices where id=p_invoice_id for update;
 if (i.well_id,i.tenant_id) is distinct from(candidate.well_id,candidate.tenant_id)
  or not coalesce(iam.has_well_role(i.well_id,array['owner']),false) then
  raise exception 'legacy_invoice_review_owner_required' using errcode='42501';end if;
 if p_command_id is null or p_confirmed_historical_amount_minor is null or p_confirmed_historical_amount_minor<=0
  or nullif(btrim(p_reason),'') is null then raise exception 'legacy_invoice_review_facts_required' using errcode='22023';end if;
 req:=jsonb_build_object('invoice_id',i.id,'historical_cycle_id',p_historical_cycle_id,
  'amount_minor',p_confirmed_historical_amount_minor,'reason',p_reason,'actor_id',auth.uid());
 select * into old from billing.legacy_invoice_accounting_reviews where invoice_id=i.id
  or(tenant_id=i.tenant_id and command_id=p_command_id);
 if found then
  if old.invoice_id<>i.id or old.command_id<>p_command_id or old.request_payload<>req then
   raise exception 'legacy_invoice_review_conflict' using errcode='22023';end if;
  return old.result_payload;
 end if;
 select * into c from finance.profit_distribution_cycles where id=p_historical_cycle_id for share;
 select pol.partner_id into partner from core.partner_irrigation_policies pol where pol.id=i.partner_policy_id
  and pol.well_id=i.well_id and pol.tenant_id=i.tenant_id;
 if c.id is null or(c.well_id,c.tenant_id) is distinct from(i.well_id,i.tenant_id)
  or c.status not in ('approved','partially_paid','paid') or partner is null
  or not exists(select 1 from finance.profit_distribution_lines l where l.distribution_cycle_id=c.id and l.partner_id=partner)
  or i.invoice_date>=c.period_end or(i.deducted_in_cycle_id is not null and i.deducted_in_cycle_id<>c.id) then
  raise exception 'legacy_invoice_review_evidence_scope_invalid' using errcode='23514';end if;
 select total_minor into total from billing.effective_invoice_totals where id=i.id;
 if total is null or p_confirmed_historical_amount_minor>total then
  raise exception 'legacy_invoice_review_amount_out_of_range' using errcode='23514';end if;
 -- A marker/aggregate partner line proves related context, not exact accounting
 -- offset. Never classify it as automatic PROVEN_ACCOUNTING_OFFSET.
 result:=jsonb_build_object('status','accounting_review_required','review_id',review_id,'invoice_id',i.id,
  'disputed_amount_minor',p_confirmed_historical_amount_minor,'title','مراجعة مبلغ قديم',
  'message','هذا المبلغ مرتبط بتوزيع سابق ويحتاج منك تحديد حالته قبل أن يستخدمه النظام مرة أخرى.',
  'settled_action','تمت تسويته سابقًا','not_settled_action','لم تتم تسويته');
 insert into billing.legacy_invoice_accounting_reviews(id,tenant_id,well_id,invoice_id,historical_cycle_id,partner_id,
  confirmed_historical_amount_minor,effective_total_snapshot_minor,invoice_snapshot,cycle_snapshot,reason,
  command_id,request_payload,result_payload,actor_id)
 values(review_id,i.tenant_id,i.well_id,i.id,c.id,partner,p_confirmed_historical_amount_minor,total,to_jsonb(i),to_jsonb(c),
  p_reason,p_command_id,req,result,auth.uid());
 return result;
end;$$;

create function api.resolve_legacy_invoice_accounting_review(p_review_id uuid,p_decision text,p_reason text,p_command_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare candidate billing.legacy_invoice_accounting_reviews%rowtype;r billing.legacy_invoice_accounting_reviews%rowtype;
 i billing.invoices%rowtype;old billing.legacy_invoice_accounting_resolutions%rowtype;req jsonb;result jsonb;amount bigint;outstanding bigint;
begin
 select * into candidate from billing.legacy_invoice_accounting_reviews where id=p_review_id;
 if not found or auth.uid() is null or not coalesce(iam.has_well_role(candidate.well_id,array['owner']),false) then
  raise exception 'legacy_invoice_review_owner_required' using errcode='42501';end if;
 perform billing.lock_customer_credit_well(candidate.well_id);
 select * into strict i from billing.invoices where id=candidate.invoice_id for update;
 select * into strict r from billing.legacy_invoice_accounting_reviews where id=p_review_id for update;
 if (r.invoice_id,r.well_id,r.tenant_id) is distinct from(candidate.invoice_id,candidate.well_id,candidate.tenant_id)
  or(i.well_id,i.tenant_id) is distinct from(r.well_id,r.tenant_id)
  or not coalesce(iam.has_well_role(r.well_id,array['owner']),false)
  or not exists(select 1 from core.partner_irrigation_policies p where p.id=i.partner_policy_id
   and p.partner_id=r.partner_id and p.well_id=r.well_id and p.tenant_id=r.tenant_id) then
  raise exception 'legacy_invoice_review_owner_required' using errcode='42501';end if;
 perform 1 from finance.profit_distribution_cycles c where c.id=r.historical_cycle_id
  and c.well_id=r.well_id and c.tenant_id=r.tenant_id and c.status in ('approved','partially_paid','paid') for share;
 if not found then return jsonb_build_object('status','review_required','title','يحتاج هذا المبلغ إلى مراجعة',
  'message','راجع التوزيع السابق المرتبط بهذا المبلغ قبل تأكيد حالته.','action','مراجعة المبلغ');end if;
 if p_command_id is null or p_decision is null or p_decision not in ('confirmed_non_cash_settlement','confirmed_not_settled')
  or nullif(btrim(p_reason),'') is null then raise exception 'legacy_invoice_resolution_facts_required' using errcode='22023';end if;
 req:=jsonb_build_object('review_id',r.id,'decision',p_decision,'reason',p_reason,'actor_id',auth.uid());
 select * into old from billing.legacy_invoice_accounting_resolutions where review_id=r.id
  or(tenant_id=r.tenant_id and command_id=p_command_id);
 if found then
  if old.review_id<>r.id or old.command_id<>p_command_id or old.request_payload<>req then
   raise exception 'legacy_invoice_resolution_conflict' using errcode='22023';end if;
  return old.result_payload;
 end if;
 amount:=case when p_decision='confirmed_non_cash_settlement' then r.confirmed_historical_amount_minor else 0 end;
 select outstanding_minor into outstanding from billing.invoice_effective_balances where invoice_id=i.id;
 if amount>coalesce(outstanding,-1) or i.status in ('draft','cancelled','reversed') then
  return jsonb_build_object('status','review_required','title','يحتاج هذا المبلغ إلى مراجعة',
   'message','تغيّر رصيد الفاتورة. راجع المبلغ والمدفوعات المرتبطة بها قبل تأكيد حالته.','action','مراجعة المبلغ');end if;
 result:=jsonb_build_object('status',p_decision,'review_id',r.id,'invoice_id',i.id,'non_cash_amount_minor',amount,
  'remaining_amount_minor',outstanding-amount,'title',case when amount>0 then 'تم تأكيد المبلغ المستخدم سابقًا' else 'تمت مراجعة المبلغ' end,
  'message',case when amount>0 then 'لن يتم تحصيل هذا المبلغ مرة أخرى.' else 'سيعود هذا المبلغ متاحًا للتحصيل.' end,'action','عرض التفاصيل');
 insert into billing.legacy_invoice_accounting_resolutions(review_id,tenant_id,well_id,invoice_id,partner_id,decision,
  settlement_amount_minor,command_id,request_payload,result_payload,reason,actor_id)
 values(r.id,r.tenant_id,r.well_id,r.invoice_id,r.partner_id,p_decision,amount,p_command_id,req,result,p_reason,auth.uid());
 -- Only append to the existing canonical debt input. No invoice UPDATE, payment
 -- INSERT or journal posting. Cached counters refresh in their existing paths.
 return result;
end;$$;
revoke all on function api.open_legacy_invoice_accounting_review(uuid,uuid,bigint,text,uuid),
 api.resolve_legacy_invoice_accounting_review(uuid,text,text,uuid) from public,anon,authenticated,service_role;
grant execute on function api.open_legacy_invoice_accounting_review(uuid,uuid,bigint,text,uuid),
 api.resolve_legacy_invoice_accounting_review(uuid,text,text,uuid) to authenticated;

create or replace view billing.invoice_explicit_settlements with(security_invoker=true) as
select i.id as invoice_id,i.tenant_id,i.well_id,i.farmer_well_account_id,i.session_id,tot.total_minor,i.status,
 i.nonallocation_paid_minor
 +greatest(coalesce(i.inserted_settlement_snapshot_minor,0)-coalesce(original_allocations.amount_minor,0),0)
 +coalesce(a.amount_minor,0)+coalesce(c.amount_minor,0)+coalesce(legacy.non_cash_settled_minor,0) as explicitly_settled_minor,
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
left join billing.legacy_invoice_review_effects legacy on legacy.invoice_id=i.id;
create or replace view billing.invoice_effective_balances with(security_invoker=true) as
select i.id as invoice_id,i.well_id,i.tenant_id,i.farmer_well_account_id,x.total_minor,
 billing.require_valid_payment_partition(x.scope_valid,x.explicitly_settled_minor+coalesce(d.direct_settled_minor,0)) as paid_minor,
 billing.require_valid_payment_partition(x.scope_valid,x.total_minor-x.explicitly_settled_minor-coalesce(d.direct_settled_minor,0)) as outstanding_minor,
 least(coalesce(legacy.disputed_minor,0),greatest(x.total_minor-x.explicitly_settled_minor-coalesce(d.direct_settled_minor,0),0)) as collection_hold_minor,
 greatest(x.total_minor-x.explicitly_settled_minor-coalesce(d.direct_settled_minor,0)-coalesce(legacy.disputed_minor,0),0) as collectible_minor
from billing.invoices i join billing.invoice_explicit_settlements x on x.invoice_id=i.id
left join billing.session_economic_settlements d on d.session_id=i.session_id and i.status not in ('draft','cancelled','reversed')
left join billing.legacy_invoice_review_effects legacy on legacy.invoice_id=i.id;
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
  perform billing.require_no_disputed_invoice(i.id,p_amount_minor) from billing.invoices i
   where (p_session_charge_id is not null and i.session_id=(select session_id from billing.session_charges where id=p_session_charge_id))
;
  perform billing.require_no_disputed_invoice((x->>'invoice_id')::uuid,(x->>'amount_minor')::bigint) from jsonb_array_elements(p_allocations) x;


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
create or replace function billing.allocate_payment(
  p_payment_id uuid,
  p_allocations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'billing', 'finance', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_payment billing.payments%rowtype;
  v_invoice billing.invoices%rowtype;
  v_item jsonb;
  v_invoice_id uuid;
  v_amount bigint;
  v_requested_total bigint := 0;
  v_allocated_before bigint;
  v_available bigint;
  v_allocation_id uuid;
  v_journal_id uuid;
  v_result_items jsonb := '[]'::jsonb;
  v_position integer := 0;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل توزيع الدفعة على الفواتير';
  end if;

  select * into v_payment from billing.payments where id=p_payment_id;
  if not found then raise exception 'الدفعة غير موجودة: %',p_payment_id;end if;
  if not coalesce(iam.has_well_permission(v_payment.well_id,'payment.allocate'),false) then
    raise exception 'لا تملك صلاحية توزيع دفعات هذا البئر';end if;
  perform billing.lock_customer_credit_well(v_payment.well_id);
  perform billing.require_no_disputed_invoice((x->>'invoice_id')::uuid,(x->>'amount_minor')::bigint) from jsonb_array_elements(p_allocations) x;

  perform billing.refresh_partition_invoices(v_payment.well_id);
  select p.* into v_payment
  from billing.payments p
  where p.id = p_payment_id
  for update;

  if not found then
    raise exception 'الدفعة غير موجودة: %', p_payment_id;
  end if;
  if v_payment.status <> 'posted' then
    raise exception 'لا يمكن توزيع دفعة حالتها % — يجب أن تكون مرحلة', v_payment.status;
  end if;
  if v_payment.farmer_well_account_id is null then
    raise exception 'لا يمكن توزيع الدفعة لأنها غير مرتبطة بحساب مزارع';
  end if;
  if not iam.has_well_permission(v_payment.well_id, 'payment.allocate') then
    raise exception 'لا تملك صلاحية توزيع دفعات هذا البئر';
  end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array'
     or jsonb_array_length(p_allocations) = 0 then
    raise exception 'يجب إرسال فاتورة واحدة على الأقل مع مبلغ التخصيص';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_allocations) x
    group by x ->> 'invoice_id'
    having count(*) > 1
  ) then
    raise exception 'لا يجوز تكرار الفاتورة نفسها في طلب التوزيع';
  end if;

  for v_item in select value from jsonb_array_elements(p_allocations)
  loop
    begin
      v_invoice_id := (v_item ->> 'invoice_id')::uuid;
      v_amount := (v_item ->> 'amount_minor')::bigint;
    exception when others then
      raise exception 'صيغة تخصيص الفاتورة غير صالحة — يلزم invoice_id و amount_minor صحيحان';
    end;
    if v_invoice_id is null then
      raise exception 'معرف الفاتورة مطلوب في كل تخصيص';
    end if;
    if v_amount is null or v_amount <= 0 then
      raise exception 'مبلغ تخصيص كل فاتورة يجب أن يكون أكبر من صفر';
    end if;
    v_requested_total := v_requested_total + v_amount;
  end loop;

  select b.direct_capacity_minor into strict v_available
  from billing.payment_economic_applications b where b.payment_id=p_payment_id;
  if v_requested_total > v_available then
    raise exception 'إجمالي التخصيص المطلوب % يتجاوز المتاح من الدفعة %',
      v_requested_total, v_available;
  end if;

  for v_item in
    select a.value
    from jsonb_array_elements(p_allocations) with ordinality as a(value, position)
    order by a.position
  loop
    v_position := v_position + 1;
    v_invoice_id := (v_item ->> 'invoice_id')::uuid;
    v_amount := (v_item ->> 'amount_minor')::bigint;

    select i.* into v_invoice
    from billing.invoices i
    where i.id = v_invoice_id
    for update;

    if not found then
      raise exception 'الفاتورة غير موجودة: %', v_invoice_id;
    end if;
    if v_invoice.well_id is distinct from v_payment.well_id
       or v_invoice.farmer_well_account_id is distinct from v_payment.farmer_well_account_id then
      raise exception 'الفاتورة % لا تخص البئر وحساب المزارع المرتبطين بالدفعة', v_invoice_id;
    end if;
    if v_invoice.status not in ('issued', 'partially_paid', 'overdue','paid') then
      raise exception 'لا يمكن تخصيص دفعة لفاتورة حالتها %', v_invoice.status;
    end if;
    if v_amount > v_invoice.outstanding_minor + coalesce((select direct_settled_minor from billing.session_economic_settlements d
      where d.session_charge_id=v_payment.session_charge_id and d.session_id=v_invoice.session_id),0) then
      raise exception 'مبلغ التخصيص % يتجاوز دين الفاتورة المتبقي %',
        v_amount, v_invoice.outstanding_minor;
    end if;

    insert into billing.payment_allocations (
      tenant_id, payment_id, invoice_id, allocated_minor
    ) values (
      v_payment.tenant_id, p_payment_id, v_invoice_id, v_amount
    )
    returning id into v_allocation_id;

    perform billing.refresh_partition_invoices(v_payment.well_id);

    -- استخدام الرصيد المقدم يحوّل الالتزام إلى تسوية ذمة المزارع.
    if v_payment.purpose = 'advance' then
      v_journal_id := gen_random_uuid();
      insert into finance.journal_entries (
        id, tenant_id, public_code, well_id, entry_date,
        source_type, source_id, description, idempotency_key
      ) values (
        v_journal_id, v_payment.tenant_id, core.generate_public_code('JE'),
        v_payment.well_id, clock_timestamp(), 'advance_allocation',
        v_allocation_id, 'استخدام رصيد مقدم في الفاتورة ' || v_invoice.public_code,
        'ADV-ALLOC-' || v_allocation_id::text
      );

      insert into finance.journal_lines (
        tenant_id, journal_entry_id, ledger_account_id, entry_side,
        amount_minor, farmer_well_account_id, description
      ) values
        (v_payment.tenant_id, v_journal_id,
         finance.ledger_account_id(v_payment.well_id, '2000'), 'debit',
         v_amount, v_payment.farmer_well_account_id, 'استخدام الرصيد المقدم'),
        (v_payment.tenant_id, v_journal_id,
         finance.ledger_account_id(v_payment.well_id, '1100'), 'credit',
         v_amount, v_payment.farmer_well_account_id, 'تسديد ذمة فاتورة من الرصيد المقدم');

      perform finance.post_journal_entry(v_journal_id, v_actor);
    else
      v_journal_id := null;
    end if;

    perform audit.log(
      v_payment.tenant_id, v_payment.well_id,
      'allocate_payment', 'billing.payment_allocations', v_allocation_id,
      null,
      jsonb_build_object(
        'payment_id', p_payment_id,
        'invoice_id', v_invoice_id,
        'allocated_minor', v_amount,
        'position', v_position,
        'journal_entry_id', v_journal_id
      ),
      'توزيع دفعة على فاتورة'
    );

    v_result_items := v_result_items || jsonb_build_array(jsonb_build_object(
      'allocation_id', v_allocation_id,
      'invoice_id', v_invoice_id,
      'allocated_minor', v_amount,
      'invoice_status',(select status from billing.invoices where id=v_invoice_id),
      'journal_entry_id', v_journal_id
    ));
  end loop;

  if (select available_minor from billing.payment_available_balances where payment_id=p_payment_id)<0 then
    raise exception 'payment_effective_availability_negative' using errcode='23514';
  end if;

  return jsonb_build_object(
    'payment_id', p_payment_id,
    'allocated_minor', v_requested_total,
    'remaining_available_minor',(select remaining_minor from billing.payment_economic_applications where payment_id=p_payment_id),
    'remaining_transfer_capacity_minor',v_available-v_requested_total,
    'allocations', v_result_items
  );
end;
$function$;
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
 perform billing.refresh_partition_invoices(c.well_id);
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
 perform billing.refresh_partition_invoices(c.well_id);
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
 perform billing.refresh_partition_invoices(c.well_id);
 return r;
end;$$;

create function billing.guard_reviewed_invoice_identity() returns trigger language plpgsql
security definer set search_path=pg_catalog,pg_temp as $$
begin
 if exists(select 1 from billing.legacy_invoice_accounting_reviews where invoice_id=old.id)
  and (new.tenant_id,new.well_id,new.farmer_well_account_id,new.session_id,new.partner_policy_id,
   new.total_minor,new.subtotal_minor,new.nonallocation_paid_minor,new.inserted_settlement_snapshot_minor)
  is distinct from(old.tenant_id,old.well_id,old.farmer_well_account_id,old.session_id,old.partner_policy_id,
   old.total_minor,old.subtotal_minor,old.nonallocation_paid_minor,old.inserted_settlement_snapshot_minor) then
  raise exception 'reviewed_invoice_original_identity_immutable' using errcode='23514';end if;return new;
end;$$;
create trigger reviewed_invoice_identity before update on billing.invoices for each row execute function billing.guard_reviewed_invoice_identity();
revoke all on function billing.guard_reviewed_invoice_identity() from public,anon,authenticated,service_role;

create function billing.guard_reviewed_invoice_allocation() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare w uuid;key bigint;remaining bigint;
begin
 select well_id into w from billing.legacy_invoice_accounting_reviews where invoice_id=new.invoice_id;
 if not found then return new;end if;
 key:=hashtextextended('customer-credit-well:'||w::text,0);
 if not exists(select 1 from pg_locks l where l.pid=pg_backend_pid() and l.locktype='advisory' and l.granted
  and l.objsubid=1 and l.classid=((key>>32)&4294967295)::oid and l.objid=(key&4294967295)::oid) then
  raise exception 'reviewed_invoice_use_sanctioned_payment' using errcode='42501';end if;
 select collectible_minor into remaining from billing.invoice_effective_balances where invoice_id=new.invoice_id;
 if new.allocated_minor>coalesce(remaining,0) then raise exception 'invoice_collectible_amount_exceeded' using errcode='23514';end if;
 return new;
end;$$;
create trigger reviewed_invoice_allocation before insert on billing.payment_allocations
 for each row execute function billing.guard_reviewed_invoice_allocation();
revoke all on function billing.guard_reviewed_invoice_allocation() from public,anon,authenticated,service_role;

create function api.get_legacy_invoice_accounting_review(p_review_id uuid) returns jsonb
language plpgsql volatile security definer set search_path=pg_catalog,pg_temp as $$
declare r billing.legacy_invoice_accounting_reviews%rowtype;x billing.legacy_invoice_accounting_resolutions%rowtype;b record;
begin
 select * into r from billing.legacy_invoice_accounting_reviews where id=p_review_id;
 if not found or auth.uid() is null or not coalesce(iam.has_well_role(r.well_id,array['owner']),false) then
  raise exception 'legacy_invoice_review_owner_required' using errcode='42501';end if;
 select * into x from billing.legacy_invoice_accounting_resolutions where review_id=r.id;
 select * into b from billing.invoice_effective_balances where invoice_id=r.invoice_id;
 return jsonb_build_object('review_id',r.id,'invoice_id',r.invoice_id,'review',to_jsonb(r),'resolution',to_jsonb(x),
  'status',coalesce(x.decision,'accounting_review_required'),'invoice_amount_minor',b.total_minor,
  'confirmed_historical_amount_minor',r.confirmed_historical_amount_minor,'remaining_amount_minor',b.outstanding_minor,
  'collectible_amount_minor',b.collectible_minor,'held_amount_minor',b.collection_hold_minor,
  'title',case when x.decision='confirmed_non_cash_settlement' then 'تم تأكيد المبلغ المستخدم سابقًا' else 'مراجعة مبلغ قديم' end,
  'message',case when x.decision='confirmed_non_cash_settlement' then 'تم تحديث المبلغ المتبقي ولن يتم تحصيل الجزء المستخدم مرة أخرى.'
   when x.decision='confirmed_not_settled' then 'سيعود هذا المبلغ متاحًا للتحصيل.'
   else 'هذا المبلغ مرتبط بتوزيع سابق ويحتاج منك تحديد حالته قبل أن يستخدمه النظام مرة أخرى.' end,
  'settled_action','تمت تسويته سابقًا','not_settled_action','لم تتم تسويته');
end;$$;
revoke all on function api.get_legacy_invoice_accounting_review(uuid) from public,anon,authenticated,service_role;
grant execute on function api.get_legacy_invoice_accounting_review(uuid) to authenticated;

-- Do not allow a direct INSERT on a reviewed default destination to enter the
-- payment triggers before root ownership. This guard asserts ownership; it
-- NEVER acquires the advisory root while already holding a financial child.
create function billing.guard_reviewed_default_payment() returns trigger
language plpgsql security definer set search_path=pg_catalog,pg_temp as $$
declare inv uuid;w uuid;key bigint;
begin
 for inv,w in select i.id,i.well_id from billing.invoices i join billing.session_charges c on c.session_id=i.session_id
  join billing.legacy_invoice_accounting_reviews r on r.invoice_id=i.id where c.id=new.session_charge_id loop
  key:=hashtextextended('customer-credit-well:'||w::text,0);
  if not exists(select 1 from pg_locks l where l.pid=pg_backend_pid() and l.locktype='advisory' and l.granted
   and l.objsubid=1 and l.classid=((key>>32)&4294967295)::oid and l.objid=(key&4294967295)::oid) then
   raise exception 'reviewed_invoice_use_sanctioned_payment' using errcode='42501';end if;
  perform billing.require_no_disputed_invoice(inv,new.amount_minor);
 end loop;return new;
end;$$;
create trigger zz_legacy_review_default_payment before insert on billing.payments
 for each row execute function billing.guard_reviewed_default_payment();
revoke all on function billing.guard_reviewed_default_payment() from public,anon,authenticated,service_role;
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
    select coalesce(sum(effective.outstanding_minor), 0) into v_irrigation
    from billing.invoices i
    join billing.invoice_effective_balances effective on effective.invoice_id=i.id
    join core.partner_irrigation_policies pol on pol.id = i.partner_policy_id
    where pol.partner_id = v_share.partner_id
      and i.status in ('issued', 'partially_paid', 'overdue')
      and i.invoice_date < p_period_end
      and i.deducted_in_cycle_id is null
      and not exists(select 1 from billing.legacy_invoice_review_effects held where held.invoice_id=i.id and held.disputed_minor>0);

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
  if exists(select 1 from finance.profit_distribution_lines l where l.distribution_cycle_id=p_cycle_id
   and exists(select 1 from billing.legacy_invoice_review_effects e where e.well_id=v_cycle.well_id and e.partner_id=l.partner_id)
   and l.irrigation_deductions_minor<>(select coalesce(sum(b.outstanding_minor),0)
    from billing.invoices i join billing.invoice_effective_balances b on b.invoice_id=i.id
    join core.partner_irrigation_policies pol on pol.id=i.partner_policy_id
    where pol.partner_id=l.partner_id and i.well_id=v_cycle.well_id
    and i.status in ('issued','partially_paid','overdue') and i.invoice_date<v_cycle.period_end and i.deducted_in_cycle_id is null)) then
   raise exception 'distribution_amounts_require_refresh' using errcode='23514',detail=
    '{"status":"review_required","title":"تغيّرت مبالغ مرتبطة بهذا التوزيع","message":"أعد حساب الدورة وراجع النتيجة قبل الاعتماد.","action":"إعادة الحساب"}';end if;
  if exists (select 1 from finance.profit_distribution_lines l
             where l.distribution_cycle_id = p_cycle_id and l.net_payable_minor < 0) then
    raise exception 'لا يمكن الاعتماد: يوجد شريك صافي مستحقه سالب — راجع الاستقطاعات';
  end if;

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
    select * from finance.profit_distribution_lines where distribution_cycle_id = p_cycle_id
  loop
    if v_line.gross_share_minor = 0 and v_line.partner_receivables_minor = 0 then
      continue;
    end if;
    insert into finance.journal_entries (tenant_id, public_code, well_id, entry_date, source_type, source_id, description, idempotency_key)
    values (v_cycle.tenant_id, core.generate_public_code('JE'), v_cycle.well_id, now(),
            'profit_distribution', v_line.id, 'مستحقات شريك من دورة التوزيع ' || v_cycle.public_code,
            'PDC-' || v_line.id::text)
    returning id into v_je;
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
    values (v_cycle.tenant_id, v_je, v_acc3200, 'debit', v_line.gross_share_minor, v_line.partner_id, 'حصة الشريك الاجمالية');
    if v_line.partner_receivables_minor > 0 then
      insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
      values (v_cycle.tenant_id, v_je, v_acc2400, 'debit', v_line.partner_receivables_minor, v_line.partner_id, 'تسوية مبالغ كانت مستحقة للشريك');
    end if;
    insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
    values (v_cycle.tenant_id, v_je, v_acc2100, 'credit', v_line.net_payable_minor, v_line.partner_id, 'صافي مستحق الشريك');
    if v_line.irrigation_deductions_minor > 0 then
      insert into finance.journal_lines (tenant_id, journal_entry_id, ledger_account_id, entry_side, amount_minor, partner_id, description)
      values (v_cycle.tenant_id, v_je, v_acc1100, 'credit', v_line.irrigation_deductions_minor, v_line.partner_id, 'خصم قيمة سقيه من ديون المزارعين');
    end if;
    perform finance.post_journal_entry(v_je, p_approved_by);
  end loop;

  -- تعليم المسواة: المصروفات المدفوعة من الشركاء والفواتير المخصومة لا تحسب مرة اخرى
  update finance.expenses e set settled_in_cycle_id = p_cycle_id
  where e.well_id = v_cycle.well_id and e.payment_source = 'partner_paid'
    and e.status = 'posted' and e.spent_at < v_cycle.period_end
    and e.settled_in_cycle_id is null;

  update billing.invoices i set deducted_in_cycle_id = p_cycle_id
  from core.partner_irrigation_policies pol
  where i.partner_policy_id = pol.id
    and i.well_id = v_cycle.well_id
    and i.status in ('issued', 'partially_paid', 'overdue')
    and i.outstanding_minor > 0
    and i.invoice_date < v_cycle.period_end
    and i.deducted_in_cycle_id is null;

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

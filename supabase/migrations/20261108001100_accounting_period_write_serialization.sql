-- R6-C2B coordinated financial boundaries, static implementation.
-- Apply with the complete follow-up set through 024; owner DB verification pending.
-- Deep period/posting helpers assert existing root ownership.
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
-- R6-C2A: every application accounting-period writer takes the existing
-- C0.2 financial well serialization BEFORE period/request/child row locks.
-- No new lock namespace. CREATE OR REPLACE retains existing function ACLs.
-- Legacy direct DML is replaced by the existing narrow business functions.
revoke insert, update, delete, truncate, references, trigger on finance.accounting_periods
 from public,anon,authenticated,service_role;
-- Remove column grants as well; table REVOKE alone does not remove them.
do $acl$
declare rel regclass;col record;
begin
 foreach rel in array array['finance.accounting_periods'::regclass,
  'finance.period_reopen_requests'::regclass,'finance.period_reopen_approvals'::regclass] loop
  execute format('revoke insert,update,delete,truncate,references,trigger on %s from public,anon,authenticated,service_role',rel);
  for col in select attname from pg_attribute where attrelid=rel and attnum>0 and not attisdropped loop
   execute format('revoke insert (%I),update (%I),references (%I) on %s from public,anon,authenticated,service_role',
    col.attname,col.attname,col.attname,rel);
  end loop;
 end loop;
end;$acl$;
-- SELECT ACLs/policies are deliberately unchanged. No generic mutation API.
drop policy if exists accounting_periods_insert_owner_manager on finance.accounting_periods;
drop policy if exists accounting_periods_update_owner_manager on finance.accounting_periods;
drop policy if exists period_reopen_requests_insert_owner_manager on finance.period_reopen_requests;
drop policy if exists period_reopen_requests_update_owner_manager on finance.period_reopen_requests;
drop policy if exists period_reopen_approvals_insert_member on finance.period_reopen_approvals;

-- Internal scope discovery is not authority. Re-fetch under the period row
-- lock after acquiring financial serialization; never accept a moved scope.
create function finance.lock_period_write(p_period_id uuid)
returns finance.accounting_periods language plpgsql volatile security definer
set search_path=pg_catalog,pg_temp as $$
declare candidate finance.accounting_periods%rowtype;locked finance.accounting_periods%rowtype;
begin
 select ap.* into candidate from finance.accounting_periods ap where ap.id=p_period_id;
 if not found then raise exception 'الفترة غير موجودة: %',p_period_id;end if;
 perform billing.require_customer_credit_well_lock(candidate.well_id);
 perform 1 from finance.accounting_periods ap where ap.well_id=candidate.well_id order by ap.id for update of ap;
 select ap.* into locked from finance.accounting_periods ap where ap.id=p_period_id for update of ap;
 if not found then raise exception 'الفترة غير موجودة: %',p_period_id;end if;
 if (locked.tenant_id,locked.well_id,locked.period_type,locked.starts_at,locked.ends_at)
  is distinct from(candidate.tenant_id,candidate.well_id,candidate.period_type,candidate.starts_at,candidate.ends_at)
  or not exists(select 1 from core.wells w where w.id=locked.well_id and w.tenant_id=locked.tenant_id) then
  raise exception 'accounting_period_scope_changed' using errcode='40001';end if;
 return locked;
end;$$;
revoke all on function finance.lock_period_write(uuid) from public,anon,authenticated,service_role;

create or replace function finance.ensure_periods(p_well_id uuid, p_date date)
returns void language plpgsql security definer
set search_path=pg_catalog,pg_temp as $$
declare
  v_tenant uuid;
begin
  perform billing.require_customer_credit_well_lock(p_well_id);
  select tenant_id into v_tenant from core.wells where id = p_well_id;
  insert into finance.accounting_periods (tenant_id, well_id, period_type, starts_at, ends_at)
  values (v_tenant, p_well_id, 'monthly', date_trunc('month', p_date)::date,
          (date_trunc('month', p_date) + interval '1 month - 1 day')::date)
  on conflict (well_id, period_type, starts_at) do nothing;
  insert into finance.accounting_periods (tenant_id, well_id, period_type, starts_at, ends_at)
  values (v_tenant, p_well_id, 'yearly', make_date(extract(year from p_date)::int, 1, 1),
          make_date(extract(year from p_date)::int, 12, 31))
  on conflict (well_id, period_type, starts_at) do nothing;
end;
$$;

create or replace function finance.close_period(p_period_id uuid, p_closed_by uuid)
returns void language plpgsql security definer
set search_path=pg_catalog,pg_temp as $$
declare
  v_per record;
  v_open_months int;
  candidate_well uuid;
begin
  select ap.well_id into candidate_well from finance.accounting_periods ap where ap.id=p_period_id;
  if not found then raise exception 'الفترة غير موجودة: %',p_period_id;end if;
  if auth.uid() is not null then
    if p_closed_by is distinct from auth.uid() or not iam.has_well_permission(candidate_well,'period.close') then
      raise exception 'لا تملك صلاحية إغلاق هذه الفترة';end if;
  end if;
  perform billing.lock_customer_credit_well((select well_id from finance.accounting_periods where id=p_period_id));
  v_per := finance.lock_period_write(p_period_id);
  -- The API already checks period.close; repeat its policy after waiting.
  -- Owner/internal calls without JWT context retain their existing contract.
  if auth.uid() is not null then
    if p_closed_by is distinct from auth.uid() or not iam.has_well_permission(v_per.well_id,'period.close') then
      raise exception 'لا تملك صلاحية إغلاق هذه الفترة';
    end if;
  end if;
  if v_per is null then raise exception 'الفترة غير موجودة: %', p_period_id; end if;
  if v_per.status = 'closed' then raise exception 'الفترة مغلقة مسبقًا'; end if;
  if v_per.period_type = 'yearly' then
    select count(*) into v_open_months
    from finance.accounting_periods m
    where m.well_id = v_per.well_id and m.period_type = 'monthly'
      and m.starts_at >= v_per.starts_at and m.ends_at <= v_per.ends_at
      and m.status <> 'closed';
    if v_open_months > 0 then
      raise exception 'لا يمكن إقفال الفترة السنوية قبل إقفال جميع فتراتها الشهرية (المتبقي: %)', v_open_months;
    end if;
  end if;
  update finance.accounting_periods
  set status = 'closed', closed_at = now(), closed_by = p_closed_by
  where id = p_period_id;
end;
$$;

create or replace function finance.request_period_reopen(p_period_id uuid, p_requested_by uuid, p_reason text)
returns uuid language plpgsql security definer
set search_path=pg_catalog,pg_temp as $$
declare
  v_per record;
  v_id uuid;
begin
  if auth.uid() is not null and(p_requested_by is distinct from auth.uid() or not coalesce(iam.has_well_role((select well_id from finance.accounting_periods where id=p_period_id),array['owner','manager']),false)) then raise exception 'period_reopen_request_forbidden' using errcode='42501';end if;
  if p_reason is null or btrim(p_reason) = '' then raise exception 'يجب ذكر سبب طلب إعادة الفتح'; end if;
  perform billing.lock_customer_credit_well((select well_id from finance.accounting_periods where id=p_period_id));
  v_per := finance.lock_period_write(p_period_id);
  if auth.uid() is not null and(p_requested_by is distinct from auth.uid() or not coalesce(iam.has_well_role(v_per.well_id,array['owner','manager']),false)) then raise exception 'period_reopen_request_forbidden' using errcode='42501';end if;
  if v_per is null then raise exception 'الفترة غير موجودة: %', p_period_id; end if;
  if v_per.status <> 'closed' then
    raise exception 'لا يمكن طلب إعادة فتح فترة حالتها % — يجب أن تكون مغلقة', v_per.status;
  end if;
  if exists (select 1 from finance.period_reopen_requests r
             where r.period_id = p_period_id and r.status in ('pending', 'partners_approved')) then
    raise exception 'يوجد طلب إعادة فتح قائم لهذه الفترة';
  end if;
  insert into finance.period_reopen_requests (tenant_id, period_id, requested_by, reason)
  values (v_per.tenant_id, p_period_id, p_requested_by, p_reason) returning id into v_id;
  insert into ops.notifications (recipient_profile_id, well_id, type, message)
  select wp.profile_id, v_per.well_id, 'period_reopen_requested',
    format('طُلب إعادة فتح فترة محاسبية مغلقة (%s الى %s). السبب: %s — صوّت من حسابك',
           v_per.starts_at, v_per.ends_at, p_reason)
  from core.well_partners wp
  where wp.well_id = v_per.well_id and wp.status = 'active'
    and wp.period_end is null and wp.profile_id is not null;
  return v_id;
end;
$$;

create or replace function finance.approve_period_reopen(p_request_id uuid, p_partner_id uuid)
returns void language plpgsql security definer
set search_path=pg_catalog,pg_temp as $$
declare
  v_req record;
  v_total int;
  v_votes int;
  v_needed int;
  candidate record;
  locked_period finance.accounting_periods%rowtype;
begin
  select r.period_id,r.tenant_id,ap.well_id into candidate
  from finance.period_reopen_requests r join finance.accounting_periods ap on ap.id=r.period_id
  where r.id=p_request_id;
  if not found then raise exception 'الطلب غير موجود: %',p_request_id;end if;
  if not exists(select 1 from core.well_partners wp where wp.id=p_partner_id
   and wp.well_id=candidate.well_id and wp.status='active' and wp.period_end is null
   and(auth.uid() is null or wp.profile_id=auth.uid())) then
   raise exception 'الشريك غير موجود أو غير نشط في هذا البئر';end if;
  perform billing.lock_customer_credit_well(candidate.well_id);
  locked_period := finance.lock_period_write(candidate.period_id);
  select r.id,r.tenant_id,r.period_id,r.status,locked_period.well_id as well_id into v_req
  from finance.period_reopen_requests r where r.id=p_request_id for update of r;
  if not found then raise exception 'الطلب غير موجود: %',p_request_id;end if;
  if (v_req.period_id,v_req.tenant_id,locked_period.well_id)
   is distinct from(candidate.period_id,candidate.tenant_id,candidate.well_id)
   or v_req.tenant_id<>locked_period.tenant_id then
   raise exception 'period_reopen_scope_changed' using errcode='40001';end if;
  if v_req.status <> 'pending' then raise exception 'لا يمكن التصويت على طلب حالته %', v_req.status; end if;
  if not exists (select 1 from core.well_partners wp
                 where wp.id = p_partner_id and wp.well_id = v_req.well_id
                   and wp.status = 'active' and wp.period_end is null
                   and(auth.uid() is null or wp.profile_id=auth.uid())) then
    raise exception 'الشريك غير موجود أو غير نشط في هذا البئر';
  end if;
  insert into finance.period_reopen_approvals (tenant_id, request_id, partner_id)
  values (v_req.tenant_id, p_request_id, p_partner_id);
  select count(*) into v_total from core.well_partners
  where well_id = v_req.well_id and status = 'active' and period_end is null;
  select count(*) into v_votes from finance.period_reopen_approvals where request_id = p_request_id;
  v_needed := ceil(v_total * 0.7)::int;
  if v_votes >= v_needed then
    update finance.period_reopen_requests set status = 'partners_approved' where id = p_request_id;
    insert into ops.notifications (recipient_profile_id, well_id, type, message)
    select pr.id, v_req.well_id, 'period_reopen_ready',
      format('اكتمل تصويت الشركاء (%s من %s) على طلب إعادة فتح فترة — بانتظار قرار الإدارة العامة', v_votes, v_total)
    from iam.profiles pr where pr.is_platform_admin;
  end if;
end;
$$;

create or replace function finance.decide_period_reopen(p_request_id uuid, p_admin_profile_id uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer
set search_path=pg_catalog,pg_temp as $$
declare
  v_req record;
  v_well uuid;
  candidate record;
  locked_period finance.accounting_periods%rowtype;
begin
  if not exists (select 1 from iam.profiles pr where pr.id = p_admin_profile_id and pr.is_platform_admin and(auth.uid() is null or pr.id=auth.uid())) then
    raise exception 'هذا القرار خاص بالإدارة العامة للتطبيق فقط';
  end if;
  select r.period_id,r.tenant_id,ap.well_id into candidate
  from finance.period_reopen_requests r join finance.accounting_periods ap on ap.id=r.period_id
  where r.id=p_request_id;
  if not found then raise exception 'الطلب غير موجود';end if;
  perform billing.lock_customer_credit_well(candidate.well_id);
  locked_period := finance.lock_period_write(candidate.period_id);
  select r.* into v_req from finance.period_reopen_requests r where r.id=p_request_id for update of r;
  if not found then raise exception 'الطلب غير موجود';end if;
  if (v_req.period_id,v_req.tenant_id,locked_period.well_id)
   is distinct from(candidate.period_id,candidate.tenant_id,candidate.well_id)
   or v_req.tenant_id<>locked_period.tenant_id then
   raise exception 'period_reopen_scope_changed' using errcode='40001';end if;
  -- Platform-admin authority must still hold after the serialization wait.
  if not exists(select 1 from iam.profiles pr where pr.id=p_admin_profile_id and pr.is_platform_admin and(auth.uid() is null or pr.id=auth.uid())) then
   raise exception 'هذا القرار خاص بالإدارة العامة للتطبيق فقط';end if;
  if v_req.status <> 'partners_approved' then
    raise exception 'لا يمكن البت قبل اكتمال تصويت الشركاء (الحالة الحالية: %)', v_req.status;
  end if;
  update finance.period_reopen_requests
  set status = case when p_approve then 'approved' else 'rejected' end,
      decided_at = now(), decided_by = p_admin_profile_id, decision_note = p_note
  where id = p_request_id;
  v_well := locked_period.well_id;
  if p_approve then
    update finance.accounting_periods
    set status = 'reopened', reopened_at = now(), reopened_by = p_admin_profile_id
    where id = v_req.period_id;
  end if;
  perform ops.notify_profile(v_req.requested_by, v_well,
    case when p_approve then 'period_reopen_approved' else 'period_reopen_rejected' end,
    case when p_approve then 'وافقت الإدارة العامة على إعادة فتح الفترة — أصبح الترحيل عليها متاحًا'
         else 'رفضت الإدارة العامة طلب إعادة فتح الفترة' end);
end;
$$;

create or replace function finance.post_journal_entry(p_entry_id uuid, p_posted_by uuid default null)
returns void language plpgsql security definer
set search_path=pg_catalog,pg_temp as $$
declare
  v_status text;
  v_debit bigint;
  v_credit bigint;
  v_lines integer;
  v_well uuid;
  v_date date;
  candidate_well uuid;
begin
  select well_id into candidate_well from finance.journal_entries where id=p_entry_id;
  if not found then raise exception 'القيد غير موجود: %',p_entry_id;end if;
  perform billing.require_customer_credit_well_lock(candidate_well);
  select status, well_id, entry_date::date into v_status, v_well, v_date
  from finance.journal_entries where id = p_entry_id for update;
  if v_well is distinct from candidate_well then
    raise exception 'journal_scope_changed' using errcode='40001';end if;
  if v_status is null then raise exception 'القيد غير موجود: %', p_entry_id; end if;
  if v_status <> 'draft' then
    raise exception 'لا يمكن ترحيل قيد حالته % — يجب أن يكون مسودة', v_status;
  end if;
  select count(*),
    coalesce(sum(case when entry_side = 'debit' then amount_minor else 0 end), 0),
    coalesce(sum(case when entry_side = 'credit' then amount_minor else 0 end), 0)
  into v_lines, v_debit, v_credit
  from finance.journal_lines where journal_entry_id = p_entry_id;
  if v_lines < 2 then
    raise exception 'القيد يجب أن يحتوي طرفين على الأقل (الموجود: %)', v_lines;
  end if;
  if v_debit <> v_credit then
    raise exception 'القيد غير متوازن: مجموع المدين % لا يساوي مجموع الدائن %', v_debit, v_credit;
  end if;
  perform finance.ensure_periods(v_well, v_date);
  perform 1 from finance.accounting_periods ap where ap.well_id=v_well and v_date between ap.starts_at and ap.ends_at order by ap.id for share of ap;
  if exists (select 1 from finance.accounting_periods ap
             where ap.well_id = v_well
               and v_date between ap.starts_at and ap.ends_at
               and ap.status = 'closed') then
    raise exception 'لا يمكن ترحيل القيد: الفترة المحاسبية المحتوية للتاريخ % مغلقة', v_date;
  end if;
  update finance.journal_entries
  set status = 'posted', posted_at = now(), posted_by = p_posted_by
  where id = p_entry_id;
end;
$$;

-- Replacing existing routines preserves their signatures, SECURITY DEFINER
-- semantics and ACLs. The only new helper remains owner-only. No API grant.
-- Audit trigger, audit function and audit well FK are unchanged.
revoke all on function finance.post_journal_entry(uuid,uuid),finance.ensure_periods(uuid,date) from public,anon,authenticated,service_role;
commit;

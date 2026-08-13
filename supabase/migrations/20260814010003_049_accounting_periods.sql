-- المرحلة 5 - الملف 049 (ق-73): الفترات الشهرية والسنوية، الاقفال المباشر،
-- اعادة الفتح بتصويت 70 بالمئة من عدد الشركاء ثم موافقة المدير العام (doc03 قسم 32 الخطوة 5)

create table finance.accounting_periods (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  period_type text not null check (period_type in ('monthly', 'yearly')),
  starts_at date not null,
  ends_at date not null,
  status text not null default 'open'
    check (status in ('open', 'reviewing', 'closed', 'reopened')),
  closed_at timestamptz,
  closed_by uuid references iam.profiles(id),
  reopened_at timestamptz,
  reopened_by uuid references iam.profiles(id),
  created_at timestamptz not null default now(),
  unique (well_id, period_type, starts_at),
  check (ends_at >= starts_at)
);
create index accounting_periods_well_idx on finance.accounting_periods (well_id, period_type, starts_at desc);

alter table finance.accounting_periods enable row level security;
create policy accounting_periods_select on finance.accounting_periods for select
  using (iam.has_well_role(well_id, array['owner', 'manager']) or iam.is_well_partner(well_id));
create policy accounting_periods_insert_owner_manager on finance.accounting_periods for insert
  with check (iam.has_well_role(well_id, array['owner', 'manager']));
create policy accounting_periods_update_owner_manager on finance.accounting_periods for update
  using (iam.has_well_role(well_id, array['owner', 'manager']));
grant select, insert, update on finance.accounting_periods to authenticated;

create table finance.period_reopen_requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  period_id uuid not null references finance.accounting_periods(id) on delete cascade,
  requested_by uuid not null references iam.profiles(id),
  reason text not null,
  status text not null default 'pending'
    check (status in ('pending', 'partners_approved', 'approved', 'rejected', 'cancelled')),
  decided_at timestamptz,
  decided_by uuid references iam.profiles(id),
  decision_note text,
  created_at timestamptz not null default now()
);
create index period_reopen_requests_period_idx on finance.period_reopen_requests (period_id, status);

alter table finance.period_reopen_requests enable row level security;
create policy period_reopen_requests_select on finance.period_reopen_requests for select
  using (exists (
    select 1 from finance.accounting_periods ap
    where ap.id = period_reopen_requests.period_id
      and (iam.has_well_role(ap.well_id, array['owner', 'manager']) or iam.is_well_partner(ap.well_id))));
create policy period_reopen_requests_insert_owner_manager on finance.period_reopen_requests for insert
  with check (exists (
    select 1 from finance.accounting_periods ap
    where ap.id = period_reopen_requests.period_id
      and iam.has_well_role(ap.well_id, array['owner', 'manager'])));
create policy period_reopen_requests_update_owner_manager on finance.period_reopen_requests for update
  using (exists (
    select 1 from finance.accounting_periods ap
    where ap.id = period_reopen_requests.period_id
      and iam.has_well_role(ap.well_id, array['owner', 'manager'])));
grant select, insert, update on finance.period_reopen_requests to authenticated;

create table finance.period_reopen_approvals (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  request_id uuid not null references finance.period_reopen_requests(id) on delete cascade,
  partner_id uuid not null references core.well_partners(id),
  created_at timestamptz not null default now(),
  unique (request_id, partner_id)
);

alter table finance.period_reopen_approvals enable row level security;
create policy period_reopen_approvals_select on finance.period_reopen_approvals for select
  using (exists (
    select 1 from finance.period_reopen_requests r
    join finance.accounting_periods ap on ap.id = r.period_id
    where r.id = period_reopen_approvals.request_id
      and (iam.has_well_role(ap.well_id, array['owner', 'manager']) or iam.is_well_partner(ap.well_id))));
create policy period_reopen_approvals_insert_member on finance.period_reopen_approvals for insert
  with check (exists (
    select 1 from finance.period_reopen_requests r
    join finance.accounting_periods ap on ap.id = r.period_id
    where r.id = period_reopen_approvals.request_id
      and iam.has_well_role(ap.well_id, array['owner', 'manager', 'partner'])));
grant select, insert on finance.period_reopen_approvals to authenticated;

alter table ops.notifications drop constraint if exists notifications_type_check;
alter table ops.notifications add constraint notifications_type_check
  check (type in (
    'long_session', 'approaching_long_session', 'distribution_finalized', 'expense_recorded',
    'handover_declared', 'handover_confirmed', 'handover_difference', 'handover_settled',
    'shift_opened', 'shift_closed', 'shift_open_too_long', 'shift_blocked',
    'session_transfer_requested', 'session_transfer_accepted', 'session_transfer_rejected',
    'period_reopen_requested', 'period_reopen_ready', 'period_reopen_approved', 'period_reopen_rejected'
  ));

create or replace function finance.ensure_periods(p_well_id uuid, p_date date)
returns void language plpgsql security definer
set search_path to 'finance', 'core', 'pg_temp' as $$
declare
  v_tenant uuid;
begin
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
set search_path to 'finance', 'core', 'pg_temp' as $$
declare
  v_per record;
  v_open_months int;
begin
  select * into v_per from finance.accounting_periods where id = p_period_id for update;
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
set search_path to 'finance', 'core', 'ops', 'pg_temp' as $$
declare
  v_per record;
  v_id uuid;
begin
  if p_reason is null or btrim(p_reason) = '' then raise exception 'يجب ذكر سبب طلب إعادة الفتح'; end if;
  select * into v_per from finance.accounting_periods where id = p_period_id;
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
set search_path to 'finance', 'core', 'ops', 'iam', 'pg_temp' as $$
declare
  v_req record;
  v_total int;
  v_votes int;
  v_needed int;
begin
  select r.id, r.tenant_id, r.period_id, r.status, ap.well_id
  into v_req
  from finance.period_reopen_requests r
  join finance.accounting_periods ap on ap.id = r.period_id
  where r.id = p_request_id for update;
  if v_req is null then raise exception 'الطلب غير موجود: %', p_request_id; end if;
  if v_req.status <> 'pending' then raise exception 'لا يمكن التصويت على طلب حالته %', v_req.status; end if;
  if not exists (select 1 from core.well_partners wp
                 where wp.id = p_partner_id and wp.well_id = v_req.well_id
                   and wp.status = 'active' and wp.period_end is null) then
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
set search_path to 'finance', 'ops', 'pg_temp' as $$
declare
  v_req record;
  v_well uuid;
begin
  if not exists (select 1 from iam.profiles pr where pr.id = p_admin_profile_id and pr.is_platform_admin) then
    raise exception 'هذا القرار خاص بالإدارة العامة للتطبيق فقط';
  end if;
  select * into v_req from finance.period_reopen_requests where id = p_request_id for update;
  if v_req is null then raise exception 'الطلب غير موجود'; end if;
  if v_req.status <> 'partners_approved' then
    raise exception 'لا يمكن البت قبل اكتمال تصويت الشركاء (الحالة الحالية: %)', v_req.status;
  end if;
  update finance.period_reopen_requests
  set status = case when p_approve then 'approved' else 'rejected' end,
      decided_at = now(), decided_by = p_admin_profile_id, decision_note = p_note
  where id = p_request_id;
  select well_id into v_well from finance.accounting_periods where id = v_req.period_id;
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

-- الخطوة 5 المؤجلة من قسم 32: منع الترحيل في فترة مغلقة
create or replace function finance.post_journal_entry(p_entry_id uuid, p_posted_by uuid default null)
returns void language plpgsql security definer
set search_path to 'finance', 'public' as $$
declare
  v_status text;
  v_debit bigint;
  v_credit bigint;
  v_lines integer;
  v_well uuid;
  v_date date;
begin
  select status, well_id, entry_date::date into v_status, v_well, v_date
  from finance.journal_entries where id = p_entry_id for update;
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

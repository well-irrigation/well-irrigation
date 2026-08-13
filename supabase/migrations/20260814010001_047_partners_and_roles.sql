-- المرحلة 5 - الملف 047 (ق-73): جدول الشركاء مصدرا وحيدا للنسب وصلاحية المالك

alter table core.well_assignments drop constraint well_assignments_role_check;
alter table core.well_assignments add constraint well_assignments_role_check
  check (role in ('owner', 'operator', 'farmer', 'manager', 'partner'));

alter table iam.profiles add column is_platform_admin boolean not null default false;

create table core.well_partners (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  person_id uuid not null references core.persons(id),
  profile_id uuid references iam.profiles(id),
  share_ppm integer not null check (share_ppm > 0 and share_ppm <= 1000000),
  phone text not null,
  national_id text,
  status text not null default 'active' check (status in ('active', 'inactive')),
  period_start date not null default current_date,
  period_end date,
  invited_at timestamptz,
  activated_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index well_partners_active_unique
  on core.well_partners (well_id, person_id) where period_end is null;
create index well_partners_well_idx on core.well_partners (well_id, status);
create index well_partners_profile_idx on core.well_partners (profile_id) where profile_id is not null;

alter table core.well_partners enable row level security;
create policy well_partners_select on core.well_partners for select
  using (iam.has_well_role(well_id, array['owner', 'manager']) or profile_id = auth.uid());
create policy well_partners_insert_owner on core.well_partners for insert
  with check (iam.has_well_role(well_id, array['owner']));
create policy well_partners_update_owner on core.well_partners for update
  using (iam.has_well_role(well_id, array['owner']));
grant select, insert, update on core.well_partners to authenticated;

create or replace function iam.is_well_partner(p_well_id uuid)
returns boolean language sql stable security definer
set search_path to 'core', 'pg_temp' as $$
  select exists (
    select 1 from core.well_partners wp
    where wp.well_id = p_well_id and wp.profile_id = auth.uid()
      and wp.status = 'active' and wp.period_end is null
  );
$$;

-- ترحيل بيانات حصص الملكية القديمة: اشخاص ثم شركاء
insert into core.persons (tenant_id, full_name, normalized_name)
select distinct w.tenant_id, p.full_name, p.full_name
from core.well_ownership_shares s
join iam.profiles p on p.id = s.profile_id
join core.wells w on w.id = s.well_id
where not exists (
  select 1 from core.persons pr
  where pr.tenant_id = w.tenant_id and pr.normalized_name = p.full_name
);

insert into core.well_partners (tenant_id, well_id, person_id, profile_id, share_ppm, phone, period_start, period_end)
select w.tenant_id, s.well_id, pr.id, s.profile_id, s.share_ppm,
       coalesce(p.phone, 'غير مسجل'), s.period_start, s.period_end
from core.well_ownership_shares s
join iam.profiles p on p.id = s.profile_id
join core.wells w on w.id = s.well_id
join core.persons pr on pr.tenant_id = w.tenant_id and pr.normalized_name = p.full_name
on conflict do nothing;

-- قيد اكتمال 100% على الشركاء
create or replace function core.check_well_partners_total()
returns trigger language plpgsql as $$
declare
  total integer;
  target_well_id uuid;
begin
  target_well_id := coalesce(new.well_id, old.well_id);
  select coalesce(sum(share_ppm), 0) into total
  from core.well_partners
  where well_id = target_well_id and period_end is null;
  if total <> 1000000 then
    raise exception 'مجموع نسب الشركاء الفعالين للبئر % يجب ان يساوي 1000000 بالضبط (100%%)، القيمة الحالية %',
      target_well_id, total;
  end if;
  return new;
end;
$$;

create constraint trigger well_partners_total_check
after insert or update on core.well_partners
deferrable initially deferred
for each row execute function core.check_well_partners_total();

-- اعادة كتابة اشعار الملاك ليقرا الشركاء (نفس التوقيع)
create or replace function ops.notify_well_owners(p_well_id uuid, p_type text, p_message text, p_session_id uuid default null)
returns integer language plpgsql security definer
set search_path to 'ops', 'core', 'pg_temp' as $$
declare
  v_count integer := 0;
begin
  insert into ops.notifications (recipient_profile_id, well_id, session_id, type, message)
  select distinct wp.profile_id, p_well_id, p_session_id, p_type, p_message
  from core.well_partners wp
  where wp.well_id = p_well_id and wp.status = 'active'
    and wp.period_end is null and wp.profile_id is not null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- سطور التوزيع تشير للشريك
alter table finance.distribution_lines
  add column partner_id uuid references core.well_partners(id);
alter table finance.distribution_lines
  alter column profile_id drop not null;
create unique index distribution_lines_batch_partner_unique
  on finance.distribution_lines (batch_id, partner_id);

-- اعادة كتابة توليد التوزيع: يقرا نسب الشركاء، ويحسب كل دفعات البئر
-- (بما فيها التحصيل بلا جلسة) ومصروفات finance.expenses المعتمدة
create or replace function finance.generate_distribution_batch(p_well_id uuid, p_period_start date, p_period_end date)
returns uuid language plpgsql security definer
set search_path to 'finance', 'billing', 'inventory', 'core', 'pg_temp' as $$
declare
  v_collected bigint;
  v_expenses bigint;
  v_net bigint;
  v_batch_id uuid;
  v_share record;
  v_remaining bigint;
  v_line_amount bigint;
  v_max_line_partner uuid;
  v_max_share_ppm int := -1;
begin
  select coalesce(sum(p.amount_minor), 0) into v_collected
  from billing.payments p
  where p.well_id = p_well_id and p.status <> 'reversed'
    and p.paid_at::date between p_period_start and p_period_end;

  select coalesce((
    select sum(x.amt) from (
      select fp.cost_minor as amt from inventory.fuel_purchases fp
      where fp.well_id = p_well_id and fp.purchased_at::date between p_period_start and p_period_end
      union all
      select e.amount_minor from finance.expenses e
      where e.well_id = p_well_id and e.status = 'posted'
        and e.spent_at::date between p_period_start and p_period_end
    ) x
  ), 0) into v_expenses;

  v_net := greatest(v_collected - v_expenses, 0);

  insert into finance.distribution_batches (well_id, period_start, period_end, total_amount_minor, status)
  values (p_well_id, p_period_start, p_period_end, v_net, 'draft')
  returning id into v_batch_id;

  v_remaining := v_net;
  for v_share in
    select id as partner_id, profile_id, share_ppm
    from core.well_partners
    where well_id = p_well_id
      and period_start <= p_period_end
      and (period_end is null or period_end >= p_period_end)
    order by share_ppm desc, id
  loop
    v_line_amount := (v_net * v_share.share_ppm) / 1000000;
    v_remaining := v_remaining - v_line_amount;
    insert into finance.distribution_lines (batch_id, partner_id, profile_id, share_ppm, amount_minor)
    values (v_batch_id, v_share.partner_id, v_share.profile_id, v_share.share_ppm, v_line_amount);
    if v_max_share_ppm = -1 then
      v_max_share_ppm := v_share.share_ppm;
      v_max_line_partner := v_share.partner_id;
    end if;
  end loop;

  -- تصحيح باقي القسمة لصاحب اكبر حصة (ق-67)
  if v_remaining <> 0 and v_max_line_partner is not null then
    update finance.distribution_lines
    set amount_minor = amount_minor + v_remaining
    where batch_id = v_batch_id and partner_id = v_max_line_partner;
  end if;

  return v_batch_id;
end;
$$;

-- اسقاط جدول الحصص القديم بعد الترحيل والاستبدال
drop trigger well_ownership_shares_total_check on core.well_ownership_shares;
drop function core.check_well_ownership_shares_total();
drop table core.well_ownership_shares;

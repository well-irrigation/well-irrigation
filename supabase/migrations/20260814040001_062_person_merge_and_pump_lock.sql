-- =====================================================================
-- 062 — ق-76: دمج الأشخاص المكررين + قفل التشغيل المتزامن للمضخة
-- 1) جدول طلبات الدمج (الوثيقة 02 قسم 7.5)
-- 2) تطبيع الاسم العربي والهاتف
-- 3) كاشف التكرار (تطابق / شك) قبل إنشاء شخص جديد
-- 4) إجراء الدمج الآمن مع حارس الأرصدة والتدقيق
-- 5) قواعد التزامن (الوثيقة 02 قسم 10.4) + قفل المضخة الافتراضي 1
-- =====================================================================

-- (1) جدول طلبات الدمج
create table core.person_merge_requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  primary_person_id uuid not null references core.persons(id),
  duplicate_person_id uuid not null references core.persons(id),
  requested_by uuid references iam.profiles(id),
  status text not null default 'pending' check (status in ('pending','merged','rejected')),
  reviewed_by uuid references iam.profiles(id),
  reviewed_at timestamptz,
  reason text,
  created_at timestamptz not null default now(),
  check (primary_person_id <> duplicate_person_id)
);
create index person_merge_requests_tenant_idx on core.person_merge_requests (tenant_id, created_at desc);

alter table core.person_merge_requests enable row level security;

create policy person_merge_requests_select_owner on core.person_merge_requests for select
  using (exists (select 1 from core.wells w where w.tenant_id = person_merge_requests.tenant_id and iam.has_well_role(w.id, array['owner'])));
create policy person_merge_requests_select_owner_manager on core.person_merge_requests for select to authenticated
  using (exists (select 1 from core.wells w where w.tenant_id = person_merge_requests.tenant_id and iam.has_well_role(w.id, array['manager'])));
create policy person_merge_requests_insert_owner on core.person_merge_requests for insert
  with check (exists (select 1 from core.wells w where w.tenant_id = person_merge_requests.tenant_id and iam.has_well_role(w.id, array['owner'])));
create policy person_merge_requests_insert_owner_manager on core.person_merge_requests for insert to authenticated
  with check (exists (select 1 from core.wells w where w.tenant_id = person_merge_requests.tenant_id and iam.has_well_role(w.id, array['manager'])));
create policy person_merge_requests_update_owner on core.person_merge_requests for update
  using (exists (select 1 from core.wells w where w.tenant_id = person_merge_requests.tenant_id and iam.has_well_role(w.id, array['owner'])));

grant select, insert, update on core.person_merge_requests to authenticated;

-- (2) تطبيع الاسم العربي: إزالة التشكيل والتطويل وتوحيد أشكال الحروف
create or replace function core.normalize_arabic(p_text text)
returns text
language plpgsql
immutable
as $fn$
declare
  v text;
begin
  v := lower(coalesce(p_text, ''));
  v := regexp_replace(v, '[ً-ٰـ]', '', 'g');
  v := replace(v, 'ء', '');
  v := translate(v, 'أإآٱئؤىة', 'ااااييوه');
  v := regexp_replace(v, '\s+', ' ', 'g');
  return nullif(btrim(v), '');
end;
$fn$;

-- تطبيع الهاتف: أرقام فقط ثم آخر 9 أرقام (يغطي مفتاح الدولة والصفر البادئ)
create or replace function core.normalize_phone(p_text text)
returns text
language plpgsql
immutable
as $fn$
declare
  v text;
begin
  v := regexp_replace(coalesce(p_text, ''), '\D', '', 'g');
  if length(v) >= 9 then
    v := right(v, 9);
  end if;
  return nullif(v, '');
end;
$fn$;

grant execute on function core.normalize_arabic(text) to authenticated;
grant execute on function core.normalize_phone(text) to authenticated;

-- (3) كاشف التكرار: يُستدعى من التطبيق قبل إنشاء شخص جديد
-- match = تطابق الاسم والهاتف معا | suspect = أحدهما فقط
create or replace function core.find_person_duplicates(p_tenant_id uuid, p_full_name text, p_phone text default null)
returns table (person_id uuid, public_code text, full_name text, match_level text, matched_on text)
language plpgsql
stable
security definer
set search_path = 'core', 'pg_temp'
as $fn$
declare
  v_name text := core.normalize_arabic(p_full_name);
  v_phone text := core.normalize_phone(p_phone);
begin
  return query
  with cand as (
    select p.id, p.public_code, p.full_name,
      (v_name is not null and (
        core.normalize_arabic(p.full_name) = v_name
        or similarity(core.normalize_arabic(p.full_name), v_name) >= 0.5
      )) as name_hit,
      (v_phone is not null and exists (
        select 1 from core.person_contacts pc
        where pc.person_id = p.id
          and pc.tenant_id = p_tenant_id
          and pc.contact_type in ('mobile','whatsapp','landline')
          and core.normalize_phone(pc.contact_value) = v_phone
      )) as phone_hit
    from core.persons p
    where p.tenant_id = p_tenant_id
      and p.status not in ('merged','archived')
  )
  select c.id, c.public_code, c.full_name,
    case when c.name_hit and c.phone_hit then 'match' else 'suspect' end,
    case
      when c.name_hit and c.phone_hit then 'name+phone'
      when c.phone_hit then 'phone'
      else 'name'
    end
  from cand c
  where c.name_hit or c.phone_hit
  order by (c.name_hit and c.phone_hit) desc, c.phone_hit desc, c.full_name;
end;
$fn$;

grant execute on function core.find_person_duplicates(uuid, text, text) to authenticated;

-- (4) إجراء الدمج الآمن: ينقل كل المراجع ويؤرشف المكرر ويسجل في التدقيق
create or replace function core.merge_persons(p_primary_id uuid, p_duplicate_id uuid, p_reason text default null, p_requested_by uuid default null)
returns uuid
language plpgsql
security definer
set search_path = 'core', 'ops', 'billing', 'finance', 'inventory', 'audit', 'pg_temp'
as $fn$
declare
  v_tenant uuid;
  v_req uuid;
begin
  if p_primary_id = p_duplicate_id then
    raise exception 'لا يمكن دمج الشخص في نفسه';
  end if;

  select p.tenant_id into v_tenant from core.persons p where p.id = p_primary_id;
  if v_tenant is null then
    raise exception 'الشخص الأساسي غير موجود: %', p_primary_id;
  end if;

  if not exists (select 1 from core.persons p where p.id = p_duplicate_id and p.tenant_id = v_tenant) then
    raise exception 'الشخص المكرر غير موجود أو يتبع مستأجرا آخر';
  end if;

  if exists (select 1 from core.persons p where p.id = p_duplicate_id and p.status in ('merged','archived')) then
    raise exception 'الشخص المكرر مؤرشف أو مدمج مسبقا';
  end if;

  -- حارس الأرصدة: لكل منهما ملف مزارع = حسابات وحركات مستقلة، الدمج الآلي مرفوض
  if exists (select 1 from ops.farmer_profiles fp where fp.person_id = p_primary_id)
     and exists (select 1 from ops.farmer_profiles fp where fp.person_id = p_duplicate_id) then
    raise exception 'لا يمكن الدمج آليا: لكل من الشخصين ملف مزارع بحساباته وحركاته — راجع المالك لمعالجة الأرصدة يدويا';
  end if;

  -- حارس الشراكات: كلاهما شريك نشط على نفس البئر
  if exists (
    select 1
    from core.well_partners w1
    join core.well_partners w2 on w2.well_id = w1.well_id and w2.person_id = p_duplicate_id and w2.period_end is null
    where w1.person_id = p_primary_id and w1.period_end is null
  ) then
    raise exception 'لا يمكن الدمج آليا: كلاهما شريك نشط على نفس البئر — راجع المالك';
  end if;

  -- نقل كل المراجع الى الأساسي
  update ops.farmer_profiles set person_id = p_primary_id where person_id = p_duplicate_id;
  update core.person_contacts set person_id = p_primary_id where person_id = p_duplicate_id;
  update core.person_aliases set person_id = p_primary_id where person_id = p_duplicate_id;
  update core.well_partners set person_id = p_primary_id where person_id = p_duplicate_id;
  update billing.payments set payer_person_id = p_primary_id where payer_person_id = p_duplicate_id;
  update inventory.fuel_transactions set owner_person_id = p_primary_id where owner_person_id = p_duplicate_id;
  update finance.journal_lines set person_id = p_primary_id where person_id = p_duplicate_id;
  update finance.opening_balance_items set person_id = p_primary_id where person_id = p_duplicate_id;
  update finance.payroll_accruals set person_id = p_primary_id where person_id = p_duplicate_id;
  update finance.worker_compensation_rules set person_id = p_primary_id where person_id = p_duplicate_id;
  update ops.session_segments set fuel_owner_person_id = p_primary_id where fuel_owner_person_id = p_duplicate_id;
  update core.persons set merged_into_person_id = p_primary_id where merged_into_person_id = p_duplicate_id;

  -- أرشفة المكرر وربطه بالأصلي
  update core.persons
  set status = 'archived', merged_into_person_id = p_primary_id, updated_at = now()
  where id = p_duplicate_id;

  -- تسجيل طلب الدمج
  insert into core.person_merge_requests (tenant_id, primary_person_id, duplicate_person_id, requested_by, status, reviewed_by, reviewed_at, reason)
  values (v_tenant, p_primary_id, p_duplicate_id, p_requested_by, 'merged', p_requested_by, now(), p_reason)
  returning id into v_req;

  -- التدقيق
  perform audit.log(v_tenant, null, 'person_merged', 'person', p_duplicate_id,
    jsonb_build_object('duplicate_person_id', p_duplicate_id),
    jsonb_build_object('merged_into', p_primary_id),
    p_reason);

  return v_req;
end;
$fn$;

grant execute on function core.merge_persons(uuid, uuid, text, uuid) to authenticated;

-- (5) قواعد التزامن (الوثيقة 02 قسم 10.4): الحد الأقصى للجلسات المتوازية لكل مورد
create table ops.resource_concurrency_rules (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  resource_type text not null check (resource_type in ('pump','well','water_line')),
  resource_id uuid,
  max_parallel_sessions integer not null default 1 check (max_parallel_sessions > 0),
  rule_status text not null default 'active' check (rule_status in ('active','disabled')),
  created_at timestamptz not null default now(),
  check (resource_type = 'well' or resource_id is not null)
);
create unique index resource_concurrency_rules_one_active
  on ops.resource_concurrency_rules (well_id, resource_type, coalesce(resource_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where rule_status = 'active';

alter table ops.resource_concurrency_rules enable row level security;

create policy rcr_select on ops.resource_concurrency_rules for select
  using (iam.has_well_role(well_id, array['owner','operator']) or iam.is_well_partner(well_id));
create policy rcr_select_manager on ops.resource_concurrency_rules for select to authenticated
  using (iam.has_well_role(well_id, array['manager','operator']));
create policy rcr_insert_owner on ops.resource_concurrency_rules for insert
  with check (iam.has_well_role(well_id, array['owner']));
create policy rcr_insert_owner_manager on ops.resource_concurrency_rules for insert to authenticated
  with check (iam.has_well_role(well_id, array['manager']));
create policy rcr_update_owner on ops.resource_concurrency_rules for update
  using (iam.has_well_role(well_id, array['owner']));
create policy rcr_update_owner_manager on ops.resource_concurrency_rules for update to authenticated
  using (iam.has_well_role(well_id, array['manager']));

grant select, insert, update on ops.resource_concurrency_rules to authenticated;

-- قفل المضخة: الافتراضي جلسة واحدة مفتوحة؛ قاعدة المضخة ثم قاعدة البئر ثم 1
create or replace function ops.prevent_parallel_sessions_on_pump()
returns trigger
language plpgsql
security definer
set search_path = 'ops', 'pg_temp'
as $fn$
declare
  v_limit integer;
  v_open integer;
begin
  if new.status is distinct from 'open' then
    return new;
  end if;

  select r.max_parallel_sessions into v_limit
  from ops.resource_concurrency_rules r
  where r.well_id = new.well_id
    and r.rule_status = 'active'
    and (r.resource_type = 'well' or (r.resource_type = 'pump' and r.resource_id = new.pump_id))
  order by case when r.resource_type = 'pump' then 0 else 1 end
  limit 1;

  v_limit := coalesce(v_limit, 1);

  select count(*) into v_open
  from ops.irrigation_sessions s
  where s.pump_id = new.pump_id and s.status = 'open';

  if v_open >= v_limit then
    raise exception 'لا يمكن فتح جلسة جديدة: المضخة مشغولة حاليا بجلسة لم تُغلق (الحد المسموح: %)', v_limit;
  end if;

  return new;
end;
$fn$;

create trigger irrigation_sessions_pump_concurrency
  before insert on ops.irrigation_sessions
  for each row execute function ops.prevent_parallel_sessions_on_pump();

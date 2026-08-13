-- المرحلة 4 - الملف 042
-- المناوبات: مناوبة مفتوحة واحدة لكل بئر (منع تام)، اقرار تسليم يؤكده المالك،
-- ونقل الجلسة الشغالة بين مناوبتين بموافقة الطرفين مع تحديد حق التحصيل.
-- المرجع: doc 03 §36.1 §36.2 + قرارات المالك

create table ops.shifts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  public_code text default core.generate_public_code('SHF'),
  operator_profile_id uuid not null references iam.profiles(id),
  cashbox_id uuid references finance.cashboxes(id),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  closed_at timestamptz,
  status text not null default 'open' check (status in ('open', 'handover_pending', 'closed', 'cancelled')),
  opening_cash_minor bigint not null default 0 check (opening_cash_minor >= 0),
  expected_cash_minor bigint,
  actual_cash_minor bigint,
  cash_difference_minor bigint,
  notes text,
  created_at timestamptz not null default now(),
  check (status <> 'open' or ended_at is null)
);

-- منع تام: مناوبة مفتوحة واحدة لكل بئر
create unique index shifts_one_open_per_well on ops.shifts (well_id) where status = 'open';
create index shifts_operator_idx on ops.shifts (operator_profile_id, started_at desc);
create index shifts_well_idx on ops.shifts (well_id, started_at desc);

alter table ops.shifts enable row level security;

create policy shifts_select_owner_operator on ops.shifts for select
  using (iam.has_well_role(well_id, array['owner', 'operator']));
create policy shifts_insert_owner_operator on ops.shifts for insert
  with check (iam.has_well_role(well_id, array['owner', 'operator']));
create policy shifts_update_owner_operator on ops.shifts for update
  using (iam.has_well_role(well_id, array['owner', 'operator']));

grant select, insert, update on ops.shifts to authenticated;

-- رسالة عربية واضحة بدل خطا الفهرس الفريد
create or replace function ops.prevent_second_open_shift()
returns trigger
language plpgsql
as $$
declare
  v_other record;
begin
  if new.status = 'open' then
    select s.id, s.operator_profile_id, s.started_at, p.full_name
    into v_other
    from ops.shifts s
    join iam.profiles p on p.id = s.operator_profile_id
    where s.well_id = new.well_id and s.status = 'open' and s.id <> new.id
    limit 1;

    if v_other.id is not null then
      raise exception 'لا يمكن بدء مناوبة جديدة: مناوبة % مفتوحة في هذا البئر منذ % ويجب اقفالها اولا (%)',
        coalesce(v_other.full_name, 'مشغل اخر'), v_other.started_at, v_other.id;
    end if;
  end if;
  return new;
end;
$$;

create trigger shifts_prevent_second_open
before insert or update on ops.shifts
for each row execute function ops.prevent_second_open_shift();

-- ═══ اقرارات التسليم ═══
create table ops.shift_handovers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  shift_id uuid not null references ops.shifts(id) on delete cascade,
  from_profile_id uuid not null references iam.profiles(id),
  to_profile_id uuid references iam.profiles(id),
  to_description text,
  declared_amount_minor bigint not null check (declared_amount_minor >= 0),
  confirmed_amount_minor bigint check (confirmed_amount_minor >= 0),
  difference_minor bigint,
  difference_reason text,
  status text not null default 'declared' check (status in ('declared', 'confirmed', 'difference_pending', 'settled', 'rejected')),
  declared_at timestamptz not null default now(),
  confirmed_by uuid references iam.profiles(id),
  confirmed_at timestamptz,
  note text,
  created_at timestamptz not null default now(),
  check (to_profile_id is not null or to_description is not null)
);

create index shift_handovers_shift_idx on ops.shift_handovers (shift_id);
create index shift_handovers_status_idx on ops.shift_handovers (well_id, status);

alter table ops.shift_handovers enable row level security;

create policy shift_handovers_select_owner_operator on ops.shift_handovers for select
  using (iam.has_well_role(well_id, array['owner', 'operator']));
create policy shift_handovers_insert_owner_operator on ops.shift_handovers for insert
  with check (iam.has_well_role(well_id, array['owner', 'operator']));
create policy shift_handovers_update_owner on ops.shift_handovers for update
  using (iam.has_well_role(well_id, array['owner']));

grant select, insert, update on ops.shift_handovers to authenticated;

-- ═══ نقل الجلسة الشغالة بين مناوبتين ═══
alter table ops.irrigation_sessions
  add column if not exists current_shift_id uuid references ops.shifts(id),
  add column if not exists collector_profile_id uuid references iam.profiles(id);

create table ops.session_shift_transfers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references core.tenants(id) on delete cascade,
  well_id uuid not null references core.wells(id) on delete cascade,
  session_id uuid not null references ops.irrigation_sessions(id) on delete cascade,
  from_shift_id uuid not null references ops.shifts(id) on delete cascade,
  to_shift_id uuid references ops.shifts(id),
  from_profile_id uuid not null references iam.profiles(id),
  to_profile_id uuid not null references iam.profiles(id),
  collection_right text not null check (collection_right in ('transfer_to_new', 'stay_with_previous')),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  requested_at timestamptz not null default now(),
  responded_at timestamptz,
  note text,
  created_at timestamptz not null default now(),
  unique (session_id, from_shift_id)
);

create index session_shift_transfers_pending_idx on ops.session_shift_transfers (to_profile_id, status);

alter table ops.session_shift_transfers enable row level security;

create policy session_shift_transfers_select_owner_operator on ops.session_shift_transfers for select
  using (iam.has_well_role(well_id, array['owner', 'operator']));
create policy session_shift_transfers_insert_owner_operator on ops.session_shift_transfers for insert
  with check (iam.has_well_role(well_id, array['owner', 'operator']));
create policy session_shift_transfers_update_owner_operator on ops.session_shift_transfers for update
  using (iam.has_well_role(well_id, array['owner', 'operator']));

grant select, insert, update on ops.session_shift_transfers to authenticated;

-- ═══ الدوال التي يستخدمها التطبيق ═══

-- بدء مناوبة: تربط الصندوق العام تلقائيا وتستقبل الجلسات المنقولة المقبولة
create or replace function ops.open_shift(p_well_id uuid, p_operator_profile_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'ops', 'core', 'finance', 'pg_temp'
as $$
declare
  v_shift_id uuid;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from core.wells where id = p_well_id;
  if v_tenant_id is null then
    raise exception 'البئر % غير موجود', p_well_id;
  end if;

  insert into ops.shifts (tenant_id, well_id, operator_profile_id, cashbox_id)
  values (v_tenant_id, p_well_id, p_operator_profile_id, finance.main_cashbox_id(p_well_id))
  returning id into v_shift_id;

  -- ربط الجلسات المنقولة المقبولة بالمناوبة الجديدة
  update ops.session_shift_transfers t
  set to_shift_id = v_shift_id
  where t.well_id = p_well_id
    and t.to_profile_id = p_operator_profile_id
    and t.status = 'accepted'
    and t.to_shift_id is null;

  update ops.irrigation_sessions s
  set current_shift_id = v_shift_id
  where s.id in (
    select t.session_id from ops.session_shift_transfers t
    where t.to_shift_id = v_shift_id and t.status = 'accepted'
  );

  perform ops.notify_well_owners(p_well_id, 'shift_opened',
    format('بدات مناوبة جديدة في البئر بواسطة المشغل %s', p_operator_profile_id));

  return v_shift_id;
end;
$$;

-- طلب نقل جلسة شغالة الى المشغل التالي
create or replace function ops.request_session_transfer(
  p_session_id uuid,
  p_from_shift_id uuid,
  p_to_profile_id uuid,
  p_collection_right text,
  p_note text default null
) returns uuid
language plpgsql
security definer
set search_path to 'ops', 'core', 'pg_temp'
as $$
declare
  v_id uuid;
  v_shift record;
begin
  select * into v_shift from ops.shifts where id = p_from_shift_id;
  if v_shift.id is null then
    raise exception 'المناوبة % غير موجودة', p_from_shift_id;
  end if;

  insert into ops.session_shift_transfers (
    tenant_id, well_id, session_id, from_shift_id, from_profile_id,
    to_profile_id, collection_right, note
  ) values (
    v_shift.tenant_id, v_shift.well_id, p_session_id, p_from_shift_id, v_shift.operator_profile_id,
    p_to_profile_id, p_collection_right, p_note
  ) returning id into v_id;

  perform ops.notify_profile(p_to_profile_id, v_shift.well_id, 'session_transfer_requested',
    case when p_collection_right = 'transfer_to_new'
      then 'طلب نقل جلسة سقي شغالة اليك مع حق تحصيل مبلغها'
      else 'طلب نقل ادارة جلسة سقي شغالة اليك بدون حق تحصيل مبلغها'
    end, p_session_id);

  return v_id;
end;
$$;

-- رد المشغل الجديد: قبول او رفض
create or replace function ops.respond_session_transfer(
  p_transfer_id uuid,
  p_accept boolean,
  p_to_shift_id uuid default null
) returns text
language plpgsql
security definer
set search_path to 'ops', 'pg_temp'
as $$
declare
  v_t record;
begin
  select * into v_t from ops.session_shift_transfers where id = p_transfer_id;
  if v_t.id is null then
    raise exception 'طلب النقل % غير موجود', p_transfer_id;
  end if;
  if v_t.status <> 'pending' then
    raise exception 'طلب النقل % تم الرد عليه مسبقا (%)', p_transfer_id, v_t.status;
  end if;

  if p_accept then
    update ops.session_shift_transfers
    set status = 'accepted', responded_at = now(), to_shift_id = coalesce(p_to_shift_id, to_shift_id)
    where id = p_transfer_id;

    update ops.irrigation_sessions
    set current_shift_id = coalesce(p_to_shift_id, current_shift_id),
        collector_profile_id = case
          when v_t.collection_right = 'transfer_to_new' then v_t.to_profile_id
          else v_t.from_profile_id
        end
    where id = v_t.session_id;

    perform ops.notify_profile(v_t.from_profile_id, v_t.well_id, 'session_transfer_accepted',
      'تم قبول نقل الجلسة الى المشغل التالي', v_t.session_id);
    return 'accepted';
  else
    update ops.session_shift_transfers
    set status = 'rejected', responded_at = now()
    where id = p_transfer_id;

    perform ops.notify_profile(v_t.from_profile_id, v_t.well_id, 'session_transfer_rejected',
      'تم رفض نقل الجلسة، ما زالت على مسؤوليتك', v_t.session_id);
    perform ops.notify_well_owners(v_t.well_id, 'session_transfer_rejected',
      'رفض المشغل التالي استلام جلسة سقي شغالة', v_t.session_id);
    return 'rejected';
  end if;
end;
$$;

-- اقفال المناوبة: يمنع الاقفال مع جلسة شغالة غير محسومة
create or replace function ops.close_shift(
  p_shift_id uuid,
  p_allow_open_sessions boolean default false
) returns uuid
language plpgsql
security definer
set search_path to 'ops', 'pg_temp'
as $$
declare
  v_shift record;
  v_unresolved integer;
begin
  select * into v_shift from ops.shifts where id = p_shift_id;
  if v_shift.id is null then
    raise exception 'المناوبة % غير موجودة', p_shift_id;
  end if;
  if v_shift.status <> 'open' then
    raise exception 'المناوبة % ليست مفتوحة (%)', p_shift_id, v_shift.status;
  end if;

  select count(*) into v_unresolved
  from ops.irrigation_sessions s
  where s.well_id = v_shift.well_id
    and s.status = 'open'
    and not exists (
      select 1 from ops.session_shift_transfers t
      where t.session_id = s.id and t.from_shift_id = p_shift_id and t.status = 'accepted'
    );

  if v_unresolved > 0 and not p_allow_open_sessions then
    raise exception 'لا يمكن اقفال المناوبة: % جلسة سقي شغالة لم يتم نقلها والاتفاق على من يستلم مبلغها', v_unresolved;
  end if;

  update ops.shifts
  set status = 'closed', ended_at = now(), closed_at = now()
  where id = p_shift_id;

  perform ops.notify_well_owners(v_shift.well_id, 'shift_closed',
    format('تم اقفال مناوبة المشغل %s', v_shift.operator_profile_id));

  return p_shift_id;
end;
$$;

-- اقرار المشغل بتسليم المبلغ
create or replace function ops.declare_handover(
  p_shift_id uuid,
  p_amount_minor bigint,
  p_to_profile_id uuid default null,
  p_to_description text default null,
  p_note text default null
) returns uuid
language plpgsql
security definer
set search_path to 'ops', 'pg_temp'
as $$
declare
  v_shift record;
  v_id uuid;
begin
  select * into v_shift from ops.shifts where id = p_shift_id;
  if v_shift.id is null then
    raise exception 'المناوبة % غير موجودة', p_shift_id;
  end if;
  if p_to_profile_id is null and p_to_description is null then
    raise exception 'يجب تحديد من تم تسليمه المبلغ (شخص من النظام او ملاحظة نصية)';
  end if;

  insert into ops.shift_handovers (
    tenant_id, well_id, shift_id, from_profile_id, to_profile_id, to_description,
    declared_amount_minor, note
  ) values (
    v_shift.tenant_id, v_shift.well_id, p_shift_id, v_shift.operator_profile_id,
    p_to_profile_id, p_to_description, p_amount_minor, p_note
  ) returning id into v_id;

  perform ops.notify_well_owners(v_shift.well_id, 'handover_declared',
    format('اقر المشغل بتسليم مبلغ %s ريال - بانتظار تاكيدك (%s)', p_amount_minor, coalesce(p_to_description, 'مستلم مسجل')));

  if p_to_profile_id is not null then
    perform ops.notify_profile(p_to_profile_id, v_shift.well_id, 'handover_declared',
      format('المشغل يقر بتسليمك مبلغ %s ريال', p_amount_minor));
  end if;

  return v_id;
end;
$$;

-- تاكيد المالك للتسليم: مطابق او بفرق مع سبب الزامي
create or replace function ops.confirm_handover(
  p_handover_id uuid,
  p_confirmed_amount_minor bigint,
  p_confirmed_by uuid,
  p_difference_reason text default null
) returns text
language plpgsql
security definer
set search_path to 'ops', 'pg_temp'
as $$
declare
  v_h record;
  v_diff bigint;
begin
  select * into v_h from ops.shift_handovers where id = p_handover_id;
  if v_h.id is null then
    raise exception 'اقرار التسليم % غير موجود', p_handover_id;
  end if;
  if v_h.status in ('confirmed', 'settled') then
    raise exception 'اقرار التسليم % مؤكد مسبقا', p_handover_id;
  end if;

  v_diff := p_confirmed_amount_minor - v_h.declared_amount_minor;

  if v_diff = 0 then
    update ops.shift_handovers
    set confirmed_amount_minor = p_confirmed_amount_minor, difference_minor = 0,
        status = 'confirmed', confirmed_by = p_confirmed_by, confirmed_at = now()
    where id = p_handover_id;

    perform ops.notify_profile(v_h.from_profile_id, v_h.well_id, 'handover_confirmed',
      format('تم تاكيد استلام مبلغ %s ريال منك، ورفعت المسؤولية', p_confirmed_amount_minor));
    return 'confirmed';
  end if;

  if p_difference_reason is null then
    raise exception 'يوجد فرق % ريال بين المبلغ المقر والمبلغ المؤكد، وذكر السبب الزامي', v_diff;
  end if;

  update ops.shift_handovers
  set confirmed_amount_minor = p_confirmed_amount_minor, difference_minor = v_diff,
      difference_reason = p_difference_reason, status = 'difference_pending',
      confirmed_by = p_confirmed_by, confirmed_at = now()
  where id = p_handover_id;

  perform ops.notify_well_owners(v_h.well_id, 'handover_difference',
    format('فرق في التسليم: المقر %s ريال والمؤكد %s ريال (الفرق %s) - السبب: %s',
      v_h.declared_amount_minor, p_confirmed_amount_minor, v_diff, p_difference_reason));
  perform ops.notify_profile(v_h.from_profile_id, v_h.well_id, 'handover_difference',
    format('يوجد فرق %s ريال في تسليمك، معلق حتى حسم المالك', v_diff));

  return 'difference_pending';
end;
$$;

-- حسم الفرق نهائيا من المالك
create or replace function ops.settle_handover(p_handover_id uuid, p_settled_by uuid)
returns text
language plpgsql
security definer
set search_path to 'ops', 'pg_temp'
as $$
declare
  v_h record;
begin
  select * into v_h from ops.shift_handovers where id = p_handover_id;
  if v_h.id is null then
    raise exception 'اقرار التسليم % غير موجود', p_handover_id;
  end if;
  if v_h.status <> 'difference_pending' then
    raise exception 'لا يوجد فرق معلق في الاقرار % (الحالة %)', p_handover_id, v_h.status;
  end if;

  update ops.shift_handovers
  set status = 'settled', confirmed_by = p_settled_by, confirmed_at = now()
  where id = p_handover_id;

  perform ops.notify_profile(v_h.from_profile_id, v_h.well_id, 'handover_settled',
    'تم حسم فرق التسليم من المالك، ورفعت المسؤولية عنك');

  return 'settled';
end;
$$;

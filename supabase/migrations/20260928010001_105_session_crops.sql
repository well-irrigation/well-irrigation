-- ق-131 البند 1 / م-45 المرحلة A: محاصيل الجلسة — لقطة مستقلة لكل جلسة.
--
-- القرار الحاكم (اعتماد المالك 2026-09-28):
--   1. كل جلسة تحفظ قائمة محاصيلها الخاصة بها بصورة مستقلة:
--      بلا محصول، أو محصولًا واحدًا، أو عدة محاصيل.
--   2. اقتراحات المحاصيل تُشتق من محاصيل جلسات الأرض السابقة حصرًا —
--      لا "محصول حالي" للأرض ولا قائمة ثابتة.
--   3. الجلسة القديمة تحتفظ بمحاصيلها كما كانت وقت بدئها: تُكتب القائمة
--      مرة واحدة عند البدء ولا مسار تحديث أو حذف لها.
--   4. الإدخال عبر عقد api وحده (ق-79): الكتابة داخل
--      ops.start_irrigation_session بصفة SECURITY DEFINER، فلا Direct DML.

begin;

-- ==============================================================
-- 1. جدول محاصيل الجلسة
-- ==============================================================

create table ops.session_crops (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references ops.irrigation_sessions(id),
  crop_name text not null,
  position integer not null,
  created_at timestamptz not null default now(),
  constraint session_crops_name_not_blank check (btrim(crop_name) <> ''),
  constraint session_crops_position_positive check (position >= 1),
  constraint session_crops_session_crop_unique unique (session_id, crop_name),
  constraint session_crops_session_position_unique unique (session_id, position)
);

create index session_crops_session_position_idx
  on ops.session_crops (session_id, position);

alter table ops.session_crops enable row level security;

-- القراءة تركّب رؤية الجلسة الأم: من يرى الجلسة عبر سياساتها يرى محاصيلها،
-- ولا شيء أبعد. الإدخال والتحديث والحذف بلا أي سياسة = محجوبة عن كل دور
-- تطبيق؛ الكتابة عبر الدالة الـDEFINER وحدها (ق-79 / Direct DML = 0).
create policy session_crops_select_composes_session
  on ops.session_crops
  for select
  to authenticated
  using (
    exists (
      select 1
      from ops.irrigation_sessions s
      where s.id = session_id
    )
  );

grant select on ops.session_crops to authenticated;

-- ==============================================================
-- 2. ops.start_irrigation_session — بند محاصيل اختياري في نهاية التوقيع
--    (نمط ق-114: وسيط ختامي افتراضي، والمسار القديم يبقى كما هو)
-- ==============================================================

drop function if exists ops.start_irrigation_session(
  uuid, uuid, uuid, uuid, uuid, text, timestamptz, uuid
);

create or replace function ops.start_irrigation_session(
  p_well_id uuid,
  p_pump_id uuid,
  p_farm_id uuid,
  p_farmer_well_account_id uuid,
  p_operator_profile_id uuid,
  p_energy_source text,
  p_started_at timestamptz default clock_timestamp(),
  p_fuel_owner_person_id uuid default null,
  p_crops text[] default null
)
returns uuid
language plpgsql
security definer
set search_path to 'ops', 'core', 'billing', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_session_id uuid;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل بدء جلسة السقي';
  end if;
  if p_operator_profile_id is distinct from v_actor then
    raise exception 'معرف المشغل يجب أن يطابق المستخدم المسجل حاليًا';
  end if;
  if not iam.has_well_permission(p_well_id, 'session.start') then
    raise exception 'لا تملك صلاحية بدء جلسة على هذا البئر';
  end if;
  if not exists (
    select 1 from core.pumps p
    where p.id = p_pump_id and p.well_id = p_well_id and p.status = 'active'
  ) then
    raise exception 'المضخة غير موجودة أو غير فعالة في هذا البئر';
  end if;
  if not exists (
    select 1 from ops.farms f
    where f.id = p_farm_id and f.well_id = p_well_id and f.status = 'active'
  ) then
    raise exception 'المزرعة غير موجودة أو غير فعالة في هذا البئر';
  end if;
  if not exists (
    select 1 from ops.farmer_well_accounts fwa
    where fwa.id = p_farmer_well_account_id
      and fwa.well_id = p_well_id
      and fwa.status = 'active'
  ) then
    raise exception 'حساب المزارع غير موجود أو غير فعال في هذا البئر';
  end if;

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, status
  ) values (
    p_well_id, p_pump_id, p_farm_id, p_farmer_well_account_id,
    p_operator_profile_id, p_started_at, 'open'
  )
  returning id into v_session_id;

  perform ops.create_priced_session_segment(
    v_session_id, p_energy_source, p_started_at, p_fuel_owner_person_id
  );

  -- محاصيل الجلسة (ق-131 البند 1): لقطة تُكتب مرة واحدة عند البدء ولا
  -- مسار تعديل لها لاحقًا. الفراغ بعد التطبيع يُتجاهل والتكرار يُدنَّب
  -- بلا فشل: قائمة اختيارية غير مالية، وتعطيل بدء الجلسة كلها بسبب
  -- عنصر تجميلي كان منع عمل يقبله الخادم (فشل كاذب).
  if p_crops is not null then
    insert into ops.session_crops (session_id, crop_name, position)
    select
      v_session_id,
      normalized.name,
      row_number() over (order by normalized.ord)
    from (
      select t.ord, btrim(t.crop) as name
      from unnest(p_crops) with ordinality as t(crop, ord)
      where t.crop is not null and btrim(t.crop) <> ''
    ) normalized
    on conflict (session_id, crop_name) do nothing;
  end if;

  return v_session_id;
end;
$function$;

revoke all on function ops.start_irrigation_session(
  uuid, uuid, uuid, uuid, uuid, text, timestamptz, uuid, text[]
) from public;

grant execute on function ops.start_irrigation_session(
  uuid, uuid, uuid, uuid, uuid, text, timestamptz, uuid, text[]
) to authenticated;

-- ==============================================================
-- 3. api.start_irrigation_session — بند محاصيل ختامي يمر كما هو
--    (حماية معرّف العملية من 084 بلا تغيير: الإعادة تعيد الجلسة نفسها
--    ولا تُدخل المحاصيل ثانيةً)
-- ==============================================================

drop function if exists api.start_irrigation_session(
  uuid, uuid, uuid, uuid, text, timestamptz, uuid, uuid
);

create function api.start_irrigation_session(
  p_well_id uuid,
  p_pump_id uuid,
  p_farm_id uuid,
  p_farmer_well_account_id uuid,
  p_energy_source text,
  p_started_at timestamptz default clock_timestamp(),
  p_fuel_owner_person_id uuid default null,
  p_command_id uuid default null,
  p_crops text[] default null
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_guard jsonb;
  v_session_id uuid;
begin
  if p_command_id is not null then
    v_guard := sync.begin_well_command(
      p_well_id,
      p_command_id,
      'start_irrigation_session',
      null
    );

    if coalesce((v_guard ->> 'duplicate')::boolean, false) then
      if v_guard ->> 'status' = 'accepted' then
        return (v_guard -> 'response' ->> 'id')::uuid;
      end if;
      raise exception 'العملية نفسها قيد المعالجة أو تحتاج مراجعة';
    end if;
  end if;

  v_session_id := ops.start_irrigation_session(
    p_well_id,
    p_pump_id,
    p_farm_id,
    p_farmer_well_account_id,
    auth.uid(),
    p_energy_source,
    p_started_at,
    p_fuel_owner_person_id,
    p_crops
  );

  if p_command_id is not null then
    perform sync.finish_well_command(
      p_well_id,
      p_command_id,
      'accepted',
      jsonb_build_object('id', v_session_id)
    );
  end if;

  return v_session_id;
end;
$function$;

revoke all on function api.start_irrigation_session(
  uuid, uuid, uuid, uuid, text, timestamptz, uuid, uuid, text[]
) from public, anon, authenticated, service_role;

grant execute on function api.start_irrigation_session(
  uuid, uuid, uuid, uuid, text, timestamptz, uuid, uuid, text[]
) to authenticated, service_role;

-- ==============================================================
-- 4. api.list_farm_recent_crops — اقتراحات الأرض من جلساتها السابقة
--    (ق-131 البند 1: الاشتقاق من التاريخ لا من قائمة ثابتة، والرؤية
--    تركّب سياسات الجلسات عبر RLS على الجدولين)
-- ==============================================================

create function api.list_farm_recent_crops(p_farm_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_crops jsonb;
begin
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل قراءة محاصيل الأرض'
      using errcode = '28000';
  end if;
  if p_farm_id is null then
    raise exception 'معرّف الأرض مطلوب'
      using errcode = '22023';
  end if;

  -- تمييز الأرض غير المرئية عن الفارغة يبقى صامتًا عمدًا: الاقتراحات
  -- استشارة لا مصدر قرار، وفشلها لا يمنع بدء الجلسة (ق-131).
  select coalesce(
           jsonb_agg(used.crop order by used.last_used_at desc, used.crop),
           '[]'::jsonb
         )
  into v_crops
  from (
    select sc.crop_name as crop, max(s.started_at) as last_used_at
    from ops.session_crops sc
    join ops.irrigation_sessions s on s.id = sc.session_id
    where s.farm_id = p_farm_id
    group by sc.crop_name
  ) used;

  return jsonb_build_object(
    'contract', 'list_farm_recent_crops',
    'version', 1,
    'farm_id', p_farm_id,
    'crops', v_crops
  );
end;
$function$;

revoke all on function api.list_farm_recent_crops(uuid)
  from public, anon, authenticated, service_role;

grant execute on function api.list_farm_recent_crops(uuid)
  to authenticated, service_role;

-- ==============================================================
-- 5. api.get_session_detail — المحاصيل المحفوظة مع الجلسة
--    (إضافة جمعية بنفس التوقيع: النسخة 1 تبقى 1، والعميل القديم لا يقرأ
--    المفتاح الجديد لا يخسر شيئًا)
-- ==============================================================

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

  select
    jsonb_build_object(
      'id', s.id,
      'well_id', s.well_id,
      'status', s.status,
      'started_at', s.started_at,
      'ended_at', s.ended_at,
      'farmer_well_account_id', fwa.id,
      'farmer_public_code', fwa.public_code,
      'farmer_name', per.full_name,
      'farm_id', f.id,
      'farm_name', f.name,
      'pump_id', pm.id,
      'pump_name', pm.name,
      'operator_name', pr.full_name,
      'energy_source', run.energy_source,
      'billable_seconds', sc.duration_seconds,
      'total_amount_minor', sc.amount_minor,
      'paid_amount_minor', pay.paid_minor,
      'payment_status', case
        when sc.id is null then 'not_billed'
        when coalesce(pay.paid_minor, 0) >= sc.amount_minor
          and sc.amount_minor > 0 then 'settled'
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
  left join ops.farms f on f.id = s.farm_id
  left join ops.farmer_well_accounts fwa
    on fwa.id = coalesce(s.farmer_well_account_id, f.farmer_well_account_id)
  left join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  left join core.persons per on per.id = fp.person_id
  left join core.pumps pm on pm.id = s.pump_id
  left join iam.profiles pr on pr.id = s.operator_profile_id
  left join billing.session_charges sc on sc.session_id = s.id
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
    select case
      when inv.id is not null then inv.paid_minor
      else (
        select coalesce(sum(p.amount_minor), 0)
        from billing.payments p
        where p.session_charge_id = sc.id
          and p.status = 'posted'
      )
    end as paid_minor
  ) pay on sc.id is not null
  left join lateral (
    select p.id, p.method, p.public_code, p.paid_at
    from billing.payments p
    where p.session_charge_id = sc.id
      and p.status = 'posted'
    order by p.paid_at desc, p.id
    limit 1
  ) last_pay on sc.id is not null
  where s.id = p_session_id;

  -- الجلسة غير المرئية عبر RLS = رفض صريح بدل مغلّف فارغ غامض.
  if v_session is null then
    raise exception 'لا توجد صلاحية على هذه الجلسة'
      using errcode = '42501';
  end if;

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
               'started_at', ss.started_at,
               'ended_at', ss.ended_at,
               'actual_seconds', ss.actual_seconds,
               'billable_seconds', ss.billable_seconds,
               'applied_rate_minor', coalesce(
                 ss.applied_operation_rate_minor,
                 ss.applied_hourly_rate_minor
               ),
               'time_charge_minor', ss.time_charge_minor,
               'fuel_charge_minor', ss.fuel_charge_minor,
               'total_charge_minor', ss.total_charge_minor,
               'notes', ss.notes
             )
             order by ss.sequence_number
           ),
           '[]'::jsonb
         )
  into v_segments
  from ops.session_segments ss
  where ss.session_id = p_session_id;

  -- المحاصيل كما اختيرت وقت بدء هذه الجلسة (لقطة مستقلة لا تتبع الأرض).
  select coalesce(
           jsonb_agg(sc.crop_name order by sc.position),
           '[]'::jsonb
         )
  into v_crops
  from ops.session_crops sc
  where sc.session_id = p_session_id;

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

comment on table ops.session_crops is
  'ق-131 البند 1: محاصيل كل جلسة بصورة مستقلة — لقطة تُكتب عند البدء ولا تُعدَّل، والاقتراحات تُشتق من جلسات الأرض السابقة.';
comment on function api.list_farm_recent_crops(uuid) is
  'ق-131: اقتراحات محاصيل الأرض من محاصيل جلساتها السابقة، مرتبة بآخر استخدام؛ الرؤية تركّب سياسات الجلسات.';

commit;

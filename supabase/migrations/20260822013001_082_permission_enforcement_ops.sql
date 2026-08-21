-- =====================================================================
-- Migration 082 — W1-03b/2 — نقل إنفاذ التشغيل والجلسات والمخزون
-- القرار: ق-113 (W1-03b Enforcement wiring)
-- المسألة: م-18
--
-- الغرض:
--   نقل سلطة الصلاحية في نطاق التشغيل والجلسات والوقود والمناوبات
--   إلى `iam.has_well_permission`. 15 موضعًا في 14 دالة.
--   يستهلك `session.energy.change` المضافة في 081.
--   بإكمالها لا يبقى أي حرس دالة على مصفوفات الأدوار النصية.
--
-- قواعد التصميم:
--   1) لا توسيع ولا تضييق صلاحية. أُثبت قبل الكتابة أن كل موضع
--      يعطي نفس المجموعة بالضبط عبر المصدرين
--      (29 موضعًا مفحوصًا، 28 EQUIVALENT، 0 DIFFERS، NO_SILENT_DRIFT).
--   2) أجساد الدوال منقولة آليًا بلا تعديل؛ التغيير الوحيد المسموح
--      هو استبدال نداء السلطة نفسه. أُثبت بالمقارنة الآلية.
--   3) فحوص الهوية (actor = صاحب المناوبة، actor is null) تبقى كما هي.
--      تحويلها إلى فحص صلاحية يضيف شرطًا لم يكن موجودًا.
--   4) `iam.has_well_role` تبقى دون تغيير: 273 RLS policy تعتمدها
--      كطبقة توافق. هذه الهجرة لا تلمس أي policy.
--   5) `create or replace function` يحفظ الصلاحيات القائمة،
--      فلا تُعاد صياغة grant/revoke ولا تتغير مساحة الـAPI.
--   6) الدوال ذات التعريف المتعدد تُنقل من أحدث تعريف حيّ فقط.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- A) ops.start_irrigation_session
--    المصدر: 20260814043001_066_session_procedures.sql
--    الصلاحية: session.start
-- ---------------------------------------------------------------------

create or replace function ops.start_irrigation_session(
  p_well_id uuid,
  p_pump_id uuid,
  p_farm_id uuid,
  p_farmer_well_account_id uuid,
  p_operator_profile_id uuid,
  p_energy_source text,
  p_started_at timestamptz default clock_timestamp(),
  p_fuel_owner_person_id uuid default null
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

  return v_session_id;
end;
$function$;

-- ---------------------------------------------------------------------
-- B) ops.pause_irrigation_session
--    المصدر: 20260814043001_066_session_procedures.sql
--    الصلاحية: session.pause
-- ---------------------------------------------------------------------

create or replace function ops.pause_irrigation_session(
  p_session_id uuid,
  p_reason text,
  p_paused_at timestamptz default clock_timestamp()
)
returns uuid
language plpgsql
security definer
set search_path to 'ops', 'core', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_tenant_id uuid;
  v_status text;
  v_segment_id uuid;
  v_segment_type text;
  v_segment_started_at timestamptz;
  v_sequence_number integer;
  v_pause_id uuid;
begin
  if p_reason not in ('operator_pause', 'farmer_requested_pause') then
    raise exception 'سبب الإيقاف غير صالح؛ المسموح operator_pause أو farmer_requested_pause';
  end if;

  select s.well_id, w.tenant_id, s.status
  into v_well_id, v_tenant_id, v_status
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
  for update of s;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;
  if v_status <> 'open' then
    raise exception 'لا يمكن إيقاف جلسة غير مفتوحة';
  end if;

  v_actor := auth.uid();
  if v_actor is null or not iam.has_well_permission(v_well_id, 'session.pause') then
    raise exception 'لا تملك صلاحية إيقاف هذه الجلسة';
  end if;

  select ss.id, ss.segment_type, ss.started_at, ss.sequence_number
  into v_segment_id, v_segment_type, v_segment_started_at, v_sequence_number
  from ops.session_segments ss
  where ss.session_id = p_session_id and ss.ended_at is null
  order by ss.sequence_number desc
  limit 1
  for update;

  if not found then
    raise exception 'لا يوجد مقطع تشغيل مفتوح يمكن إيقافه';
  end if;
  if v_segment_type not in ('solar_run', 'well_diesel_run', 'farmer_diesel_run') then
    raise exception 'الجلسة متوقفة بالفعل ولا يوجد مقطع تشغيل مفتوح';
  end if;
  if p_paused_at <= v_segment_started_at then
    raise exception 'وقت الإيقاف يجب أن يكون بعد وقت بدء مقطع التشغيل';
  end if;

  update ops.session_segments
  set ended_at = p_paused_at
  where id = v_segment_id;

  insert into ops.session_segments (
    tenant_id, session_id, sequence_number, segment_type,
    energy_source, started_at, is_billable, notes
  ) values (
    v_tenant_id, p_session_id, v_sequence_number + 1, p_reason,
    null, p_paused_at, false, p_reason
  )
  returning id into v_pause_id;

  return v_pause_id;
end;
$function$;

-- ---------------------------------------------------------------------
-- C) ops.resume_irrigation_session
--    المصدر: 20260814043001_066_session_procedures.sql
--    الصلاحية: session.resume
-- ---------------------------------------------------------------------

create or replace function ops.resume_irrigation_session(
  p_session_id uuid,
  p_resumed_at timestamptz default clock_timestamp()
)
returns uuid
language plpgsql
security definer
set search_path to 'ops', 'core', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_tenant_id uuid;
  v_status text;
  v_pause_id uuid;
  v_pause_type text;
  v_pause_started_at timestamptz;
  v_sequence_number integer;
  v_energy_source text;
  v_segment_type text;
  v_fuel_owner_person_id uuid;
  v_price_rule_id uuid;
  v_hourly_rate_minor bigint;
  v_operation_rate_minor bigint;
  v_fuel_price_per_liter_minor bigint;
  v_new_segment_id uuid;
begin
  select s.well_id, w.tenant_id, s.status
  into v_well_id, v_tenant_id, v_status
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
  for update of s;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;
  if v_status <> 'open' then
    raise exception 'لا يمكن استئناف جلسة غير مفتوحة';
  end if;

  v_actor := auth.uid();
  if v_actor is null or not iam.has_well_permission(v_well_id, 'session.resume') then
    raise exception 'لا تملك صلاحية استئناف هذه الجلسة';
  end if;

  select ss.id, ss.segment_type, ss.started_at, ss.sequence_number
  into v_pause_id, v_pause_type, v_pause_started_at, v_sequence_number
  from ops.session_segments ss
  where ss.session_id = p_session_id and ss.ended_at is null
  order by ss.sequence_number desc
  limit 1
  for update;

  if not found then
    raise exception 'لا يوجد مقطع توقف مفتوح يمكن استئنافه';
  end if;
  if v_pause_type not in ('operator_pause', 'farmer_requested_pause') then
    raise exception 'الجلسة تعمل بالفعل ولا يوجد مقطع توقف مفتوح';
  end if;
  if p_resumed_at <= v_pause_started_at then
    raise exception 'وقت الاستئناف يجب أن يكون بعد وقت بدء التوقف';
  end if;

  select ss.energy_source, ss.segment_type, ss.fuel_owner_person_id,
         ss.applied_price_rule_id, ss.applied_hourly_rate_minor,
         ss.applied_operation_rate_minor,
         ss.applied_fuel_price_per_liter_minor
  into v_energy_source, v_segment_type, v_fuel_owner_person_id,
       v_price_rule_id, v_hourly_rate_minor, v_operation_rate_minor,
       v_fuel_price_per_liter_minor
  from ops.session_segments ss
  where ss.session_id = p_session_id
    and ss.sequence_number < v_sequence_number
    and ss.segment_type in ('solar_run', 'well_diesel_run', 'farmer_diesel_run')
  order by ss.sequence_number desc
  limit 1;

  if not found then
    raise exception 'لا يوجد مصدر تشغيل سابق يمكن استئنافه';
  end if;

  update ops.session_segments
  set ended_at = p_resumed_at
  where id = v_pause_id;

  insert into ops.session_segments (
    tenant_id, session_id, sequence_number, segment_type, energy_source,
    started_at, is_billable, fuel_owner_person_id, applied_price_rule_id,
    applied_hourly_rate_minor, applied_operation_rate_minor,
    applied_fuel_price_per_liter_minor
  ) values (
    v_tenant_id, p_session_id, v_sequence_number + 1, v_segment_type,
    v_energy_source, p_resumed_at, true, v_fuel_owner_person_id,
    v_price_rule_id, v_hourly_rate_minor, v_operation_rate_minor,
    v_fuel_price_per_liter_minor
  )
  returning id into v_new_segment_id;

  return v_new_segment_id;
end;
$function$;

-- ---------------------------------------------------------------------
-- D) ops.complete_irrigation_session
--    المصدر: 20260814043001_066_session_procedures.sql
--    الصلاحية: session.complete
-- ---------------------------------------------------------------------

create or replace function ops.complete_irrigation_session(
  p_session_id uuid,
  p_ended_at timestamptz default now(),
  p_fuel_quantity_ml bigint default null,
  p_fuel_measurement_type text default null,
  p_fuel_tank_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'ops', 'billing', 'inventory', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_tenant_id uuid;
  v_status text;
  v_session_started_at timestamptz;
  v_operator_profile_id uuid;
  v_farmer_well_account_id uuid;
  v_open_segment_id uuid;
  v_open_segment_type text;
  v_open_energy_source text;
  v_open_started_at timestamptz;
  v_total_actual_seconds bigint;
  v_total_billable_seconds bigint;
  v_total_amount_minor bigint;
  v_weighted_numerator numeric;
  v_weighted_rate_minor bigint;
  v_charge_id uuid;
  v_fuel_quantity bigint;
  v_segment record;
  v_segments_json jsonb;
begin
  if p_fuel_quantity_ml is not null and p_fuel_quantity_ml <= 0 then
    raise exception 'كمية الوقود المستهلك يجب أن تكون أكبر من صفر';
  end if;
  if p_fuel_quantity_ml is not null
     and coalesce(p_fuel_measurement_type, 'actual') not in ('actual', 'estimated') then
    raise exception 'نوع قياس الوقود يجب أن يكون actual أو estimated';
  end if;

  select s.well_id, w.tenant_id, s.status, s.started_at,
         s.operator_profile_id, s.farmer_well_account_id
  into v_well_id, v_tenant_id, v_status, v_session_started_at,
       v_operator_profile_id, v_farmer_well_account_id
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
  for update of s;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;
  if v_status <> 'open' then
    raise exception 'لا يمكن إكمال جلسة مغلقة أو غير مفتوحة';
  end if;

  v_actor := auth.uid();
  if v_actor is null or not iam.has_well_permission(v_well_id, 'session.complete') then
    raise exception 'لا تملك صلاحية إكمال هذه الجلسة';
  end if;
  if p_ended_at <= v_session_started_at then
    raise exception 'وقت نهاية الجلسة يجب أن يكون بعد وقت بدايتها';
  end if;
  if p_fuel_tank_id is not null and not exists (
    select 1 from inventory.fuel_tanks ft
    where ft.id = p_fuel_tank_id
      and ft.well_id = v_well_id
      and ft.status = 'active'
  ) then
    raise exception 'خزان الوقود غير موجود أو غير فعال في هذا البئر';
  end if;
  if exists (
    select 1 from billing.session_charges sc where sc.session_id = p_session_id
  ) then
    raise exception 'توجد تكلفة مسجلة مسبقًا لهذه الجلسة';
  end if;

  select ss.id, ss.segment_type, ss.energy_source, ss.started_at
  into v_open_segment_id, v_open_segment_type, v_open_energy_source,
       v_open_started_at
  from ops.session_segments ss
  where ss.session_id = p_session_id and ss.ended_at is null
  order by ss.sequence_number desc
  limit 1
  for update;

  if not found then
    raise exception 'لا يوجد مقطع مفتوح يمكن إغلاقه عند إكمال الجلسة';
  end if;
  if p_ended_at <= v_open_started_at then
    raise exception 'وقت نهاية الجلسة يجب أن يكون بعد وقت بدء المقطع المفتوح';
  end if;
  if p_fuel_quantity_ml is not null
     and v_open_energy_source not in ('well_diesel', 'farmer_diesel') then
    raise exception 'لا يمكن تسجيل استهلاك وقود على مقطع غير ديزل';
  end if;

  update ops.session_segments
  set ended_at = p_ended_at,
      fuel_measurement_type = case
        when p_fuel_quantity_ml is null then fuel_measurement_type
        else coalesce(p_fuel_measurement_type, 'actual')
      end,
      fuel_actual_ml = case
        when p_fuel_quantity_ml is not null
         and coalesce(p_fuel_measurement_type, 'actual') = 'actual'
          then p_fuel_quantity_ml
        else fuel_actual_ml
      end,
      fuel_estimated_ml = case
        when p_fuel_quantity_ml is not null
         and coalesce(p_fuel_measurement_type, 'actual') = 'estimated'
          then p_fuel_quantity_ml
        else fuel_estimated_ml
      end
  where id = v_open_segment_id;

  if exists (
    select 1
    from (
      select ss.sequence_number,
             row_number() over (order by ss.sequence_number) as expected_sequence
      from ops.session_segments ss
      where ss.session_id = p_session_id
    ) ordered_segments
    where ordered_segments.sequence_number <> ordered_segments.expected_sequence
  ) then
    raise exception 'ترتيب مقاطع الجلسة غير متسلسل ولا يمكن إكمالها';
  end if;

  if exists (
    select 1
    from ops.session_segments a
    join ops.session_segments b
      on b.session_id = a.session_id and b.id <> a.id
    where a.session_id = p_session_id
      and tstzrange(a.started_at, a.ended_at, '[)')
          && tstzrange(b.started_at, b.ended_at, '[)')
  ) then
    raise exception 'يوجد تداخل زمني بين مقاطع الجلسة ولا يمكن إكمالها';
  end if;

  if exists (
    select 1 from ops.session_segments ss
    where ss.session_id = p_session_id
      and (ss.ended_at is null or ss.ended_at <= ss.started_at)
  ) then
    raise exception 'يوجد مقطع بلا نهاية صحيحة ولا يمكن إكمال الجلسة';
  end if;

  if exists (
    select 1 from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.is_billable
      and ss.segment_type in ('solar_run', 'well_diesel_run', 'farmer_diesel_run')
      and coalesce(ss.applied_operation_rate_minor,
                   ss.applied_hourly_rate_minor, 0) <= 0
  ) then
    raise exception 'يوجد مقطع تشغيل بلا سعر مثبت صالح';
  end if;

  if exists (
    select 1 from ops.session_segments ss
    where ss.session_id = p_session_id
      and (ss.fuel_actual_ml is not null or ss.fuel_estimated_ml is not null)
      and ss.fuel_measurement_type is null
  ) then
    raise exception 'يوجد استهلاك وقود بلا نوع قياس محدد';
  end if;

  update ops.session_segments ss
  set actual_seconds = extract(epoch from (ss.ended_at - ss.started_at))::bigint,
      billable_seconds = case
        when ss.is_billable
          then extract(epoch from (ss.ended_at - ss.started_at))::bigint
        else 0
      end,
      actual_minutes = extract(epoch from (ss.ended_at - ss.started_at))::bigint / 60,
      raw_billable_minutes = case
        when ss.is_billable
          then extract(epoch from (ss.ended_at - ss.started_at))::bigint / 60
        else 0
      end,
      time_charge_minor = case
        when not ss.is_billable then 0
        else (
          extract(epoch from (ss.ended_at - ss.started_at))::bigint
          * coalesce(ss.applied_operation_rate_minor,
                     ss.applied_hourly_rate_minor)
        ) / 3600
      end,
      fuel_charge_minor = case
        when not ss.is_billable then 0
        when coalesce(ss.fuel_actual_ml, ss.fuel_estimated_ml, 0) = 0 then 0
        when ss.applied_fuel_price_per_liter_minor is null then 0
        else (
          coalesce(ss.fuel_actual_ml, ss.fuel_estimated_ml)
          * ss.applied_fuel_price_per_liter_minor
        ) / 1000
      end,
      total_charge_minor = case
        when not ss.is_billable then 0
        else (
          extract(epoch from (ss.ended_at - ss.started_at))::bigint
          * coalesce(ss.applied_operation_rate_minor,
                     ss.applied_hourly_rate_minor)
        ) / 3600
        + case
            when coalesce(ss.fuel_actual_ml, ss.fuel_estimated_ml, 0) = 0 then 0
            when ss.applied_fuel_price_per_liter_minor is null then 0
            else (
              coalesce(ss.fuel_actual_ml, ss.fuel_estimated_ml)
              * ss.applied_fuel_price_per_liter_minor
            ) / 1000
          end
      end
  where ss.session_id = p_session_id;

  select coalesce(sum(ss.actual_seconds), 0),
         coalesce(sum(ss.billable_seconds), 0),
         coalesce(sum(ss.total_charge_minor), 0),
         coalesce(sum(
           ss.billable_seconds::numeric
           * coalesce(ss.applied_operation_rate_minor,
                      ss.applied_hourly_rate_minor, 0)::numeric
         ), 0)
  into v_total_actual_seconds, v_total_billable_seconds,
       v_total_amount_minor, v_weighted_numerator
  from ops.session_segments ss
  where ss.session_id = p_session_id;

  if v_total_billable_seconds <= 0 then
    raise exception 'لا يوجد وقت تشغيل مفوتر في الجلسة';
  end if;
  if v_total_billable_seconds > 2147483647 then
    raise exception 'مدة الجلسة المفوترة تتجاوز الحد المدعوم';
  end if;

  v_weighted_rate_minor := round(
    v_weighted_numerator / v_total_billable_seconds
  )::bigint;

  if v_weighted_rate_minor <= 0 then
    raise exception 'تعذر حساب متوسط سعر زمني صالح للجلسة';
  end if;

  update ops.irrigation_sessions
  set ended_at = p_ended_at,
      status = 'closed',
      updated_at = clock_timestamp()
  where id = p_session_id;

  insert into billing.session_charges (
    session_id, well_id, duration_seconds, price_per_hour_minor,
    amount_minor, pricing_mode
  ) values (
    p_session_id, v_well_id, v_total_billable_seconds::integer,
    v_weighted_rate_minor, v_total_amount_minor, 'segments'
  )
  returning id into v_charge_id;

  for v_segment in
    select ss.id, ss.energy_source, ss.fuel_owner_person_id,
           ss.fuel_actual_ml, ss.fuel_estimated_ml,
           ss.fuel_measurement_type, ss.ended_at
    from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.energy_source in ('well_diesel', 'farmer_diesel')
      and coalesce(ss.fuel_actual_ml, ss.fuel_estimated_ml, 0) > 0
    order by ss.sequence_number
  loop
    v_fuel_quantity := coalesce(v_segment.fuel_actual_ml,
                                v_segment.fuel_estimated_ml);

    insert into inventory.fuel_transactions (
      tenant_id, well_id, fuel_tank_id, transaction_type,
      ownership_type, owner_person_id, farmer_well_account_id,
      quantity_ml, direction, measurement_type, session_segment_id,
      occurred_at, status, created_by, notes
    ) values (
      v_tenant_id, v_well_id,
      case when v_segment.energy_source = 'well_diesel'
        then p_fuel_tank_id else null end,
      'session_consumption',
      case when v_segment.energy_source = 'well_diesel'
        then 'well' else 'farmer' end,
      case when v_segment.energy_source = 'farmer_diesel'
        then v_segment.fuel_owner_person_id else null end,
      case when v_segment.energy_source = 'farmer_diesel'
        then v_farmer_well_account_id else null end,
      v_fuel_quantity, 'out', v_segment.fuel_measurement_type,
      v_segment.id, v_segment.ended_at, 'posted', v_actor,
      'استهلاك وقود ناتج عن إكمال جلسة السقي'
    );
  end loop;

  select jsonb_agg(
    jsonb_build_object(
      'segment_id', ss.id,
      'sequence_number', ss.sequence_number,
      'segment_type', ss.segment_type,
      'energy_source', ss.energy_source,
      'actual_seconds', ss.actual_seconds,
      'billable_seconds', ss.billable_seconds,
      'time_charge_minor', ss.time_charge_minor,
      'fuel_charge_minor', ss.fuel_charge_minor,
      'total_charge_minor', ss.total_charge_minor
    ) order by ss.sequence_number
  )
  into v_segments_json
  from ops.session_segments ss
  where ss.session_id = p_session_id;

  insert into audit.audit_logs (
    tenant_id, well_id, user_id, action, entity_type, entity_id,
    new_values, reason
  ) values (
    v_tenant_id, v_well_id, v_actor, 'session_completed',
    'ops.irrigation_sessions', p_session_id,
    jsonb_build_object(
      'ended_at', p_ended_at,
      'actual_seconds', v_total_actual_seconds,
      'billable_seconds', v_total_billable_seconds,
      'amount_minor', v_total_amount_minor,
      'pricing_mode', 'segments'
    ),
    'إكمال جلسة السقي عبر الإجراء الذري'
  );

  return jsonb_build_object(
    'session_id', p_session_id,
    'session_charge_id', v_charge_id,
    'status', 'closed',
    'ended_at', p_ended_at,
    'actual_seconds', v_total_actual_seconds,
    'billable_seconds', v_total_billable_seconds,
    'weighted_price_per_hour_minor', v_weighted_rate_minor,
    'amount_minor', v_total_amount_minor,
    'segments', coalesce(v_segments_json, '[]'::jsonb)
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- E) ops.change_session_energy_source
--    المصدر: 20260814043001_066_session_procedures.sql
--    الصلاحية: session.energy.change
-- ---------------------------------------------------------------------

create or replace function ops.change_session_energy_source(
  p_session_id uuid,
  p_new_source text,
  p_changed_at timestamptz default clock_timestamp(),
  p_closed_fuel_quantity_ml bigint default null,
  p_closed_fuel_measurement_type text default null,
  p_new_fuel_owner_person_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path to 'ops', 'core', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_status text;
  v_segment_id uuid;
  v_segment_type text;
  v_current_source text;
  v_segment_started_at timestamptz;
  v_new_segment_id uuid;
begin
  if p_new_source not in ('solar', 'well_diesel', 'farmer_diesel') then
    raise exception 'مصدر الطاقة الجديد غير صالح؛ القيم المسموحة: solar أو well_diesel أو farmer_diesel';
  end if;
  if p_closed_fuel_quantity_ml is not null and p_closed_fuel_quantity_ml <= 0 then
    raise exception 'كمية الوقود للمقطع المغلق يجب أن تكون أكبر من صفر';
  end if;
  if p_closed_fuel_quantity_ml is not null
     and coalesce(p_closed_fuel_measurement_type, 'actual') not in ('actual', 'estimated') then
    raise exception 'نوع قياس الوقود يجب أن يكون actual أو estimated';
  end if;

  select s.well_id, s.status
  into v_well_id, v_status
  from ops.irrigation_sessions s
  where s.id = p_session_id
  for update;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;
  if v_status <> 'open' then
    raise exception 'لا يمكن تغيير مصدر الطاقة لجلسة غير مفتوحة';
  end if;

  v_actor := auth.uid();
  if v_actor is null or not iam.has_well_permission(v_well_id, 'session.energy.change') then
    raise exception 'لا تملك صلاحية تغيير مصدر الطاقة لهذه الجلسة';
  end if;

  select ss.id, ss.segment_type, ss.energy_source, ss.started_at
  into v_segment_id, v_segment_type, v_current_source, v_segment_started_at
  from ops.session_segments ss
  where ss.session_id = p_session_id and ss.ended_at is null
  order by ss.sequence_number desc
  limit 1
  for update;

  if not found then
    raise exception 'لا يوجد مقطع تشغيل مفتوح يمكن تغيير مصدره';
  end if;
  if v_segment_type not in ('solar_run', 'well_diesel_run', 'farmer_diesel_run') then
    raise exception 'يجب استئناف الجلسة قبل تغيير مصدر الطاقة';
  end if;
  if v_current_source = p_new_source then
    raise exception 'مصدر الطاقة الجديد مطابق للمصدر الحالي';
  end if;
  if p_changed_at <= v_segment_started_at then
    raise exception 'وقت تغيير المصدر يجب أن يكون بعد وقت بدء المقطع الحالي';
  end if;
  if p_closed_fuel_quantity_ml is not null
     and v_current_source not in ('well_diesel', 'farmer_diesel') then
    raise exception 'لا يمكن تسجيل استهلاك وقود على مقطع غير ديزل';
  end if;

  update ops.session_segments
  set ended_at = p_changed_at,
      fuel_measurement_type = case
        when p_closed_fuel_quantity_ml is null then fuel_measurement_type
        else coalesce(p_closed_fuel_measurement_type, 'actual')
      end,
      fuel_actual_ml = case
        when p_closed_fuel_quantity_ml is not null
         and coalesce(p_closed_fuel_measurement_type, 'actual') = 'actual'
          then p_closed_fuel_quantity_ml
        else fuel_actual_ml
      end,
      fuel_estimated_ml = case
        when p_closed_fuel_quantity_ml is not null
         and coalesce(p_closed_fuel_measurement_type, 'actual') = 'estimated'
          then p_closed_fuel_quantity_ml
        else fuel_estimated_ml
      end
  where id = v_segment_id;

  v_new_segment_id := ops.create_priced_session_segment(
    p_session_id, p_new_source, p_changed_at, p_new_fuel_owner_person_id
  );

  return v_new_segment_id;
end;
$function$;

-- ---------------------------------------------------------------------
-- F) ops.create_farmer
--    المصدر: 20260815033001_069_ops_procedures.sql
--    الصلاحية: farmer.create
-- ---------------------------------------------------------------------

create or replace function ops.create_farmer(
  p_well_id uuid,
  p_full_name text,
  p_phone text default null,
  p_preferred_name text default null,
  p_notes text default null,
  p_credit_limit_minor bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'ops', 'core', 'audit', 'iam', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_name text;
  v_phone text;
  v_person_id uuid;
  v_farmer_profile_id uuid;
  v_account_id uuid;
  v_already_exists boolean := false;
  v_candidates jsonb := '[]'::jsonb;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء مزارع';
  end if;
  if not iam.has_well_permission(p_well_id, 'farmer.create') then
    raise exception 'لا تملك صلاحية إنشاء مزارع في هذا البئر';
  end if;

  select w.tenant_id into v_tenant_id
  from core.wells w where w.id = p_well_id;
  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  v_name := core.normalize_arabic(p_full_name);
  v_phone := core.normalize_phone(p_phone);
  if v_name is null then
    raise exception 'اسم المزارع مطلوب';
  end if;
  if p_credit_limit_minor is not null and p_credit_limit_minor < 0 then
    raise exception 'حد الدين لا يجوز أن يكون سالبًا';
  end if;

  -- التطابق الكامل لا ينشئ شخصًا ثانيًا، لكنه يكمل ملفه وحسابه إن لزم.
  if v_phone is not null then
    select p.id into v_person_id
    from core.persons p
    where p.tenant_id = v_tenant_id
      and p.status = 'active'
      and core.normalize_arabic(p.full_name) = v_name
      and exists (
        select 1 from core.person_contacts pc
        where pc.person_id = p.id
          and pc.tenant_id = v_tenant_id
          and pc.contact_type in ('mobile', 'whatsapp', 'landline')
          and core.normalize_phone(pc.contact_value) = v_phone
      )
    order by p.created_at, p.id
    limit 1
    for update;
    v_already_exists := found;
  end if;

  if v_already_exists then
    select fp.id into v_farmer_profile_id
    from ops.farmer_profiles fp
    where fp.tenant_id = v_tenant_id and fp.person_id = v_person_id;

    if not found then
      insert into ops.farmer_profiles (tenant_id, person_id, notes)
      values (v_tenant_id, v_person_id, p_notes)
      returning id into v_farmer_profile_id;
    end if;

    select fwa.id into v_account_id
    from ops.farmer_well_accounts fwa
    where fwa.farmer_profile_id = v_farmer_profile_id
      and fwa.well_id = p_well_id;

    if not found then
      insert into ops.farmer_well_accounts (
        tenant_id, farmer_profile_id, well_id, public_code,
        credit_limit_minor, notes
      ) values (
        v_tenant_id, v_farmer_profile_id, p_well_id,
        core.generate_public_code('FWA'), p_credit_limit_minor, p_notes
      )
      returning id into v_account_id;
    end if;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
      'person_id', d.person_id,
      'public_code', d.public_code,
      'full_name', d.full_name,
      'match_level', d.match_level,
      'matched_on', d.matched_on
    )), '[]'::jsonb)
    into v_candidates
    from core.find_person_duplicates(v_tenant_id, p_full_name, p_phone) d;

    insert into core.persons (
      tenant_id, full_name, normalized_name, preferred_name,
      notes, created_by, updated_by
    ) values (
      v_tenant_id, btrim(p_full_name), v_name,
      nullif(btrim(p_preferred_name), ''), p_notes, v_actor, v_actor
    )
    returning id into v_person_id;

    if v_phone is not null then
      insert into core.person_contacts (
        tenant_id, person_id, contact_type, contact_value,
        normalized_value, is_primary
      ) values (
        v_tenant_id, v_person_id, 'mobile', btrim(p_phone),
        v_phone, true
      );
    end if;

    insert into ops.farmer_profiles (tenant_id, person_id, notes)
    values (v_tenant_id, v_person_id, p_notes)
    returning id into v_farmer_profile_id;

    insert into ops.farmer_well_accounts (
      tenant_id, farmer_profile_id, well_id, public_code,
      credit_limit_minor, notes
    ) values (
      v_tenant_id, v_farmer_profile_id, p_well_id,
      core.generate_public_code('FWA'), p_credit_limit_minor, p_notes
    )
    returning id into v_account_id;
  end if;

  perform audit.log(
    v_tenant_id, p_well_id, 'create_farmer',
    'core.persons', v_person_id, null,
    jsonb_build_object(
      'person_id', v_person_id,
      'farmer_profile_id', v_farmer_profile_id,
      'farmer_well_account_id', v_account_id,
      'already_exists', v_already_exists,
      'duplicate_candidates', v_candidates
    ),
    case when v_already_exists
      then 'إعادة الشخص المطابق دون إنشاء مكرر'
      else 'إنشاء مزارع وحساب بئر' end
  );

  return jsonb_build_object(
    'person_id', v_person_id,
    'farmer_profile_id', v_farmer_profile_id,
    'farmer_well_account_id', v_account_id,
    'already_exists', v_already_exists,
    'duplicate_candidates', v_candidates
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- G) ops.create_farm
--    المصدر: 20260817003101_075_farm_farmer_identity.sql
--    الصلاحية: farm.create
-- ---------------------------------------------------------------------

create or replace function ops.create_farm(
  p_well_id uuid,
  p_name text,
  p_farmer_well_account_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ops, core, audit, iam, pg_temp
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_farm_id uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception
      'يجب تسجيل الدخول قبل إنشاء أرض';
  end if;

  if not iam.has_well_permission(
    p_well_id,
    'farm.create'
  ) then
    raise exception
      'لا تملك صلاحية إنشاء أرض في هذا البئر';
  end if;

  if nullif(btrim(p_name), '') is null then
    raise exception
      'اسم الأرض مطلوب';
  end if;

  select w.tenant_id
  into v_tenant_id
  from core.wells w
  where w.id = p_well_id;

  if not found then
    raise exception
      'البئر غير موجود: %',
      p_well_id;
  end if;

  if p_farmer_well_account_id is null
     or not exists (
       select 1
       from ops.farmer_well_accounts fwa
       where fwa.id = p_farmer_well_account_id
         and fwa.well_id = p_well_id
         and fwa.tenant_id = v_tenant_id
         and fwa.status = 'active'
     ) then
    raise exception
      'حساب المزارع غير موجود أو غير فعال في هذا البئر';
  end if;

  -- إنشاء الأرض لا يتوقف بسبب وجود جلسة سقي مفتوحة.
  insert into ops.farms (
    well_id,
    name,
    farmer_well_account_id,
    status
  )
  values (
    p_well_id,
    btrim(p_name),
    p_farmer_well_account_id,
    'active'
  )
  returning id into v_farm_id;

  perform audit.log(
    v_tenant_id,
    p_well_id,
    'create_farm',
    'ops.farms',
    v_farm_id,
    null,
    jsonb_build_object(
      'farm_id',
      v_farm_id,
      'name',
      btrim(p_name),
      'farmer_well_account_id',
      p_farmer_well_account_id
    ),
    'إنشاء أرض للمزارع'
  );

  return jsonb_build_object(
    'farm_id',
    v_farm_id,
    'well_id',
    p_well_id,
    'farmer_well_account_id',
    p_farmer_well_account_id,
    'status',
    'active'
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- H) ops.create_booking
--    المصدر: 20260815033001_069_ops_procedures.sql
--    الصلاحية: booking.create
-- ---------------------------------------------------------------------

create or replace function ops.create_booking(
  p_well_id uuid,
  p_farmer_well_account_id uuid,
  p_farm_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_pump_id uuid default null,
  p_water_line_id uuid default null,
  p_expected_energy_source text default null,
  p_priority integer default 0,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'ops', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_booking_id uuid;
  v_pump_reservation_id uuid;
  v_line_reservation_id uuid;
  v_period tstzrange;
  v_duration integer;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء حجز سقي';
  end if;
  if not iam.has_well_permission(p_well_id, 'booking.create') then
    raise exception 'لا تملك صلاحية إنشاء حجز في هذا البئر';
  end if;
  if p_scheduled_start is null or p_scheduled_end is null
     or p_scheduled_end <= p_scheduled_start then
    raise exception 'فترة الحجز غير صالحة — يجب أن تكون النهاية بعد البداية';
  end if;
  if p_pump_id is null and p_water_line_id is null then
    raise exception 'يجب تحديد مضخة أو خط مياه واحد على الأقل للحجز';
  end if;
  if p_expected_energy_source is not null
     and p_expected_energy_source not in ('solar', 'well_diesel', 'farmer_diesel', 'mixed') then
    raise exception 'مصدر الطاقة المتوقع غير صالح';
  end if;

  select w.tenant_id into v_tenant_id
  from core.wells w where w.id = p_well_id;
  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  perform 1 from ops.farmer_well_accounts fwa
  where fwa.id = p_farmer_well_account_id
    and fwa.well_id = p_well_id and fwa.status = 'active'
  for update;
  if not found then
    raise exception 'حساب المزارع غير موجود أو غير فعال في هذا البئر';
  end if;

  if not exists (
    select 1 from ops.farms f
    where f.id = p_farm_id and f.well_id = p_well_id and f.status = 'active'
  ) then
    raise exception 'الأرض غير موجودة أو غير فعالة في هذا البئر';
  end if;

  if p_pump_id is not null then
    perform 1 from core.pumps p
    where p.id = p_pump_id and p.well_id = p_well_id and p.status = 'active'
    for update;
    if not found then
      raise exception 'المضخة غير موجودة أو غير فعالة في هذا البئر';
    end if;
  end if;

  if p_water_line_id is not null then
    perform 1 from core.water_lines wl
    where wl.id = p_water_line_id and wl.well_id = p_well_id and wl.status = 'active'
    for update;
    if not found then
      raise exception 'خط المياه غير موجود أو غير فعال في هذا البئر';
    end if;
  end if;

  if p_pump_id is not null and p_water_line_id is not null and not exists (
    select 1 from core.pump_line_links pll
    where pll.pump_id = p_pump_id and pll.water_line_id = p_water_line_id
      and pll.effective_from <= p_scheduled_start
      and (pll.effective_to is null or pll.effective_to > p_scheduled_start)
  ) then
    raise exception 'المضخة وخط المياه غير مرتبطين خلال وقت الحجز';
  end if;

  v_period := tstzrange(p_scheduled_start, p_scheduled_end, '[)');
  v_duration := ceil(extract(epoch from (p_scheduled_end - p_scheduled_start)) / 60.0)::integer;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id,
    farm_id, pump_id, water_line_id, scheduled_start, scheduled_end,
    expected_duration_minutes, expected_energy_source, status,
    priority, notes, created_by
  ) values (
    v_tenant_id, core.generate_public_code('BKG'), p_well_id,
    p_farmer_well_account_id, p_farm_id, p_pump_id, p_water_line_id,
    p_scheduled_start, p_scheduled_end, v_duration,
    p_expected_energy_source, 'confirmed', p_priority, p_notes, v_actor
  ) returning id into v_booking_id;

  if p_pump_id is not null then
    v_pump_reservation_id := ops.reserve_resource(
      p_well_id, 'pump', p_pump_id, v_period, v_booking_id, null
    );
  end if;
  if p_water_line_id is not null then
    v_line_reservation_id := ops.reserve_resource(
      p_well_id, 'water_line', p_water_line_id, v_period, v_booking_id, null
    );
  end if;

  insert into ops.booking_status_history (
    tenant_id, booking_id, old_status, new_status, reason, changed_by
  ) values (
    v_tenant_id, v_booking_id, null, 'confirmed', 'إنشاء الحجز', v_actor
  );

  perform audit.log(
    v_tenant_id, p_well_id, 'create_booking',
    'ops.irrigation_bookings', v_booking_id, null,
    jsonb_build_object(
      'booking_id', v_booking_id,
      'scheduled_start', p_scheduled_start,
      'scheduled_end', p_scheduled_end,
      'pump_reservation_id', v_pump_reservation_id,
      'water_line_reservation_id', v_line_reservation_id
    ),
    'إنشاء حجز سقي مؤكد'
  );

  return jsonb_build_object(
    'booking_id', v_booking_id,
    'status', 'confirmed',
    'scheduled_start', p_scheduled_start,
    'scheduled_end', p_scheduled_end,
    'pump_reservation_id', v_pump_reservation_id,
    'water_line_reservation_id', v_line_reservation_id
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- I) ops.reschedule_booking
--    المصدر: 20260815033001_069_ops_procedures.sql
--    الصلاحية: booking.reschedule
-- ---------------------------------------------------------------------

create or replace function ops.reschedule_booking(
  p_booking_id uuid,
  p_scheduled_start timestamptz,
  p_scheduled_end timestamptz,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to 'ops', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_booking ops.irrigation_bookings%rowtype;
  v_pump_reservation_id uuid;
  v_line_reservation_id uuid;
  v_period tstzrange;
  v_duration integer;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إعادة جدولة الحجز';
  end if;
  if p_scheduled_start is null or p_scheduled_end is null
     or p_scheduled_end <= p_scheduled_start then
    raise exception 'فترة الحجز الجديدة غير صالحة — يجب أن تكون النهاية بعد البداية';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'سبب إعادة الجدولة مطلوب';
  end if;

  select b.* into v_booking
  from ops.irrigation_bookings b
  where b.id = p_booking_id
  for update;
  if not found then
    raise exception 'الحجز غير موجود: %', p_booking_id;
  end if;
  if not iam.has_well_permission(v_booking.well_id, 'booking.reschedule') then
    raise exception 'لا تملك صلاحية إعادة جدولة هذا الحجز';
  end if;
  if v_booking.status not in ('draft', 'pending', 'confirmed', 'waiting', 'ready', 'postponed') then
    raise exception 'لا يمكن إعادة جدولة حجز حالته %', v_booking.status;
  end if;

  if v_booking.pump_id is not null then
    perform 1 from core.pumps p
    where p.id = v_booking.pump_id and p.status = 'active'
    for update;
    if not found then
      raise exception 'مضخة الحجز غير موجودة أو غير فعالة';
    end if;
  end if;
  if v_booking.water_line_id is not null then
    perform 1 from core.water_lines wl
    where wl.id = v_booking.water_line_id and wl.status = 'active'
    for update;
    if not found then
      raise exception 'خط مياه الحجز غير موجود أو غير فعال';
    end if;
  end if;

  v_period := tstzrange(p_scheduled_start, p_scheduled_end, '[)');
  v_duration := ceil(extract(epoch from (p_scheduled_end - p_scheduled_start)) / 60.0)::integer;

  update ops.resource_reservations
  set status = 'released'
  where booking_id = p_booking_id and status = 'active';

  update ops.irrigation_bookings
  set scheduled_start = p_scheduled_start,
      scheduled_end = p_scheduled_end,
      expected_duration_minutes = v_duration
  where id = p_booking_id;

  if v_booking.pump_id is not null then
    v_pump_reservation_id := ops.reserve_resource(
      v_booking.well_id, 'pump', v_booking.pump_id,
      v_period, p_booking_id, null
    );
  end if;
  if v_booking.water_line_id is not null then
    v_line_reservation_id := ops.reserve_resource(
      v_booking.well_id, 'water_line', v_booking.water_line_id,
      v_period, p_booking_id, null
    );
  end if;

  insert into ops.booking_status_history (
    tenant_id, booking_id, old_status, new_status, reason, changed_by
  ) values (
    v_booking.tenant_id, p_booking_id, v_booking.status,
    v_booking.status, 'إعادة جدولة: ' || btrim(p_reason), v_actor
  );

  perform audit.log(
    v_booking.tenant_id, v_booking.well_id, 'reschedule_booking',
    'ops.irrigation_bookings', p_booking_id,
    jsonb_build_object(
      'scheduled_start', v_booking.scheduled_start,
      'scheduled_end', v_booking.scheduled_end,
      'status', v_booking.status
    ),
    jsonb_build_object(
      'scheduled_start', p_scheduled_start,
      'scheduled_end', p_scheduled_end,
      'status', v_booking.status,
      'pump_reservation_id', v_pump_reservation_id,
      'water_line_reservation_id', v_line_reservation_id
    ),
    btrim(p_reason)
  );

  return jsonb_build_object(
    'booking_id', p_booking_id,
    'status', v_booking.status,
    'scheduled_start', p_scheduled_start,
    'scheduled_end', p_scheduled_end,
    'pump_reservation_id', v_pump_reservation_id,
    'water_line_reservation_id', v_line_reservation_id
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- J) inventory.purchase_fuel
--    المصدر: 20260815033001_069_ops_procedures.sql
--    الصلاحية: fuel.purchase
-- ---------------------------------------------------------------------

create or replace function inventory.purchase_fuel(
  p_well_id uuid,
  p_liters numeric,
  p_cost_minor bigint,
  p_purchased_at timestamptz default clock_timestamp(),
  p_recorded_by uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'inventory', 'finance', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_tank_id uuid;
  v_purchase_id uuid;
  v_transaction_id uuid;
  v_journal_id uuid;
  v_balance_before bigint;
  v_balance_after bigint;
  v_avg_after bigint;
  v_quantity_ml bigint;
  v_existing_transactions uuid[] := '{}'::uuid[];
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل شراء الديزل';
  end if;
  if p_recorded_by is not null and p_recorded_by is distinct from v_actor then
    raise exception 'مسجل الشراء يجب أن يطابق المستخدم المسجل حاليًا';
  end if;
  if not iam.has_well_permission(p_well_id, 'fuel.purchase') then
    raise exception 'لا تملك صلاحية تسجيل شراء ديزل لهذا البئر';
  end if;
  if p_liters is null or p_liters <= 0 then
    raise exception 'كمية الديزل المشتراة يجب أن تكون أكبر من صفر';
  end if;
  if p_cost_minor is null or p_cost_minor <= 0 then
    raise exception 'مبلغ شراء الديزل يجب أن يكون أكبر من صفر';
  end if;
  if p_liters <> round(p_liters, 2) then
    raise exception 'كمية الشراء تقبل منزلتين عشريتين كحد أقصى';
  end if;

  select w.tenant_id into v_tenant_id
  from core.wells w where w.id = p_well_id;
  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  select ft.id, ft.current_balance_ml
  into v_tank_id, v_balance_before
  from inventory.fuel_tanks ft
  where ft.well_id = p_well_id and ft.status = 'active'
  order by ft.created_at, ft.id
  limit 1
  for update;
  if not found then
    raise exception 'لا يوجد خزان ديزل فعال لهذا البئر';
  end if;

  v_quantity_ml := round(p_liters * 1000);
  if v_quantity_ml <= 0 then
    raise exception 'كمية الديزل بعد التحويل يجب أن تكون ملليلترًا واحدًا على الأقل';
  end if;

  select coalesce(array_agg(ftx.id), '{}'::uuid[])
  into v_existing_transactions
  from inventory.fuel_transactions ftx
  where ftx.well_id = p_well_id;

  insert into inventory.fuel_purchases (
    well_id, liters, cost_minor, purchased_at, recorded_by_profile_id
  ) values (
    p_well_id, p_liters, p_cost_minor, p_purchased_at, v_actor
  ) returning id into v_purchase_id;

  select ftx.id into v_transaction_id
  from inventory.fuel_transactions ftx
  where ftx.well_id = p_well_id
    and ftx.transaction_type = 'purchase'
    and ftx.ownership_type = 'well'
    and ftx.quantity_ml = v_quantity_ml
    and ftx.total_cost_minor = p_cost_minor
    and ftx.occurred_at = p_purchased_at
    and not (ftx.id = any(v_existing_transactions))
  order by ftx.id
  limit 1;
  if not found then
    raise exception 'فشل التحقق من حركة المخزون الناتجة عن شراء الديزل';
  end if;

  select ft.current_balance_ml, ft.avg_cost_per_liter_minor
  into v_balance_after, v_avg_after
  from inventory.fuel_tanks ft where ft.id = v_tank_id;

  if v_balance_after <> v_balance_before + v_quantity_ml then
    raise exception 'فشل التحقق من رصيد الخزان بعد شراء الديزل';
  end if;

  select je.id into v_journal_id
  from finance.journal_entries je
  where je.source_type = 'fuel_purchase'
    and je.source_id = v_transaction_id and je.status = 'posted';
  if not found then
    raise exception 'فشل التحقق من القيد المالي المرحل لشراء الديزل';
  end if;

  perform audit.log(
    v_tenant_id, p_well_id, 'purchase_fuel',
    'inventory.fuel_purchases', v_purchase_id, null,
    jsonb_build_object(
      'purchase_id', v_purchase_id,
      'fuel_transaction_id', v_transaction_id,
      'quantity_ml', v_quantity_ml,
      'cost_minor', p_cost_minor,
      'balance_ml', v_balance_after,
      'avg_cost_per_liter_minor', v_avg_after,
      'journal_entry_id', v_journal_id
    ),
    'شراء ديزل وإضافته إلى الخزان'
  );

  return jsonb_build_object(
    'purchase_id', v_purchase_id,
    'fuel_transaction_id', v_transaction_id,
    'journal_entry_id', v_journal_id,
    'balance_ml', v_balance_after,
    'avg_cost_per_liter_minor', v_avg_after
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- K) inventory.record_fuel_consumption
--    المصدر: 20260815033001_069_ops_procedures.sql
--    الصلاحية: fuel.consume
-- ---------------------------------------------------------------------

create or replace function inventory.record_fuel_consumption(
  p_well_id uuid,
  p_quantity_ml bigint,
  p_ownership_type text,
  p_measurement_type text,
  p_owner_person_id uuid default null,
  p_farmer_well_account_id uuid default null,
  p_fuel_tank_id uuid default null,
  p_session_segment_id uuid default null,
  p_occurred_at timestamptz default clock_timestamp(),
  p_created_by uuid default null,
  p_estimated_transaction_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'inventory', 'finance', 'ops', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_tank_id uuid;
  v_transaction_id uuid;
  v_journal_id uuid;
  v_status text;
  v_balance_before bigint;
  v_balance_after bigint;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل استهلاك الديزل';
  end if;
  if p_created_by is not null and p_created_by is distinct from v_actor then
    raise exception 'مسجل الاستهلاك يجب أن يطابق المستخدم المسجل حاليًا';
  end if;
  if not iam.has_well_permission(p_well_id, 'fuel.consume') then
    raise exception 'لا تملك صلاحية تسجيل استهلاك ديزل لهذا البئر';
  end if;
  if p_quantity_ml is null or p_quantity_ml <= 0 then
    raise exception 'كمية الديزل المستهلكة يجب أن تكون أكبر من صفر';
  end if;
  if p_ownership_type is null or p_ownership_type not in ('well', 'farmer') then
    raise exception 'ملكية الديزل غير صالحة؛ المسموح ديزل البئر أو ديزل المزارع';
  end if;
  if p_measurement_type is null or p_measurement_type not in ('actual', 'estimated') then
    raise exception 'نوع القياس غير صالح؛ المسموح فعلي أو تقديري';
  end if;

  select w.tenant_id into v_tenant_id
  from core.wells w where w.id = p_well_id;
  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  select ft.id, ft.current_balance_ml
  into v_tank_id, v_balance_before
  from inventory.fuel_tanks ft
  where ft.id = coalesce(p_fuel_tank_id, ft.id)
    and ft.well_id = p_well_id and ft.status = 'active'
  order by ft.created_at, ft.id
  limit 1
  for update;
  if not found then
    raise exception 'خزان الديزل غير موجود أو غير فعال في هذا البئر';
  end if;

  if p_ownership_type = 'farmer' then
    if p_owner_person_id is null or p_farmer_well_account_id is null then
      raise exception 'استهلاك ديزل المزارع يحتاج صاحب الوقود وحساب المزارع';
    end if;
    if not exists (
      select 1
      from ops.farmer_well_accounts fwa
      join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
      where fwa.id = p_farmer_well_account_id
        and fwa.well_id = p_well_id and fwa.status = 'active'
        and fp.person_id = p_owner_person_id and fp.status = 'active'
    ) then
      raise exception 'رصيد ديزل المزارع لا يخص حساب المزارع المحدد';
    end if;
    v_balance_before := inventory.farmer_fuel_balance_ml(p_well_id, p_owner_person_id);
  elsif p_owner_person_id is not null or p_farmer_well_account_id is not null then
    raise exception 'ديزل البئر لا يقبل صاحب وقود أو حساب مزارع';
  end if;

  if p_measurement_type = 'actual' and p_quantity_ml > v_balance_before then
    if p_ownership_type = 'farmer' then
      raise exception 'رصيد ديزل المزارع لا يكفي: المتاح % مل والمطلوب % مل',
        v_balance_before, p_quantity_ml;
    else
      raise exception 'رصيد ديزل البئر لا يكفي: المتاح % مل والمطلوب % مل',
        v_balance_before, p_quantity_ml;
    end if;
  end if;

  if p_estimated_transaction_id is not null then
    if p_measurement_type <> 'actual' then
      raise exception 'لا يمكن تسوية قياس تقديري إلا بقياس فعلي';
    end if;
    update inventory.fuel_transactions ftx
    set status = 'reversed',
        notes = coalesce(ftx.notes || ' | ', '') || 'استُبدل بقياس فعلي'
    where ftx.id = p_estimated_transaction_id
      and ftx.well_id = p_well_id
      and ftx.status = 'pending_actual_measurement'
      and ftx.ownership_type = p_ownership_type
      and ftx.owner_person_id is not distinct from p_owner_person_id;
    if not found then
      raise exception 'حركة القياس التقديري غير موجودة أو لا تطابق الاستهلاك الفعلي';
    end if;
  end if;

  insert into inventory.fuel_transactions (
    tenant_id, well_id, fuel_tank_id, transaction_type,
    ownership_type, owner_person_id, farmer_well_account_id,
    quantity_ml, direction, measurement_type, session_segment_id,
    occurred_at, status, created_by, notes
  ) values (
    v_tenant_id, p_well_id, v_tank_id, 'session_consumption',
    p_ownership_type, p_owner_person_id, p_farmer_well_account_id,
    p_quantity_ml, 'out', p_measurement_type, p_session_segment_id,
    p_occurred_at, 'posted', v_actor,
    case when p_measurement_type = 'estimated'
      then 'استهلاك تقديري بانتظار القياس الفعلي'
      else 'استهلاك فعلي مسجل عبر الإجراء' end
  ) returning id, status into v_transaction_id, v_status;

  if p_ownership_type = 'farmer' then
    v_balance_after := inventory.farmer_fuel_balance_ml(p_well_id, p_owner_person_id);
  else
    select ft.current_balance_ml into v_balance_after
    from inventory.fuel_tanks ft where ft.id = v_tank_id;
  end if;

  if p_measurement_type = 'estimated' and (
    v_status <> 'pending_actual_measurement' or v_balance_after <> v_balance_before
  ) then
    raise exception 'فشل التحقق: القياس التقديري يجب أن يبقى معلقًا دون خصم';
  end if;
  if p_measurement_type = 'actual' and v_balance_after <> v_balance_before - p_quantity_ml then
    raise exception 'فشل التحقق من خصم استهلاك الديزل الفعلي';
  end if;

  select je.id into v_journal_id
  from finance.journal_entries je
  where je.source_type = 'fuel_consumption'
    and je.source_id = v_transaction_id and je.status = 'posted';

  if p_measurement_type = 'actual' and p_ownership_type = 'well'
     and v_journal_id is null then
    raise exception 'فشل التحقق من القيد المالي لاستهلاك ديزل البئر';
  end if;

  perform audit.log(
    v_tenant_id, p_well_id, 'record_fuel_consumption',
    'inventory.fuel_transactions', v_transaction_id, null,
    jsonb_build_object(
      'fuel_transaction_id', v_transaction_id,
      'ownership_type', p_ownership_type,
      'measurement_type', p_measurement_type,
      'status', v_status,
      'quantity_ml', p_quantity_ml,
      'balance_ml', v_balance_after,
      'journal_entry_id', v_journal_id,
      'replaced_estimate_id', p_estimated_transaction_id
    ),
    'تسجيل استهلاك ديزل'
  );

  return jsonb_build_object(
    'fuel_transaction_id', v_transaction_id,
    'status', v_status,
    'measurement_type', p_measurement_type,
    'balance_ml', v_balance_after,
    'journal_entry_id', v_journal_id,
    'replaced_estimate_id', p_estimated_transaction_id
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- L) inventory.record_physical_fuel_count
--    المصدر: 20260815033001_069_ops_procedures.sql
--    الصلاحية: fuel.count
-- ---------------------------------------------------------------------

create or replace function inventory.record_physical_fuel_count(
  p_well_id uuid,
  p_fuel_tank_id uuid,
  p_measured_balance_ml bigint,
  p_counted_at timestamptz default clock_timestamp(),
  p_counted_by uuid default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'inventory', 'finance', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_book_balance bigint;
  v_avg_cost bigint;
  v_difference bigint;
  v_transaction_id uuid;
  v_journal_id uuid;
  v_total_cost bigint;
  v_direction text;
  v_balance_after bigint;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل تسجيل الجرد الفعلي';
  end if;
  if p_counted_by is not null and p_counted_by is distinct from v_actor then
    raise exception 'منفذ الجرد يجب أن يطابق المستخدم المسجل حاليًا';
  end if;
  if not iam.has_well_permission(p_well_id, 'fuel.count') then
    raise exception 'لا تملك صلاحية تسجيل جرد ديزل لهذا البئر';
  end if;
  if p_measured_balance_ml is null or p_measured_balance_ml < 0 then
    raise exception 'الرصيد المقاس في الجرد لا يجوز أن يكون سالبًا';
  end if;

  select ft.tenant_id, ft.current_balance_ml, ft.avg_cost_per_liter_minor
  into v_tenant_id, v_book_balance, v_avg_cost
  from inventory.fuel_tanks ft
  where ft.id = p_fuel_tank_id
    and ft.well_id = p_well_id and ft.status = 'active'
  for update;
  if not found then
    raise exception 'خزان الديزل غير موجود أو غير فعال في هذا البئر';
  end if;

  v_difference := p_measured_balance_ml - v_book_balance;
  if v_difference = 0 then
    perform audit.log(
      v_tenant_id, p_well_id, 'record_physical_fuel_count',
      'inventory.fuel_tanks', p_fuel_tank_id,
      jsonb_build_object('book_balance_ml', v_book_balance),
      jsonb_build_object('measured_balance_ml', p_measured_balance_ml, 'difference_ml', 0),
      coalesce(p_notes, 'جرد فعلي مطابق للرصيد')
    );
    return jsonb_build_object(
      'fuel_transaction_id', null,
      'journal_entry_id', null,
      'book_balance_ml', v_book_balance,
      'measured_balance_ml', p_measured_balance_ml,
      'difference_ml', 0,
      'balance_ml', v_book_balance
    );
  end if;

  v_direction := case when v_difference > 0 then 'in' else 'out' end;
  v_total_cost := round((abs(v_difference)::numeric / 1000) * v_avg_cost);

  insert into inventory.fuel_transactions (
    tenant_id, well_id, fuel_tank_id, transaction_type,
    ownership_type, quantity_ml, direction, measurement_type,
    unit_cost_per_liter_minor, total_cost_minor,
    occurred_at, status, created_by, notes
  ) values (
    v_tenant_id, p_well_id, p_fuel_tank_id, 'physical_count',
    'well', abs(v_difference), v_direction, 'actual',
    v_avg_cost, v_total_cost, p_counted_at, 'posted', v_actor,
    coalesce(p_notes, 'فرق جرد فعلي للديزل')
  ) returning id into v_transaction_id;

  select ft.current_balance_ml into v_balance_after
  from inventory.fuel_tanks ft where ft.id = p_fuel_tank_id;
  if v_balance_after <> p_measured_balance_ml then
    raise exception 'فشل التحقق من مطابقة رصيد الخزان للقياس الفعلي';
  end if;

  select je.id into v_journal_id
  from finance.journal_entries je
  where je.source_type = 'fuel_physical_count'
    and je.source_id = v_transaction_id and je.status = 'posted';
  if v_total_cost > 0 and v_journal_id is null then
    raise exception 'فشل التحقق من قيد فرق الجرد الفعلي';
  end if;

  perform audit.log(
    v_tenant_id, p_well_id, 'record_physical_fuel_count',
    'inventory.fuel_transactions', v_transaction_id,
    jsonb_build_object('book_balance_ml', v_book_balance),
    jsonb_build_object(
      'measured_balance_ml', p_measured_balance_ml,
      'difference_ml', v_difference,
      'balance_ml', v_balance_after,
      'journal_entry_id', v_journal_id
    ),
    coalesce(p_notes, 'تسجيل فرق الجرد الفعلي')
  );

  return jsonb_build_object(
    'fuel_transaction_id', v_transaction_id,
    'journal_entry_id', v_journal_id,
    'book_balance_ml', v_book_balance,
    'measured_balance_ml', p_measured_balance_ml,
    'difference_ml', v_difference,
    'balance_ml', v_balance_after,
    'avg_cost_per_liter_minor', v_avg_cost
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- M) api.open_shift
--    المصدر: 20260816235001_074_api_critical_flows.sql
--    الصلاحية: shift.open
-- ---------------------------------------------------------------------

create or replace function api.open_shift(
  p_well_id uuid
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل بدء مناوبة';
  end if;

  if not iam.has_well_permission(
    p_well_id,
    'shift.open'
  ) then
    raise exception 'لا تملك صلاحية بدء مناوبة في هذا البئر';
  end if;

  return ops.open_shift(
    p_well_id,
    v_actor
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- N) api.close_shift
--    المصدر: 20260816235001_074_api_critical_flows.sql
--    الصلاحية: shift.close_override / shift.close_override
-- ---------------------------------------------------------------------

create or replace function api.close_shift(
  p_shift_id uuid,
  p_allow_open_sessions boolean default false
)
returns uuid
language plpgsql
volatile
security invoker
set search_path = 'pg_catalog', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_well_id uuid;
  v_operator_profile_id uuid;
begin
  v_actor := auth.uid();

  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إغلاق المناوبة';
  end if;

  select s.well_id, s.operator_profile_id
  into v_well_id, v_operator_profile_id
  from ops.shifts s
  where s.id = p_shift_id;

  if not found then
    raise exception 'المناوبة غير موجودة: %', p_shift_id;
  end if;

  if v_actor is distinct from v_operator_profile_id
     and not iam.has_well_permission(
       v_well_id,
       'shift.close_override'
     ) then
    raise exception 'لا تملك صلاحية إغلاق هذه المناوبة';
  end if;

  if p_allow_open_sessions
     and not iam.has_well_permission(
       v_well_id,
       'shift.close_override'
     ) then
    raise exception 'تجاوز الجلسات المفتوحة عند إغلاق المناوبة خاص بالمالك';
  end if;

  return ops.close_shift(
    p_shift_id,
    p_allow_open_sessions
  );
end;
$function$;


commit;

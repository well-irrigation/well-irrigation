-- ================================================================
-- هجرة 085: إصلاحات الفجوات الخلفية
-- ================================================================
-- تحتوي على أربعة إصلاحات:
--   1. تصحيح سياسة قراءة الدفعات المقدمة ودفعات الديون القديمة
--   2. تصحيح احتساب الوقود في إنهاء الجلسة (ق-17 وق-91)
--   3. سحب صلاحية EXECUTE من PUBLIC على الدوال الداخلية
--   4. إزالة نموذج التسعير الملغى operation_plus_fuel

-- ================================================================
-- القسم 1: تصحيح سياسة قراءة الدفعات (فجوة 016:45)
-- ================================================================

drop policy if exists payments_select_assigned on billing.payments;

create policy payments_select_assigned
    on billing.payments for select
    using (
        -- الحالة 1: دفعة مرتبطة بجلسة — الربط عبر session_charges
        (
            session_charge_id is not null
            and exists (
                select 1 from billing.session_charges sc
                where sc.id = payments.session_charge_id
                  and iam.has_well_role(sc.well_id, array['owner', 'operator'])
            )
        )
        -- الحالة 2: دفعة مقدمة أو دين قديم — الربط عبر well_id المباشر
        or (
            session_charge_id is null
            and well_id is not null
            and iam.has_well_role(well_id, array['owner', 'operator'])
        )
    );

-- ================================================================
-- القسم 2: تصحيح احتساب الوقود وفق ق-17 وق-91
-- ================================================================

-- إزالة القيد القديم الذي يفرض total = time + fuel
alter table ops.session_segments
  drop constraint if exists session_segments_total_charge_minor_check;

-- القيد الجديد: total = time فقط (الوقود رقابي لا يُفوتر)
alter table ops.session_segments
  add constraint session_segments_total_charge_minor_check
    check (total_charge_minor = time_charge_minor);

-- إعادة تعريف الدالة مع تصحيح حساب الوقود
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
      -- تصحيح ق-17/ق-91: total = time فقط (الوقود رقابي لا يُضاف كرسوم)
      total_charge_minor = case
        when not ss.is_billable then 0
        else (
          extract(epoch from (ss.ended_at - ss.started_at))::bigint
          * coalesce(ss.applied_operation_rate_minor,
                     ss.applied_hourly_rate_minor)
        ) / 3600
      end
  where ss.session_id = p_session_id;

  select coalesce(sum(ss.actual_seconds), 0),
         coalesce(sum(ss.billable_seconds), 0),
         -- تصحيح ق-17/ق-91: المبلغ الإجمالي = مجموع time_charge_minor فقط
         coalesce(sum(ss.time_charge_minor), 0),
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

-- ================================================================
-- القسم 3: سحب EXECUTE من PUBLIC على كل الدوال الداخلية
-- ================================================================

-- سحب التنفيذ على كل الدوال الحالية
revoke execute on all functions in schema core from anon;
revoke execute on all functions in schema iam from anon;
revoke execute on all functions in schema ops from anon;
revoke execute on all functions in schema billing from anon;
revoke execute on all functions in schema finance from anon;
revoke execute on all functions in schema inventory from anon;
revoke execute on all functions in schema audit from anon;
revoke execute on all functions in schema sync from anon;
revoke execute on all functions in schema reporting from anon;

-- حماية الدوال المستقبلية
alter default privileges for role postgres in schema core
  revoke execute on functions from anon;
alter default privileges for role postgres in schema iam
  revoke execute on functions from anon;
alter default privileges for role postgres in schema ops
  revoke execute on functions from anon;
alter default privileges for role postgres in schema billing
  revoke execute on functions from anon;
alter default privileges for role postgres in schema finance
  revoke execute on functions from anon;
alter default privileges for role postgres in schema inventory
  revoke execute on functions from anon;
alter default privileges for role postgres in schema audit
  revoke execute on functions from anon;
alter default privileges for role postgres in schema sync
  revoke execute on functions from anon;
alter default privileges for role postgres in schema reporting
  revoke execute on functions from anon;

-- إعادة منح التنفيذ لـ authenticated على الدوال التي يحتاجها عبر RLS
grant execute on function iam.has_well_role(uuid, text[]) to authenticated;
grant execute on function iam.has_well_permission(uuid, text) to authenticated;
grant execute on function iam.is_well_partner(uuid) to authenticated;

-- إعادة منح التنفيذ لـ service_role على كل الدوال (للعمليات الخلفية)
grant execute on all functions in schema core to service_role;
grant execute on all functions in schema iam to service_role;
grant execute on all functions in schema ops to service_role;
grant execute on all functions in schema billing to service_role;
grant execute on all functions in schema finance to service_role;
grant execute on all functions in schema inventory to service_role;
grant execute on all functions in schema audit to service_role;
grant execute on all functions in schema sync to service_role;
grant execute on all functions in schema reporting to service_role;

-- ================================================================
-- القسم 4: إزالة نموذج التسعير الملغى وفق ق-17
-- ================================================================

-- إزالة القيد القديم
alter table ops.price_rules
  drop constraint if exists price_rules_diesel_pricing_model_check;

-- القيد الجديد: فقط inclusive_hourly مسموح
alter table ops.price_rules
  add constraint price_rules_diesel_pricing_model_check
    check (diesel_pricing_model is null or diesel_pricing_model = 'inclusive_hourly');

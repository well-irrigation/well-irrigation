-- =====================================================================
-- Migration 100: دعم تغيير مصدر الطاقة أثناء التوقف المؤقت للجلسة
--
-- القرار الحاكم: Q-129 / معايير قبول الأجهزة الميدانية
--
-- السلوك المعتمد:
--   جلسة جارية (RUNNING)
--   → إيقاف مؤقت (PAUSE): توقف احتساب الوقت والمبالغ
--   → اختيار وتأكيد مصدر طاقة جديد أثناء التوقف
--   → تبقى الجلسة متوقفة (PAUSED) بلا أي وقت مفوتر وبلا استئناف تلقائي
--   → يصبح المصدر الجديد معلّقاً (pending) للاستئناف
--   → عند الاستئناف (RESUME): يُفتح مقطع جارٍ جديد بالمصدر المعلّق
--   → يتم التقاط التسعيرة المعتمدة للمصدر الجديد عند لحظة الاستئناف
--
-- يحافظ على:
--   1. عدم فوترة أي ثانية توقف (FIN-001)
--   2. استقلالية احتساب كل مقطع (seconds * rate / 3600)
--   3. المسار الجاري الحالي كما هو دون أي تغيير في قواعده
--   4. التوقف والاستئناف العادي دون تغيير مصدر يحتفظ بسعره التاريخي
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. تحديث ops.change_session_energy_source لدعم المسار المتوقف
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
  v_tenant_id uuid;
  v_status text;
  v_segment_id uuid;
  v_segment_type text;
  v_current_source text;
  v_segment_started_at timestamptz;
  v_sequence_number integer;
  v_effective_source text;
  v_owner_person_id uuid;
  v_farmer_well_account_id uuid;
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

  select s.well_id, w.tenant_id, s.status, s.farmer_well_account_id
  into v_well_id, v_tenant_id, v_status, v_farmer_well_account_id
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
  for update of s;

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

  select ss.id, ss.segment_type, ss.energy_source, ss.started_at, ss.sequence_number
  into v_segment_id, v_segment_type, v_current_source, v_segment_started_at, v_sequence_number
  from ops.session_segments ss
  where ss.session_id = p_session_id and ss.ended_at is null
  order by ss.sequence_number desc
  limit 1
  for update;

  if not found then
    raise exception 'لا يوجد مقطع تشغيل مفتوح يمكن تغيير مصدره';
  end if;

  if v_segment_type in ('solar_run', 'well_diesel_run', 'farmer_diesel_run') then
    -- ============================================================
    -- المسار الجاري: السقي يعمل (RUNNING)
    -- ============================================================
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

  elsif v_segment_type in ('operator_pause', 'farmer_requested_pause', 'source_change_pause') then
    -- ============================================================
    -- المسار المتوقف: السقي موقوف مؤقتًا (PAUSED)
    -- ============================================================
    if p_closed_fuel_quantity_ml is not null or p_closed_fuel_measurement_type is not null then
      raise exception 'لا يمكن تسجيل بيانات إغلاق الوقود أثناء التوقف المؤقت';
    end if;
    if p_changed_at <= v_segment_started_at then
      raise exception 'وقت تغيير المصدر يجب أن يكون بعد وقت بدء المقطع الحالي';
    end if;

    -- تحديد المصدر الفعّال للمقارنة
    if v_current_source is not null then
      v_effective_source := v_current_source;
    else
      select ss.energy_source
      into v_effective_source
      from ops.session_segments ss
      where ss.session_id = p_session_id
        and ss.sequence_number < v_sequence_number
        and ss.segment_type in ('solar_run', 'well_diesel_run', 'farmer_diesel_run')
      order by ss.sequence_number desc
      limit 1;
    end if;

    if v_effective_source = p_new_source then
      raise exception 'مصدر الطاقة الجديد مطابق للمصدر الحالي';
    end if;

    -- التحقق من مالك الوقود عند التحويل إلى ديزل المزارع
    if p_new_source = 'farmer_diesel' then
      v_owner_person_id := p_new_fuel_owner_person_id;
      if v_owner_person_id is null and v_farmer_well_account_id is not null then
        select fp.person_id
        into v_owner_person_id
        from ops.farmer_well_accounts fwa
        join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
        where fwa.id = v_farmer_well_account_id;
      end if;

      if v_owner_person_id is null then
        raise exception 'يجب تحديد مالك ديزل المزارع قبل فتح المقطع';
      end if;

      if not exists (
        select 1 from core.persons p
        where p.id = v_owner_person_id and p.tenant_id = v_tenant_id
      ) then
        raise exception 'مالك ديزل المزارع لا ينتمي إلى جهة البئر';
      end if;
    else
      v_owner_person_id := null;
    end if;

    -- إغلاق مقطع التوقف الحالي
    update ops.session_segments
    set ended_at = p_changed_at
    where id = v_segment_id;

    -- فتح مقطع توقف جديد غير مفوتر يحمل المصدر المعلّق
    insert into ops.session_segments (
      tenant_id, session_id, sequence_number, segment_type,
      energy_source, started_at, is_billable, fuel_owner_person_id,
      notes
    ) values (
      v_tenant_id, p_session_id, v_sequence_number + 1, 'source_change_pause',
      p_new_source, p_changed_at, false, v_owner_person_id,
      'source_change_pause'
    )
    returning id into v_new_segment_id;

    return v_new_segment_id;

  else
    raise exception 'يجب استئناف الجلسة قبل تغيير مصدر الطاقة';
  end if;
end;
$function$;

revoke all on function ops.change_session_energy_source(
  uuid, text, timestamptz, bigint, text, uuid
) from public;

grant execute on function ops.change_session_energy_source(
  uuid, text, timestamptz, bigint, text, uuid
) to authenticated;


-- ---------------------------------------------------------------------
-- 2. تحديث ops.resume_irrigation_session لدعم المصدر المعلّق
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
  v_pause_energy_source text;
  v_pause_fuel_owner uuid;
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

  select ss.id, ss.segment_type, ss.started_at, ss.sequence_number,
         ss.energy_source, ss.fuel_owner_person_id
  into v_pause_id, v_pause_type, v_pause_started_at, v_sequence_number,
       v_pause_energy_source, v_pause_fuel_owner
  from ops.session_segments ss
  where ss.session_id = p_session_id and ss.ended_at is null
  order by ss.sequence_number desc
  limit 1
  for update;

  if not found then
    raise exception 'لا يوجد مقطع توقف مفتوح يمكن استئنافه';
  end if;
  if v_pause_type not in ('operator_pause', 'farmer_requested_pause', 'source_change_pause') then
    raise exception 'الجلسة تعمل بالفعل ولا يوجد مقطع توقف مفتوح';
  end if;
  if p_resumed_at <= v_pause_started_at then
    raise exception 'وقت الاستئناف يجب أن يكون بعد وقت بدء التوقف';
  end if;

  -- إغلاق مقطع التوقف الحالي
  update ops.session_segments
  set ended_at = p_resumed_at
  where id = v_pause_id;

  if v_pause_energy_source is not null then
    -- ============================================================
    -- الحالة ب: التوقف يحمل تغييراً معلّقاً لمصدر الطاقة
    -- يُلتقط السعر المعتمد للمصدر الجديد عند لحظة الاستئناف مباشرة
    -- ============================================================
    v_new_segment_id := ops.create_priced_session_segment(
      p_session_id,
      v_pause_energy_source,
      p_resumed_at,
      v_pause_fuel_owner
    );
  else
    -- ============================================================
    -- الحالة أ: توقف عادي دون تغيير مصدر الطاقة
    -- استئناف نفس المصدر والسعر التاريخي السابق دون إعادة تسعير
    -- ============================================================
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
  end if;

  return v_new_segment_id;
end;
$function$;

revoke all on function ops.resume_irrigation_session(
  uuid, timestamptz
) from public;

grant execute on function ops.resume_irrigation_session(
  uuid, timestamptz
) to authenticated;

-- القرار ق-77 - الملف 066: طبقة إجراءات الجلسة الذرية فوق زنادات الأمان الحالية

-- ربط الجلسة بحساب المزارع حتى يمكن إصدار فاتورتها دون تخمين.
alter table ops.irrigation_sessions
  add column farmer_well_account_id uuid
  references ops.farmer_well_accounts(id);

create index irrigation_sessions_farmer_account_idx
  on ops.irrigation_sessions (farmer_well_account_id)
  where farmer_well_account_id is not null;

-- تثبيت نتائج حساب كل مقطع بالثانية وبالمبلغ، دون تقريب زمني.
alter table ops.session_segments
  add column actual_seconds bigint,
  add column billable_seconds bigint,
  add column time_charge_minor bigint not null default 0,
  add column fuel_charge_minor bigint not null default 0,
  add column total_charge_minor bigint not null default 0,
  add constraint session_segments_actual_seconds_check
    check (actual_seconds is null or actual_seconds >= 0),
  add constraint session_segments_billable_seconds_check
    check (billable_seconds is null or billable_seconds >= 0),
  add constraint session_segments_time_charge_minor_check
    check (time_charge_minor >= 0),
  add constraint session_segments_fuel_charge_minor_check
    check (fuel_charge_minor >= 0),
  add constraint session_segments_total_charge_minor_check
    check (total_charge_minor = time_charge_minor + fuel_charge_minor);

-- الجلسة البسيطة تبقى على معادلة السعر الواحد، والجلسة المختلطة على مجموع المقاطع.
alter table billing.session_charges
  add column pricing_mode text not null default 'flat'
    check (pricing_mode in ('flat', 'segments'));

alter table billing.session_charges
  drop constraint session_charges_amount_formula_check;

alter table billing.session_charges
  add constraint session_charges_amount_formula_check
  check (
    pricing_mode = 'segments'
    or amount_minor = (duration_seconds::bigint * price_per_hour_minor) / 3600
  );

-- دالة داخلية تفتح مقطع تشغيل وتلتقط تسعيره مرة واحدة عند البدء أو تغيير المصدر.
create or replace function ops.create_priced_session_segment(
  p_session_id uuid,
  p_energy_source text,
  p_started_at timestamptz,
  p_fuel_owner_person_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path to 'ops', 'billing', 'core', 'pg_temp'
as $function$
declare
  v_segment_id uuid;
  v_tenant_id uuid;
  v_well_id uuid;
  v_farmer_well_account_id uuid;
  v_session_snapshot bigint;
  v_sequence_number integer;
  v_segment_type text;
  v_price_rule_id uuid;
  v_diesel_pricing_model text;
  v_hourly_rate_minor bigint;
  v_operation_rate_minor bigint;
  v_fuel_price_per_liter_minor bigint;
  v_owner_person_id uuid;
begin
  if p_energy_source not in ('solar', 'well_diesel', 'farmer_diesel') then
    raise exception 'مصدر الطاقة غير صالح؛ القيم المسموحة: solar أو well_diesel أو farmer_diesel';
  end if;

  select s.well_id, w.tenant_id, s.farmer_well_account_id,
         s.price_per_hour_minor_snapshot
  into v_well_id, v_tenant_id, v_farmer_well_account_id,
       v_session_snapshot
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;

  select coalesce(max(ss.sequence_number), 0) + 1
  into v_sequence_number
  from ops.session_segments ss
  where ss.session_id = p_session_id;

  select pr.id, pr.diesel_pricing_model, pr.hourly_rate_minor,
         pr.operation_hourly_rate_minor, pr.fuel_price_per_liter_minor
  into v_price_rule_id, v_diesel_pricing_model, v_hourly_rate_minor,
       v_operation_rate_minor, v_fuel_price_per_liter_minor
  from ops.price_schedules ps
  join ops.price_rules pr on pr.price_schedule_id = ps.id
  where ps.well_id = v_well_id
    and ps.status = 'active'
    and ps.effective_period @> p_started_at
    and pr.energy_source = p_energy_source
  order by lower(ps.effective_period) desc, ps.created_at desc, ps.id desc
  limit 1;

  if not found then
    if v_sequence_number = 1 then
      v_hourly_rate_minor := v_session_snapshot;
    else
      select wp.price_per_hour_minor
      into v_hourly_rate_minor
      from billing.well_pricing wp
      where wp.well_id = v_well_id
        and wp.period_start <= p_started_at
        and (wp.period_end is null or wp.period_end > p_started_at)
      order by wp.period_start desc, wp.created_at desc, wp.id desc
      limit 1;
    end if;

    v_price_rule_id := null;
    v_diesel_pricing_model := 'inclusive_hourly';
    v_operation_rate_minor := null;
    v_fuel_price_per_liter_minor := null;
  end if;

  if p_energy_source = 'solar' then
    if v_hourly_rate_minor is null or v_hourly_rate_minor <= 0 then
      raise exception 'لا يوجد سعر شمسي فعال يمكن تثبيته عند فتح المقطع';
    end if;
    v_operation_rate_minor := null;
    v_fuel_price_per_liter_minor := null;
    v_owner_person_id := null;
    v_segment_type := 'solar_run';
  elsif p_energy_source = 'well_diesel' then
    if v_diesel_pricing_model = 'operation_plus_fuel' then
      if v_operation_rate_minor is null or v_operation_rate_minor <= 0 then
        raise exception 'لا يوجد سعر تشغيل ديزل فعال يمكن تثبيته عند فتح المقطع';
      end if;
      if v_fuel_price_per_liter_minor is null or v_fuel_price_per_liter_minor < 0 then
        raise exception 'لا يوجد سعر وقود صالح يمكن تثبيته لمقطع ديزل البئر';
      end if;
      v_hourly_rate_minor := null;
    elsif v_hourly_rate_minor is null or v_hourly_rate_minor <= 0 then
      raise exception 'لا يوجد سعر ديزل شامل فعال يمكن تثبيته عند فتح المقطع';
    else
      v_operation_rate_minor := null;
      v_fuel_price_per_liter_minor := null;
    end if;
    v_owner_person_id := null;
    v_segment_type := 'well_diesel_run';
  else
    if v_diesel_pricing_model = 'operation_plus_fuel' then
      if v_operation_rate_minor is null or v_operation_rate_minor <= 0 then
        raise exception 'لا يوجد سعر تشغيل ديزل فعال يمكن تثبيته عند فتح المقطع';
      end if;
      if v_fuel_price_per_liter_minor is null or v_fuel_price_per_liter_minor < 0 then
        raise exception 'لا يوجد سعر وقود صالح يمكن تثبيته لمقطع ديزل المزارع';
      end if;
      v_hourly_rate_minor := null;
    elsif v_hourly_rate_minor is null or v_hourly_rate_minor <= 0 then
      raise exception 'لا يوجد سعر ديزل شامل فعال يمكن تثبيته عند فتح المقطع';
    else
      v_operation_rate_minor := null;
      v_fuel_price_per_liter_minor := null;
    end if;

    v_owner_person_id := p_fuel_owner_person_id;
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

    v_segment_type := 'farmer_diesel_run';
  end if;

  insert into ops.session_segments (
    tenant_id, session_id, sequence_number, segment_type, energy_source,
    started_at, is_billable, fuel_owner_person_id, applied_price_rule_id,
    applied_hourly_rate_minor, applied_operation_rate_minor,
    applied_fuel_price_per_liter_minor
  ) values (
    v_tenant_id, p_session_id, v_sequence_number, v_segment_type,
    p_energy_source, p_started_at, true, v_owner_person_id, v_price_rule_id,
    v_hourly_rate_minor, v_operation_rate_minor,
    v_fuel_price_per_liter_minor
  )
  returning id into v_segment_id;

  return v_segment_id;
end;
$function$;

-- شبكة الأمان القديمة تبقى للجلسات البسيطة، وتتخطى جلسات المقاطع التي يكملها الإجراء.
create or replace function ops.compute_session_charge()
returns trigger
language plpgsql
security definer
set search_path to 'ops', 'billing', 'pg_temp'
as $function$
declare
  v_duration_seconds integer;
  v_price_per_hour_minor bigint;
  v_amount_minor bigint;
begin
  if new.status in ('closed', 'forgotten') and new.ended_at is not null
     and old.status = 'open' then

    if exists (
      select 1 from ops.session_segments ss where ss.session_id = new.id
    ) then
      return new;
    end if;

    v_duration_seconds := extract(epoch from (new.ended_at - new.started_at))::integer;
    v_price_per_hour_minor := new.price_per_hour_minor_snapshot;

    if v_price_per_hour_minor is null then
      raise exception 'لا يوجد سعر مثبت لهذه الجلسة — يجب ضبط سعر البئر قبل بدء الجلسة';
    end if;

    v_amount_minor := (v_duration_seconds::bigint * v_price_per_hour_minor) / 3600;

    insert into billing.session_charges (
      session_id, well_id, duration_seconds, price_per_hour_minor,
      amount_minor, pricing_mode
    ) values (
      new.id, new.well_id, v_duration_seconds, v_price_per_hour_minor,
      v_amount_minor, 'flat'
    );
  end if;

  return new;
end;
$function$;

-- 5) إكمال الجلسة ذريًا وحساب المقاطع والوقود وملخص التكلفة.
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
  if v_actor is null or not iam.has_well_role(v_well_id, array['owner', 'manager', 'operator']) then
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

-- 3) تغيير مصدر الطاقة؛ السعر الجديد يلتقط هنا فقط للمقطع الجديد.
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
  if v_actor is null or not iam.has_well_role(v_well_id, array['owner', 'manager', 'operator']) then
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

-- 4) استئناف الجلسة بنسخة السعر والمصدر الأخيرين دون التقاط سعر جديد.
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
  if v_actor is null or not iam.has_well_role(v_well_id, array['owner', 'manager', 'operator']) then
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

revoke all on function ops.create_priced_session_segment(uuid, text, timestamptz, uuid) from public;

-- 1) بدء جلسة مع أول مقطع تشغيل.
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
  if not iam.has_well_role(p_well_id, array['owner', 'manager', 'operator']) then
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

-- 2) إيقاف الجلسة مؤقتًا وإضافة مقطع غير مفوتر.
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
  if v_actor is null or not iam.has_well_role(v_well_id, array['owner', 'manager', 'operator']) then
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

-- 6) إنشاء فاتورة الجلسة وبنود المقاطع ثم إصدارها لتعمل زنادات الترحيل الحالية.
create or replace function billing.issue_session_invoice(
  p_session_id uuid,
  p_issued_by uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'billing', 'ops', 'finance', 'core', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_well_id uuid;
  v_farmer_well_account_id uuid;
  v_session_status text;
  v_ended_at timestamptz;
  v_charge_amount bigint;
  v_invoice_id uuid;
  v_partner_policy_id uuid;
  v_partner_policy_type text;
  v_settlement_method text := 'normal';
  v_line_number integer := 0;
  v_lines_total bigint;
  v_segment record;
  v_time_rate bigint;
  v_fuel_quantity bigint;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إصدار فاتورة الجلسة';
  end if;
  if p_issued_by is distinct from v_actor then
    raise exception 'مصدر الفاتورة يجب أن يطابق المستخدم المسجل حاليًا';
  end if;

  select w.tenant_id, s.well_id, s.farmer_well_account_id,
         s.status, s.ended_at
  into v_tenant_id, v_well_id, v_farmer_well_account_id,
       v_session_status, v_ended_at
  from ops.irrigation_sessions s
  join core.wells w on w.id = s.well_id
  where s.id = p_session_id
  for update of s;

  if not found then
    raise exception 'جلسة السقي غير موجودة: %', p_session_id;
  end if;
  if v_session_status <> 'closed' then
    raise exception 'لا يمكن إصدار فاتورة قبل إكمال الجلسة';
  end if;
  if not iam.has_well_role(v_well_id, array['owner', 'manager', 'operator']) then
    raise exception 'لا تملك صلاحية إصدار فاتورة هذه الجلسة';
  end if;
  if v_farmer_well_account_id is null then
    raise exception 'لا يمكن إصدار الفاتورة لأن الجلسة غير مرتبطة بحساب مزارع';
  end if;
  if exists (
    select 1 from billing.invoices i
    where i.session_id = p_session_id
      and i.status not in ('cancelled', 'reversed')
  ) then
    raise exception 'توجد فاتورة سارية مسبقًا لهذه الجلسة';
  end if;
  if not exists (
    select 1 from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.ended_at is not null
  ) then
    raise exception 'لا توجد مقاطع مكتملة يمكن بناء بنود الفاتورة منها';
  end if;

  select sc.amount_minor
  into v_charge_amount
  from billing.session_charges sc
  where sc.session_id = p_session_id
    and sc.pricing_mode = 'segments';

  if not found then
    raise exception 'لا يوجد ملخص تكلفة مقاطع مكتمل لهذه الجلسة';
  end if;

  select pip.id, pip.policy_type
  into v_partner_policy_id, v_partner_policy_type
  from ops.farmer_well_accounts fwa
  join ops.farmer_profiles fp on fp.id = fwa.farmer_profile_id
  join core.well_partners wp
    on wp.well_id = fwa.well_id and wp.person_id = fp.person_id
  join core.partner_irrigation_policies pip
    on pip.partner_id = wp.id and pip.well_id = fwa.well_id
  where fwa.id = v_farmer_well_account_id
    and pip.period_start <= v_ended_at::date
    and (pip.period_end is null or pip.period_end > v_ended_at::date)
  order by pip.period_start desc, pip.created_at desc, pip.id desc
  limit 1;

  if found and v_partner_policy_type = 'deduct_from_profit' then
    v_settlement_method := 'partner_profit_offset';
  end if;

  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    session_id, invoice_date, status, subtotal_minor, total_minor,
    paid_minor, outstanding_minor, settlement_method, partner_policy_id
  ) values (
    v_tenant_id, core.generate_public_code('INV'), v_well_id,
    v_farmer_well_account_id, p_session_id, v_ended_at, 'draft',
    v_charge_amount, v_charge_amount, 0, v_charge_amount,
    v_settlement_method, v_partner_policy_id
  )
  returning id into v_invoice_id;

  for v_segment in
    select ss.id, ss.sequence_number, ss.segment_type, ss.energy_source,
           ss.billable_seconds, ss.applied_hourly_rate_minor,
           ss.applied_operation_rate_minor,
           ss.applied_fuel_price_per_liter_minor,
           ss.fuel_actual_ml, ss.fuel_estimated_ml,
           ss.time_charge_minor, ss.fuel_charge_minor,
           ss.total_charge_minor
    from ops.session_segments ss
    where ss.session_id = p_session_id
      and ss.is_billable
      and ss.total_charge_minor > 0
    order by ss.sequence_number
  loop
    if v_segment.time_charge_minor > 0 then
      v_line_number := v_line_number + 1;
      v_time_rate := coalesce(v_segment.applied_operation_rate_minor,
                              v_segment.applied_hourly_rate_minor);

      insert into billing.invoice_lines (
        tenant_id, invoice_id, line_number, line_type, description,
        quantity, unit, unit_price_minor, amount_minor,
        session_segment_id
      ) values (
        v_tenant_id, v_invoice_id, v_line_number,
        case when v_segment.energy_source = 'solar'
          then 'solar_irrigation' else 'diesel_operation' end,
        case when v_segment.energy_source = 'solar'
          then 'سقي شمسي — المقطع ' || v_segment.sequence_number
          else 'تشغيل ديزل — المقطع ' || v_segment.sequence_number end,
        v_segment.billable_seconds::numeric / 3600,
        'hour', v_time_rate, v_segment.time_charge_minor,
        v_segment.id
      );
    end if;

    if v_segment.fuel_charge_minor > 0 then
      v_line_number := v_line_number + 1;
      v_fuel_quantity := coalesce(v_segment.fuel_actual_ml,
                                  v_segment.fuel_estimated_ml);

      insert into billing.invoice_lines (
        tenant_id, invoice_id, line_number, line_type, description,
        quantity, unit, unit_price_minor, amount_minor,
        session_segment_id
      ) values (
        v_tenant_id, v_invoice_id, v_line_number, 'diesel_fuel',
        'وقود ديزل — المقطع ' || v_segment.sequence_number,
        v_fuel_quantity::numeric / 1000,
        'liter', v_segment.applied_fuel_price_per_liter_minor,
        v_segment.fuel_charge_minor, v_segment.id
      );
    end if;
  end loop;

  if v_line_number = 0 then
    raise exception 'لم تنتج مقاطع الجلسة أي بند قابل للفوترة';
  end if;

  select coalesce(sum(il.amount_minor), 0)
  into v_lines_total
  from billing.invoice_lines il
  where il.invoice_id = v_invoice_id;

  if v_lines_total <> v_charge_amount then
    raise exception 'مجموع بنود الفاتورة % لا يساوي تكلفة الجلسة %',
      v_lines_total, v_charge_amount;
  end if;

  update billing.invoices
  set status = 'issued',
      issued_at = clock_timestamp(),
      issued_by = p_issued_by
  where id = v_invoice_id;

  return v_invoice_id;
end;
$function$;

-- حصر العقد العام على المستخدمين الموثقين فقط.
revoke all on function ops.start_irrigation_session(uuid, uuid, uuid, uuid, uuid, text, timestamptz, uuid) from public;
revoke all on function ops.pause_irrigation_session(uuid, text, timestamptz) from public;
revoke all on function ops.change_session_energy_source(uuid, text, timestamptz, bigint, text, uuid) from public;
revoke all on function ops.resume_irrigation_session(uuid, timestamptz) from public;
revoke all on function ops.complete_irrigation_session(uuid, timestamptz, bigint, text, uuid) from public;
revoke all on function billing.issue_session_invoice(uuid, uuid) from public;

grant execute on function ops.start_irrigation_session(uuid, uuid, uuid, uuid, uuid, text, timestamptz, uuid) to authenticated;
grant execute on function ops.pause_irrigation_session(uuid, text, timestamptz) to authenticated;
grant execute on function ops.change_session_energy_source(uuid, text, timestamptz, bigint, text, uuid) to authenticated;
grant execute on function ops.resume_irrigation_session(uuid, timestamptz) to authenticated;
grant execute on function ops.complete_irrigation_session(uuid, timestamptz, bigint, text, uuid) to authenticated;
grant execute on function billing.issue_session_invoice(uuid, uuid) to authenticated;

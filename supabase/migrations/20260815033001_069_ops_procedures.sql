-- =====================================================================
-- 069 — إجراءات التشغيل الذرية المتبقية
-- =====================================================================

-- 1) إنشاء شخص ومزارع وحساب بئر، مع منع التطابق الكامل دون دمج تلقائي.
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
  if not iam.has_well_role(p_well_id, array['owner', 'operator']) then
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

-- 2) إنشاء أرض. الحقل الحالي يشير إلى iam.profiles، لذلك يلزم تعيين مزارع نشط.
create or replace function ops.create_farm(
  p_well_id uuid,
  p_name text,
  p_farmer_profile_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'ops', 'core', 'audit', 'iam', 'pg_temp'
as $function$
declare
  v_actor uuid;
  v_tenant_id uuid;
  v_farm_id uuid;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'يجب تسجيل الدخول قبل إنشاء أرض';
  end if;
  if not iam.has_well_role(p_well_id, array['owner']) then
    raise exception 'لا تملك صلاحية إنشاء أرض في هذا البئر';
  end if;
  if nullif(btrim(p_name), '') is null then
    raise exception 'اسم الأرض مطلوب';
  end if;

  select w.tenant_id into v_tenant_id
  from core.wells w where w.id = p_well_id;
  if not found then
    raise exception 'البئر غير موجود: %', p_well_id;
  end if;

  if p_farmer_profile_id is null or not exists (
    select 1 from iam.profiles p
    join core.well_assignments wa
      on wa.profile_id = p.id and wa.well_id = p_well_id
    where p.id = p_farmer_profile_id
      and wa.role = 'farmer' and wa.status = 'active'
  ) then
    raise exception 'ملف المزارع غير موجود أو لا يملك تعيينًا نشطًا كمزارع في هذا البئر';
  end if;

  -- لا يوجد أي شرط على الجلسات المفتوحة؛ إنشاء الأرض مسموح أثناء التشغيل.
  insert into ops.farms (well_id, name, farmer_profile_id, status)
  values (p_well_id, btrim(p_name), p_farmer_profile_id, 'active')
  returning id into v_farm_id;

  perform audit.log(
    v_tenant_id, p_well_id, 'create_farm', 'ops.farms', v_farm_id,
    null,
    jsonb_build_object(
      'farm_id', v_farm_id,
      'name', btrim(p_name),
      'farmer_profile_id', p_farmer_profile_id
    ),
    'إنشاء أرض للمزارع'
  );

  return jsonb_build_object(
    'farm_id', v_farm_id,
    'well_id', p_well_id,
    'farmer_profile_id', p_farmer_profile_id,
    'status', 'active'
  );
end;
$function$;

-- 3) حجز سقي وحجز موارده في العملية نفسها.
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
  if not iam.has_well_role(p_well_id, array['owner', 'operator']) then
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

-- 4) إعادة جدولة حجز قابل للنقل، مع تحرير الموارد القديمة وحجز الجديدة.
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
  if not iam.has_well_role(v_booking.well_id, array['owner', 'operator']) then
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

-- 5) شراء الوقود عبر جدول الشراء القديم ليعمل الجسر والتقييم والترحيل القائم.
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
  if not iam.has_well_role(p_well_id, array['owner', 'operator']) then
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

-- 6) استهلاك فعلي أو تقديري، للبئر أو لمزارع محدد.
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
  if not iam.has_well_role(p_well_id, array['owner', 'operator']) then
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

-- توسيع زناد قيود الوقود بفروقات الجرد، مع إبقاء الشراء والاستهلاك كما هما.
create or replace function finance.journalize_fuel_transaction()
returns trigger
language plpgsql
security definer
set search_path to 'finance', 'core', 'pg_temp'
as $function$
declare
  v_je uuid;
begin
  if new.status <> 'posted' or new.ownership_type <> 'well' then
    return new;
  end if;
  if new.transaction_type = 'opening_balance' then
    return new;
  end if;
  if new.total_cost_minor is null or new.total_cost_minor <= 0 then
    return new;
  end if;

  if new.transaction_type = 'purchase' and new.direction = 'in' then
    insert into finance.journal_entries (
      tenant_id, public_code, well_id, entry_date,
      source_type, source_id, description, idempotency_key
    ) values (
      new.tenant_id, core.generate_public_code('JE'), new.well_id,
      new.occurred_at, 'fuel_purchase', new.id, 'شراء ديزل',
      'FTX-' || new.id::text
    ) returning id into v_je;
    insert into finance.journal_lines (
      tenant_id, journal_entry_id, ledger_account_id, entry_side,
      amount_minor, fuel_tank_id, cashbox_id, description
    ) values
      (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1200'),
       'debit', new.total_cost_minor, new.fuel_tank_id, null, 'مخزون ديزل البئر'),
      (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1000'),
       'credit', new.total_cost_minor, null, finance.main_cashbox_id(new.well_id),
       'النقد والصناديق');

  elsif new.transaction_type = 'session_consumption' and new.direction = 'out' then
    insert into finance.journal_entries (
      tenant_id, public_code, well_id, entry_date,
      source_type, source_id, description, idempotency_key
    ) values (
      new.tenant_id, core.generate_public_code('JE'), new.well_id,
      new.occurred_at, 'fuel_consumption', new.id,
      'استهلاك ديزل في التشغيل', 'FTC-' || new.id::text
    ) returning id into v_je;
    insert into finance.journal_lines (
      tenant_id, journal_entry_id, ledger_account_id, entry_side,
      amount_minor, fuel_tank_id, description
    ) values
      (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '5000'),
       'debit', new.total_cost_minor, new.fuel_tank_id, 'تكلفة ديزل مستهلك'),
      (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1200'),
       'credit', new.total_cost_minor, new.fuel_tank_id, 'مخزون ديزل البئر');

  elsif new.transaction_type = 'physical_count' then
    insert into finance.journal_entries (
      tenant_id, public_code, well_id, entry_date,
      source_type, source_id, description, idempotency_key
    ) values (
      new.tenant_id, core.generate_public_code('JE'), new.well_id,
      new.occurred_at, 'fuel_physical_count', new.id,
      'فرق جرد فعلي للديزل', 'FPC-' || new.id::text
    ) returning id into v_je;

    if new.direction = 'out' then
      insert into finance.journal_lines (
        tenant_id, journal_entry_id, ledger_account_id, entry_side,
        amount_minor, fuel_tank_id, description
      ) values
        (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '5800'),
         'debit', new.total_cost_minor, new.fuel_tank_id, 'عجز جرد الديزل'),
        (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1200'),
         'credit', new.total_cost_minor, new.fuel_tank_id, 'تخفيض مخزون الديزل');
    else
      insert into finance.journal_lines (
        tenant_id, journal_entry_id, ledger_account_id, entry_side,
        amount_minor, fuel_tank_id, description
      ) values
        (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '1200'),
         'debit', new.total_cost_minor, new.fuel_tank_id, 'زيادة مخزون الديزل'),
        (new.tenant_id, v_je, finance.ledger_account_id(new.well_id, '5800'),
         'credit', new.total_cost_minor, new.fuel_tank_id, 'زيادة ناتجة عن الجرد');
    end if;
  end if;

  if v_je is not null then
    perform finance.post_journal_entry(v_je, new.created_by);
  end if;
  return new;
end;
$function$;

-- 7) الجرد الفعلي: الفرق فقط هو الذي يسجل حركة وقيدًا.
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
  if not iam.has_well_role(p_well_id, array['owner', 'operator']) then
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

-- العقود العامة للمستخدمين الموثقين فقط.
revoke all on function ops.create_farmer(uuid, text, text, text, text, bigint) from public;
revoke all on function ops.create_farmer(uuid, text, text, text, text, bigint) from anon;
revoke all on function ops.create_farm(uuid, text, uuid) from public;
revoke all on function ops.create_farm(uuid, text, uuid) from anon;
revoke all on function ops.create_booking(uuid, uuid, uuid, timestamptz, timestamptz, uuid, uuid, text, integer, text) from public;
revoke all on function ops.create_booking(uuid, uuid, uuid, timestamptz, timestamptz, uuid, uuid, text, integer, text) from anon;
revoke all on function ops.reschedule_booking(uuid, timestamptz, timestamptz, text) from public;
revoke all on function ops.reschedule_booking(uuid, timestamptz, timestamptz, text) from anon;
revoke all on function inventory.purchase_fuel(uuid, numeric, bigint, timestamptz, uuid) from public;
revoke all on function inventory.purchase_fuel(uuid, numeric, bigint, timestamptz, uuid) from anon;
revoke all on function inventory.record_fuel_consumption(uuid, bigint, text, text, uuid, uuid, uuid, uuid, timestamptz, uuid, uuid) from public;
revoke all on function inventory.record_fuel_consumption(uuid, bigint, text, text, uuid, uuid, uuid, uuid, timestamptz, uuid, uuid) from anon;
revoke all on function inventory.record_physical_fuel_count(uuid, uuid, bigint, timestamptz, uuid, text) from public;
revoke all on function inventory.record_physical_fuel_count(uuid, uuid, bigint, timestamptz, uuid, text) from anon;

grant execute on function ops.create_farmer(uuid, text, text, text, text, bigint) to authenticated;
grant execute on function ops.create_farm(uuid, text, uuid) to authenticated;
grant execute on function ops.create_booking(uuid, uuid, uuid, timestamptz, timestamptz, uuid, uuid, text, integer, text) to authenticated;
grant execute on function ops.reschedule_booking(uuid, timestamptz, timestamptz, text) to authenticated;
grant execute on function inventory.purchase_fuel(uuid, numeric, bigint, timestamptz, uuid) to authenticated;
grant execute on function inventory.record_fuel_consumption(uuid, bigint, text, text, uuid, uuid, uuid, uuid, timestamptz, uuid, uuid) to authenticated;
grant execute on function inventory.record_physical_fuel_count(uuid, uuid, bigint, timestamptz, uuid, text) to authenticated;

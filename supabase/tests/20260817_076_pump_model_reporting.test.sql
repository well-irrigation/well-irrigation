begin;

do $$
declare
  v_tenant uuid;
  v_other_tenant uuid;
  v_well uuid;
  v_other_well uuid;

  v_user uuid;
  v_profile uuid;

  v_person uuid;
  v_farmer_profile uuid;
  v_account uuid;
  v_farm uuid;

  v_pump uuid;
  v_legacy_pump uuid;
  v_status_pump uuid;
  v_mixed_session uuid;
  v_legacy_session uuid;

  v_solar bigint;
  v_diesel bigint;

  v_flag_a boolean;
  v_flag_b boolean;
begin

  insert into core.tenants (name)
  values ('جهة اختبار ق-81')
  returning id into v_tenant;

  insert into core.tenants (name)
  values ('جهة أخرى اختبار ق-81')
  returning id into v_other_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر اختبار ق-81')
  returning id into v_well;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر آخر اختبار ق-81')
  returning id into v_other_well;


  insert into auth.users (
    id,
    instance_id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    created_at,
    updated_at
  )
  values (
    gen_random_uuid(),
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'q81@test.local',
    crypt('x', gen_salt('bf')),
    now(),
    now(),
    now()
  )
  returning id into v_user;

  select id
  into v_profile
  from iam.profiles
  where id = v_user;

  if v_profile is null then
    insert into iam.profiles (id, full_name)
    values (v_user, 'مشغل ق-81')
    returning id into v_profile;
  end if;


  insert into core.persons (
    tenant_id,
    full_name,
    normalized_name
  )
  values (
    v_tenant,
    'مزارع ق-81',
    'مزارع ق-81'
  )
  returning id into v_person;

  insert into ops.farmer_profiles (
    tenant_id,
    person_id
  )
  values (
    v_tenant,
    v_person
  )
  returning id into v_farmer_profile;

  insert into ops.farmer_well_accounts (
    tenant_id,
    farmer_profile_id,
    well_id,
    public_code
  )
  values (
    v_tenant,
    v_farmer_profile,
    v_well,
    'FWA-Q81'
  )
  returning id into v_account;

  insert into ops.farms (
    well_id,
    name,
    farmer_well_account_id
  )
  values (
    v_well,
    'أرض اختبار ق-81',
    v_account
  )
  returning id into v_farm;


  -- -----------------------------------------------------------
  -- PASS 1
  -- Canonical pump columns exist.
  -- -----------------------------------------------------------

  if (
    select count(*)
    from information_schema.columns
    where table_schema = 'core'
      and table_name = 'pumps'
      and column_name in (
        'tenant_id',
        'public_code',
        'pump_type',
        'power_rating',
        'estimated_fuel_ml_per_hour',
        'estimated_water_flow_liters_per_minute',
        'installed_at',
        'notes'
      )
  ) = 8 then
    raise notice
      'PASS 1: نموذج المضخة يحتوي حقول المعدة المرجعية';
  else
    raise notice
      'FAIL 1: حقول نموذج المضخة المرجعية غير مكتملة';
  end if;


  -- -----------------------------------------------------------
  -- PASS 2
  -- power_source is legacy/nullable.
  -- -----------------------------------------------------------

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'core'
      and table_name = 'pumps'
      and column_name = 'power_source'
      and is_nullable = 'YES'
  )
  and coalesce(
    col_description(
      'core.pumps'::regclass,
      (
        select ordinal_position
        from information_schema.columns
        where table_schema = 'core'
          and table_name = 'pumps'
          and column_name = 'power_source'
      )
    ),
    ''
  ) ilike '%Legacy compatibility%'
  then
    raise notice
      'PASS 2: power_source أصبح legacy nullable وليس حقيقة تشغيلية';
  else
    raise notice
      'FAIL 2: power_source ما زال معرفًا كحقيقة إلزامية';
  end if;


  -- -----------------------------------------------------------
  -- PASS 3
  -- Legacy fixture shape still auto-fills tenant/public_code.
  -- -----------------------------------------------------------

  insert into core.pumps (
    well_id,
    name,
    power_source,
    pump_type,
    power_rating,
    estimated_fuel_ml_per_hour,
    estimated_water_flow_liters_per_minute,
    installed_at,
    notes
  )
  values (
    v_well,
    'مضخة حديثة ق-81',
    null,
    'centrifugal',
    '25 HP',
    4500,
    1200.500,
    date '2026-01-01',
    'اختبار النموذج الجديد'
  )
  returning id into v_pump;

  if exists (
    select 1
    from core.pumps p
    where p.id = v_pump
      and p.tenant_id = v_tenant
      and p.public_code like 'P-%'
  ) then
    raise notice
      'PASS 3: tenant/public_code يملآن تلقائيًا من هوية البئر والمضخة';
  else
    raise notice
      'FAIL 3: لم تكتمل هوية المضخة تلقائيًا';
  end if;


  -- -----------------------------------------------------------
  -- PASS 4
  -- Tenant/well mismatch is rejected.
  -- -----------------------------------------------------------

  begin
    insert into core.pumps (
      tenant_id,
      well_id,
      name
    )
    values (
      v_other_tenant,
      v_well,
      'مضخة جهة خاطئة'
    );

    raise notice
      'FAIL 4: سُمح بربط المضخة بجهة غير جهة البئر';

  exception when others then

    if position(
      'جهة المضخة لا تطابق جهة البئر'
      in sqlerrm
    ) > 0 then
      raise notice
        'PASS 4: رُفض Tenant/Well mismatch للمضخة';
    else
      raise notice
        'FAIL 4: سبب رفض Tenant/Well mismatch غير متوقع: %',
        sqlerrm;
    end if;

  end;


  -- -----------------------------------------------------------
  -- PASS 5
  -- Maintenance/retired lifecycle + invalid state rejection.
  -- -----------------------------------------------------------

  insert into core.pumps (
    well_id,
    name,
    status
  )
  values (
    v_well,
    'مضخة دورة الحالة',
    'maintenance'
  )
  returning id into v_status_pump;

  update core.pumps
  set status = 'retired'
  where id = v_status_pump;

  v_flag_a :=
    (
      select status = 'retired'
      from core.pumps
      where id = v_status_pump
    );

  v_flag_b := false;

  begin
    update core.pumps
    set status = 'broken-invalid-state'
    where id = v_status_pump;

  exception when check_violation then
    v_flag_b := true;
  end;

  if v_flag_a and v_flag_b then
    raise notice
      'PASS 5: maintenance/retired مدعومتان والحالة غير الصالحة مرفوضة';
  else
    raise notice
      'FAIL 5: دورة حالة المضخة غير صحيحة';
  end if;


  -- -----------------------------------------------------------
  -- PASS 6
  -- Public code unique inside the well.
  -- -----------------------------------------------------------

  insert into core.pumps (
    well_id,
    public_code,
    name
  )
  values (
    v_well,
    'PUMP-Q81-DUP',
    'مضخة كود أول'
  );

  begin
    insert into core.pumps (
      well_id,
      public_code,
      name
    )
    values (
      v_well,
      'PUMP-Q81-DUP',
      'مضخة كود مكرر'
    );

    raise notice
      'FAIL 6: سُمح بتكرار public_code داخل البئر';

  exception when unique_violation then
    raise notice
      'PASS 6: public_code فريد داخل البئر';
  end;


  -- -----------------------------------------------------------
  -- PASS 7
  -- Negative equipment estimates rejected.
  -- -----------------------------------------------------------

  v_flag_a := false;
  v_flag_b := false;

  begin
    insert into core.pumps (
      well_id,
      name,
      estimated_fuel_ml_per_hour
    )
    values (
      v_well,
      'مضخة وقود سالب',
      -1
    );
  exception when check_violation then
    v_flag_a := true;
  end;

  begin
    insert into core.pumps (
      well_id,
      name,
      estimated_water_flow_liters_per_minute
    )
    values (
      v_well,
      'مضخة تدفق سالب',
      -0.001
    );
  exception when check_violation then
    v_flag_b := true;
  end;

  if v_flag_a and v_flag_b then
    raise notice
      'PASS 7: القيم التقديرية السالبة للمضخة مرفوضة';
  else
    raise notice
      'FAIL 7: حراس القيم التقديرية غير مكتملين';
  end if;


  -- Pricing is needed for the historical flat-session fallback.
  insert into billing.well_pricing (
    well_id,
    price_per_hour_minor,
    period_start
  )
  values (
    v_well,
    4000,
    date '2026-01-01'
  );


  -- -----------------------------------------------------------
  -- Modern mixed session:
  -- 1200 solar + 1800 well diesel + 600 farmer diesel.
  -- -----------------------------------------------------------

  insert into ops.irrigation_sessions (
    well_id,
    pump_id,
    farm_id,
    farmer_well_account_id,
    operator_profile_id,
    started_at,
    ended_at,
    status
  )
  values (
    v_well,
    v_pump,
    v_farm,
    v_account,
    v_profile,
    timestamptz '2026-10-01 08:00:00+00',
    timestamptz '2026-10-01 09:00:00+00',
    'closed'
  )
  returning id into v_mixed_session;

  insert into ops.session_segments (
    tenant_id,
    session_id,
    sequence_number,
    segment_type,
    energy_source,
    started_at,
    ended_at,
    is_billable,
    actual_seconds,
    billable_seconds
  )
  values
  (
    v_tenant,
    v_mixed_session,
    1,
    'solar_run',
    'solar',
    timestamptz '2026-10-01 08:00:00+00',
    timestamptz '2026-10-01 08:20:00+00',
    true,
    1200,
    1200
  ),
  (
    v_tenant,
    v_mixed_session,
    2,
    'well_diesel_run',
    'well_diesel',
    timestamptz '2026-10-01 08:20:00+00',
    timestamptz '2026-10-01 08:50:00+00',
    true,
    1800,
    1800
  ),
  (
    v_tenant,
    v_mixed_session,
    3,
    'farmer_diesel_run',
    'farmer_diesel',
    timestamptz '2026-10-01 08:50:00+00',
    timestamptz '2026-10-01 09:00:00+00',
    true,
    600,
    600
  );

  select
    solar_seconds,
    diesel_seconds
  into
    v_solar,
    v_diesel
  from reporting.well_daily_summary
  where well_id = v_well
    and day = date '2026-10-01';

  if v_solar = 1200
     and v_diesel = 2400 then
    raise notice
      'PASS 8: التقرير يصنف الجلسة المختلطة من session_segments';
  else
    raise notice
      'FAIL 8: تصنيف المقاطع = solar %, diesel % والمتوقع 1200/2400',
      v_solar,
      v_diesel;
  end if;


  -- -----------------------------------------------------------
  -- Legacy flat session remains supported.
  -- -----------------------------------------------------------

  insert into core.pumps (
    well_id,
    name,
    power_source
  )
  values (
    v_well,
    'مضخة Legacy flat',
    'solar'
  )
  returning id into v_legacy_pump;

  insert into ops.irrigation_sessions (
    well_id,
    pump_id,
    farm_id,
    farmer_well_account_id,
    operator_profile_id,
    started_at,
    status
  )
  values (
    v_well,
    v_legacy_pump,
    v_farm,
    v_account,
    v_profile,
    timestamptz '2026-10-01 10:00:00+00',
    'open'
  )
  returning id into v_legacy_session;

  update ops.irrigation_sessions
  set
    ended_at = timestamptz '2026-10-01 10:15:00+00',
    status = 'closed'
  where id = v_legacy_session;

  select
    solar_seconds,
    diesel_seconds
  into
    v_solar,
    v_diesel
  from reporting.well_daily_summary
  where well_id = v_well
    and day = date '2026-10-01';

  if v_solar = 2100
     and v_diesel = 2400 then
    raise notice
      'PASS 9: legacy flat fallback بقي متوافقًا دون تلويث مصدر المقاطع';
  else
    raise notice
      'FAIL 9: legacy fallback = solar %, diesel % والمتوقع 2100/2400',
      v_solar,
      v_diesel;
  end if;


  -- -----------------------------------------------------------
  -- PASS 10
  -- Reservation function now honors pump-specific limit = 2.
  -- -----------------------------------------------------------

  insert into ops.resource_concurrency_rules (
    tenant_id,
    well_id,
    resource_type,
    resource_id,
    max_parallel_sessions
  )
  values (
    v_tenant,
    v_well,
    'pump',
    v_pump,
    2
  );

  perform ops.reserve_resource(
    v_well,
    'pump',
    v_pump,
    tstzrange(
      timestamptz '2026-10-02 08:00:00+00',
      timestamptz '2026-10-02 09:00:00+00',
      '[)'
    )
  );

  perform ops.reserve_resource(
    v_well,
    'pump',
    v_pump,
    tstzrange(
      timestamptz '2026-10-02 08:15:00+00',
      timestamptz '2026-10-02 08:45:00+00',
      '[)'
    )
  );

  begin
    perform ops.reserve_resource(
      v_well,
      'pump',
      v_pump,
      tstzrange(
        timestamptz '2026-10-02 08:30:00+00',
        timestamptz '2026-10-02 08:40:00+00',
        '[)'
      )
    );

    raise notice
      'FAIL 10: سُمح بالحجز الثالث فوق حد المضخة 2';

  exception when others then

    if position(
      'الحد الأقصى للتوازي: 2'
      in sqlerrm
    ) > 0 then
      raise notice
        'PASS 10: reserve_resource يحترم قاعدة المضخة max=2';
    else
      raise notice
        'FAIL 10: سبب رفض الحجز الثالث غير متوقع: %',
        sqlerrm;
    end if;

  end;


  -- -----------------------------------------------------------
  -- PASS 11
  -- A pump from another well cannot be reserved.
  -- -----------------------------------------------------------

  begin
    perform ops.reserve_resource(
      v_other_well,
      'pump',
      v_pump,
      tstzrange(
        timestamptz '2026-10-03 08:00:00+00',
        timestamptz '2026-10-03 09:00:00+00',
        '[)'
      )
    );

    raise notice
      'FAIL 11: سُمح بحجز مضخة من بئر آخر';

  exception when others then

    if position(
      'غير موجود أو غير فعال في هذا البئر'
      in sqlerrm
    ) > 0 then
      raise notice
        'PASS 11: رُفض حجز مضخة لا تخص البئر';
    else
      raise notice
        'FAIL 11: سبب رفض مضخة البئر الآخر غير متوقع: %',
        sqlerrm;
    end if;

  end;


  -- -----------------------------------------------------------
  -- PASS 12
  -- Q79 remains intact.
  -- -----------------------------------------------------------

  if (
    select count(*)
    from information_schema.table_privileges
    where grantee in ('anon', 'authenticated')
      and table_schema in (
        'core',
        'iam',
        'ops',
        'billing',
        'finance',
        'inventory',
        'audit',
        'sync',
        'reporting'
      )
      and privilege_type in (
        'INSERT',
        'UPDATE',
        'DELETE',
        'TRUNCATE',
        'REFERENCES',
        'TRIGGER'
      )
  ) = 0 then
    raise notice
      'PASS 12: Direct DML بقي صفرًا بعد ق-81';
  else
    raise notice
      'FAIL 12: ق-81 أعادت Direct DML بصورة غير مقصودة';
  end if;


  raise notice
    '--- انتهى اختبار ق-81 / 076 (12 فحصًا) ---';

end
$$;

rollback;

begin;

set local timezone to 'UTC';

do $$
declare
  v_tenant uuid;
  v_well uuid;
  v_no_price_well uuid;
  v_foreign_tenant uuid;
  v_foreign_well uuid;
  v_created_well uuid;
  v_user uuid;
  v_profile uuid;
  v_other_user uuid;
  v_other_profile uuid;
  v_pump uuid;
  v_open_pump uuid;
  v_no_price_pump uuid;
  v_farm uuid;
  v_open_farm uuid;
  v_no_price_farm uuid;
  v_session uuid;
  v_open_session uuid;
  v_no_price_session uuid;
  v_old_price uuid;
  v_person uuid;
  v_partner uuid;
  v_count bigint;
  v_price bigint;
  v_amount bigint;
  v_start_sessions bigint;
  v_start_open bigint;
  v_start_solar bigint;
  v_start_charges numeric;
  v_end_sessions bigint;
  v_end_open bigint;
  v_end_solar bigint;
  v_end_charges numeric;
begin
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'owner064@test.local', crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_user;

  select id into v_profile from iam.profiles where id = v_user;
  if not found then
    insert into iam.profiles (id, full_name)
    values (v_user, 'مالك اختبار 064')
    returning id into v_profile;
  end if;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'other064@test.local', crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_other_user;

  select id into v_other_profile from iam.profiles where id = v_other_user;
  if not found then
    insert into iam.profiles (id, full_name)
    values (v_other_user, 'مالك آخر 064')
    returning id into v_other_profile;
  end if;

  insert into core.tenants (name)
  values ('جهة اختبار إصلاحات 064')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر لقطة السعر والتقرير')
  returning id into v_well;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة جلسة مقفلة', 'solar')
  returning id into v_pump;

  insert into ops.farms (well_id, name)
  values (v_well, 'مزرعة جلسة مقفلة')
  returning id into v_farm;

  insert into billing.well_pricing
    (well_id, price_per_hour_minor, period_start)
  values
    (v_well, 5000, date '2026-01-01')
  returning id into v_old_price;

  insert into ops.irrigation_sessions
    (well_id, pump_id, farm_id, operator_profile_id, started_at)
  values
    (v_well, v_pump, v_farm, v_profile, timestamptz '2026-01-01 23:00:00+00')
  returning id into v_session;

  select price_per_hour_minor_snapshot
    into v_price
  from ops.irrigation_sessions
  where id = v_session;

  if v_price = 5000 then
    raise notice 'PASS 1: ثُبت سعر 5000 في الجلسة لحظة البدء';
  else
    raise notice 'FAIL 1: لقطة السعر = % والمتوقع 5000', v_price;
  end if;

  update billing.well_pricing
  set period_end = date '2026-01-02'
  where id = v_old_price;

  insert into billing.well_pricing
    (well_id, price_per_hour_minor, period_start)
  values
    (v_well, 10000, date '2026-01-02');

  update ops.irrigation_sessions
  set ended_at = timestamptz '2026-01-02 00:00:00+00',
      status = 'closed'
  where id = v_session;

  select price_per_hour_minor, amount_minor
    into v_price, v_amount
  from billing.session_charges
  where session_id = v_session;

  if v_price = 5000 and v_amount = 5000 then
    raise notice 'PASS 2: تغيير السعر إلى 10000 لم يغيّر تكلفة الجلسة المثبتة على 5000';
  else
    raise notice 'FAIL 2: سعر التكلفة = % والمبلغ = % والمتوقع 5000 و5000', v_price, v_amount;
  end if;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر بلا سعر')
  returning id into v_no_price_well;

  insert into core.pumps (well_id, name, power_source)
  values (v_no_price_well, 'مضخة بلا سعر', 'diesel')
  returning id into v_no_price_pump;

  insert into ops.farms (well_id, name)
  values (v_no_price_well, 'مزرعة بلا سعر')
  returning id into v_no_price_farm;

  insert into ops.irrigation_sessions
    (well_id, pump_id, farm_id, operator_profile_id, started_at)
  values
    (v_no_price_well, v_no_price_pump, v_no_price_farm, v_profile,
     timestamptz '2026-02-01 10:00:00+00')
  returning id into v_no_price_session;

  begin
    update ops.irrigation_sessions
    set ended_at = timestamptz '2026-02-01 11:00:00+00',
        status = 'closed'
    where id = v_no_price_session;

    raise notice 'FAIL 3: أُقفلت جلسة بلا سعر مثبت';
  exception
    when others then
      if sqlerrm = 'لا يوجد سعر مثبت لهذه الجلسة — يجب ضبط سعر البئر قبل بدء الجلسة' then
        raise notice 'PASS 3: رُفض إقفال جلسة بلا سعر مثبت بالرسالة العربية المعتمدة';
      else
        raise notice 'FAIL 3: رسالة الرفض غير المتوقعة: %', sqlerrm;
      end if;
  end;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'شريك اختبار النسب', 'شريك اختبار النسب')
  returning id into v_person;

  insert into core.well_partners (tenant_id, well_id, person_id, phone)
  values (v_tenant, v_well, v_person, '777064065')
  returning id into v_partner;

  begin
    insert into core.ownership_share_versions
      (tenant_id, well_id, partner_id, ownership_percentage, profit_percentage, effective_period)
    values
      (v_tenant, v_well, v_partner, 90, 100, daterange(current_date, null, '[)'));

    execute 'set constraints all immediate';
    raise notice 'FAIL 4: قُبل مجموع ملكية 90 بالمئة مع أرباح 100 بالمئة';
  exception
    when others then
      if position('مجموع نسب ملكية' in sqlerrm) > 0 then
        raise notice 'PASS 4: رُفض مجموع ملكية 90 بالمئة مع أرباح 100 بالمئة';
      else
        raise notice 'FAIL 4: سبب رفض غير متوقع: %', sqlerrm;
      end if;
  end;

  execute 'set constraints all deferred';

  insert into core.ownership_share_versions
    (tenant_id, well_id, partner_id, ownership_percentage, profit_percentage, effective_period)
  values
    (v_tenant, v_well, v_partner, 100, 100, daterange(current_date, null, '[)'));

  execute 'set constraints all immediate';

  if exists (
    select 1
    from core.ownership_share_versions
    where well_id = v_well
      and partner_id = v_partner
      and ownership_percentage = 100
      and profit_percentage = 100
  ) then
    raise notice 'PASS 5: قُبل مجموعا الملكية والأرباح 100 بالمئة';
  else
    raise notice 'FAIL 5: لم تُحفظ نسب 100 بالمئة الصحيحة';
  end if;

  execute 'set constraints all deferred';

  insert into core.tenants (name)
  values ('جهة لا يملكها المستخدم المختبر')
  returning id into v_foreign_tenant;

  insert into core.wells (tenant_id, name)
  values (v_foreign_tenant, 'بئر المالك الآخر')
  returning id into v_foreign_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_foreign_well, v_other_profile, 'owner', 'active');

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  begin
    insert into core.wells (tenant_id, name)
    values (v_foreign_tenant, 'بئر إدخال غير مصرح');

    raise notice 'FAIL 6: سُمح للمستخدم بإنشاء بئر في جهة لا يملكها';
  exception
    when insufficient_privilege then
      raise notice 'PASS 6: رفضت RLS إنشاء بئر في جهة لا يملكها المستخدم';
    when others then
      raise notice 'FAIL 6: فشل الإدخال لسبب غير متوقع: %', sqlerrm;
  end;

  execute 'reset role';
  execute 'set local role authenticated';

  begin
    select core.create_tenant_with_well('جهة أنشأتها الدالة', 'بئر أنشأته الدالة')
      into v_created_well;
  exception
    when others then
      raise notice 'FAIL 7: فشلت دالة تهيئة الجهة والبئر: %', sqlerrm;
  end;

  execute 'reset role';

  if v_created_well is not null
     and exists (
       select 1
       from core.wells w
       join core.tenants t on t.id = w.tenant_id
       join core.well_assignments wa on wa.well_id = w.id
       where w.id = v_created_well
         and t.name = 'جهة أنشأتها الدالة'
         and w.name = 'بئر أنشأته الدالة'
         and wa.profile_id = v_user
         and wa.role = 'owner'
         and wa.status = 'active'
     ) then
    raise notice 'PASS 7: أنشأت الدالة جهة وبئرًا وتعيين مالك نشط للمستخدم الموثق';
  elsif v_created_well is not null then
    raise notice 'FAIL 7: أنشأت الدالة بيانات ناقصة أو تعيينًا غير صحيح';
  end if;

  insert into core.partner_irrigation_policies
    (tenant_id, well_id, partner_id, policy_type, period_start, period_end)
  values
    (v_tenant, v_well, v_partner, 'normal_customer', date '2026-03-01', date '2026-04-01');

  begin
    insert into core.partner_irrigation_policies
      (tenant_id, well_id, partner_id, policy_type, period_start, period_end)
    values
      (v_tenant, v_well, v_partner, 'deduct_from_profit', date '2026-03-15', date '2026-04-15');

    raise notice 'FAIL 8: قُبلت سياستان تاريخيتان متداخلتان للشريك نفسه';
  exception
    when exclusion_violation then
      raise notice 'PASS 8: رُفض تداخل سياستين تاريخيتين للشريك نفسه';
    when others then
      raise notice 'FAIL 8: رُفض التداخل لسبب غير متوقع: %', sqlerrm;
  end;

  begin
    insert into core.partner_irrigation_policies
      (tenant_id, well_id, partner_id, policy_type, period_start, period_end)
    values
      (v_tenant, v_well, v_partner, 'deduct_from_profit', date '2026-04-01', date '2026-05-01');

    raise notice 'PASS 9: قُبلت سياستان متجاورتان بلا تداخل';
  exception
    when others then
      raise notice 'FAIL 9: رُفضت السياستان المتجاورتان: %', sqlerrm;
  end;

  select count(*)
    into v_count
  from information_schema.columns
  where table_schema = 'billing'
    and table_name = 'invoices'
    and column_name = 'rounding_minor';

  if v_count = 0 then
    raise notice 'PASS 10: عمود rounding_minor غير موجود';
  else
    raise notice 'FAIL 10: عمود rounding_minor ما زال موجودًا';
  end if;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة جلسة مفتوحة', 'solar')
  returning id into v_open_pump;

  insert into ops.farms (well_id, name)
  values (v_well, 'مزرعة جلسة مفتوحة')
  returning id into v_open_farm;

  insert into ops.irrigation_sessions
    (well_id, pump_id, farm_id, operator_profile_id, started_at)
  values
    (v_well, v_open_pump, v_open_farm, v_profile, timestamptz '2026-01-01 12:00:00+00')
  returning id into v_open_session;

  select sessions_count, open_sessions, solar_seconds, charges_minor
    into v_start_sessions, v_start_open, v_start_solar, v_start_charges
  from reporting.well_daily_summary
  where well_id = v_well and day = date '2026-01-01';

  select sessions_count, open_sessions, solar_seconds, charges_minor
    into v_end_sessions, v_end_open, v_end_solar, v_end_charges
  from reporting.well_daily_summary
  where well_id = v_well and day = date '2026-01-02';

  if v_start_sessions = 0
     and v_start_charges = 0
     and v_end_sessions = 1
     and v_end_solar = 3600
     and v_end_charges = 5000 then
    raise notice 'PASS 11: نُسبت الجلسة العابرة لمنتصف الليل إلى يوم النهاية فقط';
  else
    raise notice 'FAIL 11: يوم البداية جلسات/مبلغ=%/% ويوم النهاية جلسات/ثوان/مبلغ=%/%/%',
      v_start_sessions, v_start_charges, v_end_sessions, v_end_solar, v_end_charges;
  end if;

  if v_start_open = 1
     and v_start_sessions = 0
     and v_start_solar = 0
     and v_start_charges = 0
     and v_end_open = 0 then
    raise notice 'PASS 12: الجلسة المفتوحة ظهرت معلوماتيًا ولم تدخل في أي مجموع';
  else
    raise notice 'FAIL 12: المفتوحة يوم البداية=% والجلسات/الثوان/المبلغ=%/%/% والمفتوحة يوم النهاية=%',
      v_start_open, v_start_sessions, v_start_solar, v_start_charges, v_end_open;
  end if;

  raise notice '--- انتهى اختبار إصلاحات 064 و065 (12 فحصا) ---';
end $$;

rollback;

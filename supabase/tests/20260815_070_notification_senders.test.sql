begin;

set local timezone to 'UTC';

do $$
declare
  v_tenant uuid;
  v_well uuid;
  v_quiet_well uuid;
  v_owner_user uuid;
  v_owner_profile uuid;
  v_manager_user uuid;
  v_manager_profile uuid;
  v_person_daily uuid;
  v_person_over uuid;
  v_person_under uuid;
  v_farmer_daily uuid;
  v_farmer_over uuid;
  v_farmer_under uuid;
  v_account_daily uuid;
  v_account_over uuid;
  v_account_under uuid;
  v_farm uuid;
  v_pump uuid;
  v_session uuid;
  v_invoice_over uuid;
  v_payment_allocation uuid;
  v_summary jsonb;
  v_message text;
  v_count bigint;
  v_day date := date '2026-08-14';
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'owner070@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  ) returning id into v_owner_user;

  select id into v_owner_profile from iam.profiles where id = v_owner_user;
  if not found then
    insert into iam.profiles (id, full_name)
    values (v_owner_user, 'مالك اختبار التنبيهات 070')
    returning id into v_owner_profile;
  end if;

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at
  ) values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'manager070@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  ) returning id into v_manager_user;

  select id into v_manager_profile from iam.profiles where id = v_manager_user;
  if not found then
    insert into iam.profiles (id, full_name)
    values (v_manager_user, 'مدير اختبار التنبيهات 070')
    returning id into v_manager_profile;
  end if;

  insert into core.tenants (name)
  values ('جهة اختبار التنبيهات 070') returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر النشاط اليومي 070') returning id into v_well;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر بلا نشاط 070') returning id into v_quiet_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well, v_owner_profile, 'owner', 'active'),
    (v_well, v_manager_profile, 'manager', 'active'),
    (v_quiet_well, v_owner_profile, 'owner', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع الملخص اليومي', 'مزارع الملخص اليومي')
  returning id into v_person_daily;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'أحمد صاحب الدين', 'أحمد صاحب الدين')
  returning id into v_person_over;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'سالم تحت الحد', 'سالم تحت الحد')
  returning id into v_person_under;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person_daily) returning id into v_farmer_daily;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person_over) returning id into v_farmer_over;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person_under) returning id into v_farmer_under;

  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code, credit_limit_minor
  ) values (
    v_tenant, v_farmer_daily, v_well, 'FWA-070-DAILY', null
  ) returning id into v_account_daily;

  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code, credit_limit_minor
  ) values (
    v_tenant, v_farmer_over, v_well, 'FWA-070-OVER', 500
  ) returning id into v_account_over;

  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code, credit_limit_minor
  ) values (
    v_tenant, v_farmer_under, v_well, 'FWA-070-UNDER', 500
  ) returning id into v_account_under;

  insert into ops.farms (well_id, name)
  values (v_well, 'مزرعة الملخص اليومي') returning id into v_farm;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة الملخص اليومي', 'solar') returning id into v_pump;

  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well, 5000, date '2026-01-01');

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at
  ) values (
    v_well, v_pump, v_farm, v_account_daily,
    v_owner_profile, timestamptz '2026-08-14 08:00:00+00'
  ) returning id into v_session;

  update ops.irrigation_sessions
  set ended_at = timestamptz '2026-08-14 10:00:00+00', status = 'closed'
  where id = v_session;

  insert into billing.payments (
    farmer_well_account_id, amount_minor, method, purpose, status, paid_at
  ) values (
    v_account_daily, 3000, 'cash', 'advance', 'posted',
    timestamptz '2026-08-14 11:00:00+00'
  );

  insert into finance.expenses (
    tenant_id, well_id, amount_minor, description, spent_at,
    payment_source, attachment_skipped, attachment_skip_reason, status
  ) values (
    v_tenant, v_well, 1000, 'مصروف يومي للاختبار',
    timestamptz '2026-08-14 12:00:00+00', 'other', true,
    'تجهيز اختبار الملخص اليومي', 'posted'
  );

  -- دين 1000 ورصيد مقدم 200: الذمة المقارنة بالحد تساوي 800.
  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    invoice_date, status, subtotal_minor, total_minor,
    paid_minor, outstanding_minor, issued_at, issued_by
  ) values (
    v_tenant, 'INV-070-OVER-1', v_well, v_account_over,
    now(), 'issued', 1000, 1000, 0, 1000, now(), v_owner_profile
  ) returning id into v_invoice_over;

  insert into billing.payments (
    farmer_well_account_id, amount_minor, method, purpose, status, paid_at
  ) values (
    v_account_over, 200, 'cash', 'advance', 'posted', now()
  );

  -- هذا الحساب دينه 400 وحده 500، لذلك يجب ألا يولد تنبيهًا.
  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    invoice_date, status, subtotal_minor, total_minor,
    paid_minor, outstanding_minor, issued_at, issued_by
  ) values (
    v_tenant, 'INV-070-UNDER-1', v_well, v_account_under,
    now(), 'issued', 400, 400, 0, 400, now(), v_owner_profile
  );

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  v_summary := ops.send_daily_summaries(v_day);
  select message into v_message
  from ops.notifications
  where recipient_profile_id = v_owner_profile
    and well_id = v_well
    and type = 'daily_summary';

  if (v_summary ->> 'wells_processed')::integer = 1
     and (v_summary ->> 'notifications_created')::integer = 2
     and v_message = 'ملخص يوم 2026-08-14: 1 جلسة، المدة 2 ساعة و0 دقيقة و0 ثانية، المحصل 3000، المصروف 1000' then
    raise notice 'PASS 1: أُنشئ ملخص اليوم من أرقام العرض الرسمي بالقيم الصحيحة للمالك والمدير';
  else
    raise notice 'FAIL 1: ملخص اليوم أو أرقامه غير صحيحة: % / %', v_summary, v_message;
  end if;

  v_summary := ops.send_daily_summaries(v_day);
  if (v_summary ->> 'notifications_created')::integer = 0
     and (select count(*) from ops.notifications
          where recipient_profile_id = v_owner_profile
            and well_id = v_well and type = 'daily_summary') = 1 then
    raise notice 'PASS 2: إعادة إرسال ملخص اليوم نفسه لم تكرر التنبيه';
  else
    raise notice 'FAIL 2: تكرر تنبيه الملخص اليومي: %', v_summary;
  end if;

  if not exists (
    select 1 from ops.notifications
    where recipient_profile_id = v_owner_profile
      and well_id = v_quiet_well and type = 'daily_summary'
  ) then
    raise notice 'PASS 3: البئر الذي بلا نشاط لم يولد ملخصًا يوميًا';
  else
    raise notice 'FAIL 3: أُنشئ تنبيه لبئر بلا نشاط';
  end if;

  v_summary := ops.check_debt_thresholds();
  select message into v_message
  from ops.notifications
  where recipient_profile_id = v_owner_profile
    and well_id = v_well
    and type = 'debt_threshold_exceeded'
    and message like 'المزارع أحمد صاحب الدين%';

  if (v_summary ->> 'accounts_checked')::integer = 2
     and (v_summary ->> 'accounts_over_limit')::integer = 1
     and (v_summary ->> 'notifications_created')::integer = 2
     and v_message = 'المزارع أحمد صاحب الدين تجاوز حد الدين: ذمته 800 والحد 500' then
    raise notice 'PASS 4: تجاوز الدين أنشأ تنبيهًا صحيحًا للمالك والمدير';
  else
    raise notice 'FAIL 4: نتيجة تنبيه تجاوز الدين غير صحيحة: % / %', v_summary, v_message;
  end if;

  if not exists (
    select 1 from ops.notifications
    where recipient_profile_id = v_owner_profile
      and type = 'debt_threshold_exceeded'
      and message like 'المزارع سالم تحت الحد%'
  ) then
    raise notice 'PASS 5: الحساب الواقع تحت حد الدين لم يولد تنبيهًا';
  else
    raise notice 'FAIL 5: أُنشئ تنبيه لحساب لم يتجاوز الحد';
  end if;

  v_summary := ops.check_debt_thresholds();
  if (v_summary ->> 'notifications_created')::integer = 0
     and (select count(*) from ops.notifications
          where recipient_profile_id = v_owner_profile
            and type = 'debt_threshold_exceeded'
            and message like 'المزارع أحمد صاحب الدين%') = 1 then
    raise notice 'PASS 6: تكرار الفحص في اليوم نفسه لم يكرر تنبيه الدين';
  else
    raise notice 'FAIL 6: تكرر تنبيه الدين في اليوم نفسه: %', v_summary;
  end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);

  -- استخدام دفعة عادية يخفض الذمة إلى 300 بعد خصم الرصيد المقدم.
  insert into billing.payments (
    farmer_well_account_id, amount_minor, method, purpose, status, paid_at
  ) values (
    v_account_over, 500, 'cash', 'old_debt', 'posted', now()
  ) returning id into v_payment_allocation;

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';

  perform billing.allocate_payment(
    v_payment_allocation,
    jsonb_build_array(jsonb_build_object(
      'invoice_id', v_invoice_over,
      'amount_minor', 500
    ))
  );

  v_summary := ops.check_debt_thresholds();
  if (v_summary ->> 'accounts_over_limit')::integer = 0
     and (v_summary ->> 'notifications_created')::integer = 0 then
    raise notice 'PASS 7: نزول الذمة تحت الحد أوقف تنبيه الدين';
  else
    raise notice 'FAIL 7: الحساب بقي متجاوزًا بعد خفض ذمته: %', v_summary;
  end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);

  -- محاكاة انتقال التاريخ داخل معاملة الاختبار: ننقل إشعاري التجاوز السابقين إلى أمس.
  update ops.notifications
  set created_at = created_at - interval '1 day',
      deduplication_key = format('debt:%s:%s', v_account_over, current_date - 1)
  where type = 'debt_threshold_exceeded'
    and deduplication_key = format('debt:%s:%s', v_account_over, current_date);

  insert into billing.invoices (
    tenant_id, public_code, well_id, farmer_well_account_id,
    invoice_date, status, subtotal_minor, total_minor,
    paid_minor, outstanding_minor, issued_at, issued_by
  ) values (
    v_tenant, 'INV-070-OVER-2', v_well, v_account_over,
    now(), 'issued', 600, 600, 0, 600, now(), v_owner_profile
  );

  perform set_config('request.jwt.claim.sub', v_owner_user::text, true);
  execute 'set local role authenticated';
  v_summary := ops.check_debt_thresholds();

  if (v_summary ->> 'accounts_over_limit')::integer = 1
     and (v_summary ->> 'notifications_created')::integer = 2 then
    raise notice 'PASS 8: بعد يوم جديد وانخفاض الذمة ثم تجاوزها عاد التنبيه من جديد';
  else
    raise notice 'FAIL 8: لم يعد تنبيه الدين بعد التجاوز في يوم لاحق: %', v_summary;
  end if;

  select count(*) into v_count
  from ops.notifications
  where recipient_profile_id = v_owner_profile
    and type = 'debt_threshold_exceeded'
    and message = 'المزارع أحمد صاحب الدين تجاوز حد الدين: ذمته 900 والحد 500';

  if v_count = 1 then
    raise notice 'PASS 9: حساب الذمة خصم الرصيد المقدم فكانت الذمة 900 لا 1100';
  else
    raise notice 'FAIL 9: لم يُخصم الرصيد المقدم من الذمة عند إعادة التجاوز';
  end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
end;
$$;

rollback;

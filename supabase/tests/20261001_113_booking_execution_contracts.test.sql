-- =====================================================================
-- اختبار Migration 113 الدائم — M113-A/B/C: الجاهزية وبدء الجلسة
-- علاقة booking→session، المصدر البديل، مضخة فعالة واحدة،
-- نافذة الشمس المركزية، وevaluator الجاهزية typed.
-- لا اختبارات معتمدة على الساعة الحالية: تواريخ ثابتة حصرًا.
-- =====================================================================

begin;

set local timezone to 'UTC';

-- =====================================================================
-- M113-E2-e-b2: قاعدة المدة المشروطة للجلسة الحرّة (زناد قيد مؤجَّل).
--   كتلة أولى عمدًا: set constraints immediate هنا يفحص جلسات هذه الكتلة
--   وحدها (لا تراكم سابق). الكتل اللاحقة تتراكم مؤجَّلةً وتُطوى بـ rollback
--   النهائي دون فحص. التوقيت صريح p_started_at=v_now لثبات planned_end.
-- =====================================================================
do $test_ee$
declare
  v_tenant uuid;
  v_person uuid;
  v_profile uuid;
  v_op uuid;
  v_outsider uuid;
  v_wf uuid;   -- حرّ بلا حجز
  v_wbk uuid;  -- بدء محجوز
  v_wcf uuid;  -- حجز مؤكّد قادم (رفض/قبول)
  v_wcf2 uuid; -- حجز مؤكّد قادم (الحد)
  v_wun uuid;  -- حجز غير مؤكّد
  v_wrp uuid;  -- replay
  v_wlg uuid;  -- العقد القديم بلا مدة
  v_wold uuid; -- العقد القديم بلا حجز قادم (E2-e-b2-S1)
  v_bbk2 uuid; -- حجز ثانٍ على بئر جلسة مفتوحة (E2-e-b2-S1)
  v_acc uuid;
  v_farm uuid;
  v_pump uuid;
  v_bbk uuid;
  v_sid uuid;
  v_sid2 uuid;
  v_cmd uuid;
  v_now timestamptz := date_trunc('minute', clock_timestamp());
  v_cons text := 'ops.irrigation_sessions_adhoc_duration_guard';
begin
  insert into core.tenants (name) values ('جهة M113-E2-e-b2') returning id into v_tenant;
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع EE', 'مزارع EE') returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_profile;
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 'op-ee@test.local', crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_op;
  insert into iam.profiles (id, full_name) values (v_op, 'مشغل EE') on conflict (id) do nothing;
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 'out-ee@test.local', crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_outsider;
  insert into iam.profiles (id, full_name) values (v_outsider, 'غريب EE') on conflict (id) do nothing;

  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر EE-F') returning id into v_wf;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر EE-BK') returning id into v_wbk;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر EE-CF') returning id into v_wcf;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر EE-CF2') returning id into v_wcf2;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر EE-UN') returning id into v_wun;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر EE-RP') returning id into v_wrp;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر EE-LG') returning id into v_wlg;
  insert into core.well_assignments (well_id, profile_id, role, status) values
    (v_wf, v_op, 'operator', 'active'), (v_wbk, v_op, 'operator', 'active'),
    (v_wcf, v_op, 'operator', 'active'), (v_wcf2, v_op, 'operator', 'active'),
    (v_wun, v_op, 'operator', 'active'), (v_wrp, v_op, 'operator', 'active'),
    (v_wlg, v_op, 'operator', 'active');
  execute 'set constraints ' || v_cons || ' deferred';
  -- بئر wf (لا حجز): EE1 بدء حرّ بلا مدة ينجح؛ EE9 لا جلسة ثانية فوق مفتوحة.
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_wf, 'FWA-EE-F') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_wf, 'أرض EE-F', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_wf, 'مضخة EE-F', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_wf, 5000, date '2026-01-01');
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_sid := api.start_adhoc_session(
    v_wf, v_pump, v_farm, v_acc, 'well_diesel', null, v_now, null, null, null
  );
  execute 'set constraints ' || v_cons || ' immediate';
  if v_sid is not null
     and exists (select 1 from ops.irrigation_sessions
                 where id = v_sid and status = 'open' and planned_end_at is null) then
    raise notice 'PASS EE1: بدء حرّ بلا مدة بلا حجز قادم نجح (الزناد المؤجَّل أُطلِق)';
  else
    raise notice 'FAIL EE1: بدء حرّ بلا مدة لم ينجح كما يجب';
  end if;
  execute 'set constraints ' || v_cons || ' deferred';

  begin
    perform api.start_adhoc_session(
      v_wf, v_pump, v_farm, v_acc, 'well_diesel', null, v_now, null, null, null
    );
    raise notice 'FAIL EE9: بُدئت جلسة ثانية فوق جلسة مفتوحة';
  exception when others then
    raise notice 'PASS EE9: منع جلسة ثانية فوق المفتوحة قائم';
  end;
  -- بئر wbk: EE2 بدء محجوز (يُدرَج booking_id=null ثم يُربَط) معفى من قاعدة
  -- الحرّة؛ الزناد المؤجَّل يقرأ الصف النهائي (لا NEW) فيراه محجوزًا.
  execute 'reset role';
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_wbk, 'FWA-EE-BK') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_wbk, 'أرض EE-BK', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_wbk, 'مضخة EE-BK', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_wbk, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (v_tenant, 'BKG-EE-BK', v_wbk, v_acc, v_farm,
    v_now - interval '10 minutes', v_now + interval '50 minutes', 60,
    'well_diesel', 'confirmed') returning id into v_bbk;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_sid := (api.start_irrigation_session_from_booking(
    v_bbk, v_now, gen_random_uuid(), null
  ) ->> 'session_id')::uuid;
  execute 'set constraints ' || v_cons || ' immediate';
  if (select booking_id from ops.irrigation_sessions where id = v_sid) = v_bbk then
    raise notice 'PASS EE2: جلسة محجوزة بـ null ثم ربط نجحت والزناد قرأ الربط النهائي';
  else
    raise notice 'FAIL EE2: الجلسة المحجوزة لم تُربَط أو رُفضت';
  end if;
  execute 'set constraints ' || v_cons || ' deferred';
  -- بئر wcf: حجز مؤكّد قادم (v_now+2h). EE3 رفض بلا مدة.
  execute 'reset role';
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_wcf, 'FWA-EE-CF') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_wcf, 'أرض EE-CF', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_wcf, 'مضخة EE-CF', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_wcf, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (v_tenant, 'BKG-EE-CF', v_wcf, v_acc, v_farm,
    v_now + interval '2 hours', v_now + interval '3 hours', 60,
    'well_diesel', 'confirmed');
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  begin
    perform api.start_adhoc_session(
      v_wcf, v_pump, v_farm, v_acc, 'well_diesel', null, v_now, null, null, null
    );
    execute 'set constraints ' || v_cons || ' immediate';
    raise notice 'FAIL EE3: قُبل بدء حرّ بلا مدة مع حجز قادم';
  exception when others then
    if position('مدة مخطّطة' in sqlerrm) > 0 then
      raise notice 'PASS EE3: رُفض البدء الحرّ بلا مدة مع حجز قادم';
    else
      raise notice 'FAIL EE3: رفض غير متوقع: %', left(sqlerrm, 60);
    end if;
  end;
  execute 'set constraints ' || v_cons || ' deferred';
  -- EE6: مدة تتجاوز بداية الحجز القادم → رفض (لا تقصير صامت).
  begin
    perform api.start_adhoc_session(
      v_wcf, v_pump, v_farm, v_acc, 'well_diesel', 180, v_now, null, null, null
    );
    execute 'set constraints ' || v_cons || ' immediate';
    raise notice 'FAIL EE6: قُبلت مدة تتجاوز بداية الحجز';
  exception when others then
    if position('تتجاوز' in sqlerrm) > 0 then
      raise notice 'PASS EE6: رُفضت المدة المتجاوزة بلا تقصير صامت';
    else
      raise notice 'FAIL EE6: رفض غير متوقع: %', left(sqlerrm, 60);
    end if;
  end;
  execute 'set constraints ' || v_cons || ' deferred';

  -- EE4: مدة تنتهي قبل بداية الحجز → قبول، وplanned_end من البداية الفعلية.
  v_sid := api.start_adhoc_session(
    v_wcf, v_pump, v_farm, v_acc, 'well_diesel', 60, v_now, null, null, null
  );
  execute 'set constraints ' || v_cons || ' immediate';
  if exists (select 1 from ops.irrigation_sessions
             where id = v_sid and planned_end_at = v_now + interval '60 minutes'
               and planned_duration_minutes = 60) then
    raise notice 'PASS EE4: مدة تنتهي قبل الحجز قُبلت وplanned_end مشتق صحيح';
  else
    raise notice 'FAIL EE4: مدة ضمن النافذة لم تُقبَل أو planned_end خطأ';
  end if;
  execute 'set constraints ' || v_cons || ' deferred';
  -- بئر wcf2: EE5 النهاية المخطّطة = بداية الحجز بالضبط → قبول (الحدّ ≤).
  execute 'reset role';
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_wcf2, 'FWA-EE-CF2') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_wcf2, 'أرض EE-CF2', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_wcf2, 'مضخة EE-CF2', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_wcf2, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (v_tenant, 'BKG-EE-CF2', v_wcf2, v_acc, v_farm,
    v_now + interval '120 minutes', v_now + interval '180 minutes', 60,
    'well_diesel', 'confirmed');
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_sid := api.start_adhoc_session(
    v_wcf2, v_pump, v_farm, v_acc, 'well_diesel', 120, v_now, null, null, null
  );
  execute 'set constraints ' || v_cons || ' immediate';
  if exists (select 1 from ops.irrigation_sessions
             where id = v_sid and planned_end_at = v_now + interval '120 minutes') then
    raise notice 'PASS EE5: نهاية مخطّطة = بداية الحجز بالضبط قُبلت';
  else
    raise notice 'FAIL EE5: الحدّ المساوي لم يُقبَل';
  end if;
  execute 'set constraints ' || v_cons || ' deferred';
  -- بئر wun: حجز قادم غير مؤكّد (draft). EE8 بدء حرّ بلا مدة → قبول (غير
  -- المؤكّد لا يُعامل مانعًا).
  execute 'reset role';
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_wun, 'FWA-EE-UN') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_wun, 'أرض EE-UN', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_wun, 'مضخة EE-UN', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_wun, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (v_tenant, 'BKG-EE-UN', v_wun, v_acc, v_farm,
    v_now + interval '2 hours', v_now + interval '3 hours', 60,
    'well_diesel', 'draft');
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_sid := api.start_adhoc_session(
    v_wun, v_pump, v_farm, v_acc, 'well_diesel', null, v_now, null, null, null
  );
  execute 'set constraints ' || v_cons || ' immediate';
  if exists (select 1 from ops.irrigation_sessions where id = v_sid and status = 'open') then
    raise notice 'PASS EE8: حجز غير مؤكّد لا يُعامل مانعًا (بدء حرّ بلا مدة قُبل)';
  else
    raise notice 'FAIL EE8: غير المؤكّد عومل مانعًا';
  end if;
  execute 'set constraints ' || v_cons || ' deferred';
  -- EE12: العقد القديم (api.start_irrigation_session، بلا مدة) مع حجز مؤكّد
  -- قادم يُرفَض عبر الزناد المؤجَّل الشامل — إثبات أنّ المسار القديم لا يتجاوز.
  execute 'reset role';
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_wlg, 'FWA-EE-LG') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_wlg, 'أرض EE-LG', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_wlg, 'مضخة EE-LG', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_wlg, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (v_tenant, 'BKG-EE-LG', v_wlg, v_acc, v_farm,
    v_now + interval '2 hours', v_now + interval '3 hours', 60,
    'well_diesel', 'confirmed');
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  begin
    perform api.start_irrigation_session(
      v_wlg, v_pump, v_farm, v_acc, 'well_diesel', v_now, null, gen_random_uuid(), null
    );
    execute 'set constraints ' || v_cons || ' immediate';
    raise notice 'FAIL EE12: العقد القديم تجاوز القاعدة الجديدة';
  exception when others then
    if position('مدة مخطّطة' in sqlerrm) > 0 then
      raise notice 'PASS EE12: العقد القديم بلا مدة مع حجز قادم رُفض (الزناد شامل)';
    else
      raise notice 'FAIL EE12: رفض غير متوقع: %', left(sqlerrm, 60);
    end if;
  end;
  execute 'set constraints ' || v_cons || ' deferred';

  -- EE10: غير مخوّل لا يبدأ جلسة حرّة (الرفض عند فحص الصلاحية).
  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  begin
    perform api.start_adhoc_session(
      v_wf, v_pump, v_farm, v_acc, 'well_diesel', null, v_now, null, null, null
    );
    raise notice 'FAIL EE10: غير مخوّل بدأ جلسة';
  exception when others then
    raise notice 'PASS EE10: غير المخوّل مرفوض عن البدء الحرّ';
  end;
  perform set_config('request.jwt.claim.sub', v_op::text, true);

  -- EE11: replay بنفس command_id يعيد الجلسة ذاتها بلا تكرار (ق-114).
  execute 'reset role';
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_wrp, 'FWA-EE-RP') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_wrp, 'أرض EE-RP', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_wrp, 'مضخة EE-RP', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_wrp, 5000, date '2026-01-01');
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_cmd := gen_random_uuid();
  v_sid := api.start_adhoc_session(
    v_wrp, v_pump, v_farm, v_acc, 'well_diesel', null, v_now, null, v_cmd, null
  );
  v_sid2 := api.start_adhoc_session(
    v_wrp, v_pump, v_farm, v_acc, 'well_diesel', null, v_now, null, v_cmd, null
  );
  execute 'set constraints ' || v_cons || ' immediate';
  if v_sid = v_sid2
     and (select count(*) from ops.irrigation_sessions where well_id = v_wrp) = 1 then
    raise notice 'PASS EE11/EE7: replay بلا تكرار، وبئر wrp بلا حجز نجح رغم حجوزات آبار أخرى مؤكّدة';
  else
    raise notice 'FAIL EE11: replay كرّر الجلسة أو اختلف';
  end if;
  execute 'set constraints ' || v_cons || ' deferred';

  -- EE11b: تغيير مالك الوقود مع command_id ثابت ليس replay مطابقًا؛
  -- يجب رفض الحمولة المختلفة وعدم إنشاء جلسة ثانية.
  begin
    perform api.start_adhoc_session(
      v_wrp, v_pump, v_farm, v_acc, 'well_diesel', null,
      v_now, v_person, v_cmd, null
    );
    raise notice 'FAIL EE11b: قُبل replay بمالك وقود مختلف';
  exception when others then
    if position('معرّف العملية مستخدم لمحتوى مختلف' in sqlerrm) > 0 then
      raise notice 'PASS EE11b: رُفض replay المختلف في مالك الوقود';
    else
      raise notice 'FAIL EE11b: رفض غير متوقع: %', left(sqlerrm, 80);
    end if;
  end;
  if (select count(*) from ops.irrigation_sessions where well_id = v_wrp) = 1 then
    raise notice 'PASS EE11c: رفض replay لم يُنشئ جلسة إضافية';
  else
    raise notice 'FAIL EE11c: عدد الجلسات تغيّر بعد رفض replay';
  end if;

  -- E2-e-b2-S1) EE13: العقد القديم (api.start_irrigation_session) على بئر
  -- بلا حجز مؤكّد قادم ينجح والزناد المؤجَّل يُطلَق على إدراجه فعلًا —
  -- إثبات توافق المسار القديم لا صمته. ثم EE14: يُكمل عبر عقد الإكمال
  -- وتُنشأ الرسوم — إثبات عدم تأثر الإكمال والفوترة بالزناد المؤجَّل.
  execute 'reset role';
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر EE-OLD')
    returning id into v_wold;
  insert into core.well_assignments (well_id, profile_id, role, status)
    values (v_wold, v_op, 'operator', 'active');
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
    values (v_tenant, v_profile, v_wold, 'FWA-EE-OLD') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
    values (v_wold, 'أرض EE-OLD', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
    values (v_wold, 'مضخة EE-OLD', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
    values (v_wold, 5000, date '2026-01-01');
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_sid := api.start_irrigation_session(
    v_wold, v_pump, v_farm, v_acc, 'well_diesel',
    v_now - interval '10 minutes', null, gen_random_uuid(), null
  );
  execute 'set constraints ' || v_cons || ' immediate';
  if exists (select 1 from ops.irrigation_sessions
             where id = v_sid and booking_id is null
               and status = 'open' and planned_end_at is null) then
    raise notice 'PASS EE13: العقد القديم بلا حجز قادم نجح والزناد المؤجَّل أُطلِق عليه';
  else
    raise notice 'FAIL EE13: العقد القديم بلا حجز قادم لم ينجح';
  end if;
  execute 'set constraints ' || v_cons || ' deferred';
  perform api.complete_irrigation_session(
    v_sid, v_now - interval '5 minutes', null, null, null, gen_random_uuid()
  );
  if exists (select 1 from ops.irrigation_sessions
             where id = v_sid and status = 'closed')
     and exists (select 1 from billing.session_charges
                 where session_id = v_sid) then
    raise notice 'PASS EE14: إكمال الجلسة الحرّة القديمة وفوترتها سليمان مع الزناد المؤجَّل';
  else
    raise notice 'FAIL EE14: الإكمال أو الفوترة تأثّرت بالزناد المؤجَّل';
  end if;
  -- EE15: المسار المحجوز لا يفتح جلسة ثانية فوق مفتوحة: الرفض قبل الإدراج
  -- فلا يصل الزناد أصلًا، وبئر wbk تبقى بجلسة مفتوحة واحدة (جلسة EE2).
  execute 'reset role';
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (
    v_tenant, 'BKG-EE-BK2', v_wbk,
    (select id from ops.farmer_well_accounts where well_id = v_wbk limit 1),
    (select id from ops.farms where well_id = v_wbk limit 1),
    v_now + interval '3 hours', v_now + interval '4 hours', 60,
    'well_diesel', 'confirmed') returning id into v_bbk2;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  begin
    perform api.start_irrigation_session_from_booking(
      v_bbk2, v_now, gen_random_uuid(), null
    );
    raise notice 'FAIL EE15: بُدئت جلسة محجوزة فوق جلسة مفتوحة';
  exception when others then
    if position('جلسة مفتوحة' in sqlerrm) > 0 then
      raise notice 'PASS EE15: لا جلسة محجوزة ثانية فوق المفتوحة (رفض قبل الإدراج)';
    else
      raise notice 'FAIL EE15: رفض غير متوقع: %', left(sqlerrm, 60);
    end if;
  end;
  if (select count(*) from ops.irrigation_sessions
      where well_id = v_wbk and status = 'open') = 1 then
    raise notice 'PASS EE15b: بئر الحجز بجلسة مفتوحة واحدة حصرًا';
  else
    raise notice 'FAIL EE15b: عدد الجلسات المفتوحة على بئر الحجز تغيّر';
  end if;

  execute 'reset role';
  raise notice '--- انتهى M113-E2-e-b2: قاعدة المدة المشروطة (زناد مؤجَّل) ---';
end
$test_ee$;

do $test$
declare
  v_tenant uuid;
  v_well uuid;
  v_well_zero uuid;
  v_person uuid;
  v_farmer_profile uuid;
  v_account uuid;
  v_farm uuid;
  v_operator_profile uuid;
  v_pump uuid;
  v_booking_hist_null uuid;
  v_booking_hist_mixed uuid;
  v_booking_sess uuid;
  v_booking_alt_well uuid;
  v_booking_alt_farmer uuid;
  v_session uuid;
  v_result jsonb;
  v_count bigint;
  v_confdel text;
begin

  -- ============================================================
  -- تجهيزات (مباشرة بصفة فائقة على القاعدة المحلية فقط).
  -- ============================================================
  insert into core.tenants (name) values ('جهة اختبار تنفيذ الحجوزات 113')
    returning id into v_tenant;

  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر التنفيذ 113')
    returning id into v_well;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر بلا مضخة 113')
    returning id into v_well_zero;

  insert into core.persons (tenant_id, full_name, normalized_name)
    values (v_tenant, 'مزارع التنفيذ 113', 'مزارع التنفيذ 113')
    returning id into v_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
    values (v_tenant, v_person)
    returning id into v_farmer_profile;

  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
    values (v_tenant, v_farmer_profile, v_well, 'FWA-113')
    returning id into v_account;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'operator113@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_operator_profile;

  insert into iam.profiles (id, full_name)
    values (v_operator_profile, 'مشغل اختبار 113')
    on conflict (id) do nothing;

  insert into core.well_assignments (well_id, profile_id, role, status)
    values (v_well, v_operator_profile, 'operator', 'active');

  insert into ops.farms (well_id, name, farmer_well_account_id)
    values (v_well, 'أرض التنفيذ 113', v_account)
    returning id into v_farm;

  -- 7) المضخة active الواحدة مسموحة.
  insert into core.pumps (well_id, name, power_source)
    values (v_well, 'مضخة التنفيذ 113', 'solar')
    returning id into v_pump;

  -- حجوزات تاريخية سابقة لق-132: null وmixed — بقيمها ولا تعاد كتابتها.
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (
    v_tenant, 'BKG-113-N', v_well, v_account, v_farm,
    timestamptz '2026-10-05 06:00:00+00',
    timestamptz '2026-10-05 07:00:00+00', 60, null, 'confirmed'
  ) returning id into v_booking_hist_null;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (
    v_tenant, 'BKG-113-M', v_well, v_account, v_farm,
    timestamptz '2026-10-05 08:00:00+00',
    timestamptz '2026-10-05 09:00:00+00', 60, 'mixed', 'confirmed'
  ) returning id into v_booking_hist_mixed;

  -- 5) المصدر البديل: null/well_diesel/farmer_diesel فقط — تخزين مقبول.
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status, alternative_energy_source
  ) values (
    v_tenant, 'BKG-113-A1', v_well, v_account, v_farm,
    timestamptz '2026-10-06 06:00:00+00',
    timestamptz '2026-10-06 07:00:00+00', 60,
    'solar', 'draft', 'well_diesel'
  ) returning id into v_booking_alt_well;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status, alternative_energy_source
  ) values (
    v_tenant, 'BKG-113-A2', v_well, v_account, v_farm,
    timestamptz '2026-10-06 08:00:00+00',
    timestamptz '2026-10-06 09:00:00+00', 60,
    'solar', 'draft', 'farmer_diesel'
  ) returning id into v_booking_alt_farmer;

  -- ============================================================
  -- 1. booking_id موجود على sessions وFK صحيح بلا CASCADE حذف.
  -- ============================================================
  select
    (select count(*) from pg_attribute a
     join pg_class c on c.oid = a.attrelid
     join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'ops' and c.relname = 'irrigation_sessions'
       and a.attname = 'booking_id' and not a.attisdropped),
    (select confdeltype::text from pg_constraint con
     join pg_class c on c.oid = con.conrelid
     join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'ops' and c.relname = 'irrigation_sessions'
       and con.conname = 'irrigation_sessions_booking_fkey'
       and con.contype = 'f')
  into v_count, v_confdel;

  if v_count = 1 and v_confdel = 'a' then
    raise notice 'PASS 1: booking_id موجود على sessions بFK نحو الحجوزات وبلا حذف متسلسل';
  else
    raise notice 'FAIL 1: عمود booking_id أو الـFK غير صحيح: col=% deltype=%', v_count, v_confdel;
  end if;

  -- ============================================================
  -- 2. الجلسات التاريخية بلا booking مسموحة وتبقى NULL بلا backfill.
  -- ============================================================
  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status,
    price_per_hour_minor_snapshot
  ) values (
    v_well, v_pump, v_farm, v_account,
    v_operator_profile, timestamptz '2026-09-20 05:00:00+00',
    timestamptz '2026-09-20 07:00:00+00', 'closed',
    5000
  ) returning id into v_session;

  if (select booking_id from ops.irrigation_sessions where id = v_session) is null then
    raise notice 'PASS 2: جلسة تاريخية بلا booking تبقى صالحة وbooking_id = NULL';
  else
    raise notice 'FAIL 2: جلسة بلا booking لم تُخزَّن بقيمة NULL';
  end if;

  -- ============================================================
  -- 3. Session مرتبطة Booking تعمل.
  -- ============================================================
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (
    v_tenant, 'BKG-113-S', v_well, v_account, v_farm,
    timestamptz '2026-10-07 06:00:00+00',
    timestamptz '2026-10-07 07:00:00+00', 60, 'solar', 'confirmed'
  ) returning id into v_booking_sess;

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, status,
    price_per_hour_minor_snapshot, booking_id
  ) values (
    v_well, v_pump, v_farm, v_account,
    v_operator_profile, timestamptz '2026-10-07 06:10:00+00', 'open',
    5000, v_booking_sess
  ) returning id into v_session;

  if (select booking_id from ops.irrigation_sessions where id = v_session)
       = v_booking_sess then
    raise notice 'PASS 3: جلسة مرتبطة بحجز تعمل والرابط الحاكم محفوظ';
  else
    raise notice 'FAIL 3: ربط الجلسة بالحجز لم يعمل';
  end if;

  -- ============================================================
  -- 4. Session ثانية لنفس Booking تُرفض بالقيد الفريد الجزئي.
  -- ============================================================
  begin
    insert into ops.irrigation_sessions (
      well_id, pump_id, farm_id, farmer_well_account_id,
      operator_profile_id, started_at, ended_at, status,
      price_per_hour_minor_snapshot, booking_id
    ) values (
      v_well, v_pump, v_farm, v_account,
      v_operator_profile, timestamptz '2026-10-07 06:20:00+00',
      timestamptz '2026-10-07 07:20:00+00', 'closed',
      5000, v_booking_sess
    );
    raise notice 'FAIL 4: سُمح بجلسة ثانية لنفس الحجز';
  exception when others then
    if position('uq_irrigation_sessions_booking' in sqlerrm) > 0 then
      raise notice 'PASS 4: رُفضت جلسة ثانية لنفس الحجز بالقيد الفريد';
    else
      raise notice 'FAIL 4: سبب رفض الجلسة الثانية غير متوقع: %', sqlerrm;
    end if;
  end;

  -- ============================================================
  -- 6. solar/mixed كبديل تُرفض بقيود العمود.
  -- ============================================================
  begin
    insert into ops.irrigation_bookings (
      tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
      scheduled_start, scheduled_end, expected_duration_minutes,
      expected_energy_source, status, alternative_energy_source
    ) values (
      v_tenant, 'BKG-113-X1', v_well, v_account, v_farm,
      timestamptz '2026-10-08 06:00:00+00',
      timestamptz '2026-10-08 07:00:00+00', 60,
      'solar', 'draft', 'solar'
    );
    raise notice 'FAIL 6: سُمح بـsolar مصدرًا بديلًا';
  exception when others then
    if position('alternative_energy_source' in sqlerrm) > 0 then
      raise notice 'PASS 6: رُفض solar كبديل بقيود العمود';
    else
      raise notice 'FAIL 6: سبب رفض solar كبديل غير متوقع: %', sqlerrm;
    end if;
  end;

  begin
    insert into ops.irrigation_bookings (
      tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
      scheduled_start, scheduled_end, expected_duration_minutes,
      expected_energy_source, status, alternative_energy_source
    ) values (
      v_tenant, 'BKG-113-X2', v_well, v_account, v_farm,
      timestamptz '2026-10-08 08:00:00+00',
      timestamptz '2026-10-08 09:00:00+00', 60,
      'solar', 'draft', 'mixed'
    );
    raise notice 'FAIL 6: سُمح بـmixed مصدرًا بديلًا';
  exception when others then
    if position('alternative_energy_source' in sqlerrm) > 0 then
      raise notice 'PASS 6: رُفض mixed كبديل بقيود العمود';
    else
      raise notice 'FAIL 6: سبب رفض mixed كبديل غير متوقع: %', sqlerrm;
    end if;
  end;

  -- ============================================================
  -- 8. مضخة active ثانية لنفس البئر تُرفض بالقيد الفريد الجزئي.
  -- ============================================================
  begin
    insert into core.pumps (well_id, name, power_source)
      values (v_well, 'مضخة ثانية 113', 'diesel');
    raise notice 'FAIL 8: سُمح بمضخة فعالة ثانية لنفس البئر';
  exception when others then
    if position('uq_core_pumps_single_active_per_well' in sqlerrm) > 0 then
      raise notice 'PASS 8: رُفضت مضخة فعالة ثانية لنفس البئر';
    else
      raise notice 'FAIL 8: سبب رفض المضخة الثانية غير متوقع: %', sqlerrm;
    end if;
  end;

  -- ============================================================
  -- 9. صفر مضخة فعالة → readiness active_pump_missing.
  -- ============================================================
  v_result := ops.evaluate_booking_execution_readiness(
    v_well_zero,
    timestamptz '2026-10-09 06:00:00+00',
    timestamptz '2026-10-09 07:00:00+00',
    'well_diesel', null
  );

  if (v_result ->> 'ready')::boolean = false
     and v_result ->> 'reason_code' = 'active_pump_missing'
     and (v_result ->> 'active_pump_id') is null then
    raise notice 'PASS 9: صفر مضخة فعالة أعاد active_pump_missing typed';
  else
    raise notice 'FAIL 9: نتيجة صفر مضخة غير صحيحة: %', v_result;
  end if;

  -- ============================================================
  -- 10/11. diesel أساسي مع مضخة فعالة → ready (well/farmer).
  -- ============================================================
  v_result := ops.evaluate_booking_execution_readiness(
    v_well,
    timestamptz '2026-10-09 06:00:00+00',
    timestamptz '2026-10-09 07:00:00+00',
    'well_diesel', null
  );

  if (v_result ->> 'ready')::boolean = true
     and v_result ->> 'reason_code' = 'ready'
     and (v_result ->> 'active_pump_id')::uuid = v_pump
     and (v_result ->> 'requires_alternative')::boolean = false then
    raise notice 'PASS 10: well_diesel مع مضخة فعالة → ready';
  else
    raise notice 'FAIL 10: well_diesel لم يكن جاهزًا: %', v_result;
  end if;

  v_result := ops.evaluate_booking_execution_readiness(
    v_well,
    timestamptz '2026-10-09 08:00:00+00',
    timestamptz '2026-10-09 09:00:00+00',
    'farmer_diesel', null
  );

  if (v_result ->> 'ready')::boolean = true
     and v_result ->> 'reason_code' = 'ready'
     and (v_result ->> 'active_pump_id')::uuid = v_pump then
    raise notice 'PASS 11: farmer_diesel مع مضخة فعالة → ready';
  else
    raise notice 'FAIL 11: farmer_diesel لم يكن جاهزًا: %', v_result;
  end if;

  -- ============================================================
  -- 12. Solar 10:00–11:00 Aden بلا بديل → ready (داخل النافذة).
  --     2026-10-05 10:00 Aden = 07:00 UTC.
  -- ============================================================
  v_result := ops.evaluate_booking_execution_readiness(
    v_well,
    timestamptz '2026-10-05 07:00:00+00',
    timestamptz '2026-10-05 08:00:00+00',
    'solar', null
  );

  if (v_result ->> 'ready')::boolean = true
     and v_result ->> 'reason_code' = 'ready'
     and (v_result ->> 'requires_alternative')::boolean = false
     and (v_result ->> 'solar_window_start')::timestamptz
           = timestamptz '2026-10-05 03:00:00+00'
     and (v_result ->> 'solar_window_end')::timestamptz
           = timestamptz '2026-10-05 15:00:00+00' then
    raise notice 'PASS 12: solar داخل النافذة → ready بنافذة Aden صحيحة';
  else
    raise notice 'FAIL 12: solar داخل النافذة لم يكن جاهزًا: %', v_result;
  end if;

  -- ============================================================
  -- 13. Solar 17:00–19:00 بلا بديل → missing_alternative_energy_source.
  --     17:00 Aden = 14:00 UTC؛ 19:00 Aden = 16:00 UTC.
  -- ============================================================
  v_result := ops.evaluate_booking_execution_readiness(
    v_well,
    timestamptz '2026-10-05 14:00:00+00',
    timestamptz '2026-10-05 16:00:00+00',
    'solar', null
  );

  if (v_result ->> 'ready')::boolean = false
     and v_result ->> 'reason_code' = 'missing_alternative_energy_source'
     and (v_result ->> 'requires_alternative')::boolean = true then
    raise notice 'PASS 13: solar ممتد بعد النافذة بلا بديل أعاد missing_alternative_energy_source';
  else
    raise notice 'FAIL 13: نتيجة الامتداد بلا بديل غير صحيحة: %', v_result;
  end if;

  -- ============================================================
  -- 14/15. نفس الحالة + بديل صالح → ready.
  -- ============================================================
  v_result := ops.evaluate_booking_execution_readiness(
    v_well,
    timestamptz '2026-10-05 14:00:00+00',
    timestamptz '2026-10-05 16:00:00+00',
    'solar', 'well_diesel'
  );

  if (v_result ->> 'ready')::boolean = true
     and v_result ->> 'reason_code' = 'ready'
     and (v_result ->> 'requires_alternative')::boolean = true then
    raise notice 'PASS 14: solar ممتد مع well_diesel → ready';
  else
    raise notice 'FAIL 14: solar ممتد مع well_diesel لم يكن جاهزًا: %', v_result;
  end if;

  v_result := ops.evaluate_booking_execution_readiness(
    v_well,
    timestamptz '2026-10-05 14:00:00+00',
    timestamptz '2026-10-05 16:00:00+00',
    'solar', 'farmer_diesel'
  );

  if (v_result ->> 'ready')::boolean = true
     and v_result ->> 'reason_code' = 'ready'
     and (v_result ->> 'requires_alternative')::boolean = true then
    raise notice 'PASS 15: solar ممتد مع farmer_diesel → ready';
  else
    raise notice 'FAIL 15: solar ممتد مع farmer_diesel لم يكن جاهزًا: %', v_result;
  end if;

  -- ============================================================
  -- 16. Solar تنتهي 18:00 بالضبط بلا بديل → ready.
  --     18:00 Aden = 15:00 UTC.
  -- ============================================================
  v_result := ops.evaluate_booking_execution_readiness(
    v_well,
    timestamptz '2026-10-05 13:00:00+00',
    timestamptz '2026-10-05 15:00:00+00',
    'solar', null
  );

  if (v_result ->> 'ready')::boolean = true
     and (v_result ->> 'requires_alternative')::boolean = false then
    raise notice 'PASS 16: solar ينتهي عند 18:00 بالضبط → ready بلا بديل';
  else
    raise notice 'FAIL 16: النهاية عند 18:00 بالضبط أخطأت: %', v_result;
  end if;

  -- ============================================================
  -- 17. Solar تبدأ 18:00 → solar_start_outside_window.
  -- ============================================================
  v_result := ops.evaluate_booking_execution_readiness(
    v_well,
    timestamptz '2026-10-05 15:00:00+00',
    timestamptz '2026-10-05 16:00:00+00',
    'solar', null
  );

  if (v_result ->> 'ready')::boolean = false
     and v_result ->> 'reason_code' = 'solar_start_outside_window' then
    raise notice 'PASS 17: solar يبدأ عند 18:00 → solar_start_outside_window';
  else
    raise notice 'FAIL 17: بداية 18:00 لم تُرفض: %', v_result;
  end if;

  -- ============================================================
  -- 18. Solar قبل 06:00 → نفس الرفض. 05:00 Aden = 02:00 UTC.
  -- ============================================================
  v_result := ops.evaluate_booking_execution_readiness(
    v_well,
    timestamptz '2026-10-05 02:00:00+00',
    timestamptz '2026-10-05 03:00:00+00',
    'solar', null
  );

  if (v_result ->> 'ready')::boolean = false
     and v_result ->> 'reason_code' = 'solar_start_outside_window' then
    raise notice 'PASS 18: solar قبل 06:00 → solar_start_outside_window';
  else
    raise notice 'FAIL 18: بداية قبل 06:00 لم تُرفض: %', v_result;
  end if;

  -- ============================================================
  -- 19. mixed التاريخي يبقى مخزنًا وغير auto-start-ready typed.
  -- ============================================================
  if (select expected_energy_source from ops.irrigation_bookings
      where id = v_booking_hist_mixed) = 'mixed' then
    raise notice 'PASS 19: الحجز التاريخي mixed بقي كما هو بلا إعادة كتابة';
  else
    raise notice 'FAIL 19: الحجز التاريخي mixed تغير';
  end if;

  v_result := ops.evaluate_booking_execution_readiness(
    v_well,
    timestamptz '2026-10-05 08:00:00+00',
    timestamptz '2026-10-05 09:00:00+00',
    'mixed', null
  );

  if (v_result ->> 'ready')::boolean = false
     and v_result ->> 'reason_code' = 'unsupported_energy_source' then
    raise notice 'PASS 19: mixed التاريخي ليس execution-ready بسبب typed';
  else
    raise notice 'FAIL 19: نتيجة mixed غير صحيحة: %', v_result;
  end if;

  -- ============================================================
  -- 20. null التاريخي يبقى مخزنًا وغير جاهز بسببه المكتوب.
  -- ============================================================
  if (select expected_energy_source from ops.irrigation_bookings
      where id = v_booking_hist_null) is null then
    raise notice 'PASS 20: الحجز التاريخي null بقي كما هو بلا ترقية صامتة';
  else
    raise notice 'FAIL 20: الحجز التاريخي null تغير';
  end if;

  v_result := ops.evaluate_booking_execution_readiness(
    v_well,
    timestamptz '2026-10-05 06:00:00+00',
    timestamptz '2026-10-05 07:00:00+00',
    null, null
  );

  if (v_result ->> 'ready')::boolean = false
     and v_result ->> 'reason_code' = 'missing_energy_source' then
    raise notice 'PASS 20: null التاريخي ليس execution-ready بسبب typed';
  else
    raise notice 'FAIL 20: نتيجة null غير صحيحة: %', v_result;
  end if;

  -- ============================================================
  -- 21. diesel أساسي ومعه بديل غير منطقي → not ready typed.
  -- ============================================================
  v_result := ops.evaluate_booking_execution_readiness(
    v_well,
    timestamptz '2026-10-09 10:00:00+00',
    timestamptz '2026-10-09 11:00:00+00',
    'well_diesel', 'farmer_diesel'
  );

  if (v_result ->> 'ready')::boolean = false
     and v_result ->> 'reason_code' = 'invalid_alternative_energy_source' then
    raise notice 'PASS 21: diesel مع بديل غير منطقي → not ready typed';
  else
    raise notice 'FAIL 21: نتيجة diesel مع بديل غير صحيحة: %', v_result;
  end if;

  -- ============================================================
  -- 22. helper يشتق الزمن من Asia/Aden لا من timezone الجلسة.
  -- ============================================================
  execute 'set local timezone to ''Asia/Damascus''';

  v_result := ops.evaluate_booking_execution_readiness(
    v_well,
    timestamptz '2026-10-10 07:00:00+00',
    timestamptz '2026-10-10 08:00:00+00',
    'solar', null
  );

  execute 'set local timezone to ''UTC''';

  if (v_result ->> 'ready')::boolean = true
     and (v_result ->> 'solar_window_start')::timestamptz
           = timestamptz '2026-10-10 03:00:00+00'
     and (v_result ->> 'solar_window_end')::timestamptz
           = timestamptz '2026-10-10 15:00:00+00'
     and v_result ->> 'timezone' = 'Asia/Aden' then
    raise notice 'PASS 22: نافذة الشمس مشتقة من Asia/Aden لا من timezone الجلسة';
  else
    raise notice 'FAIL 22: النافذة تأثرت بمنطقة الجلسة: %', v_result;
  end if;

  -- ============================================================
  -- 23. لا Direct DML أو GRANT جديد للعميل نتيجة الجولة.
  -- ============================================================
  if not has_table_privilege('authenticated', 'ops.irrigation_sessions', 'INSERT')
     and not has_table_privilege('authenticated', 'ops.irrigation_bookings', 'UPDATE')
     and not has_table_privilege('authenticated', 'core.pumps', 'UPDATE')
     and (select count(*) from information_schema.role_table_grants
          where grantee = 'anon'
            and table_schema = 'ops'
            and privilege_type in ('INSERT','UPDATE','DELETE')) = 0 then
    raise notice 'PASS 23: لا Direct DML جديد لأدوار التطبيق';
  else
    raise notice 'FAIL 23: منح DML جديد ظهر نتيجة الجولة';
  end if;

  -- ============================================================
  -- 24. helpers الداخلية ليست surface عامة: لا EXECUTE لأي دور عميل.
  -- ============================================================
  if not has_function_privilege('anon',
        'ops.solar_window_for_day(date)', 'EXECUTE')
     and not has_function_privilege('authenticated',
        'ops.solar_window_for_day(date)', 'EXECUTE')
     and not has_function_privilege('service_role',
        'ops.solar_window_for_day(date)', 'EXECUTE')
     and not has_function_privilege('anon',
        'ops.evaluate_booking_execution_readiness(uuid,timestamptz,timestamptz,text,text)', 'EXECUTE')
     and not has_function_privilege('authenticated',
        'ops.evaluate_booking_execution_readiness(uuid,timestamptz,timestamptz,text,text)', 'EXECUTE')
     and not has_function_privilege('service_role',
        'ops.evaluate_booking_execution_readiness(uuid,timestamptz,timestamptz,text,text)', 'EXECUTE') then
    raise notice 'PASS 24: helpers الداخلية بلا أي GRANT — ليست surface عامة جديدة';
  else
    raise notice 'FAIL 24: أحد helpers الداخلية مكشوف لدور عميل';
  end if;

  raise notice '--- انتهى اختبار أسس تنفيذ الحجوزات 113 (فحوص مركّبة: 24) ---';
end
$test$;

-- =====================================================================
-- M113-B: إنفاذ الجاهزية في الإنشاء وإعادة الجدولة والقراءات.
-- =====================================================================

do $test_b$
declare
  v_tenant uuid;
  v_other_tenant uuid;
  v_well uuid;
  v_well_zero uuid;
  v_other_well uuid;
  v_operator uuid;
  v_account uuid;
  v_farm uuid;
  v_other_person uuid;
  v_other_profile uuid;
  v_other_account uuid;
  v_other_farm uuid;
  v_zero_person uuid;
  v_zero_profile uuid;
  v_zero_account uuid;
  v_zero_farm uuid;
  v_command uuid;
  v_conflict_command uuid;
  v_rejected_command uuid;
  v_legacy_command uuid;
  v_reschedule_command uuid;
  v_booking_diesel uuid;
  v_booking_solar uuid;
  v_booking_alt uuid;
  v_booking_historical uuid;
  v_result jsonb;
  v_replay jsonb;
  v_alt_response jsonb;
  v_conflict_response jsonb;
  v_legacy_response jsonb;
  v_item jsonb;
  v_count bigint;
  v_count_2 bigint;
  v_count_3 bigint;
  v_start timestamptz;
  v_end timestamptz;
  v_reservation uuid;
  v_booking_count_before bigint;
  v_history_count_before bigint;
  v_reservation_count_before bigint;
begin
  select w.tenant_id, w.id
    into v_tenant, v_well
  from core.wells w
  where w.name = 'بئر التنفيذ 113';

  select w.id into v_well_zero
  from core.wells w
  where w.name = 'بئر بلا مضخة 113';

  select u.id into v_operator
  from auth.users u
  where u.email = 'operator113@test.local';

  select fwa.id into v_account
  from ops.farmer_well_accounts fwa
  where fwa.public_code = 'FWA-113';

  select f.id into v_farm
  from ops.farms f
  where f.well_id = v_well and f.name = 'أرض التنفيذ 113';

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well_zero, v_operator, 'operator', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع البئر بلا مضخة 113', 'مزارع البئر بلا مضخة 113')
  returning id into v_zero_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_zero_person)
  returning id into v_zero_profile;

  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (
    v_tenant, v_zero_profile, v_well_zero, 'FWA-113-ZERO'
  ) returning id into v_zero_account;

  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_zero, 'أرض بلا مضخة 113', v_zero_account)
  returning id into v_zero_farm;

  insert into core.tenants (name)
  values ('جهة عزل أوامر الحجوزات 113')
  returning id into v_other_tenant;

  insert into core.wells (tenant_id, name)
  values (v_other_tenant, 'بئر عزل أوامر الحجوزات 113')
  returning id into v_other_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_other_well, v_operator, 'operator', 'active');

  insert into core.pumps (well_id, name, power_source)
  values (v_other_well, 'مضخة عزل أوامر الحجوزات 113', 'diesel');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_other_tenant, 'مزارع عزل أوامر الحجوزات 113', 'مزارع عزل أوامر الحجوزات 113')
  returning id into v_other_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_other_tenant, v_other_person)
  returning id into v_other_profile;

  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (
    v_other_tenant, v_other_profile, v_other_well, 'FWA-113-ISOLATED'
  ) returning id into v_other_account;

  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_other_well, 'أرض عزل أوامر الحجوزات 113', v_other_account)
  returning id into v_other_farm;

  -- B1) توقيع واحد لكل عقد، api invoker، وanon محجوب.
  if to_regprocedure(
       'api.create_booking(uuid,uuid,uuid,timestamptz,timestamptz,uuid,text,integer,text)'
     ) is null
     and to_regprocedure(
       'api.create_booking(uuid,uuid,uuid,timestamptz,timestamptz,uuid,text,integer,text,text)'
     ) is not null
     and to_regprocedure(
       'api.reschedule_booking(uuid,timestamptz,timestamptz,text,uuid)'
     ) is null
     and to_regprocedure(
       'api.reschedule_booking(uuid,timestamptz,timestamptz,text,uuid,text)'
     ) is not null
     and to_regprocedure(
       'ops.create_booking(uuid,uuid,uuid,timestamptz,timestamptz,text,integer,text)'
     ) is null
     and to_regprocedure(
       'ops.create_booking(uuid,uuid,uuid,timestamptz,timestamptz,text,integer,text,text)'
     ) is not null
     and to_regprocedure(
       'ops.reschedule_booking(uuid,timestamptz,timestamptz,text)'
     ) is null
     and to_regprocedure(
       'ops.reschedule_booking(uuid,timestamptz,timestamptz,text,text)'
     ) is not null
     and (select count(*) from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'ops'
            and p.proname = 'create_booking') = 1
     and (select count(*) from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'ops'
            and p.proname = 'reschedule_booking') = 1
     and (select count(*) from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'ops'
            and p.proname in ('create_booking', 'reschedule_booking')
            and p.prosecdef) = 2
     and has_function_privilege(
       'authenticated',
       'ops.create_booking(uuid,uuid,uuid,timestamptz,timestamptz,text,integer,text,text)',
       'EXECUTE'
     )
     and has_function_privilege(
       'service_role',
       'ops.create_booking(uuid,uuid,uuid,timestamptz,timestamptz,text,integer,text,text)',
       'EXECUTE'
     )
     and not has_function_privilege(
       'anon',
       'ops.create_booking(uuid,uuid,uuid,timestamptz,timestamptz,text,integer,text,text)',
       'EXECUTE'
     )
     and has_function_privilege(
       'authenticated',
       'ops.reschedule_booking(uuid,timestamptz,timestamptz,text,text)',
       'EXECUTE'
     )
     and has_function_privilege(
       'service_role',
       'ops.reschedule_booking(uuid,timestamptz,timestamptz,text,text)',
       'EXECUTE'
     )
     and not has_function_privilege(
       'anon',
       'ops.reschedule_booking(uuid,timestamptz,timestamptz,text,text)',
       'EXECUTE'
     )
     and not has_function_privilege(
       'anon',
       'api.create_booking(uuid,uuid,uuid,timestamptz,timestamptz,uuid,text,integer,text,text)',
       'EXECUTE'
     )
     and not has_function_privilege(
       'anon',
       'api.reschedule_booking(uuid,timestamptz,timestamptz,text,uuid,text)',
       'EXECUTE'
     )
     and (select count(*) from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'api'
            and p.proname in ('create_booking', 'reschedule_booking')
            and p.prosecdef) = 0
     and to_regprocedure(
       'sync.verify_booking_command_replay(uuid,uuid,text,jsonb,jsonb)'
     ) is not null
     and (select p.prosecdef
          from pg_proc p
          where p.oid = to_regprocedure(
            'sync.verify_booking_command_replay(uuid,uuid,text,jsonb,jsonb)'
          ))
     and (select p.proconfig @> array['search_path=pg_catalog, pg_temp']
          from pg_proc p
          where p.oid = to_regprocedure(
            'sync.verify_booking_command_replay(uuid,uuid,text,jsonb,jsonb)'
          ))
     and (select pg_get_userbyid(p.proowner)
          not in ('anon', 'authenticated', 'service_role')
          from pg_proc p
          where p.oid = to_regprocedure(
            'sync.verify_booking_command_replay(uuid,uuid,text,jsonb,jsonb)'
          ))
     and not has_function_privilege(
       'anon',
       'sync.verify_booking_command_replay(uuid,uuid,text,jsonb,jsonb)',
       'EXECUTE'
     )
     and not exists (
       select 1
       from information_schema.routine_privileges rp
       where rp.routine_schema = 'sync'
         and rp.routine_name = 'verify_booking_command_replay'
         and rp.grantee = 'PUBLIC'
         and rp.privilege_type = 'EXECUTE'
     )
     and has_function_privilege(
       'authenticated',
       'sync.verify_booking_command_replay(uuid,uuid,text,jsonb,jsonb)',
       'EXECUTE'
     )
     and has_function_privilege(
       'service_role',
       'sync.verify_booking_command_replay(uuid,uuid,text,jsonb,jsonb)',
       'EXECUTE'
     )
     and not has_schema_privilege('anon', 'ops', 'CREATE')
     and not has_schema_privilege('authenticated', 'ops', 'CREATE')
     and not has_schema_privilege('service_role', 'ops', 'CREATE')
     and not has_schema_privilege('anon', 'core', 'CREATE')
     and not has_schema_privilege('authenticated', 'core', 'CREATE')
     and not has_schema_privilege('service_role', 'core', 'CREATE')
     and not has_schema_privilege('authenticated', 'audit', 'CREATE')
     and not has_schema_privilege('service_role', 'audit', 'CREATE')
     and not has_schema_privilege('authenticated', 'iam', 'CREATE')
     and not has_schema_privilege('service_role', 'iam', 'CREATE')
     and not has_function_privilege(
       'authenticated',
       'ops.create_booking_m112_unchecked(uuid,uuid,uuid,timestamptz,timestamptz,text,integer,text)',
       'EXECUTE'
     )
     and not has_function_privilege(
       'authenticated',
       'ops.reschedule_booking_m112_unchecked(uuid,timestamptz,timestamptz,text)',
       'EXECUTE'
     )
     and not has_function_privilege(
       'service_role',
       'ops.create_booking_m112_unchecked(uuid,uuid,uuid,timestamptz,timestamptz,text,integer,text)',
       'EXECUTE'
     )
     and not has_function_privilege(
       'service_role',
       'ops.reschedule_booking_m112_unchecked(uuid,timestamptz,timestamptz,text)',
       'EXECUTE'
     ) then
    raise notice 'PASS B1: توقيعات ops وحيدة وصلاحيات api/helpers/CREATE صحيحة';
  else
    raise notice 'FAIL B1: توقيع أو خاصية أمان لعقود B غير صحيحة';
  end if;

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  -- B2) حجز ديزل مكتمل يصبح confirmed ويكتب الأثر الذري الكامل.
  v_command := gen_random_uuid();
  v_result := api.create_booking(
    v_well, v_account, v_farm,
    timestamptz '2026-11-01 03:00:00+00',
    timestamptz '2026-11-01 04:00:00+00',
    v_command, 'well_diesel', 2, 'ديزل M113-B'
  );
  v_booking_diesel := (v_result ->> 'booking_id')::uuid;

  select
    (select count(*) from ops.booking_status_history h
     where h.booking_id = v_booking_diesel and h.new_status = 'confirmed'),
    (select count(*) from ops.resource_reservations r
     where r.booking_id = v_booking_diesel and r.status = 'active'
       and r.resource_type = 'well_path')
  into v_count, v_count_2;

  if v_result ->> 'status' = 'confirmed'
     and v_result -> 'execution_readiness' ->> 'reason_code' = 'ready'
     and v_count = 1 and v_count_2 = 1 then
    raise notice 'PASS B2: حجز الديزل الجاهز تأكد ذريًا مع التاريخ والمورد';
  else
    raise notice 'FAIL B2: إنشاء حجز الديزل غير مكتمل: %', v_result;
  end if;

  -- B3) null وmixed يُرفضان بلا حجز أو تاريخ أو مورد.
  select
    (select count(*) from ops.irrigation_bookings b where b.well_id = v_well),
    (select count(*) from ops.booking_status_history h
     where h.booking_id in (select id from ops.irrigation_bookings where well_id = v_well)),
    (select count(*) from ops.resource_reservations r where r.well_id = v_well)
  into v_count, v_count_2, v_count_3;

  v_result := api.create_booking(
    v_well, v_account, v_farm,
    timestamptz '2026-11-02 03:00:00+00',
    timestamptz '2026-11-02 04:00:00+00',
    gen_random_uuid(), null, 0, null
  );
  v_replay := api.create_booking(
    v_well, v_account, v_farm,
    timestamptz '2026-11-02 05:00:00+00',
    timestamptz '2026-11-02 06:00:00+00',
    gen_random_uuid(), 'mixed', 0, null
  );

  if v_result ->> 'status' = 'rejected'
     and v_result ->> 'reason_code' = 'missing_energy_source'
     and v_replay ->> 'status' = 'rejected'
     and v_replay ->> 'reason_code' = 'unsupported_energy_source'
     and (select count(*) from ops.irrigation_bookings where well_id = v_well) = v_count
     and (select count(*) from ops.booking_status_history
          where booking_id in (select id from ops.irrigation_bookings where well_id = v_well)) = v_count_2
     and (select count(*) from ops.resource_reservations where well_id = v_well) = v_count_3 then
    raise notice 'PASS B3: null وmixed رُفضا بلا أثر تشغيلي جزئي';
  else
    raise notice 'FAIL B3: رفض الطاقة الناقصة أو أثره غير صحيح: % / %', v_result, v_replay;
  end if;

  -- B4) 06:00 شامل، و18:00 كبداية مرفوض، والنهاية عند 18:00 مقبولة.
  v_result := api.create_booking(
    v_well, v_account, v_farm,
    timestamptz '2026-11-03 03:00:00+00',
    timestamptz '2026-11-03 04:00:00+00',
    gen_random_uuid(), 'solar', 0, 'حد 06:00'
  );
  v_booking_solar := (v_result ->> 'booking_id')::uuid;

  v_replay := api.create_booking(
    v_well, v_account, v_farm,
    timestamptz '2026-11-04 15:00:00+00',
    timestamptz '2026-11-04 16:00:00+00',
    gen_random_uuid(), 'solar', 0, 'حد 18:00 بداية'
  );

  if v_result ->> 'status' = 'confirmed'
     and v_replay ->> 'status' = 'rejected'
     and v_replay ->> 'reason_code' = 'solar_start_outside_window' then
    raise notice 'PASS B4: حد 06:00 شامل وحد 18:00 غير شامل للبداية';
  else
    raise notice 'FAIL B4: حدود بداية نافذة الشمس غير صحيحة: % / %', v_result, v_replay;
  end if;

  v_result := api.create_booking(
    v_well, v_account, v_farm,
    timestamptz '2026-11-05 13:00:00+00',
    timestamptz '2026-11-05 15:00:00+00',
    gen_random_uuid(), 'solar', 0, 'ينتهي 18:00'
  );
  if v_result ->> 'status' = 'confirmed'
     and (v_result -> 'execution_readiness' ->> 'requires_alternative')::boolean = false then
    raise notice 'PASS B4: نهاية 18:00 مقبولة بلا بديل';
  else
    raise notice 'FAIL B4: نهاية 18:00 رُفضت خطأً: %', v_result;
  end if;

  -- B5) الامتداد بعد 18:00 يحتاج بديلًا، ويُحفظ البديل في القراءات.
  v_result := api.create_booking(
    v_well, v_account, v_farm,
    timestamptz '2026-11-06 14:00:00+00',
    timestamptz '2026-11-06 16:00:00+00',
    gen_random_uuid(), 'solar', 0, 'بلا بديل'
  );
  v_command := gen_random_uuid();
  v_replay := api.create_booking(
    v_well, v_account, v_farm,
    timestamptz '2026-11-07 14:00:00+00',
    timestamptz '2026-11-07 16:00:00+00',
    v_command, 'solar', 0, 'مع بديل', 'well_diesel'
  );
  v_alt_response := v_replay;
  v_booking_alt := (v_replay ->> 'booking_id')::uuid;

  if v_result ->> 'status' = 'rejected'
     and v_result ->> 'reason_code' = 'missing_alternative_energy_source'
     and v_replay ->> 'status' = 'confirmed'
     and (select alternative_energy_source from ops.irrigation_bookings
          where id = v_booking_alt) = 'well_diesel' then
    raise notice 'PASS B5: الامتداد بلا بديل رُفض ومع البديل تأكد وحُفظ';
  else
    raise notice 'FAIL B5: إنفاذ البديل عند الامتداد غير صحيح: % / %', v_result, v_replay;
  end if;

  v_result := api.list_well_bookings(v_well, null, null, 200);
  select item into v_item
  from jsonb_array_elements(v_result -> 'bookings') item
  where (item ->> 'id')::uuid = v_booking_alt;
  v_replay := api.get_booking_detail(v_booking_alt);

  if v_item ->> 'alternative_energy_source' = 'well_diesel'
     and v_replay -> 'booking' ->> 'alternative_energy_source' = 'well_diesel' then
    raise notice 'PASS B5: القائمة والتفصيل يعيدان المصدر البديل المحفوظ';
  else
    raise notice 'FAIL B5: المصدر البديل غائب عن قراءة: % / %', v_item, v_replay;
  end if;

  -- B6) غياب المضخة الفعالة يرفض التأكيد بلا أثر حجز.
  v_rejected_command := gen_random_uuid();
  v_result := api.create_booking(
    v_well_zero, v_zero_account, v_zero_farm,
    timestamptz '2026-11-08 03:00:00+00',
    timestamptz '2026-11-08 04:00:00+00',
    v_rejected_command, 'well_diesel', 0, null
  );
  v_replay := api.create_booking(
    v_well_zero, v_zero_account, v_zero_farm,
    timestamptz '2026-11-08 03:00:00+00',
    timestamptz '2026-11-08 04:00:00+00',
    v_rejected_command, 'well_diesel', 0, null
  );
  if v_result ->> 'status' = 'rejected'
     and v_result ->> 'reason_code' = 'active_pump_missing'
     and v_replay = v_result
     and not exists (select 1 from ops.irrigation_bookings where well_id = v_well_zero) then
    raise notice 'PASS B6: الرفض أُعيد حرفيًا بلا حجز جزئي';
  else
    raise notice 'FAIL B6: الرفض أو replay غير صحيح: % / %', v_result, v_replay;
  end if;

  -- B7) replay مطابق يعيد الرد، والمختلف لا يعيد نتيجة قديمة.
  select
    (select count(*) from ops.irrigation_bookings b
     where b.id = v_booking_alt),
    (select count(*) from ops.booking_status_history h
     where h.booking_id = v_booking_alt),
    (select count(*) from ops.resource_reservations r
     where r.booking_id = v_booking_alt)
  into
    v_booking_count_before,
    v_history_count_before,
    v_reservation_count_before;

  v_result := api.create_booking(
    v_well, v_account, v_farm,
    timestamptz '2026-11-07 14:00:00+00',
    timestamptz '2026-11-07 16:00:00+00',
    v_command, 'solar', 0, 'مع بديل', 'well_diesel'
  );
  select count(*) into v_count
  from sync.processed_commands pc
  where pc.command_id = v_command;
  v_item := sync.verify_booking_command_replay(
    v_well,
    v_command,
    'create_booking',
    jsonb_build_object(
      'booking_contract_version', 113,
      'well_id', v_well,
      'farmer_well_account_id', v_account,
      'farm_id', v_farm,
      'scheduled_start', timestamptz '2026-11-07 14:00:00+00',
      'scheduled_end', timestamptz '2026-11-07 16:00:00+00',
      'expected_energy_source', 'solar',
      'alternative_energy_source', 'well_diesel',
      'priority', 0,
      'notes', 'مع بديل'
    ),
    jsonb_build_object(
      'farmer_well_account_id', v_account,
      'farm_id', v_farm,
      'scheduled_start', timestamptz '2026-11-07 14:00:00+00',
      'scheduled_end', timestamptz '2026-11-07 16:00:00+00'
    )
  );

  if v_result = v_alt_response
     and v_result ->> 'booking_id' = v_booking_alt::text
     and v_count = 0
     and not (v_item ? 'request_payload')
     and v_item -> 'response' = v_alt_response
     and (select count(*) from ops.irrigation_bookings b
          where b.id = v_booking_alt) = v_booking_count_before
     and (select count(*) from ops.booking_status_history h
          where h.booking_id = v_booking_alt) = v_history_count_before
     and (select count(*) from ops.resource_reservations r
          where r.booking_id = v_booking_alt) = v_reservation_count_before then
    raise notice 'PASS B7: replay المشغل مطابق بلا قراءة سجل أو كتابة مكررة';
  else
    raise notice 'FAIL B7: replay المطابق لم يعد الرد المخزن: %', v_result;
  end if;

  begin
    perform api.create_booking(
      v_well, v_account, v_farm,
      timestamptz '2026-11-07 14:00:00+00',
      timestamptz '2026-11-07 16:00:00+00',
      v_command, 'solar', 0, 'مع بديل', 'farmer_diesel'
    );
    raise notice 'FAIL B7: replay مختلف أعاد نتيجة الأمر القديم';
  exception when others then
    if position('محتوى مختلف' in sqlerrm) > 0 then
      raise notice 'PASS B7: replay مختلف رُفض ببصمة المحتوى';
    else
      raise notice 'FAIL B7: سبب رفض replay المختلف غير متوقع: %', sqlerrm;
    end if;
  end;

  begin
    perform api.reschedule_booking(
      v_booking_alt,
      timestamptz '2026-11-08 14:00:00+00',
      timestamptz '2026-11-08 16:00:00+00',
      'خلط نوع الأمر', v_command, 'well_diesel'
    );
    raise notice 'FAIL B7: command_id خلط create_booking مع reschedule_booking';
  exception when others then
    if SQLSTATE='22023' and SQLERRM='command_identity_conflict' then
      raise notice 'PASS B7: خلط نوعي الأمر رُفض';
    else
      raise notice 'FAIL B7: سبب رفض خلط نوع الأمر غير متوقع: %', sqlerrm;
    end if;
  end;

  begin
    perform api.create_booking(
      v_well_zero, v_zero_account, v_zero_farm,
      timestamptz '2026-11-07 14:00:00+00',
      timestamptz '2026-11-07 16:00:00+00',
      v_command, 'solar', 0, 'مع بديل', 'well_diesel'
    );
    raise notice 'FAIL B7: command_id عبر بئر آخر أعاد أمر البئر الأصلي';
  exception when others then
    if position('محتوى مختلف' in sqlerrm) > 0 then
      raise notice 'PASS B7: عزل البئر رفض إعادة استخدام command_id';
    else
      raise notice 'FAIL B7: سبب رفض خلط البئر غير متوقع: %', sqlerrm;
    end if;
  end;

  execute 'reset role';
  update core.well_assignments
  set role = 'viewer'
  where well_id = v_well and profile_id = v_operator;
  execute 'set local role authenticated';

  begin
    perform api.create_booking(
      v_well, v_account, v_farm,
      timestamptz '2026-11-07 14:00:00+00',
      timestamptz '2026-11-07 16:00:00+00',
      v_command, 'solar', 0, 'مع بديل', 'well_diesel'
    );
    raise notice 'FAIL B7: دور بلا booking.create قرأ replay مخزنًا';
  exception when others then
    if position('صلاحية إنشاء حجز' in sqlerrm) > 0 then
      raise notice 'PASS B7: الدور غير المخول حُجب عن replay';
    else
      raise notice 'FAIL B7: سبب رفض الدور غير المخول غير متوقع: %', sqlerrm;
    end if;
  end;

  execute 'reset role';
  update core.well_assignments
  set role = 'operator', status = 'inactive'
  where well_id = v_well and profile_id = v_operator;
  execute 'set local role authenticated';

  begin
    perform api.create_booking(
      v_well, v_account, v_farm,
      timestamptz '2026-11-07 14:00:00+00',
      timestamptz '2026-11-07 16:00:00+00',
      v_command, 'solar', 0, 'مع بديل', 'well_diesel'
    );
    raise notice 'FAIL B7: التعيين غير النشط قرأ replay مخزنًا';
  exception when others then
    if position('لا تملك وصولًا' in sqlerrm) > 0 then
      raise notice 'PASS B7: التعيين غير النشط حُجب عن replay';
    else
      raise notice 'FAIL B7: سبب رفض التعيين غير النشط غير متوقع: %', sqlerrm;
    end if;
  end;

  execute 'reset role';
  update core.well_assignments
  set status = 'active'
  where well_id = v_well and profile_id = v_operator;
  execute 'set local role authenticated';

  v_result := api.create_booking(
    v_other_well, v_other_account, v_other_farm,
    timestamptz '2026-11-10 03:00:00+00',
    timestamptz '2026-11-10 04:00:00+00',
    v_command, 'well_diesel', 0, 'عزل الجهة'
  );
  if v_result ->> 'status' = 'confirmed'
     and (v_result ->> 'booking_id')::uuid <> v_booking_alt then
    raise notice 'PASS B7: command_id نفسه مستقل بين جهتين';
  else
    raise notice 'FAIL B7: عزل الجهة لم يحفظ استقلال command_id: %', v_result;
  end if;

  execute 'reset role';
  v_legacy_command := gen_random_uuid();
  v_legacy_response := jsonb_build_object(
    'status', 'confirmed',
    'booking_id', v_booking_diesel,
    'well_id', v_well,
    'scheduled_start', timestamptz '2026-11-01 03:00:00+00',
    'scheduled_end', timestamptz '2026-11-01 04:00:00+00'
  );
  insert into sync.processed_commands (
    tenant_id, command_id, command_type, status,
    request_payload, response_payload
  ) values (
    v_tenant, v_legacy_command, 'create_booking', 'accepted',
    jsonb_build_object(
      'farmer_well_account_id', v_account,
      'farm_id', v_farm,
      'scheduled_start', timestamptz '2026-11-01 03:00:00+00',
      'scheduled_end', timestamptz '2026-11-01 04:00:00+00'
    ),
    v_legacy_response
  );
  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  v_result := api.create_booking(
    v_well, v_account, v_farm,
    timestamptz '2026-11-01 03:00:00+00',
    timestamptz '2026-11-01 04:00:00+00',
    v_legacy_command, 'well_diesel', 2, 'ديزل M113-B'
  );
  if v_result = v_legacy_response then
    raise notice 'PASS B7: replay لأمر M112 مقبول سابقًا بقي متوافقًا';
  else
    raise notice 'FAIL B7: replay أمر M112 المقبول انكسر: %', v_result;
  end if;

  -- B8) تعارض المورد يبقى time_overlap مكتوبًا.
  v_conflict_command := gen_random_uuid();
  v_result := api.create_booking(
    v_well, v_account, v_farm,
    timestamptz '2026-11-01 03:30:00+00',
    timestamptz '2026-11-01 04:30:00+00',
    v_conflict_command, 'well_diesel', 0, 'تعارض B'
  );
  v_conflict_response := v_result;
  select
    (select count(*) from ops.irrigation_bookings b where b.well_id = v_well),
    (select count(*) from ops.booking_status_history h
     where h.booking_id in (
       select b.id from ops.irrigation_bookings b where b.well_id = v_well
     )),
    (select count(*) from ops.resource_reservations r where r.well_id = v_well)
  into
    v_booking_count_before,
    v_history_count_before,
    v_reservation_count_before;

  v_replay := api.create_booking(
    v_well, v_account, v_farm,
    timestamptz '2026-11-01 03:30:00+00',
    timestamptz '2026-11-01 04:30:00+00',
    v_conflict_command, 'well_diesel', 0, 'تعارض B'
  );
  if v_result ->> 'status' = 'conflict'
     and v_result ->> 'conflict_code' = 'time_overlap'
     and v_replay = v_conflict_response
     and (select count(*) from ops.irrigation_bookings b
          where b.well_id = v_well) = v_booking_count_before
     and (select count(*) from ops.booking_status_history h
          where h.booking_id in (
            select b.id from ops.irrigation_bookings b where b.well_id = v_well
          )) = v_history_count_before
     and (select count(*) from ops.resource_reservations r
          where r.well_id = v_well) = v_reservation_count_before then
    raise notice 'PASS B8: replay التعارض أعاد time_overlap بلا كتابة';
  else
    raise notice 'FAIL B8: replay التعارض أو ذريته غير صحيح: % / %', v_result, v_replay;
  end if;

  begin
    perform api.create_booking(
      v_well, v_account, v_farm,
      timestamptz '2026-11-01 03:30:00+00',
      timestamptz '2026-11-01 04:30:00+00',
      v_conflict_command, 'well_diesel', 1, 'تعارض B'
    );
    raise notice 'FAIL B8: replay تعارض مختلف أعاد النتيجة القديمة';
  exception when others then
    if position('محتوى مختلف' in sqlerrm) > 0 then
      raise notice 'PASS B8: replay التعارض المختلف رُفض';
    else
      raise notice 'FAIL B8: سبب رفض replay التعارض المختلف غير متوقع: %', sqlerrm;
    end if;
  end;

  -- B9) إعادة الجدولة عبر حد الشمس تُرفض أولًا ثم تنجح ببديل.
  select b.scheduled_start, b.scheduled_end
    into v_start, v_end
  from ops.irrigation_bookings b
  where b.id = v_booking_solar;
  select r.id into v_reservation
  from ops.resource_reservations r
  where r.booking_id = v_booking_solar and r.status = 'active';
  select count(*) into v_count
  from ops.booking_status_history h where h.booking_id = v_booking_solar;

  v_result := api.reschedule_booking(
    v_booking_solar,
    timestamptz '2026-11-03 14:00:00+00',
    timestamptz '2026-11-03 16:00:00+00',
    'امتداد بلا بديل', gen_random_uuid()
  );

  if v_result ->> 'status' = 'rejected'
     and v_result ->> 'reason_code' = 'missing_alternative_energy_source'
     and (select scheduled_start from ops.irrigation_bookings where id = v_booking_solar) = v_start
     and (select scheduled_end from ops.irrigation_bookings where id = v_booking_solar) = v_end
     and (select count(*) from ops.booking_status_history where booking_id = v_booking_solar) = v_count
     and (select id from ops.resource_reservations
          where booking_id = v_booking_solar and status = 'active') = v_reservation then
    raise notice 'PASS B9: إعادة الجدولة غير الجاهزة رُفضت وحفظت الأصل';
  else
    raise notice 'FAIL B9: رفض إعادة الجدولة ترك أثرًا أو سببًا خاطئًا: %', v_result;
  end if;

  v_reschedule_command := gen_random_uuid();
  v_result := api.reschedule_booking(
    v_booking_solar,
    timestamptz '2026-11-03 14:00:00+00',
    timestamptz '2026-11-03 16:00:00+00',
    'امتداد مع بديل', v_reschedule_command, 'farmer_diesel'
  );
  v_replay := api.reschedule_booking(
    v_booking_solar,
    timestamptz '2026-11-03 14:00:00+00',
    timestamptz '2026-11-03 16:00:00+00',
    'امتداد مع بديل', v_reschedule_command, 'farmer_diesel'
  );

  if v_result ->> 'status' = 'confirmed'
     and v_replay = v_result
     and (select alternative_energy_source from ops.irrigation_bookings
          where id = v_booking_solar) = 'farmer_diesel' then
    raise notice 'PASS B9: إعادة الجدولة الجاهزة حفظت البديل وreplay مطابق';
  else
    raise notice 'FAIL B9: إعادة الجدولة الجاهزة أو replay غير صحيح: % / %', v_result, v_replay;
  end if;

  begin
    perform api.reschedule_booking(
      v_booking_solar,
      timestamptz '2026-11-03 14:00:00+00',
      timestamptz '2026-11-03 16:00:00+00',
      'امتداد مع بديل', v_reschedule_command, 'well_diesel'
    );
    raise notice 'FAIL B9: replay إعادة جدولة مختلف لم يُرفض';
  exception when others then
    if position('محتوى مختلف' in sqlerrm) > 0 then
      raise notice 'PASS B9: replay إعادة الجدولة المختلف رُفض';
    else
      raise notice 'FAIL B9: سبب رفض replay إعادة الجدولة غير متوقع: %', sqlerrm;
    end if;
  end;

  select b.id, b.scheduled_start
    into v_booking_historical, v_start
  from ops.irrigation_bookings b
  where b.public_code = 'BKG-113-M';
  v_result := api.reschedule_booking(
    v_booking_historical,
    timestamptz '2026-11-09 03:00:00+00',
    timestamptz '2026-11-09 04:00:00+00',
    'اختبار mixed التاريخي', gen_random_uuid()
  );
  if v_result ->> 'status' = 'rejected'
     and v_result ->> 'reason_code' = 'unsupported_energy_source'
     and (select scheduled_start from ops.irrigation_bookings
          where id = v_booking_historical) = v_start
     and (select expected_energy_source from ops.irrigation_bookings
          where id = v_booking_historical) = 'mixed' then
    raise notice 'PASS B9: إعادة جدولة mixed التاريخي رُفضت بلا إعادة كتابة';
  else
    raise notice 'FAIL B9: حجز mixed التاريخي تغير أو تأكد: %', v_result;
  end if;

  -- B10) Direct DML يبقى مغلقًا على authenticated.
  begin
    update ops.irrigation_bookings
    set alternative_energy_source = 'well_diesel'
    where id = v_booking_diesel;
    raise notice 'FAIL B10: سُمح بتعديل مباشر للحجز';
  exception when others then
    if position('permission denied' in sqlerrm) > 0 then
      raise notice 'PASS B10: Direct DML للحجز ما زال مغلقًا';
    else
      raise notice 'FAIL B10: سبب رفض Direct DML غير متوقع: %', sqlerrm;
    end if;
  end;

  execute 'reset role';
  raise notice '--- انتهى اختبار M113-B: فحوص B1..B10 ---';
end
$test_b$;

-- =====================================================================
-- M113-C: بدء جلسة سقي من حجز مؤكد.
-- =====================================================================

do $test_c$
declare
  v_tenant uuid;
  v_well uuid;
  v_well_without_pump uuid;
  v_other_well uuid;
  v_operator uuid;
  v_outsider uuid;
  v_person uuid;
  v_profile uuid;
  v_account uuid;
  v_no_pump_account uuid;
  v_farm uuid;
  v_other_person uuid;
  v_other_profile uuid;
  v_other_account uuid;
  v_other_farm uuid;
  v_pump uuid;
  v_other_pump uuid;
  v_booking uuid;
  v_draft_booking uuid;
  v_incomplete_booking uuid;
  v_blocked_booking uuid;
  v_no_pump_booking uuid;
  v_other_booking uuid;
  v_command uuid;
  v_rejected_command uuid;
  v_session uuid;
  v_free_session uuid;
  v_result jsonb;
  v_replay jsonb;
  -- الزمن الفعلي يُرسى على ساعة الخادم فيبقى ≤ الآن دائمًا (حارس المستقبل
  -- في ق-132 و)/ز) يرفض ما بعد clock_timestamp()). الحجوزات مجدولة لاحقًا
  -- فالبدء هنا بدء يدوي مبكر مشروع (ق-132: يجوز قبل الموعد).
  v_started_at timestamptz := date_trunc('minute', clock_timestamp());
  v_count bigint;
  v_count_2 bigint;
begin
  insert into core.tenants (name)
  values ('جهة اختبار بدء الحجز 113-C')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر بدء الحجز 113-C')
  returning id into v_well;
  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر بلا مضخة 113-C')
  returning id into v_well_without_pump;
  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر معزول 113-C')
  returning id into v_other_well;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'operator113c@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_operator;
  -- زناد 018 (on_auth_user_created) ينشئ الملف الشخصي تلقائيًا مع كل
  -- auth.users جديد؛ الإدراج هنا لتسميته فقط بنمط الكتلة A نفسها.
  insert into iam.profiles (id, full_name)
  values (v_operator, 'مشغل اختبار 113-C')
  on conflict (id) do nothing;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'outsider113c@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_outsider;
  insert into iam.profiles (id, full_name)
  values (v_outsider, 'مستخدم غير مخول 113-C')
  on conflict (id) do nothing;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well, v_operator, 'operator', 'active'),
    (v_well_without_pump, v_operator, 'operator', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع بدء الحجز 113-C', 'مزارع بدء الحجز 113-C')
  returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_profile;
  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (
    v_tenant, v_profile, v_well, 'FWA-113-C'
  ) returning id into v_account;
  insert into ops.farmer_well_accounts(tenant_id,farmer_profile_id,well_id,public_code)
  values(v_tenant,v_profile,v_well_without_pump,'FWA-113-C-NO-PUMP') returning id into v_no_pump_account;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well, 'أرض بدء الحجز 113-C', v_account)
  returning id into v_farm;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع البئر المعزول 113-C', 'مزارع البئر المعزول 113-C')
  returning id into v_other_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_other_person)
  returning id into v_other_profile;
  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (
    v_tenant, v_other_profile, v_other_well, 'FWA-113-C-OTHER'
  ) returning id into v_other_account;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_other_well, 'أرض البئر المعزول 113-C', v_other_account)
  returning id into v_other_farm;

  insert into core.pumps (well_id, name, power_source, status)
  values (v_well, 'المضخة الفعالة 113-C', 'solar', 'active')
  returning id into v_pump;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_other_well, 'مضخة البئر المعزول 113-C', 'diesel', 'active')
  returning id into v_other_pump;

  insert into billing.well_pricing
    (well_id, price_per_hour_minor, period_start)
  values
    (v_well, 5000, date '2026-01-01'),
    (v_other_well, 5000, date '2026-01-01');

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, alternative_energy_source, status
  ) values (
    v_tenant, 'BKG-113-C-OK', v_well, v_account, v_farm,
    timestamptz '2026-12-01 14:00:00+00',
    timestamptz '2026-12-01 16:00:00+00', 120,
    'solar', 'well_diesel', 'confirmed'
  ) returning id into v_booking;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-113-C-DRAFT', v_well, v_account, v_farm,
     timestamptz '2026-12-02 03:00:00+00',
     timestamptz '2026-12-02 04:00:00+00', 60, 'well_diesel', 'draft')
  returning id into v_draft_booking;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-113-C-INCOMPLETE', v_well, v_account, v_farm,
     timestamptz '2026-12-03 03:00:00+00',
     timestamptz '2026-12-03 04:00:00+00', 60, 'mixed', 'confirmed')
  returning id into v_incomplete_booking;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-113-C-BLOCKED', v_well, v_account, v_farm,
     timestamptz '2026-12-04 03:00:00+00',
     timestamptz '2026-12-04 04:00:00+00', 60, 'well_diesel', 'confirmed')
  returning id into v_blocked_booking;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-113-C-NO-PUMP', v_well_without_pump,
     v_no_pump_account, null,
     timestamptz '2026-12-05 03:00:00+00',
     timestamptz '2026-12-05 04:00:00+00', 60, 'well_diesel', 'confirmed')
  returning id into v_no_pump_booking;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-113-C-OTHER', v_other_well,
     v_other_account, v_other_farm,
     timestamptz '2026-12-06 03:00:00+00',
     timestamptz '2026-12-06 04:00:00+00', 60, 'well_diesel', 'confirmed')
  returning id into v_other_booking;

  -- C1) سطح API مستقل invoker، وحد sync الداخلي مقيد.
  if to_regprocedure(
       'api.start_irrigation_session_from_booking(uuid,timestamptz,uuid,text[])'
     ) is not null
     and not (select p.prosecdef from pg_proc p where p.oid = to_regprocedure(
       'api.start_irrigation_session_from_booking(uuid,timestamptz,uuid,text[])'
     ))
     and to_regprocedure(
       'sync.begin_booking_session_command(uuid,uuid,timestamptz,text[])'
     ) is not null
     and (select p.prosecdef from pg_proc p where p.oid = to_regprocedure(
       'sync.begin_booking_session_command(uuid,uuid,timestamptz,text[])'
     ))
     and (select p.proconfig @> array['search_path=pg_catalog, pg_temp']
          from pg_proc p where p.oid = to_regprocedure(
       'sync.begin_booking_session_command(uuid,uuid,timestamptz,text[])'
     ))
     and (select p.prosecdef from pg_proc p where p.oid = to_regprocedure(
       'ops.start_irrigation_session_from_booking(uuid,uuid,timestamptz,text[])'
     ))
     and (select p.proconfig @> array['search_path=pg_catalog, pg_temp']
          from pg_proc p where p.oid = to_regprocedure(
       'ops.start_irrigation_session_from_booking(uuid,uuid,timestamptz,text[])'
     ))
     and has_function_privilege(
       'authenticated',
       'api.start_irrigation_session_from_booking(uuid,timestamptz,uuid,text[])',
       'EXECUTE'
     )
     and has_function_privilege(
       'authenticated',
       'ops.start_irrigation_session_from_booking(uuid,uuid,timestamptz,text[])',
       'EXECUTE'
     )
     and has_function_privilege(
       'authenticated',
       'sync.begin_booking_session_command(uuid,uuid,timestamptz,text[])',
       'EXECUTE'
     )
     and not has_function_privilege(
       'anon',
       'api.start_irrigation_session_from_booking(uuid,timestamptz,uuid,text[])',
       'EXECUTE'
     )
     and not has_function_privilege(
       'anon',
       'ops.start_irrigation_session_from_booking(uuid,uuid,timestamptz,text[])',
       'EXECUTE'
     )
     and not has_function_privilege(
       'anon',
       'sync.begin_booking_session_command(uuid,uuid,timestamptz,text[])',
       'EXECUTE'
     )
     and not has_function_privilege(
       'authenticated',
       'ops.lock_session_pump_for_concurrency()',
       'EXECUTE'
     )
     and not (select p.prosecdef from pg_proc p where p.oid = to_regprocedure(
       'api.start_irrigation_session(uuid,uuid,uuid,uuid,text,timestamptz,uuid,uuid,text[])'
     ))
     and (select pg_get_userbyid(p.proowner)
          not in ('anon', 'authenticated', 'service_role')
          from pg_proc p where p.oid = to_regprocedure(
       'sync.begin_booking_session_command(uuid,uuid,timestamptz,text[])'
     ))
     and (select pg_get_userbyid(p.proowner)
          not in ('anon', 'authenticated', 'service_role')
          from pg_proc p where p.oid = to_regprocedure(
       'ops.start_irrigation_session_from_booking(uuid,uuid,timestamptz,text[])'
     ))
     then
    raise notice 'PASS C1: سطح البدء invoker وحد sync موثوق ومقيد';
  else
    raise notice 'FAIL C1: توقيع أو خاصية أمان في عقد بدء الحجز غير صحيحة';
  end if;

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  -- C2) النجاح يستخرج الحقول الحاكمة ويثبت الزمن والحد التشغيلي.
  v_command := gen_random_uuid();
  v_result := api.start_irrigation_session_from_booking(
    v_booking, v_started_at, v_command, array['ذرة', 'ذرة', '  قمح  ']
  );
  v_session := (v_result ->> 'session_id')::uuid;

  if v_result ->> 'session_status' = 'open'
     and (v_result ->> 'booking_id')::uuid = v_booking
     and (v_result ->> 'pump_id')::uuid = v_pump
     and v_result ->> 'energy_source' = 'solar'
     and v_result ->> 'alternative_energy_source' = 'well_diesel'
     and (v_result ->> 'started_at')::timestamptz = v_started_at
     and (v_result ->> 'booked_duration_minutes')::integer = 120
     and (v_result ->> 'operational_end_at')::timestamptz
           = v_started_at + interval '120 minutes'
     and exists (
       select 1 from ops.irrigation_sessions s
       where s.id = v_session
         and s.booking_id = v_booking
         and s.well_id = v_well
         and s.pump_id = v_pump
         and s.farm_id = v_farm
         and s.farmer_well_account_id = v_account
         and s.operator_profile_id = v_operator
         and s.started_at = v_started_at
         and s.status = 'open'
     )
     and (select count(*) from ops.session_crops sc
          where sc.session_id = v_session) = 2 then
    raise notice 'PASS C2: الجلسة استُخرجت من الحجز وربطت بزمن فعلي وحد صحيح';
  else
    raise notice 'FAIL C2: بيانات جلسة الحجز أو حدها التشغيلي غير صحيحة: %', v_result;
  end if;

  -- C3) replay مطابق يعيد الرد نفسه بلا جلسة أو مقطع جديد.
  select count(*) into v_count
  from ops.irrigation_sessions where booking_id = v_booking;
  select count(*) into v_count_2
  from ops.session_segments where session_id = v_session;
  v_replay := api.start_irrigation_session_from_booking(
    v_booking, v_started_at, v_command, array['ذرة', 'ذرة', '  قمح  ']
  );
  if v_replay = v_result
     and (select count(*) from ops.irrigation_sessions
          where booking_id = v_booking) = v_count
     and (select count(*) from ops.session_segments
          where session_id = v_session) = v_count_2 then
    raise notice 'PASS C3: replay مطابق أعاد الجلسة نفسها بلا كتابة جديدة';
  else
    raise notice 'FAIL C3: replay غيّر النتيجة أو كرر الكتابة';
  end if;

  -- C4) نفس المعرّف مع حمولة مختلفة مرفوض بلا كتابة.
  begin
    perform api.start_irrigation_session_from_booking(
      v_booking,
      v_started_at + interval '1 minute',
      v_command,
      array['ذرة', 'ذرة', '  قمح  ']
    );
    raise notice 'FAIL C4: قُبل command_id بحمولة مختلفة';
  exception when others then
    if position('محتوى مختلف' in sqlerrm) > 0
       and (select count(*) from ops.irrigation_sessions
            where booking_id = v_booking) = v_count then
      raise notice 'PASS C4: اختلاف الحمولة رُفض بلا جلسة إضافية';
    else
      raise notice 'FAIL C4: رفض اختلاف الحمولة غير صحيح: %', sqlerrm;
    end if;
  end;

  -- C5) command جديد للحجز المنفذ لا يصنع جلسة ثانية.
  v_rejected_command := gen_random_uuid();
  begin
    perform api.start_irrigation_session_from_booking(
      v_booking, v_started_at, v_rejected_command, null
    );
    raise notice 'FAIL C5: سُمح بجلسة ثانية من الحجز نفسه';
  exception when others then
    if position('جلسة سابقة' in sqlerrm) > 0
       and (select count(*) from ops.irrigation_sessions
            where booking_id = v_booking) = 1 then
      raise notice 'PASS C5: الحجز الواحد لم ينتج أكثر من جلسة';
    else
      raise notice 'FAIL C5: رفض الجلسة الثانية غير صحيح: %', sqlerrm;
    end if;
  end;

  -- C6) جلسة البئر المفتوحة تمنع حجزًا آخر بلا أثر جزئي.
  v_rejected_command := gen_random_uuid();
  begin
    perform api.start_irrigation_session_from_booking(
      v_blocked_booking,
      v_started_at,
      v_rejected_command,
      null
    );
    raise notice 'FAIL C6: بدأت جلسة فوق جلسة مانعة';
  exception when others then
    if position('جلسة مفتوحة' in sqlerrm) > 0
       and not exists (select 1 from ops.irrigation_sessions
                       where booking_id = v_blocked_booking) then
      raise notice 'PASS C6: الجلسة المانعة رفضت البدء بلا أثر جزئي';
    else
      raise notice 'FAIL C6: رفض الجلسة المانعة غير صحيح: %', sqlerrm;
    end if;
  end;

  -- C7) draft وmixed التاريخي لا يبدآن ولا يتركان أثرًا.
  begin
    perform api.start_irrigation_session_from_booking(
      v_draft_booking,
      v_started_at,
      gen_random_uuid(), null
    );
    raise notice 'FAIL C7: بدأ حجز غير مؤكد';
  exception when others then
    if position('غير مؤكد' in sqlerrm) > 0
       and not exists (select 1 from ops.irrigation_sessions
                       where booking_id = v_draft_booking) then
      raise notice 'PASS C7: الحجز غير المؤكد رُفض بلا جلسة';
    else
      raise notice 'FAIL C7: رفض الحجز غير المؤكد غير صحيح: %', sqlerrm;
    end if;
  end;

  begin
    perform api.start_irrigation_session_from_booking(
      v_incomplete_booking,
      v_started_at,
      gen_random_uuid(), null
    );
    raise notice 'FAIL C7: بدأ حجز ناقص/تاريخي غير جاهز';
  exception when others then
    if position('unsupported_energy_source' in sqlerrm) > 0
       and not exists (select 1 from ops.irrigation_sessions
                       where booking_id = v_incomplete_booking) then
      raise notice 'PASS C7: الحجز غير الجاهز رُفض بسبب typed بلا جلسة';
    else
      raise notice 'FAIL C7: رفض الحجز غير الجاهز غير صحيح: %', sqlerrm;
    end if;
  end;

  -- C8) غياب المضخة الفعالة مرفوض بلا أثر.
  begin
    perform api.start_irrigation_session_from_booking(
      v_no_pump_booking,
      v_started_at,
      gen_random_uuid(), null
    );
    raise notice 'FAIL C8: بدأ حجز بلا مضخة فعالة';
  exception when others then
    if position('active_pump_missing' in sqlerrm) > 0
       and not exists (select 1 from ops.irrigation_sessions
                       where booking_id = v_no_pump_booking) then
      raise notice 'PASS C8: غياب المضخة رُفض بلا أثر';
    else
      raise notice 'FAIL C8: رفض غياب المضخة غير صحيح: %', sqlerrm;
    end if;
  end;

  -- C9) المستخدم غير المخول والبئر غير المعيّن معزولان.
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  execute 'set local role authenticated';
  begin
    perform api.start_irrigation_session_from_booking(
      v_blocked_booking,
      v_started_at,
      gen_random_uuid(), null
    );
    raise notice 'FAIL C9: المستخدم غير المخول بدأ من الحجز';
  exception when others then
    if position('لا تملك وصولًا' in sqlerrm) > 0 then
      raise notice 'PASS C9: المستخدم غير المخول رُفض';
    else
      raise notice 'FAIL C9: رفض المستخدم غير المخول غير صحيح: %', sqlerrm;
    end if;
  end;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';
  begin
    perform api.start_irrigation_session_from_booking(
      v_other_booking,
      v_started_at,
      gen_random_uuid(), null
    );
    raise notice 'FAIL C9: المشغل وصل إلى بئر غير معيّن';
  exception when others then
    if position('لا تملك وصولًا' in sqlerrm) > 0
       and not exists (select 1 from ops.irrigation_sessions
                       where booking_id = v_other_booking) then
      raise notice 'PASS C9: بئر الجهة غير المعيّن معزول بلا أثر';
    else
      raise notice 'FAIL C9: عزل البئر غير صحيح: %', sqlerrm;
    end if;
  end;

  -- C10) RLS لا تكشف سجل الأمر للمشغل، وAPI القديم يبقى عاملًا.
  if (select count(*) from sync.processed_commands
      where command_id = v_command) = 0 then
    raise notice 'PASS C10: سجل الأمر غير مكشوف مباشرة للمشغل';
  else
    raise notice 'FAIL C10: RLS كشفت سجل أمر البدء للمشغل';
  end if;

  execute 'reset role';
  update ops.session_segments
  set ended_at = v_started_at + interval '45 minutes'
  where session_id = v_session and ended_at is null;
  update ops.irrigation_sessions
  set status = 'closed', ended_at = v_started_at + interval '45 minutes'
  where id = v_session;

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';
  v_free_session := api.start_irrigation_session(
    v_well, v_pump, v_farm, v_account, 'well_diesel',
    timestamptz '2026-12-07 03:00:00+00', null,
    gen_random_uuid(), array['سمسم']
  );
  if exists (
    select 1 from ops.irrigation_sessions s
    where s.id = v_free_session and s.booking_id is null and s.status = 'open'
  ) then
    raise notice 'PASS C10: مسار بدء الجلسة الحرة بقي متوافقًا';
  else
    raise notice 'FAIL C10: مسار بدء الجلسة الحرة انكسر';
  end if;

  execute 'reset role';
  if not exists (
       select 1
       from sync.processed_commands pc
       where pc.entity_id in (
         v_booking, v_draft_booking, v_incomplete_booking,
         v_blocked_booking, v_no_pump_booking, v_other_booking
       )
         and pc.status = 'processing'
     )
     and not exists (
       select 1 from ops.irrigation_sessions
       where booking_id in (
         v_draft_booking, v_incomplete_booking,
         v_blocked_booking, v_no_pump_booking, v_other_booking
       )
     ) then
    raise notice 'PASS C11: كل الرفض كان ذريًا بلا أمر أو جلسة جزئية';
  else
    raise notice 'FAIL C11: وُجد أثر جزئي بعد رفض بدء من حجز';
  end if;

  raise notice '--- انتهى اختبار M113-C: فحوص C1..C11 ---';
end
$test_c$;

-- =====================================================================
-- M113-D: عقد قراءة «جدول اليوم» (api.get_well_day_schedule).
-- اليوم الحاكم Asia/Aden، فصل الجلسة الجارية عن الحجوزات، تجميع
-- active/closed، الزمن الفعلي منفصل عن المخطط، عبور منتصف الليل،
-- عزل البئر/المستخدم، نطاق المزارع الذاتي، ولا تعديل على القراءة.
-- تواريخ ثابتة مرساة بمنطقة Asia/Aden (‎+03‎، بلا توقيت صيفي).
-- =====================================================================

do $test_d$
declare
  v_tenant uuid;
  v_well uuid;
  v_other_tenant uuid;
  v_other_well uuid;
  v_operator uuid;
  v_farmer_user uuid;
  v_person uuid;
  v_profile uuid;
  v_account uuid;
  v_farm uuid;
  v_person_b uuid;
  v_profile_b uuid;
  v_account_b uuid;
  v_farm_b uuid;
  v_other_person uuid;
  v_other_profile uuid;
  v_other_account uuid;
  v_other_farm uuid;
  v_pump uuid;
  v_other_pump uuid;
  v_bk_day uuid;
  v_bk_sess uuid;
  v_bk_day2 uuid;
  v_bk_cross uuid;
  v_bk_prev uuid;
  v_bk_next uuid;
  v_bk_completed uuid;
  v_bk_cancelled uuid;
  v_bk_postponed uuid;
  v_bk_other_account uuid;
  v_bk_other_well uuid;
  v_open_session uuid;
  v_closed_session uuid;
  v_result jsonb;
  v_items jsonb;
  v_item jsonb;
  v_bk_before bigint;
  v_bk_after bigint;
  v_sess_before bigint;
  v_sess_after bigint;
begin
  insert into core.tenants (name)
  values ('جهة اختبار جدول اليوم 113-D')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر جدول اليوم 113-D')
  returning id into v_well;

  insert into core.tenants (name)
  values ('جهة معزولة جدول اليوم 113-D')
  returning id into v_other_tenant;
  insert into core.wells (tenant_id, name)
  values (v_other_tenant, 'بئر معزول جدول اليوم 113-D')
  returning id into v_other_well;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'operator113d@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_operator;
  insert into iam.profiles (id, full_name)
  values (v_operator, 'مشغل جدول اليوم 113-D')
  on conflict (id) do nothing;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'farmer113d@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_farmer_user;
  insert into iam.profiles (id, full_name)
  values (v_farmer_user, 'مزارع جدول اليوم 113-D')
  on conflict (id) do nothing;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_operator, 'operator', 'active');

  -- المزارع A مربوط بهوية الحساب الحالية لاختبار النطاق الذاتي (م-112).
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'شخص المزارع A 113-D', 'شخص المزارع A 113-D')
  returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_profile;
  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_tenant, v_profile, v_well, 'FWA-113-D-A')
  returning id into v_account;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well, 'أرض المزارع A 113-D', v_account)
  returning id into v_farm;
  insert into iam.profile_person_links
    (tenant_id, profile_id, person_id, linked_by, link_reason)
  values (v_tenant, v_farmer_user, v_person, v_operator, 'M113-D self-scope');

  -- المزارع B على البئر نفسه: يجب ألا يراه المزارع A.
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'شخص المزارع B 113-D', 'شخص المزارع B 113-D')
  returning id into v_person_b;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person_b)
  returning id into v_profile_b;
  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_tenant, v_profile_b, v_well, 'FWA-113-D-B')
  returning id into v_account_b;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well, 'أرض المزارع B 113-D', v_account_b)
  returning id into v_farm_b;

  -- حساب على البئر المعزول لاختبار عزل البئر.
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_other_tenant, 'شخص البئر المعزول 113-D', 'شخص البئر المعزول 113-D')
  returning id into v_other_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_other_tenant, v_other_person)
  returning id into v_other_profile;
  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (v_other_tenant, v_other_profile, v_other_well, 'FWA-113-D-O')
  returning id into v_other_account;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_other_well, 'أرض البئر المعزول 113-D', v_other_account)
  returning id into v_other_farm;

  insert into core.pumps (well_id, name, power_source, status)
  values (v_well, 'مضخة جدول اليوم 113-D', 'solar', 'active')
  returning id into v_pump;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_other_well, 'مضخة البئر المعزول 113-D', 'diesel', 'active')
  returning id into v_other_pump;

  -- حجوزات يوم D = 2026-12-10 بمنطقة Asia/Aden. القيد المانع للتداخل
  -- يسري على confirmed فقط، فجُعلت فتراتها غير متداخلة على البئر.
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status, alternative_energy_source
  ) values
    (v_tenant, 'BKG-D-01', v_well, v_account, v_farm,
     timestamptz '2026-12-10 05:00:00+00', timestamptz '2026-12-10 06:00:00+00',
     60, 'solar', 'confirmed', 'well_diesel')
  returning id into v_bk_day;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-D-SESS', v_well, v_account, v_farm,
     timestamptz '2026-12-10 06:30:00+00', timestamptz '2026-12-10 07:30:00+00',
     60, 'solar', 'confirmed')
  returning id into v_bk_sess;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-D-B', v_well, v_account_b, v_farm_b,
     timestamptz '2026-12-10 08:00:00+00', timestamptz '2026-12-10 09:00:00+00',
     60, 'solar', 'confirmed')
  returning id into v_bk_other_account;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-D-02', v_well, v_account, v_farm,
     timestamptz '2026-12-10 09:30:00+00', timestamptz '2026-12-10 10:30:00+00',
     60, 'solar', 'confirmed')
  returning id into v_bk_day2;

  -- عابر لمنتصف الليل: 22:00 → 02:00 بمنطقة Asia/Aden.
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-D-CROSS', v_well, v_account, v_farm,
     timestamptz '2026-12-10 19:00:00+00', timestamptz '2026-12-10 23:00:00+00',
     240, 'solar', 'confirmed')
  returning id into v_bk_cross;

  -- مجموعة مطوية (منتهٍ/ملغى/مؤجل) في يوم D — ليست confirmed.
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-D-DONE', v_well, v_account, v_farm,
     timestamptz '2026-12-10 02:00:00+00', timestamptz '2026-12-10 03:00:00+00',
     60, 'solar', 'completed')
  returning id into v_bk_completed;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-D-CANC', v_well, v_account, v_farm,
     timestamptz '2026-12-10 02:30:00+00', timestamptz '2026-12-10 03:30:00+00',
     60, 'solar', 'cancelled')
  returning id into v_bk_cancelled;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-D-POST', v_well, v_account, v_farm,
     timestamptz '2026-12-10 04:00:00+00', timestamptz '2026-12-10 04:30:00+00',
     30, 'solar', 'postponed')
  returning id into v_bk_postponed;

  -- اليوم السابق واللاحق لاختبار اختيار التاريخ.
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-D-PREV', v_well, v_account, v_farm,
     timestamptz '2026-12-09 06:00:00+00', timestamptz '2026-12-09 07:00:00+00',
     60, 'solar', 'confirmed')
  returning id into v_bk_prev;

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-D-NEXT', v_well, v_account, v_farm,
     timestamptz '2026-12-11 06:00:00+00', timestamptz '2026-12-11 07:00:00+00',
     60, 'solar', 'confirmed')
  returning id into v_bk_next;

  -- حجز على البئر المعزول (يوم D) لاختبار عزل البئر.
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_other_tenant, 'BKG-D-OTHER', v_other_well, v_other_account, v_other_farm,
     timestamptz '2026-12-10 05:00:00+00', timestamptz '2026-12-10 06:00:00+00',
     60, 'well_diesel', 'confirmed')
  returning id into v_bk_other_well;

  -- جلسة مغلقة مرتبطة بحجز: الزمن الفعلي (session.*) منفصل عن المخطط.
  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status,
    price_per_hour_minor_snapshot, booking_id
  ) values (
    v_well, v_pump, v_farm, v_account,
    v_operator, timestamptz '2026-12-10 06:35:00+00',
    timestamptz '2026-12-10 07:40:00+00', 'closed', 5000, v_bk_sess
  ) returning id into v_closed_session;

  -- جلسة جارية (open) تخص المزارع A — تُعرض أولًا ومنفصلة عن الحجوزات.
  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, status,
    price_per_hour_minor_snapshot
  ) values (
    v_well, v_pump, v_farm, v_account,
    v_operator, timestamptz '2026-12-10 10:00:00+00', 'open', 5000
  ) returning id into v_open_session;

  select count(*) into v_bk_before
  from ops.irrigation_bookings where well_id in (v_well, v_other_well);
  select count(*) into v_sess_before
  from ops.irrigation_sessions where well_id in (v_well, v_other_well);

  -- =================================================================
  -- D1) سطح العقد: api invoker، GRANT للعميل، وبلا دالة مساعدة في ops
  --     تحتاج GRANT (النافذة محسوبة سطريًا داخل الغلاف).
  -- =================================================================
  if to_regprocedure('api.get_well_day_schedule(uuid,date)') is not null
     and not (select p.prosecdef from pg_proc p
              where p.oid = to_regprocedure('api.get_well_day_schedule(uuid,date)'))
     and has_function_privilege(
       'authenticated', 'api.get_well_day_schedule(uuid,date)', 'EXECUTE')
     and not has_function_privilege(
       'anon', 'api.get_well_day_schedule(uuid,date)', 'EXECUTE')
     and to_regprocedure('ops.aden_day_window(date)') is null
  then
    raise notice 'PASS D1: العقد invoker ومُتاح للعميل بلا مساعد ops يحتاج GRANT';
  else
    raise notice 'FAIL D1: توقيع/أمان عقد جدول اليوم غير صحيح أو مساعد النافذة ما زال قائمًا';
  end if;

  -- =================================================================
  -- D2) اليوم الحاكم Asia/Aden: نافذة ثابتة + اشتقاق الافتراضي من الآن.
  --     النافذة تُحسب هنا بنفس تعبير الغلاف (بلا دالة مساعدة).
  -- =================================================================
  if lower(tstzrange(
         (date '2026-12-10'::timestamp) at time zone 'Asia/Aden',
         ((date '2026-12-10' + 1)::timestamp) at time zone 'Asia/Aden',
         '[)'))
       = timestamptz '2026-12-09 21:00:00+00'
     and upper(tstzrange(
         (date '2026-12-10'::timestamp) at time zone 'Asia/Aden',
         ((date '2026-12-10' + 1)::timestamp) at time zone 'Asia/Aden',
         '[)'))
       = timestamptz '2026-12-10 21:00:00+00'
  then
    raise notice 'PASS D2a: نافذة اليوم [00:00,24:00) بمنطقة Asia/Aden صحيحة';
  else
    raise notice 'FAIL D2a: حدود نافذة اليوم بمنطقة Asia/Aden غير صحيحة';
  end if;

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  -- D2b) غياب التاريخ ⇒ اليوم الحالي حسب Asia/Aden، لا منطقة الاتصال.
  v_result := api.get_well_day_schedule(v_well, null);
  if v_result ->> 'timezone' = 'Asia/Aden'
     and v_result ->> 'requested_day'
         = (now() at time zone 'Asia/Aden')::date::text
     and (v_result -> 'well_timezone') is not null
  then
    raise notice 'PASS D2b: التاريخ الافتراضي يُشتق من الآن بمنطقة Asia/Aden';
  else
    raise notice 'FAIL D2b: التاريخ الافتراضي لا يتبع Asia/Aden: %', v_result;
  end if;

  -- D3) اختيار التاريخ: اليوم/السابق/اللاحق يعيد حجوزات يومه فقط.
  v_result := api.get_well_day_schedule(v_well, date '2026-12-10');
  v_items := v_result -> 'bookings';
  if v_result ->> 'requested_day' = '2026-12-10'
     and exists (select 1 from jsonb_array_elements(v_items) e
                 where e ->> 'public_code' = 'BKG-D-01')
     and not exists (select 1 from jsonb_array_elements(v_items) e
                     where e ->> 'public_code' in ('BKG-D-PREV','BKG-D-NEXT'))
  then
    raise notice 'PASS D3a: يوم D يعيد حجوزاته دون السابق أو اللاحق';
  else
    raise notice 'FAIL D3a: نطاق يوم D غير صحيح';
  end if;

  v_result := api.get_well_day_schedule(v_well, date '2026-12-09');
  v_items := v_result -> 'bookings';
  if exists (select 1 from jsonb_array_elements(v_items) e
             where e ->> 'public_code' = 'BKG-D-PREV')
     and not exists (select 1 from jsonb_array_elements(v_items) e
                     where e ->> 'public_code' = 'BKG-D-01')
  then
    raise notice 'PASS D3b: اليوم السابق يعيد حجزه فقط';
  else
    raise notice 'FAIL D3b: نطاق اليوم السابق غير صحيح';
  end if;

  v_result := api.get_well_day_schedule(v_well, date '2026-12-11');
  v_items := v_result -> 'bookings';
  if exists (select 1 from jsonb_array_elements(v_items) e
             where e ->> 'public_code' = 'BKG-D-NEXT')
     and not exists (select 1 from jsonb_array_elements(v_items) e
                     where e ->> 'public_code' = 'BKG-D-01')
  then
    raise notice 'PASS D3c: اليوم اللاحق يعيد حجزه فقط';
  else
    raise notice 'FAIL D3c: نطاق اليوم اللاحق غير صحيح';
  end if;

  -- D4) الجلسة الجارية منفصلة وأولًا، والحجوزات الفعّالة مرتبة بالبدء.
  v_result := api.get_well_day_schedule(v_well, date '2026-12-10');
  v_items := v_result -> 'bookings';
  v_item := v_items -> 0;
  if (v_result -> 'current_session' ->> 'session_id')::uuid = v_open_session
     and v_result -> 'current_session' ->> 'status' = 'open'
     and (v_result -> 'current_session' -> 'booking_id') = 'null'::jsonb
     and v_item ->> 'public_code' = 'BKG-D-01'
     and v_item ->> 'status_group' = 'active'
  then
    raise notice 'PASS D4: الجلسة الجارية منفصلة أولًا والفعّالة مرتبة بالبدء';
  else
    raise notice 'FAIL D4: فصل الجلسة الجارية أو ترتيب الفعّالة غير صحيح: %',
      v_result -> 'current_session';
  end if;

  -- D5) المنتهي/الملغى/المؤجل مجموعة closed تلي كل الفعّالة.
  if (select e ->> 'status_group'
      from jsonb_array_elements(v_items) with ordinality as t(e, ord)
      where e ->> 'public_code' = 'BKG-D-DONE') = 'closed'
     and (select e ->> 'status_group'
          from jsonb_array_elements(v_items) with ordinality as t(e, ord)
          where e ->> 'public_code' = 'BKG-D-CANC') = 'closed'
     and (select e ->> 'status_group'
          from jsonb_array_elements(v_items) with ordinality as t(e, ord)
          where e ->> 'public_code' = 'BKG-D-POST') = 'closed'
     and (select min(ord)
          from jsonb_array_elements(v_items) with ordinality as t(e, ord)
          where e ->> 'status_group' = 'closed')
       > (select max(ord)
          from jsonb_array_elements(v_items) with ordinality as t(e, ord)
          where e ->> 'status_group' = 'active')
  then
    raise notice 'PASS D5: المجموعة المطوية closed تلي كل الحجوزات الفعّالة';
  else
    raise notice 'FAIL D5: تجميع/ترتيب المجموعة المطوية غير صحيح';
  end if;

  -- D6) الزمن الفعلي (session.*) منفصل عن المخطط (scheduled_*)، بلا دمج.
  select e into v_item
  from jsonb_array_elements(v_items) e
  where e ->> 'public_code' = 'BKG-D-SESS';
  if (v_item -> 'session' ->> 'session_id')::uuid = v_closed_session
     and v_item -> 'session' ->> 'status' = 'closed'
     and (v_item -> 'session' ->> 'started_at')::timestamptz
         = timestamptz '2026-12-10 06:35:00+00'
     and (v_item -> 'session' ->> 'ended_at')::timestamptz
         = timestamptz '2026-12-10 07:40:00+00'
     and (v_item ->> 'scheduled_start')::timestamptz
         = timestamptz '2026-12-10 06:30:00+00'
     and (v_item ->> 'scheduled_start')::timestamptz
         <> (v_item -> 'session' ->> 'started_at')::timestamptz
  then
    raise notice 'PASS D6: الزمن الفعلي للجلسة منفصل عن المخطط للحجز';
  else
    raise notice 'FAIL D6: خلط الزمن الفعلي بالمخطط أو ربط الجلسة غير صحيح: %',
      v_item;
  end if;

  -- D7) حجز مؤكد لم يبدأ: session = null (لا اختلاق لحالة تنفيذ غائبة).
  select e into v_item
  from jsonb_array_elements(v_items) e
  where e ->> 'public_code' = 'BKG-D-01';
  if (v_item -> 'session') = 'null'::jsonb
     and v_item ->> 'status_group' = 'active'
     and v_item ->> 'status' = 'confirmed'
  then
    raise notice 'PASS D7: حجز مؤكد بلا جلسة يعيد session=null دون اختلاق';
  else
    raise notice 'FAIL D7: حجز مؤكد بلا جلسة اختلق حالة تنفيذ: %', v_item;
  end if;

  -- D8) عبور منتصف الليل: الحجز العابر يظهر في اليوم وفي اليوم التالي.
  v_result := api.get_well_day_schedule(v_well, date '2026-12-11');
  if exists (select 1 from jsonb_array_elements(v_items) e
             where e ->> 'public_code' = 'BKG-D-CROSS')
     and exists (select 1
                 from jsonb_array_elements(v_result -> 'bookings') e
                 where e ->> 'public_code' = 'BKG-D-CROSS')
  then
    raise notice 'PASS D8: الحجز العابر لمنتصف الليل يظهر في اليومين';
  else
    raise notice 'FAIL D8: الحجز العابر لمنتصف الليل لم يظهر في اليومين';
  end if;

  -- D9) عزل البئر: نتيجة v_well لا تحوي حجز بئر آخر، والوصول لبئر غير
  -- مُسنَد يُرفض بـ 42501 بالرسالة نفسها دون كشف وجود البيانات.
  if not exists (select 1 from jsonb_array_elements(v_items) e
                 where e ->> 'public_code' = 'BKG-D-OTHER')
  then
    raise notice 'PASS D9a: جدول البئر لا يتسرب إليه حجز بئر آخر';
  else
    raise notice 'FAIL D9a: تسرب حجز بئر آخر إلى الجدول';
  end if;

  begin
    perform api.get_well_day_schedule(v_other_well, date '2026-12-10');
    raise notice 'FAIL D9b: سُمح بقراءة جدول بئر غير مُسنَد للمشغل';
  exception
    when sqlstate '42501' then
      raise notice 'PASS D9b: قراءة بئر غير مُسنَد رُفضت بـ 42501';
    when others then
      raise notice 'FAIL D9b: رفض بئر غير مُسنَد بخطأ غير متوقع: %', sqlerrm;
  end;

  -- D10) نطاق المزارع الذاتي (م-112): المزارع A يرى حجوزاته وجلسته فقط.
  perform set_config('request.jwt.claim.sub', v_farmer_user::text, true);
  v_result := api.get_well_day_schedule(v_well, date '2026-12-10');
  v_items := v_result -> 'bookings';
  if exists (select 1 from jsonb_array_elements(v_items) e
             where e ->> 'public_code' = 'BKG-D-01')
     and not exists (select 1 from jsonb_array_elements(v_items) e
                     where e ->> 'public_code' = 'BKG-D-B')
     and (v_result -> 'current_session' ->> 'session_id')::uuid = v_open_session
  then
    raise notice 'PASS D10: المزارع يرى حجوزاته وجلسته الجارية فقط دون غيره';
  else
    raise notice 'FAIL D10: نطاق المزارع الذاتي تسرب أو حجب خطأً: %', v_items;
  end if;

  -- D11) قراءة بلا تعديل: أعداد الحجوزات والجلسات لم تتغيّر.
  execute 'reset role';
  select count(*) into v_bk_after
  from ops.irrigation_bookings where well_id in (v_well, v_other_well);
  select count(*) into v_sess_after
  from ops.irrigation_sessions where well_id in (v_well, v_other_well);
  if v_bk_after = v_bk_before and v_sess_after = v_sess_before then
    raise notice 'PASS D11: القراءة لم تُحدث أي تغيير على الحجوزات أو الجلسات';
  else
    raise notice 'FAIL D11: تغيّرت الأعداد بعد القراءة (bk %/% sess %/%)',
      v_bk_after, v_bk_before, v_sess_after, v_sess_before;
  end if;

  raise notice '--- انتهى اختبار M113-D: فحوص D1..D11 ---';
end
$test_d$;

-- ==============================================================
-- M113-T: سلامة زمن البداية الفعلي — حارس المستقبل في مسار الحجز
--   ق-132 و)/ز) + الثابتان 748/753: الزمن الفعلي حقيقة لا تُختلق،
--   ولا تُنسب للجلسة بداية لم تحدث. الحد الأعلى الوحيد المُثبَت خادميًا
--   هو clock_timestamp()؛ أي حد أدنى (Offline) فجوة سياسة لم تُعتمد بعد.
-- ==============================================================
do $test_t$
declare
  v_tenant uuid;
  v_well uuid;
  v_operator uuid;
  v_person uuid;
  v_profile uuid;
  v_account uuid;
  v_farm uuid;
  v_pump uuid;
  v_booking uuid;
  v_command uuid;
  v_future_command uuid;
  v_result jsonb;
  v_replay jsonb;
  v_session uuid;
  v_count bigint;
  v_count_2 bigint;
  -- الآن مُقتطع للدقيقة: البدء الفعلي ≤ الآن دائمًا، والحجز مجدول غدًا
  -- فالبدء هنا بدء يدوي مبكر مشروع (ق-132: يجوز قبل الموعد المجدول).
  v_now timestamptz := date_trunc('minute', clock_timestamp());
begin
  insert into core.tenants (name)
  values ('جهة اختبار سلامة الزمن 113-T')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر سلامة الزمن 113-T')
  returning id into v_well;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'operator113t@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_operator;
  insert into iam.profiles (id, full_name)
  values (v_operator, 'مشغل اختبار 113-T')
  on conflict (id) do nothing;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_operator, 'operator', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع سلامة الزمن 113-T', 'مزارع سلامة الزمن 113-T')
  returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_profile;
  insert into ops.farmer_well_accounts (
    tenant_id, farmer_profile_id, well_id, public_code
  ) values (
    v_tenant, v_profile, v_well, 'FWA-113-T'
  ) returning id into v_account;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well, 'أرض سلامة الزمن 113-T', v_account)
  returning id into v_farm;

  -- مضخة فعالة واحدة فقط: شرط جاهزية التنفيذ (فهرس 106 الوحيد الفعال).
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well, 'مضخة سلامة الزمن 113-T', 'diesel', 'active')
  returning id into v_pump;

  insert into billing.well_pricing
    (well_id, price_per_hour_minor, period_start)
  values (v_well, 5000, date '2026-01-01');

  -- حجز مؤكّد بطاقة ديزل البئر: جاهز بلا توقيت نافذة شمسية، مجدول غدًا
  -- حتى يكون البدء الآن بدءًا يدويًا مبكرًا مشروعًا لا تنفيذًا متأخرًا.
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (
    v_tenant, 'BKG-113-T-OK', v_well, v_account, v_farm,
    v_now + interval '1 day',
    v_now + interval '1 day' + interval '90 minutes', 90,
    'well_diesel', 'confirmed'
  ) returning id into v_booking;

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  -- T1) زمن بداية في المستقبل مرفوض بلا جلسة ولا سجل أمر (رفض ذرّي).
  --     الخادم يُثبت باستحالة بداية لم تقع بعد؛ المعاملة الواحدة تُرجِع
  --     إدراج سجل الأمر مع الاستثناء فلا أثر جزئي.
  v_future_command := gen_random_uuid();
  begin
    perform api.start_irrigation_session_from_booking(
      v_booking, v_now + interval '1 day', v_future_command, null
    );
    raise notice 'FAIL T1: قُبل زمن بداية في المستقبل';
  exception when others then
    if position('المستقبل' in sqlerrm) > 0
       and not exists (select 1 from ops.irrigation_sessions
                       where booking_id = v_booking)
       and (select count(*) from sync.processed_commands
            where command_id = v_future_command) = 0 then
      raise notice 'PASS T1: زمن المستقبل رُفض بلا جلسة ولا سجل أمر';
    else
      raise notice 'FAIL T1: رفض المستقبل غير ذرّي أو برسالة غير متوقعة: %', sqlerrm;
    end if;
  end;

  -- T2) بدء يدوي مبكر مشروع بزمن فعلي ≤ الآن ينجح ويربط بالحجز.
  v_command := gen_random_uuid();
  v_result := api.start_irrigation_session_from_booking(
    v_booking, v_now, v_command, null
  );
  v_session := (v_result ->> 'session_id')::uuid;
  if v_result ->> 'session_status' = 'open'
     and (v_result ->> 'booking_id')::uuid = v_booking
     and (v_result ->> 'started_at')::timestamptz = v_now
     and exists (
       select 1 from ops.irrigation_sessions s
       where s.id = v_session
         and s.booking_id = v_booking
         and s.started_at = v_now
         and s.status = 'open'
     ) then
    raise notice 'PASS T2: بدء يدوي مبكر بزمن فعلي صحيح نجح وربط بالحجز';
  else
    raise notice 'FAIL T2: بدء الزمن الفعلي الصحيح فشل أو لم يربط: %', v_result;
  end if;

  -- T3) الحد التشغيلي = الزمن الفعلي + المدة المحجوزة (لا اختلاق زمن).
  if (v_result ->> 'booked_duration_minutes')::integer = 90
     and (v_result ->> 'operational_end_at')::timestamptz
           = v_now + interval '90 minutes' then
    raise notice 'PASS T3: الحد التشغيلي اشتُقّ من الزمن الفعلي والمدة';
  else
    raise notice 'FAIL T3: الحد التشغيلي غير مشتق من الزمن الفعلي: %', v_result;
  end if;

  -- T4) replay مطابق يعيد النتيجة نفسها بلا جلسة أو مقطع جديد ولا تغيير
  --     للزمن المخزَّن.
  select count(*) into v_count
  from ops.irrigation_sessions where booking_id = v_booking;
  select count(*) into v_count_2
  from ops.session_segments where session_id = v_session;
  v_replay := api.start_irrigation_session_from_booking(
    v_booking, v_now, v_command, null
  );
  if v_replay = v_result
     and (select count(*) from ops.irrigation_sessions
          where booking_id = v_booking) = v_count
     and (select count(*) from ops.session_segments
          where session_id = v_session) = v_count_2 then
    raise notice 'PASS T4: replay مطابق أعاد الزمن نفسه بلا كتابة جديدة';
  else
    raise notice 'FAIL T4: replay غيّر الزمن أو كرر الكتابة';
  end if;

  -- T5) نفس المعرّف بزمن مختلف (غير مستقبلي) مرفوض بلا جلسة إضافية:
  --     حارس المحتوى يسبق، فلا يُستبدل الزمن المخزَّن ولا يُعاد الكتابة.
  begin
    perform api.start_irrigation_session_from_booking(
      v_booking, v_now - interval '1 minute', v_command, null
    );
    raise notice 'FAIL T5: قُبل زمن مختلف لنفس المعرّف';
  exception when others then
    if position('محتوى مختلف' in sqlerrm) > 0
       and (select count(*) from ops.irrigation_sessions
            where booking_id = v_booking) = v_count then
      raise notice 'PASS T5: اختلاف الزمن لنفس المعرّف رُفض بلا جلسة إضافية';
    else
      raise notice 'FAIL T5: رفض اختلاف الزمن غير صحيح: %', sqlerrm;
    end if;
  end;

  execute 'reset role';
  raise notice '--- انتهى اختبار M113-T: فحوص T1..T5 ---';
end
$test_t$;

-- ==============================================================
-- M113-E1: مُقيّم حالة انتقال الحجوزات — قراءة فقط للعرض والقرار.
--   يثبت تمثيل الحالات (ق-132 §و + الثوابت 748-753 و252/253): جلسة
--   جارية، الحجز التالي المؤكد وترتيبه، الاستحقاق مقابل المستقبل،
--   الانتقال الآمن المشروط، الجلسة المانعة، البدء اليدوي الأول، وأن
--   «بلوغ الموعد» ليس إذنًا ببداية فعلية؛ مع عزل الصلاحيات وبلا كتابة.
-- ==============================================================
do $test_e$
declare
  v_tenant uuid;
  v_person uuid;
  v_profile uuid;
  v_operator uuid;
  v_outsider uuid;
  v_well_a uuid;
  v_well_g uuid;
  v_well_n uuid;
  v_well_b uuid;
  v_well_c uuid;
  v_well_d uuid;
  v_well_e uuid;
  v_well_iso uuid;
  v_acc uuid;
  v_farm uuid;
  v_pump uuid;
  v_bk1 uuid;
  v_now timestamptz := date_trunc('minute', clock_timestamp());
  v_started_b timestamptz;
  v_res jsonb;
  v_sess_before bigint;
  v_bk_before bigint;
  v_sess_after bigint;
  v_bk_after bigint;
begin
  insert into core.tenants (name)
  values ('جهة اختبار انتقال الحجز 113-E') returning id into v_tenant;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع انتقال 113-E', 'مزارع انتقال 113-E')
  returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_profile;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'operator113e@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_operator;
  insert into iam.profiles (id, full_name)
  values (v_operator, 'مشغل 113-E') on conflict (id) do nothing;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'outsider113e@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_outsider;
  insert into iam.profiles (id, full_name)
  values (v_outsider, 'غريب 113-E') on conflict (id) do nothing;

  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر E-A') returning id into v_well_a;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر E-G') returning id into v_well_g;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر E-N') returning id into v_well_n;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر E-B') returning id into v_well_b;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر E-C') returning id into v_well_c;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر E-D') returning id into v_well_d;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر E-E') returning id into v_well_e;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر E-ISO') returning id into v_well_iso;

  -- المشغل معيّن على كل الآبار عدا ISO (عزل البئر غير المعيّن).
  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well_a, v_operator, 'operator', 'active'),
    (v_well_g, v_operator, 'operator', 'active'),
    (v_well_n, v_operator, 'operator', 'active'),
    (v_well_b, v_operator, 'operator', 'active'),
    (v_well_c, v_operator, 'operator', 'active'),
    (v_well_d, v_operator, 'operator', 'active'),
    (v_well_e, v_operator, 'operator', 'active');

  -- بئر A: بلا جلسة، حجزان مؤكدان غير مبدوءين — مستحق (now-10m) ومستقبلي
  -- (now+1d). الأبكر = المستحق فيثبت الترتيب والاستحقاق والبدء اليدوي.
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_a, 'FWA-E-A') returning id into v_acc;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-E-A-DUE', v_well_a, v_acc,
     v_now - interval '10 minutes', v_now + interval '50 minutes', 60,
     'well_diesel', 'confirmed'),
    (v_tenant, 'BKG-E-A-FUT', v_well_a, v_acc,
     v_now + interval '1 day', v_now + interval '1 day 1 hour', 60,
     'well_diesel', 'confirmed');

  -- بئر G: بلا جلسة، حجز مؤكد مستقبلي وحيد (now+2h) — بدء يدوي بانتظار
  -- الموعد (منتظر الجدولة، لا إذن).
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_g, 'FWA-E-G') returning id into v_acc;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-E-G-FUT', v_well_g, v_acc,
     v_now + interval '2 hours', v_now + interval '3 hours', 60,
     'well_diesel', 'confirmed');

  -- بئر N: بلا جلسة وبلا حجوزات — لا حجز تالٍ.

  perform set_config('request.jwt.claim.sub', v_operator::text, true);

  -- بئر B: جلسة محجوزة بلغت حدها الفعلي + حجز تالٍ مستحق → انتقال آمن.
  --   b1 مدته 5د بدأ قبل 20د (بدء مبكر مشروع) فحدّه now-15m ماضٍ، بينما
  --   scheduled_end مستقبلي: يثبت 748 (الحد = البداية الفعلية + المدة لا
  --   scheduled_end). b2 مستحق (now-2m).
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_b, 'FWA-E-B') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_b, 'أرض E-B', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_b, 'مضخة E-B', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_b, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-E-B1', v_well_b, v_acc, v_farm,
     v_now + interval '1 hour', v_now + interval '3 hours', 5,
     'well_diesel', 'confirmed') returning id into v_bk1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-E-B2', v_well_b, v_acc, v_farm,
     v_now - interval '2 minutes', v_now + interval '58 minutes', 60,
     'well_diesel', 'confirmed');
  v_started_b := v_now - interval '20 minutes';
  execute 'set local role authenticated';
  perform api.start_irrigation_session_from_booking(
    v_bk1, v_started_b, gen_random_uuid(), null
  );
  execute 'reset role';

  -- بئر C: جلسة محجوزة بلغت حدها + حجز تالٍ مستقبلي → قرار «تشغيل الآن/
  --   انتظار» (استحقاق مستقبلي لا إذن تلقائي). c1 مدته 5د بدأ قبل 20د،
  --   c2 مستقبلي (now+1d).
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_c, 'FWA-E-C') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_c, 'أرض E-C', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_c, 'مضخة E-C', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_c, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-E-C1', v_well_c, v_acc, v_farm,
     v_now + interval '1 hour', v_now + interval '3 hours', 5,
     'well_diesel', 'confirmed') returning id into v_bk1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-E-C2', v_well_c, v_acc, v_farm,
     v_now + interval '1 day', v_now + interval '1 day 1 hour', 60,
     'well_diesel', 'confirmed');
  execute 'set local role authenticated';
  perform api.start_irrigation_session_from_booking(
    v_bk1, v_now - interval '20 minutes', gen_random_uuid(), null
  );
  execute 'reset role';

  -- بئر D: جلسة محجوزة لم تبلغ حدها + حجز تالٍ مستحق → مانعة (751:
  --   إنذار وتدخل، لا بدء فوقها). d1 نافذته 120د [now-121m,now-1m) تطابق
  --   expected_duration_minutes؛ بدأ داخلها (now-2m) فحدّه الفعلي now+118m
  --   يمتد بعد نهاية النافذة. d2 مستحق. نافذتا d1 وd2 [now-1m,now+59m)
  --   متلاصقتان نصف مفتوحتين فلا تتعارضان مع قيد عدم تداخل المؤكد.
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_d, 'FWA-E-D') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_d, 'أرض E-D', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_d, 'مضخة E-D', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_d, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-E-D1', v_well_d, v_acc, v_farm,
     v_now - interval '121 minutes', v_now - interval '1 minute', 120,
     'well_diesel', 'confirmed') returning id into v_bk1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-E-D2', v_well_d, v_acc, v_farm,
     v_now - interval '1 minute', v_now + interval '59 minutes', 60,
     'well_diesel', 'confirmed');
  execute 'set local role authenticated';
  perform api.start_irrigation_session_from_booking(
    v_bk1, v_now - interval '2 minutes', gen_random_uuid(), null
  );
  execute 'reset role';

  -- بئر E: جلسة حرة/عابرة مفتوحة (booking_id null، بلا حد محجوز) + حجز
  --   تالٍ مستحق → مانعة عابرة (751): لا حد يُختلق، والتالي منتظر.
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_e, 'FWA-E-E') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_e, 'أرض E-E', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_e, 'مضخة E-E', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_e, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-E-E1', v_well_e, v_acc, v_farm,
     v_now - interval '1 minute', v_now + interval '59 minutes', 60,
     'well_diesel', 'confirmed');
  execute 'set local role authenticated';
  perform api.start_irrigation_session(
    v_well_e, v_pump, v_farm, v_acc, 'well_diesel',
    v_now - interval '5 minutes', null, gen_random_uuid(), null
  );
  execute 'reset role';

  -- لقطة قبل التقييم: التقييم قراءة فقط فلا يغيّر هذه الأعداد.
  select count(*) into v_sess_before from ops.irrigation_sessions
  where well_id in (v_well_a, v_well_g, v_well_n, v_well_b,
                    v_well_c, v_well_d, v_well_e, v_well_iso);
  select count(*) into v_bk_before from ops.irrigation_bookings
  where well_id in (v_well_a, v_well_g, v_well_n, v_well_b,
                    v_well_c, v_well_d, v_well_e, v_well_iso);

  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  execute 'set local role authenticated';

  -- E1) بئر A: بلا جلسة، التالي الأبكر هو المستحق → بدء يدوي، والموعد
  --     ليس إذنًا؛ ويثبت ترتيب الحجز التالي (المستحق قبل المستقبلي).
  v_res := api.evaluate_well_booking_transition(v_well_a);
  if v_res ->> 'decision' = 'manual_start_required'
     and (v_res ->> 'requires_manual_start')::boolean
     and not (v_res ->> 'safe_to_auto_start')::boolean
     and not (v_res ->> 'has_open_session')::boolean
     and v_res ->> 'current_session' is null
     and v_res -> 'next_booking' ->> 'public_code' = 'BKG-E-A-DUE'
     and v_res -> 'next_booking' ->> 'timing' = 'due'
     and (v_res -> 'next_booking' ->> 'is_overdue')::boolean
     and v_res ->> 'reason_code' = 'manual_start_pending_due' then
    raise notice 'PASS E1: بلا جلسة + مستحق → بدء يدوي والموعد ليس إذنًا، والترتيب صحيح';
  else
    raise notice 'FAIL E1: حالة بئر A غير متوقعة: %', v_res;
  end if;

  -- E2) بئر G: بلا جلسة + تالٍ مستقبلي → بدء يدوي بانتظار الموعد.
  v_res := api.evaluate_well_booking_transition(v_well_g);
  if v_res ->> 'decision' = 'manual_start_required'
     and v_res -> 'next_booking' ->> 'timing' = 'future'
     and not (v_res -> 'next_booking' ->> 'is_overdue')::boolean
     and v_res ->> 'reason_code' = 'manual_start_awaiting_schedule' then
    raise notice 'PASS E2: تالٍ مستقبلي بلا جلسة → بدء يدوي بانتظار الموعد';
  else
    raise notice 'FAIL E2: حالة بئر G غير متوقعة: %', v_res;
  end if;

  -- E3) بئر N: بلا جلسة وبلا حجز تالٍ → لا حجز تالٍ.
  v_res := api.evaluate_well_booking_transition(v_well_n);
  if v_res ->> 'decision' = 'no_next_booking'
     and v_res ->> 'next_booking' is null
     and not (v_res ->> 'has_open_session')::boolean
     and v_res ->> 'current_session' is null then
    raise notice 'PASS E3: بئر بلا جلسة وبلا حجز تالٍ أعاد نتيجة واضحة';
  else
    raise notice 'FAIL E3: حالة بئر N غير متوقعة: %', v_res;
  end if;

  -- E4) بئر B: جلسة محجوزة بلغت حدها + مستحق → أهلية توقيت للانتقال، لا إذن
  --     تلقائي (E2-d: safe_to_auto_start محافظ false، الجاهزية تُفحَص ذريًا)،
  --     والحد = البداية الفعلية + المدة لا scheduled_end (748).
  v_res := api.evaluate_well_booking_transition(v_well_b);
  if v_res ->> 'decision' = 'transition_ready'
     and (v_res ->> 'transition_timing_eligible')::boolean
     and not (v_res ->> 'safe_to_auto_start')::boolean
     and (v_res ->> 'requires_atomic_recheck')::boolean
     and (v_res ->> 'advisory_only')::boolean
     and not (v_res ->> 'requires_user_decision')::boolean
     and not (v_res ->> 'requires_manual_start')::boolean
     and (v_res -> 'current_session' ->> 'is_booked')::boolean
     and (v_res -> 'current_session' ->> 'reached_operational_end')::boolean
     and (v_res -> 'current_session' ->> 'operational_end_at')::timestamptz
           = v_started_b + interval '5 minutes'
     and v_res -> 'next_booking' ->> 'public_code' = 'BKG-E-B2'
     and v_res -> 'next_booking' ->> 'timing' = 'due'
     and v_res ->> 'reason_code' = 'current_reached_end_next_due' then
    raise notice 'PASS E4: بلغ الحد + مستحق → أهلية توقيت لا إذن تلقائي (محافظ)';
  else
    raise notice 'FAIL E4: حالة بئر B غير متوقعة: %', v_res;
  end if;

  -- E5) بئر C: جلسة بلغت حدها + تالٍ مستقبلي → قرار تشغيل الآن/انتظار.
  v_res := api.evaluate_well_booking_transition(v_well_c);
  if v_res ->> 'decision' = 'decision_required_run_now_or_wait'
     and (v_res ->> 'requires_user_decision')::boolean
     and not (v_res ->> 'safe_to_auto_start')::boolean
     and (v_res -> 'current_session' ->> 'reached_operational_end')::boolean
     and v_res -> 'next_booking' ->> 'timing' = 'future'
     and v_res ->> 'reason_code' = 'current_reached_end_next_future' then
    raise notice 'PASS E5: جلسة بلغت حدها + مستقبلي → قرار صريح لا إذن تلقائي';
  else
    raise notice 'FAIL E5: حالة بئر C غير متوقعة: %', v_res;
  end if;

  -- E6) بئر D: جلسة لم تبلغ حدها + مستحق → مانعة (تدخل مستخدم).
  v_res := api.evaluate_well_booking_transition(v_well_d);
  if v_res ->> 'decision' = 'blocked_by_open_session'
     and (v_res ->> 'requires_user_decision')::boolean
     and not (v_res -> 'current_session' ->> 'reached_operational_end')::boolean
     and v_res -> 'next_booking' ->> 'timing' = 'due'
     and v_res ->> 'reason_code' = 'current_session_active_blocks_due_next' then
    raise notice 'PASS E6: جلسة لم تبلغ حدها + مستحق → مانعة بلا بدء فوقها';
  else
    raise notice 'FAIL E6: حالة بئر D غير متوقعة: %', v_res;
  end if;

  -- E7) بئر E: جلسة حرة/عابرة + مستحق → مانعة عابرة، لا حد مُختلق.
  v_res := api.evaluate_well_booking_transition(v_well_e);
  if v_res ->> 'decision' = 'blocked_by_open_session'
     and not (v_res -> 'current_session' ->> 'is_booked')::boolean
     and v_res -> 'current_session' ->> 'reached_operational_end' is null
     and v_res -> 'current_session' ->> 'operational_end_at' is null
     and v_res -> 'next_booking' ->> 'timing' = 'due'
     and v_res ->> 'reason_code' = 'transient_session_blocks_due_next' then
    raise notice 'PASS E7: جلسة عابرة حرة + مستحق → مانعة بلا اختلاق حد';
  else
    raise notice 'FAIL E7: حالة بئر E غير متوقعة: %', v_res;
  end if;

  -- E8) عزل الصلاحية: غريب بلا تعيين يُرفض عن تقييم حالة بئر لغيره.
  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  begin
    perform api.evaluate_well_booking_transition(v_well_a);
    raise notice 'FAIL E8: غريب قيّم حالة بئر لا يملكه';
  exception when others then
    if position('صلاحية' in sqlerrm) > 0 then
      raise notice 'PASS E8: الغريب مرفوض عن تقييم حالة البئر';
    else
      raise notice 'FAIL E8: رفض الغريب غير متوقع: %', sqlerrm;
    end if;
  end;

  -- E9) عزل البئر: مشغل غير معيّن على ISO يُرفض.
  perform set_config('request.jwt.claim.sub', v_operator::text, true);
  begin
    perform api.evaluate_well_booking_transition(v_well_iso);
    raise notice 'FAIL E9: المشغل قيّم بئرًا غير معيّن عليه';
  exception when others then
    if position('صلاحية' in sqlerrm) > 0 then
      raise notice 'PASS E9: بئر غير معيّن معزول عن التقييم';
    else
      raise notice 'FAIL E9: عزل البئر غير متوقع: %', sqlerrm;
    end if;
  end;

  execute 'reset role';

  -- E10) لا كتابة: التقييم قراءة فقط فلم تتغير أعداد الجلسات والحجوزات.
  select count(*) into v_sess_after from ops.irrigation_sessions
  where well_id in (v_well_a, v_well_g, v_well_n, v_well_b,
                    v_well_c, v_well_d, v_well_e, v_well_iso);
  select count(*) into v_bk_after from ops.irrigation_bookings
  where well_id in (v_well_a, v_well_g, v_well_n, v_well_b,
                    v_well_c, v_well_d, v_well_e, v_well_iso);
  if v_sess_after = v_sess_before and v_bk_after = v_bk_before then
    raise notice 'PASS E10: التقييم قراءة فقط — لا جلسة ولا حجز جديد';
  else
    raise notice 'FAIL E10: التقييم غيّر الأعداد (sess %/% bk %/%)',
      v_sess_after, v_sess_before, v_bk_after, v_bk_before;
  end if;

  raise notice '--- انتهى اختبار M113-E1: فحوص E1..E10 ---';
end
$test_e$;

-- ==============================================================

-- أدوات اختبار مؤقتة فقط؛ لا عقد إنتاج ولا تعطيل لحارس.
-- اللقطة تقارن المحتوى الكامل لا الأعداد فقط، بما يشمل جميع الجداول
-- المالية والتدقيق والطابور والموارد؛ تُقرأ بدور مالك الاختبار.
create function pg_temp.m113_q137_check(ok boolean, label text)
returns void language plpgsql as $qcheck$
begin
  if ok is distinct from true then raise exception 'FAIL %', label; end if;
  raise notice 'PASS %', label;
end
$qcheck$;

create function pg_temp.m113_q137_snapshot()
returns jsonb language plpgsql as $qsnapshot$
declare
  r record;
  rows_json jsonb;
  result jsonb := '{}'::jsonb;
begin
  for r in
    select n.nspname, c.relname
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid=c.relnamespace
    where c.relkind in ('r','p') and not c.relispartition
      and (n.nspname in ('billing','finance','inventory','audit','sync')
        or (n.nspname='core' and c.relname in ('wells','well_settings'))
        or (n.nspname='ops' and c.relname in (
          'irrigation_bookings','irrigation_sessions','session_segments',
          'booking_transition_chains','booking_transition_decisions',
          'booking_status_history','resource_reservations',
          'booking_automation_control','booking_automation_execution_contexts')))
    order by n.nspname,c.relname
  loop
    execute format(
      'select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),''[]''::jsonb) from %I.%I t',
      r.nspname,r.relname) into rows_json;
    result := result || jsonb_build_object(r.nspname||'.'||r.relname,rows_json);
  end loop;
  perform pg_temp.m113_q137_check(
    result ?& array['ops.irrigation_bookings','ops.irrigation_sessions',
      'ops.booking_transition_chains','ops.booking_transition_decisions',
      'sync.processed_commands','billing.session_charges',
      'finance.journal_entries','finance.journal_lines'],
    'Q137 snapshot includes required operational/financial authorities');
  return result;
end
$qsnapshot$;

-- الاستدعاء المرفوض داخل subtransaction، ثم مقارنة الصفوف خارجها:
-- نجاح الاستدعاء أو رمز/رسالة غير متوقعين يفشل الاختبار ولا يُبتلع.
create function pg_temp.m113_q137_refused(
  statement text, label text, expected_state text,
  expected_message text default null, as_role text default 'authenticated')
returns void language plpgsql as $qrefused$
declare
  before_state jsonb;
  caught_state text;
  caught_message text;
begin
  before_state := pg_temp.m113_q137_snapshot();
  begin
    if as_role is not null then
      execute format('set local role %I',as_role);
    end if;
    execute statement;
  exception when others then
    get stacked diagnostics caught_state=returned_sqlstate,
      caught_message=message_text;
  end;
  execute 'reset role';
  perform pg_temp.m113_q137_check(
    caught_state is not null
    and (expected_state is null or caught_state=expected_state)
    and (expected_message is null or caught_message ~ expected_message),label);
  perform pg_temp.m113_q137_check(
    pg_temp.m113_q137_snapshot()=before_state,label||' / zero partial effects');
end
$qrefused$;

create function pg_temp.m113_q137_dml_closed(
  statement text,label text,as_role text default 'authenticated')
returns void language plpgsql as $qdml$
declare
  before_state jsonb;
  affected bigint := 0;
  caught_state text;
begin
  before_state := pg_temp.m113_q137_snapshot();
  begin
    execute format('set local role %I',as_role);
    execute statement;
    get diagnostics affected=row_count;
  exception when others then
    get stacked diagnostics caught_state=returned_sqlstate;
  end;
  execute 'reset role';
  perform pg_temp.m113_q137_check(
    (caught_state='42501' or (caught_state is null and affected=0))
    and pg_temp.m113_q137_snapshot()=before_state,label);
end
$qdml$;

-- معرفات fixtures فقط، بين أقسام الاختبار داخل المعاملة الملغاة.
create temporary table m113_q137_context(data jsonb not null) on commit drop;

-- M113-E2-a: بدء يدوي مستقل؛ Legacy rows لا تنشأ بالتشغيل بعد Q137.
-- تُحفظ اختبارات الهوية/replay والرفض والعزل وإغلاق Direct DML.
-- الصفوف التاريخية أدناه fixtures بصلاحية مالك الاختبار، لا أثرًا للبدء.
do $test_ea$
declare
  v_tenant uuid;
  v_op1 uuid;
  v_op2 uuid;
  v_outsider uuid;
  v_person uuid;
  v_profile uuid;
  v_well_1 uuid;
  v_well_rej uuid;
  v_well_free uuid;
  v_well_iso uuid;
  v_acc uuid;
  v_farm uuid;
  v_pump uuid;
  v_acc_free uuid;
  v_farm_free uuid;
  v_pump_free uuid;
  v_bk1 uuid;
  v_bk_rej uuid;
  v_bk_iso uuid;
  v_sess1 uuid;
  v_result jsonb;
  v_replay jsonb;
  v_cmd uuid;
  v_count bigint;
  v_opened uuid;
  v_status text;
  v_curr uuid;
  v_now timestamptz := date_trunc('minute', clock_timestamp()) - interval '4 hours';
begin
  insert into core.tenants (name)
  values ('جهة اختبار سلسلة الانتقال 113-EA')
  returning id into v_tenant;

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع السلسلة 113-EA', 'مزارع السلسلة 113-EA')
  returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_profile;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'op1-113ea@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_op1;
  insert into iam.profiles (id, full_name)
  values (v_op1, 'مشغل 1 113-EA') on conflict (id) do nothing;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'op2-113ea@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_op2;
  insert into iam.profiles (id, full_name)
  values (v_op2, 'مشغل 2 113-EA') on conflict (id) do nothing;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'outsider-113ea@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_outsider;
  insert into iam.profiles (id, full_name)
  values (v_outsider, 'غريب 113-EA') on conflict (id) do nothing;

  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EA-1') returning id into v_well_1;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EA-REJ') returning id into v_well_rej;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EA-FREE') returning id into v_well_free;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EA-ISO') returning id into v_well_iso;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well_1, v_op1, 'operator', 'active'),
    (v_well_rej, v_op1, 'operator', 'active'),
    (v_well_free, v_op1, 'operator', 'active'),
    (v_well_iso, v_op2, 'operator', 'active');

  -- بئر EA-1: حساب+أرض+مضخة+تسعير+حجز مؤكد جاهز (well_diesel، مجدول لاحقًا).
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_1, 'FWA-EA-1') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_1, 'أرض EA-1', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_1, 'مضخة EA-1', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_1, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EA-1', v_well_1, v_acc, v_farm,
     v_now + interval '1 hour', v_now + interval '2 hours', 60,
     'well_diesel', 'confirmed') returning id into v_bk1;

  -- بئر EA-REJ: حجز جاهز لاختبار أن الرفض لا يخلّف سلسلة.
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_rej, 'FWA-EA-REJ') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_rej, 'أرض EA-REJ', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_rej, 'مضخة EA-REJ', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_rej, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EA-REJ', v_well_rej, v_acc, v_farm,
     v_now + interval '1 hour', v_now + interval '2 hours', 60,
     'well_diesel', 'confirmed') returning id into v_bk_rej;

  -- بئر EA-ISO: حجز جاهز لاختبار عزل البئر؛ لا سلسلة تنشأ من البدء.
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_iso, 'FWA-EA-ISO') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_iso, 'أرض EA-ISO', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_iso, 'مضخة EA-ISO', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_iso, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EA-ISO', v_well_iso, v_acc, v_farm,
     v_now + interval '1 hour', v_now + interval '2 hours', 60,
     'well_diesel', 'confirmed') returning id into v_bk_iso;

  -- بئر EA-FREE: حساب+أرض+مضخة+تسعير لجلسة حرة (بلا حجز) — لا سلسلة.
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_free, 'FWA-EA-FREE')
  returning id into v_acc_free;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_free, 'أرض EA-FREE', v_acc_free) returning id into v_farm_free;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_free, 'مضخة EA-FREE', 'diesel', 'active')
  returning id into v_pump_free;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_free, 5000, date '2026-01-01');

  -- EA1) لا سلسلة بمجرد وجود حجز مؤكد (قبل أي بدء).
  select count(*) into v_count
  from ops.booking_transition_chains where well_id = v_well_1;
  if v_count = 0 then
    raise notice 'PASS EA1: لا سلسلة تُنشأ بمجرد وجود حجز مؤكد';
  else
    raise notice 'FAIL EA1: سلسلة ظهرت دون بدء يدوي (%).', v_count;
  end if;

  perform set_config('request.jwt.claim.sub', v_op1::text, true);
  execute 'set local role authenticated';

  -- EA2/EA3: الجلسة مرتبطة بالحجز، دون chain أو قرار جديد.
  v_cmd := gen_random_uuid();
  v_result := api.start_irrigation_session_from_booking(v_bk1,v_now,v_cmd,null);
  v_sess1 := (v_result->>'session_id')::uuid;
  perform pg_temp.m113_q137_check(
    v_sess1 is not null and (v_result->>'booking_id')::uuid=v_bk1
    and v_result ? 'operational_end_at'
    and exists(select 1 from ops.irrigation_sessions
      where id=v_sess1 and booking_id=v_bk1 and status='open')
    and not exists(select 1 from ops.booking_transition_chains where well_id=v_well_1)
    and not exists(select 1 from ops.booking_transition_decisions where well_id=v_well_1),
    'EA2/EA3: manual booking identity without legacy chain or decision');

  -- EA5: نفس الإقرار والجلسة، ولا سلسلة عند إعادة الطلب.
  v_replay := api.start_irrigation_session_from_booking(v_bk1,v_now,v_cmd,null);
  perform pg_temp.m113_q137_check(v_replay=v_result
    and (select count(*) from ops.irrigation_sessions where booking_id=v_bk1)=1
    and not exists(select 1 from ops.booking_transition_chains where well_id=v_well_1),
    'EA5: exact manual replay has one session and zero chains');

  -- EA6) اختلاف حمولة الأمر لنفس المعرّف لا يغيّر حالة السلسلة.
  begin
    perform api.start_irrigation_session_from_booking(
      v_bk1, v_now - interval '1 minute', v_cmd, null
    );
    raise notice 'FAIL EA6: قُبل اختلاف الحمولة لنفس المعرّف';
  exception when others then
    select count(*) into v_count
    from ops.booking_transition_chains where well_id = v_well_1;
    select opened_by_session_id into v_opened
    from ops.booking_transition_chains where well_id = v_well_1;
    if position('محتوى مختلف' in sqlerrm) > 0
       and v_count = 0 and (select count(*) from ops.irrigation_sessions
         where booking_id=v_bk1 and id=v_sess1)=1 then
      raise notice 'PASS EA6: اختلاف الحمولة رُفض ولم يكرر الجلسة أو ينشئ سلسلة';
    else
      raise notice 'FAIL EA6: أثر غير متوقع لاختلاف الحمولة: %', sqlerrm;
    end if;
  end;

  -- EA4) رفض بدء الجلسة (زمن مستقبلي) لا يخلّف سلسلة يتيمة ولا جلسة.
  begin
    perform api.start_irrigation_session_from_booking(
      v_bk_rej, v_now + interval '1 day', gen_random_uuid(), null
    );
    raise notice 'FAIL EA4: قُبل بدء بزمن مستقبلي';
  exception when others then
    if (select count(*) from ops.booking_transition_chains
        where well_id = v_well_rej) = 0
       and not exists (select 1 from ops.irrigation_sessions
                       where well_id = v_well_rej) then
      raise notice 'PASS EA4: الرفض الذري لم يخلّف سلسلة ولا جلسة';
    else
      raise notice 'FAIL EA4: الرفض ترك أثرًا جزئيًا';
    end if;
  end;

  -- EA10) بدء جلسة حرة (بلا حجز) لا يُنشئ سلسلة.
  perform api.start_irrigation_session(
    v_well_free, v_pump_free, v_farm_free, v_acc_free, 'well_diesel',
    v_now, null, gen_random_uuid(), null
  );
  if (select count(*) from ops.booking_transition_chains
      where well_id = v_well_free) = 0
     and exists (select 1 from ops.irrigation_sessions
                 where well_id = v_well_free and booking_id is null) then
    raise notice 'PASS EA10: الجلسة الحرة لم تُنشئ سلسلة حجوزات';
  else
    raise notice 'FAIL EA10: جلسة حرة أنشأت سلسلة أو لم تُنشأ';
  end if;

  -- op2 يبدأ حجز بئره؛ بيانات التاريخ تُجهز لاحقًا كـfixture لعزل البئر.
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_op2::text, true);
  execute 'set local role authenticated';
  perform api.start_irrigation_session_from_booking(
    v_bk_iso, v_now, gen_random_uuid(), null
  );
  execute 'reset role';

  -- Legacy fixtures retained solely for historical RLS/unique-index tests.
  -- Manual starts above have already proved zero generated chains.
  insert into ops.booking_transition_chains(
    tenant_id,well_id,status,opened_by_session_id,opened_at,current_session_id,created_by)
  values
    (v_tenant,v_well_1,'active',v_sess1,v_now,v_sess1,v_op1),
    (v_tenant,v_well_iso,'active',
      (select id from ops.irrigation_sessions where booking_id=v_bk_iso),v_now,
      (select id from ops.irrigation_sessions where booking_id=v_bk_iso),v_op2);

  -- EA7) ضمان قاعدي: لا سلسلتان نشطتان لنفس البئر (فهرس فريد جزئي).
  --     محاولة إدراج مباشر كـsuperuser تتجاوز RLS فيبقى الفهرس هو الحكم.
  begin
    insert into ops.booking_transition_chains (
      tenant_id, well_id, status, opened_by_session_id, opened_at,
      current_session_id, created_by
    ) values (
      v_tenant, v_well_1, 'active', v_sess1, v_now, v_sess1, v_op1
    );
    raise notice 'FAIL EA7: سُمح بسلسلتين نشطتين لنفس البئر';
  exception
    when unique_violation then
      raise notice 'PASS EA7: الفهرس الفريد الجزئي منع سلسلة نشطة ثانية';
    when others then
      raise notice 'FAIL EA7: فشل غير متوقع في ضمان السلسلة الواحدة: %', sqlerrm;
  end;

  -- EA9) لا كتابة مباشرة لأدوار التطبيق (SELECT فقط، لا سياسة كتابة).
  perform set_config('request.jwt.claim.sub', v_op1::text, true);
  execute 'set local role authenticated';
  begin
    insert into ops.booking_transition_chains (
      tenant_id, well_id, status, opened_by_session_id, opened_at,
      current_session_id, created_by
    ) values (
      v_tenant, v_well_1, 'active', v_sess1, v_now, v_sess1, v_op1
    );
    raise notice 'FAIL EA9: كتابة مباشرة سُمحت لدور التطبيق';
  exception
    when insufficient_privilege then
      raise notice 'PASS EA9: الكتابة المباشرة محجوبة عن دور التطبيق';
    when others then
      raise notice 'FAIL EA9: فشل غير متوقع للكتابة المباشرة: %', sqlerrm;
  end;

  -- EA8) عزل الآبار والجهات عبر RLS.
  select count(*) into v_count
  from ops.booking_transition_chains where well_id = v_well_1;
  if v_count = 1 then
    raise notice 'PASS EA8a: مشغل البئر يرى fixture التاريخ المصرح به';
  else
    raise notice 'FAIL EA8a: مشغل البئر لم يرَ سلسلته (%).', v_count;
  end if;

  select count(*) into v_count
  from ops.booking_transition_chains where well_id = v_well_iso;
  if v_count = 0 then
    raise notice 'PASS EA8c: بئر غير مُسنَد لا تُرى سلسلته (عزل البئر)';
  else
    raise notice 'FAIL EA8c: تسربت سلسلة بئر غير مُسنَد (%).', v_count;
  end if;

  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  select count(*) into v_count
  from ops.booking_transition_chains where well_id = v_well_1;
  if v_count = 0 then
    raise notice 'PASS EA8b: الغريب لا يرى أي سلسلة (عزل الجهة)';
  else
    raise notice 'FAIL EA8b: تسربت سلسلة إلى غريب (%).', v_count;
  end if;

  execute 'reset role';
  insert into m113_q137_context values(jsonb_build_object(
    'tenant',v_tenant,'op',v_op1,'other_op',v_op2,'outsider',v_outsider,
    'well',v_well_1,'other_well',v_well_iso,'unused_well',v_well_rej,
    'booking',v_bk1,'other_booking',v_bk_iso,'unused_booking',v_bk_rej,
    'session',v_sess1,'now',v_now));
  raise notice '--- M113-E2-a / Q137 manual start and retained history security ---';
end
$test_ea$;

-- ==============================================================
-- M113-E2-b: كتابة قرارات Legacy retired by Q137؛ رفض بلا آثار.
do $test_eb$
declare
  c jsonb;
  chain uuid;
  action text;
  cmd uuid;
begin
  select data into strict c from m113_q137_context;
  select id into strict chain from ops.booking_transition_chains
    where well_id=(c->>'well')::uuid;
  perform set_config('request.jwt.claim.sub',c->>'op',true);
  foreach action in array array['run_now','wait'] loop
    cmd := gen_random_uuid();
    perform pg_temp.m113_q137_refused(format(
      'select api.record_booking_transition_decision(%L::uuid,%L::uuid,%L::uuid,%L,0::bigint,%L::uuid)',
      chain,c->>'session',c->>'other_booking',action,cmd),
      'EB: retired decision '||action,'0A000','^legacy_booking_automation_disabled$');
    -- نفس الهوية المرفوضة لا تتحول إلى processed-command ناجح عند التكرار.
    perform pg_temp.m113_q137_refused(format(
      'select api.record_booking_transition_decision(%L::uuid,%L::uuid,%L::uuid,%L,0::bigint,%L::uuid)',
      chain,c->>'session',c->>'other_booking',action,cmd),
      'EB: repeat disabled decision '||action,'0A000','^legacy_booking_automation_disabled$');
  end loop;
end
$test_eb$;

-- M113-E2-c1: إكمال محجوز يدويًا، مستقل عن Legacy Automation بعد Q137.
-- اختبارات الوقت والهوية/replay والمحاسبة والعزل والغلاف العام محفوظة.
do $test_ec$
declare
  v_tenant uuid;
  v_op uuid;
  v_outsider uuid;
  v_person uuid;
  v_profile uuid;
  v_well_main uuid;
  v_well_legacy uuid;
  v_well_due uuid;
  v_well_free uuid;
  v_acc uuid;
  v_farm uuid;
  v_pump uuid;
  v_acc_free uuid;
  v_farm_free uuid;
  v_pump_free uuid;
  v_b1 uuid;
  v_b_future uuid;
  v_bl uuid;
  v_bd1 uuid;
  v_bd2 uuid;
  v_s_main uuid;
  v_s_legacy uuid;
  v_s_due uuid;
  v_chain_main uuid;
  v_cmd uuid;
  v_result jsonb;
  v_count bigint;
  v_cstatus text;
  v_opened uuid;
  v_rev bigint;
  v_now timestamptz := date_trunc('minute', clock_timestamp());
begin
  insert into core.tenants (name)
  values ('جهة اختبار إكمال السلسلة 113-EC') returning id into v_tenant;
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع الإكمال 113-EC', 'مزارع الإكمال 113-EC')
  returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_profile;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'op-113ec@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_op;
  insert into iam.profiles (id, full_name)
  values (v_op, 'مشغل 113-EC') on conflict (id) do nothing;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'outsider-113ec@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_outsider;
  insert into iam.profiles (id, full_name)
  values (v_outsider, 'غريب 113-EC') on conflict (id) do nothing;

  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EC-MAIN') returning id into v_well_main;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EC-LEGACY') returning id into v_well_legacy;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EC-DUE') returning id into v_well_due;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EC-FREE') returning id into v_well_free;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well_main, v_op, 'operator', 'active'),
    (v_well_legacy, v_op, 'operator', 'active'),
    (v_well_due, v_op, 'operator', 'active'),
    (v_well_free, v_op, 'operator', 'active');

  -- بئر MAIN: حجز يُبدأ منه (مدة 120د) ويُكمَل مبكرًا، وحجز تالٍ مستقبلي.
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_main, 'FWA-EC-M') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_main, 'أرض EC-M', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_main, 'مضخة EC-M', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_main, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC-M1', v_well_main, v_acc, v_farm,
     v_now - interval '10 minutes', v_now + interval '110 minutes', 120,
     'well_diesel', 'confirmed') returning id into v_b1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC-M-FUT', v_well_main, v_acc, v_farm,
     v_now + interval '2 hours', v_now + interval '3 hours', 60,
     'well_diesel', 'confirmed') returning id into v_b_future;

  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_result := api.start_irrigation_session_from_booking(
    v_b1, v_now - interval '10 minutes', gen_random_uuid(), null
  );
  v_s_main := (v_result ->> 'session_id')::uuid;
  select id into v_chain_main
  from ops.booking_transition_chains where well_id = v_well_main;

  -- EC8) ended_at مستقبلي مرفوض (حارس المستقبل) بلا أثر.
  begin
    perform api.complete_booking_session(
      v_s_main, v_now + interval '1 day', gen_random_uuid()
    );
    raise notice 'FAIL EC8: قُبل ended_at مستقبلي';
  exception when others then
    if position('المستقبل' in sqlerrm) > 0
       and exists (select 1 from ops.irrigation_sessions
                   where id = v_s_main and status = 'open')
       and not exists (select 1 from billing.session_charges
                       where session_id = v_s_main) then
      raise notice 'PASS EC8: ended_at المستقبلي رُفض بلا إكمال ولا تسوية';
    else
      raise notice 'FAIL EC8: رفض المستقبل غير صحيح: %', sqlerrm;
    end if;
  end;

  -- EC9) ended_at قبل بداية الجلسة مرفوض بلا أثر.
  begin
    perform api.complete_booking_session(
      v_s_main, v_now - interval '20 minutes', gen_random_uuid()
    );
    raise notice 'FAIL EC9: قُبل ended_at قبل البداية';
  exception when others then
    if exists (select 1 from ops.irrigation_sessions
               where id = v_s_main and status = 'open') then
      raise notice 'PASS EC9: زمن قبل البداية رُفض والجلسة باقية مفتوحة';
    else
      raise notice 'FAIL EC9: رفض زمن ما قبل البداية غير صحيح: %', sqlerrm;
    end if;
  end;

  -- EC1/EC2) إكمال مبكر ناجح: الجلسة مغلقة، لا مقطع مفتوح، تسوية موجودة.
  v_cmd := gen_random_uuid();
  v_result := api.complete_booking_session(
    v_s_main, v_now - interval '5 minutes', v_cmd
  );
  if v_result ->> 'status' = 'closed'
     and v_result ? 'session_charge_id'
     and exists (select 1 from ops.irrigation_sessions
                 where id = v_s_main and status = 'closed')
     and not exists (select 1 from ops.session_segments
                     where session_id = v_s_main and ended_at is null)
     and (select count(*) from billing.session_charges
          where session_id = v_s_main) = 1 then
    raise notice 'PASS EC1/EC2: الإكمال أغلق الجلسة وأتم المقاطع وأنشأ تسوية واحدة';
  else
    raise notice 'FAIL EC1/EC2: إكمال/تسوية غير صحيحة: %', v_result;
  end if;

  -- EC5/EC6/EC16: لا يصطنع الإكمال سلسلة أو قرارًا بدلا عن الإنسان.
  perform pg_temp.m113_q137_check(
    not exists(select 1 from ops.booking_transition_chains where well_id=v_well_main)
    and not exists(select 1 from ops.booking_transition_decisions where well_id=v_well_main),
    'EC5/EC6/EC16: completion creates no legacy chain or decision');

  -- EC4) لا جلسة تالية أُنشئت في هذه الجولة.
  if (select count(*) from ops.irrigation_sessions where well_id = v_well_main) = 1
  then
    raise notice 'PASS EC4: لا جلسة تالية أُنشئت عند الإكمال';
  else
    raise notice 'FAIL EC4: جلسة إضافية ظهرت على البئر';
  end if;

  -- EC3/EC10) replay مطابق يعيد الرد بلا تسوية ثانية.
  perform api.complete_booking_session(v_s_main, v_now - interval '5 minutes', v_cmd);
  if (select count(*) from billing.session_charges
      where session_id = v_s_main) = 1 then
    raise notice 'PASS EC3/EC10: replay المطابق لم يُنشئ تسوية ثانية';
  else
    raise notice 'FAIL EC3/EC10: تكررت التسوية عند الإعادة';
  end if;

  -- EC11) نفس المعرّف بحمولة مختلفة مرفوض.
  begin
    perform api.complete_booking_session(
      v_s_main, v_now - interval '4 minutes', v_cmd
    );
    raise notice 'FAIL EC11: قُبل اختلاف الحمولة لنفس المعرّف';
  exception when others then
    if position('محتوى مختلف' in sqlerrm) > 0 then
      raise notice 'PASS EC11: اختلاف الحمولة لنفس المعرّف مرفوض';
    else
      raise notice 'FAIL EC11: رفض اختلاف الحمولة غير صحيح: %', sqlerrm;
    end if;
  end;

  -- EC12) أمر إكمال ثانٍ (معرّف جديد) على جلسة مغلقة لا يُنشئ تسوية ثانية.
  begin
    perform api.complete_booking_session(
      v_s_main, v_now - interval '3 minutes', gen_random_uuid()
    );
    raise notice 'FAIL EC12: قُبل إكمال ثانٍ لجلسة مغلقة';
  exception when others then
    if (select count(*) from billing.session_charges
        where session_id = v_s_main) = 1 then
      raise notice 'PASS EC12: الإكمال الثاني رُفض بلا تسوية ثانية';
    else
      raise notice 'FAIL EC12: ظهرت تسوية ثانية';
    end if;
  end;

  -- بئر LEGACY: الإكمال عبر مسار M084 القديم يصالح السلسلة بالزناد.
  execute 'reset role';
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_legacy, 'FWA-EC-L') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_legacy, 'أرض EC-L', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_legacy, 'مضخة EC-L', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_legacy, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC-L1', v_well_legacy, v_acc, v_farm,
     v_now - interval '10 minutes', v_now + interval '110 minutes', 120,
     'well_diesel', 'confirmed') returning id into v_bl;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_result := api.start_irrigation_session_from_booking(
    v_bl, v_now - interval '10 minutes', gen_random_uuid(), null
  );
  v_s_legacy := (v_result ->> 'session_id')::uuid;

  -- EC13) عزل: غريب لا يُكمل جلسة سلسلة لا يملك وصولها.
  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  begin
    perform api.complete_booking_session(
      v_s_legacy, v_now - interval '5 minutes', gen_random_uuid()
    );
    raise notice 'FAIL EC13: غريب أكمل جلسة لا يملكها';
  exception when others then
    if position('وصول' in sqlerrm) > 0 or position('صلاحية' in sqlerrm) > 0 then
      raise notice 'PASS EC13: الغريب مرفوض عن إكمال الجلسة';
    else
      raise notice 'FAIL EC13: رفض الغريب غير صحيح: %', sqlerrm;
    end if;
  end;
  perform set_config('request.jwt.claim.sub', v_op::text, true);

  -- EC15) غلاف الإكمال العام القائم يغلق الجلسة ولا يعيد Legacy Automation.
  perform api.complete_irrigation_session(
    v_s_legacy, v_now - interval '5 minutes', null, null, null, gen_random_uuid()
  );
  select status into v_cstatus
  from ops.booking_transition_chains where well_id = v_well_legacy;
  if not exists(select 1 from ops.booking_transition_chains where well_id=v_well_legacy)
     and exists (select 1 from ops.irrigation_sessions
                 where id = v_s_legacy and status = 'closed') then
    raise notice 'PASS EC15: غلاف الإكمال العام أغلق الجلسة دون سلسلة';
  else
    raise notice 'FAIL EC15: المسار القديم ترك السلسلة غير متسقة (s=%)', v_cstatus;
  end if;

  -- بئر DUE: إكمال مع حجز تالٍ مستحق — لا يُسجَّل التالي كأنه بدأ.
  execute 'reset role';
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_due, 'FWA-EC-D') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_due, 'أرض EC-D', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_due, 'مضخة EC-D', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_due, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC-D1', v_well_due, v_acc, v_farm,
     v_now - interval '10 minutes', v_now + interval '110 minutes', 120,
     'well_diesel', 'confirmed') returning id into v_bd1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC-D2', v_well_due, v_acc, v_farm,
     v_now - interval '40 minutes', v_now - interval '15 minutes', 25,
     'well_diesel', 'confirmed') returning id into v_bd2;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_result := api.start_irrigation_session_from_booking(
    v_bd1, v_now - interval '10 minutes', gen_random_uuid(), null
  );
  v_s_due := (v_result ->> 'session_id')::uuid;
  perform api.complete_booking_session(
    v_s_due, v_now - interval '5 minutes', gen_random_uuid()
  );
  select status into v_cstatus
  from ops.booking_transition_chains where well_id = v_well_due;
  if not exists(select 1 from ops.booking_transition_chains where well_id=v_well_due)
     and not exists (select 1 from ops.irrigation_sessions
                     where booking_id = v_bd2) then
    raise notice 'PASS EC7: مع تالٍ مستحق: لا سلسلة ولا بدء تلقائي للتالي';
  else
    raise notice 'FAIL EC7: حالة الاستحقاق غير صحيحة (s=%)', v_cstatus;
  end if;

  -- EC14) إكمال جلسة حرة عبر المسار القديم: ينجح ولا سلسلة له.
  execute 'reset role';
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_free, 'FWA-EC-F')
  returning id into v_acc_free;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_free, 'أرض EC-F', v_acc_free) returning id into v_farm_free;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_free, 'مضخة EC-F', 'diesel', 'active')
  returning id into v_pump_free;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_free, 5000, date '2026-01-01');
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_opened := api.start_irrigation_session(
    v_well_free, v_pump_free, v_farm_free, v_acc_free, 'well_diesel',
    v_now - interval '10 minutes', null, gen_random_uuid(), null
  );
  perform api.complete_irrigation_session(
    v_opened, v_now - interval '5 minutes',
    null, null, null, gen_random_uuid()
  );
  if exists (select 1 from ops.irrigation_sessions
             where id = v_opened and status = 'closed')
     and not exists (select 1 from ops.booking_transition_chains
                     where well_id = v_well_free) then
    raise notice 'PASS EC14: الجلسة الحرة أُكملت قديمًا دون إنشاء سلسلة';
  else
    raise notice 'FAIL EC14: مسار الجلسة الحرة تأثر بالسلسلة';
  end if;

  execute 'reset role';
  raise notice '--- انتهى اختبار M113-E2-c1: فحوص EC1..EC16 ---';
end
$test_ec$;

-- ==============================================================
-- M113-E2-c1-S1: forgotten ليس إكمالًا محاسبيًا؛ لا Legacy effects بعد Q137.
do $test_ecf$
declare
  v_tenant uuid;
  v_op uuid;
  v_person uuid;
  v_profile uuid;
  v_well_f uuid;
  v_well_c uuid;
  v_acc uuid;
  v_farm uuid;
  v_pump uuid;
  v_b1 uuid;
  v_bc1 uuid;
  v_bc_next uuid;
  v_s_f uuid;
  v_s_c uuid;
  v_chain_f uuid;
  v_cstatus text;
  v_opened uuid;
  v_rev bigint;
  v_result jsonb;
  v_now timestamptz := date_trunc('minute', clock_timestamp());
begin
  insert into core.tenants (name)
  values ('جهة اختبار forgotten 113-ECF') returning id into v_tenant;
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع ECF', 'مزارع ECF') returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_profile;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'op-113ecf@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_op;
  insert into iam.profiles (id, full_name)
  values (v_op, 'مشغل ECF') on conflict (id) do nothing;

  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر ECF-F') returning id into v_well_f;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر ECF-C') returning id into v_well_c;
  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well_f, v_op, 'operator', 'active'),
    (v_well_c, v_op, 'operator', 'active');

  -- بئر F: حجز يُبدأ منه ثم تُحوَّل جلسته إلى forgotten مباشرةً.
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_f, 'FWA-ECF-F') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_f, 'أرض ECF-F', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_f, 'مضخة ECF-F', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_f, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-ECF-F1', v_well_f, v_acc, v_farm,
     v_now - interval '10 minutes', v_now + interval '110 minutes', 120,
     'well_diesel', 'confirmed') returning id into v_b1;

  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_result := api.start_irrigation_session_from_booking(
    v_b1, v_now - interval '10 minutes', gen_random_uuid(), null
  );
  v_s_f := (v_result ->> 'session_id')::uuid;
  execute 'reset role';
  select id into v_chain_f
  from ops.booking_transition_chains where well_id = v_well_f;

  -- ECF1: البداية اليدوية open بلا سلسلة.
  perform pg_temp.m113_q137_check(
    exists(select 1 from ops.irrigation_sessions where id=v_s_f and status='open')
    and not exists(select 1 from ops.booking_transition_chains where well_id=v_well_f),
    'ECF1: manual session open without chain');

  -- تحويل مباشر إلى forgotten (كـsuperuser): لا عقد يكتبها، فنحاكيها هنا.
  update ops.irrigation_sessions
  set status = 'forgotten', ended_at = v_now - interval '5 minutes'
  where id = v_s_f;

  -- ECF2..ECF6: forgotten لا ينتحل إكمالًا أو تسوية أو قرارًا.
  perform pg_temp.m113_q137_check(
    exists(select 1 from ops.irrigation_sessions where id=v_s_f and status='forgotten')
    and not exists(select 1 from ops.booking_transition_chains where well_id=v_well_f)
    and not exists(select 1 from ops.booking_transition_decisions where well_id=v_well_f)
    and not exists(select 1 from billing.session_charges where session_id=v_s_f)
    and not exists(select 1 from sync.processed_commands where entity_id=v_s_f
      and command_type='complete_booking_session'),
    'ECF2-6: forgotten creates no charge, completion receipt, chain or decision');

  -- بئر C: الإغلاق المحاسبي الصحيح يعمل مستقلًا عن السلسلة.
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_c, 'FWA-ECF-C') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_c, 'أرض ECF-C', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_c, 'مضخة ECF-C', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_c, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-ECF-C1', v_well_c, v_acc, v_farm,
     v_now - interval '10 minutes', v_now + interval '110 minutes', 120,
     'well_diesel', 'confirmed') returning id into v_bc1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-ECF-C-NEXT', v_well_c, v_acc, v_farm,
     v_now + interval '2 hours', v_now + interval '3 hours', 60,
     'well_diesel', 'confirmed') returning id into v_bc_next;

  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_result := api.start_irrigation_session_from_booking(
    v_bc1, v_now - interval '10 minutes', gen_random_uuid(), null
  );
  v_s_c := (v_result ->> 'session_id')::uuid;
  perform api.complete_booking_session(
    v_s_c, v_now - interval '5 minutes', gen_random_uuid()
  );
  execute 'reset role';

  -- ECF7/ECF8) الإغلاق الصحيح لا ينشئ سلسلة ولا يبدأ التالي.
  select status into v_cstatus
  from ops.booking_transition_chains where well_id = v_well_c;
  if not exists(select 1 from ops.booking_transition_chains where well_id=v_well_c)
     and not exists (select 1 from ops.irrigation_sessions
                     where booking_id = v_bc_next) then
    raise notice 'PASS ECF7/ECF8: الإغلاق الصحيح بلا سلسلة أو بدء للتالي';
  else
    raise notice 'FAIL ECF7/ECF8: مصالحة الإغلاق الصحيح غير سليمة (s=%)', v_cstatus;
  end if;

  raise notice '--- انتهى اختبار M113-E2-c1-S1: forgotten بلا تسوية، closed بتسوية يدوية ---';
end
$test_ecf$;

-- ==============================================================
-- M113-E2-c2-a: بدء لاحق يدوي مستقل عن fixture التاريخ، بهوية ثابتة.
do $test_ec2$
declare
  c jsonb;
  b ops.irrigation_bookings%rowtype;
  next_booking uuid;
  session2 uuid;
  cmd uuid := gen_random_uuid();
  denied_cmd uuid := gen_random_uuid();
  t timestamptz;
  first_receipt jsonb;
  replay jsonb;
  history_before jsonb;
begin
  select data into strict c from m113_q137_context;
  select * into strict b from ops.irrigation_bookings where id=(c->>'booking')::uuid;
  t := (c->>'now')::timestamptz;
  select to_jsonb(x) into strict history_before from ops.booking_transition_chains x
    where x.well_id=b.well_id;
  perform set_config('request.jwt.claim.sub',c->>'op',true);
  execute 'set local role authenticated';
  perform api.complete_booking_session((c->>'session')::uuid,t+interval '30 minutes',gen_random_uuid());
  execute 'reset role';
  insert into ops.irrigation_bookings(tenant_id,public_code,well_id,
    farmer_well_account_id,farm_id,scheduled_start,scheduled_end,
    expected_duration_minutes,expected_energy_source,status)
  values(b.tenant_id,'BKG-Q137-EC2-NEXT',b.well_id,b.farmer_well_account_id,
    b.farm_id,b.scheduled_end,b.scheduled_end+interval '1 hour',60,'well_diesel','confirmed')
  returning id into next_booking;
  execute 'set local role authenticated';
  first_receipt := api.start_irrigation_session_from_booking(
    next_booking,t+interval '35 minutes',cmd,null);
  session2 := (first_receipt->>'session_id')::uuid;
  replay := api.start_irrigation_session_from_booking(next_booking,t+interval '35 minutes',cmd,null);
  execute 'reset role';
  perform pg_temp.m113_q137_check(first_receipt=replay and session2 is not null
    and (first_receipt->>'booking_id')::uuid=next_booking
    and (select count(*) from ops.irrigation_sessions where booking_id=next_booking)=1
    and (select to_jsonb(x) from ops.booking_transition_chains x where x.well_id=b.well_id)=history_before,
    'EC2: next manual booking replays one session without changing legacy history');
  perform pg_temp.m113_q137_refused(format(
    'select api.start_irrigation_session_from_booking(%L::uuid,%L::timestamptz,%L::uuid,null)',
    next_booking,t+interval '36 minutes',cmd),
    'EC2: changed manual payload rejected',null,'محتوى مختلف');
  perform pg_temp.m113_q137_refused(format(
    'select api.start_irrigation_session_from_booking(%L::uuid,%L::timestamptz,%L::uuid,null)',
    next_booking,t+interval '35 minutes',denied_cmd),
    'EC2: consumed booking cannot create another session',null,'جلسة');
  execute 'set local role authenticated';
  perform api.complete_booking_session(session2,t+interval '50 minutes',gen_random_uuid());
  execute 'reset role';
  perform pg_temp.m113_q137_check(
    (select count(*) from billing.session_charges where session_id=session2)=1
    and not exists(select 1 from sync.processed_commands where command_id=denied_cmd),
    'EC2: one charge, no processed command for refused duplicate start');
end
$test_ec2$;

-- M113-E2-c2-b: pending executor retired by Q137؛ حد النواة اليدوية محفوظ.
do $test_ec2b$
declare
  c jsonb;
  v_op uuid;
  v_now timestamptz;
  chain uuid;
begin
  select data into strict c from m113_q137_context;
  v_op := (c->>'op')::uuid;
  v_now := (c->>'now')::timestamptz;
  select id into strict chain from ops.booking_transition_chains
    where well_id=(c->>'well')::uuid;
  perform set_config('request.jwt.claim.sub',v_op::text,true);
  perform pg_temp.m113_q137_refused(format(
    'select api.execute_pending_booking_start(%L::uuid,0::bigint,%L::uuid)',
    chain,gen_random_uuid()),'EC2B: retired pending API','0A000',
    '^legacy_booking_automation_disabled$');
  perform pg_temp.m113_q137_refused(format(
    'select ops.start_booking_session_core(%L::uuid,%L::uuid,%L::timestamptz,null,true)',
    c->>'unused_booking',v_op,v_now),'EC2B: owner cannot use pending flag',
    '0A000','^legacy_booking_automation_disabled$',null);
  execute 'set local role authenticated';
  -- EC2B-19) حدّ الأمان: النواة start_booking_session_core موجودة definer
  --   بمسار بحث مثبت، وغير ممنوحة لأي دور تطبيقي (العميل لا يصلها فلا يمرّر
  --   العلم true)؛ بينما الغلاف اليدوي وسطح api يبقيان ممنوحين لـauthenticated.
  if to_regprocedure(
       'ops.start_booking_session_core(uuid,uuid,timestamptz,text[],boolean)'
     ) is not null
     and (select p.prosecdef from pg_proc p where p.oid = to_regprocedure(
       'ops.start_booking_session_core(uuid,uuid,timestamptz,text[],boolean)'
     ))
     and (select p.proconfig @> array['search_path=pg_catalog, pg_temp']
          from pg_proc p where p.oid = to_regprocedure(
       'ops.start_booking_session_core(uuid,uuid,timestamptz,text[],boolean)'
     ))
     and not has_function_privilege(
       'authenticated',
       'ops.start_booking_session_core(uuid,uuid,timestamptz,text[],boolean)',
       'EXECUTE'
     )
     and not has_function_privilege(
       'anon',
       'ops.start_booking_session_core(uuid,uuid,timestamptz,text[],boolean)',
       'EXECUTE'
     )
     and not has_function_privilege(
       'service_role',
       'ops.start_booking_session_core(uuid,uuid,timestamptz,text[],boolean)',
       'EXECUTE'
     )
     and has_function_privilege(
       'authenticated',
       'ops.start_irrigation_session_from_booking(uuid,uuid,timestamptz,text[])',
       'EXECUTE'
     )
  then
    raise notice 'PASS EC2B-19: النواة غير ممنوحة لأي دور تطبيقي (العلم غير قابل للانتحال)';
  else
    raise notice 'FAIL EC2B-19: حدّ أمان النواة غير صحيح (موجودة/definer/منح)';
  end if;

  -- EC2B-20) تحقق أمني ديناميكي (STEP 4): استدعاء النواة مباشرةً بدور
  --   authenticated مرفوض فعليًا (لا فحص صلاحية ساكن وحده)، فالعلم
  --   p_executing_pending_decision غير قابل للتمرير من العميل. السياق هنا
  --   authenticated/v_op؛ لا نلمس الدور لئلّا نكسر EC2B-11 التالي.
  begin
    perform ops.start_booking_session_core(
      gen_random_uuid(), v_op, v_now, null, true
    );
    raise notice 'FAIL EC2B-20: نُفِّذت النواة مباشرةً بدور authenticated';
  exception when others then
    if sqlstate = '42501' or position('permission denied' in sqlerrm) > 0 then
      raise notice 'PASS EC2B-20: استدعاء النواة المباشر مرفوض فعليًا (42501)';
    else
      raise notice 'FAIL EC2B-20: رفض النواة بخطأ غير متوقع: % (%)', sqlerrm, sqlstate;
    end if;
  end;


  execute 'reset role';
end
$test_ec2b$;

-- M113-E2-d: المقيم قراءة حالية فقط؛ لا chain من البدء/الإكمال اليدوي.
do $test_ed$
declare
  c jsonb;
  well uuid;
  booking uuid;
  session_id uuid;
  res jsonb;
  before_state jsonb;
  t timestamptz;
begin
  select data into strict c from m113_q137_context;
  well := (c->>'unused_well')::uuid;
  booking := (c->>'unused_booking')::uuid;
  t := (c->>'now')::timestamptz;
  perform set_config('request.jwt.claim.sub',c->>'op',true);
  before_state := pg_temp.m113_q137_snapshot();
  execute 'set local role authenticated';
  res := api.evaluate_well_booking_transition(well);
  execute 'reset role';
  perform pg_temp.m113_q137_check(
    (res->>'requires_manual_start')::boolean is true
    and (res->>'chain_armed')::boolean is false
    and res->'chain'='null'::jsonb
    and pg_temp.m113_q137_snapshot()=before_state,
    'ED1: evaluator requires human start and has no effects');
  execute 'set local role authenticated';
  res := api.start_irrigation_session_from_booking(booking,t,gen_random_uuid(),null);
  session_id := (res->>'session_id')::uuid;
  execute 'reset role';
  before_state := pg_temp.m113_q137_snapshot();
  execute 'set local role authenticated';
  res := api.evaluate_well_booking_transition(well);
  execute 'reset role';
  perform pg_temp.m113_q137_check(
    (res->>'has_open_session')::boolean is true
    and (res->>'safe_to_auto_start')::boolean is false
    and (res->>'chain_armed')::boolean is false
    and pg_temp.m113_q137_snapshot()=before_state,
    'ED2/3: real open session blocks next start without arming a chain');
  execute 'set local role authenticated';
  perform api.complete_booking_session(session_id,t+interval '10 minutes',gen_random_uuid());
  res := api.evaluate_well_booking_transition(well);
  execute 'reset role';
  perform pg_temp.m113_q137_check(
    (res->>'has_open_session')::boolean is false
    and (res->>'chain_armed')::boolean is false
    and not exists(select 1 from ops.booking_transition_chains where well_id=well)
    and not exists(select 1 from ops.booking_transition_decisions where well_id=well)
    and ((res->'next_booking'->>'id') is distinct from booking::text),
    'ED9/10/11: completed booking is not resurrected as the next booking');
  perform set_config('request.jwt.claim.sub',c->>'other_op',true);
  perform pg_temp.m113_q137_refused(format(
    'select api.evaluate_well_booking_transition(%L::uuid)',well),
    'ED13: evaluator denies unassigned well',null,'صلاحية|وصول|غير موجود');
end
$test_ed$;

-- M113-P1-A: إعداد Legacy replay-only؛ القراءة والعزل وDirect DML محفوظة.
do $test_pa$
declare
  v_tenant uuid;
  v_owner uuid;    -- مالك البئر (مراقبة فقط؛ تحكمه عن بعد مؤجل إلى P7)
  v_op uuid;       -- المشغل المخوّل على البئرين
  v_mgr uuid;      -- مدير له session.start كنونيًا بلا حيازة مشغل
  v_outsider uuid; -- بلا تعيين نشط (عليه تعيين مشغل غير نشط فحسب)
  v_wa uuid;       -- بئر أ
  v_wb uuid;       -- بئر ب
  v_wc uuid;       -- بئر ج (لإدراج المالك غير المشروع)
  v_rows integer;
  v_err text;
  v_res jsonb;
  v_rev0 bigint;
  v_rev1 bigint;
  v_rev2 bigint;
  v_rev3 bigint;
  v_revb bigint;
  v_cmd uuid;
  v_cmd_owner uuid;  -- محاولة المالك المباشرة (المرفوضة)
  v_cmd_direct uuid; -- أمر الاستدعاء المباشر للمشغل (المقبول المسجَّل)
  v_cmd_stale uuid;  -- أمر المراجعة القديمة (المتراجع ذريًا)
begin
  insert into core.tenants (name) values ('جهة M113-P1-A') returning id into v_tenant;
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 'own-pa@test.local', crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_owner;
  insert into iam.profiles (id, full_name) values (v_owner, 'مالك PA') on conflict (id) do nothing;
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 'op-pa@test.local', crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_op;
  insert into iam.profiles (id, full_name) values (v_op, 'مشغل PA') on conflict (id) do nothing;
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 'out-pa@test.local', crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_outsider;
  insert into iam.profiles (id, full_name) values (v_outsider, 'غريب PA') on conflict (id) do nothing;
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 'mgr-pa@test.local', crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_mgr;
  insert into iam.profiles (id, full_name) values (v_mgr, 'مدير PA') on conflict (id) do nothing;

  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر PA-A') returning id into v_wa;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر PA-B') returning id into v_wb;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر PA-C') returning id into v_wc;
  insert into core.well_assignments (well_id, profile_id, role, status) values
    (v_wa, v_owner, 'owner', 'active'), (v_wb, v_owner, 'owner', 'active'),
    (v_wc, v_owner, 'owner', 'active'),
    (v_wa, v_op, 'operator', 'active'), (v_wb, v_op, 'operator', 'active'),
    (v_wa, v_mgr, 'manager', 'active'),
    (v_wa, v_outsider, 'operator', 'inactive');

  -- PA1: الافتراض OFF بمراجعة 0، وسلسلة JSON null، والتمييز الصريح:
  --   منفّذ الأتمتة غير جاهز مستقلًا عن الإعداد المحفوظ.
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_res := api.get_well_booking_automation(v_wa);
  if (v_res ->> 'booking_auto_transition_enabled')::boolean is false
     and (v_res ->> 'booking_auto_transition_revision')::bigint = 0
     and (v_res ->> 'settings_row_exists')::boolean is true
     and (v_res ->> 'active_chain') is null
     and (v_res ->> 'automation_executor_ready')::boolean is false
     and (v_res ->> 'auto_transition_executed')::boolean is false
     and v_res ->> 'first_session' = 'manual' then
    raise notice 'PASS PA1: الافتراض OFF بمراجعة 0 وسلسلة JSON null وجاهزية المنفّذ صريحة';
  else
    raise notice 'FAIL PA1: قراءة الافتراض غير صحيحة: %', v_res;
  end if;
  execute 'reset role';


  -- طلب جديد ON/OFF لا يُقبل حتى للمشغل المخول؛ لا إنشاء صف/أمر.
  perform set_config('request.jwt.claim.sub',v_op::text,true);
  v_cmd := gen_random_uuid();
  perform pg_temp.m113_q137_refused(format(
    'select api.set_well_booking_automation(%L::uuid,true,0::bigint,%L::uuid)',
    v_wa,v_cmd),'PA3: new ON disabled','0A000','^legacy_booking_automation_disabled$');
  perform pg_temp.m113_q137_refused(format(
    'select api.set_well_booking_automation(%L::uuid,false,0::bigint,%L::uuid)',
    v_wa,v_cmd),'PA6: new OFF disabled','0A000','^legacy_booking_automation_disabled$');
  perform pg_temp.m113_q137_refused(format(
    'select ops.set_well_booking_automation(%L::uuid,true,null,%L::uuid,%L::uuid)',
    v_wa,v_op,gen_random_uuid()),'PA8: direct authorized setter disabled',
    '0A000','^legacy_booking_automation_disabled$');
  perform pg_temp.m113_q137_refused(format(
    'select api.set_well_booking_automation(%L::uuid,true,null,%L::uuid)',
    v_wb,gen_random_uuid()),'PA9: second well also disabled',
    '0A000','^legacy_booking_automation_disabled$');
  perform pg_temp.m113_q137_refused(format(
    'select api.set_well_booking_automation(%L::uuid,true,null,%L::uuid)',
    v_wc,gen_random_uuid()),'PA11: unassigned well remains unauthorized','42501');
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform pg_temp.m113_q137_refused(format(
    'select api.set_well_booking_automation(%L::uuid,true,0::bigint,%L::uuid)',
    v_wa,gen_random_uuid()),'PA2: owner cannot activate remotely','42501');
  perform pg_temp.m113_q137_refused(format(
    'select ops.set_well_booking_automation(%L::uuid,true,0::bigint,%L::uuid,%L::uuid)',
    v_wa,v_owner,gen_random_uuid()),'PA8a: direct owner setter unauthorized','42501');

  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  perform pg_temp.m113_q137_refused(format(
    'select api.get_well_booking_automation(%L::uuid)',v_wa),
    'PA7: inactive assignment cannot read',null,'صلاحية|وصول|غير موجود|مخول');
  perform pg_temp.m113_q137_refused(format(
    'select api.set_well_booking_automation(%L::uuid,true,0::bigint,%L::uuid)',
    v_wa,gen_random_uuid()),'PA7b: inactive assignment cannot write','42501');
  perform set_config('request.jwt.claim.sub',v_mgr::text,true);
  perform pg_temp.m113_q137_refused(format(
    'select api.get_well_booking_automation(%L::uuid)',v_wa),
    'PA7c: manager cannot read operator control',null,'صلاحية|وصول|غير موجود|مخول');
  perform pg_temp.m113_q137_refused(format(
    'select api.set_well_booking_automation(%L::uuid,true,0::bigint,%L::uuid)',
    v_wa,gen_random_uuid()),'PA7d: manager cannot write operator control','42501');

  -- صف إعدادات fixture لضمان أن اختبار UPDATE ليس صفرا لغياب الهدف.
  insert into core.well_settings(well_id) values(v_wa)
    on conflict(well_id) do nothing;
  delete from core.well_settings where well_id=v_wc;
  v_rev3 := (select booking_auto_transition_revision from core.well_settings where well_id=v_wa);
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  execute 'set local role authenticated';
  -- PA8c: لا تعديل مباشر للعمودين المحميين حتى بيد المالك الذي تسمح له
  --   سياسة 017 بتحديث الصف. لا يُفترض رمي الاستثناء دائمًا: يُفحص عدد
  --   الصفوف المتغيرة، ثم يُتحقق بقاء القيمة والمراجعة مباشرةً (PA8c2).
  execute 'reset role';
  delete from core.well_settings where well_id = v_wc;
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_rows := -1;
  v_err := null;
  begin
    update core.well_settings
      set booking_auto_transition_enabled = true,
          booking_auto_transition_revision = 999
      where well_id = v_wa;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
  exception when others then
    v_err := sqlerrm;
  end;
  if v_err is not null and position('permission denied' in v_err) > 0 then
    raise notice 'PASS PA8c: تحديث المالك المباشر للعمودين مرفوض امتيازيًا';
  elsif v_err is null and v_rows = 0 then
    raise notice 'PASS PA8c: تحديث المالك المباشر حُجب بلا صفوف متغيرة';
  else
    raise notice 'FAIL PA8c: تجاوز محتمل للحماية (rows=% خطأ=%)', v_rows, coalesce(v_err, 'لا يوجد');
  end if;

  -- PA8d: لا إدراج غير مشروع للعمودين المحميين من المالك على بئر بلا
  --   صف إعدادات، ولا أثر ولو قُبل الإدراج بصمت.
  v_rows := -1;
  v_err := null;
  begin
    insert into core.well_settings
      (well_id, booking_auto_transition_enabled, booking_auto_transition_revision)
      values (v_wc, true, 999);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
  exception when others then
    v_err := sqlerrm;
  end;
  if v_err is not null and position('permission denied' in v_err) > 0 then
    raise notice 'PASS PA8d: إدراج المالك للعمودين المحميين مرفوض امتيازيًا';
  elsif v_err is null and v_rows = 0 then
    raise notice 'PASS PA8d: إدراج المالك حُجب بلا صفوف';
  else
    raise notice 'FAIL PA8d: تجاوز محتمل للحماية (rows=% خطأ=%)', v_rows, coalesce(v_err, 'لا يوجد');
  end if;
  execute 'reset role';
  if exists (select 1 from core.well_settings
             where well_id = v_wc
               and (booking_auto_transition_enabled is distinct from false
                    or booking_auto_transition_revision <> 0))
     or (select booking_auto_transition_enabled from core.well_settings where well_id = v_wa)
        is distinct from false
     or (select booking_auto_transition_revision from core.well_settings where well_id = v_wa)
        is distinct from v_rev3 then
    raise notice 'FAIL PA8c2: محاولتا المالك المباشرتان غيّرتا ما لا يجب';
  else
    raise notice 'PASS PA8c2: القيمة والمراجعة على حالهما الصحيح رغم محاولتي المالك';
  end if;


  raise notice '--- M113-P1-A / Q137: new control writes disabled; guards retained ---';
end
$test_pa$;

-- M113-P1-B: جميع هويات تنفيذ Legacy retired by Q137؛ لا أثر جزئي.
do $test_pb$
declare
  c jsonb;
  r record;
  args text;
  statement text;
  state_before jsonb;
  chain uuid;
  session_id uuid;
  cmd uuid;
  relation text;
  actor_role text;
begin
  select data into strict c from m113_q137_context;
  session_id := (c->>'session')::uuid;
  select id into strict chain from ops.booking_transition_chains
    where well_id=(c->>'well')::uuid;
  perform set_config('request.jwt.claim.sub',c->>'op',true);

  -- المجموعة مأخوذة من حلقة retire في الهجرة، وتشمل كل overload مثبت.
  for r in
    select p.oid,n.nspname,p.proname,p.proargtypes
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace
    where (n.nspname='ops' and p.proname in (
      'execute_booking_transition','execute_booking_transition_automation',
      'execute_pending_booking_start','record_booking_transition_decision'))
      or (n.nspname='api' and p.proname in (
        'record_booking_transition_decision','execute_pending_booking_start'))
    order by n.nspname,p.proname,p.oid
  loop
    perform pg_temp.m113_q137_check(
      not pg_catalog.has_function_privilege('anon',r.oid,'EXECUTE')
      and not exists(select 1 from pg_catalog.pg_proc p,
        lateral pg_catalog.aclexplode(coalesce(p.proacl,pg_catalog.acldefault('f',p.proowner))) a
        where p.oid=r.oid and a.grantee=0 and a.privilege_type='EXECUTE'),
      'PB: anon/PUBLIC denied for '||r.oid::regprocedure::text);
    perform pg_temp.m113_q137_check(
      (select p.prosecdef=(r.nspname='ops')
        and p.proconfig @> array['search_path=pg_catalog, pg_temp']
       from pg_catalog.pg_proc p where p.oid=r.oid)
      and case when r.nspname='api' then
        pg_catalog.has_function_privilege('authenticated',r.oid,'EXECUTE')
        and pg_catalog.has_function_privilege('service_role',r.oid,'EXECUTE')
      else
        not pg_catalog.has_function_privilege('authenticated',r.oid,'EXECUTE')
        and not pg_catalog.has_function_privilege('service_role',r.oid,'EXECUTE')
      end,'PB: fixed search_path/security/grants '||r.oid::regprocedure::text);
    -- NULL مضبوط النوع يكفي هنا لاختبار الإيقاف قبل أي تفسير للحمولة؛
    -- EB/EC2B أعلاه يختبران كذلك معرفات حقيقية لصفوف التاريخ.
    select string_agg('NULL::'||pg_catalog.format_type(t,null),',' order by ord)
      into args from unnest(r.proargtypes::oid[]) with ordinality a(t,ord);
    statement := format('select %I.%I(%s)',r.nspname,r.proname,args);
    perform pg_temp.m113_q137_refused(statement,
      'PB: disabled identity '||r.oid::regprocedure::text,
      '0A000','^legacy_booking_automation_disabled$',
      case when r.nspname='api' then 'authenticated' else null end);
    -- PB0: حتى غياب هوية المستخدم لا يفتح مسار تنفيذ أو دفتر أوامر.
    perform set_config('request.jwt.claim.sub','',true);
    perform pg_temp.m113_q137_refused(statement,
      'PB0: no identity cannot activate '||r.oid::regprocedure::text,
      '0A000','^legacy_booking_automation_disabled$',
      case when r.nspname='api' then 'authenticated' else null end);
    perform set_config('request.jwt.claim.sub',c->>'op',true);
    foreach actor_role in array array['anon','authenticated','service_role'] loop
      perform pg_temp.m113_q137_refused(statement,
        'PB: '||actor_role||' closed '||r.oid::regprocedure::text,
        case when pg_catalog.has_function_privilege(actor_role,r.oid,'EXECUTE')
          then '0A000' else '42501' end,
        case when pg_catalog.has_function_privilege(actor_role,r.oid,'EXECUTE')
          then '^legacy_booking_automation_disabled$' else null end,actor_role);
    end loop;
  end loop;
  perform pg_temp.m113_q137_check(
    to_regprocedure('ops.execute_booking_transition(uuid,bigint,uuid)') is not null
    and to_regprocedure('api.record_booking_transition_decision(uuid,uuid,uuid,text,bigint,uuid)') is not null
    and to_regprocedure('api.execute_pending_booking_start(uuid,bigint,uuid)') is not null
    and to_regprocedure('ops.execute_booking_transition_automation(uuid,uuid,uuid,uuid,bigint,bigint,bigint,uuid,uuid,uuid)') is not null
    and to_regprocedure('ops.execute_pending_booking_start(uuid,bigint,uuid)') is not null
    and to_regprocedure('ops.record_booking_transition_decision(uuid,uuid,uuid,text,bigint,uuid,uuid)') is not null,
    'PB: every required production signature exists, never a vacuous loop');

  -- عقد إنهاء التاريخ يقبل replay قديمًا مصرحًا فقط؛ الطلب الجديد مرفوض.
  perform pg_temp.m113_q137_refused(format(
    'select api.end_booking_transition_chain(%L::uuid,%L::uuid)',
    session_id,gen_random_uuid()),'PB: fresh terminal API disabled',
    '0A000','^legacy_booking_automation_disabled$');
  perform pg_temp.m113_q137_refused(format(
    'select ops.end_booking_transition_chain(%L::uuid,%L::uuid,%L::uuid)',
    session_id,c->>'op',gen_random_uuid()),'PB: fresh internal terminal disabled',
    '0A000','^legacy_booking_automation_disabled$',null);

  -- جدول التاريخ ليس قناة كتابة خلفية. كل محاولة تقارن لقطة الأعمال.
  foreach relation in array array['booking_transition_chains','booking_transition_decisions'] loop
    foreach actor_role in array array['authenticated','anon'] loop
      perform pg_temp.m113_q137_dml_closed(
        format('update ops.%I set well_id=well_id',relation),
        'PB: historical UPDATE closed '||relation||'/'||actor_role,actor_role);
      perform pg_temp.m113_q137_dml_closed(
        format('delete from ops.%I',relation),
        'PB: historical DELETE closed '||relation||'/'||actor_role,actor_role);
    end loop;
  end loop;

  -- عزل قراءة قرارات تاريخية موجودة، لا نكتفي بجدول فارغ.
  insert into ops.booking_transition_decisions(
    tenant_id,well_id,chain_id,prev_session_id,next_booking_id,decision,decided_by,command_id)
  values((c->>'tenant')::uuid,(c->>'well')::uuid,chain,session_id,
    (c->>'booking')::uuid,'wait',(c->>'op')::uuid,gen_random_uuid());
  execute 'set local role authenticated';
  perform pg_temp.m113_q137_check(
    (select count(*) from ops.booking_transition_decisions where chain_id=chain)=1,
    'PB: assigned operator reads historical decision fixture');
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',c->>'other_op',true);
  execute 'set local role authenticated';
  perform pg_temp.m113_q137_check(
    not exists(select 1 from ops.booking_transition_decisions where chain_id=chain),
    'PB: historical decisions isolated by well');
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',c->>'outsider',true);
  execute 'set local role authenticated';
  perform pg_temp.m113_q137_check(
    not exists(select 1 from ops.booking_transition_decisions where chain_id=chain),
    'PB: historical decisions isolated from outsider');
  execute 'reset role';
  perform set_config('request.jwt.claim.sub',c->>'op',true);
  perform pg_temp.m113_q137_dml_closed(format(
    'insert into ops.booking_transition_decisions(tenant_id,well_id,chain_id,prev_session_id,next_booking_id,decision,decided_by,command_id) values(%L::uuid,%L::uuid,%L::uuid,%L::uuid,%L::uuid,''wait'',%L::uuid,%L::uuid)',
    c->>'tenant',c->>'well',chain,session_id,c->>'booking',c->>'op',gen_random_uuid()),
    'PB: historical decision INSERT closed');
end
$test_pb$;

rollback;

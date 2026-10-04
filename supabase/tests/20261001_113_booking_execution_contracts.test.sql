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
    if position('محتوى مختلف' in sqlerrm) > 0 then
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
     v_account, null,
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
-- M113-E2-a: سلسلة تشغيل الحجوزات الدائمة — إثبات البدء اليدوي الأول.
--   يثبت (ق-132 §ه / 252-253): لا سلسلة بمجرد حجز؛ أول بدء يدوي ناجح
--   يؤسس سلسلة active مسلّحة بجلسة بداية حقيقية؛ الرفض لا يخلّف سلسلة
--   يتيمة؛ replay لا يكرر؛ سلسلة واحدة غير منتهية لكل بئر (ضمان قاعدي)؛
--   عزل الآبار والجهات؛ لا كتابة مباشرة لأدوار التطبيق؛ ولا سلسلة لجلسة
--   حرة. (لا انتقال/إنهاء/قرار في هذه الجولة.)
-- ==============================================================
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
  v_cmd uuid;
  v_count bigint;
  v_opened uuid;
  v_status text;
  v_curr uuid;
  v_now timestamptz := date_trunc('minute', clock_timestamp());
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

  -- بئر EA-ISO: حجز جاهز، يبدؤه op2 ليُنشئ سلسلة لا يراها op1 (عزل البئر).
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

  -- EA2/EA3) أول بدء يدوي ناجح يؤسس سلسلة active مسلّحة بجلسة البداية
  --   الحقيقية، والعقد السابق (session_id/booking_id/operational_end) باقٍ.
  v_cmd := gen_random_uuid();
  v_result := api.start_irrigation_session_from_booking(
    v_bk1, v_now, v_cmd, null
  );
  v_sess1 := (v_result ->> 'session_id')::uuid;
  -- سلسلة واحدة غير منتهية لكل بئر (فهرس فريد جزئي) ⇒ قراءة الصف الواحد
  -- مباشرة بروابطه الحاكمة، لا تجميع uuid (max(uuid) غير مدعوم) ولا ترتيب
  -- uuid عشوائي. العدد يُفحص على حدة لإثبات وحدانية السلسلة.
  select count(*) into v_count
  from ops.booking_transition_chains where well_id = v_well_1;
  select opened_by_session_id, status, current_session_id
  into v_opened, v_status, v_curr
  from ops.booking_transition_chains where well_id = v_well_1;
  if v_count = 1 and v_status = 'active'
     and v_opened = v_sess1 and v_curr = v_sess1
     and v_result ? 'session_id' and v_result ? 'booking_id'
     and v_result ? 'operational_end_at'
     and (v_result ->> 'booking_id')::uuid = v_bk1 then
    raise notice 'PASS EA2/EA3: البدء اليدوي أسّس سلسلة مسلّحة بجلسة حقيقية والعقد باقٍ';
  else
    raise notice 'FAIL EA2/EA3: سلسلة أو ربط البداية غير صحيح (c=% s=% o=%)',
      v_count, v_status, v_opened;
  end if;

  -- EA5) replay مطابق لا ينشئ سلسلة ثانية.
  perform api.start_irrigation_session_from_booking(v_bk1, v_now, v_cmd, null);
  select count(*) into v_count
  from ops.booking_transition_chains where well_id = v_well_1;
  if v_count = 1 then
    raise notice 'PASS EA5: replay المطابق لم ينشئ سلسلة ثانية';
  else
    raise notice 'FAIL EA5: replay كرّر السلسلة (%).', v_count;
  end if;

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
       and v_count = 1 and v_opened = v_sess1 then
      raise notice 'PASS EA6: اختلاف الحمولة رُفض ولم يغيّر السلسلة';
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

  -- op2 يبدأ حجز بئره المعزول فتُنشأ سلسلة لا يراها op1 لاحقًا.
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_op2::text, true);
  execute 'set local role authenticated';
  perform api.start_irrigation_session_from_booking(
    v_bk_iso, v_now, gen_random_uuid(), null
  );
  execute 'reset role';

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
    raise notice 'PASS EA8a: مشغل البئر يرى سلسلته';
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
  raise notice '--- انتهى اختبار M113-E2-a: فحوص EA1..EA10 ---';
end
$test_ea$;

-- ==============================================================
-- M113-E2-b: قرارات الانتقال الدائمة (run_now / wait).
--   يثبت: تسجيل wait و run_now بلا بدء جلسة؛ هوية ووقت القرار؛ سلامة
--   الربط؛ منع القرار على سلسلة منتهية/حجز غير مؤكد/بئر آخر/مستخدم غير
--   مخوّل؛ replay بلا تكرار؛ رفض اختلاف الحمولة؛ تسلسل قرارين وتاريخهما؛
--   رفض wait لحجز حلّ موعده (753)؛ عدم مساس الجلسات/الفواتير؛ لا أثر
--   جزئي عند الرفض. (لا بدء/إكمال/انتقال فعلي في هذه الجولة.)
-- ==============================================================
do $test_eb$
declare
  v_tenant uuid;
  v_op uuid;
  v_outsider uuid;
  v_person uuid;
  v_profile uuid;
  v_well_a uuid;
  v_well_ended uuid;
  v_well_notconf uuid;
  v_well_other uuid;
  v_well_open uuid;
  v_acc uuid;
  v_farm uuid;
  v_pump uuid;
  v_b1 uuid;
  v_b_future uuid;
  v_b_due uuid;
  v_b_other uuid;
  v_chain_a uuid;
  v_sess1 uuid;
  v_chain uuid;
  v_sess uuid;
  v_bnext uuid;
  v_cmd1 uuid;
  v_cmd2 uuid;
  v_result jsonb;
  v_count bigint;
  v_dec text;
  v_decided_by uuid;
  v_cstatus text;
  v_cnext uuid;
  v_rev bigint;
  v_sess_before bigint;
  v_inv_before bigint;
  v_sess_after bigint;
  v_inv_after bigint;
  v_now timestamptz := date_trunc('minute', clock_timestamp());
begin
  insert into core.tenants (name)
  values ('جهة اختبار قرار الانتقال 113-EB') returning id into v_tenant;
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع القرار 113-EB', 'مزارع القرار 113-EB')
  returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_profile;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'op-113eb@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_op;
  insert into iam.profiles (id, full_name)
  values (v_op, 'مشغل 113-EB') on conflict (id) do nothing;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'outsider-113eb@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_outsider;
  insert into iam.profiles (id, full_name)
  values (v_outsider, 'غريب 113-EB') on conflict (id) do nothing;

  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EB-A') returning id into v_well_a;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EB-ENDED') returning id into v_well_ended;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EB-NOTCONF') returning id into v_well_notconf;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EB-OTHER') returning id into v_well_other;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EB-OPEN') returning id into v_well_open;

  -- المشغل معيّن على كل الآبار عدا OTHER (لإثبات رفض حجز بئر آخر).
  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well_a, v_op, 'operator', 'active'),
    (v_well_ended, v_op, 'operator', 'active'),
    (v_well_notconf, v_op, 'operator', 'active'),
    (v_well_open, v_op, 'operator', 'active');

  -- بئر A: حساب/أرض/مضخة/تسعير + ثلاثة حجوزات مؤكدة غير متداخلة:
  --   b1 ماضٍ (تبدأ منه السلسلة ثم تُغلق)، b_due مستحق، b_future مستقبلي.
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_a, 'FWA-EB-A') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_a, 'أرض EB-A', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_a, 'مضخة EB-A', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_a, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EB-A1', v_well_a, v_acc, v_farm,
     v_now - interval '3 hours', v_now - interval '2 hours', 60,
     'well_diesel', 'confirmed') returning id into v_b1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EB-A-DUE', v_well_a, v_acc, v_farm,
     v_now - interval '30 minutes', v_now + interval '30 minutes', 60,
     'well_diesel', 'confirmed') returning id into v_b_due;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EB-A-FUT', v_well_a, v_acc, v_farm,
     v_now + interval '2 hours', v_now + interval '3 hours', 60,
     'well_diesel', 'confirmed') returning id into v_b_future;

  -- حجز بئر آخر (بلا سلسلة) لإثبات رفض حجز من بئر مختلف.
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_other, 'FWA-EB-OTHER')
  returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_other, 'أرض EB-OTHER', v_acc) returning id into v_farm;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EB-OTHER', v_well_other, v_acc, v_farm,
     v_now + interval '2 hours', v_now + interval '3 hours', 60,
     'well_diesel', 'confirmed') returning id into v_b_other;

  -- تأسيس سلسلة A: بدء يدوي من b1 (E2-a) ثم إكمال الجلسة بالعقد القائم
  -- (ليست محل اختبار هنا) حتى تُحسم الجلسة السابقة قبل القرار.
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_result := api.start_irrigation_session_from_booking(
    v_b1, v_now - interval '150 minutes', gen_random_uuid(), null
  );
  v_sess1 := (v_result ->> 'session_id')::uuid;
  perform api.complete_irrigation_session(
    v_sess1, v_now - interval '2 hours', null, null, null, gen_random_uuid()
  );
  execute 'reset role';

  select id into v_chain_a
  from ops.booking_transition_chains where well_id = v_well_a;

  -- لقطة بعد حسم الجلسة السابقة: القرارات لا تمسّ الجلسات ولا الفواتير.
  select count(*) into v_sess_before
  from ops.irrigation_sessions where well_id = v_well_a;
  select count(*) into v_inv_before
  from billing.invoices inv
  join ops.irrigation_sessions s on s.id = inv.session_id
  where s.well_id = v_well_a;

  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';

  -- EB1/EB3/EB4/EB6rev) wait صحيح بالنسخة المتوقعة 0 (أول قرار): يُسجَّل
  --   بصاحبه وربطه، والسلسلة إلى waiting، والنسخة تتقدّم إلى 1.
  v_cmd1 := gen_random_uuid();
  v_result := api.record_booking_transition_decision(
    v_chain_a, v_sess1, v_b_future, 'wait', 0, v_cmd1
  );
  select decision, decided_by into v_dec, v_decided_by
  from ops.booking_transition_decisions
  where chain_id = v_chain_a and next_booking_id = v_b_future;
  select status, next_booking_id, decision_revision
  into v_cstatus, v_cnext, v_rev
  from ops.booking_transition_chains where id = v_chain_a;
  if v_result ->> 'decision' = 'wait'
     and v_result ->> 'chain_status' = 'waiting'
     and (v_result ->> 'chain_revision')::bigint = 1
     and v_dec = 'wait' and v_decided_by = v_op
     and v_cstatus = 'waiting' and v_cnext = v_b_future and v_rev = 1 then
    raise notice 'PASS EB1/EB3/EB4: wait سُجّل بالنسخة 0→1 والسلسلة إلى waiting';
  else
    raise notice 'FAIL EB1/EB3/EB4: تسجيل wait غير صحيح: %', v_result;
  end if;

  -- EB-753rev) wait لحجز حلّ موعده مرفوض برفض انطباق (لا تصنيف 753)؛ النسخة
  --   تطابق فيُختبَر سبب الانتظار لا سبب النسخة.
  begin
    perform api.record_booking_transition_decision(
      v_chain_a, v_sess1, v_b_due, 'wait', 1, gen_random_uuid()
    );
    raise notice 'FAIL EB-WAITDUE: قُبل wait لحجز حلّ موعده';
  exception when others then
    if position('لم يحن موعده' in sqlerrm) > 0
       and not exists (
         select 1 from ops.booking_transition_decisions
         where chain_id = v_chain_a and next_booking_id = v_b_due
           and decision = 'wait'
       ) then
      raise notice 'PASS EB-WAITDUE: wait لحجز مستحق رُفض لعدم الانطباق (لا 753)';
    else
      raise notice 'FAIL EB-WAITDUE: رفض wait المستحق غير صحيح: %', sqlerrm;
    end if;
  end;

  -- EB2) run_now صحيح بالنسخة 1: يُسجَّل، لا جلسة تُنشأ، current_session_id
  --   يبقى صادقًا (الجلسة المغلقة)، والسلسلة إلى pending_start لا active،
  --   والنسخة تتقدّم إلى 2.
  v_cmd2 := gen_random_uuid();
  v_result := api.record_booking_transition_decision(
    v_chain_a, v_sess1, v_b_due, 'run_now', 1, v_cmd2
  );
  select count(*) into v_count
  from ops.irrigation_sessions where well_id = v_well_a;
  select status, current_session_id, decision_revision
  into v_cstatus, v_cnext, v_rev
  from ops.booking_transition_chains where id = v_chain_a;
  if v_result ->> 'decision' = 'run_now'
     and v_result ->> 'chain_status' = 'pending_start'
     and (v_result ->> 'chain_revision')::bigint = 2
     and v_count = v_sess_before
     and v_cstatus = 'pending_start' and v_cnext = v_sess1 and v_rev = 2 then
    raise notice 'PASS EB2: run_now → pending_start بلا جلسة، والجلسة الحالية صادقة';
  else
    raise notice 'FAIL EB2: run_now غير صحيح أو أنشأ جلسة أو ادّعى حالة: %', v_result;
  end if;

  -- EB9) replay مطابق (نفس المعرّف والحمولة بالنسخة 1) يعيد الرد المخزَّن
  --   ولو تقدّمت النسخة إلى 2؛ لا سجل مكرر.
  perform api.record_booking_transition_decision(
    v_chain_a, v_sess1, v_b_due, 'run_now', 1, v_cmd2
  );
  select count(*) into v_count
  from ops.booking_transition_decisions where command_id = v_cmd2;
  if v_count = 1 then
    raise notice 'PASS EB9: replay المطابق أعاد الرد بلا تكرار رغم تقدّم النسخة';
  else
    raise notice 'FAIL EB9: replay كرّر سجل القرار (%).', v_count;
  end if;

  -- EB10) نفس المعرّف بنسخة مختلفة (جزء من البصمة) مرفوض بلا سجل إضافي.
  begin
    perform api.record_booking_transition_decision(
      v_chain_a, v_sess1, v_b_due, 'run_now', 2, v_cmd2
    );
    raise notice 'FAIL EB10: قُبل اختلاف النسخة لنفس المعرّف';
  exception when others then
    select count(*) into v_count
    from ops.booking_transition_decisions where command_id = v_cmd2;
    if position('محتوى مختلف' in sqlerrm) > 0 and v_count = 1 then
      raise notice 'PASS EB10: اختلاف النسخة لنفس المعرّف رُفض بلا سجل إضافي';
    else
      raise notice 'FAIL EB10: رفض اختلاف النسخة غير صحيح: %', sqlerrm;
    end if;
  end;

  -- EB-STALE) نسخة قديمة (1 والحالي 2) بمعرّف جديد مرفوضة بلا كتابة.
  begin
    perform api.record_booking_transition_decision(
      v_chain_a, v_sess1, v_b_due, 'run_now', 1, gen_random_uuid()
    );
    raise notice 'FAIL EB-STALE: قُبلت نسخة قرار قديمة';
  exception when others then
    select decision_revision into v_rev
    from ops.booking_transition_chains where id = v_chain_a;
    if position('نسخة' in sqlerrm) > 0 and v_rev = 2 then
      raise notice 'PASS EB-STALE: النسخة القديمة رُفضت دون تغيير النسخة الحالية';
    else
      raise notice 'FAIL EB-STALE: رفض النسخة القديمة غير صحيح: %', sqlerrm;
    end if;
  end;

  -- EB-FRESH) تغيير قرار مقصود بالنسخة الحالية 2 يُقبل ويرفعها إلى 3.
  v_result := api.record_booking_transition_decision(
    v_chain_a, v_sess1, v_b_future, 'wait', 2, gen_random_uuid()
  );
  select status, decision_revision into v_cstatus, v_rev
  from ops.booking_transition_chains where id = v_chain_a;
  if (v_result ->> 'chain_revision')::bigint = 3
     and v_cstatus = 'waiting' and v_rev = 3 then
    raise notice 'PASS EB-FRESH: تغيير قرار بالنسخة الحالية قُبل ورفعها إلى 3';
  else
    raise notice 'FAIL EB-FRESH: تغيير القرار الطازج غير صحيح: %', v_result;
  end if;

  -- EB11) تاريخ القرارات محفوظ (ثلاثة صفوف) والأحدث يحكم الحالة والنسخة.
  select count(*) into v_count
  from ops.booking_transition_decisions where chain_id = v_chain_a;
  select last_decision, decision_revision into v_dec, v_rev
  from ops.booking_transition_chains where id = v_chain_a;
  if v_count = 3 and v_dec = 'wait' and v_rev = 3 then
    raise notice 'PASS EB11: تاريخ القرارات محفوظ والأحدث حكم الحالة والنسخة';
  else
    raise notice 'FAIL EB11: تسلسل القرارات غير صحيح (c=% d=% r=%)',
      v_count, v_dec, v_rev;
  end if;

  -- EB7) حجز من بئر آخر مرفوض (بالنسخة الحالية 3).
  begin
    perform api.record_booking_transition_decision(
      v_chain_a, v_sess1, v_b_other, 'run_now', 3, gen_random_uuid()
    );
    raise notice 'FAIL EB7: قُبل حجز من بئر آخر';
  exception when others then
    if position('بئر' in sqlerrm) > 0 then
      raise notice 'PASS EB7: حجز بئر آخر مرفوض';
    else
      raise notice 'FAIL EB7: رفض حجز البئر الآخر غير صحيح: %', sqlerrm;
    end if;
  end;

  -- EB8) مستخدم غير مخوّل مرفوض برسالة عامة لا تكشف حالة السلسلة/النسخة.
  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  begin
    perform api.record_booking_transition_decision(
      v_chain_a, v_sess1, v_b_due, 'run_now', 3, gen_random_uuid()
    );
    raise notice 'FAIL EB8: غير مخوّل اتخذ قرارًا';
  exception when others then
    if (position('وصول' in sqlerrm) > 0 or position('صلاحية' in sqlerrm) > 0)
       and position('pending_start' in sqlerrm) = 0
       and position('waiting' in sqlerrm) = 0 then
      raise notice 'PASS EB8: غير المخوّل مرفوض برسالة عامة لا تكشف الحالة';
    else
      raise notice 'FAIL EB8: رفض غير المخوّل غير صحيح أو كاشف: %', sqlerrm;
    end if;
  end;
  perform set_config('request.jwt.claim.sub', v_op::text, true);

  -- EB5) سلسلة منتهية: القرار مرفوض.
  execute 'reset role';
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_ended, 'FWA-EB-END')
  returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_ended, 'أرض EB-END', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_ended, 'مضخة EB-END', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_ended, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EB-END1', v_well_ended, v_acc, v_farm,
     v_now - interval '3 hours', v_now - interval '2 hours', 60,
     'well_diesel', 'confirmed') returning id into v_bnext;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_result := api.start_irrigation_session_from_booking(
    v_bnext, v_now - interval '150 minutes', gen_random_uuid(), null
  );
  v_sess := (v_result ->> 'session_id')::uuid;
  perform api.complete_irrigation_session(
    v_sess, v_now - interval '2 hours', null, null, null, gen_random_uuid()
  );
  execute 'reset role';
  select id into v_chain
  from ops.booking_transition_chains where well_id = v_well_ended;
  update ops.booking_transition_chains
  set status = 'ended', ended_at = v_now, ended_reason = 'test'
  where id = v_chain;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EB-END2', v_well_ended, v_acc, v_farm,
     v_now + interval '2 hours', v_now + interval '3 hours', 60,
     'well_diesel', 'confirmed') returning id into v_bnext;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  begin
    perform api.record_booking_transition_decision(
      v_chain, v_sess, v_bnext, 'run_now', 0, gen_random_uuid()
    );
    raise notice 'FAIL EB5: قُبل قرار على سلسلة منتهية';
  exception when others then
    if position('منتهية' in sqlerrm) > 0 then
      raise notice 'PASS EB5: القرار على سلسلة منتهية مرفوض';
    else
      raise notice 'FAIL EB5: رفض السلسلة المنتهية غير صحيح: %', sqlerrm;
    end if;
  end;

  -- EB6) حجز تالٍ غير مؤكد: القرار مرفوض.
  execute 'reset role';
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_notconf, 'FWA-EB-NC')
  returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_notconf, 'أرض EB-NC', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_notconf, 'مضخة EB-NC', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_notconf, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EB-NC1', v_well_notconf, v_acc, v_farm,
     v_now - interval '3 hours', v_now - interval '2 hours', 60,
     'well_diesel', 'confirmed') returning id into v_bnext;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EB-NC-DRAFT', v_well_notconf, v_acc, v_farm,
     v_now + interval '2 hours', v_now + interval '3 hours', 60,
     'well_diesel', 'draft') returning id into v_b_other;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_result := api.start_irrigation_session_from_booking(
    v_bnext, v_now - interval '150 minutes', gen_random_uuid(), null
  );
  v_sess := (v_result ->> 'session_id')::uuid;
  perform api.complete_irrigation_session(
    v_sess, v_now - interval '2 hours', null, null, null, gen_random_uuid()
  );
  execute 'reset role';
  select id into v_chain
  from ops.booking_transition_chains where well_id = v_well_notconf;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  begin
    perform api.record_booking_transition_decision(
      v_chain, v_sess, v_b_other, 'run_now', 0, gen_random_uuid()
    );
    raise notice 'FAIL EB6: قُبل قرار على حجز غير مؤكد';
  exception when others then
    if position('غير مؤكد' in sqlerrm) > 0 then
      raise notice 'PASS EB6: القرار على حجز غير مؤكد مرفوض';
    else
      raise notice 'FAIL EB6: رفض الحجز غير المؤكد غير صحيح: %', sqlerrm;
    end if;
  end;

  -- EB-OPEN) جلسة سابقة ما زالت مفتوحة: القرار مرفوض (لا أثر جزئي).
  execute 'reset role';
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_open, 'FWA-EB-OPEN')
  returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_open, 'أرض EB-OPEN', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_open, 'مضخة EB-OPEN', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_open, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EB-OPEN1', v_well_open, v_acc, v_farm,
     v_now - interval '30 minutes', v_now + interval '30 minutes', 60,
     'well_diesel', 'confirmed') returning id into v_bnext;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EB-OPEN2', v_well_open, v_acc, v_farm,
     v_now + interval '2 hours', v_now + interval '3 hours', 60,
     'well_diesel', 'confirmed') returning id into v_b_other;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_result := api.start_irrigation_session_from_booking(
    v_bnext, v_now - interval '10 minutes', gen_random_uuid(), null
  );
  v_sess := (v_result ->> 'session_id')::uuid;  -- تبقى مفتوحة (لا إكمال)
  execute 'reset role';
  select id into v_chain
  from ops.booking_transition_chains where well_id = v_well_open;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  begin
    perform api.record_booking_transition_decision(
      v_chain, v_sess, v_b_other, 'run_now', 0, gen_random_uuid()
    );
    raise notice 'FAIL EB-OPEN: قُبل قرار والجلسة السابقة مفتوحة';
  exception when others then
    if (position('حسم' in sqlerrm) > 0 or position('مفتوحة' in sqlerrm) > 0)
       and not exists (
         select 1 from ops.booking_transition_decisions
         where chain_id = v_chain
       ) then
      raise notice 'PASS EB-OPEN: القرار مرفوض قبل حسم السابقة بلا أثر جزئي';
    else
      raise notice 'FAIL EB-OPEN: رفض الجلسة المفتوحة غير صحيح: %', sqlerrm;
    end if;
  end;

  -- EB12) القرارات لم تمسّ جلسات أو فواتير بئر A.
  execute 'reset role';
  select count(*) into v_sess_after
  from ops.irrigation_sessions where well_id = v_well_a;
  select count(*) into v_inv_after
  from billing.invoices inv
  join ops.irrigation_sessions s on s.id = inv.session_id
  where s.well_id = v_well_a;
  if v_sess_after = v_sess_before and v_inv_after = v_inv_before then
    raise notice 'PASS EB12: القرارات لم تُنشئ جلسة ولا فاتورة';
  else
    raise notice 'FAIL EB12: تغيّرت الجلسات/الفواتير (s %/% inv %/%)',
      v_sess_after, v_sess_before, v_inv_after, v_inv_before;
  end if;

  raise notice '--- انتهى اختبار M113-E2-b: فحوص EB + pending_start/revision/stale/fresh ---';
end
$test_eb$;

-- ==============================================================
-- M113-E2-c1: إكمال جلسة محجوزة واعٍ بالسلسلة (المرحلة الأولى).
--   يثبت: إكمال محاسبي عبر العقد القائم؛ مصالحة السلسلة إلى
--   decision_required بالزناد (أي مسار، بما فيه M084 القديم)؛ لا waiting
--   تلقائي لمجرد موعد مستقبلي؛ لا بدء تالٍ؛ حارس ended_at المستقبلي؛ رفض
--   زمن قبل البداية؛ لا تسوية مكررة؛ replay/اختلاف الحمولة/التنافس؛ عزل؛
--   المسار الحر دون مساس؛ وثبات دليل البداية وسجل القرارات.
-- ==============================================================
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

  -- EC5/EC6/EC16) السلسلة إلى decision_required (لا waiting لمجرد حجز تالٍ
  --   مستقبلي، ولا active، ولا ended)؛ دليل البداية ثابت، النسخة بلا رفع،
  --   ولا سجل قرار أُدخل نيابةً.
  select status, opened_by_session_id, decision_revision
  into v_cstatus, v_opened, v_rev
  from ops.booking_transition_chains where id = v_chain_main;
  if v_cstatus = 'decision_required'
     and v_opened = v_s_main and v_rev = 0
     and not exists (select 1 from ops.booking_transition_decisions
                     where chain_id = v_chain_main) then
    raise notice 'PASS EC5/EC6/EC16: السلسلة decision_required، لا waiting تلقائي ولا قرار منتحل';
  else
    raise notice 'FAIL EC5/EC6/EC16: حالة السلسلة بعد الإكمال غير صحيحة (s=% r=%)',
      v_cstatus, v_rev;
  end if;

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

  -- EC15) الإكمال القديم (M084) يصالح السلسلة إلى decision_required.
  perform api.complete_irrigation_session(
    v_s_legacy, v_now - interval '5 minutes', null, null, null, gen_random_uuid()
  );
  select status into v_cstatus
  from ops.booking_transition_chains where well_id = v_well_legacy;
  if v_cstatus = 'decision_required'
     and exists (select 1 from ops.irrigation_sessions
                 where id = v_s_legacy and status = 'closed') then
    raise notice 'PASS EC15: المسار القديم أغلق الجلسة وصالح السلسلة بالزناد';
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
  if v_cstatus = 'decision_required'
     and not exists (select 1 from ops.irrigation_sessions
                     where booking_id = v_bd2) then
    raise notice 'PASS EC7: مع تالٍ مستحق — decision_required والتالي لم يُسجَّل كبادئ';
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
-- M113-E2-c1-S1: forgotten ليس إكمالًا محاسبيًا — لا يصالح السلسلة.
--   يثبت: open→forgotten لا يحوّل السلسلة إلى decision_required ولا يسجّل
--   قرارًا ولا ينشئ تسوية زائفة ولا يمسّ دليل البداية أو decision_revision؛
--   بينما open→closed الصحيح ما زال يصالح إلى decision_required دون بدء
--   الحجز التالي.
-- ==============================================================
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

  -- ECF1) جلسة محجوزة مرتبطة بسلسلة تبدأ open والسلسلة active.
  if exists (select 1 from ops.irrigation_sessions
             where id = v_s_f and status = 'open')
     and (select status from ops.booking_transition_chains
          where id = v_chain_f) = 'active' then
    raise notice 'PASS ECF1: الجلسة open والسلسلة active عند البدء';
  else
    raise notice 'FAIL ECF1: حالة البدء غير متوقعة';
  end if;

  -- تحويل مباشر إلى forgotten (كـsuperuser): لا عقد يكتبها، فنحاكيها هنا.
  update ops.irrigation_sessions
  set status = 'forgotten', ended_at = v_now - interval '5 minutes'
  where id = v_s_f;

  -- ECF2..ECF6) forgotten لا يصالح السلسلة ولا يسجّل قرارًا ولا تسوية،
  --   ودليل البداية والنسخة ثابتان.
  select status, opened_by_session_id, decision_revision
  into v_cstatus, v_opened, v_rev
  from ops.booking_transition_chains where id = v_chain_f;
  if v_cstatus = 'active'
     and v_opened = v_s_f and v_rev = 0
     and not exists (select 1 from ops.booking_transition_decisions
                     where chain_id = v_chain_f)
     and not exists (select 1 from billing.session_charges
                     where session_id = v_s_f) then
    raise notice 'PASS ECF2-6: forgotten أبقى السلسلة active بلا قرار ولا تسوية زائفة';
  else
    raise notice 'FAIL ECF2-6: forgotten أثّر على السلسلة أو التسوية (s=% r=%)',
      v_cstatus, v_rev;
  end if;

  -- بئر C: إغلاق محاسبي صحيح عبر الغلاف الجديد ما زال يصالح السلسلة.
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

  -- ECF7/ECF8) الإغلاق الصحيح يصالح إلى decision_required ولا يبدأ التالي.
  select status into v_cstatus
  from ops.booking_transition_chains where well_id = v_well_c;
  if v_cstatus = 'decision_required'
     and not exists (select 1 from ops.irrigation_sessions
                     where booking_id = v_bc_next) then
    raise notice 'PASS ECF7/ECF8: الإغلاق الصحيح صالح السلسلة بلا بدء التالي';
  else
    raise notice 'FAIL ECF7/ECF8: مصالحة الإغلاق الصحيح غير سليمة (s=%)', v_cstatus;
  end if;

  raise notice '--- انتهى اختبار M113-E2-c1-S1: forgotten لا يصالح، closed يصالح ---';
end
$test_ecf$;

-- ==============================================================
-- M113-E2-c2-a: توحيد بدء الحجوزات مع اتساق السلسلة (بدء لاحق).
--   يثبت: بدء لاحق يحدّث current_session_id ولا ينشئ سلسلة ثانية ولا يمسّ
--   opened_by_session_id؛ بوابة تسوية السابقة (closed + session_charges،
--   لا forgotten)؛ إغلاق مباشر بلا تسوية يمنع التالي؛ forgotten يمنع
--   التالي؛ الحجز المستهلك لا ينشئ جلسة ثانية؛ replay/اختلاف الحمولة؛
--   المسار الحر دون مساس. (لا تشغيل تلقائي ولا pending_start executor.)
-- ==============================================================
do $test_ec2$
declare
  v_tenant uuid;
  v_op uuid;
  v_person uuid;
  v_profile uuid;
  v_well_x uuid;
  v_well_dc uuid;
  v_well_fg uuid;
  v_well_free uuid;
  v_acc uuid;
  v_farm uuid;
  v_pump uuid;
  v_acc_free uuid;
  v_farm_free uuid;
  v_pump_free uuid;
  v_b1 uuid;
  v_b2 uuid;
  v_dc1 uuid;
  v_dc2 uuid;
  v_fg1 uuid;
  v_fg2 uuid;
  v_s1 uuid;
  v_s2 uuid;
  v_sx uuid;
  v_chain uuid;
  v_cstatus text;
  v_opened uuid;
  v_curr uuid;
  v_cnt bigint;
  v_cmd uuid;
  v_result jsonb;
  v_now timestamptz := date_trunc('minute', clock_timestamp());
begin
  insert into core.tenants (name)
  values ('جهة اختبار البدء اللاحق 113-EC2') returning id into v_tenant;
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع EC2', 'مزارع EC2') returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_profile;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'op-113ec2@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_op;
  insert into iam.profiles (id, full_name)
  values (v_op, 'مشغل EC2') on conflict (id) do nothing;

  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EC2-X') returning id into v_well_x;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EC2-DC') returning id into v_well_dc;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EC2-FG') returning id into v_well_fg;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EC2-FREE') returning id into v_well_free;
  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well_x, v_op, 'operator', 'active'),
    (v_well_dc, v_op, 'operator', 'active'),
    (v_well_fg, v_op, 'operator', 'active'),
    (v_well_free, v_op, 'operator', 'active');

  -- بئر X: b1 ماضٍ (بدء أول + إكمال)، b2 مستحق (بدء لاحق).
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_x, 'FWA-EC2-X') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_x, 'أرض EC2-X', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_x, 'مضخة EC2-X', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_x, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC2-X1', v_well_x, v_acc, v_farm,
     v_now - interval '3 hours', v_now - interval '2 hours', 60,
     'well_diesel', 'confirmed') returning id into v_b1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC2-X2', v_well_x, v_acc, v_farm,
     v_now - interval '30 minutes', v_now + interval '30 minutes', 60,
     'well_diesel', 'confirmed') returning id into v_b2;

  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_result := api.start_irrigation_session_from_booking(
    v_b1, v_now - interval '150 minutes', gen_random_uuid(), null
  );
  v_s1 := (v_result ->> 'session_id')::uuid;
  perform api.complete_booking_session(
    v_s1, v_now - interval '2 hours', gen_random_uuid()
  );

  -- EC2-1/2/3/4) بدء لاحق صحيح: يحدّث current إلى الجلسة الجديدة، سلسلة
  --   واحدة، opened_by ثابت، والجلسة السابقة كانت مغلقة ومسوّاة.
  v_cmd := gen_random_uuid();
  v_result := api.start_irrigation_session_from_booking(
    v_b2, v_now - interval '20 minutes', v_cmd, null
  );
  v_s2 := (v_result ->> 'session_id')::uuid;
  select count(*) into v_cnt
  from ops.booking_transition_chains where well_id = v_well_x;
  select status, current_session_id, opened_by_session_id
  into v_cstatus, v_curr, v_opened
  from ops.booking_transition_chains where well_id = v_well_x;
  if v_cnt = 1 and v_cstatus = 'active'
     and v_curr = v_s2 and v_opened = v_s1 and v_s2 <> v_s1
     and (select booking_id from ops.irrigation_sessions where id = v_s2) = v_b2 then
    raise notice 'PASS EC2-1/2/3/4: بدء لاحق حدّث current ولا سلسلة ثانية ودليل البداية ثابت';
  else
    raise notice 'FAIL EC2-1/2/3/4: اتساق البدء اللاحق غير صحيح (n=% s=% cur=% op=%)',
      v_cnt, v_cstatus, v_curr, v_opened;
  end if;

  -- EC2-11) replay مطابق للبدء اللاحق لا يكرر الجلسة ولا يغيّر السلسلة.
  v_result := api.start_irrigation_session_from_booking(
    v_b2, v_now - interval '20 minutes', v_cmd, null
  );
  select count(*) into v_cnt
  from ops.irrigation_sessions where well_id = v_well_x;
  if (v_result ->> 'session_id')::uuid = v_s2
     and v_cnt = 2
     and (select current_session_id from ops.booking_transition_chains
          where well_id = v_well_x) = v_s2 then
    raise notice 'PASS EC2-11: replay المطابق أعاد الجلسة نفسها بلا تكرار';
  else
    raise notice 'FAIL EC2-11: replay غيّر الجلسة أو السلسلة';
  end if;

  -- EC2-12) نفس المعرّف بحمولة مختلفة مرفوض.
  begin
    perform api.start_irrigation_session_from_booking(
      v_b2, v_now - interval '19 minutes', v_cmd, null
    );
    raise notice 'FAIL EC2-12: قُبل اختلاف الحمولة لنفس المعرّف';
  exception when others then
    if position('محتوى مختلف' in sqlerrm) > 0 then
      raise notice 'PASS EC2-12: اختلاف الحمولة لنفس المعرّف مرفوض';
    else
      raise notice 'FAIL EC2-12: رفض اختلاف الحمولة غير صحيح: %', sqlerrm;
    end if;
  end;

  -- EC2-9) حجز مستهلك (b2 له S2) لا ينشئ جلسة ثانية.
  begin
    perform api.start_irrigation_session_from_booking(
      v_b2, v_now - interval '18 minutes', gen_random_uuid(), null
    );
    raise notice 'FAIL EC2-9: قُبل بدء ثانٍ لحجز مستهلك';
  exception when others then
    if position('جلسة سابقة' in sqlerrm) > 0
       and (select count(*) from ops.irrigation_sessions
            where booking_id = v_b2) = 1 then
      raise notice 'PASS EC2-9: الحجز المستهلك لم ينتج جلسة ثانية';
    else
      raise notice 'FAIL EC2-9: رفض الحجز المستهلك غير صحيح: %', sqlerrm;
    end if;
  end;
  execute 'reset role';

  -- بئر DC: إغلاق مباشر بلا تسوية (الحساب التلقائي يتخطّى الجلسات ذات
  --   المقاطع) ⇒ بوابة التسوية تمنع بدء التالي.
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_dc, 'FWA-EC2-DC') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_dc, 'أرض EC2-DC', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_dc, 'مضخة EC2-DC', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_dc, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC2-DC1', v_well_dc, v_acc, v_farm,
     v_now - interval '3 hours', v_now - interval '2 hours', 60,
     'well_diesel', 'confirmed') returning id into v_dc1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC2-DC2', v_well_dc, v_acc, v_farm,
     v_now - interval '30 minutes', v_now + interval '30 minutes', 60,
     'well_diesel', 'confirmed') returning id into v_dc2;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_result := api.start_irrigation_session_from_booking(
    v_dc1, v_now - interval '150 minutes', gen_random_uuid(), null
  );
  v_sx := (v_result ->> 'session_id')::uuid;
  execute 'reset role';
  -- إغلاق مباشر بلا إكمال محاسبي (لا session_charges لجلسة ذات مقاطع).
  update ops.irrigation_sessions
  set status = 'closed', ended_at = v_now - interval '2 hours'
  where id = v_sx;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  begin
    perform api.start_irrigation_session_from_booking(
      v_dc2, v_now - interval '20 minutes', gen_random_uuid(), null
    );
    raise notice 'FAIL EC2-5: بُدئ التالي رغم غياب تسوية السابقة';
  exception when others then
    if position('تسوية' in sqlerrm) > 0
       and not exists (select 1 from ops.irrigation_sessions
                       where booking_id = v_dc2) then
      raise notice 'PASS EC2-5: إغلاق بلا تسوية منع بدء التالي';
    else
      raise notice 'FAIL EC2-5: منع البدء بلا تسوية غير صحيح: %', sqlerrm;
    end if;
  end;
  execute 'reset role';

  -- بئر FG: جلسة forgotten لا تصالح السلسلة (تبقى active)، فيُمنع البدء
  --   اللاحق (الحالة ليست decision_required/waiting).
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_fg, 'FWA-EC2-FG') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_fg, 'أرض EC2-FG', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_fg, 'مضخة EC2-FG', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_fg, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC2-FG1', v_well_fg, v_acc, v_farm,
     v_now - interval '3 hours', v_now - interval '2 hours', 60,
     'well_diesel', 'confirmed') returning id into v_fg1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC2-FG2', v_well_fg, v_acc, v_farm,
     v_now - interval '30 minutes', v_now + interval '30 minutes', 60,
     'well_diesel', 'confirmed') returning id into v_fg2;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_result := api.start_irrigation_session_from_booking(
    v_fg1, v_now - interval '150 minutes', gen_random_uuid(), null
  );
  v_sx := (v_result ->> 'session_id')::uuid;
  execute 'reset role';
  update ops.irrigation_sessions
  set status = 'forgotten', ended_at = v_now - interval '2 hours'
  where id = v_sx;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  begin
    perform api.start_irrigation_session_from_booking(
      v_fg2, v_now - interval '20 minutes', gen_random_uuid(), null
    );
    raise notice 'FAIL EC2-6: بُدئ التالي رغم جلسة سابقة forgotten';
  exception when others then
    if position('لاحق' in sqlerrm) > 0
       and not exists (select 1 from ops.irrigation_sessions
                       where booking_id = v_fg2) then
      raise notice 'PASS EC2-6: جلسة forgotten منعت بدء التالي';
    else
      raise notice 'FAIL EC2-6: منع البدء بعد forgotten غير صحيح: %', sqlerrm;
    end if;
  end;

  -- EC2-15) مسار الجلسة الحرة غير متأثر (لا سلسلة).
  execute 'reset role';
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_free, 'FWA-EC2-FR')
  returning id into v_acc_free;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_free, 'أرض EC2-FR', v_acc_free) returning id into v_farm_free;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_free, 'مضخة EC2-FR', 'diesel', 'active')
  returning id into v_pump_free;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_free, 5000, date '2026-01-01');
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_sx := api.start_irrigation_session(
    v_well_free, v_pump_free, v_farm_free, v_acc_free, 'well_diesel',
    v_now - interval '20 minutes', null, gen_random_uuid(), null
  );
  if exists (select 1 from ops.irrigation_sessions
             where id = v_sx and booking_id is null and status = 'open')
     and not exists (select 1 from ops.booking_transition_chains
                     where well_id = v_well_free) then
    raise notice 'PASS EC2-15: الجلسة الحرة بلا سلسلة ولا تأثّر بالمسار الجديد';
  else
    raise notice 'FAIL EC2-15: الجلسة الحرة تأثّرت بالسلسلة';
  end if;

  execute 'reset role';
  raise notice '--- انتهى اختبار M113-E2-c2-a: بدء لاحق واتساق السلسلة ---';
end
$test_ec2$;

-- ==============================================================
-- M113-E2-c2-b: تنفيذ قرار run_now المحفوظ (pending_start).
--   يثبت: قرار محفوظ بلا جلسة قبل التنفيذ؛ تنفيذ صحيح ينشئ جلسة واحدة
--   وينقل pending_start→active مع current الجديد ودليل بداية ثابت؛
--   replay/اختلاف الحمولة؛ wait لا يُنفَّذ؛ نسخة قرار قديمة لا تُنفَّذ؛
--   غير مخوّل مرفوض؛ والبدء اليدوي لا يتجاوز قرارًا إلزاميًا (حجز مختلف).
-- ==============================================================
do $test_ec2b$
declare
  v_tenant uuid;
  v_op uuid;
  v_outsider uuid;
  v_person uuid;
  v_profile uuid;
  v_well_x uuid;
  v_well_w uuid;
  v_acc uuid;
  v_farm uuid;
  v_pump uuid;
  v_b1 uuid;
  v_b2 uuid;
  v_b3 uuid;
  v_bw1 uuid;
  v_bw2 uuid;
  v_s1 uuid;
  v_s2 uuid;
  v_sw1 uuid;
  v_chain_x uuid;
  v_chain_w uuid;
  v_cstatus text;
  v_curr uuid;
  v_opened uuid;
  v_cnt bigint;
  v_cmd uuid;
  v_result jsonb;
  v_now timestamptz := date_trunc('minute', clock_timestamp());
begin
  insert into core.tenants (name)
  values ('جهة اختبار تنفيذ pending 113-EC2B') returning id into v_tenant;
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع EC2B', 'مزارع EC2B') returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_profile;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'op-113ec2b@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_op;
  insert into iam.profiles (id, full_name)
  values (v_op, 'مشغل EC2B') on conflict (id) do nothing;
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'outsider-113ec2b@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_outsider;
  insert into iam.profiles (id, full_name)
  values (v_outsider, 'غريب EC2B') on conflict (id) do nothing;

  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EC2B-X') returning id into v_well_x;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر EC2B-W') returning id into v_well_w;
  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well_x, v_op, 'operator', 'active'),
    (v_well_w, v_op, 'operator', 'active');

  -- بئر X: b1 (بدء أول+إكمال)، b2 (الحجز المقرَّر run_now)، b3 (حجز مختلف
  -- لاختبار منع تجاوز القرار). غير متداخلة.
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_x, 'FWA-EC2B-X') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_x, 'أرض EC2B-X', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_x, 'مضخة EC2B-X', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_x, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC2B-X1', v_well_x, v_acc, v_farm,
     v_now - interval '3 hours', v_now - interval '2 hours', 60,
     'well_diesel', 'confirmed') returning id into v_b1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC2B-X2', v_well_x, v_acc, v_farm,
     v_now - interval '30 minutes', v_now + interval '30 minutes', 60,
     'well_diesel', 'confirmed') returning id into v_b2;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC2B-X3', v_well_x, v_acc, v_farm,
     v_now + interval '1 hour', v_now + interval '2 hours', 60,
     'well_diesel', 'confirmed') returning id into v_b3;

  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_result := api.start_irrigation_session_from_booking(
    v_b1, v_now - interval '150 minutes', gen_random_uuid(), null
  );
  v_s1 := (v_result ->> 'session_id')::uuid;
  perform api.complete_booking_session(
    v_s1, v_now - interval '2 hours', gen_random_uuid()
  );
  execute 'reset role';
  select id into v_chain_x
  from ops.booking_transition_chains where well_id = v_well_x;

  -- تسجيل قرار run_now لـb2 (النسخة المتوقعة 0) ⇒ pending_start، النسخة 1.
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  perform api.record_booking_transition_decision(
    v_chain_x, v_s1, v_b2, 'run_now', 0, gen_random_uuid()
  );

  -- EC2B-1) قرار محفوظ ولا جلسة للحجز المقرَّر قبل التنفيذ.
  select status into v_cstatus
  from ops.booking_transition_chains where id = v_chain_x;
  if v_cstatus = 'pending_start'
     and not exists (select 1 from ops.irrigation_sessions where booking_id = v_b2)
  then
    raise notice 'PASS EC2B-1: قرار run_now محفوظ (pending_start) بلا جلسة بعد';
  else
    raise notice 'FAIL EC2B-1: حالة ما قبل التنفيذ غير صحيحة (s=%)', v_cstatus;
  end if;

  -- EC2B-17) البدء اليدوي لا يتجاوز القرار الإلزامي: بدء حجز مختلف (b3)
  --   من pending_start مرفوض.
  begin
    perform api.start_irrigation_session_from_booking(
      v_b3, v_now - interval '5 minutes', gen_random_uuid(), null
    );
    raise notice 'FAIL EC2B-17: بدء يدوي تجاوز قرار run_now بحجز مختلف';
  exception when others then
    if position('لاحق' in sqlerrm) > 0
       and not exists (select 1 from ops.irrigation_sessions where booking_id = v_b3)
    then
      raise notice 'PASS EC2B-17: بدء حجز مختلف من pending_start مرفوض (لا تجاوز)';
    else
      raise notice 'FAIL EC2B-17: منع التجاوز غير صحيح: %', sqlerrm;
    end if;
  end;

  -- EC2B-18) البدء اليدوي القديم لا يتجاوز عقد التنفيذ: بدء الحجز المقرَّر
  --   نفسه (b2) مباشرةً من pending_start مرفوض ويُحال لعقد التنفيذ المخصص،
  --   ولا تُنشأ له جلسة. السلسلة تبقى pending_start بلا تغيّر.
  begin
    perform api.start_irrigation_session_from_booking(
      v_b2, v_now - interval '5 minutes', gen_random_uuid(), null
    );
    raise notice 'FAIL EC2B-18: بدء يدوي مباشر نفّذ قرار pending_start المحفوظ';
  exception when others then
    if position('المخصص' in sqlerrm) > 0
       and not exists (select 1 from ops.irrigation_sessions where booking_id = v_b2)
       and (select status from ops.booking_transition_chains where id = v_chain_x)
           = 'pending_start'
    then
      raise notice 'PASS EC2B-18: البدء المباشر من pending_start مرفوض (يُنفَّذ عبر العقد)';
    else
      raise notice 'FAIL EC2B-18: منع البدء المباشر غير صحيح: %', sqlerrm;
    end if;
  end;

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

  -- EC2B-11) نسخة قرار قديمة لا تُنفَّذ (CAS على decision_revision).
  begin
    perform api.execute_pending_booking_start(
      v_chain_x, 0, gen_random_uuid()
    );
    raise notice 'FAIL EC2B-11: نُفِّذت نسخة قرار قديمة';
  exception when others then
    if position('نسخة' in sqlerrm) > 0
       and not exists (select 1 from ops.irrigation_sessions where booking_id = v_b2)
    then
      raise notice 'PASS EC2B-11: نسخة القرار القديمة رُفضت بلا تنفيذ';
    else
      raise notice 'FAIL EC2B-11: رفض النسخة القديمة غير صحيح: %', sqlerrm;
    end if;
  end;

  -- EC2B-15) غير مخوّل لا ينفّذ.
  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  begin
    perform api.execute_pending_booking_start(
      v_chain_x, 1, gen_random_uuid()
    );
    raise notice 'FAIL EC2B-15: غير مخوّل نفّذ القرار';
  exception when others then
    if position('وصول' in sqlerrm) > 0 or position('صلاحية' in sqlerrm) > 0 then
      raise notice 'PASS EC2B-15: غير المخوّل مرفوض عن التنفيذ';
    else
      raise notice 'FAIL EC2B-15: رفض غير المخوّل غير صحيح: %', sqlerrm;
    end if;
  end;
  perform set_config('request.jwt.claim.sub', v_op::text, true);

  -- EC2B-2/3/4/5) تنفيذ صحيح: جلسة واحدة، pending_start→active، current
  --   الجديد، ودليل البداية ثابت.
  v_cmd := gen_random_uuid();
  v_result := api.execute_pending_booking_start(v_chain_x, 1, v_cmd);
  v_s2 := (v_result -> 'start' ->> 'session_id')::uuid;
  select status, current_session_id, opened_by_session_id
  into v_cstatus, v_curr, v_opened
  from ops.booking_transition_chains where id = v_chain_x;
  if v_cstatus = 'active'
     and v_curr = v_s2 and v_opened = v_s1 and v_s2 <> v_s1
     and (select count(*) from ops.irrigation_sessions where booking_id = v_b2) = 1
  then
    raise notice 'PASS EC2B-2/3/4/5: التنفيذ أنشأ جلسة واحدة ونقل إلى active بدليل بداية ثابت';
  else
    raise notice 'FAIL EC2B-2/3/4/5: نتيجة التنفيذ غير صحيحة (s=% cur=% op=%)',
      v_cstatus, v_curr, v_opened;
  end if;

  -- EC2B-8) replay مطابق لا ينشئ جلسة ثانية.
  v_result := api.execute_pending_booking_start(v_chain_x, 1, v_cmd);
  if (select count(*) from ops.irrigation_sessions where booking_id = v_b2) = 1
     and (select current_session_id from ops.booking_transition_chains
          where id = v_chain_x) = v_s2 then
    raise notice 'PASS EC2B-8: replay المطابق لم ينشئ جلسة ثانية';
  else
    raise notice 'FAIL EC2B-8: replay كرّر الجلسة';
  end if;

  -- EC2B-9) نفس المعرّف بنسخة مختلفة (حمولة مختلفة) مرفوض.
  begin
    perform api.execute_pending_booking_start(v_chain_x, 5, v_cmd);
    raise notice 'FAIL EC2B-9: قُبل اختلاف الحمولة لنفس المعرّف';
  exception when others then
    if position('محتوى مختلف' in sqlerrm) > 0 then
      raise notice 'PASS EC2B-9: اختلاف النسخة لنفس المعرّف مرفوض';
    else
      raise notice 'FAIL EC2B-9: رفض اختلاف الحمولة غير صحيح: %', sqlerrm;
    end if;
  end;
  execute 'reset role';

  -- بئر W: قرار wait لا يصلح إذن تشغيل فوري — التنفيذ يُرفض.
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_w, 'FWA-EC2B-W') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_w, 'أرض EC2B-W', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_w, 'مضخة EC2B-W', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_w, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC2B-W1', v_well_w, v_acc, v_farm,
     v_now - interval '3 hours', v_now - interval '2 hours', 60,
     'well_diesel', 'confirmed') returning id into v_bw1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-EC2B-W2', v_well_w, v_acc, v_farm,
     v_now + interval '2 hours', v_now + interval '3 hours', 60,
     'well_diesel', 'confirmed') returning id into v_bw2;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_result := api.start_irrigation_session_from_booking(
    v_bw1, v_now - interval '150 minutes', gen_random_uuid(), null
  );
  v_sw1 := (v_result ->> 'session_id')::uuid;
  perform api.complete_booking_session(
    v_sw1, v_now - interval '2 hours', gen_random_uuid()
  );
  execute 'reset role';
  select id into v_chain_w
  from ops.booking_transition_chains where well_id = v_well_w;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  perform api.record_booking_transition_decision(
    v_chain_w, v_sw1, v_bw2, 'wait', 0, gen_random_uuid()
  );

  -- EC2B-10) تنفيذ قرار بينما السلسلة waiting (لا pending_start) مرفوض.
  begin
    perform api.execute_pending_booking_start(
      v_chain_w, 1, gen_random_uuid()
    );
    raise notice 'FAIL EC2B-10: نُفِّذ تشغيل فوري على قرار wait';
  exception when others then
    if position('تشغيل فوري نافذ' in sqlerrm) > 0
       and not exists (select 1 from ops.irrigation_sessions where booking_id = v_bw2)
    then
      raise notice 'PASS EC2B-10: قرار wait لا يُنفَّذ كتشغيل فوري';
    else
      raise notice 'FAIL EC2B-10: رفض تنفيذ wait غير صحيح: %', sqlerrm;
    end if;
  end;

  execute 'reset role';
  raise notice '--- انتهى اختبار M113-E2-c2-b: تنفيذ pending_start ---';
end
$test_ec2b$;

-- =====================================================================
-- M113-E2-d: اتساق المُقيّم ومسح مؤشر الحجز المستهلَك.
--   يثبت: رؤية السلسلة الدائمة في المُقيّم (chain_armed/chain_status/
--   pending_execution)، تمييز الجلسة المفتوحة عن جلسة السلسلة المغلقة،
--   safe_to_auto_start المحافظ، ومسح next_booking_id عند استهلاكه في
--   تنفيذ pending_start والبدء المبكر أثناء waiting. قراءة فقط للمُقيّم.
-- =====================================================================
do $test_ed$
declare
  v_tenant uuid;
  v_person uuid;
  v_profile uuid;
  v_op uuid;
  v_outsider uuid;
  v_well_x uuid;
  v_well_y uuid;
  v_acc uuid;
  v_farm uuid;
  v_pump uuid;
  v_b1 uuid;
  v_b2 uuid;
  v_bw1 uuid;
  v_bw2 uuid;
  v_s1 uuid;
  v_s2 uuid;
  v_sw1 uuid;
  v_chain_x uuid;
  v_chain_y uuid;
  v_res jsonb;
  v_cstatus text;
  v_cnext uuid;
  v_ccur uuid;
  v_cmd uuid;
  v_cnt bigint;
  v_now timestamptz := date_trunc('minute', clock_timestamp());
begin
  insert into core.tenants (name)
  values ('جهة اختبار M113-E2-d') returning id into v_tenant;
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع ED', 'مزارع ED') returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_profile;

  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'op-113ed@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_op;
  insert into iam.profiles (id, full_name)
  values (v_op, 'مشغل ED') on conflict (id) do nothing;
  insert into auth.users
    (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'outsider-113ed@test.local',
     crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_outsider;
  insert into iam.profiles (id, full_name)
  values (v_outsider, 'غريب ED') on conflict (id) do nothing;

  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر ED-X') returning id into v_well_x;
  insert into core.wells (tenant_id, name) values
    (v_tenant, 'بئر ED-Y') returning id into v_well_y;
  insert into core.well_assignments (well_id, profile_id, role, status)
  values
    (v_well_x, v_op, 'operator', 'active'),
    (v_well_y, v_op, 'operator', 'active');
  -- بئر X: b1 (بدء+إكمال → decision_required)، b2 (مستحق: run_now ثم تنفيذ).
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_x, 'FWA-ED-X') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_x, 'أرض ED-X', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_x, 'مضخة ED-X', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_x, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-ED-X1', v_well_x, v_acc, v_farm,
     v_now - interval '3 hours', v_now - interval '2 hours', 60,
     'well_diesel', 'confirmed') returning id into v_b1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-ED-X2', v_well_x, v_acc, v_farm,
     v_now - interval '30 minutes', v_now + interval '30 minutes', 60,
     'well_diesel', 'confirmed') returning id into v_b2;

  -- بئر Y: bw1 (بدء+إكمال → decision_required)، bw2 (مستقبلي: wait ثم بدء
  -- يدوي مبكر مشروع).
  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_profile, v_well_y, 'FWA-ED-Y') returning id into v_acc;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well_y, 'أرض ED-Y', v_acc) returning id into v_farm;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_well_y, 'مضخة ED-Y', 'diesel', 'active') returning id into v_pump;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_well_y, 5000, date '2026-01-01');
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-ED-Y1', v_well_y, v_acc, v_farm,
     v_now - interval '3 hours', v_now - interval '2 hours', 60,
     'well_diesel', 'confirmed') returning id into v_bw1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values
    (v_tenant, 'BKG-ED-Y2', v_well_y, v_acc, v_farm,
     v_now + interval '2 hours', v_now + interval '3 hours', 60,
     'well_diesel', 'confirmed') returning id into v_bw2;
  -- ED1 (STEP 5.1) لا سلسلة → أول بدء يدوي مطلوب، بلا رؤية سلسلة.
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_res := api.evaluate_well_booking_transition(v_well_x);
  if not (v_res ->> 'chain_armed')::boolean
     and v_res ->> 'chain_status' is null
     and v_res -> 'chain' = 'null'::jsonb
     and (v_res ->> 'requires_manual_start')::boolean
     and v_res ->> 'decision' = 'manual_start_required'
     and not (v_res ->> 'safe_to_auto_start')::boolean then
    raise notice 'PASS ED1: لا سلسلة → بدء يدوي أول بلا رؤية سلسلة';
  else
    raise notice 'FAIL ED1: حالة ما قبل السلسلة غير صحيحة: %', v_res;
  end if;

  -- أول بدء يدوي من b1 بزمن ماضٍ (الجلسة لم تبلغ حدها بعد).
  v_res := api.start_irrigation_session_from_booking(
    v_b1, v_now - interval '30 minutes', gen_random_uuid(), null
  );
  v_s1 := (v_res ->> 'session_id')::uuid;

  -- ED2 (STEP 5.2) أول بدء ناجح → سلسلة active مُسلّحة بجلسة مفتوحة.
  v_res := api.evaluate_well_booking_transition(v_well_x);
  if (v_res ->> 'chain_armed')::boolean
     and v_res ->> 'chain_status' = 'active'
     and (v_res ->> 'has_open_session')::boolean
     and (v_res -> 'chain' ->> 'current_session_id')::uuid = v_s1 then
    raise notice 'PASS ED2: أول بدء ناجح → سلسلة active مُسلّحة بجلسة مفتوحة';
  else
    raise notice 'FAIL ED2: حالة ما بعد أول بدء غير صحيحة: %', v_res;
  end if;

  -- ED3 (STEP 5.3) جلسة مفتوحة ليست إذنًا تلقائيًا ببدء التالي.
  if not (v_res ->> 'safe_to_auto_start')::boolean
     and (v_res ->> 'requires_atomic_recheck')::boolean then
    raise notice 'PASS ED3: جلسة مفتوحة ليست safe_to_auto_start';
  else
    raise notice 'FAIL ED3: جلسة مفتوحة مثّلت إذنًا تلقائيًا: %', v_res;
  end if;

  -- إكمال b1 (إغلاق محاسبي صحيح) → السلسلة decision_required بالزناد.
  perform api.complete_booking_session(v_s1, v_now, gen_random_uuid());
  -- chain_id عبر reset role (كتابة السلسلة محجوبة؛ قراءة الـid للعمليات).
  execute 'reset role';
  select id into v_chain_x
  from ops.booking_transition_chains where well_id = v_well_x;

  -- ED9/ED10/ED11 (STEP 5.9/5.10/5.11) بعد الإغلاق: مرجع جلسة مغلقة صادق،
  -- لا قرار منتحل، وبلوغ موعد b2 لا يثبت بدءًا فائتًا.
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_res := api.evaluate_well_booking_transition(v_well_x);
  if v_res ->> 'chain_status' = 'decision_required'
     and (v_res -> 'chain' ->> 'current_session_id')::uuid = v_s1
     and not (v_res ->> 'has_open_session')::boolean
     and v_res -> 'chain' ->> 'last_decision' is null then
    raise notice 'PASS ED9/ED10: مرجع الجلسة المغلقة صادق ولا قرار منتحل';
  else
    raise notice 'FAIL ED9/ED10: حالة ما بعد الإغلاق غير صحيحة: %', v_res;
  end if;
  if v_res ->> 'decision' = 'manual_start_required'
     and v_res ? 'missed_exact_start_note'
     and v_res -> 'next_booking' ->> 'id' = v_b2::text then
    raise notice 'PASS ED11: موعد مستحق لا يثبت بدءًا فائتًا (بدء يدوي صريح)';
  else
    raise notice 'FAIL ED11: تفسير الموعد الفائت غير صحيح: %', v_res;
  end if;

  -- تسجيل قرار run_now لـb2 (النسخة 0) ⇒ pending_start، النسخة 1، next=b2.
  perform api.record_booking_transition_decision(
    v_chain_x, v_s1, v_b2, 'run_now', 0, gen_random_uuid()
  );

  -- ED5 (STEP 5.5) pending_start يظهر «تنفيذ معلّق» لا جلسة بدأت.
  v_res := api.evaluate_well_booking_transition(v_well_x);
  if v_res ->> 'chain_status' = 'pending_start'
     and (v_res ->> 'pending_execution')::boolean
     and (v_res -> 'chain' ->> 'next_booking_id')::uuid = v_b2
     and not (v_res ->> 'has_open_session')::boolean then
    raise notice 'PASS ED5: pending_start → تنفيذ معلّق والمؤشر على b2 بلا جلسة';
  else
    raise notice 'FAIL ED5: تمثيل pending_start غير صحيح: %', v_res;
  end if;
  -- ED8 (STEP 5.8) فشل البدء يحفظ الحالة والمؤشر: نسخة قديمة (CAS) تُرفَض،
  -- فتبقى pending_start والمؤشر على b2 دون تغيير ذري.
  begin
    perform api.execute_pending_booking_start(v_chain_x, 0, gen_random_uuid());
    raise notice 'FAIL ED8: نُفِّذت نسخة قرار قديمة';
  exception when others then
    v_res := api.evaluate_well_booking_transition(v_well_x);
    if position('نسخة' in sqlerrm) > 0
       and v_res ->> 'chain_status' = 'pending_start'
       and (v_res -> 'chain' ->> 'next_booking_id')::uuid = v_b2 then
      raise notice 'PASS ED8: فشل البدء أبقى pending_start والمؤشر سليمين';
    else
      raise notice 'FAIL ED8: حالة/مؤشر بعد الفشل غير سليمين: % / %', sqlerrm, v_res;
    end if;
  end;

  -- ED6 (STEP 5.6) تنفيذ pending_start بالنسخة الصحيحة: جلسة جديدة current،
  -- والمؤشر المستهلَك يُمسح، والسلسلة active.
  v_cmd := gen_random_uuid();
  v_res := api.execute_pending_booking_start(v_chain_x, 1, v_cmd);
  v_s2 := (v_res -> 'start' ->> 'session_id')::uuid;
  v_res := api.evaluate_well_booking_transition(v_well_x);
  if v_res ->> 'chain_status' = 'active'
     and (v_res -> 'chain' ->> 'current_session_id')::uuid = v_s2
     and v_res -> 'chain' ->> 'next_booking_id' is null
     and v_s2 <> v_s1 then
    raise notice 'PASS ED6: تنفيذ pending_start ضبط current الجديد ومسح المؤشر';
  else
    raise notice 'FAIL ED6: ما بعد التنفيذ غير صحيح: %', v_res;
  end if;

  -- ED12 (STEP 5.12) سجل القرار التاريخي باقٍ بعد التنفيذ (لا يُمحى).
  execute 'reset role';
  select count(*) into v_cnt
  from ops.booking_transition_decisions
  where chain_id = v_chain_x and decision = 'run_now' and next_booking_id = v_b2;
  if v_cnt = 1 then
    raise notice 'PASS ED12: سجل قرار run_now التاريخي باقٍ بعد التنفيذ';
  else
    raise notice 'FAIL ED12: سجل القرار التاريخي غير سليم (n=%)', v_cnt;
  end if;
  -- بئر Y (STEP 5.4/5.7): waiting ثم بدء يدوي مبكر مشروع يستهلك المؤشر.
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_res := api.start_irrigation_session_from_booking(
    v_bw1, v_now - interval '30 minutes', gen_random_uuid(), null
  );
  v_sw1 := (v_res ->> 'session_id')::uuid;
  perform api.complete_booking_session(v_sw1, v_now, gen_random_uuid());

  execute 'reset role';
  select id into v_chain_y
  from ops.booking_transition_chains where well_id = v_well_y;

  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  perform api.record_booking_transition_decision(
    v_chain_y, v_sw1, v_bw2, 'wait', 0, gen_random_uuid()
  );

  -- ED4 (STEP 5.4) قرار wait يظهر waiting لا جلسة جديدة، والمؤشر على bw2.
  v_res := api.evaluate_well_booking_transition(v_well_y);
  if v_res ->> 'chain_status' = 'waiting'
     and (v_res -> 'chain' ->> 'next_booking_id')::uuid = v_bw2
     and v_res -> 'chain' ->> 'last_decision' = 'wait'
     and not (v_res ->> 'has_open_session')::boolean then
    raise notice 'PASS ED4: قرار wait → waiting والمؤشر على bw2 بلا جلسة';
  else
    raise notice 'FAIL ED4: تمثيل waiting غير صحيح: %', v_res;
  end if;

  -- بدء يدوي مبكر مشروع لـbw2 أثناء waiting (ق-132/750) بزمن الآن.
  perform api.start_irrigation_session_from_booking(
    v_bw2, v_now, gen_random_uuid(), null
  );

  -- ED7 (STEP 5.7) البدء المبكر أثناء waiting يستهلك المؤشر الصحيح.
  v_res := api.evaluate_well_booking_transition(v_well_y);
  if v_res ->> 'chain_status' = 'active'
     and v_res -> 'chain' ->> 'next_booking_id' is null
     and (v_res ->> 'has_open_session')::boolean then
    raise notice 'PASS ED7: بدء مبكر أثناء waiting استهلك المؤشر الصحيح';
  else
    raise notice 'FAIL ED7: استهلاك المؤشر أثناء waiting غير صحيح: %', v_res;
  end if;
  -- ED13 (STEP 5.13) غير مخوّل لا يقرأ حالة السلسلة (الرفض قبل أي قراءة).
  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  begin
    perform api.evaluate_well_booking_transition(v_well_x);
    raise notice 'FAIL ED13: غير مخوّل قرأ حالة انتقال البئر';
  exception when others then
    if position('صلاحية' in sqlerrm) > 0 or position('وصول' in sqlerrm) > 0 then
      raise notice 'PASS ED13: غير المخوّل معزول عن حالة السلسلة';
    else
      raise notice 'FAIL ED13: رفض غير المخوّل غير متوقع: %', sqlerrm;
    end if;
  end;

  execute 'reset role';
  raise notice '--- انتهى اختبار M113-E2-d: اتساق المُقيّم ومسح المؤشر ---';





end
$test_ed$;

-- =====================================================================
-- M113-P1-A — ق-134 §1/§5: إعداد تشغيل/إيقاف الانتقال الآلي لكل بئر.
--   الافتراض OFF بمراجعة 0، والتحكم للمشغل المخوّل حصرًا (session.start
--   + حيازة المشغل)؛ مالك البئر يراقب ولا يتحكم عن بعد (مساره P7).
--   مراجعة تصاعدية مستقلة بلا updated_at، والعملية الداخلية ممنوحة
--   EXECUTE للأدوار المصرح بها وتحمل حراس الهوية والتفويض ودورة
--   الأمر الكاملة، ولا جلسة ولا تسوية مالية ناتجة عن تغيير الإعداد.
-- =====================================================================
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

  -- PA2: منع التحكم البعيد للمالك عبر هذا العقد قبل استكمال ضوابط
  --   هاتف المشغّل (ق-134 §5) — مساره مؤجل إلى P7، والقيمة لا تتغير.
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  begin
    perform api.set_well_booking_automation(v_wa, true, 0::bigint, gen_random_uuid());
    raise notice 'FAIL PA2: المالك تحكم في الإعداد عن بعد';
  exception when others then
    if position('P7' in sqlerrm) > 0 then
      raise notice 'PASS PA2: تحكم المالك عن بعد محجوب حتى P7';
    else
      raise notice 'FAIL PA2: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
  v_res := api.get_well_booking_automation(v_wa);
  if (v_res ->> 'booking_auto_transition_enabled')::boolean is false
     and (v_res ->> 'booking_auto_transition_revision')::bigint = 0 then
    raise notice 'PASS PA2b: رفض المالك بلا أي أثر على القيمة أو المراجعة';
  else
    raise notice 'FAIL PA2b: الرفض ترك أثرًا: %', v_res;
  end if;
  execute 'reset role';

  -- PA3: المشغل المخوّل يغيّر ON بنجاح، والرد صريح: حفظ بلا تنفيذ.
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_rev0 := (api.get_well_booking_automation(v_wa) ->> 'booking_auto_transition_revision')::bigint;
  v_cmd := gen_random_uuid();
  v_res := api.set_well_booking_automation(v_wa, true, v_rev0, v_cmd);
  if (v_res ->> 'booking_auto_transition_enabled')::boolean is true
     and (v_res ->> 'setting_saved')::boolean is true
     and (v_res ->> 'auto_transition_executed')::boolean is false
     and (v_res ->> 'booking_auto_transition_revision')::bigint = v_rev0 + 1 then
    raise notice 'PASS PA3: المشغل المخول حفظ ON بلا ادعاء تنفيذ انتقال';
  else
    raise notice 'FAIL PA3: رد تغيير المشغل غير صحيح: %', v_res;
  end if;
  v_rev1 := (v_res ->> 'booking_auto_transition_revision')::bigint;
  execute 'reset role';

  -- PA3b: المالك يراقب: يرى الإعداد ON المحفوظ والمنفّذ غير جاهز.
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  v_res := api.get_well_booking_automation(v_wa);
  if (v_res ->> 'booking_auto_transition_enabled')::boolean is true
     and (v_res ->> 'automation_executor_ready')::boolean is false
     and (v_res ->> 'auto_transition_executed')::boolean is false
     and v_res -> 'active_chain' is not distinct from 'null'::jsonb then
    raise notice 'PASS PA3b: الإعداد ON محفوظ والمنفّذ غير جاهز — تمييز صريح';
  else
    raise notice 'FAIL PA3b: قراءة المراقبة غير صحيحة: %', v_res;
  end if;
  execute 'reset role';

  -- PA4: إعادة إرسال الأمر المطابق (نفس المعرف والحمولة) تنجح وتعيد
  --   الرد المخزَّن بلا تكرار الأثر: المراجعة لا تتقدم مرتين.
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_res := api.set_well_booking_automation(v_wa, true, v_rev0, v_cmd);
  if (v_res ->> 'booking_auto_transition_enabled')::boolean is true
     and (v_res ->> 'booking_auto_transition_revision')::bigint = v_rev1
     and v_res ? 'setting_saved' then
    raise notice 'PASS PA4: إعادة الأمر المطابق أعادت الرد المخزَّن دون تكرار أثر';
  else
    raise notice 'FAIL PA4: إعادة الأمر لم تعمل كما يجب: %', v_res;
  end if;

  -- PA5: نفس معرّف الأمر بحمولة مختلفة يُرفض.
  begin
    perform api.set_well_booking_automation(v_wa, false, v_rev0, v_cmd);
    raise notice 'FAIL PA5: معرّف العملية قُبل بمحتوى مختلف';
  exception when others then
    if position('مستخدم لمحتوى مختلف' in sqlerrm) > 0 then
      raise notice 'PASS PA5: معرف الأمر بحمولة مختلفة مرفوض';
    else
      raise notice 'FAIL PA5: رفض غير متوقع: %', sqlerrm;
    end if;
  end;

  -- PA6: تعديلان داخل المعاملة نفسها ثم أمر مؤجَّل قديم يحمل مراجعة
  --   بينية — يجب رفضه (لا updated_at/now() الثابت داخل المعاملة).
  v_res := api.set_well_booking_automation(v_wa, false, v_rev1, gen_random_uuid());
  v_rev2 := (v_res ->> 'booking_auto_transition_revision')::bigint;
  if v_rev2 = v_rev1 + 1 then
    raise notice 'PASS PA6: التعديل الثاني داخل المعاملة رفع المراجعة (% → %)', v_rev1, v_rev2;
  else
    raise notice 'FAIL PA6: المراجعة لم تتقدم داخل المعاملة: %', v_res;
  end if;
  begin
    perform api.set_well_booking_automation(v_wa, true, v_rev1, gen_random_uuid());
    raise notice 'FAIL PA6b: أمر بمراجعة بينية تجاوز تعديلًا أحدث في المعاملة نفسها';
  exception when others then
    if position('نسخة إعداد قديمة' in sqlerrm) > 0 then
      raise notice 'PASS PA6b: المراجعة البينية القديمة مرفوضة داخل المعاملة نفسها';
    else
      raise notice 'FAIL PA6b: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
  begin
    perform api.set_well_booking_automation(v_wa, true, v_rev0, gen_random_uuid());
    raise notice 'FAIL PA6c: أمر بالمراجعة الابتدائية قُبل بعد تعديلين';
  exception when others then
    if position('نسخة إعداد قديمة' in sqlerrm) > 0 then
      raise notice 'PASS PA6c: المراجعة الابتدائية القديمة مرفوضة أيضًا';
    else
      raise notice 'FAIL PA6c: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
  v_res := api.get_well_booking_automation(v_wa);
  if (v_res ->> 'booking_auto_transition_enabled')::boolean is false
     and (v_res ->> 'booking_auto_transition_revision')::bigint = v_rev2 then
    raise notice 'PASS PA6d: رفض الأوامر القديمة بلا أي أثر على القيمة';
  else
    raise notice 'FAIL PA6d: حالة ما بعد الرفض غير صحيحة: %', v_res;
  end if;

  -- PA7: الصلاحيات — الغريب بتعيين مشغل غير نشط فحسب محجوب كليًا:
  --   التعيين غير النشط لا يمنح قراءة ولا تغييرًا عبر المسار الكنوني.
  perform set_config('request.jwt.claim.sub', v_outsider::text, true);
  begin
    perform api.get_well_booking_automation(v_wa);
    raise notice 'FAIL PA7: غريب قرأ إعداد البئر';
  exception when others then
    if position('صلاحية' in sqlerrm) > 0 then
      raise notice 'PASS PA7: الغريب (بتعيين غير نشط) محجوب عن القراءة';
    else
      raise notice 'FAIL PA7: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
  begin
    perform api.set_well_booking_automation(v_wa, true, null, gen_random_uuid());
    raise notice 'FAIL PA7b: غريب غيّر إعداد البئر';
  exception when others then
    if position('P7' in sqlerrm) > 0 then
      raise notice 'PASS PA7b: الغريب (بتعيين غير نشط) محجوب عن التغيير';
    else
      raise notice 'FAIL PA7b: رفض غير متوقع: %', sqlerrm;
    end if;
  end;

  -- PA7c/PA7d: المدير يملك session.start كنونيًا ولا يملك حيازة
  --   المشغل — محجوب عن القراءة (مالك/مشغل فحسب) وعن التغيير (P7).
  perform set_config('request.jwt.claim.sub', v_mgr::text, true);
  begin
    perform api.get_well_booking_automation(v_wa);
    raise notice 'FAIL PA7c: مدير قرأ إعداد البئر';
  exception when others then
    if position('صلاحية' in sqlerrm) > 0 then
      raise notice 'PASS PA7c: المدير محجوب عن القراءة';
    else
      raise notice 'FAIL PA7c: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
  begin
    perform api.set_well_booking_automation(v_wa, true, null, gen_random_uuid());
    raise notice 'FAIL PA7d: مدير غيّر إعداد البئر';
  exception when others then
    if position('P7' in sqlerrm) > 0 then
      raise notice 'PASS PA7d: المدير محجوب عن التغيير رغم session.start';
    else
      raise notice 'FAIL PA7d: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
  execute 'reset role';

  -- PA8: الاستدعاء المباشر للعملية الداخلية يطبّق العقد كاملًا: حرس
  --   التفويض أولًا يرفض المالك (يمرّ session.start بوصفه مالكًا
  --   ويُوقِعه حرس حيازة المشغل) قبل أي تسجيل أو كتابة.
  v_cmd_owner := gen_random_uuid();
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  execute 'set local role authenticated';
  begin
    perform ops.set_well_booking_automation(v_wa, true, v_rev2, v_owner, v_cmd_owner);
    raise notice 'FAIL PA8: المالك كتب عبر العملية الداخلية مباشرة';
  exception when others then
    if position('P7' in sqlerrm) > 0 then
      raise notice 'PASS PA8: الاستدعاء المباشر يرفض المالك قبل أي تسجيل';
    else
      raise notice 'FAIL PA8: رفض غير متوقع: %', sqlerrm;
    end if;
  end;

  -- PA8b: الاستدعاء المباشر بالمشغل المخوّل ينفّذ دورة الأمر كاملة:
  --   كتابة محراسة بمراجعة تصاعدية وقبول مسجَّل في المعاملة نفسها.
  v_cmd_direct := gen_random_uuid();
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  v_res := ops.set_well_booking_automation(v_wa, false, v_rev2, v_op, v_cmd_direct);
  v_rev3 := (v_res ->> 'booking_auto_transition_revision')::bigint;
  if (v_res ->> 'booking_auto_transition_enabled')::boolean is false
     and v_rev3 = v_rev2 + 1
     and (v_res ->> 'setting_saved')::boolean is true
     and (v_res ->> 'auto_transition_executed')::boolean is false then
    raise notice 'PASS PA8b: الاستدعاء المباشر كتب بمراجعة تصاعدية صحيحة';
  else
    raise notice 'FAIL PA8b: دورة الاستدعاء المباشر غير صحيحة: %', v_res;
  end if;

  -- PA8e: إعادة الأمر نفسه مباشرةً تعيد الرد المخزَّن بلا كتابة ثانية
  --   ولو تقدّمت المراجعة.
  v_res := ops.set_well_booking_automation(v_wa, false, v_rev2, v_op, v_cmd_direct);
  if (v_res ->> 'booking_auto_transition_revision')::bigint = v_rev3
     and (api.get_well_booking_automation(v_wa) ->> 'booking_auto_transition_revision')::bigint = v_rev3 then
    raise notice 'PASS PA8e: إعادة الأمر المباشر أعادت الرد المخزَّن دون تكرار أثر';
  else
    raise notice 'FAIL PA8e: تكرار أثر في إعادة الأمر المباشر: %', v_res;
  end if;

  -- PA8f: نفس معرّف الأمر بحمولة مختلفة (مباشرةً) يُرفض بلا أي أثر.
  begin
    perform ops.set_well_booking_automation(v_wa, true, v_rev2, v_op, v_cmd_direct);
    raise notice 'FAIL PA8f: معرّف العملية قُبل بحمولة مختلفة مباشرةً';
  exception when others then
    if position('مستخدم لمحتوى مختلف' in sqlerrm) > 0 then
      raise notice 'PASS PA8f: معرف الأمر المباشر بحمولة مختلفة مرفوض';
    else
      raise notice 'FAIL PA8f: رفض غير متوقع: %', sqlerrm;
    end if;
  end;

  -- PA8g: مراجعة قديمة بالاستدعاء المباشر تُرفض، والتراجع الذري يمحو
  --   تسجيل الأمر مع فشل الكتابة فلا يبقى أمر معلّق بلا إكمال.
  v_cmd_stale := gen_random_uuid();
  begin
    perform ops.set_well_booking_automation(v_wa, true, v_rev2, v_op, v_cmd_stale);
    raise notice 'FAIL PA8g: مراجعة قديمة قُبلت بالاستدعاء المباشر';
  exception when others then
    if position('نسخة إعداد قديمة' in sqlerrm) > 0 then
      raise notice 'PASS PA8g: المراجعة القديمة مرفوضة مباشرةً';
    else
      raise notice 'FAIL PA8g: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
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

  -- PA8h: دفتر الأوامر — أمر مقبول واحد مسجَّل بردّه الكامل، ولا بقايا
  --   لأوامر مرفوضة (المالك/المراجعة القديمة) ولا أمر بلا إكمال:
  --   لا كتابة بلا تسجيل ولا تسجيل بلا إتمام.
  if (select count(*) from sync.processed_commands
      where command_id = v_cmd_direct) <> 1
     or not exists (select 1 from sync.processed_commands
      where command_id = v_cmd_direct
        and status = 'accepted'
        and command_type = 'set_well_booking_automation'
        and response_payload ->> 'booking_auto_transition_revision' = v_rev3::text)
     or exists (select 1 from sync.processed_commands
      where command_id in (v_cmd_owner, v_cmd_stale)) then
    raise notice 'FAIL PA8h: دفتر الأوامر غير متسق مع دورة الأمر الذرية';
  else
    raise notice 'PASS PA8h: أمر مقبول واحد مسجَّل بالرد ولا بقايا لأوامر مرفوضة';
  end if;

  -- PA9: استقلال بئرين — دورة ON/OFF كاملة على بئر ب لا تمسّ بئر أ.
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  v_revb := (api.get_well_booking_automation(v_wb) ->> 'booking_auto_transition_revision')::bigint;
  v_res := api.set_well_booking_automation(v_wb, true, v_revb, gen_random_uuid());
  v_res := api.set_well_booking_automation(v_wb, false, (v_res ->> 'booking_auto_transition_revision')::bigint, gen_random_uuid());
  if (v_res ->> 'booking_auto_transition_enabled')::boolean is false then
    raise notice 'PASS PA9: دورة ON ثم OFF على بئر ب اكتملت بمراجعته المستقلة';
  else
    raise notice 'FAIL PA9: دورة بئر ب غير صحيحة: %', v_res;
  end if;
  execute 'reset role';
  if (select booking_auto_transition_enabled from core.well_settings where well_id = v_wa)
     is distinct from false
     or (select booking_auto_transition_enabled from core.well_settings where well_id = v_wb)
     is distinct from false then
    raise notice 'FAIL PA9b: القيم المخزنة النهائية غير مستقلة';
  else
    raise notice 'PASS PA9b: استقلال البئرين قائم (أ و ب على false بمراجعتين مستقلتين)';
  end if;

  -- PA10: تغيير الإعداد لا يُنشئ جلسة ولا سلسلة ولا تسوية مالية.
  if exists (select 1 from ops.irrigation_sessions where well_id in (v_wa, v_wb))
     or exists (select 1 from ops.booking_transition_chains where well_id in (v_wa, v_wb))
     or exists (select 1 from billing.session_charges where well_id in (v_wa, v_wb)) then
    raise notice 'FAIL PA10: أثر جانبي جلسة/سلسلة/مالي من تغيير الإعداد';
  else
    raise notice 'PASS PA10: لا جلسة ولا سلسلة ولا تسوية مالية من تغيير الإعداد';
  end if;
  if exists (
    select 1 from sync.processed_commands pc
    where pc.entity_id in (v_wa, v_wb)
      and pc.command_type <> 'set_well_booking_automation'
  ) then
    raise notice 'FAIL PA10b: سُجّل نوع أمر آخر غير تغيير الإعداد';
  else
    raise notice 'PASS PA10b: سجل الأوامر لتغيير الإعداد فقط بلا أي أمر آخر';
  end if;

  -- PA11: مسار الصف المفقود — أمر بمراجعة 0 يُرفض صراحة، وأول تغيير
  --   مقبول بنسخة متوقعة null ينشئ الصف بالمراجعة 1، ولا تعود مراجعة
  --   قديمة (0 أو null) إلى النفاذ بعد الإنشاء.
  execute 'reset role';
  delete from core.well_settings where well_id = v_wb;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  execute 'set local role authenticated';
  begin
    perform api.set_well_booking_automation(v_wb, false, 0::bigint, gen_random_uuid());
    raise notice 'FAIL PA11: أمر بمراجعة 0 على صف مفقود خمّن الإنشاء';
  exception when others then
    if position('لا يوجد صف إعدادات' in sqlerrm) > 0 then
      raise notice 'PASS PA11: أمر بمراجعة 0 على صف مفقود مرفوض صراحة';
    else
      raise notice 'FAIL PA11: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
  v_res := api.set_well_booking_automation(v_wb, false, null, gen_random_uuid());
  if (v_res ->> 'booking_auto_transition_enabled')::boolean is false
     and (v_res ->> 'booking_auto_transition_revision')::bigint = 1 then
    raise notice 'PASS PA11b: أول تغيير مقبول على صف مفقود أنشأه بالمراجعة 1';
  else
    raise notice 'FAIL PA11b: إنشاء الصف المفقود غير صحيح: %', v_res;
  end if;
  begin
    perform api.set_well_booking_automation(v_wb, true, 0::bigint, gen_random_uuid());
    raise notice 'FAIL PA11c: مراجعة 0 القديمة عادت إلى النفاذ بعد الإنشاء';
  exception when others then
    if position('نسخة إعداد قديمة' in sqlerrm) > 0 then
      raise notice 'PASS PA11c: مراجعة 0 القديمة مرفوضة بعد الإنشاء';
    else
      raise notice 'FAIL PA11c: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
  begin
    perform api.set_well_booking_automation(v_wb, true, null, gen_random_uuid());
    raise notice 'FAIL PA11d: نسخة null قُبلت على صف موجود';
  exception when others then
    if position('نسخة إعداد قديمة' in sqlerrm) > 0 then
      raise notice 'PASS PA11d: null لا تعود إلى النفاذ بعد وجود الصف';
    else
      raise notice 'FAIL PA11d: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
  execute 'reset role';
  raise notice '--- انتهى اختبار M113-P1-A: إعداد الانتقال الآلي لكل بئر ---';
end
$test_pa$;

-- =====================================================================
-- M113-P1-B — ق-134 §1 / الثوابت 748–753 و761–764: نواة الانتقال
--   الذرية بين جلستين محجوزتين.
--   الحراسات: هوية حقيقية، إعداد ON مقفول، سلسلة active مسلّحة،
--   748 للزمن، الحجز التالي مستحق، CAS على نسخة السلسلة، دورة sync.
--   الإخراج الذري: فشل أي خطوة يتراجع عن الإغلاق والرسوم والتسجيل
--   معًا — لا إغلاق بلا بدء ولا بدء بلا تسوية مثبتة.
--   ملاحظة تنفيذ الاختبار: النواة بلا منح لأدوار التطبيق (غير متاحة
--   للعميل) فتُستدعى هنا بصف المالك مع ادعاء هوية المشغل عبر
--   request.jwt.claim.sub — حراس العقود تقرأ الادعاء نفسه.
-- =====================================================================
do $test_pb$
declare
  v_tenant uuid;
  v_person uuid;
  v_fprofile uuid;
  v_owner uuid;
  v_op uuid;
  v_w1 uuid; v_w2 uuid; v_w3 uuid; v_w4 uuid; v_w5 uuid;
  v_acc1 uuid; v_acc2 uuid; v_acc3 uuid; v_acc4 uuid; v_acc5 uuid;
  v_farm1 uuid; v_farm2 uuid; v_farm3 uuid; v_farm4 uuid; v_farm5 uuid;
  v_pump1 uuid; v_pump2 uuid; v_pump3 uuid; v_pump4 uuid; v_pump5 uuid;
  v_ba1 uuid; v_bb1 uuid;
  v_ba2 uuid; v_bb2 uuid;
  v_ba5 uuid; v_bc5 uuid;
  v_ba4 uuid; v_bb4 uuid;
  v_s1 uuid; v_s2 uuid; v_s4 uuid; v_s5 uuid;
  v_chain1 uuid; v_chain2 uuid; v_chain4 uuid; v_chain5 uuid;
  v_now timestamptz := date_trunc('minute', clock_timestamp());
  v_op_end1 timestamptz;
  v_op_end5 timestamptz;
  v_rev bigint;
  v_res jsonb;
  v_close_res jsonb;
  v_status_txt text;
  v_ended timestamptz;
  v_cur uuid;
  v_cmd1 uuid;
  v_cmd2 uuid;
  v_cnt integer;
begin
  insert into core.tenants (name) values ('جهة M113-P1-B') returning id into v_tenant;
  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع PB', 'مزارع PB') returning id into v_person;
  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person) returning id into v_fprofile;

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 'own-pb@test.local', crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_owner;
  insert into iam.profiles (id, full_name) values (v_owner, 'مالك PB') on conflict (id) do nothing;
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
     email_confirmed_at, created_at, updated_at)
  values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 'op-pb@test.local', crypt('x', gen_salt('bf')), now(), now(), now())
  returning id into v_op;
  insert into iam.profiles (id, full_name) values (v_op, 'مشغل PB') on conflict (id) do nothing;

  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر PB-1') returning id into v_w1;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر PB-2') returning id into v_w2;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر PB-3') returning id into v_w3;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر PB-4') returning id into v_w4;
  insert into core.wells (tenant_id, name) values (v_tenant, 'بئر PB-5') returning id into v_w5;
  insert into core.well_assignments (well_id, profile_id, role, status) values
    (v_w1, v_owner, 'owner', 'active'), (v_w2, v_owner, 'owner', 'active'),
    (v_w3, v_owner, 'owner', 'active'), (v_w4, v_owner, 'owner', 'active'),
    (v_w5, v_owner, 'owner', 'active'),
    (v_w1, v_op, 'operator', 'active'), (v_w2, v_op, 'operator', 'active'),
    (v_w3, v_op, 'operator', 'active'), (v_w4, v_op, 'operator', 'active'),
    (v_w5, v_op, 'operator', 'active');

  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_fprofile, v_w1, 'FWA-PB-1') returning id into v_acc1;
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_fprofile, v_w2, 'FWA-PB-2') returning id into v_acc2;
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_fprofile, v_w3, 'FWA-PB-3') returning id into v_acc3;
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_fprofile, v_w4, 'FWA-PB-4') returning id into v_acc4;
  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_fprofile, v_w5, 'FWA-PB-5') returning id into v_acc5;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_w1, 'أرض PB-1', v_acc1) returning id into v_farm1;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_w2, 'أرض PB-2', v_acc2) returning id into v_farm2;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_w3, 'أرض PB-3', v_acc3) returning id into v_farm3;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_w4, 'أرض PB-4', v_acc4) returning id into v_farm4;
  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_w5, 'أرض PB-5', v_acc5) returning id into v_farm5;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_w1, 'مضخة PB-1', 'diesel', 'active') returning id into v_pump1;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_w2, 'مضخة PB-2', 'diesel', 'active') returning id into v_pump2;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_w3, 'مضخة PB-3', 'diesel', 'active') returning id into v_pump3;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_w4, 'مضخة PB-4', 'diesel', 'active') returning id into v_pump4;
  insert into core.pumps (well_id, name, power_source, status)
  values (v_w5, 'مضخة PB-5', 'diesel', 'active') returning id into v_pump5;
  insert into billing.well_pricing (well_id, price_per_hour_minor, period_start)
  values (v_w1, 5000, date '2026-01-01'), (v_w2, 5000, date '2026-01-01'),
         (v_w3, 5000, date '2026-01-01'), (v_w4, 5000, date '2026-01-01'),
         (v_w5, 5000, date '2026-01-01');

  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (v_tenant, 'BKG-PB-A1', v_w1, v_acc1, v_farm1,
    v_now - interval '150 minutes', v_now - interval '30 minutes', 120,
    'well_diesel', 'confirmed') returning id into v_ba1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (v_tenant, 'BKG-PB-B1', v_w1, v_acc1, v_farm1,
    v_now - interval '5 minutes', v_now + interval '55 minutes', 60,
    'well_diesel', 'confirmed') returning id into v_bb1;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (v_tenant, 'BKG-PB-A2', v_w2, v_acc2, v_farm2,
    v_now - interval '130 minutes', v_now - interval '10 minutes', 120,
    'well_diesel', 'confirmed') returning id into v_ba2;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (v_tenant, 'BKG-PB-B2', v_w2, v_acc2, v_farm2,
    v_now - interval '5 minutes', v_now + interval '55 minutes', 60,
    'well_diesel', 'confirmed') returning id into v_bb2;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (v_tenant, 'BKG-PB-A4', v_w4, v_acc4, v_farm4,
    v_now - interval '150 minutes', v_now - interval '30 minutes', 120,
    'well_diesel', 'confirmed') returning id into v_ba4;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (v_tenant, 'BKG-PB-B4', v_w4, v_acc4, v_farm4,
    v_now - interval '5 minutes', v_now + interval '55 minutes', 60,
    'well_diesel', 'confirmed') returning id into v_bb4;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (v_tenant, 'BKG-PB-A5', v_w5, v_acc5, v_farm5,
    v_now - interval '80 minutes', v_now - interval '20 minutes', 60,
    'well_diesel', 'confirmed') returning id into v_ba5;
  insert into ops.irrigation_bookings (
    tenant_id, public_code, well_id, farmer_well_account_id, farm_id,
    scheduled_start, scheduled_end, expected_duration_minutes,
    expected_energy_source, status
  ) values (v_tenant, 'BKG-PB-C5', v_w5, v_acc5, v_farm5,
    v_now + interval '2 hours', v_now + interval '3 hours', 60,
    'well_diesel', 'confirmed') returning id into v_bc5;

  -- تفعيل ON بيد المشغل المخول عبر عقد P1-A (w2 تبقى OFF لاختبار
  --   الحارس) — تغيير الإعداد قرار المشغل المخول لا المالك عن بعد.
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  v_res := api.set_well_booking_automation(v_w1, true, 0::bigint, gen_random_uuid());
  v_res := api.set_well_booking_automation(v_w3, true, 0::bigint, gen_random_uuid());
  v_res := api.set_well_booking_automation(v_w4, true, 0::bigint, gen_random_uuid());
  v_res := api.set_well_booking_automation(v_w5, true, 0::bigint, gen_random_uuid());
  perform set_config('request.jwt.claim.sub', v_op::text, true);

  -- PB0: بلا هوية حقيقية لا انتقال — لا هوية مختلقة للمجدول ولا تجاوز.
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform ops.execute_booking_transition(v_w1, 0::bigint, gen_random_uuid());
    raise notice 'FAIL PB0: انتقال آلي بلا هوية مستدعٍ';
  exception when others then
    if position('تسجيل الدخول' in sqlerrm) > 0 then
      raise notice 'PASS PB0: النواة ترفض الافتقار لهوية حقيقية';
    else
      raise notice 'FAIL PB0: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
  perform set_config('request.jwt.claim.sub', v_op::text, true);

  -- w1 — النجاح الكامل وعائلة الإيديمبوتنس. بدء S1 بزمن ماضٍ فعلي:
  --   الحد التشغيلي (748) = البداية الفعلية + 120د = v_now - 10د.
  v_res := ops.start_booking_session_core(v_ba1, v_op, v_now - interval '130 minutes');
  v_s1 := (v_res ->> 'session_id')::uuid;
  v_op_end1 := (v_res ->> 'operational_end_at')::timestamptz;
  select c.id into v_chain1 from ops.booking_transition_chains c where c.well_id = v_w1;

  v_cmd1 := gen_random_uuid();
  v_res := ops.execute_booking_transition(v_w1, 0::bigint, v_cmd1);
  if (v_res ->> 'auto_transition_executed')::boolean is true
     and v_res ->> 'close_reason' = 'auto_schedule_close'
     and (v_res ->> 'field_confirmation')::boolean is false
     and (v_res ->> 'closed_session_id')::uuid = v_s1
     and (v_res ->> 'closed_at_operational_end')::timestamptz = v_op_end1
     and (v_res -> 'settlement' ->> 'session_charge_id') is not null
     and (v_res ->> 'started_booking_id')::uuid = v_bb1
     and (v_res ->> 'started_session_id') is not null then
    raise notice 'PASS PB1: الانتقال الذري اكتمل إغلاقًا وبدءًا بسببه الآلي الصريح';
  else
    raise notice 'FAIL PB1: رد الانتقال غير صحيح: %', v_res;
  end if;
  select s.status, s.ended_at into v_status_txt, v_ended
  from ops.irrigation_sessions s where s.id = v_s1;
  select count(*) into v_cnt from billing.session_charges sc where sc.session_id = v_s1;
  if v_status_txt = 'closed' and v_ended = v_op_end1 and v_cnt = 1 then
    raise notice 'PASS PB1b: الجلسة أُغلقت عند الحد الموثوق حرفيًا برسوم واحدة';
  else
    raise notice 'FAIL PB1b: إغلاق الجلسة أو رسومها غير صحيح: % / % / %', v_status_txt, v_ended, v_cnt;
  end if;
  select c.status, c.current_session_id, c.decision_revision
    into v_status_txt, v_cur, v_rev
  from ops.booking_transition_chains c where c.id = v_chain1;
  select s.id into v_s2 from ops.irrigation_sessions s where s.booking_id = v_bb1;
  if v_status_txt = 'active' and v_cur = v_s2 and v_rev = 0
     and v_s2 is not null
     and exists (select 1 from ops.irrigation_sessions where id = v_s2 and status = 'open') then
    raise notice 'PASS PB1c: السلسلة عادت active بجلسة تالية جديدة وبلا تحريك النسخة';
  else
    raise notice 'FAIL PB1c: حالة السلسلة بعد الانتقال غير صحيحة: % / % / %', v_status_txt, v_rev, v_s2;
  end if;

  -- PB2: إعادة الأمر المطابق تعيد الرد المخزَّن: لا إغلاق ثانٍ ولا
  --   رسوم مكررة ولا جلسة ثانية (تكرار الأمر).
  v_res := ops.execute_booking_transition(v_w1, 0::bigint, v_cmd1);
  select count(*) into v_cnt from billing.session_charges sc where sc.session_id = v_s1;
  if (v_res ->> 'started_session_id')::uuid = v_s2
     and (v_res ->> 'auto_transition_executed')::boolean is true
     and v_cnt = 1
     and (select count(*) from ops.irrigation_sessions where booking_id = v_bb1) = 1
     and (select status from ops.irrigation_sessions where id = v_s2) = 'open' then
    raise notice 'PASS PB2: إعادة الأمر أعادت الرد المخزَّن بلا رسوم أو جلسة مكررة';
  else
    raise notice 'FAIL PB2: تكرار أثر عند إعادة الأمر: %', v_res;
  end if;

  -- PB3: نفس معرّف الأمر بحمولة مختلفة يُرفض (اختلاف البصمة).
  begin
    perform ops.execute_booking_transition(v_w1, 1::bigint, v_cmd1);
    raise notice 'FAIL PB3: معرّف العملية قُبل ببصمة مختلفة';
  exception when others then
    if position('مستخدم لمحتوى مختلف' in sqlerrm) > 0 then
      raise notice 'PASS PB3: إعادة استخدام المعرف ببصمة مختلفة مرفوضة';
    else
      raise notice 'FAIL PB3: رفض غير متوقع: %', sqlerrm;
    end if;
  end;

  -- PB4: نسخة سلسلة قديمة تُرفض، والتراجع الذري يمحو تسجيل الأمر.
  v_cmd2 := gen_random_uuid();
  begin
    perform ops.execute_booking_transition(v_w1, 5::bigint, v_cmd2);
    raise notice 'FAIL PB4: نسخة قديمة قُبلت';
  exception when others then
    if position('نسخة سلسلة قديمة' in sqlerrm) > 0 then
      raise notice 'PASS PB4: النسخة القديمة مرفوضة بمقارنة-وتبديل';
    else
      raise notice 'FAIL PB4: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
  if not exists (select 1 from sync.processed_commands where command_id = v_cmd2) then
    raise notice 'PASS PB4b: فشل الأمر ترك دفتر الأوامر نظيفًا بلا تسجيل معلّق';
  else
    raise notice 'FAIL PB4b: بقي أمر مسجَّل بلا إكمال بعد الفشل';
  end if;

  -- PB5: منع الجلسة الثانية على الحجز المستهلك عبر العقد اليدوي أيضًا.
  begin
    perform api.start_irrigation_session_from_booking(v_bb1, v_now, gen_random_uuid(), null);
    raise notice 'FAIL PB5: بُدئت جلسة ثانية على الحجز المستهلك';
  exception when others then
    if position('مرتبط بجلسة سابقة' in sqlerrm) > 0 then
      raise notice 'PASS PB5: الحجز المستهلك محجوب عن جلسة ثانية';
    else
      raise notice 'FAIL PB5: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
  perform set_config('request.jwt.claim.sub', v_op::text, true);

  -- w2 — حراسات الإعداد والزمن والسلسلة.
  -- PB6: الإعداد OFF يحجب الانتقال قبل أي شيء — حفظ ON في P1-A شرط
  --   لا كفاية، والOFF يحجب حتى بلا جلسة مفتوحة.
  begin
    perform ops.execute_booking_transition(v_w2, 0::bigint, gen_random_uuid());
    raise notice 'FAIL PB6: انتقال آلي والإعداد OFF';
  exception when others then
    if position('booking_auto_transition_disabled' in sqlerrm) > 0 then
      raise notice 'PASS PB6: الإعداد OFF يحجب الانتقال';
    else
      raise notice 'FAIL PB6: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  v_res := api.set_well_booking_automation(v_w2, true, 0::bigint, gen_random_uuid());
  perform set_config('request.jwt.claim.sub', v_op::text, true);

  v_res := ops.start_booking_session_core(v_ba2, v_op, v_now);
  v_s2 := (v_res ->> 'session_id')::uuid;
  select c.id into v_chain2 from ops.booking_transition_chains c where c.well_id = v_w2;

  -- PB7: الجلسة لم تبلغ حدها التشغيلي الموثوق (748) — لا إغلاق آلي
  --   ولا بدء فوقها (751/758).
  begin
    perform ops.execute_booking_transition(v_w2, 0::bigint, gen_random_uuid());
    raise notice 'FAIL PB7: إغلاق آلي لجلسة لم تبلغ حدها';
  exception when others then
    if position('current_not_reached_operational_end' in sqlerrm) > 0 then
      raise notice 'PASS PB7: الجلسة دون الحد الموثوق محجوبة عن الإغلاق';
    else
      raise notice 'FAIL PB7: رفض غير متوقع: %', sqlerrm;
    end if;
  end;

  -- PB8: غياب البداية اليدوية (لا سلسلة مسلّحة) يحجب الانتقال (761).
  delete from ops.booking_transition_chains where id = v_chain2;
  begin
    perform ops.execute_booking_transition(v_w2, 0::bigint, gen_random_uuid());
    raise notice 'FAIL PB8: انتقال بلا سلسلة مسلّحة';
  exception when others then
    if position('chain_not_armed' in sqlerrm) > 0 then
      raise notice 'PASS PB8: غياب السلسلة المسلّحة يحجب الانتقال';
    else
      raise notice 'FAIL PB8: رفض غير متوقع: %', sqlerrm;
    end if;
  end;

  -- w3 — الجلسة الحرة/العابرة (751): بلا أي حجز على البئر فبدء حرّ
  --   بلا مدة ممكن، والحارس يحجب الإغلاق الآلي قبل فحص السلسلة.
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  -- الدالة تعيد uuid فتُستبق النتيجة: لا حاجة لمعرفها لاحقًا.
  perform api.start_adhoc_session(
    v_w3, v_pump3, v_farm3, v_acc3, 'well_diesel', null, v_now, null, null, null
  );
  begin
    perform ops.execute_booking_transition(v_w3, 0::bigint, gen_random_uuid());
    raise notice 'FAIL PB9: إغلاق آلي لجلسة حرة/عابرة';
  exception when others then
    if position('transient_or_free_session_blocked' in sqlerrm) > 0 then
      raise notice 'PASS PB9: الجلسة الحرة/العابرة محجوبة عن الإغلاق الآلي';
    else
      raise notice 'FAIL PB9: رفض غير متوقع: %', sqlerrm;
    end if;
  end;

  -- w5 — انتظار غير محسوم (763): قرار wait محفوظ يعلّق الانتقال الآلي
  --   حتى يُحسم بقراره القائم.
  v_res := ops.start_booking_session_core(v_ba5, v_op, v_now - interval '70 minutes');
  v_s5 := (v_res ->> 'session_id')::uuid;
  v_op_end5 := (v_res ->> 'operational_end_at')::timestamptz;
  select c.id into v_chain5 from ops.booking_transition_chains c where c.well_id = v_w5;
  v_close_res := api.complete_booking_session(v_s5, v_op_end5, gen_random_uuid());
  v_res := api.record_booking_transition_decision(
    v_chain5, v_s5, v_bc5, 'wait', 0::bigint, gen_random_uuid()
  );
  begin
    perform ops.execute_booking_transition(v_w5, 1::bigint, gen_random_uuid());
    raise notice 'FAIL PB10: انتقال آلي وقرار انتظار غير محسوم';
  exception when others then
    if position('no_open_session_to_close' in sqlerrm) > 0 then
      raise notice 'PASS PB10: الانتظار غير المحسوم يعلّق الانتقال الآلي';
    else
      raise notice 'FAIL PB10: رفض غير متوقع: %', sqlerrm;
    end if;
  end;

  -- w4 — عدم الجاهزية: المضخة الفعالة مفقودة فلا بدء، والتراجع الذري
  --   يمحو الإغلاق والرسوم والتسجيل معًا فلا حالة جزئية إطلاقًا.
  perform set_config('request.jwt.claim.sub', v_op::text, true);
  v_res := ops.start_booking_session_core(v_ba4, v_op, v_now - interval '130 minutes');
  v_s4 := (v_res ->> 'session_id')::uuid;
  select c.id into v_chain4 from ops.booking_transition_chains c where c.well_id = v_w4;
  update core.pumps set status = 'inactive' where well_id = v_w4;
  v_cmd2 := gen_random_uuid();
  begin
    perform ops.execute_booking_transition(v_w4, 0::bigint, v_cmd2);
    raise notice 'FAIL PB11: انتقال نجح بلا مضخة فعالة للتالي';
  exception when others then
    if position('غير جاهز للتنفيذ' in sqlerrm) > 0 then
      raise notice 'PASS PB11: عدم الجاهزية يمنع بدء التالي';
    else
      raise notice 'FAIL PB11: رفض غير متوقع: %', sqlerrm;
    end if;
  end;
  if exists (select 1 from ops.irrigation_sessions where id = v_s4 and status = 'open')
     and not exists (select 1 from billing.session_charges where session_id = v_s4)
     and not exists (select 1 from ops.irrigation_sessions where booking_id = v_bb4)
     and not exists (select 1 from sync.processed_commands where command_id = v_cmd2) then
    raise notice 'PASS PB11b: التراجع الذري أعاد الحالة: الجلسة مفتوحة بلا رسوم ولا بدء ولا أمر';
  else
    raise notice 'FAIL PB11b: بقي أثر جزئي بعد فشل الانتقال';
  end if;
  update core.pumps set status = 'active' where well_id = v_w4;
  raise notice '--- انتهى اختبار M113-P1-B: نواة الانتقال الذرية ---';
end
$test_pb$;

rollback;

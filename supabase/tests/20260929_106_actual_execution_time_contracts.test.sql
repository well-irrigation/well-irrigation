-- ق-131 البند 7 / م-45 المرحلة A: الزمن الفعلي في عقود القراءة والتقارير.
-- هذا اختبار DB فقط؛ كل التغييرات تتراجع في النهاية.
--
-- ما يثبه هذا الملف:
--   1. الجلسة المقفلة ذات التوقف: فعليّها = مجموع مقاطعها كلها (تشغيل +
--      توقف غير محسوب)، ومفوترّها أقل منه — والكمتان منفصلتان في
--      list_well_sessions وفي get_session_detail.
--   2. المبلغ المالي يبقى محسوبًا من المفوتر وحده (3000 لا 3600).
--   3. التقارير: المجموع والسلسلة اليومية بالفعلي، وتوزيع الطاقة من
--      actual_seconds لحاملات المصدر بدقة الثواني (بلا تقريب دقائق
--      مسار actual_minutes*60 القديم).
--   4. الجلسة القديمة بلا مقاطع تعود بمغلفها المخزَّن ended_at - started_at.
--   5. الجارية بلا مدة فعلية نهائية (null) وخارج مجاميع التقارير (ق-37).
--   6. إصدار عقد التقارير صار 3، وعقدا القراءة بقيا 1 بإضافة جمعية.
--   7. الكتابة المباشرة على جدول الجلسات محجوبة عن المصادَق (ق-79):
--      الجلستان التجهيزيتان (القديمة بلا مقاطع والجارية) بُنيتا بسلطة
--      الإعداد وحدها بنمط تنقّل الأدوار في اختبار 095.

\set ON_ERROR_STOP on

begin;

set local timezone to 'UTC';

do $test$
declare
  v_user uuid;
  v_tenant uuid;
  v_well uuid;
  v_person uuid;
  v_farmer_profile uuid;
  v_farmer_account uuid;
  v_farm uuid;
  v_pump_a uuid;
  v_pump_c uuid;
  v_pump_b uuid;
  v_pump_d uuid;
  v_schedule uuid;
  v_session_a uuid;
  v_session_c uuid;
  v_session_b uuid;
  v_session_d uuid;
  v_list jsonb;
  v_item jsonb;
  v_detail jsonb;
  v_seg jsonb;
  v_report jsonb;
  v_count bigint;
  v_denied boolean;
begin
  -- -------------------------------------------------------------
  -- 1. التجهيز: بئر بتسعير شمسي 3600/ساعة (نمط 105).
  -- -------------------------------------------------------------
  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-actual-time-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_user;

  insert into core.tenants (name)
  values ('جهة اختبار الزمن الفعلي 106')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر اختبار الزمن الفعلي 106')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_user, 'owner', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع الزمن الفعلي', 'مزارع الزمن الفعلي')
  returning id into v_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_farmer_profile;

  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_farmer_profile, v_well, 'FWA-106')
  returning id into v_farmer_account;

  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well, 'مزرعة الزمن الفعلي', v_farmer_account)
  returning id into v_farm;

  -- أربع مضخات: زناد منع التوازي يحكم المضخة الواحدة.
  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة الزمن الفعلي أ', 'solar')
  returning id into v_pump_a;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة الزمن الفعلي ج', 'solar')
  returning id into v_pump_c;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة الزمن الفعلي ب', 'solar')
  returning id into v_pump_b;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة الزمن الفعلي د', 'solar')
  returning id into v_pump_d;

  insert into billing.well_pricing
    (well_id, price_per_hour_minor, period_start)
  values (v_well, 5000, date '2026-09-01');

  insert into ops.price_schedules
    (tenant_id, well_id, name, effective_period, status, approved_by)
  values (
    v_tenant, v_well, 'تسعير اختبار الزمن الفعلي',
    tstzrange(
      timestamptz '2026-09-01 00:00:00+03',
      timestamptz '2026-10-01 00:00:00+03',
      '[)'
    ),
    'active', v_user
  )
  returning id into v_schedule;

  insert into ops.price_rules
    (tenant_id, price_schedule_id, energy_source, hourly_rate_minor)
  values (v_tenant, v_schedule, 'solar', 3600);

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- -------------------------------------------------------------
  -- 2. الجلسة أ (50 دقيقة تشغيل + 10 دقائق توقف غير محسوبة):
  --    بدء 08:00، إيقاف 08:50، إنهاء من التوقف 09:00.
  -- -------------------------------------------------------------
  v_session_a := api.start_irrigation_session(
    v_well, v_pump_a, v_farm, v_farmer_account, 'solar',
    timestamptz '2026-09-10 08:00:00+03'
  );

  perform api.pause_irrigation_session(
    v_session_a, 'operator_pause', timestamptz '2026-09-10 08:50:00+03'
  );

  perform api.complete_irrigation_session(
    v_session_a, timestamptz '2026-09-10 09:00:00+03'
  );

  -- الجلسة ج (دقة الثواني في الطاقة): تشغيل 1000 ثانية = 16 دقيقة و40
  -- ثانية. مسار actual_minutes*60 القديم كان سيعطي 960.
  v_session_c := api.start_irrigation_session(
    v_well, v_pump_c, v_farm, v_farmer_account, 'solar',
    timestamptz '2026-09-10 10:00:00+03'
  );

  perform api.complete_irrigation_session(
    v_session_c, timestamptz '2026-09-10 10:16:40+03'
  );

  -- الجلستان ب (قديمة بلا مقاطع: 11:00 → 12:00 = 3600 ثانية، بلا تكلفة
  -- ولا فاتورة) ود (جارية بلا نهاية) تاريخٌ تاريخي يُبنى تجهيزًا بسلطة
  -- الإعداد وحدها: الكتابة المباشرة على جدول الجلسات محجوبة عن
  -- المصادَق قصدًا (ق-79)، فنخرج من دوره للإدخال ثم نرجع إليه قبل
  -- نداءات العقود (نمط 095 في تنقّل الأدوار).
  execute 'reset role';

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, ended_at, status
  ) values (
    v_well, v_pump_b, v_farm, v_farmer_account, v_user,
    timestamptz '2026-09-10 11:00:00+03',
    timestamptz '2026-09-10 12:00:00+03', 'closed'
  ) returning id into v_session_b;

  -- الجلسة د (جارية): بلا نهاية وبلا مدة فعلية نهائية.
  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, farmer_well_account_id,
    operator_profile_id, started_at, status
  ) values (
    v_well, v_pump_d, v_farm, v_farmer_account, v_user,
    timestamptz '2026-09-10 12:30:00+03', 'open'
  ) returning id into v_session_d;

  -- العودة إلى سياق المصادَق نفسه قبل كل نداءات العقود.
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- -------------------------------------------------------------
  -- 3. سجل الجلسات: الفعلي والمفوتر كميتان منفصلتان لكل جلسة.
  -- -------------------------------------------------------------
  v_list := api.list_well_sessions(v_well);

  select it into v_item
  from jsonb_array_elements(v_list -> 'items') it
  where it ->> 'id' = v_session_a::text;

  if (v_item ->> 'actual_seconds')::bigint = 3600
     and (v_item ->> 'billable_seconds')::bigint = 3000
  then
    raise notice 'PASS 1: الجلسة بالتوقف: فعلي=3600 ومفوتر=3000 منفصلان في السجل';
  else
    raise notice 'FAIL 1: سجل الجلسة أ: فعلي=% مفوتر=%',
      v_item -> 'actual_seconds', v_item -> 'billable_seconds';
  end if;

  select it into v_item
  from jsonb_array_elements(v_list -> 'items') it
  where it ->> 'id' = v_session_b::text;

  if (v_item ->> 'actual_seconds')::bigint = 3600
     and (v_item -> 'billable_seconds') = 'null'::jsonb
  then
    raise notice 'PASS 2: الجلسة القديمة بلا مقاطع عادت بمغلفها المخزَّن 3600';
  else
    raise notice 'FAIL 2: سجل الجلسة ب: فعلي=% مفوتر=%',
      v_item -> 'actual_seconds', v_item -> 'billable_seconds';
  end if;

  select it into v_item
  from jsonb_array_elements(v_list -> 'items') it
  where it ->> 'id' = v_session_d::text;

  if (v_item -> 'actual_seconds') = 'null'::jsonb then
    raise notice 'PASS 3: الجارية بلا مدة فعلية نهائية — null لا تلفيق';
  else
    raise notice 'FAIL 3: الجارية أعادت فعليًا: %', v_item -> 'actual_seconds';
  end if;

  -- -------------------------------------------------------------
  -- 4. تفصيل الجلسة أ: الكميتان على مستوى الجلسة، والتوقف بمقاطعه
  --    فعلي 600 ومفوتر 0.
  -- -------------------------------------------------------------
  v_detail := api.get_session_detail(v_session_a);

  if (v_detail -> 'session' ->> 'actual_seconds')::bigint = 3600
     and (v_detail -> 'session' ->> 'billable_seconds')::bigint = 3000
  then
    raise notice 'PASS 4: تفصيل الجلسة أ يعيد الفعلي والمفوتر منفصلين';
  else
    raise notice 'FAIL 4: تفصيل الجلسة أ: فعلي=% مفوتر=%',
      v_detail -> 'session' -> 'actual_seconds',
      v_detail -> 'session' -> 'billable_seconds';
  end if;

  select seg into v_seg
  from jsonb_array_elements(v_detail -> 'segments') seg
  where seg ->> 'segment_type' = 'operator_pause';

  if (v_seg ->> 'actual_seconds')::bigint = 600
     and (v_seg ->> 'billable_seconds')::bigint = 0
  then
    raise notice 'PASS 5: مقطع التوقف فعله 600 ومفوتره 0 — دخل الفعلي ولم يدخل المفوتر';
  else
    raise notice 'FAIL 5: مقطع التوقف: فعلي=% مفوتر=%',
      v_seg -> 'actual_seconds', v_seg -> 'billable_seconds';
  end if;

  -- -------------------------------------------------------------
  -- 5. تفصيل الجلسة ب: مغلف مخزَّن مع مقاطع فارغة.
  -- -------------------------------------------------------------
  v_detail := api.get_session_detail(v_session_b);

  if (v_detail -> 'session' ->> 'actual_seconds')::bigint = 3600
     and jsonb_array_length(v_detail -> 'segments') = 0
  then
    raise notice 'PASS 6: تفصيل القديمة بلا مقاطع بمغلفها 3600 وقائمة مقاطع صادقة';
  else
    raise notice 'FAIL 6: تفصيل الجلسة ب: فعلي=% مقاطع=%',
      v_detail -> 'session' -> 'actual_seconds', v_detail -> 'segments';
  end if;

  -- -------------------------------------------------------------
  -- 6. المال كما هو: التكلفة المخزَّنة بالمفوتر وحدها 3000 ومبلغها
  --    (3000 ث × 3600/س ÷ 3600) = 3000، لا 3600.
  -- -------------------------------------------------------------
  select count(*) into v_count
  from billing.session_charges
  where session_id = v_session_a
    and duration_seconds = 3000
    and amount_minor = 3000;

  if v_count = 1 then
    raise notice 'PASS 7: التكلفة المخزَّنة بالمفوتر 3000 ومبلغها 3000 — المال لم يُلمس';
  else
    raise notice 'FAIL 7: تكلفة الجلسة أ غير مطابقة: %', v_count;
  end if;

  -- -------------------------------------------------------------
  -- 7. التقارير: الفعلي في المجموع واليوم، والطاقة بدقة الثواني،
  --    والإيراد من الفوترة.
  -- -------------------------------------------------------------
  v_report := api.get_reports_summary(
    v_well, 'custom',
    timestamptz '2026-09-10 00:00:00+03',
    timestamptz '2026-09-10 23:00:00+03'
  );

  if v_report ->> 'contract' = 'get_reports_summary'
     and (v_report ->> 'version')::int = 3
     and v_report ->> 'duration_basis' = 'actual_execution'
  then
    raise notice 'PASS 8: مغلَّف التقارير يعلن النسخة 3 وأساس المدة الفعلي';
  else
    raise notice 'FAIL 8: مغلَّف التقارير: %',
      v_report - 'totals' - 'daily_irrigation' - 'energy_distribution'
        - 'financial_trends';
  end if;

  if (v_report -> 'totals' ->> 'total_sessions')::bigint = 3
     and (v_report -> 'totals' ->> 'total_duration_seconds')::bigint = 8200
  then
    raise notice 'PASS 9: مجموع المدة الفعلية 8200 (3600+1000+3600) والجارية خارجه';
  else
    raise notice 'FAIL 9: مجاميع التقارير: جلسات=% مدة=%',
      v_report -> 'totals' -> 'total_sessions',
      v_report -> 'totals' -> 'total_duration_seconds';
  end if;

  select coalesce(sum((d ->> 'duration_seconds')::bigint), 0)
    into v_count
  from jsonb_array_elements(v_report -> 'daily_irrigation') d
  where d ->> 'day' = '2026-09-10';

  if v_count = 8200
     and (v_report -> 'daily_irrigation' -> 0 ->> 'sessions_count')::int = 3
  then
    raise notice 'PASS 10: السلسلة اليومية بالفعلي 8200 على يوم النهاية (ق-27)';
  else
    raise notice 'FAIL 10: السلسلة اليومية: %', v_report -> 'daily_irrigation';
  end if;

  select en into v_item
  from jsonb_array_elements(v_report -> 'energy_distribution') en
  where en ->> 'energy_source' = 'solar';

  if (v_item ->> 'total_seconds')::bigint = 4000 then
    raise notice 'PASS 11: طاقة الشمس 4000 من actual_seconds بدقة الثواني (لا 3960 بالدقائق)';
  else
    raise notice 'FAIL 11: طاقة الشمس: %', v_item;
  end if;

  if (v_report -> 'totals' ->> 'total_revenue_minor')::bigint = 4000 then
    raise notice 'PASS 12: الإيراد 4000 من الفوترة المخزَّنة كما هو';
  else
    raise notice 'FAIL 12: الإيراد: %',
      v_report -> 'totals' -> 'total_revenue_minor';
  end if;

  -- -------------------------------------------------------------
  -- 8. سطح العقد: مفتاح الفعلي في عقود القراءة وإصداراتها.
  -- -------------------------------------------------------------
  if position('actual_seconds' in pg_get_functiondef(
        to_regprocedure('api.list_well_sessions(uuid, uuid, timestamptz, timestamptz, boolean, integer)')
      )) > 0
     and position('actual_seconds' in pg_get_functiondef(
        to_regprocedure('api.get_session_detail(uuid)')
      )) > 0
  then
    raise notice 'PASS 13: عقود القراءة تحمل مفتاح الفعلي في تعريفاتها';
  else
    raise notice 'FAIL 13: مفتاح الفعلي غائب عن تعريف أحد العقدين';
  end if;

  -- -------------------------------------------------------------
  -- 9. الكتابة المباشرة على جدول الجلسات محجوبة عن المصادَق (ق-79):
  --    إنما بُنيت الجلستان ب/د أعلاه بسلطة الإعداد وحدها، والمصادَق
  --    يقرأ العقود ولا يكتب الجداول.
  -- -------------------------------------------------------------
  v_denied := false;
  begin
    insert into ops.irrigation_sessions (
      well_id, pump_id, farm_id, operator_profile_id, started_at, status
    ) values (
      v_well, v_pump_b, v_farm, v_user,
      timestamptz '2026-09-10 13:00:00+03', 'open'
    );
  exception when insufficient_privilege then
    v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 14: الإدخال المباشر في irrigation_sessions محجوب عن المصادَق';
  else
    raise notice 'FAIL 14: المصادَق كتب مباشرة في جدول الجلسات — كسر Direct DML';
  end if;
end;
$test$;

rollback;

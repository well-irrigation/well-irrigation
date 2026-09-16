begin;

set local timezone to 'UTC';

-- =====================================================================
-- اختبار هجرة 100: تغيير مصدر الطاقة أثناء التوقف المؤقت (Q-129 / ق-100)
--
-- يثبت هذا الاختبار:
-- A-H. المسار الكامل: بدء شمس ← جريان ← إيقاف مؤقت ← تغيير لديزل أثناء التوقف
--      ← بقاء التوقف غير مفوتر ← استئناف بديزل مع التقاط تسعيرته عند الاستئناف
--      ← إكمال الجلسة وتحقيق حساب FIN-001 (3313 + 180 = 3493 وليس 6808).
-- I.   تغييرات متعددة أثناء نفس التوقف (شمس ← ديزل بئر ← ديزل مزارع ← استئناف).
-- J.   حماية التكرار (Idempotency) عبر api ومعرّف العملية p_command_id.
-- K.   رفض التحويل لنفس المصدر الفعّال أثناء التوقف بلا إنشاء مقطع مكرر.
-- L.   الإخفاق الحازم (fail-closed) عند تمرير وسائط إغلاق الوقود أثناء التوقف المؤقت.
-- =====================================================================

do $test$
declare
  v_user uuid;
  v_tenant uuid;
  v_well uuid;
  v_person uuid;
  v_farmer_profile uuid;
  v_farmer_account uuid;
  v_farm uuid;
  v_pump uuid;
  v_schedule uuid;
  v_session uuid;
  v_cmd_change uuid;
  v_cmd_resume uuid;
  v_res_id uuid;
  v_res_id_2 uuid;
  v_open_seg record;
  v_solar_seg record;
  v_pause_seg record;
  v_resume_seg record;
  v_complete_res jsonb;
  v_charge record;
  v_seg_count int;
  v_seg_count_after int;
  v_caught boolean;
  v_pause_seg_id uuid;
  v_session_status text;
  v_billable_sec bigint;
  v_total_amount bigint;

  -- أوقات محددة وحتمية لاختبار FIN-001
  c_t0 timestamptz := timestamptz '2026-09-16 08:00:00+00';
  c_t1 timestamptz := timestamptz '2026-09-16 08:39:46+00'; -- بعد 2386 ثانية
  c_t2 timestamptz := timestamptz '2026-09-16 08:45:00+00'; -- تغيير المصدر أثناء التوقف
  c_t3 timestamptz := timestamptz '2026-09-16 08:50:00+00'; -- الاستئناف بعد 10 دقائق توقف
  c_t4 timestamptz := timestamptz '2026-09-16 08:51:05+00'; -- بعد 65 ثانية تشغيل ديزل
begin

  -- ============================================================
  -- 1. التهيئة: مستخدم وجهة وبئر ومزارع ومضخة وقواعد تسعير
  -- ============================================================

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q129-m100-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_user;

  insert into core.tenants (name)
  values ('جهة اختبار هجرة 100')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر اختبار هجرة 100')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_user, 'owner', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع اختبار هجرة 100', 'مزارع اختبار هجرة 100')
  returning id into v_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_farmer_profile;

  insert into ops.farmer_well_accounts (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_farmer_profile, v_well, 'FWA-100')
  returning id into v_farmer_account;

  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well, 'مزرعة اختبار 100', v_farmer_account)
  returning id into v_farm;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة اختبار 100', 'solar')
  returning id into v_pump;

  -- جدول تسعير معتمد: شمسي 5000 وديزل بئر 10000 وديزل مزارع 4000
  insert into ops.price_schedules (
    tenant_id, well_id, name, effective_period, status, approved_by
  )
  values (
    v_tenant, v_well, 'تسعيرة اختبار 100',
    tstzrange(timestamptz '2026-09-01 00:00:00+00', null, '[)'),
    'active', v_user
  )
  returning id into v_schedule;

  insert into ops.price_rules (tenant_id, price_schedule_id, energy_source, hourly_rate_minor)
  values (v_tenant, v_schedule, 'solar', 5000);

  insert into ops.price_rules (
    tenant_id, price_schedule_id, energy_source, diesel_pricing_model, hourly_rate_minor
  )
  values (
    v_tenant, v_schedule, 'well_diesel', 'inclusive_hourly', 10000
  );

  insert into ops.price_rules (
    tenant_id, price_schedule_id, energy_source, diesel_pricing_model, hourly_rate_minor
  )
  values (
    v_tenant, v_schedule, 'farmer_diesel', 'inclusive_hourly', 4000
  );

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';


  -- ============================================================
  -- A-D. بدء جلسة شمسية ثم إيقافها مؤقتاً بعد 2386 ثانية
  -- ============================================================

  v_session := ops.start_irrigation_session(
    p_well_id => v_well,
    p_pump_id => v_pump,
    p_farm_id => v_farm,
    p_farmer_well_account_id => v_farmer_account,
    p_operator_profile_id => v_user,
    p_energy_source => 'solar',
    p_started_at => c_t0
  );

  -- التحقق من المقطع الشمسي الأول
  select * into v_solar_seg
  from ops.session_segments
  where session_id = v_session and sequence_number = 1;

  if v_solar_seg.segment_type <> 'solar_run' or v_solar_seg.applied_hourly_rate_minor <> 5000 then
    raise exception 'فشل بدء المقطع الشمسي: type=% rate=%', v_solar_seg.segment_type, v_solar_seg.applied_hourly_rate_minor;
  end if;

  -- إيقاف مؤقت عند c_t1 (بعد 2386 ثانية)
  perform ops.pause_irrigation_session(
    p_session_id => v_session,
    p_reason => 'operator_pause',
    p_paused_at => c_t1
  );

  select * into v_pause_seg
  from ops.session_segments
  where session_id = v_session and sequence_number = 2;

  if v_pause_seg.segment_type <> 'operator_pause' or v_pause_seg.is_billable <> false then
    raise exception 'فشل مقطع الإيقاف المؤقت الأول';
  end if;


  -- ============================================================
  -- E. تغيير مصدر الطاقة إلى well_diesel أثناء التوقف المؤقت
  -- ============================================================

  v_res_id := ops.change_session_energy_source(
    p_session_id => v_session,
    p_new_source => 'well_diesel',
    p_changed_at => c_t2
  );

  -- التحقق فوراً بعد التغيير:
  -- 1. المقطع المفتوح هو مقطع توقف غير مفوتر يحمل المصدر المعلّق
  select * into v_open_seg
  from ops.session_segments
  where session_id = v_session and ended_at is null;

  if v_open_seg.id <> v_res_id then
    raise exception 'معرّف المقطع المفتوح غير مطابق للنتيجة المعاد';
  end if;
  if v_open_seg.segment_type <> 'source_change_pause' then
    raise exception 'نوع المقطع المفتوح بعد التغيير أثناء التوقف ليس source_change_pause: %', v_open_seg.segment_type;
  end if;
  if v_open_seg.is_billable <> false then
    raise exception 'مقطع تغيير المصدر أثناء التوقف يجب أن يكون غير مفوتر (is_billable=false)';
  end if;
  if v_open_seg.energy_source <> 'well_diesel' then
    raise exception 'المصدر المعلّق في مقطع التوقف يجب أن يكون well_diesel: %', v_open_seg.energy_source;
  end if;
  if v_open_seg.applied_hourly_rate_minor is not null then
    raise exception 'مقطع التوقف يجب ألا يحمل أي سعر مثبت قبل الاستئناف';
  end if;

  -- 2. مقطع التوقف السابق أُغلق عند c_t2
  select ended_at into v_pause_seg.ended_at
  from ops.session_segments
  where session_id = v_session and sequence_number = 2;

  if v_pause_seg.ended_at <> c_t2 then
    raise exception 'مقطع التوقف السابق لم يغلق عند وقت التغيير: %', v_pause_seg.ended_at;
  end if;

  -- 3. المقطع الشمسي التاريخي لم يمس
  select * into v_solar_seg
  from ops.session_segments
  where session_id = v_session and sequence_number = 1;

  if v_solar_seg.ended_at <> c_t1 or v_solar_seg.applied_hourly_rate_minor <> 5000 then
    raise exception 'تغيير المصدر أثناء التوقف أثّر على المقطع التاريخي السابق';
  end if;

  raise notice 'PASS A-E: التغيير أثناء التوقف ينشئ مقطع توقف غير مفوتر بالمصدر المعلّق ويغلق التوقف السابق';


  -- ============================================================
  -- F-G. استئناف الجلسة عند c_t3
  -- ============================================================

  v_res_id := ops.resume_irrigation_session(
    p_session_id => v_session,
    p_resumed_at => c_t3
  );

  -- التحقق بعد الاستئناف:
  -- 1. مقطع التوقف المعلّق أُغلق عند c_t3
  select * into v_open_seg
  from ops.session_segments
  where session_id = v_session and sequence_number = 3;

  if v_open_seg.ended_at <> c_t3 then
    raise exception 'مقطع التوقف المعلّق لم يغلق عند وقت الاستئناف';
  end if;

  -- 2. المقطع الجديد مفتوح وهو مقطع تشغيل ديزل مفوتر وبدأ عند c_t3
  select * into v_resume_seg
  from ops.session_segments
  where session_id = v_session and ended_at is null;

  if v_resume_seg.id <> v_res_id then
    raise exception 'معرّف المقطع المستأنف غير مطابق للنتيجة المعاد';
  end if;
  if v_resume_seg.segment_type <> 'well_diesel_run' then
    raise exception 'نوع المقطع المستأنف ليس well_diesel_run: %', v_resume_seg.segment_type;
  end if;
  if v_resume_seg.is_billable <> true then
    raise exception 'المقطع المستأنف يجب أن يكون مفوتراً (is_billable=true)';
  end if;
  if v_resume_seg.started_at <> c_t3 then
    raise exception 'بداية مقطع التشغيل الجديد ليست وقت الاستئناف: %', v_resume_seg.started_at;
  end if;
  if v_resume_seg.applied_hourly_rate_minor <> 10000 then
    raise exception 'لم يتم التقاط تسعيرة ديزل البئر (10000) عند الاستئناف: %', v_resume_seg.applied_hourly_rate_minor;
  end if;

  raise notice 'PASS F-G: الاستئناف يفتح مقطع تشغيل بالمصدر المعلّق وبسعر لحظة الاستئناف مباشرة';


  -- ============================================================
  -- H. إنهاء الجلسة عند c_t4 (بعد 65 ثانية) وإثبات FIN-001
  -- ============================================================

  v_complete_res := ops.complete_irrigation_session(
    p_session_id => v_session,
    p_ended_at => c_t4
  );

  -- التحقق من حساب FIN-001 الحتمي:
  -- مقطع 1: شمسي 2386 ثانية @ 5000 = (2386 * 5000) / 3600 = 3313
  -- مقطع 2: توقف مشغل (غير مفوتر = 0 ثانية مفوترة، 0 ريال)
  -- مقطع 3: توقف تغيير مصدر (غير مفوتر = 0 ثانية مفوترة، 0 ريال)
  -- مقطع 4: ديزل بئر 65 ثانية @ 10000 = (65 * 10000) / 3600 = 180
  -- إجمالي الثواني المفوترة = 2386 + 65 = 2451 ثانية
  -- إجمالي المبلغ = 3313 + 180 = 3493 ريال (وليس 6808 ريال إطلاقاً)
  select * into v_charge
  from billing.session_charges
  where session_id = v_session;

  if v_charge.duration_seconds <> 2451 then
    raise exception 'إجمالي الثواني المفوترة غير مطابق: % (المتوقع 2451)', v_charge.duration_seconds;
  end if;
  if v_charge.amount_minor <> 3493 then
    raise exception 'قاعدة FIN-001 خُرقت! المبلغ المحسوب: % (المتوقع الصارم: 3493)', v_charge.amount_minor;
  end if;

  raise notice 'PASS H: حساب FIN-001 صحيح تماماً: 3313 + 180 = 3493 ريال';


  -- ============================================================
  -- I. تغييرات متعددة أثناء نفس التوقف (A → B → C)
  -- ============================================================

  v_session := ops.start_irrigation_session(
    p_well_id => v_well,
    p_pump_id => v_pump,
    p_farm_id => v_farm,
    p_farmer_well_account_id => v_farmer_account,
    p_operator_profile_id => v_user,
    p_energy_source => 'solar',
    p_started_at => timestamptz '2026-09-16 10:00:00+00'
  );

  -- توقف
  perform ops.pause_irrigation_session(
    v_session, 'operator_pause', timestamptz '2026-09-16 10:10:00+00'
  );

  -- تغيير 1 أثناء التوقف: إلى well_diesel
  perform ops.change_session_energy_source(
    v_session, 'well_diesel', timestamptz '2026-09-16 10:12:00+00'
  );

  -- تغيير 2 أثناء التوقف: إلى farmer_diesel
  perform ops.change_session_energy_source(
    v_session, 'farmer_diesel', timestamptz '2026-09-16 10:15:00+00'
  );

  -- استئناف
  v_res_id := ops.resume_irrigation_session(
    v_session, timestamptz '2026-09-16 10:20:00+00'
  );

  select * into v_open_seg
  from ops.session_segments
  where id = v_res_id;

  if v_open_seg.segment_type <> 'farmer_diesel_run' or v_open_seg.applied_hourly_rate_minor <> 4000 then
    raise exception 'الاستئناف بعد تغييرات متعددة لم يستخدم آخر مصدر معلّق (farmer_diesel): type=% rate=%',
      v_open_seg.segment_type, v_open_seg.applied_hourly_rate_minor;
  end if;

  raise notice 'PASS I: التغييرات المتعددة أثناء التوقف تطبق آخر مصدر معلّق فقط عند الاستئناف';


  -- ============================================================
  -- J. حماية التكرار (Idempotency) عبر api ومعرّف p_command_id
  -- ============================================================

  v_cmd_change := gen_random_uuid();

  -- توقف الجلسة الثانية
  perform api.pause_irrigation_session(
    p_session_id => v_session,
    p_reason => 'operator_pause',
    p_paused_at => timestamptz '2026-09-16 10:25:00+00'
  );

  select count(*) into v_seg_count
  from ops.session_segments
  where session_id = v_session;

  -- إرسال أمر التغيير للمرة الأولى
  v_res_id := api.change_session_energy_source(
    p_session_id => v_session,
    p_new_source => 'solar',
    p_changed_at => timestamptz '2026-09-16 10:26:00+00',
    p_command_id => v_cmd_change
  );

  -- إرسال نفس الأمر بنفس معرّف العملية (إعادة محاولة شبكية)
  v_res_id_2 := api.change_session_energy_source(
    p_session_id => v_session,
    p_new_source => 'solar',
    p_changed_at => timestamptz '2026-09-16 10:26:00+00',
    p_command_id => v_cmd_change
  );

  if v_res_id <> v_res_id_2 then
    raise exception 'إعادة أمر التغيير بمعرّف العملية لم تُعد نفس النتيجة';
  end if;

  -- التحقق من عدم إنشاء مقطع إضافي مكرر
  select count(*) into v_seg_count_after
  from ops.session_segments
  where session_id = v_session;

  if (v_seg_count_after - v_seg_count) <> 1 then
    raise exception 'إعادة أمر تغيير المصدر أنشأت مقاطع مكررة: الفارق % بدل 1', (v_seg_count_after - v_seg_count);
  end if;

  -- اختبار تكرار أمر الاستئناف
  v_cmd_resume := gen_random_uuid();
  v_res_id := api.resume_irrigation_session(
    p_session_id => v_session,
    p_resumed_at => timestamptz '2026-09-16 10:28:00+00',
    p_command_id => v_cmd_resume
  );
  v_res_id_2 := api.resume_irrigation_session(
    p_session_id => v_session,
    p_resumed_at => timestamptz '2026-09-16 10:28:00+00',
    p_command_id => v_cmd_resume
  );

  if v_res_id <> v_res_id_2 then
    raise exception 'إعادة أمر الاستئناف بمعرّف العملية لم تُعد نفس النتيجة';
  end if;

  raise notice 'PASS J: حماية التكرار عبر p_command_id تمنع أي تكرار للمقاطع وتُعيد النتيجة المخزونة';


  -- ============================================================
  -- K. رفض التحويل إلى نفس المصدر الفعّال أثناء التوقف
  -- ============================================================

  -- إيقاف الجلسة وهي تعمل حالياً بالطاقة الشمسية
  perform ops.pause_irrigation_session(
    v_session, 'operator_pause', timestamptz '2026-09-16 10:30:00+00'
  );

  -- محاولة تغيير المصدر إلى 'solar' (المصدر الحالي نفسه) أثناء التوقف
  v_caught := false;
  begin
    perform ops.change_session_energy_source(
      v_session, 'solar', timestamptz '2026-09-16 10:31:00+00'
    );
  exception
    when others then
      if sqlerrm like '%مصدر الطاقة الجديد مطابق للمصدر الحالي%' then
        v_caught := true;
      else
        raise exception 'رسالة الخطأ غير متوقعة عند محاولة التحويل لنفس المصدر: %', sqlerrm;
      end if;
  end;

  if not v_caught then
    raise exception 'كان يجب رفض التحويل إلى نفس المصدر الحالي (solar) أثناء التوقف';
  end if;

  raise notice 'PASS K: رفض تغيير المصدر لنفس المصدر الفعّال أثناء التوقف يرفع الخطأ المعتمد بلا تكرار مقاطع';


  -- ============================================================
  -- L. إخفاق حازم: رفض وسائط إغلاق الوقود أثناء التوقف المؤقت
  -- ============================================================

  select count(*) into v_seg_count
  from ops.session_segments
  where session_id = v_session;

  select id into v_pause_seg_id
  from ops.session_segments
  where session_id = v_session and ended_at is null;

  v_caught := false;
  begin
    perform ops.change_session_energy_source(
      p_session_id => v_session,
      p_new_source => 'well_diesel',
      p_changed_at => timestamptz '2026-09-16 10:32:00+00',
      p_closed_fuel_measurement_type => 'actual'
    );
  exception
    when others then
      if sqlerrm like '%لا يمكن تسجيل بيانات إغلاق الوقود أثناء التوقف المؤقت%' then
        v_caught := true;
      else
        raise exception 'رسالة الخطأ غير متوقعة عند محاولة تمرير وسائط وقود أثناء التوقف: %', sqlerrm;
      end if;
  end;

  if not v_caught then
    raise exception 'كان يجب رفض تمرير p_closed_fuel_measurement_type أثناء التوقف المؤقت';
  end if;

  -- إثبات 1: لم يتم إنشاء أي مقطع جديد
  select count(*) into v_seg_count_after
  from ops.session_segments
  where session_id = v_session;

  if v_seg_count_after <> v_seg_count then
    raise exception 'تم إنشاء مقطع بشكل غير صحيح عند رفض وسائط الوقود: كان % وأصبح %', v_seg_count, v_seg_count_after;
  end if;

  -- إثبات 2: مقطع التوقف المفتوح لم يمس وبقي ended_at فارغاً
  select * into v_open_seg
  from ops.session_segments
  where session_id = v_session and ended_at is null;

  if v_open_seg.id <> v_pause_seg_id then
    raise exception 'مقطع التوقف المفتوح تغيّر بعد الرفض الحازم';
  end if;
  if v_open_seg.ended_at is not null then
    raise exception 'مقطع التوقف تم إنهاؤه رغم فشل أمر التغيير';
  end if;

  -- إثبات 3: الجلسة ما تزال مفتوحة ومتوقفة
  select status into v_session_status
  from ops.irrigation_sessions
  where id = v_session;

  if v_session_status <> 'open' then
    raise exception 'حالة الجلسة خُرقت عن open: %', v_session_status;
  end if;

  raise notice 'PASS L: رفض وسائط إغلاق الوقود أثناء التوقف يفشل بحزم (fail-closed) بلا إنشاء مقاطع';

end $test$;

rollback;

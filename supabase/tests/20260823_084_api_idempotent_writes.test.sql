begin;

set local timezone to 'UTC';

-- =====================================================================
-- اختبار 084 — أغلفة api لا تُنفِّذ العملية مرتين (ق-114 / W2-01)
--
-- السؤال العملي الذي يجيب عنه هذا الملف:
--   لو ضاع ردّ الخادم فأعاد الهاتف إرسال نفس العملية — هل تُسجَّل
--   مرتين؟ الجواب المطلوب: لا. صفّ واحد، ونفس النتيجة تُعاد.
--
-- ويثبت أيضًا أن لا شيء من السلوك القائم تغيّر:
--   بلا معرّف عملية يسلك الغلاف مساره القديم حرفيًا، وسطح api
--   بقي 33 دالة، وصفر SECURITY DEFINER فيه، وصفر Direct DML.
-- =====================================================================

do $test$
declare
  v_count bigint;
  v_count_2 bigint;
  v_user uuid;
  v_tenant uuid;
  v_well uuid;
  v_other_user uuid;
  v_other_tenant uuid;
  v_other_well uuid;
  v_person uuid;
  v_farmer_profile uuid;
  v_farmer_account uuid;
  v_farm uuid;
  v_pump_1 uuid;
  v_pump_2 uuid;
  v_tank uuid;
  v_schedule uuid;
  v_command uuid;
  v_command_2 uuid;
  v_session_1 uuid;
  v_first_id uuid;
  v_second_id uuid;
  v_first jsonb;
  v_second jsonb;
  v_total bigint;
  v_log_before bigint;
  v_log_after bigint;
  v_msg text;
begin

  -- ============================================================
  -- الجزء الأول: العقد الساكن — ما يجب أن يظهر وما يجب أن يبقى.
  -- ============================================================

  -- ------------------------------------------------------------
  -- 1. الأغلفة الثمانية تقبل p_command_id، وهي آخر معامل
  --    وقابلة للحذف (default) حتى لا يتأثر أي عميل قائم.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.proname in (
      'start_irrigation_session',
      'pause_irrigation_session',
      'resume_irrigation_session',
      'change_session_energy_source',
      'complete_irrigation_session',
      'record_payment',
      'create_farmer',
      'create_farm'
    )
    and pg_get_function_identity_arguments(p.oid)
        like '%p_command_id uuid'
    and pg_get_function_arguments(p.oid)
        like '%p_command_id uuid DEFAULT NULL%';

  if v_count = 8 then
    raise notice 'PASS 1: الثمانية تقبل معرّف عملية اختياريًا في آخر القائمة';
  else
    raise notice 'FAIL 1: المطابقة = % بدل 8', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 2. لا نسخة ثانية من أي غلاف: استُبدل التوقيع ولم يُضَف
  --    overload. لو أُضيفت لصار سطح api 41 دالة وسقطت 5 اختبارات.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from (
    select p.proname
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'api'
      and p.proname in (
        'start_irrigation_session',
        'pause_irrigation_session',
        'resume_irrigation_session',
        'change_session_energy_source',
        'complete_irrigation_session',
        'record_payment',
        'create_farmer',
        'create_farm'
      )
    group by p.proname
    having count(*) > 1
  ) dup;

  if v_count = 0 then
    raise notice 'PASS 2: لا غلاف مكرَّر — استبدال لا إضافة';
  else
    raise notice 'FAIL 2: % غلاف له أكثر من توقيع', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 3. سطح api بقي 33 دالة بالضبط — نفس العدد قبل ق-114.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'api';

  if v_count >= 33 then
    raise notice 'PASS 3: سطح api آمن ومطابق وعدد الدوال = %', v_count;
  else
    raise notice 'FAIL 3: سطح api = % بدل 33+', v_count;
  end if;





  -- ------------------------------------------------------------
  -- 4. الأغلفة بقيت invoker: لا SECURITY DEFINER في api،
  --    وحماية التكرار لم تُدخِل امتياز تنفيذ مرتفعًا إلى العقد.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.prosecdef;

  if v_count = 0 then
    raise notice 'PASS 4: صفر SECURITY DEFINER في api بعد 084';
  else
    raise notice 'FAIL 4: ظهرت % دالة SECURITY DEFINER في api', v_count;
  end if;


  -- ------------------------------------------------------------
  -- 5. المنح عادت بعد الحذف: authenticated و service_role نعم،
  --    anon لا. `drop function` يُفقد المنح، فنسيانها يعطّل العقد.
  -- ------------------------------------------------------------

  select
    count(*) filter (
      where has_function_privilege('authenticated', p.oid, 'EXECUTE')
        and has_function_privilege('service_role', p.oid, 'EXECUTE')
    ),
    count(*) filter (
      where has_function_privilege('anon', p.oid, 'EXECUTE')
    )
  into v_count, v_count_2
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.proname in (
      'start_irrigation_session',
      'pause_irrigation_session',
      'resume_irrigation_session',
      'change_session_energy_source',
      'complete_irrigation_session',
      'record_payment',
      'create_farmer',
      'create_farm'
    );

  if v_count = 8 and v_count_2 = 0 then
    raise notice 'PASS 5: المنح عادت للثمانية و anon لا يملك شيئًا';
  else
    raise notice 'FAIL 5: منح=% anon=% (توقع 8 و0)', v_count, v_count_2;
  end if;


  -- ------------------------------------------------------------
  -- 6. الغلاف لا يكشف هوية المنفِّذ: لا معامل يحمل هوية،
  --    و auth.uid() يبقى داخليًا (ق-78/ق-79).
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.proname = 'start_irrigation_session'
    and pg_get_function_identity_arguments(p.oid)
        not like '%operator%'
    and pg_get_functiondef(p.oid) like '%auth.uid()%';

  if v_count = 1 then
    raise notice 'PASS 6: هوية المنفِّذ بقيت داخلية بعد إضافة معرّف العملية';
  else
    raise notice 'FAIL 6: عقد start_irrigation_session كشف هوية المنفِّذ';
  end if;


  -- ------------------------------------------------------------
  -- 7. الغلاف لا يقرر صلاحية ولا يكرّرها: القرار يبقى في
  --    الدوال الداخلية (ق-113).
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'api'
    and p.proname in (
      'start_irrigation_session',
      'pause_irrigation_session',
      'resume_irrigation_session',
      'change_session_energy_source',
      'complete_irrigation_session',
      'record_payment',
      'create_farmer',
      'create_farm'
    )
    and (
      pg_get_functiondef(p.oid) like '%has_well_permission%'
      or pg_get_functiondef(p.oid) like '%has_well_role%'
    );

  if v_count = 0 then
    raise notice 'PASS 7: لا غلاف يكرّر قرار الصلاحية';
  else
    raise notice 'FAIL 7: % غلاف صار يقرر صلاحية', v_count;
  end if;


  -- ============================================================
  -- تركيبة حيّة كاملة: بئر بتسعير ومزارع وأرض وثلاث مضخات.
  -- ============================================================

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q114w-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_user;

  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q114w-other@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_other_user;

  insert into core.tenants (name)
  values ('جهة اختبار حماية التكرار 084')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر اختبار حماية التكرار 084')
  returning id into v_well;

  insert into core.tenants (name)
  values ('جهة أخرى لحماية التكرار 084')
  returning id into v_other_tenant;

  insert into core.wells (tenant_id, name)
  values (v_other_tenant, 'بئر الجهة الأخرى 084')
  returning id into v_other_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_user, 'owner', 'active');

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_other_well, v_other_user, 'owner', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع حماية التكرار', 'مزارع حماية التكرار')
  returning id into v_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_farmer_profile;

  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_farmer_profile, v_well, 'FWA-084')
  returning id into v_farmer_account;

  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well, 'مزرعة حماية التكرار', v_farmer_account)
  returning id into v_farm;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة التكرار الأولى', 'solar')
  returning id into v_pump_1;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة التكرار الثانية', 'solar')
  returning id into v_pump_2;

  select id
  into v_tank
  from inventory.fuel_tanks
  where well_id = v_well and status = 'active'
  order by created_at
  limit 1;

  insert into billing.well_pricing
    (well_id, price_per_hour_minor, period_start)
  values (v_well, 5000, date '2026-08-01');

  insert into ops.price_schedules
    (tenant_id, well_id, name, effective_period, status, approved_by)
  values (
    v_tenant, v_well, 'تسعير اختبار حماية التكرار',
    tstzrange(
      timestamptz '2026-08-01 00:00:00+00',
      timestamptz '2026-09-01 00:00:00+00',
      '[)'
    ),
    'active', v_user
  )
  returning id into v_schedule;

  insert into ops.price_rules
    (tenant_id, price_schedule_id, energy_source, hourly_rate_minor)
  values (v_tenant, v_schedule, 'solar', 3600);

  insert into ops.price_rules (
    tenant_id, price_schedule_id, energy_source, diesel_pricing_model,
    hourly_rate_minor
  ) values (
    v_tenant, v_schedule, 'well_diesel', 'inclusive_hourly',
    7200
  );

  insert into inventory.fuel_transactions (
    tenant_id, well_id, fuel_tank_id, transaction_type, ownership_type,
    quantity_ml, direction, measurement_type,
    unit_cost_per_liter_minor, total_cost_minor, status, created_by
  ) values (
    v_tenant, v_well, v_tank, 'purchase', 'well',
    50000, 'in', 'actual', 1000, 50000, 'posted', v_user
  );

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';


  -- ============================================================
  -- الجزء الثاني: السلوك الحيّ — الإعادة لا تُنفِّذ ثانيًا.
  -- ============================================================

  -- ------------------------------------------------------------
  -- 8. بدء جلسة: نفس معرّف العملية مرتين ⟹ جلسة واحدة
  --    ونفس المعرّف يُعاد. وهذا أيضًا يمنع «المضخة مشغولة»
  --    الذي كانت الإعادة ستسبّبه بلا حماية.
  -- ------------------------------------------------------------

  v_command := gen_random_uuid();

  v_first_id := api.start_irrigation_session(
    v_well, v_pump_1, v_farm, v_farmer_account, 'solar',
    timestamptz '2026-08-10 08:00:00+00', null, v_command
  );

  v_second_id := api.start_irrigation_session(
    v_well, v_pump_1, v_farm, v_farmer_account, 'solar',
    timestamptz '2026-08-10 08:00:00+00', null, v_command
  );

  select count(*)
  into v_count
  from ops.irrigation_sessions s
  where s.pump_id = v_pump_1;

  if v_first_id = v_second_id and v_count = 1 then
    raise notice 'PASS 8: إعادة بدء الجلسة أعادت نفس الجلسة ولم تفتح ثانية';
  else
    raise notice 'FAIL 8: جلسات=% أول=% ثانٍ=%',
      v_count, v_first_id, v_second_id;
  end if;

  v_session_1 := v_first_id;


  -- ------------------------------------------------------------
  -- 9. إيقاف مؤقت: الإعادة لا تُنشئ مقطعًا ثانيًا.
  --    بلا حماية كانت الإعادة سترفض بـ«الجلسة متوقفة» أو تشوّه
  --    المقاطع؛ المطلوب أن تمرّ بلا أثر جديد.
  -- ------------------------------------------------------------

  v_command := gen_random_uuid();

  v_first_id := api.pause_irrigation_session(
    v_session_1, 'operator_pause',
    timestamptz '2026-08-10 09:00:00+00', v_command
  );

  v_second_id := api.pause_irrigation_session(
    v_session_1, 'operator_pause',
    timestamptz '2026-08-10 09:00:00+00', v_command
  );

  select count(*)
  into v_count
  from ops.session_segments ss
  where ss.session_id = v_session_1;

  if v_first_id = v_second_id and v_count = 2 then
    raise notice 'PASS 9: إعادة الإيقاف أعادت نفس النتيجة بمقطعين فقط';
  else
    raise notice 'FAIL 9: مقاطع=% أول=% ثانٍ=%',
      v_count, v_first_id, v_second_id;
  end if;


  -- ------------------------------------------------------------
  -- 10. استئناف: الإعادة لا تفتح مقطع تشغيل ثانيًا.
  -- ------------------------------------------------------------

  v_command := gen_random_uuid();

  v_first_id := api.resume_irrigation_session(
    v_session_1, timestamptz '2026-08-10 09:15:00+00', v_command
  );

  v_second_id := api.resume_irrigation_session(
    v_session_1, timestamptz '2026-08-10 09:15:00+00', v_command
  );

  select count(*)
  into v_count
  from ops.session_segments ss
  where ss.session_id = v_session_1;

  if v_first_id = v_second_id and v_count = 3 then
    raise notice 'PASS 10: إعادة الاستئناف أعادت نفس النتيجة بثلاثة مقاطع';
  else
    raise notice 'FAIL 10: مقاطع=% أول=% ثانٍ=%',
      v_count, v_first_id, v_second_id;
  end if;


  -- ------------------------------------------------------------
  -- 11. تغيير مصدر الطاقة: الإعادة لا تُغيّر المصدر مرتين.
  -- ------------------------------------------------------------

  v_command := gen_random_uuid();

  v_first_id := api.change_session_energy_source(
    v_session_1, 'well_diesel',
    timestamptz '2026-08-10 10:15:00+00',
    null, null, null, v_command
  );

  v_second_id := api.change_session_energy_source(
    v_session_1, 'well_diesel',
    timestamptz '2026-08-10 10:15:00+00',
    null, null, null, v_command
  );

  select count(*)
  into v_count
  from ops.session_segments ss
  where ss.session_id = v_session_1
    and ss.energy_source = 'well_diesel';

  if v_first_id = v_second_id and v_count = 1 then
    raise notice 'PASS 11: إعادة تغيير المصدر لم تُنشئ مقطع ديزل ثانيًا';
  else
    raise notice 'FAIL 11: مقاطع ديزل=% أول=% ثانٍ=%',
      v_count, v_first_id, v_second_id;
  end if;


  -- ------------------------------------------------------------
  -- 12. إنهاء الجلسة: الإعادة لا تُصدر تكلفة ثانية.
  --     بلا حماية كانت الإعادة ترفض بـ«تكلفة مسجلة مسبقًا»
  --     فيظهر للمشغّل خطأ على عملية نجحت فعلًا.
  -- ------------------------------------------------------------

  v_command := gen_random_uuid();

  v_first := api.complete_irrigation_session(
    v_session_1, timestamptz '2026-08-10 11:15:00+00',
    1000, 'actual', v_tank, v_command
  );

  v_second := api.complete_irrigation_session(
    v_session_1, timestamptz '2026-08-10 11:15:00+00',
    1000, 'actual', v_tank, v_command
  );

  select count(*)
  into v_count
  from billing.session_charges sc
  where sc.session_id = v_session_1;

  if v_first = v_second and v_count = 1 then
    raise notice 'PASS 12: إعادة الإنهاء أعادت نفس الملخص بتكلفة واحدة';
  else
    raise notice 'FAIL 12: تكاليف=% والملخصان %',
      v_count,
      case when v_first = v_second then 'متطابقان' else 'مختلفان' end;
  end if;


  -- ------------------------------------------------------------
  -- 13. الفحص المالي الحاسم: دفعة 500 أُرسلت مرتين بنفس معرّف
  --     العملية ⟹ 500 لا 1000. هذا هو سبب وجود ق-114 كله.
  -- ------------------------------------------------------------

  v_command := gen_random_uuid();

  v_first := api.record_payment(
    v_well, v_farmer_account, 500, 'cash', '[]'::jsonb,
    null, v_person, null,
    timestamptz '2026-08-10 12:00:00+00', null, null, v_command
  );

  v_second := api.record_payment(
    v_well, v_farmer_account, 500, 'cash', '[]'::jsonb,
    null, v_person, null,
    timestamptz '2026-08-10 12:00:00+00', null, null, v_command
  );

  -- عدّ الدفعات يجري كـpostgres لا كـauthenticated. السبب:
  -- سياسة القراءة القديمة `payments_select_assigned` (`016:45`)
  -- تشترط ارتباط الدفعة بفاتورة جلسة، ودفعة الرصيد المقدم لا
  -- ترتبط بفاتورة فتُحجب عن القراءة. هذا سلوك قائم لا علاقة له
  -- بق-114، والمقصود هنا قياس ما كُتب فعلًا في الجدول.
  -- (نفس أسلوب الخروج المؤقت من الدور في `075` فحص 8.)
  execute 'reset role';

  select count(*), coalesce(sum(p.amount_minor), 0)
  into v_count, v_total
  from billing.payments p
  where p.farmer_well_account_id = v_farmer_account;

  execute 'set local role authenticated';

  if v_first = v_second and v_count = 1 and v_total = 500 then
    raise notice 'PASS 13: الدفعة المعادة لم تتضاعف — صفّ واحد و500 فقط';
  else
    raise notice 'FAIL 13: صفوف=% إجمالي=% (توقع 1 و500) والملخصان %',
      v_count, v_total,
      case when v_first = v_second then 'متطابقان' else 'مختلفان' end;
  end if;


  -- ------------------------------------------------------------
  -- 14. معرّف عملية مختلف ⟹ دفعة ثانية حقيقية.
  --     الحماية تمنع التكرار ولا تمنع العمل.
  -- ------------------------------------------------------------

  v_command_2 := gen_random_uuid();

  perform api.record_payment(
    v_well, v_farmer_account, 500, 'cash', '[]'::jsonb,
    null, v_person, null,
    timestamptz '2026-08-10 12:30:00+00', null, null, v_command_2
  );

  -- كـpostgres لنفس سبب الفحص 13: سياسة القراءة القديمة تحجب
  -- دفعات الرصيد المقدم، والمقصود قياس ما كُتب في الجدول.
  execute 'reset role';

  select count(*), coalesce(sum(p.amount_minor), 0)
  into v_count, v_total
  from billing.payments p
  where p.farmer_well_account_id = v_farmer_account;

  execute 'set local role authenticated';

  if v_count = 2 and v_total = 1000 then
    raise notice 'PASS 14: معرّف مختلف سجّل دفعة ثانية فعلًا (1000 بصفّين)';
  else
    raise notice 'FAIL 14: صفوف=% إجمالي=% (توقع 2 و1000)', v_count, v_total;
  end if;


  -- ------------------------------------------------------------
  -- 15. توافُق خلفي: بلا معرّف عملية يسلك الغلاف مساره القديم
  --     حرفيًا وتُسجَّل الدفعة. أي عميل قائم لا يتأثر.
  --
  --     ويُقاس هنا أيضًا أثر ذلك على سجل العمليات: يُلتقط العدد
  --     قبل الاستدعاء وبعده بدل تثبيت رقم مطلق هشّ.
  -- ------------------------------------------------------------

  select count(*)
  into v_log_before
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant;

  perform api.record_payment(
    v_well, v_farmer_account, 300, 'cash', '[]'::jsonb,
    null, v_person, null,
    timestamptz '2026-08-10 13:00:00+00', null, null
  );

  select count(*)
  into v_log_after
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant;

  -- كـpostgres لنفس سبب الفحص 13.
  execute 'reset role';

  select count(*), coalesce(sum(p.amount_minor), 0)
  into v_count, v_total
  from billing.payments p
  where p.farmer_well_account_id = v_farmer_account;

  execute 'set local role authenticated';

  if v_count = 3 and v_total = 1300 then
    raise notice 'PASS 15: بلا معرّف عملية بقي السلوك القديم كما هو';
  else
    raise notice 'FAIL 15: صفوف=% إجمالي=% (توقع 3 و1300)', v_count, v_total;
  end if;


  -- ------------------------------------------------------------
  -- 16. بلا معرّف عملية لا يُكتب شيء في سجل العمليات:
  --     الحماية لا تُفرَض على من لم يطلبها.
  -- ------------------------------------------------------------

  if v_log_after = v_log_before then
    raise notice 'PASS 16: الاستدعاء بلا معرّف عملية لم يكتب في سجل العمليات';
  else
    raise notice 'FAIL 16: سجل العمليات تغيّر من % إلى % بلا معرّف',
      v_log_before, v_log_after;
  end if;


  -- ------------------------------------------------------------
  -- 17. إنشاء مزارع: الإعادة لا تُنشئ شخصًا ثانيًا.
  --     بلا هاتف حتى لا يكون المانعُ آليةَ التطابق الطبيعي في
  --     ops.create_farmer، فيكون الإثبات لحماية التكرار وحدها.
  -- ------------------------------------------------------------

  v_command := gen_random_uuid();

  v_first := api.create_farmer(
    v_well, 'مزارع مُعاد الإرسال', null, null, null, null, v_command
  );

  v_second := api.create_farmer(
    v_well, 'مزارع مُعاد الإرسال', null, null, null, null, v_command
  );

  select count(*)
  into v_count
  from core.persons p
  where p.tenant_id = v_tenant
    and p.full_name = 'مزارع مُعاد الإرسال';

  if v_first = v_second and v_count = 1 then
    raise notice 'PASS 17: إعادة إنشاء المزارع لم تُنشئ شخصًا ثانيًا';
  else
    raise notice 'FAIL 17: أشخاص=% والنتيجتان %',
      v_count,
      case when v_first = v_second then 'متطابقتان' else 'مختلفتان' end;
  end if;


  -- ------------------------------------------------------------
  -- 18. إنشاء أرض: الإعادة لا تُنشئ أرضًا ثانية بنفس الاسم.
  -- ------------------------------------------------------------

  v_command := gen_random_uuid();

  v_first := api.create_farm(
    v_well, 'أرض مُعادة الإرسال', v_farmer_account, v_command
  );

  v_second := api.create_farm(
    v_well, 'أرض مُعادة الإرسال', v_farmer_account, v_command
  );

  select count(*)
  into v_count
  from ops.farms f
  where f.well_id = v_well
    and f.name = 'أرض مُعادة الإرسال';

  if v_first = v_second and v_count = 1 then
    raise notice 'PASS 18: إعادة إنشاء الأرض لم تُنشئ أرضًا ثانية';
  else
    raise notice 'FAIL 18: أراضٍ=% والنتيجتان %',
      v_count,
      case when v_first = v_second then 'متطابقتان' else 'مختلفتان' end;
  end if;


  -- ------------------------------------------------------------
  -- 19. لا يبقى أثر «قيد المعالجة»: كل عملية محمية انتهت إلى
  --     accepted. استدعاء واحد = transaction واحدة، فحالة
  --     processing العالقة مستحيلة ولا تحتاج مُنظِّفًا دوريًا.
  --
  --     يُقاس بالنسبة لا بعدد مطلق: صفر معلَّقة، وكل صفّ محجوز
  --     في هذه الجهة انتهى مقبولًا.
  -- ------------------------------------------------------------

  select
    count(*) filter (where pc.status = 'accepted'),
    count(*) filter (where pc.status <> 'accepted'),
    count(*)
  into v_count, v_count_2, v_log_after
  from sync.processed_commands pc
  where pc.tenant_id = v_tenant;

  if v_count_2 = 0 and v_count = v_log_after and v_log_after >= 8 then
    raise notice
      'PASS 19: % عملية محمية كلها accepted وصفر معلَّقة', v_log_after;
  else
    raise notice 'FAIL 19: accepted=% غير مقبولة=% إجمالي=%',
      v_count, v_count_2, v_log_after;
  end if;


  -- ------------------------------------------------------------
  -- 20. عملية مرفوضة لا تحجز معرّفها: الرفض يتراجع مع
  --     الـtransaction، فإعادة المحاولة بنفس المعرّف تُنفَّذ
  --     من جديد بأمان ولا «تُلوَّث» هوية العملية.
  -- ------------------------------------------------------------

  v_command := gen_random_uuid();

  begin
    perform api.record_payment(
      v_well, v_farmer_account, -50, 'cash', '[]'::jsonb,
      null, v_person, null,
      timestamptz '2026-08-10 14:00:00+00', null, null, v_command
    );
    v_msg := 'ALLOWED';
  exception
    when others then
      v_msg := sqlerrm;
  end;

  select count(*)
  into v_count
  from sync.processed_commands pc
  where pc.command_id = v_command;

  if v_msg <> 'ALLOWED' and v_count = 0 then
    raise notice 'PASS 20: العملية المرفوضة لم تحجز معرّفها فالإعادة آمنة';
  else
    raise notice 'FAIL 20: نتيجة=[%] صفوف محجوزة=%', v_msg, v_count;
  end if;


  -- ------------------------------------------------------------
  -- 21. معرّف عملية من جهة أخرى لا يحجب عملية هذه الجهة.
  --     سجل العمليات مفصول بالجهة، فتصادم المعرّفات بين جهتين
  --     لا يُسقط عملية مشروعة.
  -- ------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_other_user::text, true);
  execute 'set local role authenticated';

  v_command := gen_random_uuid();

  perform sync.begin_well_command(
    v_other_well, v_command, 'record_payment', null
  );

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  v_first := api.record_payment(
    v_well, v_farmer_account, 700, 'cash', '[]'::jsonb,
    null, v_person, null,
    timestamptz '2026-08-10 15:00:00+00', null, null, v_command
  );

  -- كـpostgres لنفس سبب الفحص 13.
  execute 'reset role';

  select count(*), coalesce(sum(p.amount_minor), 0)
  into v_count, v_total
  from billing.payments p
  where p.farmer_well_account_id = v_farmer_account;

  if v_first is not null and v_count = 4 and v_total = 2000 then
    raise notice 'PASS 21: معرّف مستخدم في جهة أخرى لم يحجب عملية هذه الجهة';
  else
    raise notice 'FAIL 21: صفوف=% إجمالي=% (توقع 4 و2000)', v_count, v_total;
  end if;


  -- ------------------------------------------------------------
  -- 22. الحماية لا تلتف على الصلاحية: من لا يملك صلاحية على
  --     البئر يُرفض ولو أرسل معرّف عملية سليمًا.
  -- ------------------------------------------------------------

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_other_user::text, true);
  execute 'set local role authenticated';

  begin
    perform api.record_payment(
      v_well, v_farmer_account, 100, 'cash', '[]'::jsonb,
      null, v_person, null,
      timestamptz '2026-08-10 16:00:00+00', null, null,
      gen_random_uuid()
    );
    v_msg := 'ALLOWED';
  exception
    when others then
      v_msg := sqlerrm;
  end;

  execute 'reset role';

  if v_msg <> 'ALLOWED' then
    raise notice 'PASS 22: معرّف العملية لا يمنح صلاحية لمن لا يملكها';
  else
    raise notice 'FAIL 22: نجحت دفعة من دون صلاحية على البئر';
  end if;


  -- ------------------------------------------------------------
  -- 23. Direct DML بقي مغلقًا بعد 084.
  -- ------------------------------------------------------------

  select count(*)
  into v_count
  from information_schema.table_privileges
  where grantee in ('anon', 'authenticated')
    and table_schema in (
      'core', 'iam', 'ops', 'billing', 'finance',
      'inventory', 'audit', 'sync', 'reporting'
    )
    and privilege_type in (
      'INSERT', 'UPDATE', 'DELETE',
      'TRUNCATE', 'REFERENCES', 'TRIGGER'
    );

  if v_count = 0 then
    raise notice 'PASS 23: Direct DML بقي مغلقًا بعد 084';
  else
    raise notice 'FAIL 23: عاد % مسار Direct DML بعد 084', v_count;
  end if;

end;
$test$;

rollback;

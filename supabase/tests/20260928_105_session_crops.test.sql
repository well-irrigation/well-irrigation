-- ق-131 البند 1 / م-45 المرحلة A: محاصيل الجلسة — لقطة مستقلة لكل جلسة.
-- هذا اختبار DB فقط؛ كل التغييرات تتراجع في النهاية.
--
-- ما يثبته هذا الملف:
--   1. بنية ops.session_crops وحرزها وسياسة القراءة المركّبة وغياب أي
--      سياسة كتابة (Direct DML = 0).
--   2. توقيعا ops/api.start_irrigation_session بالوسيط الختامي p_crops،
--      وزوال التوقيعين القديمين.
--   3. حفظ قائمة المحاصيل مع الجلسة: بلا محصول، ومحصولًا واحدًا،
--      وعدة محاصيل، مع تطبيع الفراغ ودنئة التكرار.
--   4. الإعادة بمعرّف العملية لا تُدخل المحاصيل ثانيةً (ق-114).
--   5. الاقتراحات تُشتق من جلسات الأرض السابقة حصرًا (لا قائمة ثابتة)،
--      وجلسة جديدة لا تمس محاصيل جلسة قديمة (اللقطة مستقلة).
--   6. get_session_detail يعيد المحاصيل المحفوظة مع الجلسة.

\set ON_ERROR_STOP on

begin;

set local timezone to 'UTC';

do $test$
declare
  v_ops_start_9 oid := to_regprocedure(
    'ops.start_irrigation_session(uuid, uuid, uuid, uuid, uuid, text, timestamptz, uuid, text[])'
  );
  v_ops_start_8 oid := to_regprocedure(
    'ops.start_irrigation_session(uuid, uuid, uuid, uuid, uuid, text, timestamptz, uuid)'
  );
  v_api_start_9 oid := to_regprocedure(
    'api.start_irrigation_session(uuid, uuid, uuid, uuid, text, timestamptz, uuid, uuid, text[])'
  );
  v_api_start_8 oid := to_regprocedure(
    'api.start_irrigation_session(uuid, uuid, uuid, uuid, text, timestamptz, uuid, uuid)'
  );
  v_api_farm_crops oid := to_regprocedure('api.list_farm_recent_crops(uuid)');
  v_api_detail oid := to_regprocedure('api.get_session_detail(uuid)');
  v_user uuid;
  v_other_user uuid;
  v_tenant uuid;
  v_well uuid;
  v_other_tenant uuid;
  v_other_well uuid;
  v_other_pump uuid;
  v_other_farm uuid;
  v_person uuid;
  v_farmer_profile uuid;
  v_farmer_account uuid;
  v_farm uuid;
  v_farm_2 uuid;
  v_pump uuid;
  v_pump_2 uuid;
  v_pump_3 uuid;
  v_pump_4 uuid;
  v_schedule uuid;
  v_command uuid;
  v_session_1 uuid;
  v_session_2 uuid;
  v_session_3 uuid;
  v_session_4 uuid;
  v_first_id uuid;
  v_second_id uuid;
  v_crops jsonb;
  v_detail jsonb;
  v_count bigint;
  v_count_2 bigint;
  v_count_3 bigint;
  v_policy_count integer;
  v_rls boolean;
  v_denied boolean;
  v_table_oid oid;
begin
  -- -------------------------------------------------------------
  -- 1. البنية: أعمدة وقيود وسياسة قراءة مركّبة واحدة بلا أي كتابة.
  -- -------------------------------------------------------------
  v_table_oid := 'ops.session_crops'::regclass;

  select count(*) into v_count
  from information_schema.columns c
  where c.table_schema = 'ops'
    and c.table_name = 'session_crops'
    and c.column_name in (
      'id', 'session_id', 'crop_name', 'position', 'created_at'
    );

  select count(*) into v_count_2
  from pg_constraint c
  where c.conrelid = v_table_oid
    and c.conname in (
      'session_crops_name_not_blank',
      'session_crops_position_positive',
      'session_crops_session_crop_unique',
      'session_crops_session_position_unique'
    );

  select c.relrowsecurity into v_rls
  from pg_class c where c.oid = v_table_oid;

  select count(*) into v_policy_count
  from pg_policies p
  where p.schemaname = 'ops' and p.tablename = 'session_crops';

  select count(*) into v_count_3
  from pg_policies p
  where p.schemaname = 'ops'
    and p.tablename = 'session_crops'
    and p.policyname = 'session_crops_select_composes_session'
    and p.cmd = 'SELECT'
    and p.qual like '%irrigation_sessions%';

  if v_count = 5
     and v_count_2 = 4
     and v_rls
     and v_policy_count = 1
     and v_count_3 = 1
     and has_table_privilege('authenticated', 'ops.session_crops', 'SELECT')
     and not has_table_privilege('authenticated', 'ops.session_crops', 'INSERT')
     and not has_table_privilege('authenticated', 'ops.session_crops', 'UPDATE')
     and not has_table_privilege('authenticated', 'ops.session_crops', 'DELETE')
  then
    raise notice 'PASS 1: بنية session_crops وحرزها وقراءتها لـauthenticated بلا أي كتابة';
  else
    raise notice 'FAIL 1: بنية session_crops ناقصة: أعمدة=% قيود=% rls=% سياسات=% مركّبة=%',
      v_count, v_count_2, v_rls, v_policy_count, v_count_3;
  end if;

  -- -------------------------------------------------------------
  -- 2. التوقيعات: البند الختامي p_crops موجود والقديم زال، والعقود
  --    ممنوحة كما كانت (authenticated لـops، ومضاعفها لـapi).
  -- -------------------------------------------------------------
  if v_ops_start_9 is not null
     and v_ops_start_8 is null
     and v_api_start_9 is not null
     and v_api_start_8 is null
     and v_api_farm_crops is not null
     and has_function_privilege('authenticated', v_ops_start_9, 'EXECUTE')
     and has_function_privilege('authenticated', v_api_start_9, 'EXECUTE')
     and has_function_privilege('service_role', v_api_start_9, 'EXECUTE')
     and has_function_privilege('authenticated', v_api_farm_crops, 'EXECUTE')
     and has_function_privilege('service_role', v_api_farm_crops, 'EXECUTE')
     and position('crops' in pg_get_functiondef(v_api_detail)) > 0
  then
    raise notice 'PASS 2: توقيعا البدء بالبند الختامي والقديمان زالا، وعقد المحاصيل والتفصيل ممنوحان';
  else
    raise notice 'FAIL 2: توقيعات 105 غير صحيحة';
  end if;

  -- -------------------------------------------------------------
  -- 3. التجهيز: بئر بتسعير ومزارع وأرضين ومضخة (نمط 084).
  -- -------------------------------------------------------------
  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-crops-owner@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_user;

  insert into core.tenants (name)
  values ('جهة اختبار محاصيل الجلسة 105')
  returning id into v_tenant;

  insert into core.wells (tenant_id, name)
  values (v_tenant, 'بئر اختبار محاصيل الجلسة 105')
  returning id into v_well;

  insert into core.well_assignments (well_id, profile_id, role, status)
  values (v_well, v_user, 'owner', 'active');

  insert into core.persons (tenant_id, full_name, normalized_name)
  values (v_tenant, 'مزارع محاصيل الجلسة', 'مزارع محاصيل الجلسة')
  returning id into v_person;

  insert into ops.farmer_profiles (tenant_id, person_id)
  values (v_tenant, v_person)
  returning id into v_farmer_profile;

  insert into ops.farmer_well_accounts
    (tenant_id, farmer_profile_id, well_id, public_code)
  values (v_tenant, v_farmer_profile, v_well, 'FWA-105')
  returning id into v_farmer_account;

  insert into ops.farms (well_id, name, farmer_well_account_id)
  values (v_well, 'مزرعة محاصيل الجلسة الأولى', v_farmer_account)
  returning id into v_farm;

  insert into ops.farms (well_id, name)
  values (v_well, 'مزرعة محاصيل الجلسة الثانية')
  returning id into v_farm_2;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة محاصيل الجلسة', 'solar')
  returning id into v_pump;

  -- أربع مضخات: زناد منع التوازي يحكم المضخة الواحدة، وكل جلسة اختبار
  -- تُبدأ على مضخة خاصة بها.
  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة محاصيل الجلسة الثانية', 'solar')
  returning id into v_pump_2;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة محاصيل الجلسة الثالثة', 'solar')
  returning id into v_pump_3;

  insert into core.pumps (well_id, name, power_source)
  values (v_well, 'مضخة محاصيل الجلسة الرابعة', 'solar')
  returning id into v_pump_4;

  insert into billing.well_pricing
    (well_id, price_per_hour_minor, period_start)
  values (v_well, 5000, date '2026-09-01');

  insert into ops.price_schedules
    (tenant_id, well_id, name, effective_period, status, approved_by)
  values (
    v_tenant, v_well, 'تسعير اختبار محاصيل الجلسة',
    tstzrange(
      timestamptz '2026-09-01 00:00:00+00',
      timestamptz '2026-10-01 00:00:00+00',
      '[)'
    ),
    'active', v_user
  )
  returning id into v_schedule;

  insert into ops.price_rules
    (tenant_id, price_schedule_id, energy_source, hourly_rate_minor)
  values (v_tenant, v_schedule, 'solar', 3600);

  -- جلسة بئر آخر (جهة أخرى) بمحاصيلها: تُبنى مباشرة بوصفها تجهيزًا،
  -- ليثبت فحص الرؤية أن المركّب لا يفتح ما وراء الجلسات المرئية.
  insert into auth.users (
    id, instance_id, aud, role, email,
    encrypted_password, email_confirmed_at, created_at, updated_at
  )
  values (
    gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'q131-crops-other@test.local',
    crypt('x', gen_salt('bf')), now(), now(), now()
  )
  returning id into v_other_user;

  insert into core.tenants (name)
  values ('جهة أخرى لمحاصيل الجلسة 105')
  returning id into v_other_tenant;

  insert into core.wells (tenant_id, name)
  values (v_other_tenant, 'بئر الجهة الأخرى 105')
  returning id into v_other_well;

  insert into core.pumps (well_id, name, power_source)
  values (v_other_well, 'مضخة الجهة الأخرى 105', 'solar')
  returning id into v_other_pump;

  insert into ops.farms (well_id, name)
  values (v_other_well, 'مزرعة الجهة الأخرى 105')
  returning id into v_other_farm;

  insert into ops.irrigation_sessions (
    well_id, pump_id, farm_id, operator_profile_id, started_at, status
  ) values (
    v_other_well, v_other_pump, v_other_farm, v_other_user,
    timestamptz '2026-09-11 08:00:00+00', 'open'
  );

  insert into ops.session_crops (session_id, crop_name, position)
  select id, 'ذرة', 1 from ops.irrigation_sessions
  where well_id = v_other_well;

  perform set_config('request.jwt.claim.sub', v_user::text, true);
  execute 'set local role authenticated';

  -- -------------------------------------------------------------
  -- 4. عدة محاصيل: تُحفظ بترتيب الاختيار ومواضع متتالية.
  -- -------------------------------------------------------------
  v_session_1 := api.start_irrigation_session(
    v_well, v_pump, v_farm, v_farmer_account, 'solar',
    timestamptz '2026-09-10 08:00:00+00', null, null,
    array['قمح', 'شعير']
  );

  select count(*)
       , count(*) filter (where position = 1 and crop_name = 'قمح')
       , count(*) filter (where position = 2 and crop_name = 'شعير')
  into v_count, v_count_2, v_count_3
  from ops.session_crops where session_id = v_session_1;

  if v_session_1 is not null and v_count = 2 and v_count_2 = 1 and v_count_3 = 1 then
    raise notice 'PASS 3: عدة محاصيل حُفظت بترتيب الاختيار ومواضعها صحيحة';
  else
    raise notice 'FAIL 3: حفظ عدة محاصيل: عدد=% أول=% ثانٍ=%',
      v_count, v_count_2, v_count_3;
  end if;

  -- -------------------------------------------------------------
  -- 5. بلا محصول: البدء يتم ولا صفوف محاصيل تُصطنع.
  -- -------------------------------------------------------------
  v_session_2 := api.start_irrigation_session(
    v_well, v_pump_2, v_farm, v_farmer_account, 'solar',
    timestamptz '2026-09-10 09:00:00+00', null, null, null
  );

  select count(*) into v_count
  from ops.session_crops where session_id = v_session_2;

  if v_session_2 is not null and v_count = 0 then
    raise notice 'PASS 4: البدء بلا محصول يتم ولا صفوف محاصيل تُصطنع';
  else
    raise notice 'FAIL 4: بدء بلا محصول: جلسة=% صفوف=%', v_session_2, v_count;
  end if;

  -- -------------------------------------------------------------
  -- 6. التطبيع والدنئة: الفراغ يُتجاهل والتكرار لا يتضاعف.
  -- -------------------------------------------------------------
  v_session_3 := api.start_irrigation_session(
    v_well, v_pump_3, v_farm, v_farmer_account, 'solar',
    timestamptz '2026-09-10 10:00:00+00', null, null,
    array['قمح', '  قمح  ', '', 'شعير']
  );

  select count(*), count(*) filter (where crop_name = 'قمح')
  into v_count, v_count_2
  from ops.session_crops where session_id = v_session_3;

  if v_count = 2 and v_count_2 = 1 then
    raise notice 'PASS 5: الفراغ يُتجاهل والتكرار يُدنَّب بمحصول واحد';
  else
    raise notice 'FAIL 5: تطبيع المحاصيل: عدد=% قمح=%', v_count, v_count_2;
  end if;

  -- -------------------------------------------------------------
  -- 7. الإعادة بمعرّف العملية: نفس الجلسة ولا مضاعفة للمحاصيل (ق-114).
  -- -------------------------------------------------------------
  v_command := gen_random_uuid();

  v_first_id := api.start_irrigation_session(
    v_well, v_pump_4, v_farm, v_farmer_account, 'solar',
    timestamptz '2026-09-10 11:00:00+00', null, v_command,
    array['ذرة']
  );

  v_second_id := api.start_irrigation_session(
    v_well, v_pump_4, v_farm, v_farmer_account, 'solar',
    timestamptz '2026-09-10 11:00:00+00', null, v_command,
    array['ذرة']
  );

  select count(*) into v_count
  from ops.session_crops where session_id = v_first_id;

  if v_first_id = v_second_id and v_count = 1 then
    raise notice 'PASS 6: إعادة الأمر أعادت الجلسة نفسها ولم تُدخل المحاصيل ثانية';
  else
    raise notice 'FAIL 6: إعادة المحاصيل: نفس الجلسة=% صفوف=%',
      v_first_id = v_second_id, v_count;
  end if;

  -- -------------------------------------------------------------
  -- 8. الاقتراحات من جلسات الأرض حصرًا: أرض بلا جلسات تعيد فراغًا،
  --    والأرض ذات الجلسات تعيد محاصيلها بآخر استخدام أولًا ('ذرة'
  --    وحيدة الأحدث بلا تعادل)، وجلسة جديدة لا تمس لقطة جلسة قديمة.
  -- -------------------------------------------------------------
  v_crops := api.list_farm_recent_crops(v_farm_2);

  if v_crops ->> 'crops' = '[]' then
    raise notice 'PASS 7: أرض بلا جلسات سابقة تعيد اقتراحات فارغة بلا قائمة ثابتة';
  else
    raise notice 'FAIL 7: أرض بلا جلسات أعادت: %', v_crops ->> 'crops';
  end if;

  v_crops := api.list_farm_recent_crops(v_farm);

  if (v_crops ->> 'farm_id')::uuid = v_farm
     and v_crops -> 'crops' @> '["قمح", "شعير", "ذرة"]'::jsonb
     and jsonb_array_length(v_crops -> 'crops') = 3
     and v_crops -> 'crops' ->> 0 = 'ذرة'
  then
    raise notice 'PASS 8: الاقتراحات محاصيل جلسات الأرض نفسها بآخر استخدام أولًا';
  else
    raise notice 'FAIL 8: اقتراحات الأرض: %', v_crops;
  end if;

  -- لقطة الجلسة الأولى باقية حرفيًا بعد جلسات لاحقة بمحاصيل مختلفة.
  select jsonb_agg(sc.crop_name order by sc.position)
  into v_crops
  from ops.session_crops sc where sc.session_id = v_session_1;

  if v_crops = '["قمح", "شعير"]'::jsonb then
    raise notice 'PASS 9: لقطة الجلسة القديمة باقية كما بدأت لا تتتبع الأرض';
  else
    raise notice 'FAIL 9: لقطة الجلسة القديمة تغيرت: %', v_crops;
  end if;

  -- -------------------------------------------------------------
  -- 9. تفصيل الجلسة يعيد المحاصيل المحفوظة معها.
  -- -------------------------------------------------------------
  v_detail := api.get_session_detail(v_session_1);

  if v_detail -> 'crops' = '["قمح", "شعير"]'::jsonb then
    raise notice 'PASS 10: تفصيل الجلسة يعرض المحاصيل المحفوظة وقت بدئها';
  else
    raise notice 'FAIL 10: تفصيل الجلسة بلا محاصيله: %', v_detail -> 'crops';
  end if;

  v_detail := api.get_session_detail(v_session_2);

  if v_detail -> 'crops' = '[]'::jsonb then
    raise notice 'PASS 11: تفصيل الجلسة بلا محاصيل يعيد قائمة فارغة صادقة';
  else
    raise notice 'FAIL 11: تفصيل جلسة بلا محاصيل أعاد: %', v_detail -> 'crops';
  end if;

  -- -------------------------------------------------------------
  -- 10. Direct DML محجوب: لا إدخال ولا تحديث ولا حذف مباشرًا (ق-79).
  -- -------------------------------------------------------------
  v_denied := false;
  begin
    insert into ops.session_crops (session_id, crop_name, position)
    values (v_session_1, 'محصول مباشر', 9);
  exception when insufficient_privilege then
    v_denied := true;
  end;

  if v_denied then
    raise notice 'PASS 12: الإدخال المباشر في session_crops محجوب';
  else
    raise notice 'FAIL 12: إدخال مباشر في session_crops نجح — كسر Direct DML';
  end if;

  v_denied := false;
  begin
    update ops.session_crops set crop_name = 'معدَّل'
    where session_id = v_session_1;
  exception when insufficient_privilege then
    v_denied := true;
  end;

  v_count := 0;
  if v_denied then
    select count(*) into v_count
    from ops.session_crops where crop_name = 'معدَّل';
  end if;

  if v_denied and v_count = 0 then
    raise notice 'PASS 13: التحديث المباشر محجوب — اللقطة بلا مسار تعديل';
  else
    raise notice 'FAIL 13: تحديث مباشر في session_crops: محجوب=%', v_denied;
  end if;

  v_denied := false;
  begin
    delete from ops.session_crops where session_id = v_session_1;
  exception when insufficient_privilege then
    v_denied := true;
  end;

  select count(*) into v_count
  from ops.session_crops where session_id = v_session_1;

  if v_denied and v_count = 2 then
    raise notice 'PASS 14: الحذف المباشر محجوب ومحاصيل الجلسة باقية';
  else
    raise notice 'FAIL 14: حذف مباشر في session_crops: محجوب=% باقٍ=%',
      v_denied, v_count;
  end if;

  -- -------------------------------------------------------------
  -- 11. الرؤية المركّبة: محاصيل جلسة بئر آخر غير مرئية لمالك هذا البئر.
  -- -------------------------------------------------------------
  select count(*) into v_count
  from ops.session_crops sc
  join ops.irrigation_sessions s on s.id = sc.session_id
  where s.well_id = v_other_well;

  if v_count = 0 then
    raise notice 'PASS 15: محاصيل بئر آخر لا تُرى — القراءة تركّب سياسات الجلسات';
  else
    raise notice 'FAIL 15: رؤية مركّبة مسرّبة: %= صفوف لجهة أخرى', v_count;
  end if;
end;
$test$;

rollback;
